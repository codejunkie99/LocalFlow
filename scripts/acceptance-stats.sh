#!/usr/bin/env bash
set -euo pipefail
# Extract LocalFlow latency entries from the last N minutes of OSLog and compute median/p95.
# Usage: scripts/acceptance-stats.sh [minutes]

MINUTES="${1:-10}"
TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

echo "=== Extracting LocalFlow latency logs (last ${MINUTES} min) ==="
log show --last "${MINUTES}m" --predicate 'subsystem == "dev.localflow.app"' --style compact > "$TMPDIR/raw.log" 2>/dev/null || {
    echo "ERROR: Could not read system log. Try: log show --last ${MINUTES}m --predicate 'subsystem == \"dev.localflow.app\"' --style compact"
    exit 1
}

# Parse lines like: ... total=1234ms speech=800ms rewrite=300ms paste=100ms fallback=false
grep -F 'timing:' "$TMPDIR/raw.log" > "$TMPDIR/latency.log" || true

if [ ! -s "$TMPDIR/latency.log" ]; then
    echo "No latency entries found in the last ${MINUTES} minutes."
    echo "Ensure LocalFlow has been used and try with a larger window: $0 30"
    exit 1
fi

COUNT=$(wc -l < "$TMPDIR/latency.log" | tr -d ' ')
echo "Found $COUNT latency entries."

# Extract total milliseconds using sed
grep -oE 'total=[0-9.]+ms' "$TMPDIR/latency.log" | sed 's/total=//;s/ms//' > "$TMPDIR/totals.txt"

# Compute median and p95 using awk
sort -n "$TMPDIR/totals.txt" > "$TMPDIR/sorted.txt"
N=$(wc -l < "$TMPDIR/sorted.txt" | tr -d ' ')

MEDIAN=$(awk -v n="$N" '{
  a[NR]=$1
} END {
  if (n % 2) { print a[int(n/2)+1] }
  else { print (a[n/2] + a[n/2+1]) / 2 }
}' "$TMPDIR/sorted.txt")

P95_IDX=$(python3 -c "import math; n=$N; print(max(1, int(math.ceil(0.95 * n))))" 2>/dev/null || echo "$N")
P95=$(awk -v idx="$P95_IDX" 'NR==idx{print $1}' "$TMPDIR/sorted.txt")

echo ""
echo "=== Acceptance Results ==="
echo "Trials:  $COUNT"
echo "Median:  ${MEDIAN}ms"
echo "P95:     ${P95}ms"
echo ""

MEDIAN_INT=$(echo "$MEDIAN" | cut -d. -f1)
P95_INT=$(echo "$P95" | cut -d. -f1)

PASS=true
if [ -z "$MEDIAN" ] || [ "$MEDIAN_INT" -gt 1500 ] 2>/dev/null; then
    echo "FAIL: Median ${MEDIAN}ms exceeds 1500ms target"
    PASS=false
fi
if [ -z "$P95" ] || [ "$P95_INT" -gt 2500 ] 2>/dev/null; then
    echo "FAIL: P95 ${P95}ms exceeds 2500ms target"
    PASS=false
fi
if [ "$COUNT" -lt 20 ]; then
    echo "WARN: Only $COUNT trials (need 20)"
    PASS=false
fi

if [ "$PASS" = true ]; then
    echo "PASS: Latency contract met."
fi
