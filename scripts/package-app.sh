#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [[ -n "${LOCALFLOW_VERSION:-}" \
    && ! "$LOCALFLOW_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "ERROR: LOCALFLOW_VERSION must be semantic, for example 0.2.0" >&2
    exit 2
fi
if [[ -n "${LOCALFLOW_BUILD_NUMBER:-}" \
    && ! "$LOCALFLOW_BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    echo "ERROR: LOCALFLOW_BUILD_NUMBER must be a positive integer" >&2
    exit 2
fi

echo "=== Building release ==="
CLANG_MODULE_CACHE_PATH=/private/tmp/localflow-clang-cache \
    swift build -c release --disable-sandbox --product LocalFlowApp
CLANG_MODULE_CACHE_PATH=/private/tmp/localflow-clang-cache \
    swift build -c release --disable-sandbox --product LocalFlowUpdater

BIN="$(CLANG_MODULE_CACHE_PATH=/private/tmp/localflow-clang-cache \
    swift build -c release --disable-sandbox --show-bin-path)/LocalFlowApp"
UPDATER_BIN="$(CLANG_MODULE_CACHE_PATH=/private/tmp/localflow-clang-cache \
    swift build -c release --disable-sandbox --show-bin-path)/LocalFlowUpdater"
APP="$ROOT/dist/LocalFlow.app"
SIGNING_IDENTITY="${LOCALFLOW_SIGNING_IDENTITY:-}"

if [[ -n "$SIGNING_IDENTITY" ]]; then
    if ! security find-identity -v -p codesigning | grep -F -- "\"$SIGNING_IDENTITY\"" >/dev/null; then
        echo "ERROR: Code-signing identity not found: $SIGNING_IDENTITY" >&2
        exit 1
    fi
else
    SIGNING_IDENTITY="$(security find-identity -v -p codesigning \
        | awk -F'"' '/"Apple Development:/{print $2; exit}')"
fi

if [[ -z "$SIGNING_IDENTITY" ]]; then
    SIGNING_IDENTITY="-"
    echo "WARNING: No Apple Development identity was found; using ad-hoc signing." >&2
    echo "macOS may require Accessibility permission again after each rebuild." >&2
    SIGNING_LABEL="ad-hoc identity"
else
    SIGNING_LABEL="$SIGNING_IDENTITY"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN" "$APP/Contents/MacOS/LocalFlowApp"
cp "$UPDATER_BIN" "$APP/Contents/Helpers/LocalFlowUpdater"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

if [[ -n "${LOCALFLOW_VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $LOCALFLOW_VERSION" \
        "$APP/Contents/Info.plist"
fi
if [[ -n "${LOCALFLOW_BUILD_NUMBER:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $LOCALFLOW_BUILD_NUMBER" \
        "$APP/Contents/Info.plist"
fi

echo "=== Signing with $SIGNING_LABEL ==="
codesign --force --timestamp=none --sign "$SIGNING_IDENTITY" "$APP/Contents/Helpers/LocalFlowUpdater"
codesign --force --deep --timestamp=none --sign "$SIGNING_IDENTITY" "$APP"

echo "=== Verifying ==="
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --strict --verbose=2 "$APP/Contents/Helpers/LocalFlowUpdater"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "=== App packaged at: $APP ==="
