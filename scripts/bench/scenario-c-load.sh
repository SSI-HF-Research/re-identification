#!/bin/bash
# ============================================================================
# scenario-c-load.sh — Sustained load, ramp concurrency.
#
# PURPOSE
#   Find the throughput ceiling and observe latency degradation as
#   concurrency rises. Reports blocks_cut per level so you can distinguish
#   "chaincode is slow" from "orderer idle".
#
# METRICS SERVED
#   M2 — transaction latency (query vs invoke, both covered here as invoke)
#        max throughput (tx/s at the knee of the latency curve)
#   M6 — scalability under concurrency
#
# VALUE
#   Produces the headline "max throughput" number and the "at what
#   concurrency does the system degrade" story arc for the paper.
#
# WORKLOAD CHOICE
#   RegisterIdentityReference — single write, 2 endorsers, unique key per
#   call. Minimizes MVCC conflicts to isolate pure concurrency effects.
#
# CLI OVERHEAD
#   The CLI spawns one process per operation, so the local machine becomes
#   the bottleneck before the Fabric peers do. Under C>8 you are measuring
#   fork+exec saturation, not Fabric. Document this caveat in the paper.
#   For C>8 use a long-lived SDK client.
#
# USAGE
#   LEVELS="1 2 4 8 16" OPS_PER_LEVEL=50 ./scenario-c-load.sh
# ============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/bench/config.sh"
source "$ROOT/scripts/bench/lib.sh"

SUMMARY_CSV="$BENCH_DIR/scenario-c-throughput-summary.csv"
echo "concurrency,ops_attempted,ops_ok,ops_failed,elapsed_s,throughput_tps_ok,blocks_cut" > "$SUMMARY_CSV"

warmup_all

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
  DOCKERSTATS="$CSV.dockerstats"
  echo ">> Concurrency level: $level ($OPS_PER_LEVEL operations)"

  start_docker_stats "$DOCKERSTATS"
  before_h=$(channel_height OrgIM "$CHANNEL_WAREHOUSE")

  t0=$(now_ns)
  i=1
  while [ "$i" -le "$OPS_PER_LEVEL" ]; do
    batch_end=$(( i + level - 1 ))
    [ "$batch_end" -gt "$OPS_PER_LEVEL" ] && batch_end=$OPS_PER_LEVEL
    pids=()
    for ((j=i; j<=batch_end; j++)); do
      one_op "$j" "$CSV" & pids+=($!)
    done
    failed=$(wait_all_pids "${pids[@]}")
    [ "$failed" -gt 0 ] && echo "   $failed ops failed in batch" >&2
    i=$(( batch_end + 1 ))
  done
  t1=$(now_ns)
  after_h=$(channel_height OrgIM "$CHANNEL_WAREHOUSE")

  stop_docker_stats "$DOCKERSTATS"

  blocks_cut=$(( after_h - before_h ))
  elapsed_s=$(awk "BEGIN{printf \"%.3f\", ($t1-$t0)/1000000000}")
  ok_count=$(awk -F',' '$3==1{c++} END{print c+0}' "$CSV")
  fail_count=$(awk -F',' '$3==0{c++} END{print c+0}' "$CSV")
  tps=$(awk "BEGIN{printf \"%.2f\", $ok_count/$elapsed_s}")

  echo "$level,$OPS_PER_LEVEL,$ok_count,$fail_count,$elapsed_s,$tps,$blocks_cut" >> "$SUMMARY_CSV"
  echo "   -> ${elapsed_s}s | ok=$ok_count fail=$fail_count | ${tps} tx/s | blocks=${blocks_cut}"

  [ "$fail_count" -gt 0 ] && echo "   WARNING: $fail_count failures — check MVCC / endorsement timeout"
done

echo ""
echo ">> Summary:"
column -t -s',' "$SUMMARY_CSV" 2>/dev/null || cat "$SUMMARY_CSV"