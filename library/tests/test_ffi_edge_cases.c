/* test_ffi_edge_cases.c - Edge case tests for libarchivist FFI
 *
 * This file tests edge cases, boundary conditions, and error scenarios.
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

/* Test functions */
int test_null_context() {
    printf("Test: NULL context handling\n");
    reset_callback_state();
    
    int result = archivist_version(NULL, test_callback, NULL);
    if (result == 0) {
        print_test_result("archivist_version with NULL context", 0);
        return 1;
    }
    print_test_result("archivist_version with NULL context", 1);
    
    return 0;
}

int test_null_callback() {
    printf("Test: NULL callback handling\n");
    reset_callback_state();
    
    void* ctx = archivist_new("", test_callback, NULL);
    if (!ctx) {
        print_test_result("archivist_new", 0);
        return 1;
    }
    
    sleep_ms(100);
    
    int result = archivist_create(ctx, NULL, NULL);
    if (result == 0) {
        print_test_result("archivist_create with NULL callback", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_create with NULL callback", 1);
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_empty_strings() {
    printf("Test: Empty string handling\n");
    reset_callback_state();
    
    void* ctx = archivist_new("", test_callback, NULL);
    if (!ctx) {
        print_test_result("archivist_new", 0);
        return 1;
    }
    
    sleep_ms(100);
    
    int result = archivist_log_level(ctx, "", test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_log_level with empty string", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_log_level with empty string", 1);
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_invalid_peer_id() {
    printf("Test: Invalid peer ID handling\n");
    reset_callback_state();
    
    void* ctx = archivist_new("", test_callback, NULL);
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
    
    result = archivist_find_peer(ctx, "invalid-peer-id", test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_find_peer with invalid peer ID", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_find_peer with invalid peer ID", 1);
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_invalid_cid() {
    printf("Test: Invalid CID handling\n");
    reset_callback_state();
    
    void* ctx = archivist_new("", test_callback, NULL);
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
    
    result = archivist_download_init(ctx, "invalid-cid", 262144, 0, test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_download_init with invalid CID", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_download_init with invalid CID", 1);
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_set_event_callback() {
    printf("Test: Set event callback\n");
    reset_callback_state();
    
    void* ctx = archivist_new("", test_callback, NULL);
    if (!ctx) {
        print_test_result("archivist_new", 0);
        return 1;
    }
    
    sleep_ms(100);
    
    archivist_set_event_callback(ctx, test_callback, (void*)0xABCD);
    print_test_result("archivist_set_event_callback", 1);
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_debug() {
    printf("Test: Get debug info\n");
    reset_callback_state();
    
    void* ctx = archivist_new("", test_callback, NULL);
    if (!ctx) {
        print_test_result("archivist_new", 0);
        return 1;
    }
    
    sleep_ms(100);
    
    int result = archivist_debug(ctx, test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_debug", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_debug", 1);
    
    sleep_ms(100);
    
    if (callback_status != 0) {
        print_test_result("archivist_debug callback status", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_debug callback status", 1);
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_log_level() {
    printf("Test: Set log level\n");
    reset_callback_state();
    
    void* ctx = archivist_new("", test_callback, NULL);
    if (!ctx) {
        print_test_result("archivist_new", 0);
        return 1;
    }
    
    sleep_ms(100);
    
    int result = archivist_log_level(ctx, "DEBUG", test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_log_level", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_log_level", 1);
    
    sleep_ms(100);
    
    if (callback_status != 0) {
        print_test_result("archivist_log_level callback status", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_log_level callback status", 1);
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_multiple_operations() {
    printf("Test: Multiple operations in sequence\n");
    reset_callback_state();
    
    void* ctx = archivist_new("", test_callback, NULL);
    if (!ctx) {
        print_test_result("archivist_new", 0);
        return 1;
    }
    
    sleep_ms(100);
    
    int i;
    for (i = 0; i < 10; i++) {
        reset_callback_state();
        
        int result = archivist_version(ctx, test_callback, NULL);
        if (result != 0) {
            print_test_result("archivist_version (multiple)", 0);
            archivist_destroy(ctx, test_callback, NULL);
            return 1;
        }
        
        sleep_ms(50);
        
        if (callback_status != 0) {
            print_test_result("archivist_version callback status (multiple)", 0);
            archivist_destroy(ctx, test_callback, NULL);
            return 1;
        }
    }
    print_test_result("Multiple operations in sequence", 1);
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int main(int argc, char** argv) {
    (void)argc;
    (void)argv;
    
    printf("=== Edge Case Tests ===\n\n");
    
    test_null_context();
    test_null_callback();
    test_empty_strings();
    test_invalid_peer_id();
    test_invalid_cid();
    test_set_event_callback();
    test_debug();
    test_log_level();
    test_multiple_operations();
    
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
        printf("\n✓ All edge case tests PASSED\n");
        return 0;
    } else {
        printf("\n✗ %d test(s) FAILED\n", tests_failed);
        return 1;
    }
}
