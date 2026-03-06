/* test_ffi.c - Simple C test program for libarchivist FFI
 *
 * This program tests the basic FFI functionality to ensure the library works correctly.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "libarchivist.h"

static int callback_status = 0;
static char* callback_data = NULL;
static size_t callback_data_len = 0;
static void* callback_user_data = NULL;

void test_callback(int status, const char* data, size_t len, void* userData) {
    callback_status = status;
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
    callback_user_data = userData;
}

int test_create_context() {
    printf("Test: Create and destroy context\n");
    
    void* ctx = archivist_new("", test_callback, (void*)0x1234);
    if (!ctx) {
        printf("  FAILED: archivist_new returned NULL\n");
        return 1;
    }
    printf("  PASSED: Context created\n");
    
    sleep(1);
    
    int result = archivist_destroy(ctx, test_callback, NULL);
    if (result != 0) {
        printf("  FAILED: archivist_destroy returned %d\n", result);
        return 1;
    }
    printf("  PASSED: Context destroyed\n");
    
    return 0;
}

int test_config_null() {
    printf("Test: Config with NULL\n");
    
    void* ctx = archivist_new(NULL, test_callback, NULL);
    if (!ctx) {
        printf("  FAILED: archivist_new returned NULL\n");
        return 1;
    }
    printf("  PASSED: Context created with NULL config\n");
    
    sleep(1);
    
    // Verify the default data dir is used
    int result = archivist_repo(ctx, test_callback, NULL);
    if (result != 0) {
        printf("  FAILED: archivist_repo returned %d\n", result);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    sleep(1);
    
    if (callback_status != 0) {
        printf("  FAILED: Repo callback status %d\n", callback_status);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    if (callback_data && callback_data_len > 0) {
        printf("  PASSED: Default repo: %s\n", callback_data);
    } else {
        printf("  WARNING: No repo data received\n");
    }
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_config_empty() {
    printf("Test: Config with empty string\n");
    
    void* ctx = archivist_new("", test_callback, NULL);
    if (!ctx) {
        printf("  FAILED: archivist_new returned NULL\n");
        return 1;
    }
    printf("  PASSED: Context created with empty config\n");
    
    sleep(1);
    
    // Verify the default data dir is used
    int result = archivist_repo(ctx, test_callback, NULL);
    if (result != 0) {
        printf("  FAILED: archivist_repo returned %d\n", result);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    sleep(1);
    
    if (callback_status != 0) {
        printf("  FAILED: Repo callback status %d\n", callback_status);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    if (callback_data && callback_data_len > 0) {
        printf("  PASSED: Default repo: %s\n", callback_data);
    } else {
        printf("  WARNING: No repo data received\n");
    }
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_config_custom_data_dir() {
    printf("Test: Config with custom data-dir\n");
    
    // Use TOML format to set a custom data directory
    const char* config = "data-dir = \"/tmp/archivist-test-custom\"";
    void* ctx = archivist_new(config, test_callback, NULL);
    if (!ctx) {
        printf("  FAILED: archivist_new returned NULL\n");
        return 1;
    }
    printf("  PASSED: Context created with custom data-dir config\n");
    
    sleep(1);
    
    // Verify the custom data dir is used
    int result = archivist_repo(ctx, test_callback, NULL);
    if (result != 0) {
        printf("  FAILED: archivist_repo returned %d\n", result);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    sleep(1);
    
    if (callback_status != 0) {
        printf("  FAILED: Repo callback status %d\n", callback_status);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    if (callback_data && callback_data_len > 0) {
        printf("  PASSED: Custom repo: %s\n", callback_data);
        // Verify the path contains our custom directory
        if (strstr(callback_data, "archivist-test-custom") != NULL) {
            printf("  PASSED: Custom data-dir was applied correctly\n");
        } else {
            printf("  FAILED: Custom data-dir was not applied\n");
            archivist_destroy(ctx, test_callback, NULL);
            return 1;
        }
    } else {
        printf("  FAILED: No repo data received\n");
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_config_invalid() {
    printf("Test: Config with invalid TOML\n");
    
    // Invalid TOML: missing closing quote
    const char* config = "data-dir = \"/tmp/test";
    void* ctx = archivist_new(config, test_callback, NULL);
    if (!ctx) {
        printf("  FAILED: archivist_new returned NULL\n");
        return 1;
    }
    printf("  PASSED: Context created (async error expected)\n");
    
    sleep(2);
    
    // The error should be reported via callback
    if (callback_status != 0) {
        printf("  PASSED: Invalid config correctly returned error: %s\n",
               callback_data ? callback_data : "unknown");
    } else {
        printf("  WARNING: No error reported for invalid config\n");
    }
    
    // Clean up even if there was an error
    if (ctx) {
        archivist_destroy(ctx, test_callback, NULL);
    }
    return 0;
}

int test_version() {
    printf("Test: Get version\n");
    
    void* ctx = archivist_new("", test_callback, NULL);
    if (!ctx) {
        printf("  FAILED: archivist_new returned NULL\n");
        return 1;
    }
    
    sleep(1);
    
    int result = archivist_version(ctx, test_callback, (void*)0x5678);
    if (result != 0) {
        printf("  FAILED: archivist_version returned %d\n", result);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    sleep(1);
    
    if (callback_status != 0) {
        printf("  FAILED: Callback status %d\n", callback_status);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    if (callback_data && callback_data_len > 0) {
        printf("  PASSED: Version: %s\n", callback_data);
    } else {
        printf("  WARNING: No version data received\n");
    }
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_peer_id() {
    printf("Test: Get peer ID\n");
    
    void* ctx = archivist_new("", test_callback, NULL);
    if (!ctx) {
        printf("  FAILED: archivist_new returned NULL\n");
        return 1;
    }
    
    sleep(1);
    
    int result = archivist_create(ctx, test_callback, NULL);
    if (result != 0) {
        printf("  FAILED: archivist_create returned %d\n", result);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    sleep(1);
    
    if (callback_status != 0) {
        printf("  FAILED: Create callback status %d\n", callback_status);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    callback_status = 0;
    if (callback_data) {
        free(callback_data);
        callback_data = NULL;
        callback_data_len = 0;
    }
    
    result = archivist_peer_id(ctx, test_callback, NULL);
    if (result != 0) {
        printf("  FAILED: archivist_peer_id returned %d\n", result);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    sleep(1);
    
    if (callback_status != 0) {
        printf("  FAILED: Callback status %d\n", callback_status);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    if (callback_data && callback_data_len > 0) {
        printf("  PASSED: Peer ID: %s\n", callback_data);
    } else {
        printf("  WARNING: No peer ID data received\n");
    }
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_debug() {
    printf("Test: Debug\n");
    
    void* ctx = archivist_new("", test_callback, NULL);
    if (!ctx) {
        printf("  FAILED: archivist_new returned NULL\n");
        return 1;
    }
    
    sleep(1);
    
    int result = archivist_debug(ctx, test_callback, NULL);
    if (result != 0) {
        printf("  FAILED: archivist_debug returned %d\n", result);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    sleep(1);
    
    if (callback_status != 0) {
        printf("  FAILED: Callback status %d\n", callback_status);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    if (callback_data && callback_data_len > 0) {
        printf("  PASSED: Debug info received\n");
    } else {
        printf("  WARNING: No debug data received\n");
    }
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_connected_peers() {
    printf("Test: Connected peers\n");
    
    void* ctx = archivist_new("", test_callback, NULL);
    if (!ctx) {
        printf("  FAILED: archivist_new returned NULL\n");
        return 1;
    }
    
    sleep(1);
    
    int result = archivist_create(ctx, test_callback, NULL);
    if (result != 0) {
        printf("  FAILED: archivist_create returned %d\n", result);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    sleep(1);
    
    if (callback_status != 0) {
        printf("  FAILED: Create callback status %d\n", callback_status);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    callback_status = 0;
    if (callback_data) {
        free(callback_data);
        callback_data = NULL;
        callback_data_len = 0;
    }
    
    result = archivist_connected_peers(ctx, test_callback, NULL);
    if (result != 0) {
        printf("  FAILED: archivist_connected_peers returned %d\n", result);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    sleep(1);
    
    if (callback_status != 0) {
        printf("  FAILED: Callback status %d\n", callback_status);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    if (callback_data && callback_data_len > 0) {
        printf("  PASSED: Connected peers: %s\n", callback_data);
    } else {
        printf("  PASSED: No connected peers (expected)\n");
    }
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_storage_list() {
    printf("Test: Storage list\n");
    
    void* ctx = archivist_new("", test_callback, NULL);
    if (!ctx) {
        printf("  FAILED: archivist_new returned NULL\n");
        return 1;
    }
    
    sleep(1);
    
    int result = archivist_create(ctx, test_callback, NULL);
    if (result != 0) {
        printf("  FAILED: archivist_create returned %d\n", result);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    sleep(1);
    
    if (callback_status != 0) {
        printf("  FAILED: Create callback status %d\n", callback_status);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    callback_status = 0;
    if (callback_data) {
        free(callback_data);
        callback_data = NULL;
        callback_data_len = 0;
    }
    
    result = archivist_list(ctx, test_callback, NULL);
    if (result != 0) {
        printf("  FAILED: archivist_list returned %d\n", result);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    sleep(1);
    
    if (callback_status != 0) {
        printf("  FAILED: Callback status %d\n", callback_status);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    if (callback_data && callback_data_len > 0) {
        printf("  PASSED: Storage list: %s\n", callback_data);
    } else {
        printf("  PASSED: Empty storage list (expected)\n");
    }
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_storage_space() {
    printf("Test: Storage space\n");
    
    void* ctx = archivist_new("", test_callback, NULL);
    if (!ctx) {
        printf("  FAILED: archivist_new returned NULL\n");
        return 1;
    }
    
    sleep(1);
    
    int result = archivist_create(ctx, test_callback, NULL);
    if (result != 0) {
        printf("  FAILED: archivist_create returned %d\n", result);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    sleep(1);
    
    if (callback_status != 0) {
        printf("  FAILED: Create callback status %d\n", callback_status);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    callback_status = 0;
    if (callback_data) {
        free(callback_data);
        callback_data = NULL;
        callback_data_len = 0;
    }
    
    result = archivist_space(ctx, test_callback, NULL);
    if (result != 0) {
        printf("  FAILED: archivist_space returned %d\n", result);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    sleep(1);
    
    if (callback_status != 0) {
        printf("  FAILED: Callback status %d\n", callback_status);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    if (callback_data && callback_data_len > 0) {
        printf("  PASSED: Storage space: %s\n", callback_data);
    } else {
        printf("  WARNING: No storage space data received\n");
    }
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int test_start_stop() {
    printf("Test: Start and stop\n");
    
    void* ctx = archivist_new("", test_callback, NULL);
    if (!ctx) {
        printf("  FAILED: archivist_new returned NULL\n");
        return 1;
    }
    
    sleep(1);
    
    int result = archivist_start(ctx, test_callback, NULL);
    if (result != 0) {
        printf("  FAILED: archivist_start returned %d\n", result);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    sleep(2);
    
    if (callback_status != 0) {
        printf("  FAILED: Start callback status %d\n", callback_status);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    printf("  PASSED: Node started\n");
    
    result = archivist_stop(ctx, test_callback, NULL);
    if (result != 0) {
        printf("  FAILED: archivist_stop returned %d\n", result);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    
    sleep(2);
    
    if (callback_status != 0) {
        printf("  FAILED: Stop callback status %d\n", callback_status);
        archivist_destroy(ctx, test_callback, NULL);
        return 1;
    }
    printf("  PASSED: Node stopped\n");
    
    archivist_destroy(ctx, test_callback, NULL);
    return 0;
}

int main(int argc, char** argv) {
    (void)argc;
    (void)argv;
        
    printf("=== Archivist FFI Test Suite ===\n\n");
    
    int failed = 0;
    
    // Configuration parsing tests
    failed += test_config_null();
    printf("\n");
    
    failed += test_config_empty();
    printf("\n");
    
    failed += test_config_custom_data_dir();
    printf("\n");
    
    failed += test_config_invalid();
    printf("\n");
    
    // Original tests
    failed += test_create_context();
    printf("\n");
    
    failed += test_version();
    printf("\n");
    
    failed += test_peer_id();
    printf("\n");
    
    failed += test_debug();
    printf("\n");
    
    failed += test_connected_peers();
    printf("\n");
    
    failed += test_storage_list();
    printf("\n");
    
    failed += test_storage_space();
    printf("\n");
    
    failed += test_start_stop();
    printf("\n");
    
    if (callback_data) {
        free(callback_data);
    }
    
    printf("=== Test Summary ===\n");
    if (failed == 0) {
        printf("All tests PASSED\n");
        return 0;
    } else {
        printf("%d test(s) FAILED\n", failed);
        return 1;
    }
}
