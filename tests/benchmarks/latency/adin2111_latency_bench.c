/*
 * ADIN2111 Latency Benchmark Tool
 * 
 * Copyright (C) 2025 Analog Devices Inc.
 * 
 * Precision latency measurement for ADIN2111 driver
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <pthread.h>
#include <time.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <linux/if_packet.h>
#include <linux/if_ether.h>

#define BENCH_VERSION "1.0.0"
#define DEFAULT_PORT 12346
#define DEFAULT_COUNT 1000
#define DEFAULT_INTERVAL_US 10000  /* 10ms */
#define MAX_PACKET_SIZE 1518
#define TIMESTAMP_SIZE 16

struct latency_config {
    char interface[IFNAMSIZ];
    int packet_count;
    int packet_size;
    int interval_us;
    bool continuous;
    bool verbose;
    char target_ip[16];
    int target_port;
};

struct latency_sample {
    double send_time;
    double receive_time;
    double latency;
    int sequence;
    int size;
};

struct latency_stats {
    double min_latency;
    double max_latency;
    double total_latency;
    double sum_squares;
    int sample_count;
    int lost_packets;
    double jitter;
};

static volatile bool benchmark_running = true;

/* Signal handler */
static void signal_handler(int sig)
{
    benchmark_running = false;
    printf("\nLatency benchmark interrupted by signal %d\n", sig);
}

/* Get high precision timestamp */
static double get_precise_time(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* Create timestamped packet */
static int create_timestamped_packet(char *buffer, int size, int sequence)
{
    struct {
        double timestamp;
        int sequence;
        int size;
        char padding[4];
    } header;
    
    if (size < sizeof(header)) {
        return -1;
    }
    
    header.timestamp = get_precise_time();
    header.sequence = sequence;
    header.size = size;
    memset(header.padding, 0, sizeof(header.padding));
    
    memcpy(buffer, &header, sizeof(header));
    
    /* Fill remaining with test pattern */
    for (int i = sizeof(header); i < size; i++) {
        buffer[i] = (char)(i & 0xFF);
    }
    
    return size;
}

/* Extract timestamp from packet */
static int extract_timestamp(const char *buffer, int size, struct latency_sample *sample)
{
    struct {
        double timestamp;
        int sequence;
        int size;
        char padding[4];
    } header;
    
    if (size < sizeof(header)) {
        return -1;
    }
    
    memcpy(&header, buffer, sizeof(header));
    
    sample->send_time = header.timestamp;
    sample->receive_time = get_precise_time();
    sample->latency = sample->receive_time - sample->send_time;
    sample->sequence = header.sequence;
    sample->size = header.size;
    
    return 0;
}

/* Update latency statistics */
static void update_stats(struct latency_stats *stats, struct latency_sample *sample)
{
    if (sample->latency < 0 || sample->latency > 10.0) {
        /* Ignore invalid latency measurements */
        return;
    }
    
    if (stats->sample_count == 0) {
        stats->min_latency = sample->latency;
        stats->max_latency = sample->latency;
    } else {
        if (sample->latency < stats->min_latency)
            stats->min_latency = sample->latency;
        if (sample->latency > stats->max_latency)
            stats->max_latency = sample->latency;
    }
    
    stats->total_latency += sample->latency;
    stats->sum_squares += sample->latency * sample->latency;
    stats->sample_count++;
}

/* Calculate jitter (standard deviation) */
static void calculate_jitter(struct latency_stats *stats)
{
    if (stats->sample_count < 2) {
        stats->jitter = 0.0;
        return;
    }
    
    double mean = stats->total_latency / stats->sample_count;
    double variance = (stats->sum_squares / stats->sample_count) - (mean * mean);
    stats->jitter = sqrt(variance);
}

/* UDP latency test */
static int run_udp_latency_test(struct latency_config *config)
{
    int send_sock, recv_sock;
    struct sockaddr_in dest_addr, bind_addr, from_addr;
    char *send_buffer, *recv_buffer;
    struct latency_stats stats = {0};
    struct latency_sample sample;
    socklen_t addr_len;
    fd_set read_fds;
    struct timeval timeout;
    int i;
    
    printf("Starting UDP latency test...\n");
    printf("Target: %s:%d\n", config->target_ip, config->target_port);
    printf("Packet size: %d bytes\n", config->packet_size);
    printf("Packet count: %d\n", config->packet_count);
    printf("Interval: %d microseconds\n", config->interval_us);
    printf("\n");
    
    /* Create sockets */
    send_sock = socket(AF_INET, SOCK_DGRAM, 0);
    recv_sock = socket(AF_INET, SOCK_DGRAM, 0);
    
    if (send_sock < 0 || recv_sock < 0) {
        perror("socket");
        return -1;
    }
    
    /* Bind sender to specific interface if specified */
    if (strlen(config->interface) > 0) {
        struct ifreq ifr;
        strncpy(ifr.ifr_name, config->interface, IFNAMSIZ - 1);
        if (setsockopt(send_sock, SOL_SOCKET, SO_BINDTODEVICE, &ifr, sizeof(ifr)) < 0) {
            perror("setsockopt SO_BINDTODEVICE");
            close(send_sock);
            close(recv_sock);
            return -1;
        }
    }
    
    /* Setup destination address */
    memset(&dest_addr, 0, sizeof(dest_addr));
    dest_addr.sin_family = AF_INET;
    dest_addr.sin_port = htons(config->target_port);
    if (inet_aton(config->target_ip, &dest_addr.sin_addr) == 0) {
        fprintf(stderr, "Invalid target IP address\n");
        close(send_sock);
        close(recv_sock);
        return -1;
    }
    
    /* Bind receiver */
    memset(&bind_addr, 0, sizeof(bind_addr));
    bind_addr.sin_family = AF_INET;
    bind_addr.sin_port = htons(config->target_port + 1); /* Reply port */
    bind_addr.sin_addr.s_addr = INADDR_ANY;
    
    if (bind(recv_sock, (struct sockaddr *)&bind_addr, sizeof(bind_addr)) < 0) {
        perror("bind");
        close(send_sock);
        close(recv_sock);
        return -1;
    }
    
    /* Set socket timeout */
    timeout.tv_sec = 1;
    timeout.tv_usec = 0;
    if (setsockopt(recv_sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) < 0) {
        perror("setsockopt SO_RCVTIMEO");
    }
    
    /* Allocate buffers */
    send_buffer = malloc(config->packet_size);
    recv_buffer = malloc(config->packet_size);
    
    if (!send_buffer || !recv_buffer) {
        perror("malloc");
        close(send_sock);
        close(recv_sock);
        return -1;
    }
    
    printf("Seq  | Latency (ms) | Jitter (ms) | Status\n");
    printf("-----|-------------|-------------|--------\n");
    
    /* Send packets and measure latency */
    for (i = 0; i < config->packet_count && benchmark_running; i++) {
        /* Create timestamped packet */
        int packet_size = create_timestamped_packet(send_buffer, config->packet_size, i);
        if (packet_size < 0) {
            stats.lost_packets++;
            continue;
        }
        
        /* Send packet */
        ssize_t sent = sendto(send_sock, send_buffer, packet_size, 0,
                             (struct sockaddr *)&dest_addr, sizeof(dest_addr));
        
        if (sent < 0) {
            stats.lost_packets++;
            if (config->verbose) {
                printf("%4d | Error: send failed         | LOST\n", i);
            }
            continue;
        }
        
        /* Wait for response with timeout */
        FD_ZERO(&read_fds);
        FD_SET(recv_sock, &read_fds);
        
        timeout.tv_sec = 0;
        timeout.tv_usec = 500000; /* 500ms timeout */
        
        int select_result = select(recv_sock + 1, &read_fds, NULL, NULL, &timeout);
        
        if (select_result > 0 && FD_ISSET(recv_sock, &read_fds)) {
            addr_len = sizeof(from_addr);
            ssize_t received = recvfrom(recv_sock, recv_buffer, config->packet_size, 0,
                                       (struct sockaddr *)&from_addr, &addr_len);
            
            if (received > 0) {
                if (extract_timestamp(recv_buffer, received, &sample) == 0) {
                    update_stats(&stats, &sample);
                    calculate_jitter(&stats);
                    
                    if (config->verbose || (i % 100 == 0)) {
                        printf("%4d | %11.3f | %11.3f | OK\n",
                               sample.sequence,
                               sample.latency * 1000.0,
                               stats.jitter * 1000.0);
                    }
                } else {
                    stats.lost_packets++;
                    if (config->verbose) {
                        printf("%4d | Invalid timestamp       | LOST\n", i);
                    }
                }
            } else {
                stats.lost_packets++;
                if (config->verbose) {
                    printf("%4d | Receive error           | LOST\n", i);
                }
            }
        } else {
            stats.lost_packets++;
            if (config->verbose) {
                printf("%4d | Timeout                 | LOST\n", i);
            }
        }
        
        /* Wait for next interval */
        if (config->interval_us > 0) {
            usleep(config->interval_us);
        }
    }
    
    /* Print results */
    printf("\n");
    printf("Latency Test Results\n");
    printf("===================\n");
    printf("Packets sent: %d\n", i);
    printf("Packets received: %d\n", stats.sample_count);
    printf("Packet loss: %d (%.2f%%)\n", stats.lost_packets,
           (stats.lost_packets * 100.0) / i);
    
    if (stats.sample_count > 0) {
        double avg_latency = stats.total_latency / stats.sample_count;
        printf("\nLatency Statistics:\n");
        printf("  Minimum: %.3f ms\n", stats.min_latency * 1000.0);
        printf("  Maximum: %.3f ms\n", stats.max_latency * 1000.0);
        printf("  Average: %.3f ms\n", avg_latency * 1000.0);
        printf("  Jitter (stddev): %.3f ms\n", stats.jitter * 1000.0);
        
        /* Percentile calculations would require sorting, simplified here */
        printf("\nLatency Distribution:\n");
        if (stats.min_latency * 1000.0 < 1.0) {
            printf("  < 1ms: Excellent\n");
        } else if (stats.min_latency * 1000.0 < 10.0) {
            printf("  1-10ms: Good\n");
        } else if (stats.min_latency * 1000.0 < 100.0) {
            printf("  10-100ms: Fair\n");
        } else {
            printf("  > 100ms: Poor\n");
        }
    }
    
    free(send_buffer);
    free(recv_buffer);
    close(send_sock);
    close(recv_sock);
    
    return (stats.sample_count > 0) ? 0 : -1;
}

/* Continuous latency monitoring */
static int run_continuous_monitoring(struct latency_config *config)
{
    struct latency_stats stats = {0};
    time_t last_report = time(NULL);
    
    printf("Starting continuous latency monitoring...\n");
    printf("Press Ctrl+C to stop\n\n");
    
    while (benchmark_running) {
        /* Run a small batch of measurements */
        struct latency_config batch_config = *config;
        batch_config.packet_count = 10;
        batch_config.verbose = false;
        
        /* This would need to be implemented with proper continuous monitoring */
        /* For now, just run periodic batches */
        
        time_t now = time(NULL);
        if (now - last_report >= 5) {
            printf("Continuous monitoring: %d samples, avg %.3f ms\n",
                   stats.sample_count,
                   stats.sample_count > 0 ? (stats.total_latency / stats.sample_count * 1000.0) : 0.0);
            last_report = now;
        }
        
        sleep(1);
    }
    
    return 0;
}

/* Usage */
static void usage(const char *prog)
{
    printf("Usage: %s [OPTIONS]\n", prog);
    printf("\nOptions:\n");
    printf("  -i INTERFACE    Network interface to test (required)\n");
    printf("  -c COUNT        Number of packets to send (default: %d)\n", DEFAULT_COUNT);
    printf("  -s SIZE         Packet size in bytes (default: 64)\n");
    printf("  -I INTERVAL     Interval between packets in microseconds (default: %d)\n", DEFAULT_INTERVAL_US);
    printf("  -T IP           Target IP address (default: 127.0.0.1)\n");
    printf("  -p PORT         Target port (default: %d)\n", DEFAULT_PORT);
    printf("  -C              Continuous monitoring mode\n");
    printf("  -v              Verbose output\n");
    printf("  -h              Show this help\n");
    printf("\nExamples:\n");
    printf("  %s -i eth0 -c 1000 -s 64      # Test eth0 with 1000 64-byte packets\n", prog);
    printf("  %s -i eth0 -C                 # Continuous monitoring on eth0\n", prog);
    printf("  %s -i eth0 -I 1000 -v         # 1ms intervals with verbose output\n", prog);
}

int main(int argc, char *argv[])
{
    struct latency_config config = {
        .packet_count = DEFAULT_COUNT,
        .packet_size = 64,
        .interval_us = DEFAULT_INTERVAL_US,
        .continuous = false,
        .verbose = false,
        .target_port = DEFAULT_PORT
    };
    
    int opt;
    
    strcpy(config.target_ip, "127.0.0.1");
    
    printf("ADIN2111 Latency Benchmark v%s\n", BENCH_VERSION);
    printf("Copyright (C) 2025 Analog Devices Inc.\n\n");
    
    /* Parse command line options */
    while ((opt = getopt(argc, argv, "i:c:s:I:T:p:Cvh")) != -1) {
        switch (opt) {
        case 'i':
            strncpy(config.interface, optarg, IFNAMSIZ - 1);
            config.interface[IFNAMSIZ - 1] = '\0';
            break;
        case 'c':
            config.packet_count = atoi(optarg);
            if (config.packet_count <= 0) {
                fprintf(stderr, "Invalid packet count\n");
                return 1;
            }
            break;
        case 's':
            config.packet_size = atoi(optarg);
            if (config.packet_size < 32 || config.packet_size > MAX_PACKET_SIZE) {
                fprintf(stderr, "Invalid packet size (32-%d)\n", MAX_PACKET_SIZE);
                return 1;
            }
            break;
        case 'I':
            config.interval_us = atoi(optarg);
            if (config.interval_us < 0) {
                fprintf(stderr, "Invalid interval\n");
                return 1;
            }
            break;
        case 'T':
            strncpy(config.target_ip, optarg, sizeof(config.target_ip) - 1);
            config.target_ip[sizeof(config.target_ip) - 1] = '\0';
            break;
        case 'p':
            config.target_port = atoi(optarg);
            if (config.target_port <= 0 || config.target_port > 65535) {
                fprintf(stderr, "Invalid port number\n");
                return 1;
            }
            break;
        case 'C':
            config.continuous = true;
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
    
    /* Run benchmark */
    if (config.continuous) {
        return run_continuous_monitoring(&config);
    } else {
        return run_udp_latency_test(&config);
    }
}