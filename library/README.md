# libarchivist

C FFI (Foreign Function Interface) for the Archivist distributed storage system.

## Overview

libarchivist provides a C API for interacting with Archivist nodes. All functions are asynchronous and execute on a separate thread, returning results via callbacks.

## Building

### Prerequisites

- Nim compiler
- gcc
- pthread library

### Build Commands

```bash
# Build library and tests
make

# Build only the library
make build/lib/libarchivist.so

# Clean build artifacts
make clean

# Install to /usr/local (requires sudo)
make install

# Uninstall from /usr/local (requires sudo)
make uninstall
```

## Known Issues

**Test Suite Status:** The test suite currently has runtime issues. Tests fail with SIGSEGV or hang indefinitely. This is a known issue being investigated. The build commands work correctly.

## Usage

### Basic Example

```c
#include "libarchivist.h"

void callback(int callerRet, const char *msg, size_t len, void *userData) {
    if (callerRet == RET_OK) {
        printf("Success: %.*s\n", (int)len, msg);
    } else if (callerRet == RET_ERR) {
        printf("Error: %.*s\n", (int)len, msg);
    }
}

int main() {
    // Create context
    void *ctx = archivist_new(NULL, callback, NULL);
    
    // Create and start node
    archivist_create(ctx, callback, NULL);
    archivist_start(ctx, callback, NULL);
    
    // ... perform operations ...
    
    // Stop and cleanup
    archivist_stop(ctx, callback, NULL);
    archivist_destroy(ctx, callback, NULL);
    
    return 0;
}
```

### Return Codes

- `RET_OK` (0) - Operation succeeded
- `RET_ERR` (1) - Operation failed
- `RET_MISSING_CALLBACK` (2) - Callback not provided
- `RET_PROGRESS` (3) - Progress update (for upload/download)

### Key Functions

- `archivist_new()` - Create a new Archivist context
- `archivist_create()` - Initialize the node
- `archivist_start()` - Start the node
- `archivist_stop()` - Stop the node
- `archivist_destroy()` - Destroy the context
- `archivist_upload()` - Upload data to storage
- `archivist_download()` - Download data from storage
- `archivist_get_version()` - Get library version info

## Testing

> **⚠️ Note:** Test commands below currently do not work properly. See [Known Issues](#known-issues) for details.

```bash
# Run all FFI tests
make test

# Run specific test suites
make test-context      # Context lifecycle tests
make test-config       # Configuration tests
make test-version      # Version information tests
make test-p2p          # P2P operations tests
make test-storage      # Storage operations tests
make test-upload       # Upload operations tests
make test-download     # Download operations tests
make test-edge-cases   # Edge case tests
```

## API Reference

See [`libarchivist.h`](libarchivist.h) for complete API documentation.

## Configuration

The library accepts TOML configuration via the `configToml` parameter in `archivist_new()`. Pass `NULL` or an empty string to use defaults.

## License

See LICENSE-APACHEv2 and LICENSE-MIT files in the parent directory.
