#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SDK=/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk
MOD_DIR="$ROOT/.build/arm64-apple-macosx/debug/Modules"
BUILD_DIR="$ROOT/.build/arm64-apple-macosx/debug"

echo "=== Building all targets ==="
CLANG_MODULE_CACHE_PATH=/private/tmp/.clang_cache swift build --disable-sandbox

BIN_DIR="$(CLANG_MODULE_CACHE_PATH=/private/tmp/.clang_cache swift build --disable-sandbox --show-bin-path)"

# Core tests (standalone executables linked against core object files)
CORE_OBJS=$(find "$BUILD_DIR/LocalFlowCore.build" -name "*.o" 2>/dev/null | tr '\n' ' ')

for test_file in Tests/LocalFlowCoreTests/*.swift; do
    name="test_$(basename "$test_file" .swift)"
    echo "=== Running $name ==="
    CLANG_MODULE_CACHE_PATH=/private/tmp/.clang_cache swiftc \
        -I "$MOD_DIR" \
        -target arm64-apple-macosx26.0 \
        -sdk "$SDK" \
        "$test_file" \
        $CORE_OBJS \
        -o "$BIN_DIR/$name"
    "$BIN_DIR/$name"
done

# Platform tests
PLATFORM_OBJS=$(find "$BUILD_DIR/LocalFlowPlatform.build" -name "*.o" 2>/dev/null | tr '\n' ' ')
ALL_OBJS="$CORE_OBJS $PLATFORM_OBJS"

for test_file in Tests/LocalFlowPlatformTests/*.swift; do
    name="test_$(basename "$test_file" .swift)"
    echo "=== Running $name ==="
    CLANG_MODULE_CACHE_PATH=/private/tmp/.clang_cache swiftc \
        -I "$MOD_DIR" \
        -target arm64-apple-macosx26.0 \
        -sdk "$SDK" \
        "$test_file" \
        $ALL_OBJS \
        -o "$BIN_DIR/$name"
    "$BIN_DIR/$name"
done

echo "=== All tests passed ==="
