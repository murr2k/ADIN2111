/*
 * ADIN2111 CPU Utilization Benchmark Tool
 * 
 * Copyright (C) 2025 Analog Devices Inc.
 * 
 * CPU utilization monitoring during ADIN2111 operations
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <pthread.h>
#include <time.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>

#define BENCH_VERSION "1.0.0"
#define DEFAULT_DURATION 60
#define DEFAULT_INTERVAL 1000  /* 1 second in milliseconds */
#define MAX_CPUS 64
#define PROC_STAT_FILE "/proc/stat"
#define PROC_MEMINFO_FILE "/proc/meminfo"

struct cpu_stats {
    unsigned long user;
    unsigned long nice;
    unsigned long system;
    unsigned long idle;
    unsigned long iowait;
    unsigned long irq;
    unsigned long softirq;
    unsigned long steal;
    unsigned long guest;
    unsigned long guest_nice;
    unsigned long total;
    unsigned long total_idle;
};

struct memory_stats {
    unsigned long mem_total;
    unsigned long mem_free;
    unsigned long mem_available;
    unsigned long buffers;
    unsigned long cached;
    unsigned long swap_total;
    unsigned long swap_free;
};

struct network_stats {
    unsigned long rx_packets;
    unsigned long tx_packets;
    unsigned long rx_bytes;
    unsigned long tx_bytes;
    unsigned long rx_errors;
    unsigned long tx_errors;
};

struct bench_config {
    char interface[IFNAMSIZ];
    int duration;
    int interval_ms;
    bool verbose;
    bool generate_load;
    int load_threads;
};

struct cpu_monitor {
    struct cpu_stats prev_stats[MAX_CPUS + 1]; /* +1 for total */
    struct cpu_stats curr_stats[MAX_CPUS + 1];
    int cpu_count;
    double cpu_usage[MAX_CPUS + 1];
    struct memory_stats memory;
    struct network_stats network;
    char interface[IFNAMSIZ];
};

static volatile bool monitoring_running = true;

/* Signal handler */
static void signal_handler(int sig)
{
    monitoring_running = false;
    printf("\nCPU monitoring interrupted by signal %d\n", sig);
}

/* Get current time in milliseconds */
static unsigned long get_time_ms(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000UL + ts.tv_nsec / 1000000UL;
}

/* Parse CPU stats from /proc/stat */
static int parse_cpu_stats(struct cpu_stats *stats, const char *line)
{
    int parsed = sscanf(line, "cpu%*d %lu %lu %lu %lu %lu %lu %lu %lu %lu %lu",
                       &stats->user, &stats->nice, &stats->system, &stats->idle,
                       &stats->iowait, &stats->irq, &stats->softirq, &stats->steal,
                       &stats->guest, &stats->guest_nice);
    
    if (parsed >= 4) {
        stats->total = stats->user + stats->nice + stats->system + stats->idle +
                      stats->iowait + stats->irq + stats->softirq + stats->steal;
        stats->total_idle = stats->idle + stats->iowait;
        return 0;
    }
    
    return -1;
}

/* Read CPU statistics */
static int read_cpu_stats(struct cpu_monitor *monitor)
{
    FILE *fp;
    char line[256];
    int cpu_index = 0;
    
    fp = fopen(PROC_STAT_FILE, "r");
    if (!fp) {
        perror("fopen /proc/stat");
        return -1;
    }
    
    while (fgets(line, sizeof(line), fp) && cpu_index <= MAX_CPUS) {
        if (strncmp(line, "cpu", 3) == 0) {
            if (cpu_index == 0) {
                /* First line is total CPU stats */
                if (parse_cpu_stats(&monitor->curr_stats[0], line) != 0) {
                    fclose(fp);
                    return -1;
                }
            } else {
                /* Individual CPU stats */
                if (parse_cpu_stats(&monitor->curr_stats[cpu_index], line) != 0) {
                    break;
                }
            }
            cpu_index++;
        } else if (strncmp(line, "cpu", 3) != 0) {
            /* No more CPU lines */
            break;
        }
    }
    
    monitor->cpu_count = cpu_index - 1; /* Subtract 1 for total */
    fclose(fp);
    return 0;
}

/* Calculate CPU usage percentage */
static double calculate_cpu_usage(struct cpu_stats *prev, struct cpu_stats *curr)
{
    unsigned long total_diff = curr->total - prev->total;
    unsigned long idle_diff = curr->total_idle - prev->total_idle;
    
    if (total_diff == 0) {
        return 0.0;
    }
    
    return 100.0 * (total_diff - idle_diff) / total_diff;
}

/* Read memory statistics */
static int read_memory_stats(struct memory_stats *memory)
{
    FILE *fp;
    char line[256];
    char key[64];
    unsigned long value;
    
    fp = fopen(PROC_MEMINFO_FILE, "r");
    if (!fp) {
        perror("fopen /proc/meminfo");
        return -1;
    }
    
    memset(memory, 0, sizeof(*memory));
    
    while (fgets(line, sizeof(line), fp)) {
        if (sscanf(line, "%63s %lu kB", key, &value) == 2) {
            if (strcmp(key, "MemTotal:") == 0) {
                memory->mem_total = value;
            } else if (strcmp(key, "MemFree:") == 0) {
                memory->mem_free = value;
            } else if (strcmp(key, "MemAvailable:") == 0) {
                memory->mem_available = value;
            } else if (strcmp(key, "Buffers:") == 0) {
                memory->buffers = value;
            } else if (strcmp(key, "Cached:") == 0) {
                memory->cached = value;
            } else if (strcmp(key, "SwapTotal:") == 0) {
                memory->swap_total = value;
            } else if (strcmp(key, "SwapFree:") == 0) {
                memory->swap_free = value;
            }
        }
    }
    
    fclose(fp);
    return 0;
}

/* Read network interface statistics */
static int read_network_stats(struct network_stats *network, const char *interface)
{
    FILE *fp;
    char line[256];
    char iface[IFNAMSIZ];
    
    fp = fopen("/proc/net/dev", "r");
    if (!fp) {
        perror("fopen /proc/net/dev");
        return -1;
    }
    
    /* Skip header lines */
    fgets(line, sizeof(line), fp);
    fgets(line, sizeof(line), fp);
    
    memset(network, 0, sizeof(*network));
    
    while (fgets(line, sizeof(line), fp)) {
        if (sscanf(line, "%[^:]: %lu %lu %lu %*u %*u %*u %*u %*u %lu %lu %lu",
                   iface, &network->rx_bytes, &network->rx_packets, &network->rx_errors,
                   &network->tx_bytes, &network->tx_packets, &network->tx_errors) >= 6) {
            
            if (strcmp(iface, interface) == 0) {
                fclose(fp);
                return 0;
            }
        }
    }
    
    fclose(fp);
    return -1; /* Interface not found */
}

/* Update CPU monitor statistics */
static int update_cpu_monitor(struct cpu_monitor *monitor)
{
    /* Copy current to previous */
    memcpy(monitor->prev_stats, monitor->curr_stats, sizeof(monitor->prev_stats));
    
    /* Read new statistics */
    if (read_cpu_stats(monitor) != 0) {
        return -1;
    }
    
    /* Calculate CPU usage */
    for (int i = 0; i <= monitor->cpu_count; i++) {
        monitor->cpu_usage[i] = calculate_cpu_usage(&monitor->prev_stats[i],
                                                   &monitor->curr_stats[i]);
    }
    
    /* Read memory statistics */
    read_memory_stats(&monitor->memory);
    
    /* Read network statistics */
    if (strlen(monitor->interface) > 0) {
        read_network_stats(&monitor->network, monitor->interface);
    }
    
    return 0;
}

/* Print CPU monitoring header */
static void print_monitor_header(void)
{
    printf("Time     | CPU%% | User%% | Sys%% | IOWait%% | Memory%% | Network (pps) | Errors\n");
    printf("---------|------|-------|------|---------|---------|---------------|-------\n");
}

/* Print CPU monitoring data */
static void print_monitor_data(struct cpu_monitor *monitor, unsigned long timestamp)
{
    double memory_usage = 0.0;
    if (monitor->memory.mem_total > 0) {
        memory_usage = 100.0 * (monitor->memory.mem_total - monitor->memory.mem_available) /
                       monitor->memory.mem_total;
    }
    
    /* Calculate rates (simplified - would need previous values for accurate rates) */
    unsigned long total_packets = monitor->network.rx_packets + monitor->network.tx_packets;
    unsigned long total_errors = monitor->network.rx_errors + monitor->network.tx_errors;
    
    struct cpu_stats *total = &monitor->curr_stats[0];
    double user_pct = 0.0, sys_pct = 0.0, iowait_pct = 0.0;
    
    if (total->total > 0) {
        user_pct = 100.0 * (total->user + total->nice) / total->total;
        sys_pct = 100.0 * (total->system + total->irq + total->softirq) / total->total;
        iowait_pct = 100.0 * total->iowait / total->total;
    }
    
    printf("%8lu | %4.1f | %5.1f | %4.1f | %7.1f | %6.1f%% | %13lu | %6lu\n",
           timestamp / 1000, /* Convert to seconds */
           monitor->cpu_usage[0],
           user_pct,
           sys_pct,
           iowait_pct,
           memory_usage,
           total_packets,
           total_errors);
}

/* Traffic generation thread */
static void* traffic_generator_thread(void *arg)
{
    struct bench_config *config = (struct bench_config *)arg;
    int sockfd;
    struct sockaddr_in dest_addr;
    char buffer[1024];
    
    /* Create UDP socket */
    sockfd = socket(AF_INET, SOCK_DGRAM, 0);
    if (sockfd < 0) {
        perror("socket");
        return NULL;
    }
    
    /* Bind to interface if specified */
    if (strlen(config->interface) > 0) {
        struct ifreq ifr;
        strncpy(ifr.ifr_name, config->interface, IFNAMSIZ - 1);
        if (setsockopt(sockfd, SOL_SOCKET, SO_BINDTODEVICE, &ifr, sizeof(ifr)) < 0) {
            perror("setsockopt SO_BINDTODEVICE");
            close(sockfd);
            return NULL;
        }
    }
    
    /* Setup destination */
    memset(&dest_addr, 0, sizeof(dest_addr));
    dest_addr.sin_family = AF_INET;
    dest_addr.sin_port = htons(12345);
    dest_addr.sin_addr.s_addr = inet_addr("127.0.0.1");
    
    /* Fill buffer with test data */
    memset(buffer, 0xAA, sizeof(buffer));
    
    printf("Traffic generator thread started\n");
    
    while (monitoring_running) {
        sendto(sockfd, buffer, sizeof(buffer), 0,
               (struct sockaddr *)&dest_addr, sizeof(dest_addr));
        usleep(1000); /* Send at ~1000 pps */
    }
    
    close(sockfd);
    printf("Traffic generator thread stopped\n");
    return NULL;
}

/* Main monitoring function */
static int run_cpu_monitoring(struct bench_config *config)
{
    struct cpu_monitor monitor = {0};
    pthread_t *traffic_threads = NULL;
    unsigned long start_time, current_time;
    unsigned long last_update = 0;
    
    strncpy(monitor.interface, config->interface, IFNAMSIZ - 1);
    
    printf("Starting CPU utilization monitoring...\n");
    printf("Interface: %s\n", config->interface);
    printf("Duration: %d seconds\n", config->duration);
    printf("Sample interval: %d ms\n", config->interval_ms);
    printf("Generate load: %s\n", config->generate_load ? "Yes" : "No");
    if (config->generate_load) {
        printf("Load threads: %d\n", config->load_threads);
    }
    printf("\n");
    
    /* Initial CPU stats read */
    if (read_cpu_stats(&monitor) != 0) {
        fprintf(stderr, "Failed to read initial CPU stats\n");
        return -1;
    }
    
    printf("Detected %d CPU cores\n", monitor.cpu_count);
    printf("\n");
    
    /* Start traffic generation threads if requested */
    if (config->generate_load) {
        traffic_threads = malloc(config->load_threads * sizeof(pthread_t));
        if (!traffic_threads) {
            perror("malloc");
            return -1;
        }
        
        for (int i = 0; i < config->load_threads; i++) {
            if (pthread_create(&traffic_threads[i], NULL, traffic_generator_thread, config) != 0) {
                perror("pthread_create");
                free(traffic_threads);
                return -1;
            }
        }
        
        sleep(1); /* Let traffic threads start */
    }
    
    print_monitor_header();
    
    start_time = get_time_ms();
    
    while (monitoring_running) {
        current_time = get_time_ms();
        
        /* Check if monitoring duration exceeded */
        if (config->duration > 0 && (current_time - start_time) >= (config->duration * 1000UL)) {
            break;
        }
        
        /* Update statistics at specified interval */
        if (current_time - last_update >= config->interval_ms) {
            if (update_cpu_monitor(&monitor) == 0) {
                print_monitor_data(&monitor, current_time - start_time);
            }
            last_update = current_time;
        }
        
        usleep(100000); /* 100ms sleep */
    }
    
    /* Stop traffic generation */
    monitoring_running = false;
    
    if (traffic_threads) {
        for (int i = 0; i < config->load_threads; i++) {
            pthread_join(traffic_threads[i], NULL);
        }
        free(traffic_threads);
    }
    
    /* Print summary */
    printf("\n");
    printf("CPU Monitoring Summary\n");
    printf("=====================\n");
    printf("Monitoring duration: %.2f seconds\n", (current_time - start_time) / 1000.0);
    printf("Average CPU usage: %.1f%%\n", monitor.cpu_usage[0]);
    
    if (monitor.memory.mem_total > 0) {
        double memory_usage = 100.0 * (monitor.memory.mem_total - monitor.memory.mem_available) /
                             monitor.memory.mem_total;
        printf("Memory usage: %.1f%% (%.1f MB / %.1f MB)\n",
               memory_usage,
               (monitor.memory.mem_total - monitor.memory.mem_available) / 1024.0,
               monitor.memory.mem_total / 1024.0);
    }
    
    if (strlen(monitor.interface) > 0) {
        printf("Network interface %s:\n", monitor.interface);
        printf("  RX: %lu packets, %lu bytes, %lu errors\n",
               monitor.network.rx_packets, monitor.network.rx_bytes, monitor.network.rx_errors);
        printf("  TX: %lu packets, %lu bytes, %lu errors\n",
               monitor.network.tx_packets, monitor.network.tx_bytes, monitor.network.tx_errors);
    }
    
    return 0;
}

/* Usage */
static void usage(const char *prog)
{
    printf("Usage: %s [OPTIONS]\n", prog);
    printf("\nOptions:\n");
    printf("  -i INTERFACE    Network interface to monitor (required)\n");
    printf("  -d DURATION     Monitoring duration in seconds (default: %d, 0=infinite)\n", DEFAULT_DURATION);
    printf("  -I INTERVAL     Sample interval in milliseconds (default: %d)\n", DEFAULT_INTERVAL);
    printf("  -g              Generate network load for testing\n");
    printf("  -t THREADS      Number of load generation threads (default: 1)\n");
    printf("  -v              Verbose output\n");
    printf("  -h              Show this help\n");
    printf("\nExamples:\n");
    printf("  %s -i eth0 -d 30             # Monitor eth0 for 30 seconds\n", prog);
    printf("  %s -i eth0 -g -t 4           # Monitor with 4 load generation threads\n", prog);
    printf("  %s -i eth0 -I 500            # Sample every 500ms\n", prog);
}

int main(int argc, char *argv[])
{
    struct bench_config config = {
        .duration = DEFAULT_DURATION,
        .interval_ms = DEFAULT_INTERVAL,
        .verbose = false,
        .generate_load = false,
        .load_threads = 1
    };
    
    int opt;
    
    printf("ADIN2111 CPU Utilization Benchmark v%s\n", BENCH_VERSION);
    printf("Copyright (C) 2025 Analog Devices Inc.\n\n");
    
    /* Parse command line options */
    while ((opt = getopt(argc, argv, "i:d:I:gt:vh")) != -1) {
        switch (opt) {
        case 'i':
            strncpy(config.interface, optarg, IFNAMSIZ - 1);
            config.interface[IFNAMSIZ - 1] = '\0';
            break;
        case 'd':
            config.duration = atoi(optarg);
            if (config.duration < 0) {
                fprintf(stderr, "Invalid duration\n");
                return 1;
            }
            break;
        case 'I':
            config.interval_ms = atoi(optarg);
            if (config.interval_ms < 100 || config.interval_ms > 60000) {
                fprintf(stderr, "Invalid interval (100-60000 ms)\n");
                return 1;
            }
            break;
        case 'g':
            config.generate_load = true;
            break;
        case 't':
            config.load_threads = atoi(optarg);
            if (config.load_threads < 1 || config.load_threads > 16) {
                fprintf(stderr, "Invalid thread count (1-16)\n");
                return 1;
            }
            break;
        case 'v':
            config.verbose = true;
            break;
        case 'h':
            usage(argv[0]);
            return 0;
        default:
            usage(argv[0]);
            return 1;
        }
    }
    
    if (strlen(config.interface) == 0) {
        fprintf(stderr, "Network interface must be specified with -i\n");
        usage(argv[0]);
        return 1;
    }
    
    /* Setup signal handlers */
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    
    /* Run monitoring */
    return run_cpu_monitoring(&config);
}