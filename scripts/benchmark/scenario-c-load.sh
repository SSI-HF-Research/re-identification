#!/bin/bash
# Scenario C — load test. Sweeps concurrency levels.
# Env: LEVELS, OPS_PER_LEVEL

set -uo pipefail
export LC_ALL=C                          # <-- força decimal separator "."

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/benchmark/config.sh"
source "$ROOT/scripts/benchmark/lib.sh"

LEVELS="${LEVELS:-1 2 4 8 16}"
OPS_PER_LEVEL="${OPS_PER_LEVEL:-50}"

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

# ---------------------------------------------------------------------------
# Block height via the host-side peer CLI (same identity used by invokeCC.sh).
# Returns the height as an integer, or an empty string on failure.
# ---------------------------------------------------------------------------
height_of() {
  local channel="$1"
  (
    export PATH="$ROOT/bin:$PATH"
    export FABRIC_CFG_PATH="$ROOT/network"
    source "$ROOT/scripts/envvar.sh"
    setGlobalsForOrg OrgIM
    peer channel getinfo -c "$channel" 2>/dev/null
  ) | grep -o '{.*}' | jq -r '.height // empty' 2>/dev/null
}

# ---------------------------------------------------------------------------
# Main sweep
# ---------------------------------------------------------------------------
for level in $LEVELS; do
  CSV="$BENCH_DIR/scenario-c_level${level}.csv"
  ensure_csv_header "$CSV"
  echo ">> Concurrency level: $level ($OPS_PER_LEVEL operations)"

  h_before=$(height_of "$CHANNEL_WAREHOUSE")

  t0=$(now_ns)
  i=1
  while [ "$i" -le "$OPS_PER_LEVEL" ]; do
    batch_end=$(( i + level - 1 ))
    [ "$batch_end" -gt "$OPS_PER_LEVEL" ] && batch_end=$OPS_PER_LEVEL
    pids=()
    for ((j=i; j<=batch_end; j++)); do
      one_op "$j" "$CSV" &
      pids+=($!)
    done
    for pid in "${pids[@]}"; do
      wait "$pid" || true
    done
    i=$(( batch_end + 1 ))
  done
  t1=$(now_ns)

  # Small settle so the local peer has caught up to the last commit.
  sleep 1
  h_after=$(height_of "$CHANNEL_WAREHOUSE")

  if [ -n "$h_before" ] && [ -n "$h_after" ]; then
    blocks_cut=$(( h_after - h_before ))
  else
    blocks_cut="n/a"
    echo "   WARN: could not read channel height (h_before='$h_before' h_after='$h_after')" >&2
  fi

  elapsed_s=$(awk "BEGIN{printf \"%.3f\", ($t1-$t0)/1000000000}")
  ok_count=$(awk -F',' 'NR>1 && $3==1{c++} END{print c+0}' "$CSV")
  fail_count=$(awk -F',' 'NR>1 && $3==0{c++} END{print c+0}' "$CSV")
  tps=$(awk "BEGIN{printf \"%.2f\", $ok_count/$elapsed_s}")

  echo "$level,$OPS_PER_LEVEL,$ok_count,$fail_count,$elapsed_s,$tps,$blocks_cut" >> "$SUMMARY_CSV"
  echo "   -> ${elapsed_s}s | ok=$ok_count fail=$fail_count | ${tps} tx/s | blocks_cut=$blocks_cut"

  if [ "$fail_count" -gt 0 ]; then
    echo "   WARNING: $fail_count failures at this level"
  fi
done

echo ""
echo ">> Throughput summary by concurrency level:"
cat "$SUMMARY_CSV" | column -t -s',' -o '  '