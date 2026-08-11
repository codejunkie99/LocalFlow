#!/usr/bin/env bash

# Pure identity helpers for LocalFlow setup. These functions accept identity
# list text as an argument and never invoke `security` themselves.

identity_label() {
    awk -F'"' '/valid identities found|^[[:space:]]*[0-9]+\)/ {
        if (NF >= 2) { print $2 }
    }' <<<"$1"
}

identity_fingerprint() {
    awk -F'[)"]' '/^[[:space:]]*[0-9]+\)/ {
        if (NF >= 2) {
            value = $2
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
            print value
        }
    }' <<<"$1"
}

identity_fingerprint_for_label() {
    local identities="$1"
    local wanted_label="$2"
    awk -F'"' -v wanted="$wanted_label" '
        $2 == wanted {
            prefix = $1
            sub(/^[[:space:]]*[0-9]+\)[[:space:]]*/, "", prefix)
            sub(/[[:space:]]+$/, "", prefix)
            print prefix
            exit
        }
    ' <<<"$identities"
}

identity_rank() {
    local label="$1"
    case "$label" in
        "Developer ID Application:"*) printf '%s\n' 1 ;;
        "Apple Development:"*) printf '%s\n' 2 ;;
        "LocalFlow Local Signing"*) printf '%s\n' 3 ;;
        *) printf '%s\n' 0 ;;
    esac
}

select_localflow_identity() {
    awk -F'"' '
        function rank(label, value) {
            if (label ~ /^Developer ID Application:/) return 3
            if (label ~ /^Apple Development:/) return 2
            if (label ~ /^LocalFlow Local Signing/) return 1
            return 0
        }
        /valid identities found/ { next }
        /^[[:space:]]*[0-9]+\)/ {
            if (NF < 2) next
            label = $2
            r = rank(label)
            if (r > best_rank) {
                best_rank = r
                best_label = label
            }
        }
        END { printf "%s", best_label }
    ' <<<"$1"
}

create_localflow_signing_identity() (
    local temp_dir
    temp_dir="$(mktemp -d)"
    local password
    password="$(openssl rand -hex 24)"
    trap 'rm -rf -- "$temp_dir"' EXIT

    local key="$temp_dir/localflow.key"
    local cert="$temp_dir/localflow.crt"
    local p12="$temp_dir/localflow.p12"

    openssl req -x509 -newkey rsa:2048 \
        -keyout "$key" \
        -out "$cert" \
        -days 3650 \
        -nodes \
        -subj "/CN=LocalFlow Local Signing" \
        -addext "keyUsage=digitalSignature" \
        -addext "extendedKeyUsage=codeSigning" >/dev/null 2>&1

    openssl pkcs12 -export \
        -inkey "$key" \
        -in "$cert" \
        -out "$p12" \
        -passout "pass:$password" >/dev/null 2>&1

    security import "$p12" -k "$HOME/Library/Keychains/login.keychain-db" \
        -P "$password" -T /usr/bin/codesign >/dev/null 2>&1

    local identity
    identity="$(select_localflow_identity "$(security find-identity -v -p codesigning 2>/dev/null || true)")"
    if [[ -z "$identity" ]]; then
        echo "ERROR: local signing identity was not created successfully" >&2
        return 1
    fi
    printf '%s' "$identity"
)

replace_app_bundle() {
    local current="$1"
    local staged="$2"
    local previous="$3"
    local parent
    parent="$(dirname "$current")"

    if [[ "$(dirname "$staged")" != "$parent" \
        || "$(dirname "$previous")" != "$parent" \
        || "$(basename "$current")" != "LocalFlow.app" \
        || "$(basename "$staged")" != ".LocalFlow.staged.app" \
        || "$(basename "$previous")" != ".LocalFlow.previous.app" \
        || ! -d "$staged" ]]; then
        echo "ERROR: invalid LocalFlow replacement paths" >&2
        return 1
    fi

    if [[ -e "$previous" ]]; then
        rm -rf -- "$previous"
    fi
    if [[ -e "$current" ]]; then
        mv "$current" "$previous"
    fi
    if ! mv "$staged" "$current"; then
        if [[ -e "$previous" && ! -e "$current" ]]; then
            mv "$previous" "$current"
        fi
        return 1
    fi
}
