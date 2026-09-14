#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
source scripts/utils.sh

CHANNEL_WAREHOUSE="${CHANNEL_WAREHOUSE:-warehouse-channel}"
CC_IDENTITY="${CC_IDENTITY:-identity-mapping}"
CC_WAREHOUSE="${CC_WAREHOUSE:-warehouse-mapping}"
CC_WREID="${CC_WREID:-warehouse-reidentification}"

: "${REQ_ID:?REQ_ID required}"
: "${WP:?WP required}"
: "${APPROVALS_JSON:?APPROVALS_JSON required}"

# ----- [1] WPI resolve WP -> ref -----
REF=$(./scripts/queryCC.sh OrgWPI "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
  "{\"function\":\"GetIdentityReferenceByWP\",\"Args\":[\"$WP\"]}")
[ -n "$REF" ] || { errorln "WP->REF vazio"; exit 1; }
successln "[1] WP -> REF OK ($REF)"

# ----- [2] WPI resolve ref -> PII -----
PII=$(./scripts/queryCC.sh OrgWPI "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
  "{\"function\":\"GetPii\",\"Args\":[\"$REF\"]}")
[ -n "$PII" ] || { errorln "REF->PII vazio"; exit 1; }
successln "[2] REF -> PII OK"

# ----- [3] WPI submete PII + approvals; chaincode verifica K-of-N -----
./scripts/invokeCC.sh "$CHANNEL_WAREHOUSE" "$CC_WREID" \
  "{\"function\":\"RegisterReIdentifiedPII\",\"Args\":[\"$REQ_ID\"]}" \
  "{\"pii\":\"$PII\",\"approvals\":$APPROVALS_JSON}" \
  OrgWPI OrgWPI OrgMO OrgEC1 OrgEC2
successln "[3] K-of-N verificado on-chain; PII gravada"

# ----- [4] MO lê a PII -----
PII_FINAL=$(./scripts/queryCC.sh OrgMO "$CHANNEL_WAREHOUSE" "$CC_WREID" \
  "{\"function\":\"GetReidentifiedPII\",\"Args\":[\"$REQ_ID\"]}")
[ "$PII_FINAL" == "$PII" ] || { errorln "PII divergente"; exit 1; }
successln "[4] MO obteve PII OK"

# ----- Checagens negativas (assinaturas) -----
set +e
infoln "Checagens negativas de assinatura"

# 3.1 — assinatura de outro reqId não vale
BAD_REQ="fake-$(openssl rand -hex 4)"
BAD_APPROVALS=$(echo "$APPROVALS_JSON" | jq -c 'map(. + {mspId:.mspId})')
./scripts/invokeCC.sh "$CHANNEL_WAREHOUSE" "$CC_WREID" \
  "{\"function\":\"RegisterReIdentifiedPII\",\"Args\":[\"$BAD_REQ\"]}" \
  "{\"pii\":\"injetada\",\"approvals\":$BAD_APPROVALS}" \
  OrgWPI OrgWPI OrgMO OrgEC1 OrgEC2 >/dev/null 2>&1 \
  && { errorln "FAIL: aceitou assinaturas com reqId errado"; exit 1; }

# 3.2 — assinatura adulterada (flip de byte no base64)
TAMPERED=$(echo "$APPROVALS_JSON" | jq -c 'map(if .decision=="approve" then . + {signature: (.signature[0:4] + "AAAA" + .signature[8:])} else . end)')
./scripts/invokeCC.sh "$CHANNEL_WAREHOUSE" "$CC_WREID" \
  "{\"function\":\"RegisterReIdentifiedPII\",\"Args\":[\"$REQ_ID-suffix\"]}" \
  "{\"pii\":\"injetada\",\"approvals\":$TAMPERED}" \
  OrgWPI OrgWPI OrgMO OrgEC1 OrgEC2 >/dev/null 2>&1 \
  && { errorln "FAIL: aceitou assinatura adulterada"; exit 1; }

# 3.3 — só 1 aprovação (abaixo de K)
ONE=$(echo "$APPROVALS_JSON" | jq -c '[.[] | select(.decision=="approve")][0:1]')
./scripts/invokeCC.sh "$CHANNEL_WAREHOUSE" "$CC_WREID" \
  "{\"function\":\"RegisterReIdentifiedPII\",\"Args\":[\"$REQ_ID-x\"]}" \
  "{\"pii\":\"injetada\",\"approvals\":$ONE}" \
  OrgWPI OrgWPI OrgMO OrgEC1 OrgEC2 >/dev/null 2>&1 \
  && { errorln "FAIL: aceitou <K assinaturas"; exit 1; }

set -e
successln "Warehouse side: todas as checagens passaram."