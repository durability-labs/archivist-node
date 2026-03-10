/* test_ffi_version.c - Version information tests for libarchivist FFI
 *
 * This file tests version, revision, and SPR retrieval.
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
int test_version() {
    printf("Test: Get version\n");
    reset_callback_state();

    char* config = generate_unique_config();
    void* ctx = archivist_new(config, test_callback, NULL);
    if (!ctx) {
        print_test_result("archivist_new", 0);
        return 1;
    }
    
    sleep_ms(100);
    
    int result = archivist_version(ctx, test_callback, (void*)0x5678);
    if (result != 0) {
        print_test_result("archivist_version", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_version", 1);
    
    sleep_ms(100);
    
    if (callback_status != 0) {
        print_test_result("archivist_version callback status", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_version callback status", 1);
    
    if (callback_data && callback_data_len > 0) {
        printf("  Version: %s\n", callback_data);
        print_test_result("archivist_version data", 1);
    } else {
        print_test_result("archivist_version data", 0);
    }
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_revision() {
    printf("Test: Get revision\n");
    reset_callback_state();

    char* config = generate_unique_config();
    void* ctx = archivist_new(config, test_callback, NULL);
    if (!ctx) {
        print_test_result("archivist_new", 0);
        return 1;
    }
    
    sleep_ms(100);
    
    int result = archivist_revision(ctx, test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_revision", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_revision", 1);
    
    sleep_ms(100);
    
    if (callback_status != 0) {
        print_test_result("archivist_revision callback status", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_revision callback status", 1);
    
    if (callback_data && callback_data_len > 0) {
        printf("  Revision: %s\n", callback_data);
        print_test_result("archivist_revision data", 1);
    } else {
        print_test_result("archivist_revision data", 0);
    }
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_spr() {
    printf("Test: Get SPR\n");
    reset_callback_state();

    char* config = generate_unique_config();
    void* ctx = archivist_new(config, test_callback, NULL);
    if (!ctx) {
        print_test_result("archivist_new", 0);
        return 1;
    }
    
    sleep_ms(100);
    
    int result = archivist_spr(ctx, test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_spr", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_spr", 1);
    
    sleep_ms(100);
    
    if (callback_status != 0) {
        print_test_result("archivist_spr callback status", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_spr callback status", 1);
    
    if (callback_data && callback_data_len > 0) {
        printf("  SPR: %s\n", callback_data);
        print_test_result("archivist_spr data", 1);
    } else {
        print_test_result("archivist_spr data", 0);
    }
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_repo() {
    printf("Test: Get repo path\n");
    reset_callback_state();

    char* config = generate_unique_config();
    void* ctx = archivist_new(config, test_callback, NULL);
    if (!ctx) {
        print_test_result("archivist_new", 0);
        return 1;
    }
    
    sleep_ms(100);
    
    int result = archivist_repo(ctx, test_callback, NULL);
    if (result != 0) {
        print_test_result("archivist_repo", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_repo", 1);
    
    sleep_ms(100);
    
    if (callback_status != 0) {
        print_test_result("archivist_repo callback status", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    print_test_result("archivist_repo callback status", 1);
    
    if (callback_data && callback_data_len > 0) {
        printf("  Repo: %s\n", callback_data);
        print_test_result("archivist_repo data", 1);
    } else {
        print_test_result("archivist_repo data", 0);
    }
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_multiple_version_queries() {
    printf("Test: Multiple version queries\n");
    reset_callback_state();

    char* config = generate_unique_config();
    void* ctx = archivist_new(config, test_callback, NULL);
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
    print_test_result("Multiple version queries", 1);
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int main(int argc, char** argv) {
    (void)argc;
    (void)argv;
    
    printf("=== Version Information Tests ===\n\n");
    
    test_version();
    test_revision();
    test_spr();
    test_repo();
    test_multiple_version_queries();
    
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
        printf("\n✓ All version information tests PASSED\n");
        return 0;
    } else {
        printf("\n✗ %d test(s) FAILED\n", tests_failed);
        return 1;
    }
}
