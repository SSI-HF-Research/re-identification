#!/bin/bash
# Scenario B — full re-identification cycle.
# Env: REPEAT, CONCURRENCY_REID

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/benchmark/config.sh"
source "$ROOT/scripts/benchmark/lib.sh"

REPEAT="${REPEAT:-100}"
CONCURRENCY_REID="${CONCURRENCY_REID:-1}"

CSV="$BENCH_DIR/scenario-b_repeat${REPEAT}_conc${CONCURRENCY_REID}.csv"
ensure_csv_header "$CSV"

echo ">> Scenario B: $REPEAT re-identification cycles, concurrency=$CONCURRENCY_REID"
echo ">> CSV: $CSV"

warmup_all

# ---------------------------------------------------------------------------
# One re-identification cycle (target setup not counted)
# ---------------------------------------------------------------------------
one_reid_cycle() {
  local run_id="$1"
  local out; out="$(mktemp)"
  local datamart_id="bench-reid-dm-${run_id}"

  # --- Setup (NOT measured) ---
  local pii="reid-pii-${run_id}-$(date +%s%N)"
  local ref="reid-ref-${run_id}-$(openssl rand -hex 8)"
  local wp; wp="$(node "$ROOT/scripts/test/crypto-helper.js" wp "$WP_MASTER_KEY" "$pii")"

  "$ROOT/scripts/invokeCC.sh" "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
    '{"function":"RegisterIdentityReference","Args":[]}' \
    "{\"pii\":\"$pii\",\"identityReference\":\"$ref\"}" \
    OrgIM OrgIM OrgWPI >/dev/null 2>&1

  "$ROOT/scripts/invokeCC.sh" "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
    "{\"function\":\"RegisterWP\",\"Args\":[\"$ref\"]}" \
    "{\"wp\":\"$wp\"}" OrgWPI OrgWPI OrgHDW >/dev/null 2>&1

  local study_key
  study_key="$(node "$ROOT/scripts/test/crypto-helper.js" hkdf "$SP_MASTER_KEY" "$STUDY_ID" "$datamart_id")"
  "$ROOT/scripts/invokeCC.sh" "$CHANNEL_STUDY" "$CC_STUDY" \
    "{\"function\":\"RegisterSPBatch\",\"Args\":[\"$datamart_id\"]}" \
    "{\"studyKey\":\"$study_key\",\"wpList\":[\"$wp\"]}" \
    OrgSPI OrgSPI OrgSC >/dev/null 2>&1

  local sp
  sp="$("$ROOT/scripts/queryCC.sh" OrgSC "$CHANNEL_STUDY" "$CC_STUDY" \
    "{\"function\":\"GetSPForWP\",\"Args\":[\"$datamart_id\",\"$wp\"]}")"

  # --- Re-identification (MEASURED from here) ---
  local t_total_start; t_total_start=$(now_ns)

  local txfile; txfile="$(mktemp)"
  export CAPTURE_TXID_FILE="$txfile"
  time_cmd "$CSV" "B1_create_reid_request" "$out" \
    "$ROOT/scripts/invokeCC.sh" "$CHANNEL_STUDY" "$CC_SREID" \
    "{\"function\":\"CreateReIDRequest\",\"Args\":[\"$STUDY_ID\",\"$datamart_id\",\"$sp\"]}" \
    NA OrgRO OrgRO OrgSPI OrgSC OrgEC1 OrgEC2
  local rc=$?
  unset CAPTURE_TXID_FILE
  if [ $rc -ne 0 ]; then rm -f "$out" "$txfile"; return 1; fi
  local req_id; req_id="$(cat "$txfile")"
  rm -f "$txfile"
  if [ -z "$req_id" ]; then
    echo "  [ERROR] reqId not captured" >&2; rm -f "$out"; return 1
  fi

  local sig1
  sig1="$(node "$ROOT/scripts/test/ec-sign.js" sign ec1.example.com "reid_approval:${req_id}:approve")"
  time_cmd "$CSV" "B2_ec_sign_1of2" "$out" \
    "$ROOT/scripts/invokeCC.sh" "$CHANNEL_STUDY" "$CC_SREID" \
    "{\"function\":\"SignReIDRequest\",\"Args\":[\"$req_id\",\"approve\",\"$sig1\"]}" \
    NA OrgEC1 OrgEC1 OrgEC2 OrgEC3 OrgSPI OrgRO
  if [ $? -ne 0 ]; then rm -f "$out"; return 1; fi

  local sig2
  sig2="$(node "$ROOT/scripts/test/ec-sign.js" sign ec2.example.com "reid_approval:${req_id}:approve")"
  time_cmd "$CSV" "B3_ec_sign_2of2_threshold" "$out" \
    "$ROOT/scripts/invokeCC.sh" "$CHANNEL_STUDY" "$CC_SREID" \
    "{\"function\":\"SignReIDRequest\",\"Args\":[\"$req_id\",\"approve\",\"$sig2\"]}" \
    NA OrgEC2 OrgEC1 OrgEC2 OrgEC3 OrgSPI OrgRO
  if [ $? -ne 0 ]; then rm -f "$out"; return 1; fi

  time_cmd "$CSV" "B4_resolve_sp_to_wp" "$out" \
    "$ROOT/scripts/queryCC.sh" OrgSPI "$CHANNEL_STUDY" "$CC_STUDY" \
    "{\"function\":\"GetWPBySP\",\"Args\":[\"$sp\"]}"
  if [ $? -ne 0 ]; then rm -f "$out"; return 1; fi
  local wp_resolved; wp_resolved="$(cat "$out")"

  time_cmd "$CSV" "B5_register_reid_result_study" "$out" \
    "$ROOT/scripts/invokeCC.sh" "$CHANNEL_STUDY" "$CC_SREID" \
    "{\"function\":\"RegisterReIDResult\",\"Args\":[\"$req_id\"]}" \
    "{\"wp\":\"$wp_resolved\"}" OrgSPI OrgSPI OrgRO
  if [ $? -ne 0 ]; then rm -f "$out"; return 1; fi

  time_cmd "$CSV" "B6_resolve_wp_to_ref" "$out" \
    "$ROOT/scripts/queryCC.sh" OrgWPI "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
    "{\"function\":\"GetIdentityReferenceByWP\",\"Args\":[\"$wp_resolved\"]}"
  if [ $? -ne 0 ]; then rm -f "$out"; return 1; fi
  local ref_resolved; ref_resolved="$(cat "$out")"

  time_cmd "$CSV" "B7_resolve_ref_to_pii" "$out" \
    "$ROOT/scripts/queryCC.sh" OrgWPI "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
    "{\"function\":\"GetPii\",\"Args\":[\"$ref_resolved\"]}"
  if [ $? -ne 0 ]; then rm -f "$out"; return 1; fi
  local pii_resolved; pii_resolved="$(cat "$out")"

  local approvals_json
  approvals_json="$("$ROOT/scripts/queryCC.sh" OrgRO "$CHANNEL_STUDY" "$CC_SREID" \
    "{\"function\":\"GetReIDApprovals\",\"Args\":[\"$req_id\"]}")"

  time_cmd "$CSV" "B8_register_reidentified_pii" "$out" \
    "$ROOT/scripts/invokeCC.sh" "$CHANNEL_WAREHOUSE" "$CC_WREID" \
    "{\"function\":\"RegisterReIdentifiedPII\",\"Args\":[\"$req_id\"]}" \
    "{\"pii\":\"$pii_resolved\",\"approvals\":$approvals_json}" \
    OrgWPI OrgWPI OrgMO OrgEC1 OrgEC2
  if [ $? -ne 0 ]; then rm -f "$out"; return 1; fi

  time_cmd "$CSV" "B9_mo_reads_pii" "$out" \
    "$ROOT/scripts/queryCC.sh" OrgMO "$CHANNEL_WAREHOUSE" "$CC_WREID" \
    "{\"function\":\"GetReidentifiedPII\",\"Args\":[\"$req_id\"]}"
  rc=$?
  rm -f "$out"
  if [ $rc -ne 0 ]; then return 1; fi

  local t_total_end; t_total_end=$(now_ns)
  local total_ms=$(( (t_total_end - t_total_start) / 1000000 ))
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
  {
    flock -x 200
    echo "B_TOTAL_reid_process,${total_ms},1,${ts}" >> "$CSV"
  } 200>>"${CSV}.lock"
}

# ---------------------------------------------------------------------------
# Run cycles with per-PID failure tracking
# ---------------------------------------------------------------------------
i=1
total_failed=0
while [ "$i" -le "$REPEAT" ]; do
  batch_end=$(( i + CONCURRENCY_REID - 1 ))
  [ "$batch_end" -gt "$REPEAT" ] && batch_end=$REPEAT
  run_parallel one_reid_cycle "$i" "$batch_end"
  rc=$?
  [ $rc -gt 0 ] && total_failed=$(( total_failed + rc ))
  i=$(( batch_end + 1 ))
done

echo ""
if [ $total_failed -gt 0 ]; then
  echo ">> WARNING: $total_failed cycles failed"
fi
echo ">> Scenario B completed."
echo ">> Raw CSV: $CSV"
echo ">> Run: python3 $ROOT/scripts/benchmark/analyze.py $CSV --warmup 5"