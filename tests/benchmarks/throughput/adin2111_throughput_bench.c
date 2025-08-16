/*
 * ADIN2111 Throughput Benchmark Tool
 * 
 * Copyright (C) 2025 Analog Devices Inc.
 * 
 * Comprehensive throughput testing for ADIN2111 driver
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
#define DEFAULT_PORT 12345
#define DEFAULT_DURATION 60
#define DEFAULT_PACKET_SIZE 1024
#define MAX_PACKET_SIZE 1518
#define STATS_INTERVAL 1000000 /* 1 second in microseconds */

struct bench_config {
    char interface[IFNAMSIZ];
    int duration;
    int packet_size;
    int thread_count;
    bool bidirectional;
    bool raw_socket;
    bool verbose;
    char target_ip[16];
    int target_port;
};

struct bench_stats {
    unsigned long packets_sent;
    unsigned long packets_received;
    unsigned long bytes_sent;
    unsigned long bytes_received;
    unsigned long errors;
    double start_time;
    double end_time;
    double min_latency;
    double max_latency;
    double total_latency;
    unsigned long latency_samples;
};

struct thread_context {
    int thread_id;
    struct bench_config *config;
    struct bench_stats stats;
    bool is_sender;
};

static volatile bool benchmark_running = true;
static pthread_mutex_t stats_mutex = PTHREAD_MUTEX_INITIALIZER;
static struct bench_stats global_stats = {0};

/* Signal handler */
static void signal_handler(int sig)
{
    benchmark_running = false;
    printf("\nBenchmark interrupted by signal %d\n", sig);
}

/* Get current time in seconds */
static double get_time(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* Get current time in microseconds */
static unsigned long get_time_us(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec * 1000000UL + ts.tv_nsec / 1000UL;
}

/* Update global statistics */
static void update_global_stats(struct bench_stats *stats)
{
    pthread_mutex_lock(&stats_mutex);
    global_stats.packets_sent += stats->packets_sent;
    global_stats.packets_received += stats->packets_received;
    global_stats.bytes_sent += stats->bytes_sent;
    global_stats.bytes_received += stats->bytes_received;
    global_stats.errors += stats->errors;
    
    if (stats->latency_samples > 0) {
        if (global_stats.min_latency == 0 || stats->min_latency < global_stats.min_latency)
            global_stats.min_latency = stats->min_latency;
        if (stats->max_latency > global_stats.max_latency)
            global_stats.max_latency = stats->max_latency;
        global_stats.total_latency += stats->total_latency;
        global_stats.latency_samples += stats->latency_samples;
    }
    pthread_mutex_unlock(&stats_mutex);
}

/* Create test packet with timestamp */
static int create_test_packet(char *buffer, int size, bool add_timestamp)
{
    struct ethhdr *eth;
    char *payload;
    int payload_size;
    
    if (size < sizeof(struct ethhdr)) {
        return -1;
    }
    
    /* Ethernet header */
    eth = (struct ethhdr *)buffer;
    memset(eth->h_dest, 0xFF, ETH_ALEN);   /* Broadcast */
    memset(eth->h_source, 0x00, ETH_ALEN); /* Source MAC */
    eth->h_proto = htons(ETH_P_IP);
    
    /* Payload */
    payload = buffer + sizeof(struct ethhdr);
    payload_size = size - sizeof(struct ethhdr);
    
    /* Add timestamp if requested */
    if (add_timestamp && payload_size >= sizeof(unsigned long)) {
        unsigned long timestamp = get_time_us();
        memcpy(payload, &timestamp, sizeof(timestamp));
        payload += sizeof(timestamp);
        payload_size -= sizeof(timestamp);
    }
    
    /* Fill remaining payload with test pattern */
    for (int i = 0; i < payload_size; i++) {
        payload[i] = (char)(i & 0xFF);
    }
    
    return size;
}

/* Extract timestamp from packet */
static double extract_timestamp(const char *buffer, int size)
{
    const char *payload;
    unsigned long timestamp;
    
    if (size < sizeof(struct ethhdr) + sizeof(unsigned long)) {
        return 0.0;
    }
    
    payload = buffer + sizeof(struct ethhdr);
    memcpy(&timestamp, payload, sizeof(timestamp));
    
    return timestamp / 1e6; /* Convert to seconds */
}

/* UDP socket sender thread */
static void* udp_sender_thread(void *arg)
{
    struct thread_context *ctx = (struct thread_context *)arg;
    int sockfd;
    struct sockaddr_in dest_addr;
    char *packet_buffer;
    double start_time, end_time;
    unsigned long packet_count = 0;
    unsigned long last_stats_time = 0;
    
    /* Create UDP socket */
    sockfd = socket(AF_INET, SOCK_DGRAM, 0);
    if (sockfd < 0) {
        perror("socket");
        return NULL;
    }
    
    /* Bind to specific interface if specified */
    if (strlen(ctx->config->interface) > 0) {
        struct ifreq ifr;
        strncpy(ifr.ifr_name, ctx->config->interface, IFNAMSIZ - 1);
        if (setsockopt(sockfd, SOL_SOCKET, SO_BINDTODEVICE, &ifr, sizeof(ifr)) < 0) {
            perror("setsockopt SO_BINDTODEVICE");
            close(sockfd);
            return NULL;
        }
    }
    
    /* Setup destination address */
    memset(&dest_addr, 0, sizeof(dest_addr));
    dest_addr.sin_family = AF_INET;
    dest_addr.sin_port = htons(ctx->config->target_port);
    if (inet_aton(ctx->config->target_ip, &dest_addr.sin_addr) == 0) {
        fprintf(stderr, "Invalid target IP address\n");
        close(sockfd);
        return NULL;
    }
    
    /* Allocate packet buffer */
    packet_buffer = malloc(ctx->config->packet_size);
    if (!packet_buffer) {
        perror("malloc");
        close(sockfd);
        return NULL;
    }
    
    start_time = get_time();
    ctx->stats.start_time = start_time;
    
    printf("Thread %d: Starting UDP sender (target: %s:%d, size: %d)\n",
           ctx->thread_id, ctx->config->target_ip, ctx->config->target_port,
           ctx->config->packet_size);
    
    while (benchmark_running && (get_time() - start_time) < ctx->config->duration) {
        /* Create packet with timestamp */
        int packet_size = create_test_packet(packet_buffer, ctx->config->packet_size, true);
        if (packet_size < 0) {
            ctx->stats.errors++;
            continue;
        }
        
        /* Send packet */
        ssize_t sent = sendto(sockfd, packet_buffer, packet_size, 0,
                             (struct sockaddr *)&dest_addr, sizeof(dest_addr));
        
        if (sent < 0) {
            if (errno != EINTR && errno != EAGAIN) {
                ctx->stats.errors++;
            }
        } else {
            ctx->stats.packets_sent++;
            ctx->stats.bytes_sent += sent;
            packet_count++;
        }
        
        /* Print statistics periodically */
        if (ctx->config->verbose) {
            unsigned long current_time = get_time_us();
            if (current_time - last_stats_time >= STATS_INTERVAL) {
                double elapsed = (current_time - start_time * 1e6) / 1e6;
                double rate = packet_count / elapsed;
                printf("Thread %d: Sent %lu packets (%.2f pps)\r",
                       ctx->thread_id, packet_count, rate);
                fflush(stdout);
                last_stats_time = current_time;
            }
        }
        
        /* Small delay to avoid overwhelming */
        usleep(10);
    }
    
    end_time = get_time();
    ctx->stats.end_time = end_time;
    
    if (ctx->config->verbose) {
        printf("\nThread %d: Sender completed - %lu packets in %.2f seconds\n",
               ctx->thread_id, packet_count, end_time - start_time);
    }
    
    free(packet_buffer);
    close(sockfd);
    
    return NULL;
}

/* UDP socket receiver thread */
static void* udp_receiver_thread(void *arg)
{
    struct thread_context *ctx = (struct thread_context *)arg;
    int sockfd;
    struct sockaddr_in bind_addr, from_addr;
    char *packet_buffer;
    double start_time, end_time;
    unsigned long packet_count = 0;
    unsigned long last_stats_time = 0;
    socklen_t addr_len;
    
    /* Create UDP socket */
    sockfd = socket(AF_INET, SOCK_DGRAM, 0);
    if (sockfd < 0) {
        perror("socket");
        return NULL;
    }
    
    /* Set socket options */
    int opt = 1;
    if (setsockopt(sockfd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt)) < 0) {
        perror("setsockopt SO_REUSEADDR");
    }
    
    /* Bind to receive port */
    memset(&bind_addr, 0, sizeof(bind_addr));
    bind_addr.sin_family = AF_INET;
    bind_addr.sin_port = htons(ctx->config->target_port);
    bind_addr.sin_addr.s_addr = INADDR_ANY;
    
    if (bind(sockfd, (struct sockaddr *)&bind_addr, sizeof(bind_addr)) < 0) {
        perror("bind");
        close(sockfd);
        return NULL;
    }
    
    /* Set receive timeout */
    struct timeval timeout;
    timeout.tv_sec = 1;
    timeout.tv_usec = 0;
    if (setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) < 0) {
        perror("setsockopt SO_RCVTIMEO");
    }
    
    /* Allocate packet buffer */
    packet_buffer = malloc(MAX_PACKET_SIZE);
    if (!packet_buffer) {
        perror("malloc");
        close(sockfd);
        return NULL;
    }
    
    start_time = get_time();
    ctx->stats.start_time = start_time;
    ctx->stats.min_latency = 1e9; /* Initialize to large value */
    
    printf("Thread %d: Starting UDP receiver (port: %d)\n",
           ctx->thread_id, ctx->config->target_port);
    
    while (benchmark_running && (get_time() - start_time) < ctx->config->duration) {
        addr_len = sizeof(from_addr);
        ssize_t received = recvfrom(sockfd, packet_buffer, MAX_PACKET_SIZE, 0,
                                   (struct sockaddr *)&from_addr, &addr_len);
        
        if (received < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                continue; /* Timeout, check if we should continue */
            } else if (errno != EINTR) {
                ctx->stats.errors++;
            }
        } else {
            ctx->stats.packets_received++;
            ctx->stats.bytes_received += received;
            packet_count++;
            
            /* Calculate latency if timestamp is present */
            double packet_time = extract_timestamp(packet_buffer, received);
            if (packet_time > 0) {
                double current_time = get_time();
                double latency = current_time - packet_time;
                
                if (latency > 0 && latency < 10.0) { /* Sanity check */
                    if (latency < ctx->stats.min_latency)
                        ctx->stats.min_latency = latency;
                    if (latency > ctx->stats.max_latency)
                        ctx->stats.max_latency = latency;
                    ctx->stats.total_latency += latency;
                    ctx->stats.latency_samples++;
                }
            }
        }
        
        /* Print statistics periodically */
        if (ctx->config->verbose) {
            unsigned long current_time = get_time_us();
            if (current_time - last_stats_time >= STATS_INTERVAL) {
                double elapsed = (current_time - start_time * 1e6) / 1e6;
                double rate = packet_count / elapsed;
                printf("Thread %d: Received %lu packets (%.2f pps)\r",
                       ctx->thread_id, packet_count, rate);
                fflush(stdout);
                last_stats_time = current_time;
            }
        }
    }
    
    end_time = get_time();
    ctx->stats.end_time = end_time;
    
    if (ctx->config->verbose) {
        printf("\nThread %d: Receiver completed - %lu packets in %.2f seconds\n",
               ctx->thread_id, packet_count, end_time - start_time);
    }
    
    free(packet_buffer);
    close(sockfd);
    
    return NULL;
}

/* Raw socket sender thread */
static void* raw_sender_thread(void *arg)
{
    struct thread_context *ctx = (struct thread_context *)arg;
    int sockfd;
    struct sockaddr_ll dest_addr;
    char *packet_buffer;
    double start_time, end_time;
    unsigned long packet_count = 0;
    
    /* Create raw socket */
    sockfd = socket(AF_PACKET, SOCK_RAW, htons(ETH_P_ALL));
    if (sockfd < 0) {
        perror("socket");
        return NULL;
    }
    
    /* Get interface index */
    struct ifreq ifr;
    strncpy(ifr.ifr_name, ctx->config->interface, IFNAMSIZ - 1);
    if (ioctl(sockfd, SIOCGIFINDEX, &ifr) < 0) {
        perror("ioctl SIOCGIFINDEX");
        close(sockfd);
        return NULL;
    }
    
    /* Setup destination address */
    memset(&dest_addr, 0, sizeof(dest_addr));
    dest_addr.sll_family = AF_PACKET;
    dest_addr.sll_ifindex = ifr.ifr_ifindex;
    dest_addr.sll_protocol = htons(ETH_P_ALL);
    
    /* Allocate packet buffer */
    packet_buffer = malloc(ctx->config->packet_size);
    if (!packet_buffer) {
        perror("malloc");
        close(sockfd);
        return NULL;
    }
    
    start_time = get_time();
    ctx->stats.start_time = start_time;
    
    printf("Thread %d: Starting raw socket sender (interface: %s, size: %d)\n",
           ctx->thread_id, ctx->config->interface, ctx->config->packet_size);
    
    while (benchmark_running && (get_time() - start_time) < ctx->config->duration) {
        /* Create raw packet */
        int packet_size = create_test_packet(packet_buffer, ctx->config->packet_size, true);
        if (packet_size < 0) {
            ctx->stats.errors++;
            continue;
        }
        
        /* Send packet */
        ssize_t sent = sendto(sockfd, packet_buffer, packet_size, 0,
                             (struct sockaddr *)&dest_addr, sizeof(dest_addr));
        
        if (sent < 0) {
            if (errno != EINTR && errno != EAGAIN) {
                ctx->stats.errors++;
            }
        } else {
            ctx->stats.packets_sent++;
            ctx->stats.bytes_sent += sent;
            packet_count++;
        }
        
        /* Print progress */
        if (ctx->config->verbose && (packet_count % 10000 == 0)) {
            printf("Thread %d: Sent %lu packets\r", ctx->thread_id, packet_count);
            fflush(stdout);
        }
        
        usleep(100); /* Small delay */
    }
    
    end_time = get_time();
    ctx->stats.end_time = end_time;
    
    if (ctx->config->verbose) {
        printf("\nThread %d: Raw sender completed - %lu packets in %.2f seconds\n",
               ctx->thread_id, packet_count, end_time - start_time);
    }
    
    free(packet_buffer);
    close(sockfd);
    
    return NULL;
}

/* Run throughput benchmark */
static int run_benchmark(struct bench_config *config)
{
    pthread_t *threads;
    struct thread_context *contexts;
    int i;
    double total_duration;
    
    printf("Starting ADIN2111 throughput benchmark...\n");
    printf("Interface: %s\n", config->interface);
    printf("Duration: %d seconds\n", config->duration);
    printf("Packet size: %d bytes\n", config->packet_size);
    printf("Threads: %d\n", config->thread_count);
    printf("Mode: %s\n", config->raw_socket ? "Raw socket" : "UDP");
    if (!config->raw_socket) {
        printf("Target: %s:%d\n", config->target_ip, config->target_port);
    }
    printf("Bidirectional: %s\n", config->bidirectional ? "Yes" : "No");
    printf("\n");
    
    /* Allocate thread arrays */
    int total_threads = config->thread_count * (config->bidirectional ? 2 : 1);
    threads = malloc(total_threads * sizeof(pthread_t));
    contexts = malloc(total_threads * sizeof(struct thread_context));
    
    if (!threads || !contexts) {
        perror("malloc");
        return -1;
    }
    
    /* Initialize global stats */
    memset(&global_stats, 0, sizeof(global_stats));
    global_stats.start_time = get_time();
    
    /* Create sender threads */
    for (i = 0; i < config->thread_count; i++) {
        contexts[i].thread_id = i;
        contexts[i].config = config;
        contexts[i].is_sender = true;
        memset(&contexts[i].stats, 0, sizeof(contexts[i].stats));
        
        if (config->raw_socket) {
            if (pthread_create(&threads[i], NULL, raw_sender_thread, &contexts[i]) != 0) {
                perror("pthread_create");
                return -1;
            }
        } else {
            if (pthread_create(&threads[i], NULL, udp_sender_thread, &contexts[i]) != 0) {
                perror("pthread_create");
                return -1;
            }
        }
    }
    
    /* Create receiver threads if bidirectional */
    if (config->bidirectional) {
        for (i = 0; i < config->thread_count; i++) {
            int idx = config->thread_count + i;
            contexts[idx].thread_id = idx;
            contexts[idx].config = config;
            contexts[idx].is_sender = false;
            memset(&contexts[idx].stats, 0, sizeof(contexts[idx].stats));
            
            if (pthread_create(&threads[idx], NULL, udp_receiver_thread, &contexts[idx]) != 0) {
                perror("pthread_create");
                return -1;
            }
        }
    }
    
    /* Wait for all threads to complete */
    for (i = 0; i < total_threads; i++) {
        pthread_join(threads[i], NULL);
        update_global_stats(&contexts[i].stats);
    }
    
    global_stats.end_time = get_time();
    total_duration = global_stats.end_time - global_stats.start_time;
    
    /* Print results */
    printf("\n");
    printf("ADIN2111 Throughput Benchmark Results\n");
    printf("=====================================\n");
    printf("Total Duration: %.2f seconds\n", total_duration);
    printf("\nTraffic Statistics:\n");
    printf("  Packets Sent: %lu\n", global_stats.packets_sent);
    printf("  Packets Received: %lu\n", global_stats.packets_received);
    printf("  Bytes Sent: %lu (%.2f MB)\n", global_stats.bytes_sent, 
           global_stats.bytes_sent / 1024.0 / 1024.0);
    printf("  Bytes Received: %lu (%.2f MB)\n", global_stats.bytes_received,
           global_stats.bytes_received / 1024.0 / 1024.0);
    printf("  Errors: %lu\n", global_stats.errors);
    
    printf("\nThroughput:\n");
    if (global_stats.packets_sent > 0) {
        double tx_pps = global_stats.packets_sent / total_duration;
        double tx_mbps = (global_stats.bytes_sent * 8.0) / total_duration / 1024.0 / 1024.0;
        printf("  TX Rate: %.2f packets/sec, %.2f Mbps\n", tx_pps, tx_mbps);
    }
    
    if (global_stats.packets_received > 0) {
        double rx_pps = global_stats.packets_received / total_duration;
        double rx_mbps = (global_stats.bytes_received * 8.0) / total_duration / 1024.0 / 1024.0;
        printf("  RX Rate: %.2f packets/sec, %.2f Mbps\n", rx_pps, rx_mbps);
    }
    
    if (global_stats.latency_samples > 0) {
        double avg_latency = global_stats.total_latency / global_stats.latency_samples;
        printf("\nLatency:\n");
        printf("  Samples: %lu\n", global_stats.latency_samples);
        printf("  Min: %.3f ms\n", global_stats.min_latency * 1000.0);
        printf("  Max: %.3f ms\n", global_stats.max_latency * 1000.0);
        printf("  Average: %.3f ms\n", avg_latency * 1000.0);
    }
    
    free(threads);
    free(contexts);
    
    return 0;
}

/* Usage */
static void usage(const char *prog)
{
    printf("Usage: %s [OPTIONS]\n", prog);
    printf("\nOptions:\n");
    printf("  -i INTERFACE    Network interface to test (required)\n");
    printf("  -d DURATION     Test duration in seconds (default: %d)\n", DEFAULT_DURATION);
    printf("  -s SIZE         Packet size in bytes (default: %d)\n", DEFAULT_PACKET_SIZE);
    printf("  -t THREADS      Number of threads (default: 1)\n");
    printf("  -T IP           Target IP address (default: 127.0.0.1)\n");
    printf("  -p PORT         Target port (default: %d)\n", DEFAULT_PORT);
    printf("  -b              Bidirectional test (send and receive)\n");
    printf("  -r              Use raw sockets instead of UDP\n");
    printf("  -v              Verbose output\n");
    printf("  -h              Show this help\n");
    printf("\nExamples:\n");
    printf("  %s -i eth0 -d 30 -s 1500      # Test eth0 for 30 seconds with 1500 byte packets\n", prog);
    printf("  %s -i eth0 -b -t 4            # Bidirectional test with 4 threads\n", prog);
    printf("  %s -i eth0 -r                 # Use raw sockets\n", prog);
}

int main(int argc, char *argv[])
{
    struct bench_config config = {
        .duration = DEFAULT_DURATION,
        .packet_size = DEFAULT_PACKET_SIZE,
        .thread_count = 1,
        .bidirectional = false,
        .raw_socket = false,
        .verbose = false,
        .target_port = DEFAULT_PORT
    };
    
    int opt;
    
    strcpy(config.target_ip, "127.0.0.1");
    
    printf("ADIN2111 Throughput Benchmark v%s\n", BENCH_VERSION);
    printf("Copyright (C) 2025 Analog Devices Inc.\n\n");
    
    /* Parse command line options */
    while ((opt = getopt(argc, argv, "i:d:s:t:T:p:brvh")) != -1) {
        switch (opt) {
        case 'i':
            strncpy(config.interface, optarg, IFNAMSIZ - 1);
            config.interface[IFNAMSIZ - 1] = '\0';
            break;
        case 'd':
            config.duration = atoi(optarg);
            if (config.duration <= 0) {
                fprintf(stderr, "Invalid duration\n");
                return 1;
            }
            break;
        case 's':
            config.packet_size = atoi(optarg);
            if (config.packet_size <= 0 || config.packet_size > MAX_PACKET_SIZE) {
                fprintf(stderr, "Invalid packet size (1-%d)\n", MAX_PACKET_SIZE);
                return 1;
            }
            break;
        case 't':
            config.thread_count = atoi(optarg);
            if (config.thread_count <= 0 || config.thread_count > 16) {
                fprintf(stderr, "Invalid thread count (1-16)\n");
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
        case 'b':
            config.bidirectional = true;
            break;
        case 'r':
            config.raw_socket = true;
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
    return run_benchmark(&config);
}