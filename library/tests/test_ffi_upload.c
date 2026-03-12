/* test_ffi_upload.c - Upload operations tests for libarchivist FFI
 *
 * This file tests file upload operations.
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
int test_upload_init() {
    printf("Test: Upload initialization\n");
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
    
    result = archivist_upload_init(ctx, "/tmp/test-file.txt", 262144, test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_upload_init", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_upload_init", 1);
    
    sleep_ms(100);
    
    if (callback_status != 0) {
        print_test_result("archivist_upload_init callback status", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_upload_init callback status", 1);
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_upload_init_zero_chunk_size() {
    printf("Test: Upload initialization with zero chunk size\n");
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
    
    result = archivist_upload_init(ctx, "/tmp/test-file.txt", 0, test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_upload_init with zero chunk size", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_upload_init with zero chunk size", 1);
    
    sleep_ms(100);
    
    if (callback_status != 0) {
        print_test_result("archivist_upload_init callback status", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_upload_init callback status", 1);
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_upload_init_large_chunk_size() {
    printf("Test: Upload initialization with large chunk size\n");
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
    
    result = archivist_upload_init(ctx, "/tmp/test-file.txt", 1024 * 1024 * 1024, test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_upload_init with large chunk size", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_upload_init with large chunk size", 1);
    
    sleep_ms(100);
    
    if (callback_status != 0) {
        print_test_result("archivist_upload_init callback status", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_upload_init callback status", 1);
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_upload_cancel() {
    printf("Test: Upload cancellation\n");
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
    
    result = archivist_upload_cancel(ctx, "test-session-id", test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_upload_cancel", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_upload_cancel", 1);
    
    sleep_ms(100);
    
    if (callback_status != 0) {
        print_test_result("archivist_upload_cancel callback status", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_upload_cancel callback status", 1);
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_upload_finalize() {
    printf("Test: Upload finalization\n");
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
    
    result = archivist_upload_finalize(ctx, "test-session-id", test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_upload_finalize", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_upload_finalize", 1);
    
    sleep_ms(100);
    
    if (callback_status != 0) {
        print_test_result("archivist_upload_finalize callback status", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_upload_finalize callback status", 1);
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_upload_file() {
    printf("Test: Upload file\n");
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
    
    result = archivist_upload_file(ctx, "test-session-id", test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_upload_file", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_upload_file", 1);
    
    sleep_ms(100);
    
    if (callback_status != 0) {
        print_test_result("archivist_upload_file callback status", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_upload_file callback status", 1);
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int main(int argc, char** argv) {
    (void)argc;
    (void)argv;
    
    printf("=== Upload Operations Tests ===\n\n");
    
    test_upload_init();
    test_upload_init_zero_chunk_size();
    test_upload_init_large_chunk_size();
    test_upload_cancel();
    test_upload_finalize();
    test_upload_file();
    
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
        printf("\n✓ All upload operations tests PASSED\n");
        return 0;
    } else {
        printf("\n✗ %d test(s) FAILED\n", tests_failed);
        return 1;
    }
}
