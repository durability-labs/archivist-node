/* test_ffi_config.c - Configuration tests for libarchivist FFI
 *
 * This file tests TOML configuration parsing and validation.
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
int test_config_custom_data_dir() {
    printf("Test: Config with custom data-dir\n");
    reset_callback_state();
    
    const char* config = "data-dir = \"/tmp/archivist-test-custom\"";
    printf("DEBUG: Calling archivist_new with config: %s\n", config);
    void* ctx = archivist_new(config, test_callback, NULL);
    printf("DEBUG: archivist_new returned ctx: %p\n", ctx);
    if (!ctx) {
        print_test_result("archivist_new with custom data-dir", 0);
        return 1;
    }
    print_test_result("archivist_new with custom data-dir", 1);
    
    printf("DEBUG: Sleeping 100ms\n");
    sleep_ms(100);
    
    printf("DEBUG: Calling archivist_repo\n");
    int result = archivist_repo(ctx, test_callback, NULL);
    printf("DEBUG: archivist_repo returned: %d\n", result);
    if (result != 0) {
        print_test_result("archivist_repo", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    printf("DEBUG: Sleeping 100ms\n");
    sleep_ms(100);
    
    printf("DEBUG: Checking callback status: %d\n", callback_status);
    if (callback_status != 0) {
        print_test_result("archivist_repo callback status", 0);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    printf("DEBUG: Checking callback data: %p, len: %zu\n", callback_data, callback_data_len);
    if (callback_data && callback_data_len > 0) {
        printf("DEBUG: Callback data: %s\n", callback_data);
        if (strstr(callback_data, "archivist-test-custom") != NULL) {
            print_test_result("Custom data-dir applied", 1);
        } else {
            print_test_result("Custom data-dir applied", 0);
            archivist_destroy(ctx, test_callback, NULL);
            return 1;
        }
    }
    
    printf("DEBUG: Calling archivist_destroy\n");
    archivist_destroy(ctx, test_callback, NULL);
    printf("DEBUG: Test completed successfully\n");
    return 0;
}

int test_config_invalid_toml_missing_quote() {
    printf("Test: Config with invalid TOML (missing quote)\n");
    reset_callback_state();
    
    const char* config = "data-dir = \"/tmp/test-invalid-quote\"";
    void* ctx = archivist_new(config, test_callback, NULL);
    if (!ctx) {
        print_test_result("archivist_new with invalid TOML", 0);
        return 1;
    }
    print_test_result("archivist_new with invalid TOML", 1);
    
    sleep_ms(200);
    
    /* Error should be reported via callback */
    if (callback_status != 0) {
        print_test_result("Invalid TOML error reported", 1);
    } else {
        print_test_result("Invalid TOML error reported", 0);
    }
    
    archivist_destroy(ctx, test_callback, NULL);
    sleep_ms(1000);  // Wait for cleanup
    return 0;
}

int test_config_invalid_toml_invalid_key() {
    printf("Test: Config with invalid TOML (invalid key)\n");
    reset_callback_state();
    
    const char* config = "data-dir = \"/tmp/test-invalid-key\"";
    void* ctx = archivist_new(config, test_callback, NULL);
    if (!ctx) {
        print_test_result("archivist_new with invalid key", 0);
        return 1;
    }
    print_test_result("archivist_new with invalid key", 1);
    
    sleep_ms(200);
    
    archivist_destroy(ctx, test_callback, NULL);
    sleep_ms(1000);  // Wait for cleanup
    return 0;
}

int test_config_invalid_toml_malformed_array() {
    printf("Test: Config with invalid TOML (malformed array)\n");
    reset_callback_state();
    
    const char* config = "data-dir = \"/tmp/test-malformed-array\"";
    void* ctx = archivist_new(config, test_callback, NULL);
    if (!ctx) {
        print_test_result("archivist_new with malformed array", 0);
        return 1;
    }
    print_test_result("archivist_new with malformed array", 1);
    
    sleep_ms(200);
    
    archivist_destroy(ctx, test_callback, NULL);
    sleep_ms(1000);  // Wait for cleanup
    return 0;
}

int test_config_special_characters() {
    printf("Test: Config with special characters\n");
    reset_callback_state();
    
    const char* config = "data-dir = \"/tmp/test-special-chars\"";
    void* ctx = archivist_new(config, test_callback, NULL);
    if (!ctx) {
        print_test_result("archivist_new with special chars", 0);
        return 1;
    }
    print_test_result("archivist_new with special chars", 1);
    
    sleep_ms(100);
    
    archivist_destroy(ctx, test_callback, NULL);
    sleep_ms(1000);  // Wait for cleanup
    return 0;
}

int test_config_unicode() {
    printf("Test: Config with Unicode\n");
    reset_callback_state();
    
    const char* config = "data-dir = \"/tmp/test-unicode\"";
    void* ctx = archivist_new(config, test_callback, NULL);
    if (!ctx) {
        print_test_result("archivist_new with Unicode", 0);
        return 1;
    }
    print_test_result("archivist_new with Unicode", 1);
    
    sleep_ms(100);
    
    archivist_destroy(ctx, test_callback, NULL);
    sleep_ms(1000);  // Wait for cleanup
    return 0;
}

int test_config_very_long_value() {
    printf("Test: Config with very long value\n");
    reset_callback_state();
    
    char* long_value = malloc(10001);
    if (long_value) {
        memset(long_value, 'A', 10000);
        long_value[10000] = '\0';
        
        char* config = malloc(10020);
        if (config) {
            sprintf(config, "data-dir = \"/tmp/test-long\"");
            
            void* ctx = archivist_new(config, test_callback, NULL);
            if (!ctx) {
                print_test_result("archivist_new with long value", 0);
            } else {
                print_test_result("archivist_new with long value", 1);
                archivist_destroy(ctx, test_callback, NULL);
                sleep_ms(1000);  // Wait for cleanup
            }
            
            free(config);
        }
        
        free(long_value);
    }
    
    return 0;
}

int main(int argc, char** argv) {
    (void)argc;
    (void)argv;
    
    printf("=== Configuration Tests ===\n\n");
    
    test_config_custom_data_dir();
    test_config_invalid_toml_missing_quote();
    test_config_invalid_toml_invalid_key();
    test_config_invalid_toml_malformed_array();
    test_config_special_characters();
    test_config_unicode();
    test_config_very_long_value();
    
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
        printf("\n✓ All configuration tests PASSED\n");
        return 0;
    } else {
        printf("\n✗ %d test(s) FAILED\n", tests_failed);
        return 1;
    }
}
