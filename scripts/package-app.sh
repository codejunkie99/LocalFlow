#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "=== Building release ==="
CLANG_MODULE_CACHE_PATH=/private/tmp/localflow-clang-cache \
    swift build -c release --disable-sandbox --product LocalFlowApp

BIN="$(CLANG_MODULE_CACHE_PATH=/private/tmp/localflow-clang-cache \
    swift build -c release --disable-sandbox --show-bin-path)/LocalFlowApp"
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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LocalFlowApp"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

echo "=== Signing with $SIGNING_LABEL ==="
codesign --force --deep --timestamp=none --sign "$SIGNING_IDENTITY" "$APP"

echo "=== Verifying ==="
plutil -lint "$APP/Contents/Info.plist"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "=== App packaged at: $APP ==="
