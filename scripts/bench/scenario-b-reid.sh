#!/bin/bash
# ============================================================================
# scenario-b-reid.sh — Full re-identification flow (setup excluded).
#
# PURPOSE
#   Measures the complete SP → WP → ref → PII re-identification path,
#   including K-of-N committee approval, cross-channel transport, and
#   signature verification on the warehouse side.
#
# METRICS SERVED
#   M4 — total re-identification process:
#          B1 create_reid_request          (ledger write, study)
#          B2 ec_sign_1of2                 (ledger write, EC1)
#          B3 ec_sign_2of2_threshold       (ledger write, EC2)
#          B4 resolve_sp_to_wp             (PDC read, study-mapping)
#          B5 register_reid_result_study   (PDC write, study-reid)
#          B6 resolve_wp_to_ref            (PDC read, warehouse-mapping)
#          B7 resolve_ref_to_pii           (PDC read, identity-mapping)
#          B8 register_reidentified_pii    (PDC write, warehouse-reid)
#          B9 mo_reads_pii                 (PDC read, warehouse-reid)
#          B_TOTAL_reid_process            (aggregate, from B1 start to B9 end)
#   M5 — partial: this is the "→ PII" tail of the full e2e
#   M6 — scaling: sweep REPEAT and CONCURRENCY_REID
#
# VALUE
#   This is the defense number for the paper's Section 7. Setup is NOT
#   counted (patient + SP pre-exist). CONCURRENCY_REID > 1 gives the
#   multi-researcher scenario.
#
# CLI OVERHEAD
#   B_TOTAL_reid_process is a sum of 9 CLI invocations. The floor is
#   ~9 * BASELINE_MS for the raw measurement. Adjusted throughput =
#   raw - baseline. Report both.
#
# USAGE
#   REPEAT=30 CONCURRENCY_REID=4 ./scenario-b-reid.sh
# ============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/bench/config.sh"
source "$ROOT/scripts/bench/lib.sh"

CSV="$BENCH_DIR/scenario-b_repeat${REPEAT}_conc${CONCURRENCY_REID}.csv"
ensure_csv_header "$CSV"
DOCKERSTATS="$CSV.dockerstats"

echo ">> Scenario B: REPEAT=$REPEAT concurrency=$CONCURRENCY_REID"
echo ">> CSV: $CSV"

warmup_all

one_reid_cycle() {
  local run_id="$1"
  local out; out="$(mktemp)"
  local datamart_id="bench-reid-dm-${run_id}"

  # --- Setup (NOT timed) ---------------------------------------------------
  local pii="reid-pii-${run_id}-$(date +%s%N)"
  local ref="reid-ref-${run_id}-$(openssl rand -hex 8)"
  local wp; wp="$(compute_wp "$pii")"

  "$ROOT/scripts/invokeCC.sh" "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
    '{"function":"RegisterIdentityReference","Args":[]}' \
    "{\"pii\":\"$pii\",\"identityReference\":\"$ref\"}" OrgIM OrgIM OrgWPI >/dev/null 2>&1
  "$ROOT/scripts/invokeCC.sh" "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
    "{\"function\":\"RegisterWP\",\"Args\":[\"$ref\"]}" \
    "{\"wp\":\"$wp\"}" OrgWPI OrgWPI OrgHDW >/dev/null 2>&1

  local study_key; study_key="$(compute_study_key "$STUDY_ID" "$datamart_id")"
  "$ROOT/scripts/invokeCC.sh" "$CHANNEL_STUDY" "$CC_STUDY" \
    "{\"function\":\"RegisterSPBatch\",\"Args\":[\"$datamart_id\"]}" \
    "{\"studyKey\":\"$study_key\",\"wpList\":[\"$wp\"]}" OrgSPI OrgSPI OrgSC >/dev/null 2>&1

  local sp
  sp="$("$ROOT/scripts/queryCC.sh" OrgSC "$CHANNEL_STUDY" "$CC_STUDY" \
    "{\"function\":\"GetSPForWP\",\"Args\":[\"$datamart_id\",\"$wp\"]}")"

  # --- Timed re-id cycle ---------------------------------------------------
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
  local req_id; req_id="$(cat "$txfile")"; rm -f "$txfile"
  [ -z "$req_id" ] && { echo "  [ERROR] no reqId" >&2; rm -f "$out"; return 1; }

  local sig1; sig1="$(sign_approval ec1.example.com "$req_id" approve)"
  time_cmd "$CSV" "B2_ec_sign_1of2" "$out" \
    "$ROOT/scripts/invokeCC.sh" "$CHANNEL_STUDY" "$CC_SREID" \
    "{\"function\":\"SignReIDRequest\",\"Args\":[\"$req_id\",\"approve\",\"$sig1\"]}" \
    NA OrgEC1 OrgEC1 OrgEC2 OrgEC3 OrgSPI OrgRO
  [ $? -ne 0 ] && { rm -f "$out"; return 1; }

  local sig2; sig2="$(sign_approval ec2.example.com "$req_id" approve)"
  time_cmd "$CSV" "B3_ec_sign_2of2_threshold" "$out" \
    "$ROOT/scripts/invokeCC.sh" "$CHANNEL_STUDY" "$CC_SREID" \
    "{\"function\":\"SignReIDRequest\",\"Args\":[\"$req_id\",\"approve\",\"$sig2\"]}" \
    NA OrgEC2 OrgEC1 OrgEC2 OrgEC3 OrgSPI OrgRO
  [ $? -ne 0 ] && { rm -f "$out"; return 1; }

  time_cmd "$CSV" "B4_resolve_sp_to_wp" "$out" \
    "$ROOT/scripts/queryCC.sh" OrgSPI "$CHANNEL_STUDY" "$CC_STUDY" \
    "{\"function\":\"GetWPBySP\",\"Args\":[\"$sp\"]}"
  [ $? -ne 0 ] && { rm -f "$out"; return 1; }
  local wp_resolved; wp_resolved="$(cat "$out")"

  time_cmd "$CSV" "B5_register_reid_result_study" "$out" \
    "$ROOT/scripts/invokeCC.sh" "$CHANNEL_STUDY" "$CC_SREID" \
    "{\"function\":\"RegisterReIDResult\",\"Args\":[\"$req_id\"]}" \
    "{\"wp\":\"$wp_resolved\"}" OrgSPI OrgSPI OrgRO
  [ $? -ne 0 ] && { rm -f "$out"; return 1; }

  time_cmd "$CSV" "B6_resolve_wp_to_ref" "$out" \
    "$ROOT/scripts/queryCC.sh" OrgWPI "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
    "{\"function\":\"GetIdentityReferenceByWP\",\"Args\":[\"$wp_resolved\"]}"
  [ $? -ne 0 ] && { rm -f "$out"; return 1; }
  local ref_resolved; ref_resolved="$(cat "$out")"

  time_cmd "$CSV" "B7_resolve_ref_to_pii" "$out" \
    "$ROOT/scripts/queryCC.sh" OrgWPI "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
    "{\"function\":\"GetPii\",\"Args\":[\"$ref_resolved\"]}"
  [ $? -ne 0 ] && { rm -f "$out"; return 1; }
  local pii_resolved; pii_resolved="$(cat "$out")"

  local approvals_json
  approvals_json="$("$ROOT/scripts/queryCC.sh" OrgRO "$CHANNEL_STUDY" "$CC_SREID" \
    "{\"function\":\"GetReIDApprovals\",\"Args\":[\"$req_id\"]}")"

  time_cmd "$CSV" "B8_register_reidentified_pii" "$out" \
    "$ROOT/scripts/invokeCC.sh" "$CHANNEL_WAREHOUSE" "$CC_WREID" \
    "{\"function\":\"RegisterReIdentifiedPII\",\"Args\":[\"$req_id\"]}" \
    "{\"pii\":\"$pii_resolved\",\"approvals\":$approvals_json}" \
    OrgWPI OrgWPI OrgMO OrgEC1 OrgEC2
  [ $? -ne 0 ] && { rm -f "$out"; return 1; }

  time_cmd "$CSV" "B9_mo_reads_pii" "$out" \
    "$ROOT/scripts/queryCC.sh" OrgMO "$CHANNEL_WAREHOUSE" "$CC_WREID" \
    "{\"function\":\"GetReidentifiedPII\",\"Args\":[\"$req_id\"]}"
  rc=$?
  rm -f "$out"
  [ $rc -ne 0 ] && return 1

  local t_total_end; t_total_end=$(now_ns)
  local total_ms=$(( (t_total_end - t_total_start) / 1000000 ))
  local ts; ts=$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)
  { flock -x 200
    echo "B_TOTAL_reid_process,${total_ms},1,${ts}" >> "$CSV"
  } 200>>"${CSV}.lock"
}

start_docker_stats "$DOCKERSTATS"
i=1
while [ "$i" -le "$REPEAT" ]; do
  batch_end=$(( i + CONCURRENCY_REID - 1 ))
  [ "$batch_end" -gt "$REPEAT" ] && batch_end=$REPEAT
  pids=()
  for ((j=i; j<=batch_end; j++)); do
    one_reid_cycle "$j" & pids+=($!)
  done
  failed=$(wait_all_pids "${pids[@]}")
  [ "$failed" -gt 0 ] && echo "   ATENCAO: $failed cycles failed in [$i..$batch_end]" >&2
  i=$(( batch_end + 1 ))
done
stop_docker_stats "$DOCKERSTATS"

echo ""
echo ">> Scenario B complete. CSV: $CSV"
echo ">> Analyze: python3 $ROOT/scripts/bench/analyze.py $CSV --warmup 3 --baseline $BASELINE_MS"