#!/bin/bash
# Scenario C: load test. Increases the concurrency level and measures
# throughput (tx/s) and latency per level until saturation.
#
# Metrics covered: M2 (maximum throughput), M6 (scalability by
# concurrency).
#
# Operation used as load: RegisterIdentityReference (simple invoke,
# 2 endorsers, writes to a unique key per call — minimizes the risk of
# MVCC conflicts to isolate the effect of pure concurrency).
#

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/benchmark/config.sh"
source "$ROOT/scripts/benchmark/lib.sh"

LEVELS="1 2 4 8 16 32 64" OPS_PER_LEVEL=400
SUMMARY_CSV="$BENCH_DIR/scenario-c-throughput-summary.csv"
echo "concurrency,ops_attempted,ops_ok,ops_failed,elapsed_s,throughput_tps_ok" > "$SUMMARY_CSV"

one_op() {
  local idx="$1" csv="$2" out
  out="$(mktemp)"
  local pii="load-pii-${idx}-$(date +%s%N)"
  local ref="load-ref-${idx}-$(openssl rand -hex 8)"
  time_cmd "$csv" "C_register_identity" "$out" \
    "$ROOT/scripts/invokeCC.sh" "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
    '{"function":"RegisterIdentityReference","Args":[]}' \
    "{\"pii\":\"$pii\",\"identityReference\":\"$ref\"}" \
    OrgIM OrgIM OrgWPI
  rm -f "$out"
}

for level in $LEVELS; do
  CSV="$BENCH_DIR/scenario-c_level${level}.csv"
  ensure_csv_header "$CSV"
  echo ">> Concurrency level: $level ($OPS_PER_LEVEL operations)"

  t0=$(now_ns)
  i=1
  while [ "$i" -le "$OPS_PER_LEVEL" ]; do
    batch_end=$(( i + level - 1 ))
    [ "$batch_end" -gt "$OPS_PER_LEVEL" ] && batch_end=$OPS_PER_LEVEL
    for ((j=i; j<=batch_end; j++)); do
      one_op "$j" "$CSV" &
    done
    wait
    i=$(( batch_end + 1 ))
  done
  t1=$(now_ns)

  elapsed_s=$(awk "BEGIN{printf \"%.3f\", ($t1-$t0)/1000000000}")
  ok_count=$(awk -F',' '$3==1{c++} END{print c+0}' "$CSV")
  fail_count=$(awk -F',' '$3==0{c++} END{print c+0}' "$CSV")
  tps=$(awk "BEGIN{printf \"%.2f\", $ok_count/$elapsed_s}")

  echo "$level,$OPS_PER_LEVEL,$ok_count,$fail_count,$elapsed_s,$tps" >> "$SUMMARY_CSV"
  echo "   -> ${elapsed_s}s | ok=$ok_count fail=$fail_count | ${tps} tx/s (successful)"

  if [ "$fail_count" -gt 0 ]; then
    echo "   WARNING: $fail_count failures at this level — check MVCC_READ_CONFLICT / endorsement timeout"
  fi
done

echo ""
echo ">> Throughput summary by concurrency level:"
column -t -s',' "$SUMMARY_CSV" 2>/dev/null || cat "$SUMMARY_CSV"
echo ">> File: $SUMMARY_CSV"
