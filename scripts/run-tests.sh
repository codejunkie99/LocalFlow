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

SUITE_FAILURES=0

for test_file in Tests/LocalFlowCoreTests/*.swift; do
    name="test_$(basename "$test_file" .swift)"
    echo "=== Running $name ==="
    if ! CLANG_MODULE_CACHE_PATH=/private/tmp/.clang_cache swiftc \
        -I "$MOD_DIR" \
        -target arm64-apple-macosx26.0 \
        -sdk "$SDK" \
        "$test_file" \
        $CORE_OBJS \
        -o "$BIN_DIR/$name"
    then
        SUITE_FAILURES=$((SUITE_FAILURES + 1))
        continue
    fi
    "$BIN_DIR/$name" || SUITE_FAILURES=$((SUITE_FAILURES + 1))
done

# Platform tests
PLATFORM_OBJS=$(find "$BUILD_DIR/LocalFlowPlatform.build" -name "*.o" 2>/dev/null | tr '\n' ' ')
ALL_OBJS="$CORE_OBJS $PLATFORM_OBJS"

for test_file in Tests/LocalFlowPlatformTests/*.swift; do
    name="test_$(basename "$test_file" .swift)"
    echo "=== Running $name ==="
    if ! CLANG_MODULE_CACHE_PATH=/private/tmp/.clang_cache swiftc \
        -I "$MOD_DIR" \
        -target arm64-apple-macosx26.0 \
        -sdk "$SDK" \
        "$test_file" \
        $ALL_OBJS \
        -o "$BIN_DIR/$name"
    then
        SUITE_FAILURES=$((SUITE_FAILURES + 1))
        continue
    fi
    "$BIN_DIR/$name" || SUITE_FAILURES=$((SUITE_FAILURES + 1))
done

for test_file in Tests/ScriptTests/*.sh; do
    echo "=== Running $(basename "$test_file") ==="
    bash "$test_file" || SUITE_FAILURES=$((SUITE_FAILURES + 1))
done

if [[ -f Tests/UpdaterTests/run-updater-tests.sh ]]; then
    echo "=== Running run-updater-tests.sh ==="
    bash Tests/UpdaterTests/run-updater-tests.sh || SUITE_FAILURES=$((SUITE_FAILURES + 1))
fi

if [[ "$SUITE_FAILURES" -gt 0 ]]; then
    echo "=== $SUITE_FAILURES test suite(s) failed ===" >&2
    exit 1
fi

echo "=== All tests passed ==="
