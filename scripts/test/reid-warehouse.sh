#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
source scripts/utils.sh

# Warehouse-side validation:
# [0] RO creates the request with wp + SPI attestation + EC approvals
# [1] WPI resolves WP -> identity_reference
# [2] WPI resolves identity_reference -> PII
# [3] WPI invokes RegisterReIdentifiedPII: chaincode verifies EC quorum and SPI attestation, writes PII
# [4] MO reads the PII back
# then negative checks.

CHANNEL_WAREHOUSE="${CHANNEL_WAREHOUSE:-warehouse-channel}"
CC_IDENTITY="${CC_IDENTITY:-identity-mapping}"
CC_WAREHOUSE="${CC_WAREHOUSE:-warehouse-mapping}"
CC_WREID="${CC_WREID:-warehouse-reidentification}"

: "${REQ_ID:?REQ_ID required}"
: "${WP:?WP required}"
: "${SPI_SIGNATURE:?SPI_SIGNATURE required}"
: "${APPROVALS_JSON:?APPROVALS_JSON required}"

APPROVALS_MIN=$(echo "$APPROVALS_JSON" | jq -c .)

# ----- [0] RO creates the warehouse-side request -----
TRANSIENT=$(jq -nc \
  --arg wp "$WP" \
  --arg sig "$SPI_SIGNATURE" \
  --argjson ap "$APPROVALS_MIN" \
  '{wp:$wp, spiSignature:$sig, approvals:$ap}')

./scripts/invokeCC.sh "$CHANNEL_WAREHOUSE" "$CC_WREID" \
  "{\"function\":\"CreateWarehouseReIDRequest\",\"Args\":[\"$REQ_ID\"]}" \
  "$TRANSIENT" \
  OrgRO OrgRO OrgWPI OrgMO
successln "[0] Warehouse request created"

# ----- [1] WPI resolves WP -> REF -----
REF=$(./scripts/queryCC.sh OrgWPI "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
  "{\"function\":\"GetIdentityReferenceByWP\",\"Args\":[\"$WP\"]}")
[ -n "$REF" ] || { errorln "WP->REF returned an empty value"; exit 1; }
successln "[1] WP -> REF resolved ($REF)"

# ----- [2] WPI resolves REF -> PII -----
PII=$(./scripts/queryCC.sh OrgWPI "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
  "{\"function\":\"GetPii\",\"Args\":[\"$REF\"]}")
[ -n "$PII" ] || { errorln "REF->PII returned an empty value"; exit 1; }
successln "[2] REF -> PII resolved"

# ----- [3] WPI registers PII; chaincode verifies EC quorum + SPI attestation -----
./scripts/invokeCC.sh "$CHANNEL_WAREHOUSE" "$CC_WREID" \
  "{\"function\":\"RegisterReIdentifiedPII\",\"Args\":[\"$REQ_ID\"]}" \
  "{\"pii\":\"$PII\"}" \
  OrgWPI OrgWPI OrgMO OrgEC1 OrgEC2
successln "[3] K-of-N + SPI attestation verified; PII stored"

# ----- [4] MO reads back -----
PII_FINAL=$(./scripts/queryCC.sh OrgMO "$CHANNEL_WAREHOUSE" "$CC_WREID" \
  "{\"function\":\"GetReidentifiedPII\",\"Args\":[\"$REQ_ID\"]}")
[ "$PII_FINAL" == "$PII" ] || { errorln "PII values do not match"; exit 1; }
successln "[4] MO retrieved the PII successfully"

# ----- Negative checks -----
set +e
infoln "Running negative validation checks"

# 3.1 — Unknown request ID (no CreateWarehouseReIDRequest was issued)
BAD_REQ="fake-$(openssl rand -hex 4)"
./scripts/invokeCC.sh "$CHANNEL_WAREHOUSE" "$CC_WREID" \
  "{\"function\":\"RegisterReIdentifiedPII\",\"Args\":[\"$BAD_REQ\"]}" \
  "{\"pii\":\"injection\"}" \
  OrgWPI OrgWPI OrgMO OrgEC1 OrgEC2 >/dev/null 2>&1 \
  && { errorln "FAIL: accepted unknown request ID"; exit 1; }

# 3.2 — Tampered SPI signature: request is created, but PII write must fail
TAMPERED_SIG="${SPI_SIGNATURE:0:4}AAAA${SPI_SIGNATURE:8}"
BAD_TRANSIENT=$(jq -nc \
  --arg wp "$WP" \
  --arg sig "$TAMPERED_SIG" \
  --argjson ap "$APPROVALS_MIN" \
  '{wp:$wp, spiSignature:$sig, approvals:$ap}')
BAD_REQ2="tampered-$(openssl rand -hex 4)"
./scripts/invokeCC.sh "$CHANNEL_WAREHOUSE" "$CC_WREID" \
  "{\"function\":\"CreateWarehouseReIDRequest\",\"Args\":[\"$BAD_REQ2\"]}" \
  "$BAD_TRANSIENT" OrgRO OrgRO OrgWPI OrgMO >/dev/null 2>&1

./scripts/invokeCC.sh "$CHANNEL_WAREHOUSE" "$CC_WREID" \
  "{\"function\":\"RegisterReIdentifiedPII\",\"Args\":[\"$BAD_REQ2\"]}" \
  "{\"pii\":\"injection\"}" \
  OrgWPI OrgWPI OrgMO OrgEC1 OrgEC2 >/dev/null 2>&1 \
  && { errorln "FAIL: accepted tampered SPI signature"; exit 1; }

# 3.3 — Under-quorum approvals: request is created, but PII write must fail
ONE=$(echo "$APPROVALS_JSON" | jq -c '[.[] | select(.decision=="approve")][0:1]')
BAD_TRANSIENT2=$(jq -nc \
  --arg wp "$WP" \
  --arg sig "$SPI_SIGNATURE" \
  --argjson ap "$ONE" \
  '{wp:$wp, spiSignature:$sig, approvals:$ap}')
BAD_REQ3="underquorum-$(openssl rand -hex 4)"
./scripts/invokeCC.sh "$CHANNEL_WAREHOUSE" "$CC_WREID" \
  "{\"function\":\"CreateWarehouseReIDRequest\",\"Args\":[\"$BAD_REQ3\"]}" \
  "$BAD_TRANSIENT2" OrgRO OrgRO OrgWPI OrgMO >/dev/null 2>&1

./scripts/invokeCC.sh "$CHANNEL_WAREHOUSE" "$CC_WREID" \
  "{\"function\":\"RegisterReIdentifiedPII\",\"Args\":[\"$BAD_REQ3\"]}" \
  "{\"pii\":\"injection\"}" \
  OrgWPI OrgWPI OrgMO OrgEC1 OrgEC2 >/dev/null 2>&1 \
  && { errorln "FAIL: accepted under-quorum approvals"; exit 1; }

# 3.4 — Replay: create a request for a new ID reusing the old approvals/signature
REPLAY_REQ="replay-$(openssl rand -hex 4)"
REPLAY_TRANSIENT=$(jq -nc \
  --arg wp "$WP" \
  --arg sig "$SPI_SIGNATURE" \
  --argjson ap "$APPROVALS_MIN" \
  '{wp:$wp, spiSignature:$sig, approvals:$ap}')
./scripts/invokeCC.sh "$CHANNEL_WAREHOUSE" "$CC_WREID" \
  "{\"function\":\"CreateWarehouseReIDRequest\",\"Args\":[\"$REPLAY_REQ\"]}" \
  "$REPLAY_TRANSIENT" OrgRO OrgRO OrgWPI OrgMO >/dev/null 2>&1

./scripts/invokeCC.sh "$CHANNEL_WAREHOUSE" "$CC_WREID" \
  "{\"function\":\"RegisterReIdentifiedPII\",\"Args\":[\"$REPLAY_REQ\"]}" \
  "{\"pii\":\"injection\"}" \
  OrgWPI OrgWPI OrgMO OrgEC1 OrgEC2 >/dev/null 2>&1 \
  && { errorln "FAIL: accepted replay of SPI attestation and EC approvals"; exit 1; }

set -e
successln "Warehouse side: all validation checks passed."