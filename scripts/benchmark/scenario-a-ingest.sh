#!/bin/bash
# Scenario A — patient ingestion + datamart assembly.
# Env: N_PATIENTS, BATCH_SIZE, CONCURRENCY

set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/benchmark/config.sh"
source "$ROOT/scripts/benchmark/lib.sh"

N_PATIENTS="${N_PATIENTS:-1000}"
BATCH_SIZE="${BATCH_SIZE:-50}"
CONCURRENCY="${CONCURRENCY:-8}"

CSV="$BENCH_DIR/scenario-a_N${N_PATIENTS}_batch${BATCH_SIZE}_conc${CONCURRENCY}.csv"
ensure_csv_header "$CSV"

STATE_DIR="$(mktemp -d)"
trap 'rm -rf "$STATE_DIR"' EXIT

echo ">> Scenario A: N=$N_PATIENTS patients, batch=$BATCH_SIZE, concurrency=$CONCURRENCY"
echo ">> CSV: $CSV"

warmup_all

# ---------------------------------------------------------------------------
# One patient: ref + get_pii + WP + register_wp
# ---------------------------------------------------------------------------
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

  {
    flock -x 201
    printf '%s\t%s\t%s\n' "$idx" "$ref" "$wp" >> "$STATE_DIR/patients.tsv"
  } 201>>"$STATE_DIR/patients.tsv.lock"
}

# ---------------------------------------------------------------------------
# Block A — patients
# ---------------------------------------------------------------------------
echo ">> [Block A] Patient ingestion"
i=1
total_failed=0
while [ "$i" -le "$N_PATIENTS" ]; do
  batch_end=$(( i + CONCURRENCY - 1 ))
  [ "$batch_end" -gt "$N_PATIENTS" ] && batch_end=$N_PATIENTS
  if ! run_parallel ingest_one_patient "$i" "$batch_end"; then
    total_failed=$(( total_failed + $? ))
  fi
  i=$(( batch_end + 1 ))
done

total_ingested=$(wc -l < "$STATE_DIR/patients.tsv" 2>/dev/null || echo 0)
echo ">> $total_ingested/$N_PATIENTS patients ingested successfully (failures=$total_failed)"

# ---------------------------------------------------------------------------
# Block B — datamarts
# ---------------------------------------------------------------------------
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
  size=$(( end - start ))

  wp_list_json="["
  first=true
  for ((k=start; k<end; k++)); do
    if [ "$first" = true ]; then first=false; else wp_list_json+=","; fi
    wp_list_json+="\"${all_wps[$k]}\""
  done
  wp_list_json+="]"

  study_key="$(node "$ROOT/scripts/test/crypto-helper.js" hkdf "$SP_MASTER_KEY" "$STUDY_ID" "$datamart_id")"

  out="$(mktemp)"
  time_cmd "$CSV" "A4_register_sp_batch_size${size}" "$out" \
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
echo ">> Run: python3 $ROOT/scripts/benchmark/analyze.py $CSV --warmup 5"