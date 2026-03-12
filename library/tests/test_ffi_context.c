/* test_ffi_context.c - Context lifecycle tests for libarchivist FFI
 *
 * This file tests context creation, destruction, and lifecycle management.
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
int test_create_context_basic() {
    printf("Test: Create and destroy context (basic)\n");
    reset_callback_state();
    
    void* ctx = archivist_new("", test_callback, (void*)0x1234);
    if (!ctx) {
        print_test_result("archivist_new", 0);
        return 1;
    }
    print_test_result("archivist_new", 1);
    
    sleep_ms(100);
    
    int result = archivist_destroy(ctx, test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_destroy", 0);
        return 1;
    }
    print_test_result("archivist_destroy", 1);
    
    return 0;
}

int test_create_context_null_config() {
    printf("Test: Create context with NULL config\n");
    reset_callback_state();
    
    void* ctx = archivist_new(NULL, test_callback, NULL);
    if (!ctx) {
        print_test_result("archivist_new with NULL config", 0);
        return 1;
    }
    print_test_result("archivist_new with NULL config", 1);
    
    sleep_ms(100);
    
    int result = archivist_destroy(ctx, test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_destroy", 0);
        return 1;
    }
    
    return 0;
}

int test_create_context_empty_config() {
    printf("Test: Create context with empty config\n");
    reset_callback_state();
    
    void* ctx = archivist_new("", test_callback, NULL);
    if (!ctx) {
        print_test_result("archivist_new with empty config", 0);
        return 1;
    }
    print_test_result("archivist_new with empty config", 1);
    
    sleep_ms(100);
    
    int result = archivist_destroy(ctx, test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_destroy", 0);
        return 1;
    }
    
    return 0;
}

int test_create_context_null_callback() {
    printf("Test: Create context with NULL callback\n");
    reset_callback_state();
    
    void* ctx = archivist_new("", NULL, NULL);
    /* Should return NULL due to NULL callback */
    if (ctx != NULL) {
        print_test_result("archivist_new with NULL callback", 0);
        return 1;
    }
    print_test_result("archivist_new with NULL callback", 1);
    
    return 0;
}

int test_multiple_contexts() {
    printf("Test: Create multiple contexts\n");
    reset_callback_state();
    
    void* contexts[10];
    int i;
    
    for (i = 0; i < 10; i++) {
        contexts[i] = archivist_new("", test_callback, (void*)(long)i);
        if (!contexts[i]) {
            print_test_result("archivist_new (multiple)", 0);
            return 1;
        }
    }
    print_test_result("archivist_new (multiple)", 1);
    
    sleep_ms(100);
    
    for (i = 0; i < 10; i++) {
        int result = archivist_destroy(contexts[i], test_callback, NULL);
        if (result != 0) {
            print_test_result("archivist_destroy (multiple)", 0);
            return 1;
        }
    }
    print_test_result("archivist_destroy (multiple)", 1);
    
    return 0;
}

int test_rapid_context_creation() {
    printf("Test: Rapid context creation/destruction\n");
    reset_callback_state();
    
    int i;
    for (i = 0; i < 50; i++) {
        void* ctx = archivist_new("", test_callback, NULL);
        if (!ctx) {
            print_test_result("archivist_new (rapid)", 0);
            return 1;
        }
        
        int result = archivist_destroy(ctx, test_callback, NULL);
        if (result != 0) {
            print_test_result("archivist_destroy (rapid)", 0);
            return 1;
        }
    }
    print_test_result("Rapid context creation/destruction", 1);
    
    return 0;
}

int main(int argc, char** argv) {
    (void)argc;
    (void)argv;
    
    printf("=== Context Lifecycle Tests ===\n\n");
    
    test_create_context_basic();
    test_create_context_null_config();
    test_create_context_empty_config();
    test_create_context_null_callback();
    test_multiple_contexts();
    test_rapid_context_creation();
    
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
        printf("\n✓ All context lifecycle tests PASSED\n");
        return 0;
    } else {
        printf("\n✗ %d test(s) FAILED\n", tests_failed);
        return 1;
    }
}
