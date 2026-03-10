# Makefile for building and testing libarchivist

CC = gcc
CFLAGS = -Wall -Wextra -O2 -fPIC
LDFLAGS = -Lbuild/lib -larchivist -lpthread

NIM = nim
NIM_FLAGS = --app:lib --opt:speed -d:release --mm:arc --nimMainPrefix:libarchivist

BUILD_DIR = build
LIB_DIR = $(BUILD_DIR)/lib
BIN_DIR = $(BUILD_DIR)/bin

LIB_NAME = libarchivist
LIB_SO = $(LIB_DIR)/$(LIB_NAME).so
LIB_A = $(LIB_DIR)/$(LIB_NAME).a

# Focused C test binaries
TEST_BINS = \
	$(BIN_DIR)/test_ffi_context \
	$(BIN_DIR)/test_ffi_config \
	$(BIN_DIR)/test_ffi_version \
	$(BIN_DIR)/test_ffi_p2p \
	$(BIN_DIR)/test_ffi_storage \
	$(BIN_DIR)/test_ffi_upload \
	$(BIN_DIR)/test_ffi_download \
	$(BIN_DIR)/test_ffi_edge_cases

NIM_SOURCES = libarchivist.nim
C_TEST_SOURCES_FOCUSED = \
	tests/test_ffi_context.c \
	tests/test_ffi_config.c \
	tests/test_ffi_version.c \
	tests/test_ffi_p2p.c \
	tests/test_ffi_storage.c \
	tests/test_ffi_upload.c \
	tests/test_ffi_download.c \
	tests/test_ffi_edge_cases.c

.PHONY: all
all: $(LIB_SO) $(TEST_BINS)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(LIB_DIR):
	mkdir -p $(LIB_DIR)

$(BIN_DIR):
	mkdir -p $(BIN_DIR)

$(LIB_SO): $(NIM_SOURCES) | $(LIB_DIR)
	cd .. && $(NIM) c $(NIM_FLAGS) --out:library/$(LIB_SO) library/$(NIM_SOURCES)

$(LIB_A): $(NIM_SOURCES) | $(LIB_DIR)
	$(NIM) c $(NIM_FLAGS) --out:$(LIB_A) $(NIM_SOURCES)

# Build all focused C test binaries
$(BIN_DIR)/test_ffi_%: tests/test_ffi_%.c $(LIB_SO) | $(BIN_DIR)
	$(CC) $(CFLAGS) -o $@ $< $(LDFLAGS) -I. -Itests

.PHONY: test
test: $(TEST_BINS)
	@echo "Running FFI tests..."
	@for test in $(TEST_BINS); do \
		echo ""; \
		echo "Running $$test..."; \
		LD_LIBRARY_PATH=$(LIB_DIR) $$test || exit 1; \
	done
	@echo ""
	@echo "All FFI tests passed!"

.PHONY: test-all
test-all: test
	@echo "All FFI tests completed."

# Individual test targets
.PHONY: test-context test-config test-version test-p2p test-storage test-upload test-download test-edge-cases
test-context: $(BIN_DIR)/test_ffi_context
	@echo "Running context lifecycle tests..."
	@LD_LIBRARY_PATH=$(LIB_DIR) $(BIN_DIR)/test_ffi_context

test-config: $(BIN_DIR)/test_ffi_config
	@echo "Running configuration tests..."
	@LD_LIBRARY_PATH=$(LIB_DIR) $(BIN_DIR)/test_ffi_config

test-version: $(BIN_DIR)/test_ffi_version
	@echo "Running version information tests..."
	@LD_LIBRARY_PATH=$(LIB_DIR) $(BIN_DIR)/test_ffi_version

test-p2p: $(BIN_DIR)/test_ffi_p2p
	@echo "Running P2P operations tests..."
	@LD_LIBRARY_PATH=$(LIB_DIR) $(BIN_DIR)/test_ffi_p2p

test-storage: $(BIN_DIR)/test_ffi_storage
	@echo "Running storage operations tests..."
	@LD_LIBRARY_PATH=$(LIB_DIR) $(BIN_DIR)/test_ffi_storage

test-upload: $(BIN_DIR)/test_ffi_upload
	@echo "Running upload operations tests..."
	@LD_LIBRARY_PATH=$(LIB_DIR) $(BIN_DIR)/test_ffi_upload

test-download: $(BIN_DIR)/test_ffi_download
	@echo "Running download operations tests..."
	@LD_LIBRARY_PATH=$(LIB_DIR) $(BIN_DIR)/test_ffi_download

test-edge-cases: $(BIN_DIR)/test_ffi_edge_cases
	@echo "Running edge case tests..."
	@LD_LIBRARY_PATH=$(LIB_DIR) $(BIN_DIR)/test_ffi_edge_cases

.PHONY: clean
clean:
	rm -rf $(BUILD_DIR)
	rm -f *.so *.a

.PHONY: install
install: $(LIB_SO)
	install -d /usr/local/lib
	install -m 644 $(LIB_SO) /usr/local/lib/
	install -d /usr/local/include
	install -m 644 libarchivist.h /usr/local/include/
	ldconfig

.PHONY: uninstall
uninstall:
	rm -f /usr/local/lib/$(LIB_NAME).so
	rm -f /usr/local/include/libarchivist.h
	ldconfig

.PHONY: check
check:
	$(NIM) check libarchivist.nim

.PHONY: help
help:
	@echo "Available targets:"
	@echo "  all       - Build library and all test programs (default)"
	@echo "  test      - Run all FFI tests"
	@echo "  test-nim  - Run Nim tests"
	@echo "  test-all  - Run all tests (FFI + Nim)"
	@echo "  clean     - Remove build artifacts"
	@echo "  install   - Install library to /usr/local"
	@echo "  uninstall - Remove library from /usr/local"
	@echo "  check     - Check Nim code for errors"
	@echo "  help      - Show this help message"
	@echo ""
	@echo "Individual FFI test targets:"
	@echo "  test-context    - Run context lifecycle tests"
	@echo "  test-config     - Run configuration tests"
	@echo "  test-version    - Run version information tests"
	@echo "  test-p2p        - Run P2P operations tests"
	@echo "  test-storage    - Run storage operations tests"
	@echo "  test-upload     - Run upload operations tests"
	@echo "  test-download   - Run download operations tests"
	@echo "  test-edge-cases - Run edge case tests"
