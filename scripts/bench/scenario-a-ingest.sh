#!/bin/bash
# ============================================================================
# scenario-a-ingest.sh — Batch ingestion: N patients → M datamarts.
#
# PURPOSE
#   Measures the pseudonymization pipeline end-to-end and the cost of
#   assembling datamarts. This is the "how does patient onboarding scale"
#   benchmark.
#
# METRICS SERVED
#   M1 — pseudonymization time per level:
#          A1 register_identity (PII → ref)
#          A2 get_pii           (PDC read, needed for client-side WP)
#          A3 register_wp       (ref → WP)
#          A4 register_sp_batch (WP → SP, batched)
#   M3 — implicit PDC read/write latencies (each label is one operation)
#   M5 — partial: pipeline up to WP/SP, feeding the end-to-end number
#   M6 — scaling: sweep N_PATIENTS, BATCH_SIZE, CONCURRENCY
#
# VALUE
#   Isolates which pseudonymization step is the bottleneck. RegisterWP writes
#   two PDC entries (ref: and wp:); RegisterIdentityReference writes one.
#   Comparing A1 vs A3 shows the cost of the reverse index.
#
# CLI OVERHEAD
#   Subtract BASELINE_MS (from scenario-f) to get the chaincode-only cost.
#
# USAGE
#   N_PATIENTS=200 BATCH_SIZE=20 CONCURRENCY=8 ./scenario-a-ingest.sh
# ============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/bench/config.sh"
source "$ROOT/scripts/bench/lib.sh"

CSV="$BENCH_DIR/scenario-a_N${N_PATIENTS}_batch${BATCH_SIZE}_conc${CONCURRENCY}.csv"
ensure_csv_header "$CSV"
DOCKERSTATS="$CSV.dockerstats"

echo ">> Scenario A: N=$N_PATIENTS batch=$BATCH_SIZE concurrency=$CONCURRENCY"
echo ">> CSV: $CSV"

warmup_all

STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$STATE_DIR"' EXIT

ingest_one_patient() {
  local idx="$1"
  local pii="bench-pii-${idx}-$(date +%s%N)"
  local ref="bench-ref-${idx}-$(openssl rand -hex 8)"
  local out; out="$(mktemp)"

  time_cmd "$CSV" "A1_register_identity" "$out" \
    "$ROOT/scripts/invokeCC.sh" "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
    '{"function":"RegisterIdentityReference","Args":[]}' \
    "{\"pii\":\"$pii\",\"identityReference\":\"$ref\"}" \
    OrgIM OrgIM OrgWPI
  if [ $? -ne 0 ]; then rm -f "$out"; return 1; fi

  time_cmd "$CSV" "A2_get_pii" "$out" \
    "$ROOT/scripts/queryCC.sh" OrgWPI "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
    "{\"function\":\"GetPii\",\"Args\":[\"$ref\"]}"
  if [ $? -ne 0 ]; then rm -f "$out"; return 1; fi
  local pii_out; pii_out="$(cat "$out")"

  local wp; wp="$(compute_wp "$pii_out")"

  time_cmd "$CSV" "A3_register_wp" "$out" \
    "$ROOT/scripts/invokeCC.sh" "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
    "{\"function\":\"RegisterWP\",\"Args\":[\"$ref\"]}" \
    "{\"wp\":\"$wp\"}" OrgWPI OrgWPI OrgHDW
  local rc=$?
  rm -f "$out"
  if [ $rc -ne 0 ]; then return 1; fi

  { flock -x 201
    echo -e "${idx}\t${ref}\t${wp}" >> "$STATE_DIR/patients.tsv"
  } 201>>"$STATE_DIR/patients.tsv.lock"
}

start_docker_stats "$DOCKERSTATS"

echo ">> [Block A] Patient ingestion"
i=1
while [ "$i" -le "$N_PATIENTS" ]; do
  batch_end=$(( i + CONCURRENCY - 1 ))
  [ "$batch_end" -gt "$N_PATIENTS" ] && batch_end=$N_PATIENTS
  pids=()
  for ((j=i; j<=batch_end; j++)); do
    ingest_one_patient "$j" & pids+=($!)
  done
  failed=$(wait_all_pids "${pids[@]}")
  [ "$failed" -gt 0 ] && echo "   ATENCAO: $failed failures in [$i..$batch_end]" >&2
  i=$(( batch_end + 1 ))
done

total_ingested=$(wc -l < "$STATE_DIR/patients.tsv" 2>/dev/null || echo 0)
echo ">> $total_ingested/$N_PATIENTS patients ingested"

echo ""
echo ">> [Block B] Datamart assembly (batches of $BATCH_SIZE)"
mapfile -t all_wps < <(cut -f3 "$STATE_DIR/patients.tsv" 2>/dev/null)
total=${#all_wps[@]}
dm_idx=0
start=0
while [ "$start" -lt "$total" ]; do
  end=$(( start + BATCH_SIZE ))
  [ "$end" -gt "$total" ] && end=$total
  dm_idx=$(( dm_idx + 1 ))
  datamart_id="bench-dm-${dm_idx}"

  wp_list_json="["
  first=true
  for ((k=start; k<end; k++)); do
    if [ "$first" = true ]; then first=false; else wp_list_json+=","; fi
    wp_list_json+="\"${all_wps[$k]}\""
  done
  wp_list_json+="]"

  study_key="$(compute_study_key "$STUDY_ID" "$datamart_id")"
  out="$(mktemp)"
  time_cmd "$CSV" "A4_register_sp_batch_size$(( end - start ))" "$out" \
    "$ROOT/scripts/invokeCC.sh" "$CHANNEL_STUDY" "$CC_STUDY" \
    "{\"function\":\"RegisterSPBatch\",\"Args\":[\"$datamart_id\"]}" \
    "{\"studyKey\":\"$study_key\",\"wpList\":$wp_list_json}" \
    OrgSPI OrgSPI OrgSC
  rm -f "$out"
  start=$end
done

stop_docker_stats "$DOCKERSTATS"

echo ""
echo ">> Scenario A complete. CSV: $CSV"
echo ">> Analyze: python3 $ROOT/scripts/bench/analyze.py $CSV --warmup 5 --baseline $BASELINE_MS"