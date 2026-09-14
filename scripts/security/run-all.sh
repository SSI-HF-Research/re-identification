#!/bin/bash
# ============================================================================
# run-all.sh — Orchestrator for the security test suite.
#
# PURPOSE
#   Runs every security test, aggregates the pass/fail counts, and returns
#   a non-zero exit code if any test failed.
#
# METRICS SERVED
#   Produces the overall pass/fail table for the security chapter of the
#   paper. Every test file writes its own CSV under SEC_DIR.
#
# USAGE
#   ./run-all.sh
# ============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/security/config.sh"

echo "=============================================================="
echo " Security test suite — $(date '+%Y-%m-%d %H:%M:%S')"
echo " Results: $SEC_DIR"
echo "=============================================================="

TOTAL_FAIL=0
run() {
  local name="$1"
  echo ""
  echo ">>>>> $name"
  bash "$ROOT/scripts/security/$name" || TOTAL_FAIL=$(( TOTAL_FAIL + 1 ))
}

run channel-isolation.sh
run pdc-isolation.sh
run function-access.sh
run ec-signatures.sh
run cross-channel-leakage.sh

echo ""
echo "=============================================================="
echo " Security test suite finished"
echo " Failed test files: $TOTAL_FAIL"
echo "=============================================================="

for f in "$SEC_DIR"/test-*.csv; do
  [ -f "$f" ] || continue
  pass=$(awk -F',' '$1=="PASS"{c++} END{print c+0}' "$f")
  fail=$(awk -F',' '$1=="FAIL"{c++} END{print c+0}' "$f")
  printf "  %-40s  pass=%s fail=%s\n" "$(basename "$f")" "$pass" "$fail"
done

[ "$TOTAL_FAIL" -eq 0 ]