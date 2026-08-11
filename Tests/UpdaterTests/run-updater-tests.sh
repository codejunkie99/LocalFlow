#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILD_DIR="$ROOT/.build/arm64-apple-macosx/debug"
HELPER="$BUILD_DIR/LocalFlowUpdater"

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

assert_true() {
    local condition="$1"
    local message="$2"
    if [[ "$condition" == "1" ]]; then
        passed=$((passed + 1))
    else
        failed=$((failed + 1))
        printf 'FAIL: %s\n' "$message" >&2
    fi
}

make_fixture() {
    local root="$1"
    local name="$2"
    local marker="$3"
    local app="$root/$name"
    mkdir -p "$app/Contents/MacOS"
    printf '#!/bin/sh\nexit 0\n' > "$app/Contents/MacOS/LocalFlowApp"
    chmod +x "$app/Contents/MacOS/LocalFlowApp"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string dev.localflow.app" \
        "$app/Contents/Info.plist" 2>/dev/null || true
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string 0.2.0" \
        "$app/Contents/Info.plist" 2>/dev/null || true
    printf '%s\n' "$marker" > "$app/marker.txt"
}

if [[ ! -x "$HELPER" ]]; then
    failed=$((failed + 1))
    printf 'FAIL: updater helper is missing at %s\n' "$HELPER" >&2
    printf '%d passed, %d failed\n' "$passed" "$failed"
    exit 1
fi

root="$(mktemp -d)"
mkdir -p "$root/apps"
current="$root/apps/LocalFlow.app"
staged="$root/apps/.LocalFlow.staged.app"
previous="$root/apps/.LocalFlow.previous.app"
database="$root/history.sqlite3"
backup="$root/history-backup.sqlite3"
receipt="$root/receipt.json"

make_fixture "$root/apps" "LocalFlow.app" "current-version"
make_fixture "$root/apps" ".LocalFlow.staged.app" "staged-version"
printf 'database-marker\n' > "$database"

"$HELPER" \
    --parent-pid "$$" \
    --current "$current" \
    --staged "$staged" \
    --previous "$previous" \
    --database "$database" \
    --database-backup "$backup" \
    --receipt "$receipt" \
    --expected-bundle-id dev.localflow.app \
    --expected-requirement "identifier \"dev.localflow.app\"" \
    --skip-launch \
    --test-mode

assert_eq "staged-version" "$(cat "$current/marker.txt")" \
    "successful replacement moves staged app to canonical path"
assert_eq "current-version" "$(cat "$previous/marker.txt")" \
    "successful replacement keeps prior app as one rollback copy"
assert_eq "database-marker" "$(cat "$backup")" \
    "helper backs up the database before replacement"
assert_true "$([[ -f "$receipt" ]] && echo 1 || echo 0)" \
    "helper writes a launch receipt on success"

broken_root="$(mktemp -d)"
mkdir -p "$broken_root/apps"
broken_current="$broken_root/apps/LocalFlow.app"
broken_staged="$broken_root/apps/.LocalFlow.staged.app"
broken_previous="$broken_root/apps/.LocalFlow.previous.app"
make_fixture "$broken_root/apps" "LocalFlow.app" "keep-me"
mkdir -p "$broken_staged/Contents/MacOS"
printf 'not-an-app\n' > "$broken_staged/Contents/MacOS/executable"

if "$HELPER" \
    --parent-pid "$$" \
    --current "$broken_current" \
    --staged "$broken_staged" \
    --previous "$broken_previous" \
    --database "$broken_root/history.sqlite3" \
    --database-backup "$broken_root/backup.sqlite3" \
    --receipt "$broken_root/receipt.json" \
    --expected-bundle-id dev.localflow.app \
    --expected-requirement "identifier \"dev.localflow.app\"" \
    --skip-launch \
    --test-mode >/dev/null 2>&1; then
    failed=$((failed + 1))
    printf 'FAIL: invalid staged app must fail replacement\n' >&2
else
    passed=$((passed + 1))
fi
assert_eq "keep-me" "$(cat "$broken_current/marker.txt")" \
    "invalid staged bundle leaves current app untouched"

rollback_root="$(mktemp -d)"
mkdir -p "$rollback_root/apps"
rollback_current="$rollback_root/apps/LocalFlow.app"
rollback_staged="$rollback_root/apps/.LocalFlow.staged.app"
rollback_previous="$rollback_root/apps/.LocalFlow.previous.app"
rollback_database="$rollback_root/history.sqlite3"
rollback_backup="$rollback_root/history-backup.sqlite3"
make_fixture "$rollback_root/apps" "LocalFlow.app" "rollback-current"
make_fixture "$rollback_root/apps" ".LocalFlow.staged.app" "rollback-staged"
printf 'database-before\n' > "$rollback_database"

if "$HELPER" \
    --parent-pid "$$" \
    --current "$rollback_current" \
    --staged "$rollback_staged" \
    --previous "$rollback_previous" \
    --database "$rollback_database" \
    --database-backup "$rollback_backup" \
    --receipt "$rollback_root/receipt.json" \
    --expected-bundle-id dev.localflow.app \
    --expected-requirement "identifier \"dev.localflow.app\"" \
    --simulate-launch-timeout \
    --test-mode >/dev/null 2>&1; then
    failed=$((failed + 1))
    printf 'FAIL: simulated launch timeout must fail\n' >&2
else
    passed=$((passed + 1))
fi
assert_eq "rollback-current" "$(cat "$rollback_current/marker.txt")" \
    "launch timeout restores the previous app"
assert_eq "database-before" "$(cat "$rollback_database")" \
    "launch timeout restores the prior database"

printf '%d passed, %d failed\n' "$passed" "$failed"
exit "$([ "$failed" -gt 0 ] && echo 1 || echo 0)"
