/*
 * ADIN2111 User-space Test Utilities
 * 
 * Copyright (C) 2025 Analog Devices Inc.
 * 
 * User-space utilities for testing ADIN2111 driver functionality
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <net/if.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <linux/sockios.h>
#include <linux/ethtool.h>
#include <time.h>
#include <signal.h>
#include <pthread.h>

#define ADIN2111_TEST_VERSION "1.0.0"
#define MAX_INTERFACES 10
#define MAX_PACKET_SIZE 1518
#define DEFAULT_TEST_DURATION 60

struct test_config {
    char interface[IFNAMSIZ];
    int packet_size;
    int packet_count;
    int test_duration;
    int thread_count;
    bool verbose;
    bool continuous;
};

struct test_stats {
    unsigned long packets_sent;
    unsigned long packets_received;
    unsigned long bytes_sent;
    unsigned long bytes_received;
    unsigned long errors;
    double start_time;
    double end_time;
};

static volatile bool test_running = true;

/* Signal handler */
static void signal_handler(int sig)
{
    test_running = false;
    printf("\nTest interrupted by signal %d\n", sig);
}

/* Get current time in seconds */
static double get_time(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

/* Check if interface exists and is up */
static int check_interface(const char *interface)
{
    struct ifreq ifr;
    int sockfd;
    
    sockfd = socket(AF_INET, SOCK_DGRAM, 0);
    if (sockfd < 0) {
        perror("socket");
        return -1;
    }
    
    strncpy(ifr.ifr_name, interface, IFNAMSIZ - 1);
    ifr.ifr_name[IFNAMSIZ - 1] = '\0';
    
    if (ioctl(sockfd, SIOCGIFFLAGS, &ifr) < 0) {
        perror("ioctl SIOCGIFFLAGS");
        close(sockfd);
        return -1;
    }
    
    close(sockfd);
    
    if (!(ifr.ifr_flags & IFF_UP)) {
        printf("Interface %s is down\n", interface);
        return -1;
    }
    
    return 0;
}

/* Get interface statistics */
static int get_interface_stats(const char *interface, struct test_stats *stats)
{
    FILE *fp;
    char line[256];
    char iface[IFNAMSIZ];
    unsigned long rx_packets, tx_packets, rx_bytes, tx_bytes;
    unsigned long rx_errors, tx_errors;
    
    fp = fopen("/proc/net/dev", "r");
    if (!fp) {
        perror("fopen /proc/net/dev");
        return -1;
    }
    
    /* Skip header lines */
    fgets(line, sizeof(line), fp);
    fgets(line, sizeof(line), fp);
    
    while (fgets(line, sizeof(line), fp)) {
        if (sscanf(line, "%s %lu %*u %lu %*u %*u %*u %*u %*u %lu %*u %lu",
                   iface, &rx_bytes, &rx_errors, &tx_bytes, &tx_errors) == 5) {
            
            /* Remove ':' from interface name */
            char *colon = strchr(iface, ':');
            if (colon)
                *colon = '\0';
            
            if (strcmp(iface, interface) == 0) {
                stats->bytes_received = rx_bytes;
                stats->bytes_sent = tx_bytes;
                stats->errors = rx_errors + tx_errors;
                fclose(fp);
                return 0;
            }
        }
    }
    
    fclose(fp);
    return -1;
}

/* Send test packets */
static int send_test_packets(struct test_config *config, struct test_stats *stats)
{
    int sockfd;
    struct sockaddr_in dest_addr;
    char *packet_data;
    int i;
    
    sockfd = socket(AF_INET, SOCK_DGRAM, 0);
    if (sockfd < 0) {
        perror("socket");
        return -1;
    }
    
    /* Bind to specific interface */
    struct ifreq ifr;
    strncpy(ifr.ifr_name, config->interface, IFNAMSIZ - 1);
    if (setsockopt(sockfd, SOL_SOCKET, SO_BINDTODEVICE, &ifr, sizeof(ifr)) < 0) {
        perror("setsockopt SO_BINDTODEVICE");
        close(sockfd);
        return -1;
    }
    
    /* Setup destination */
    memset(&dest_addr, 0, sizeof(dest_addr));
    dest_addr.sin_family = AF_INET;
    dest_addr.sin_port = htons(12345);
    dest_addr.sin_addr.s_addr = inet_addr("127.0.0.1");
    
    /* Allocate packet buffer */
    packet_data = malloc(config->packet_size);
    if (!packet_data) {
        perror("malloc");
        close(sockfd);
        return -1;
    }
    
    /* Fill with test pattern */
    for (i = 0; i < config->packet_size; i++) {
        packet_data[i] = i & 0xFF;
    }
    
    stats->start_time = get_time();
    
    /* Send packets */
    for (i = 0; i < config->packet_count && test_running; i++) {
        ssize_t sent = sendto(sockfd, packet_data, config->packet_size, 0,
                             (struct sockaddr *)&dest_addr, sizeof(dest_addr));
        
        if (sent < 0) {
            if (errno != EINTR) {
                perror("sendto");
                stats->errors++;
            }
        } else {
            stats->packets_sent++;
            stats->bytes_sent += sent;
        }
        
        if (config->verbose && (i % 1000 == 0)) {
            printf("Sent %d packets\r", i);
            fflush(stdout);
        }
        
        /* Small delay to avoid overwhelming */
        usleep(1000);
    }
    
    stats->end_time = get_time();
    
    free(packet_data);
    close(sockfd);
    
    return 0;
}

/* Receive test packets */
static int receive_test_packets(struct test_config *config, struct test_stats *stats)
{
    int sockfd;
    struct sockaddr_in bind_addr;
    char *packet_data;
    socklen_t addr_len;
    struct sockaddr_in from_addr;
    
    sockfd = socket(AF_INET, SOCK_DGRAM, 0);
    if (sockfd < 0) {
        perror("socket");
        return -1;
    }
    
    /* Bind to receive port */
    memset(&bind_addr, 0, sizeof(bind_addr));
    bind_addr.sin_family = AF_INET;
    bind_addr.sin_port = htons(12345);
    bind_addr.sin_addr.s_addr = INADDR_ANY;
    
    if (bind(sockfd, (struct sockaddr *)&bind_addr, sizeof(bind_addr)) < 0) {
        perror("bind");
        close(sockfd);
        return -1;
    }
    
    /* Set receive timeout */
    struct timeval timeout;
    timeout.tv_sec = 1;
    timeout.tv_usec = 0;
    if (setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout)) < 0) {
        perror("setsockopt SO_RCVTIMEO");
    }
    
    packet_data = malloc(MAX_PACKET_SIZE);
    if (!packet_data) {
        perror("malloc");
        close(sockfd);
        return -1;
    }
    
    stats->start_time = get_time();
    
    /* Receive packets */
    while (test_running) {
        addr_len = sizeof(from_addr);
        ssize_t received = recvfrom(sockfd, packet_data, MAX_PACKET_SIZE, 0,
                                   (struct sockaddr *)&from_addr, &addr_len);
        
        if (received < 0) {
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                continue; /* Timeout, check if we should continue */
            } else if (errno != EINTR) {
                perror("recvfrom");
                stats->errors++;
            }
        } else {
            stats->packets_received++;
            stats->bytes_received += received;
            
            if (config->verbose && (stats->packets_received % 1000 == 0)) {
                printf("Received %lu packets\r", stats->packets_received);
                fflush(stdout);
            }
        }
    }
    
    stats->end_time = get_time();
    
    free(packet_data);
    close(sockfd);
    
    return 0;
}

/* Thread function for packet sending */
static void* sender_thread(void *arg)
{
    struct test_config *config = (struct test_config *)arg;
    struct test_stats stats = {0};
    
    send_test_packets(config, &stats);
    
    printf("\nSender thread completed:\n");
    printf("  Packets sent: %lu\n", stats.packets_sent);
    printf("  Bytes sent: %lu\n", stats.bytes_sent);
    printf("  Errors: %lu\n", stats.errors);
    printf("  Duration: %.2f seconds\n", stats.end_time - stats.start_time);
    
    return NULL;
}

/* Thread function for packet receiving */
static void* receiver_thread(void *arg)
{
    struct test_config *config = (struct test_config *)arg;
    struct test_stats stats = {0};
    
    receive_test_packets(config, &stats);
    
    printf("\nReceiver thread completed:\n");
    printf("  Packets received: %lu\n", stats.packets_received);
    printf("  Bytes received: %lu\n", stats.bytes_received);
    printf("  Errors: %lu\n", stats.errors);
    printf("  Duration: %.2f seconds\n", stats.end_time - stats.start_time);
    
    return NULL;
}

/* Performance test */
static int run_performance_test(struct test_config *config)
{
    pthread_t sender_tid, receiver_tid;
    struct test_stats initial_stats = {0};
    struct test_stats final_stats = {0};
    double test_start, test_end;
    
    printf("Running performance test on interface %s\n", config->interface);
    printf("Packet size: %d bytes, Count: %d, Threads: %d\n",
           config->packet_size, config->packet_count, config->thread_count);
    
    /* Get initial interface statistics */
    get_interface_stats(config->interface, &initial_stats);
    
    test_start = get_time();
    
    /* Create sender and receiver threads */
    if (pthread_create(&receiver_tid, NULL, receiver_thread, config) != 0) {
        perror("pthread_create receiver");
        return -1;
    }
    
    sleep(1); /* Give receiver time to start */
    
    if (pthread_create(&sender_tid, NULL, sender_thread, config) != 0) {
        perror("pthread_create sender");
        pthread_cancel(receiver_tid);
        return -1;
    }
    
    /* Wait for threads to complete */
    pthread_join(sender_tid, NULL);
    pthread_join(receiver_tid, NULL);
    
    test_end = get_time();
    
    /* Get final interface statistics */
    get_interface_stats(config->interface, &final_stats);
    
    printf("\nPerformance Test Results:\n");
    printf("========================\n");
    printf("Total test duration: %.2f seconds\n", test_end - test_start);
    printf("Interface statistics delta:\n");
    printf("  TX bytes: %lu\n", final_stats.bytes_sent - initial_stats.bytes_sent);
    printf("  RX bytes: %lu\n", final_stats.bytes_received - initial_stats.bytes_received);
    printf("  Errors: %lu\n", final_stats.errors - initial_stats.errors);
    
    return 0;
}

/* Link status test */
static int test_link_status(const char *interface)
{
    int sockfd;
    struct ifreq ifr;
    struct ethtool_cmd ecmd;
    
    sockfd = socket(AF_INET, SOCK_DGRAM, 0);
    if (sockfd < 0) {
        perror("socket");
        return -1;
    }
    
    strncpy(ifr.ifr_name, interface, IFNAMSIZ - 1);
    ifr.ifr_name[IFNAMSIZ - 1] = '\0';
    
    ecmd.cmd = ETHTOOL_GSET;
    ifr.ifr_data = (char *)&ecmd;
    
    if (ioctl(sockfd, SIOCETHTOOL, &ifr) < 0) {
        perror("ioctl SIOCETHTOOL");
        close(sockfd);
        return -1;
    }
    
    close(sockfd);
    
    printf("Link status for %s:\n", interface);
    printf("  Speed: %d Mbps\n", ecmd.speed);
    printf("  Duplex: %s\n", ecmd.duplex == DUPLEX_FULL ? "Full" : "Half");
    printf("  Link: %s\n", ecmd.autoneg ? "Auto-negotiation" : "Fixed");
    
    return 0;
}

/* Interface discovery */
static int discover_adin2111_interfaces(char interfaces[][IFNAMSIZ], int max_count)
{
    FILE *fp;
    char line[256];
    char iface[IFNAMSIZ];
    int count = 0;
    
    fp = fopen("/proc/net/dev", "r");
    if (!fp) {
        perror("fopen /proc/net/dev");
        return -1;
    }
    
    /* Skip header lines */
    fgets(line, sizeof(line), fp);
    fgets(line, sizeof(line), fp);
    
    while (fgets(line, sizeof(line), fp) && count < max_count) {
        if (sscanf(line, "%s", iface) == 1) {
            /* Remove ':' from interface name */
            char *colon = strchr(iface, ':');
            if (colon)
                *colon = '\0';
            
            /* Check if this looks like an ADIN2111 interface */
            if (strncmp(iface, "eth", 3) == 0) {
                strncpy(interfaces[count], iface, IFNAMSIZ - 1);
                interfaces[count][IFNAMSIZ - 1] = '\0';
                count++;
            }
        }
    }
    
    fclose(fp);
    return count;
}

/* Usage */
static void usage(const char *prog)
{
    printf("Usage: %s [OPTIONS]\n", prog);
    printf("\nOptions:\n");
    printf("  -i INTERFACE    Network interface to test (default: auto-detect)\n");
    printf("  -s SIZE         Packet size in bytes (default: 1024)\n");
    printf("  -c COUNT        Number of packets to send (default: 10000)\n");
    printf("  -d DURATION     Test duration in seconds (default: 60)\n");
    printf("  -t THREADS      Number of threads (default: 1)\n");
    printf("  -v              Verbose output\n");
    printf("  -C              Continuous mode\n");
    printf("  -l              Test link status only\n");
    printf("  -D              Discover ADIN2111 interfaces\n");
    printf("  -h              Show this help\n");
    printf("\nExamples:\n");
    printf("  %s -i eth0 -s 1500 -c 5000    # Test eth0 with 1500 byte packets\n", prog);
    printf("  %s -D                         # Discover ADIN2111 interfaces\n", prog);
    printf("  %s -l -i eth0                 # Check link status of eth0\n", prog);
}

int main(int argc, char *argv[])
{
    struct test_config config = {
        .packet_size = 1024,
        .packet_count = 10000,
        .test_duration = DEFAULT_TEST_DURATION,
        .thread_count = 1,
        .verbose = false,
        .continuous = false
    };
    
    char interfaces[MAX_INTERFACES][IFNAMSIZ];
    int interface_count = 0;
    bool link_test_only = false;
    bool discover_only = false;
    int opt;
    
    printf("ADIN2111 Test Utility v%s\n", ADIN2111_TEST_VERSION);
    printf("Copyright (C) 2025 Analog Devices Inc.\n\n");
    
    /* Parse command line options */
    while ((opt = getopt(argc, argv, "i:s:c:d:t:vClDh")) != -1) {
        switch (opt) {
        case 'i':
            strncpy(config.interface, optarg, IFNAMSIZ - 1);
            config.interface[IFNAMSIZ - 1] = '\0';
            break;
        case 's':
            config.packet_size = atoi(optarg);
            if (config.packet_size <= 0 || config.packet_size > MAX_PACKET_SIZE) {
                fprintf(stderr, "Invalid packet size\n");
                return 1;
            }
            break;
        case 'c':
            config.packet_count = atoi(optarg);
            if (config.packet_count <= 0) {
                fprintf(stderr, "Invalid packet count\n");
                return 1;
            }
            break;
        case 'd':
            config.test_duration = atoi(optarg);
            if (config.test_duration <= 0) {
                fprintf(stderr, "Invalid test duration\n");
                return 1;
            }
            break;
        case 't':
            config.thread_count = atoi(optarg);
            if (config.thread_count <= 0 || config.thread_count > 10) {
                fprintf(stderr, "Invalid thread count\n");
                return 1;
            }
            break;
        case 'v':
            config.verbose = true;
            break;
        case 'C':
            config.continuous = true;
            break;
        case 'l':
            link_test_only = true;
            break;
        case 'D':
            discover_only = true;
            break;
        case 'h':
            usage(argv[0]);
            return 0;
        default:
            usage(argv[0]);
            return 1;
        }
    }
    
    /* Setup signal handlers */
    signal(SIGINT, signal_handler);
    signal(SIGTERM, signal_handler);
    
    /* Discover interfaces if requested */
    if (discover_only) {
        interface_count = discover_adin2111_interfaces(interfaces, MAX_INTERFACES);
        if (interface_count < 0) {
            fprintf(stderr, "Failed to discover interfaces\n");
            return 1;
        }
        
        printf("Discovered %d interface(s):\n", interface_count);
        for (int i = 0; i < interface_count; i++) {
            printf("  %s\n", interfaces[i]);
        }
        return 0;
    }
    
    /* Auto-detect interface if not specified */
    if (strlen(config.interface) == 0) {
        interface_count = discover_adin2111_interfaces(interfaces, MAX_INTERFACES);
        if (interface_count <= 0) {
            fprintf(stderr, "No ADIN2111 interfaces found. Please specify with -i\n");
            return 1;
        }
        strncpy(config.interface, interfaces[0], IFNAMSIZ - 1);
        printf("Auto-detected interface: %s\n", config.interface);
    }
    
    /* Check if interface exists and is up */
    if (check_interface(config.interface) < 0) {
        fprintf(stderr, "Interface %s is not available\n", config.interface);
        return 1;
    }
    
    /* Run link test only if requested */
    if (link_test_only) {
        return test_link_status(config.interface);
    }
    
    /* Run performance test */
    return run_performance_test(&config);
}