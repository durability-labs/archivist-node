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
TEST_BIN = $(BIN_DIR)/test_ffi

NIM_SOURCES = libarchivist.nim
C_TEST_SOURCES = test_ffi.c

.PHONY: all
all: $(LIB_SO) $(TEST_BIN)

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

$(TEST_BIN): $(C_TEST_SOURCES) $(LIB_SO) | $(BIN_DIR)
	$(CC) $(CFLAGS) -o $(TEST_BIN) $(C_TEST_SOURCES) $(LDFLAGS) -I.

.PHONY: test
test: $(TEST_BIN)
	@echo "Running FFI tests..."
	@LD_LIBRARY_PATH=$(LIB_DIR) $(TEST_BIN)

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
	@echo "  all       - Build library and test program (default)"
	@echo "  test      - Run FFI tests"
	@echo "  clean     - Remove build artifacts"
	@echo "  install   - Install library to /usr/local"
	@echo "  uninstall - Remove library from /usr/local"
	@echo "  check     - Check Nim code for errors"
	@echo "  help      - Show this help message"
