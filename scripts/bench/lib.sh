#!/bin/bash
# ============================================================================
# lib.sh — Shared helpers for the benchmark suite.
#
# PURPOSE
#   Timing primitives, CSV recording, warmup, parallel job management,
#   docker stats capture, and convenience wrappers around invokeCC/queryCC.
#
# METRICS SERVED
#   All of them. Every scenario uses time_cmd() to record samples to a CSV
#   with the schema:  label,duration_ms,success,timestamp
#
# CLI OVERHEAD MITIGATION
#   - warmup_all():    cold-start amortization
#   - start/stop_docker_stats(): infra correlation
#   - wait_all_pids(): prevents silent job failures from corrupting sample counts
#   - time_cmd() uses `date +%s%N` (nanosecond resolution, ms precision) —
#     the correct granularity for operations that take hundreds of ms.
# ============================================================================

set -uo pipefail

BENCH_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Timing
# ---------------------------------------------------------------------------
now_ns() { date +%s%N; }
now_ms() { echo $(( $(date +%s%N) / 1000000 )); }

# time_cmd <csv> <label> <out_file> <cmd...>
#   Runs cmd, captures stdout+stderr into out_file, appends a CSV row:
#     label,duration_ms,success_0_or_1,utc_timestamp
#   flock protects the CSV from concurrent writers.
time_cmd() {
  local csv="$1" label="$2" out_file="$3"; shift 3
  local t0 t1 rc
  t0=$(now_ns)
  "$@" > "$out_file" 2>&1
  rc=$?
  t1=$(now_ns)
  local dur_ms=$(( (t1 - t0) / 1000000 ))
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
  local success=1; [ $rc -ne 0 ] && success=0
  {
    flock -x 202
    echo "${label},${dur_ms},${success},${ts}" >> "$csv"
  } 202>>"${csv}.lock"
  return $rc
}

ensure_csv_header() {
  local csv="$1"
  [ -f "$csv" ] || echo "label,duration_ms,success,timestamp" > "$csv"
}

# ---------------------------------------------------------------------------
# Warmup — pays container start / gRPC channel setup costs before measuring
# ---------------------------------------------------------------------------
warmup_all() {
  [ "${WARMUP_ENABLED}" = "1" ] || return 0
  echo ">> Warmup: touching every chaincode (cold-start amortization)"

  local rc=0
  "$ROOT/scripts/queryCC.sh" OrgIM  "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" '{"function":"testChaincode","Args":[]}' >/dev/null 2>&1 || rc=1
  "$ROOT/scripts/queryCC.sh" OrgWPI "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" '{"function":"testChaincode","Args":[]}' >/dev/null 2>&1 || rc=1
  "$ROOT/scripts/queryCC.sh" OrgSPI "$CHANNEL_STUDY"    "$CC_STUDY"    '{"function":"testChaincode","Args":[]}' >/dev/null 2>&1 || rc=1
  "$ROOT/scripts/queryCC.sh" OrgSPI "$CHANNEL_STUDY"    "$CC_SREID"    '{"function":"testChaincode","Args":[]}' >/dev/null 2>&1 || rc=1
  "$ROOT/scripts/queryCC.sh" OrgWPI "$CHANNEL_WAREHOUSE" "$CC_WREID"   '{"function":"testChaincode","Args":[]}' >/dev/null 2>&1 || rc=1

  [ $rc -eq 0 ] && echo "   warmup ok" || echo "   warmup completed with warnings"
  return 0
}

# ---------------------------------------------------------------------------
# Parallel jobs
# ---------------------------------------------------------------------------
# wait_all_pids <pid...>  -> prints number of failures on stdout
wait_all_pids() {
  local failed=0
  for pid in "$@"; do
    wait "$pid" || failed=$(( failed + 1 ))
  done
  echo "$failed"
}

# ---------------------------------------------------------------------------
# Channel height (used by scenario C to report blocks_cut)
# ---------------------------------------------------------------------------
channel_height() {
  local org="$1" channel="$2"
  ( source "$ROOT/scripts/envvar.sh"
    setGlobalsForOrg "$org" >/dev/null 2>&1
    peer channel getinfo -c "$channel" 2>/dev/null | jq -r '.height // 0'
  ) 2>/dev/null || echo 0
}

# ---------------------------------------------------------------------------
# docker stats
# ---------------------------------------------------------------------------
start_docker_stats() {
  [ "${COLLECT_DOCKER_STATS}" = "1" ] || return 0
  local out_file="$1"
  : > "$out_file"
  docker stats --format '{{.Name}},{{.CPUPerc}},{{.MemUsage}}' --no-trunc \
    >> "$out_file" 2>/dev/null &
  echo $! > "${out_file}.pid"
}

stop_docker_stats() {
  [ "${COLLECT_DOCKER_STATS}" = "1" ] || return 0
  local out_file="$1"
  if [ -f "${out_file}.pid" ]; then
    kill "$(cat "${out_file}.pid")" 2>/dev/null || true
    rm -f "${out_file}.pid"
  fi
}

# ---------------------------------------------------------------------------
# Fabric wrappers (thin, just so scripts read more cleanly)
# ---------------------------------------------------------------------------
invoke() {
  local channel="$1" cc="$2" ctor="$3" transient="$4" caller="$5"; shift 5
  "$ROOT/scripts/invokeCC.sh" "$channel" "$cc" "$ctor" "$transient" "$caller" "$@"
}

query() {
  local org="$1" channel="$2" cc="$3" ctor="$4"
  "$ROOT/scripts/queryCC.sh" "$org" "$channel" "$cc" "$ctor"
}

# ---------------------------------------------------------------------------
# Crypto helpers
# ---------------------------------------------------------------------------
compute_wp()        { node "$ROOT/scripts/test/crypto-helper.js" wp   "$WP_MASTER_KEY" "$1"; }
compute_study_key() { node "$ROOT/scripts/test/crypto-helper.js" hkdf "$SP_MASTER_KEY" "$1" "$2"; }
compute_sp()        { node "$ROOT/scripts/test/crypto-helper.js" sp   "$1" "$2"; }
sign_approval()     { node "$ROOT/scripts/test/ec-sign.js" sign "$1" "reid_approval:$2:$3"; }