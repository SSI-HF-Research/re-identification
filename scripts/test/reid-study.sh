#!/bin/bash
set -euo pipefail

# Study-side flow of a re-identification process:
# create request -> collect K-of-N EC approvals -> SPI resolves SP -> WP
# -> SPI attests (reqId, WP) -> RO fetches the bundle for the warehouse side.

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
source scripts/utils.sh

invoke_capture_txid() {
  local out_file="$1"; shift
  local output rc=0
  output=$(CAPTURE_TXID_FILE="$out_file" ./scripts/invokeCC.sh "$@" 2>&1) || rc=$?
  echo "$output"
  if [ "$rc" -ne 0 ]; then
    errorln "  >> invokeCC.sh rc=$rc"
    return "$rc"
  fi
}

CHANNEL_STUDY="${CHANNEL_STUDY:-study-channel}"
CC_STUDY="${CC_STUDY:-study-mapping}"
CC_SREID="${CC_SREID:-study-reidentification}"
CHANNEL_WAREHOUSE="${CHANNEL_WAREHOUSE:-warehouse-channel}"
CC_IDENTITY="${CC_IDENTITY:-identity-mapping}"
CC_WAREHOUSE="${CC_WAREHOUSE:-warehouse-mapping}"

WP_MASTER_KEY="${WP_MASTER_KEY:-test-wp-master-key}"
SP_MASTER_KEY="${SP_MASTER_KEY:-test-sp-master-key}"
STUDY_ID="${STUDY_ID:-study-id-1}"
DATAMART_ID="${DATAMART_ID:-dm-1}"

WORKDIR="$(mktemp -d)"; trap 'rm -rf "$WORKDIR"' EXIT

# ----- Setup synthetic identity + datamart mapping -----
PII="pii-reid-$(openssl rand -hex 4)"
REF="ref-$(openssl rand -hex 16)"
WP=$(node scripts/test/crypto-helper.js wp "$WP_MASTER_KEY" "$PII")

./scripts/invokeCC.sh warehouse-channel identity-mapping \
  '{"function":"RegisterIdentityReference","Args":[]}' \
  "{\"pii\":\"$PII\"}" OrgIM OrgIM OrgWPI

./scripts/invokeCC.sh warehouse-channel warehouse-mapping \
  "{\"function\":\"RegisterWP\",\"Args\":[\"$REF\"]}" \
  "{\"wp\":\"$WP\"}" OrgWPI OrgWPI OrgHDW

STUDY_KEY=$(node scripts/test/crypto-helper.js hkdf "$SP_MASTER_KEY" "$STUDY_ID" "$DATAMART_ID")
WP_LIST_JSON="[\"$WP\"]"
./scripts/invokeCC.sh study-channel study-mapping \
  "{\"function\":\"RegisterSPBatch\",\"Args\":[\"$DATAMART_ID\"]}" \
  "{\"studyKey\":\"$STUDY_KEY\",\"wpList\":$WP_LIST_JSON}" OrgSPI OrgSPI OrgSC

SP=$(./scripts/queryCC.sh OrgSC study-channel study-mapping \
  "{\"function\":\"GetSPForWP\",\"Args\":[\"$DATAMART_ID\",\"$WP\"]}")

successln "[setup] REF=$REF WP=$WP SP=$SP"

# ----- [1] RO creates the request -----
TX_FILE="$WORKDIR/txid"
: > "$TX_FILE"

if ! invoke_capture_txid "$TX_FILE" \
      "$CHANNEL_STUDY" "$CC_SREID" \
      "{\"function\":\"CreateReIDRequest\",\"Args\":[\"$STUDY_ID\",\"$DATAMART_ID\",\"$SP\"]}" \
      NA \
      OrgRO OrgRO OrgSPI OrgSC OrgEC1 OrgEC2; then
  errorln "[1] FAILED: CreateReIDRequest returned an error"
  exit 1
fi

REQ_ID=$(cat "$TX_FILE" 2>/dev/null || true)
if [ -z "$REQ_ID" ]; then
  errorln "[1] FAILED: txId was not captured in $TX_FILE"
  exit 1
fi
successln "[1] reqId=$REQ_ID"

# ----- [2] EC1 signs approval -----
MSG1="reid_approval:${REQ_ID}:approve"
SIG1=$(node scripts/test/ec-sign.js sign ec1.example.com "$MSG1")
./scripts/invokeCC.sh study-channel "$CC_SREID" \
  "{\"function\":\"SignReIDRequest\",\"Args\":[\"$REQ_ID\",\"approve\",\"$SIG1\"]}" \
  NA OrgEC1 OrgEC1 OrgEC2 OrgEC3 OrgSPI OrgRO
STATUS=$(./scripts/queryCC.sh OrgRO study-channel "$CC_SREID" \
  "{\"function\":\"GetReIDRequest\",\"Args\":[\"$REQ_ID\"]}" | jq -r .status)
[ "$STATUS" == "pending" ] || { errorln "expected pending, got $STATUS"; exit 1; }
successln "[2] 1/2 approvals: status=pending OK"

# ----- [3] EC2 signs -> quorum reached -----
MSG2="reid_approval:${REQ_ID}:approve"
SIG2=$(node scripts/test/ec-sign.js sign ec2.example.com "$MSG2")
./scripts/invokeCC.sh study-channel "$CC_SREID" \
  "{\"function\":\"SignReIDRequest\",\"Args\":[\"$REQ_ID\",\"approve\",\"$SIG2\"]}" \
  NA OrgEC2 OrgEC1 OrgEC2 OrgEC3 OrgSPI OrgRO
STATUS=$(./scripts/queryCC.sh OrgRO study-channel "$CC_SREID" \
  "{\"function\":\"GetReIDRequest\",\"Args\":[\"$REQ_ID\"]}" | jq -r .status)
[ "$STATUS" == "approved" ] || { errorln "expected approved, got $STATUS"; exit 1; }
successln "[3] 2/2 approvals: status=approved OK"

# ----- [4] SPI resolves SP -> WP -----
WP_FROM_SP=$(./scripts/queryCC.sh OrgSPI study-channel study-mapping \
  "{\"function\":\"GetWPBySP\",\"Args\":[\"$SP\"]}")
[ "$WP_FROM_SP" == "$WP" ] || { errorln "WP mismatch"; exit 1; }
successln "[4] SP -> WP OK"

# ----- [5] SPI signs (reqId, WP) and stores both -----
SPI_MSG="spi_resolution:${REQ_ID}:${WP_FROM_SP}"
SPI_SIG=$(node scripts/test/ec-sign.js sign spi.example.com "$SPI_MSG")

./scripts/invokeCC.sh study-channel "$CC_SREID" \
  "{\"function\":\"RegisterReIDResult\",\"Args\":[\"$REQ_ID\"]}" \
  "{\"wp\":\"$WP_FROM_SP\",\"spiSignature\":\"$SPI_SIG\"}" \
  OrgSPI OrgSPI OrgRO
successln "[5] RegisterReIDResult OK (with SPI attestation)"

# ----- [6] RO fetches bundle + approvals; exports context -----
BUNDLE=$(./scripts/queryCC.sh OrgRO study-channel "$CC_SREID" \
  "{\"function\":\"GetReIDBundle\",\"Args\":[\"$REQ_ID\"]}")

WP_FROM_BUNDLE=$(echo "$BUNDLE" | jq -r .wp)
SPI_SIG_FROM_BUNDLE=$(echo "$BUNDLE" | jq -r .spiSignature)
[ "$WP_FROM_BUNDLE" == "$WP" ] || { errorln "WP mismatch in bundle"; exit 1; }
[ -n "$SPI_SIG_FROM_BUNDLE" ] || { errorln "SPI signature missing in bundle"; exit 1; }

./scripts/queryCC.sh OrgRO study-channel "$CC_SREID" \
  "{\"function\":\"GetReIDApprovals\",\"Args\":[\"$REQ_ID\"]}" > "$WORKDIR/approvals.json"

if [ -n "${STUDY_OUT_FILE:-}" ]; then
  {
    echo "REQ_ID='$REQ_ID'"
    echo "WP='$WP_FROM_BUNDLE'"
    echo "SPI_SIGNATURE='$SPI_SIG_FROM_BUNDLE'"
    echo "SP='$SP'"
    echo "PII='$PII'"
    echo "DATAMART_ID='$DATAMART_ID'"
    printf "APPROVALS_JSON=%q\n" "$(cat "$WORKDIR/approvals.json")"
  } > "$STUDY_OUT_FILE"
fi
successln "Study side: OK."