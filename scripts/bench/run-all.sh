#!/bin/bash
# ============================================================================
# run-all.sh — Orchestrator for the full benchmark suite.
#
# PURPOSE
#   Runs every scenario in sequence, aggregates each CSV, and prints a
#   combined summary. Failures in one scenario don't stop the suite.
#
# METRICS SERVED
#   All (M1..M6). Runs every scenario once and reports per-file stats.
#
# USAGE
#   ./run-all.sh
# ============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/bench/config.sh"

echo "=============================================================="
echo " Full benchmark suite — $(date '+%Y-%m-%d %H:%M:%S')"
echo " Results: $BENCH_DIR"
echo "=============================================================="

run() {
  local name="$1"
  echo ""
  echo ">>>>> $name"
  bash "$ROOT/scripts/bench/$name" || echo "!! $name failed — continuing" >&2
}

# Scenario F first — gives us the baseline to reference in later analyses
run scenario-f-cli-overhead.sh
run scenario-a-ingest.sh
run scenario-b-reid.sh
run scenario-c-load.sh
run scenario-d-pdc-isolation.sh
run scenario-e-payload-sweep.sh

echo ""
echo "=============================================================="
echo " All scenarios finished."
echo "=============================================================="
echo ""
for f in "$BENCH_DIR"/scenario-*.csv; do
  [ -f "$f" ] || continue
  echo ""
  echo ">> $(basename "$f")"
  python3 "$ROOT/scripts/bench/analyze.py" "$f" --warmup 3 2>/dev/null || true
done