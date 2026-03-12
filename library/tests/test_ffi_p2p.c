/* test_ffi_p2p.c - P2P operations tests for libarchivist FFI
 *
 * This file tests P2P networking operations.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "libarchivist.h"

/* Test statistics */
static int tests_run = 0;
static int tests_passed = 0;
static int tests_failed = 0;

/* Callback state */
static int callback_status = 0;
static char* callback_data = NULL;
static size_t callback_data_len = 0;
static void* callback_user_data = NULL;

/* Port management */
static int test_port_counter = 18080;

/* Helper functions */
void reset_callback_state() {
    callback_status = 0;
    if (callback_data) {
        free(callback_data);
        callback_data = NULL;
    }
    callback_data_len = 0;
    callback_user_data = NULL;
}

void test_callback(int status, const char* data, size_t len, void* userData) {
    callback_status = status;
    callback_user_data = userData;
    
    if (data && len > 0) {
        if (callback_data) {
            free(callback_data);
        }
        callback_data = malloc(len + 1);
        if (callback_data) {
            memcpy(callback_data, data, len);
            callback_data[len] = '\0';
            callback_data_len = len;
        }
    } else {
        callback_data_len = 0;
    }
}

void print_test_result(const char* test_name, int passed) {
    tests_run++;
    if (passed) {
        tests_passed++;
        printf("  ✓ PASSED: %s\n", test_name);
    } else {
        tests_failed++;
        printf("  ✗ FAILED: %s\n", test_name);
    }
}

void sleep_ms(int milliseconds) {
    usleep(milliseconds * 1000);
}

/* Generate unique port configuration for each test */
char* generate_unique_config() {
    static char config[512];
    int port = test_port_counter++;
    snprintf(config, sizeof(config),
        "api-bindaddr = \"127.0.0.1\"\n"
        "api-port = %d\n"
        "repo-kind = \"fs\"\n"
        "data-dir = \"/tmp/archivist-test-%d\"\n"
        "log-level = \"INFO\"\n",
        port, port);
    return config;
}

/* Test functions */
int test_peer_id() {
    printf("Test: Get peer ID\n");
    reset_callback_state();

    char* config = generate_unique_config();
    void* ctx = archivist_new(config, test_callback, NULL);
    if (!ctx) {
        print_test_result("archivist_new", 0);
        return 1;
    }
    
    sleep_ms(100);
    
    int result = archivist_create(ctx, test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_create", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    sleep_ms(100);
    
    if (callback_status != 0) {
        print_test_result("archivist_create callback status", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    reset_callback_state();
    
    result = archivist_peer_id(ctx, test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_peer_id", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_peer_id", 1);
    
    sleep_ms(100);
    
    if (callback_status != 0) {
        print_test_result("archivist_peer_id callback status", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_peer_id callback status", 1);
    
    if (callback_data && callback_data_len > 0) {
        printf("  Peer ID: %s\n", callback_data);
        print_test_result("archivist_peer_id data", 1);
    } else {
        print_test_result("archivist_peer_id data", 0);
    }
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_connected_peers() {
    printf("Test: Get connected peers\n");
    reset_callback_state();

    char* config = generate_unique_config();
    void* ctx = archivist_new(config, test_callback, NULL);
    if (!ctx) {
        print_test_result("archivist_new", 0);
        return 1;
    }
    
    sleep_ms(100);
    
    int result = archivist_create(ctx, test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_create", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    sleep_ms(100);
    
    reset_callback_state();
    
    result = archivist_connected_peers(ctx, test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_connected_peers", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_connected_peers", 1);
    
    sleep_ms(100);
    
    if (callback_status != 0) {
        print_test_result("archivist_connected_peers callback status", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_connected_peers callback status", 1);
    
    if (callback_data && callback_data_len > 0) {
        printf("  Connected peers: %s\n", callback_data);
    } else {
        printf("  No connected peers (expected)\n");
    }
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_connected_peer_ids() {
    printf("Test: Get connected peer IDs\n");
    reset_callback_state();

    char* config = generate_unique_config();
    void* ctx = archivist_new(config, test_callback, NULL);
    if (!ctx) {
        print_test_result("archivist_new", 0);
        return 1;
    }
    
    sleep_ms(100);
    
    int result = archivist_create(ctx, test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_create", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    sleep_ms(100);
    
    reset_callback_state();
    
    result = archivist_connected_peer_ids(ctx, test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_connected_peer_ids", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_connected_peer_ids", 1);
    
    sleep_ms(100);
    
    if (callback_status != 0) {
        print_test_result("archivist_connected_peer_ids callback status", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_connected_peer_ids callback status", 1);
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_find_peer() {
    printf("Test: Find peer\n");
    reset_callback_state();

    char* config = generate_unique_config();
    void* ctx = archivist_new(config, test_callback, NULL);
    if (!ctx) {
        print_test_result("archivist_new", 0);
        return 1;
    }
    
    sleep_ms(100);
    
    int result = archivist_create(ctx, test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_create", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    sleep_ms(100);
    
    reset_callback_state();
    
    result = archivist_find_peer(ctx, "QmExamplePeerId", test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_find_peer", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_find_peer", 1);
    
    sleep_ms(100);
    
    if (callback_status != 0) {
        print_test_result("archivist_find_peer callback status", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_find_peer callback status", 1);
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_connect() {
    printf("Test: Connect to peer\n");
    reset_callback_state();

    char* config = generate_unique_config();
    void* ctx = archivist_new(config, test_callback, NULL);
    if (!ctx) {
        print_test_result("archivist_new", 0);
        return 1;
    }
    
    sleep_ms(100);
    
    int result = archivist_create(ctx, test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_create", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    sleep_ms(100);
    
    reset_callback_state();
    
    result = archivist_connect(ctx, "QmExamplePeerId", NULL, 0, test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_connect", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_connect", 1);
    
    sleep_ms(100);
    
    if (callback_status != 0) {
        print_test_result("archivist_connect callback status", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_connect callback status", 1);
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_disconnect() {
    printf("Test: Disconnect from peer\n");
    reset_callback_state();

    char* config = generate_unique_config();
    void* ctx = archivist_new(config, test_callback, NULL);
    if (!ctx) {
        print_test_result("archivist_new", 0);
        return 1;
    }
    
    sleep_ms(100);
    
    int result = archivist_create(ctx, test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_create", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    sleep_ms(100);
    
    reset_callback_state();
    
    result = archivist_disconnect(ctx, "QmExamplePeerId", test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_disconnect", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_disconnect", 1);
    
    sleep_ms(100);
    
    if (callback_status != 0) {
        print_test_result("archivist_disconnect callback status", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_disconnect callback status", 1);
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int main(int argc, char** argv) {
    (void)argc;
    (void)argv;
    
    printf("=== P2P Operations Tests ===\n\n");
    
    test_peer_id();
    test_connected_peers();
    test_connected_peer_ids();
    test_find_peer();
    test_connect();
    test_disconnect();
    
    /* Cleanup */
    if (callback_data) {
        free(callback_data);
    }
    
    /* Print Summary */
    printf("\n=== Test Summary ===\n");
    printf("Total tests run: %d\n", tests_run);
    printf("Tests passed: %d\n", tests_passed);
    printf("Tests failed: %d\n", tests_failed);
    printf("Success rate: %.1f%%\n", (tests_passed * 100.0) / tests_run);
    
    if (tests_failed == 0) {
        printf("\n✓ All P2P operations tests PASSED\n");
        return 0;
    } else {
        printf("\n✗ %d test(s) FAILED\n", tests_failed);
        return 1;
    }
}
