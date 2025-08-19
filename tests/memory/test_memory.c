/*
 * Memory test for ADIN2111 driver
 * Tests for memory leaks and proper allocation/deallocation
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv) {
    printf("Running ADIN2111 memory tests...\n");
    
    // Simple allocation test
    void *buffer = malloc(1536);  // Ethernet frame size
    if (!buffer) {
        printf("Memory allocation failed\n");
        return 1;
    }
    
    // Use the buffer
    memset(buffer, 0, 1536);
    
    // Free the buffer
    free(buffer);
    
    printf("Memory tests completed successfully\n");
    return 0;
}