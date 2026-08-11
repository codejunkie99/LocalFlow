#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/scripts/lib/localflow-signing.sh"

passed=0
failed=0

assert_eq() {
    local expected="$1"
    local actual="$2"
    local message="$3"
    if [[ "$expected" == "$actual" ]]; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$message" "$expected" "$actual" >&2
    fi
}

assert_eq "$(identity_label '  1) AAA "Developer ID Application: Example (TEAMID)"')" \
    "Developer ID Application: Example (TEAMID)" \
    "identity_label extracts the quoted label"

assert_eq "$(identity_fingerprint '  1) BBB "Apple Development: Example (TEAMID)"')" \
    "BBB" \
    "identity_fingerprint extracts the certificate hash"

developer_id='  1) AAA "Developer ID Application: Example (TEAMID)"'
apple_dev='  1) BBB "Apple Development: Example (TEAMID)"'
both="$apple_dev
$developer_id"

assert_eq "$(identity_fingerprint_for_label "$both" 'Apple Development: Example (TEAMID)')" \
    "BBB" \
    "identity_fingerprint_for_label resolves the selected identity hash"

assert_eq "$(select_localflow_identity "$both")" \
    "Developer ID Application: Example (TEAMID)" \
    "Developer ID is preferred over Apple Development"

assert_eq "$(select_localflow_identity "$apple_dev")" \
    "Apple Development: Example (TEAMID)" \
    "Apple Development is selected when it is the only identity"

assert_eq "$(select_localflow_identity '0 valid identities found')" \
    "" \
    "no valid identities yields empty selection"

local_signing='  1) CCC "LocalFlow Local Signing (SOMEFINGERPRINT)"'
assert_eq "$(select_localflow_identity "$local_signing")" \
    "LocalFlow Local Signing (SOMEFINGERPRINT)" \
    "LocalFlow local signing is accepted"

assert_eq "$(select_localflow_identity '  1) DDD "Mac Developer: Example (TEAMID)"')" \
    "" \
    "Mac Developer identities are rejected"

assert_eq "$(select_localflow_identity "$both
$local_signing")" \
    "Developer ID Application: Example (TEAMID)" \
    "selection order remains Developer ID first when all three exist"

function test_setup_dry_run {
    local tmp_root
    tmp_root="$(mktemp -d)"
    local identity_before
    identity_before="$(defaults read dev.localflow.app LocalFlowSigningIdentity 2>/dev/null || echo 0)"
    local output
    set +e
    output="$(LOCALFLOW_SETUP_DRY_RUN=1 \
        LOCALFLOW_IDENTITY_FIXTURE="$apple_dev" \
        bash "$ROOT/scripts/setup-localflow.sh" --install-root "$tmp_root" 2>&1)"
    local setup_status=$?
    set -e
    if [[ "$setup_status" -ne 0 ]]; then
        failed=$((failed + 1))
        printf 'FAIL: setup dry-run exited %d\n%s\n' "$setup_status" "$output" >&2
        return
    fi

    local contains_checks=(
        "macOS|dry run reports macOS prerequisite checks"
        "Apple silicon|dry run reports Apple silicon requirement"
        "Apple Development: Example (TEAMID)|dry run reports the selected identity"
        "LocalFlow.app|dry run reports the canonical destination"
        "package-app.sh|dry run reports the packaging command"
        "codesign|dry run reports signature verification"
        "open .*LocalFlow.app|dry run reports the launch command"
    )
    local check
    for check in "${contains_checks[@]}"; do
        local pattern="${check%%|*}"
        local message="${check#*|}"
        if ! printf '%s' "$output" | grep -q "$pattern"; then
            failed=$((failed + 1))
            printf 'FAIL: %s\n%s\n' "$message" "$output" >&2
        else
            passed=$((passed + 1))
        fi
    done

    if [[ -e "$tmp_root/LocalFlow.app" || -e "$tmp_root/.LocalFlow.staged.app" ]]; then
        failed=$((failed + 1))
        printf 'FAIL: dry run must not create an app bundle\n' >&2
    fi

    assert_eq "$identity_before" "$(defaults read dev.localflow.app LocalFlowSigningIdentity 2>/dev/null || echo 0)" \
        "dry run must not write signing preferences"
}

test_setup_dry_run

function test_atomic_app_replacement {
    local tmp_root
    tmp_root="$(mktemp -d)"
    local current="$tmp_root/LocalFlow.app"
    local staged="$tmp_root/.LocalFlow.staged.app"
    local previous="$tmp_root/.LocalFlow.previous.app"
    mkdir -p "$current" "$staged" "$previous"
    printf 'current\n' > "$current/marker"
    printf 'staged\n' > "$staged/marker"
    printf 'stale previous\n' > "$previous/marker"

    replace_app_bundle "$current" "$staged" "$previous"

    assert_eq "staged" "$(cat "$current/marker")" \
        "setup installs staged app at the canonical path"
    assert_eq "current" "$(cat "$previous/marker")" \
        "setup retains exactly the replaced app as rollback copy"
}

test_atomic_app_replacement

printf '%d passed, %d failed\n' "$passed" "$failed"
exit "$([ "$failed" -gt 0 ] && echo 1 || echo 0)"
