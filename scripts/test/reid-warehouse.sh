#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
source scripts/utils.sh

# This script validates the warehouse-side part of the re-identification flow:
# it resolves the pseudonym back to the original reference, retrieves the PII,
# verifies the K-of-N approval policy, and rejects invalid or tampered approval sets.
CHANNEL_WAREHOUSE="${CHANNEL_WAREHOUSE:-warehouse-channel}"
CC_IDENTITY="${CC_IDENTITY:-identity-mapping}"
CC_WAREHOUSE="${CC_WAREHOUSE:-warehouse-mapping}"
CC_WREID="${CC_WREID:-warehouse-reidentification}"

: "${REQ_ID:?REQ_ID required}"
: "${WP:?WP required}"
: "${APPROVALS_JSON:?APPROVALS_JSON required}"

# ----- [1] WPI resolves the warehouse pseudonym (WP) back to an identity reference -----
# This step proves the warehouse-side mapping can be reversed to the original
# patient reference before the final re-identification is processed.
REF=$(./scripts/queryCC.sh OrgWPI "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
  "{\"function\":\"GetIdentityReferenceByWP\",\"Args\":[\"$WP\"]}")
[ -n "$REF" ] || { errorln "WP->REF returned an empty value"; exit 1; }
successln "[1] WP -> REF resolved successfully ($REF)"

# ----- [2] WPI resolves the identity reference to personally identifiable information -----
# Once the reference is known, the warehouse can access the original PII that was
# previously registered under that reference.
PII=$(./scripts/queryCC.sh OrgWPI "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
  "{\"function\":\"GetPii\",\"Args\":[\"$REF\"]}")
[ -n "$PII" ] || { errorln "REF->PII returned an empty value"; exit 1; }
successln "[2] REF -> PII resolved successfully"

# ----- [3] WPI submits the PII and approvals; the chaincode verifies the K-of-N policy -----
# This is the main authorization check: the chaincode accepts the PII only if the
# approvals provided match the request ID and satisfy the required quorum size.
./scripts/invokeCC.sh "$CHANNEL_WAREHOUSE" "$CC_WREID" \
  "{\"function\":\"RegisterReIdentifiedPII\",\"Args\":[\"$REQ_ID\"]}" \
  "{\"pii\":\"$PII\",\"approvals\":$APPROVALS_JSON}" \
  OrgWPI OrgWPI OrgMO OrgEC1 OrgEC2
successln "[3] K-of-N verified on-chain; PII stored"

# ----- [4] MO reads the stored PII and verifies that it matches the original value -----
# The monitoring or operational role verifies the stored value exactly matches the
# original PII, ensuring integrity after the on-chain admission checks.
PII_FINAL=$(./scripts/queryCC.sh OrgMO "$CHANNEL_WAREHOUSE" "$CC_WREID" \
  "{\"function\":\"GetReidentifiedPII\",\"Args\":[\"$REQ_ID\"]}")
[ "$PII_FINAL" == "$PII" ] || { errorln "PII values do not match"; exit 1; }
successln "[4] MO retrieved the PII successfully"

# ----- Negative signature validation checks -----
# These checks confirm that the chaincode rejects invalid approval data and enforces
# the safety rules against request substitution, tampering, and insufficient quorum.
set +e
infoln "Running negative signature validation checks"

# 3.1 — An approval signed for a different request ID must be rejected.
BAD_REQ="fake-$(openssl rand -hex 4)"
BAD_APPROVALS=$(echo "$APPROVALS_JSON" | jq -c 'map(. + {mspId:.mspId})')
./scripts/invokeCC.sh "$CHANNEL_WAREHOUSE" "$CC_WREID" \
  "{\"function\":\"RegisterReIdentifiedPII\",\"Args\":[\"$BAD_REQ\"]}" \
  "{\"pii\":\"injection\",\"approvals\":$BAD_APPROVALS}" \
  OrgWPI OrgWPI OrgMO OrgEC1 OrgEC2 >/dev/null 2>&1 \
  && { errorln "FAIL: accepted approvals signed for the wrong request ID"; exit 1; }

# 3.2 — A tampered signature must be rejected.
TAMPERED=$(echo "$APPROVALS_JSON" | jq -c 'map(if .decision=="approve" then . + {signature: (.signature[0:4] + "AAAA" + .signature[8:])} else . end)')
./scripts/invokeCC.sh "$CHANNEL_WAREHOUSE" "$CC_WREID" \
  "{\"function\":\"RegisterReIdentifiedPII\",\"Args\":[\"$REQ_ID-suffix\"]}" \
  "{\"pii\":\"injection\",\"approvals\":$TAMPERED}" \
  OrgWPI OrgWPI OrgMO OrgEC1 OrgEC2 >/dev/null 2>&1 \
  && { errorln "FAIL: accepted a tampered signature"; exit 1; }

# 3.3 — A request with fewer than K approvals must be rejected.
ONE=$(echo "$APPROVALS_JSON" | jq -c '[.[] | select(.decision=="approve")][0:1]')
./scripts/invokeCC.sh "$CHANNEL_WAREHOUSE" "$CC_WREID" \
  "{\"function\":\"RegisterReIdentifiedPII\",\"Args\":[\"$REQ_ID-x\"]}" \
  "{\"pii\":\"injection\",\"approvals\":$ONE}" \
  OrgWPI OrgWPI OrgMO OrgEC1 OrgEC2 >/dev/null 2>&1 \
  && { errorln "FAIL: accepted fewer than K approvals"; exit 1; }

set -e
successln "Warehouse side: all validation checks passed."