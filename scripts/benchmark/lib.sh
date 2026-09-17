#!/bin/bash
# lib.sh 

set -uo pipefail

# ---------------------------------------------------------------------------
# Timing
# ---------------------------------------------------------------------------
now_ns() { date +%s%N; }

# time_cmd <csv> <label> <out_file> <cmd...>
time_cmd() {
  local csv="$1" label="$2" out_file="$3"; shift 3
  local t0 t1 rc
  t0=$(now_ns)
  set +e
  "$@" > "$out_file" 2>&1
  rc=$?
  set -e
  t1=$(now_ns)
  local ms=$(( (t1 - t0) / 1000000 ))
  local success=1
  [ $rc -ne 0 ] && success=0
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
  {
    flock -x 199
    echo "${label},${ms},${success},${ts}" >> "$csv"
  } 199>>"${csv}.lock"
  return $rc
}

ensure_csv_header() {
  local csv="$1"
  echo "label,duration_ms,success,timestamp" > "$csv"   
}

# ---------------------------------------------------------------------------
# Warmup
# ---------------------------------------------------------------------------
warmup_all() {
  echo ">> Warmup"
  local org_cc_pairs=(
    "OrgIM:$CHANNEL_WAREHOUSE:$CC_IDENTITY"
    "OrgWPI:$CHANNEL_WAREHOUSE:$CC_WAREHOUSE"
    "OrgWPI:$CHANNEL_WAREHOUSE:$CC_WREID"
    "OrgSPI:$CHANNEL_STUDY:$CC_STUDY"
    "OrgSPI:$CHANNEL_STUDY:$CC_SREID"
  )
  for pair in "${org_cc_pairs[@]}"; do
    IFS=':' read -r org chan cc <<< "$pair"
    "$ROOT/scripts/queryCC.sh" "$org" "$chan" "$cc" \
      '{"function":"testChaincode","Args":[]}' >/dev/null 2>&1 || true
  done
  echo ">> Warmup concluído."
}

# ---------------------------------------------------------------------------
# Parallel job runner with per-PID failure tracking
# run_parallel <fn_name> <start> <end>
# ---------------------------------------------------------------------------
run_parallel() {
  local fn="$1" start="$2" end="$3"
  local -a pids=()
  for ((j=start; j<=end; j++)); do
    "$fn" "$j" &
    pids+=($!)
  done
  local failed=0
  for pid in "${pids[@]}"; do
    wait "$pid" || failed=$(( failed + 1 ))
  done
  return $failed
}

# ---------------------------------------------------------------------------
# Channel height helper
# ---------------------------------------------------------------------------
channel_height() {
  local channel="$1" org="$2"
  local out
  out=$("$ROOT/scripts/queryCC.sh" "$org" "$channel" "_lifecycle" \
        '{"function":"QueryChaincodeDefinition","Args":[]}' 2>/dev/null || true)
  # fallback via peer CLI:
  local msp_id
  case "$org" in
    OrgIM)  msp_id="OrgIMMSP";;
    OrgWPI) msp_id="OrgWPIMSP";;
    OrgHDW) msp_id="OrgHDWMSP";;
    OrgSC)  msp_id="OrgSCMSP";;
    OrgSPI) msp_id="OrgSPIMSP";;
    OrgRO)  msp_id="OrgROMSP";;
    OrgMO)  msp_id="OrgMOMSP";;
  esac
  "$ROOT/scripts/envvar.sh" >/dev/null 2>&1 || true
  source "$ROOT/scripts/envvar.sh"
  "set${org#Org}" 2>/dev/null || true
  peer channel getinfo -c "$channel" 2>/dev/null | jq -r '.height' 2>/dev/null || echo 0
}