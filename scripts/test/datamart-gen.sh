#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
source scripts/utils.sh
source scripts/envvar.sh

CHANNEL_WAREHOUSE="${CHANNEL_WAREHOUSE:-warehouse-channel}"
CHANNEL_STUDY="${CHANNEL_STUDY:-study-channel}"
CC_IDENTITY="${CC_IDENTITY:-identity-mapping}"
CC_WAREHOUSE="${CC_WAREHOUSE:-warehouse-mapping}"
CC_STUDY="${CC_STUDY:-study-mapping}"

N_PATIENTS="${N_PATIENTS:-3}"
M_DATAMARTS="${M_DATAMARTS:-2}"
WP_MASTER_KEY="${WP_MASTER_KEY:-test-wp-master-key}"
SP_MASTER_KEY="${SP_MASTER_KEY:-test-sp-master-key}"
STUDY_ID="${STUDY_ID:-study-poc}"
RUN_ID="${RUN_ID:-$(openssl rand -hex 4)}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

invoke() {
  local channel="$1" cc="$2" ctor="$3" transient="$4" caller="$5"; shift 5
  ./scripts/invokeCC.sh "$channel" "$cc" "$ctor" "$transient" "$caller" "$@"
}

invoke_json_result() {
  local output payload
  output=$(invoke "$@" 2>&1) || {
    printf '%s\n' "$output" >&2
    return 1
  }
  printf '%s\n' "$output"

  payload=$(printf '%s\n' "$output" \
    | sed -n 's/.*payload:"\(.*\)".*/\1/p' \
    | tail -n1)
  if [ -z "$payload" ]; then
    errorln "Chaincode invoke response did not contain a payload" >&2
    return 1
  fi

  # peer prints JSON quotes escaped inside payload:"...".
  payload="${payload//\\\"/\"}"
  printf '%s\n' "$payload" | jq -c .
}

query() {
  local org="$1" channel="$2" cc="$3" ctor="$4"
  ./scripts/queryCC.sh "$org" "$channel" "$cc" "$ctor"
}

# ---------------------------------------------------------------------------
# 1) Batch ingestion on Warehouse Channel
#    - RegisterIdentityReferenceBatch(piis)  -> refs[]  (one tx)
#    - client computes WP = HMAC(wpKey, pii) for each PII
#    - RegisterWPBatch(pairs)                -> { count, imBatchId, mappingTxId }
#    - spot checks: GetPii / GetWP / GetIdentityReferenceByWP
# ---------------------------------------------------------------------------
declare -a PIIS REFS WPS

for i in $(seq 1 "$N_PATIENTS"); do
  PIIS[$i]="teste-${RUN_ID}-$i"
done

PIIS_JSON=$(printf '%s\n' "${PIIS[@]}" | jq -Rsc 'split("\n") | map(select(length > 0))')
infoln "Registering $N_PATIENTS identities in one batch"

# --- RegisterIdentityReferenceBatch ---
# invokeCC prints the invoke output; we take the last line, which is the
# JSON array of refs returned by the chaincode.
REFS_JSON=$(invoke_json_result "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
  '{"function":"RegisterIdentityReferenceBatch","Args":[]}' \
  "{\"piis\":$PIIS_JSON}" \
  OrgIM OrgIM OrgWPI | tail -n1)

mapfile -t REFS_ARR < <(echo "$REFS_JSON" | jq -r '.[]')
[ "${#REFS_ARR[@]}" -eq "$N_PATIENTS" ] \
  || { errorln "Expected $N_PATIENTS refs, got ${#REFS_ARR[@]}"; exit 1; }

for i in $(seq 1 "$N_PATIENTS"); do
  REFS[$i]="${REFS_ARR[$((i-1))]}"
done
successln "IM batch registered (${#REFS_ARR[@]} refs)"

# --- Compute WPs client-side and build pairs ---
PAIRS_JSON='[]'
for i in $(seq 1 "$N_PATIENTS"); do
  wp=$(node scripts/test/crypto-helper.js wp "$WP_MASTER_KEY" "${PIIS[$i]}")
  WPS[$i]="$wp"
  PAIRS_JSON=$(jq -c \
    --arg ref "${REFS[$i]}" \
    --arg wp "$wp" \
    '. + [{identityReference:$ref, wp:$wp}]' <<< "$PAIRS_JSON")
done

# --- RegisterWPBatch ---
MAP_RESULT=$(invoke_json_result "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
  '{"function":"RegisterWPBatch","Args":[]}' \
  "{\"pairs\":$PAIRS_JSON}" \
  OrgWPI OrgWPI OrgHDW | tail -n1)
IM_BATCH=$(echo "$MAP_RESULT" | jq -r .imBatchId)
MAP_TX=$(echo "$MAP_RESULT" | jq -r .mappingTxId)
successln "WP batch registered (imBatchId=$IM_BATCH, mappingTxId=$MAP_TX)"

# --- Consistency spot-checks (WPI can read both collections) ---
for i in $(seq 1 "$N_PATIENTS"); do
  ref="${REFS[$i]}"
  wp="${WPS[$i]}"

  pii_back=$(query OrgWPI "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
    "{\"function\":\"GetPii\",\"Args\":[\"$ref\"]}")
  [ "$pii_back" == "${PIIS[$i]}" ] \
    || { errorln "GetPii($ref) = '$pii_back', expected '${PIIS[$i]}'"; exit 1; }

  wp_back=$(query OrgWPI "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
    "{\"function\":\"GetWP\",\"Args\":[\"$ref\"]}")
  [ "$wp_back" == "$wp" ] \
    || { errorln "GetWP($ref) = '$wp_back', expected '$wp'"; exit 1; }

  ref_back=$(query OrgWPI "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
    "{\"function\":\"GetIdentityReferenceByWP\",\"Args\":[\"$wp\"]}")
  [ "$ref_back" == "$ref" ] \
    || { errorln "GetIdentityReferenceByWP($wp) = '$ref_back', expected '$ref'"; exit 1; }
done

successln "Warehouse batch ingestion OK"

# ---------------------------------------------------------------------------
# 2) Datamarts (Study Channel)
# ---------------------------------------------------------------------------
declare -a DATAMARTS

for d in $(seq 1 "$M_DATAMARTS"); do
  datamartId="datamart-$d"
  DATAMARTS[$d]="$datamartId"

  studyKey=$(node scripts/test/crypto-helper.js hkdf "$SP_MASTER_KEY" "$STUDY_ID" "$datamartId")
  wpListJson=$(printf '%s\n' "${WPS[@]}" | jq -R . | jq -s .)

  infoln "Registering datamart $datamartId with ${#WPS[@]} WPs"

  invoke "$CHANNEL_STUDY" "$CC_STUDY" \
    "{\"function\":\"RegisterSPBatch\",\"Args\":[\"$datamartId\"]}" \
    "{\"studyKey\":\"$studyKey\",\"wpList\":$wpListJson}" \
    OrgSPI OrgSPI OrgSC

  count=0
  for attempt in 1 2 3 4 5 6 7 8; do
    splist=$(query OrgSC "$CHANNEL_STUDY" "$CC_STUDY" \
      "{\"function\":\"GetSPListByDatamart\",\"Args\":[\"$datamartId\"]}")
    count=$(echo "$splist" | jq 'length')
    [ "$count" -eq "${#WPS[@]}" ] && break
    sleep 2
  done
  if [ "$count" -ne "${#WPS[@]}" ]; then
    errorln "GetSPListByDatamart returned $count pairs, expected ${#WPS[@]}"
    exit 1
  fi
  successln "Datamart $datamartId OK"
done

# ---------------------------------------------------------------------------
# 3) Unlinkability between datamarts
# ---------------------------------------------------------------------------
infoln "Checking unlinkability between datamarts"

for i in $(seq 1 "$N_PATIENTS"); do
  wp="${WPS[$i]}"
  for d1 in $(seq 1 "$M_DATAMARTS"); do
    for d2 in $(seq $((d1 + 1)) "$M_DATAMARTS"); do
      dm1="${DATAMARTS[$d1]}"
      dm2="${DATAMARTS[$d2]}"

      sp1=$(query OrgSC "$CHANNEL_STUDY" "$CC_STUDY" \
        "{\"function\":\"GetSPForWP\",\"Args\":[\"$dm1\",\"$wp\"]}")
      sp2=$(query OrgSC "$CHANNEL_STUDY" "$CC_STUDY" \
        "{\"function\":\"GetSPForWP\",\"Args\":[\"$dm2\",\"$wp\"]}")

      if [ -z "$sp1" ] || [ -z "$sp2" ]; then
        errorln "SP is empty for WP $wp in $dm1/$dm2"; exit 1
      fi
      if [ "$sp1" == "$sp2" ]; then
        errorln "FAILED unlinkability: same SP for WP $wp in $dm1 and $dm2"; exit 1
      fi
    done
  done
  successln "Patient $i: different SPs between datamarts"
done

# ---------------------------------------------------------------------------
# 4) Negative checks (ACL isolation)
# ---------------------------------------------------------------------------
infoln "Negative checks"
set +e

check_denied() {
  local desc="$1"; shift
  "$@" >/dev/null 2>&1
  local rc=$?
  if [ $rc -eq 0 ]; then
    errorln "FAILED: $desc"
    exit 1
  fi
}

check_denied "HDW was able to read Identity_Mapping" \
  query OrgHDW "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
  "{\"function\":\"GetPii\",\"Args\":[\"${REFS[1]}\"]}"

check_denied "RO was able to read Identity_Mapping" \
  query OrgRO "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
  "{\"function\":\"GetPii\",\"Args\":[\"${REFS[1]}\"]}"

check_denied "MO was able to read Identity_Mapping" \
  query OrgMO "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
  "{\"function\":\"GetPii\",\"Args\":[\"${REFS[1]}\"]}"

check_denied "IM was able to read Warehouse_Mapping" \
  query OrgIM "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
  "{\"function\":\"GetWP\",\"Args\":[\"${REFS[1]}\"]}"

check_denied "RO was able to read Warehouse_Mapping" \
  query OrgRO "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
  "{\"function\":\"GetWP\",\"Args\":[\"${REFS[1]}\"]}"

check_denied "MO was able to read Warehouse_Mapping" \
  query OrgMO "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
  "{\"function\":\"GetWP\",\"Args\":[\"${REFS[1]}\"]}"

check_denied "MO was able to read Study_Mapping" \
  query OrgMO "$CHANNEL_STUDY" "$CC_STUDY" \
  "{\"function\":\"GetSPListByDatamart\",\"Args\":[\"${DATAMARTS[1]}\"]}"

check_denied "RO was able to read Study_Mapping" \
  query OrgRO "$CHANNEL_STUDY" "$CC_STUDY" \
  "{\"function\":\"GetSPListByDatamart\",\"Args\":[\"${DATAMARTS[1]}\"]}"

set -e
successln "All checks passed."