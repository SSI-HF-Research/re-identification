#!/bin/bash
# run-all.sh — runs the 3 scenarios sequentially with default parameters
# (adjust the environment variables before calling, or edit config.sh).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "=================================================="
echo " BENCHMARK — Scenarios A, B, C"
echo "=================================================="

echo ""
echo ">>> Scenario A (batch ingestion)"
N_PATIENTS=1000 BATCH_SIZE=200 CONCURRENCY=4
"$ROOT/scripts/benchmark/scenario-a-ingest.sh"

echo ""
echo ">>> Scenario B (full re-identification)"
REPEAT=30 CONCURRENCY_REID=4 ./scripts/benchmark/scenario-b-reid.sh
"$ROOT/scripts/benchmark/scenario-b-reid.sh"

echo ""
echo ">>> Scenario C (load / throughput test)"
LEVELS="1 2 4 8" OPS_PER_LEVEL=30
"$ROOT/scripts/benchmark/scenario-c-load.sh"

echo ""
echo "=================================================="
echo " Aggregated analysis"
echo "=================================================="
for csv in "$ROOT"/bench-results/*.csv; do
  [ -f "$csv" ] || continue
  echo ""
  python3 "$ROOT/scripts/benchmark/analyze.py" "$csv"
done
