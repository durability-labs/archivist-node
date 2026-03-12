/* test_ffi_download.c - Download operations tests for libarchivist FFI
 *
 * This file tests file download operations.
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
int test_download_init() {
    printf("Test: Download initialization\n");
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
    
    result = archivist_download_init(ctx, "QmExampleCid", 262144, 0, test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_download_init", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_download_init", 1);
    
    sleep_ms(100);
    
    if (callback_status != 0) {
        print_test_result("archivist_download_init callback status", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_download_init callback status", 1);
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_download_init_local() {
    printf("Test: Download initialization (local)\n");
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
    
    result = archivist_download_init(ctx, "QmExampleCid", 262144, 1, test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_download_init (local)", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_download_init (local)", 1);
    
    sleep_ms(100);
    
    if (callback_status != 0) {
        print_test_result("archivist_download_init callback status", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_download_init callback status", 1);
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_download_stream() {
    printf("Test: Download stream\n");
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
    
    result = archivist_download_stream(ctx, "QmExampleCid", 262144, 0, "/tmp/downloaded-file.txt", test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_download_stream", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_download_stream", 1);
    
    sleep_ms(100);
    
    if (callback_status != 0) {
        print_test_result("archivist_download_stream callback status", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_download_stream callback status", 1);
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_download_stream_null_filepath() {
    printf("Test: Download stream with NULL filepath\n");
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
    
    result = archivist_download_stream(ctx, "QmExampleCid", 262144, 0, NULL, test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_download_stream with NULL filepath", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_download_stream with NULL filepath", 1);
    
    sleep_ms(100);
    
    if (callback_status != 0) {
        print_test_result("archivist_download_stream callback status", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_download_stream callback status", 1);
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_download_cancel() {
    printf("Test: Download cancellation\n");
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
    
    result = archivist_download_cancel(ctx, "QmExampleCid", test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_download_cancel", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_download_cancel", 1);
    
    sleep_ms(100);
    
    if (callback_status != 0) {
        print_test_result("archivist_download_cancel callback status", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_download_cancel callback status", 1);
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_download_manifest() {
    printf("Test: Download manifest\n");
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
    
    result = archivist_download_manifest(ctx, "QmExampleCid", test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_download_manifest", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_download_manifest", 1);
    
    sleep_ms(100);
    
    if (callback_status != 0) {
        print_test_result("archivist_download_manifest callback status", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_download_manifest callback status", 1);
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int main(int argc, char** argv) {
    (void)argc;
    (void)argv;
    
    printf("=== Download Operations Tests ===\n\n");
    
    test_download_init();
    test_download_init_local();
    test_download_stream();
    test_download_stream_null_filepath();
    test_download_cancel();
    test_download_manifest();
    
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
        printf("\n✓ All download operations tests PASSED\n");
        return 0;
    } else {
        printf("\n✗ %d test(s) FAILED\n", tests_failed);
        return 1;
    }
}
