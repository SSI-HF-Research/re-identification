#!/bin/bash
# Scenario A: ingest N patients into the warehouse channel and assemble
# datamarts on the study channel in batches of BATCH_SIZE.
#
# Covered metrics: M1 (pseudonymization per stage), M3 (read/write
# operations per PDC, implicit in each stage), M5 (partial), M6 (varying N,
# BATCH_SIZE, CONCURRENCY).
#
# Usage:
#   N_PATIENTS=200 BATCH_SIZE=20 CONCURRENCY=8 ./scenario-a-ingest.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/benchmark/config.sh"
source "$ROOT/scripts/benchmark/lib.sh"

CSV="$BENCH_DIR/scenario-a_N${N_PATIENTS}_batch${BATCH_SIZE}_conc${CONCURRENCY}.csv"
ensure_csv_header "$CSV"

STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$STATE_DIR"' EXIT

echo ">> Scenario A: N=$N_PATIENTS patients, batch=$BATCH_SIZE, concurrency=$CONCURRENCY"
echo ">> CSV: $CSV"

ingest_one_patient() {
  local idx="$1"
  local pii="benchmark-pii-${idx}-$(date +%s%N)"
  local ref="benchmark-ref-${idx}-$(openssl rand -hex 8)"
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

  local wp
  wp="$(node "$ROOT/scripts/test/crypto-helper.js" wp "$WP_MASTER_KEY" "$pii_out")"

  time_cmd "$CSV" "A3_register_wp" "$out" \
    "$ROOT/scripts/invokeCC.sh" "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
    "{\"function\":\"RegisterWP\",\"Args\":[\"$ref\"]}" \
    "{\"wp\":\"$wp\"}" \
    OrgWPI OrgWPI OrgHDW
  local rc=$?
  rm -f "$out"
  if [ $rc -ne 0 ]; then return 1; fi

  # Protect the append with flock because multiple ingest_one_patient instances run in parallel.
  {
    flock -x 201
    echo -e "${idx}\t${ref}\t${wp}" >> "$STATE_DIR/patients.tsv"
  } 201>>"$STATE_DIR/patients.tsv.lock"
}

echo ">> [Block A] Patient ingestion"
i=1
while [ "$i" -le "$N_PATIENTS" ]; do
  batch_end=$(( i + CONCURRENCY - 1 ))
  [ "$batch_end" -gt "$N_PATIENTS" ] && batch_end=$N_PATIENTS
  for ((j=i; j<=batch_end; j++)); do
    ingest_one_patient "$j" &
  done
  wait
  i=$(( batch_end + 1 ))
done

total_ingested=$(wc -l < "$STATE_DIR/patients.tsv" 2>/dev/null || echo 0)
echo ">> $total_ingested/$N_PATIENTS patients ingested successfully"

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
  datamart_id="benchmark-dm-${dm_idx}"

  wp_list_json="["
  first=true
  for ((k=start; k<end; k++)); do
    if [ "$first" = true ]; then first=false; else wp_list_json+=","; fi
    wp_list_json+="\"${all_wps[$k]}\""
  done
  wp_list_json+="]"

  study_key="$(node "$ROOT/scripts/test/crypto-helper.js" hkdf "$SP_MASTER_KEY" "$STUDY_ID" "$datamart_id")"

  out="$(mktemp)"
  time_cmd "$CSV" "A4_register_sp_batch_size$(( end - start ))" "$out" \
    "$ROOT/scripts/invokeCC.sh" "$CHANNEL_STUDY" "$CC_STUDY" \
    "{\"function\":\"RegisterSPBatch\",\"Args\":[\"$datamart_id\"]}" \
    "{\"studyKey\":\"$study_key\",\"wpList\":$wp_list_json}" \
    OrgSPI OrgSPI OrgSC
  rm -f "$out"

  start=$end
done

echo ""
echo ">> Scenario A completed."
echo ">> Raw CSV: $CSV"
echo ">> Run: python3 $ROOT/scripts/benchmark/analyze.py $CSV"
