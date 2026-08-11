#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/lib/localflow-signing.sh"

DRY_RUN="${LOCALFLOW_SETUP_DRY_RUN:-0}"
INSTALL_ROOT="${LOCALFLOW_INSTALL_ROOT:-$HOME/Applications}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --install-root)
            INSTALL_ROOT="$2"
            shift 2
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

INSTALL_DIR="$INSTALL_ROOT/LocalFlow.app"
STAGED_DIR="$INSTALL_ROOT/.LocalFlow.staged.app"
PREVIOUS_DIR="$INSTALL_ROOT/.LocalFlow.previous.app"

echo "LocalFlow setup"
echo "Repository: $ROOT"
echo "Canonical app: $INSTALL_DIR"

echo "=== Checking prerequisites ==="
echo "macOS $(sw_vers -productVersion)"
case "$(uname -m)" in
    arm64) echo "Apple silicon: OK" ;;
    *)
        echo "ERROR: LocalFlow requires an Apple silicon Mac." >&2
        exit 1
        ;;
esac

if ! xcode-select -p >/dev/null 2>&1; then
    echo "Command Line Tools are not installed."
    echo "Opening the Apple developer installer. When it finishes, run this exact command again:"
    echo ""
    echo "  ./scripts/setup-localflow.sh"
    echo ""
    if [[ "$DRY_RUN" != "1" ]]; then
        xcode-select --install
    fi
    exit 1
fi
echo "Command Line Tools: OK ($(xcode-select -p))"

for tool in swift git; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "ERROR: missing required tool: $tool" >&2
        exit 1
    fi
done
echo "Swift: $(swift --version 2>&1 | head -1)"
echo "Git: $(git --version 2>&1)"

if [[ "$DRY_RUN" != "1" ]]; then
    mkdir -p "$INSTALL_ROOT"
    if [[ ! -w "$INSTALL_ROOT" ]]; then
        echo "ERROR: not writable: $INSTALL_ROOT" >&2
        exit 1
    fi
    echo "Applications directory: writable"
else
    echo "Applications directory: [dry-run] check $INSTALL_ROOT"
fi

echo "=== Selecting a stable signing identity ==="
IDENTITY=""
IDENTITY_LIST=""
if [[ -n "${LOCALFLOW_IDENTITY_FIXTURE:-}" ]]; then
    IDENTITY_LIST="$LOCALFLOW_IDENTITY_FIXTURE"
    IDENTITY="$(identity_label "$IDENTITY_LIST")"
elif [[ "$DRY_RUN" == "1" ]]; then
    IDENTITY_LIST="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    IDENTITY="$(select_localflow_identity "$IDENTITY_LIST")"
    if [[ -z "$IDENTITY" ]]; then
        IDENTITY="LocalFlow Local Signing (FIXTURE)"
        IDENTITY_LIST='  1) FIXTURE "LocalFlow Local Signing (FIXTURE)"'
        echo "[dry-run] no real identity read; using fixture identity"
    fi
else
    IDENTITY_LIST="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    IDENTITY="$(select_localflow_identity "$IDENTITY_LIST")"
    if [[ -z "$IDENTITY" ]]; then
        echo "No Developer ID or Apple Development identity found; creating a LocalFlow-only local signing identity."
        IDENTITY="$(create_localflow_signing_identity)"
        IDENTITY_LIST="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    fi
fi

if [[ -z "$IDENTITY" ]]; then
    echo "ERROR: no code-signing identity available. Install an Apple Development certificate or rerun with LOCALFLOW_SETUP_DRY_RUN=0." >&2
    exit 1
fi
echo "Selected identity: $IDENTITY"
FINGERPRINT="$(identity_fingerprint_for_label "$IDENTITY_LIST" "$IDENTITY")"
if [[ -z "$FINGERPRINT" ]]; then
    echo "ERROR: could not resolve the selected signing identity fingerprint." >&2
    exit 1
fi
echo "Identity fingerprint: $FINGERPRINT"

echo "=== Building and packaging ==="
if [[ "$DRY_RUN" != "1" ]]; then
    LOCALFLOW_SIGNING_IDENTITY="$IDENTITY" "$ROOT/scripts/package-app.sh"
else
    echo "[dry-run] LOCALFLOW_SIGNING_IDENTITY=\"$IDENTITY\" ./scripts/package-app.sh"
fi

if [[ "$DRY_RUN" != "1" ]]; then
    BUNDLE_ID="$(defaults read "$ROOT/dist/LocalFlow.app/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || true)"
    if [[ "$BUNDLE_ID" != "dev.localflow.app" ]]; then
        echo "ERROR: packaged bundle identifier is not dev.localflow.app" >&2
        exit 1
    fi
    echo "Bundle identifier: $BUNDLE_ID"
else
    echo "[dry-run] verify CFBundleIdentifier == dev.localflow.app"
fi

echo "=== Installing canonical app ==="
if [[ "$DRY_RUN" != "1" ]]; then
    if [[ -e "$STAGED_DIR" ]]; then
        rm -rf -- "$STAGED_DIR"
    fi
    ditto "$ROOT/dist/LocalFlow.app" "$STAGED_DIR"
    codesign --verify --deep --strict --verbose=2 "$STAGED_DIR"
    replace_app_bundle "$INSTALL_DIR" "$STAGED_DIR" "$PREVIOUS_DIR"
    defaults write dev.localflow.app LocalFlowSigningIdentity -string "$IDENTITY"
    defaults write dev.localflow.app LocalFlowSigningFingerprint -string "$FINGERPRINT"
else
    echo "[dry-run] ditto dist/LocalFlow.app $STAGED_DIR"
    echo "[dry-run] codesign --verify --deep --strict $STAGED_DIR"
    echo "[dry-run] mv $STAGED_DIR $INSTALL_DIR"
    echo "[dry-run] defaults write dev.localflow.app LocalFlowSigningIdentity -string \"$IDENTITY\""
    echo "[dry-run] defaults write dev.localflow.app LocalFlowSigningFingerprint -string \"$FINGERPRINT\""
fi

echo "=== Verifying signature ==="
if [[ "$DRY_RUN" != "1" ]]; then
    codesign --verify --deep --strict --verbose=2 "$INSTALL_DIR"
    codesign -d -r- "$INSTALL_DIR" 2>/dev/null | head -1
else
    echo "[dry-run] codesign --verify --deep --strict $INSTALL_DIR"
fi

echo "=== One-time permissions ==="
echo "1. Grant Microphone access when LocalFlow asks."
echo "2. Grant Speech Recognition access when LocalFlow asks."
echo "3. Open System Settings > Privacy & Security > Accessibility and enable LocalFlow."
echo "4. Test in TextEdit: place the cursor, hold Option-Space, speak, release."

echo "=== Launching LocalFlow ==="
if [[ "$DRY_RUN" != "1" ]]; then
    open "$INSTALL_DIR"
else
    echo "[dry-run] open $INSTALL_DIR"
fi

echo "Setup complete. Keep the '$IDENTITY' signing identity on this Mac so permissions survive later updates."
