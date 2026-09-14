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

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

invoke() {
  local channel="$1" cc="$2" ctor="$3" transient="$4" caller="$5"; shift 5
  ./scripts/invokeCC.sh "$channel" "$cc" "$ctor" "$transient" "$caller" "$@"
}

query() {
  local org="$1" channel="$2" cc="$3" ctor="$4"
  ./scripts/queryCC.sh "$org" "$channel" "$cc" "$ctor"
}

# ---------------------------------------------------------------------------
# Patient ingestion (Warehouse Channel)
# ---------------------------------------------------------------------------
declare -a REFS WPS PIIS

for i in $(seq 1 "$N_PATIENTS"); do
  pii="teste1-$i"
  ref="ref-$(openssl rand -hex 16)"
  PIIS[$i]="$pii"
  REFS[$i]="$ref"

  infoln "Registrando paciente $i: $ref"

  # RegisterIdentityReference (IM + WPI)
  invoke "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
    '{"function":"RegisterIdentityReference","Args":[]}' \
    "{\"pii\":\"$pii\",\"identityReference\":\"$ref\"}" \
    OrgIM OrgIM OrgWPI

  # GetPii via WPI
  pii_back=""
  for attempt in 1 2 3 4 5; do
    pii_back=$(query OrgWPI "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
      "{\"function\":\"GetPii\",\"Args\":[\"$ref\"]}" 2>/dev/null || true)
    [ "$pii_back" == "$pii" ] && break
    sleep 2
  done
  if [ "$pii_back" != "$pii" ]; then
    errorln "GetPii retornou '$pii_back', esperado '$pii'"
    exit 1
  fi

  # WP client-side
  wp=$(node scripts/test/crypto-helper.js wp "$WP_MASTER_KEY" "$pii")
  WPS[$i]="$wp"

  # RegisterWP (WPI + HDW)
  invoke "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
    "{\"function\":\"RegisterWP\",\"Args\":[\"$ref\"]}" \
    "{\"wp\":\"$wp\"}" \
    OrgWPI OrgWPI OrgHDW

  # GetWP via HDW
 
  wp_back=""
  for attempt in 1 2 3 4 5; do
    wp_back=$(query OrgHDW "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
    "{\"function\":\"GetWP\",\"Args\":[\"$ref\"]}")
    [ "$wp_back" == "$wp" ] && break
    sleep 2
  done
  if [ "$wp_back" != "$wp" ]; then
    errorln "GetWP retornou '$wp_back', esperado '$wp'"
    exit 1
  fi

  # GetIdentityReferenceByWP (reverse index)
  ref_back=$(query OrgWPI "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
    "{\"function\":\"GetIdentityReferenceByWP\",\"Args\":[\"$wp\"]}")
  if [ "$ref_back" != "$ref" ]; then
    errorln "GetIdentityReferenceByWP retornou '$ref_back', esperado '$ref'"
    exit 1
  fi

  successln "Paciente $i OK"
done

# ---------------------------------------------------------------------------
# Datamarts (Study Channel)
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

  splist=$(query OrgSC "$CHANNEL_STUDY" "$CC_STUDY" \
  "{\"function\":\"GetSPListByDatamart\",\"Args\":[\"${DATAMARTS[1]}\"]}")

echo "keys in ${DATAMARTS[1]}: $(echo "$splist" | jq -r 'keys[]')"
echo "WPs of this run:        ${WPS[@]}"

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
# Unlinkability
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
        errorln "SP empty for WP $wp in $dm1/$dm2"
        exit 1
      fi

      if [ "$sp1" == "$sp2" ]; then
        errorln "FAILED unlinkability: same SP for WP $wp in $dm1 and $dm2"
        exit 1
      fi
    done
  done
  successln "Patient $i: different SPs between datamarts"
done

# ---------------------------------------------------------------------------
# Negative checks
# ---------------------------------------------------------------------------
infoln "Negative checks"
set +e

# HDW cant read Identity_Mapping
query OrgHDW "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
  "{\"function\":\"GetPii\",\"Args\":[\"${REFS[1]}\"]}" >/dev/null 2>&1
if [ $? -eq 0 ]; then
  errorln "FAILED: HDW was able to read Identity_Mapping"
  exit 1
fi

# RO cant read Identity_Mapping
query OrgRO "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
  "{\"function\":\"GetPii\",\"Args\":[\"${REFS[1]}\"]}" >/dev/null 2>&1
if [ $? -eq 0 ]; then
  errorln "FAILED: RO was able to read Identity_Mapping"
  exit 1
fi

# MO cant read Identity_Mapping
query OrgMO "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
  "{\"function\":\"GetPii\",\"Args\":[\"${REFS[1]}\"]}" >/dev/null 2>&1
if [ $? -eq 0 ]; then
  errorln "FAILED: MO was able to read Identity_Mapping"
  exit 1
fi

# IM cant read Warehouse_Mapping
query OrgIM "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
  "{\"function\":\"GetWP\",\"Args\":[\"${REFS[1]}\"]}" >/dev/null 2>&1
if [ $? -eq 0 ]; then
  errorln "FAILED: IM was able to read Warehouse_Mapping"
  exit 1
fi

# RO cant read Warehouse_Mapping
query OrgRO "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
  "{\"function\":\"GetPii\",\"Args\":[\"${REFS[1]}\"]}" >/dev/null 2>&1
if [ $? -eq 0 ]; then
  errorln "FAILED: RO was able to read Warehouse_Mapping"
  exit 1
fi

# MO cant read Warehouse_Mapping
query OrgMO "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
  "{\"function\":\"GetPii\",\"Args\":[\"${REFS[1]}\"]}" >/dev/null 2>&1
if [ $? -eq 0 ]; then
  errorln "FAILED: MO was able to read Warehouse_Mapping"
  exit 1
fi

# MO cant read Study_Mapping
query OrgMO "$CHANNEL_STUDY" "$CC_STUDY" \
  "{\"function\":\"GetSPListByDatamart\",\"Args\":[\"${DATAMARTS[1]}\"]}" >/dev/null 2>&1
if [ $? -eq 0 ]; then
  errorln "FAILED: MO was able to read Study_Mapping"
  exit 1
fi

# RO cant read Study_Mapping
query OrgRO "$CHANNEL_STUDY" "$CC_STUDY" \
  "{\"function\":\"GetSPListByDatamart\",\"Args\":[\"${DATAMARTS[1]}\"]}" >/dev/null 2>&1
if [ $? -eq 0 ]; then
  errorln "FAILED: RO was able to read Study_Mapping"
  exit 1
fi

set -e

successln "Todas as checagens passaram."