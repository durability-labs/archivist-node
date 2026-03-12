/* test_ffi_storage.c - Storage operations tests for libarchivist FFI
 *
 * This file tests storage management operations.
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
int test_storage_list() {
    printf("Test: Get storage list\n");
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
    
    result = archivist_list(ctx, test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_list", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_list", 1);
    
    sleep_ms(100);
    
    if (callback_status != 0) {
        print_test_result("archivist_list callback status", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_list callback status", 1);
    
    if (callback_data && callback_data_len > 0) {
        printf("  Storage list: %s\n", callback_data);
    } else {
        printf("  Empty storage list (expected)\n");
    }
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_storage_space() {
    printf("Test: Get storage space\n");
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
    
    result = archivist_space(ctx, test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_space", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_space", 1);
    
    sleep_ms(100);
    
    if (callback_status != 0) {
        print_test_result("archivist_space callback status", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_space callback status", 1);
    
    if (callback_data && callback_data_len > 0) {
        printf("  Storage space: %s\n", callback_data);
    }
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_storage_exists() {
    printf("Test: Check if CID exists\n");
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
    
    result = archivist_exists(ctx, "QmExampleCidThatDoesNotExist", test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_exists", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_exists", 1);
    
    sleep_ms(100);
    
    if (callback_status != 0) {
        print_test_result("archivist_exists callback status", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_exists callback status", 1);
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_storage_delete() {
    printf("Test: Delete CID\n");
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
    
    result = archivist_delete(ctx, "QmExampleCid", test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_delete", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_delete", 1);
    
    sleep_ms(100);
    
    if (callback_status != 0) {
        print_test_result("archivist_delete callback status", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_delete callback status", 1);
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_storage_fetch() {
    printf("Test: Fetch CID\n");
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
    
    result = archivist_fetch(ctx, "QmExampleCid", test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_fetch", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_fetch", 1);
    
    sleep_ms(100);
    
    if (callback_status != 0) {
        print_test_result("archivist_fetch callback status", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_fetch callback status", 1);
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_storage_local_size() {
    printf("Test: Get local size\n");
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
    
    result = archivist_local_size(ctx, test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_local_size", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_local_size", 1);
    
    sleep_ms(100);
    
    if (callback_status != 0) {
        print_test_result("archivist_local_size callback status", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_local_size callback status", 1);
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_storage_block_count() {
    printf("Test: Get block count\n");
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
    
    result = archivist_block_count(ctx, test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_block_count", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_block_count", 1);
    
    sleep_ms(100);
    
    if (callback_status != 0) {
        print_test_result("archivist_block_count callback status", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_block_count callback status", 1);
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int main(int argc, char** argv) {
    (void)argc;
    (void)argv;
    
    printf("=== Storage Operations Tests ===\n\n");
    
    test_storage_list();
    test_storage_space();
    test_storage_exists();
    test_storage_delete();
    test_storage_fetch();
    test_storage_local_size();
    test_storage_block_count();
    
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
        printf("\n✓ All storage operations tests PASSED\n");
        return 0;
    } else {
        printf("\n✗ %d test(s) FAILED\n", tests_failed);
        return 1;
    }
}
