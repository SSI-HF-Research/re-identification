#!/bin/bash
# run-all.sh — run all scenarios with recommended defaults.

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "==================================================================="
echo "  Fabric PoC benchmark suite"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "==================================================================="

echo ""
echo "### Scenario A — ingest ###"
N_PATIENTS=5000 BATCH_SIZE=500 CONCURRENCY=8 \
  "$ROOT/scripts/benchmark/scenario-a-ingest.sh"

echo ""
echo "### Scenario B — reid (baseline) ###"
REPEAT=100 CONCURRENCY_REID=8 \
  "$ROOT/scripts/benchmark/scenario-b-reid.sh"

echo ""
echo "### Scenario C — load sweep ###"
LEVELS="1 2 4 8 16 32" OPS_PER_LEVEL=50 \
  "$ROOT/scripts/benchmark/scenario-c-load.sh"

echo ""
echo "### Analysis ###"
for csv in "$ROOT"/bench-results/scenario-*.csv; do
  case "$csv" in
    *summary*) continue ;;
  esac
  echo ""
  python3 "$ROOT/scripts/benchmark/analyze.py" "$csv" --warmup 5
done

echo ""
echo "==================================================================="
echo "  Done. Raw CSVs in $ROOT/bench-results/"
echo "==================================================================="