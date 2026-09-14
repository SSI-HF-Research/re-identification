#!/bin/bash
# ============================================================================
# test-function-access.sh — Verifies chaincode-level caller assertions.
#
# PURPOSE
#   Each chaincode has `assertCallerIs(...)` checks that reject callers
#   outside the allowed MSP. This file exercises each assertion.
#
# METRICS SERVED
#   Security assertion:
#     RegisterIdentityReference  — only IM
#     RegisterWP                 — only WPI
#     CreateReIDRequest          — only RO
#     SignReIDRequest            — only EC1/EC2/EC3
#     RegisterReIDResult         — only SPI
#     RegisterReIdentifiedPII    — only WPI
#     GetReidentifiedPII         — only MO
#
# VALUE
#   Confirms that confidentiality does not rely solely on PDC membership
#   but is enforced inside the chaincode too — defense in depth.
# ============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/security/00-config.sh"
source "$ROOT/scripts/security/lib.sh"

RESULTS_FILE="$SEC_DIR/test-function-access.csv"
: > "$RESULTS_FILE"

echo ">> test-function-access"

# Seed data so we have valid arguments to feed into denied calls
SEED_PII="acc-pii-$(openssl rand -hex 4)"
SEED_REF="ref-$(openssl rand -hex 16)"
SEED_WP="$(node "$ROOT/scripts/test/crypto-helper.js" wp "$WP_MASTER_KEY" "$SEED_PII")"
SEED_DM="acc-dm-$(openssl rand -hex 4)"
SEED_SK="$(node "$ROOT/scripts/test/crypto-helper.js" hkdf "$SP_MASTER_KEY" "$STUDY_ID" "$SEED_DM")"

inv "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
  '{"function":"RegisterIdentityReference","Args":[]}' \
  "{\"pii\":\"$SEED_PII\",\"identityReference\":\"$SEED_REF\"}" \
  OrgIM OrgIM OrgWPI >/dev/null 2>&1 || true
inv "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
  "{\"function\":\"RegisterWP\",\"Args\":[\"$SEED_REF\"]}" \
  "{\"wp\":\"$SEED_WP\"}" OrgWPI OrgWPI OrgHDW >/dev/null 2>&1 || true
inv "$CHANNEL_STUDY" "$CC_STUDY" \
  "{\"function\":\"RegisterSPBatch\",\"Args\":[\"$SEED_DM\"]}" \
  "{\"studyKey\":\"$SEED_SK\",\"wpList\":[\"$SEED_WP\"]}" \
  OrgSPI OrgSPI OrgSC >/dev/null 2>&1 || true
SEED_SP="$(q OrgSC "$CHANNEL_STUDY" "$CC_STUDY" \
  "{\"function\":\"GetSPForWP\",\"Args\":[\"$SEED_DM\",\"$SEED_WP\"]}")"

# Create a real approved request so we can test later-stage functions
TXFILE="$(mktemp)"
CAPTURE_TXID_FILE="$TXFILE" "$ROOT/scripts/invokeCC.sh" \
  "$CHANNEL_STUDY" "$CC_SREID" \
  "{\"function\":\"CreateReIDRequest\",\"Args\":[\"$STUDY_ID\",\"$SEED_DM\",\"$SEED_SP\"]}" \
  NA OrgRO OrgRO OrgSPI OrgSC OrgEC1 OrgEC2 >/dev/null 2>&1 || true
SEED_REQ="$(cat "$TXFILE" 2>/dev/null || true)"
rm -f "$TXFILE"

# --- RegisterIdentityReference: only IM -------------------------------------
echo "  RegisterIdentityReference — only IM"
for org in OrgWPI OrgHDW OrgMO OrgRO OrgEC1 OrgEC2 OrgEC3; do
  expect_denied "$org cannot call RegisterIdentityReference" \
    inv "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
    '{"function":"RegisterIdentityReference","Args":[]}' \
    "{\"pii\":\"x\",\"identityReference\":\"x-$org\"}" \
    "$org" OrgIM OrgWPI
done

# --- RegisterWP: only WPI ---------------------------------------------------
echo "  RegisterWP — only WPI"
for org in OrgIM OrgHDW OrgMO OrgRO OrgEC1 OrgEC2 OrgEC3; do
  expect_denied "$org cannot call RegisterWP" \
    inv "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
    "{\"function\":\"RegisterWP\",\"Args\":[\"new-ref-for-$org\"]}" \
    "{\"wp\":\"wp-$org\"}" \
    "$org" OrgWPI OrgHDW
done

# --- CreateReIDRequest: only RO ---------------------------------------------
echo "  CreateReIDRequest — only RO"
for org in OrgSPI OrgSC OrgMO OrgEC1 OrgEC2 OrgEC3; do
  expect_denied "$org cannot call CreateReIDRequest" \
    inv "$CHANNEL_STUDY" "$CC_SREID" \
    "{\"function\":\"CreateReIDRequest\",\"Args\":[\"$STUDY_ID\",\"$SEED_DM\",\"$SEED_SP\"]}" \
    NA "$org" OrgRO OrgSPI OrgSC OrgEC1 OrgEC2
done

# --- SignReIDRequest: only EC1/EC2/EC3 -------------------------------------
echo "  SignReIDRequest — only EC members"
if [ -n "$SEED_REQ" ]; then
  SIG="$(node "$ROOT/scripts/test/ec-sign.js" sign ec1.example.com "reid_approval:${SEED_REQ}:approve")"
  for org in OrgRO OrgSPI OrgSC OrgMO OrgIM OrgWPI OrgHDW; do
    expect_denied "$org cannot call SignReIDRequest" \
      inv "$CHANNEL_STUDY" "$CC_SREID" \
      "{\"function\":\"SignReIDRequest\",\"Args\":[\"$SEED_REQ\",\"approve\",\"$SIG\"]}" \
      NA "$org" OrgEC1 OrgEC2 OrgEC3 OrgSPI OrgRO
  done
else
  echo "  (skipped — could not seed a request)"
fi

# --- RegisterReIDResult: only SPI -------------------------------------------
echo "  RegisterReIDResult — only SPI"
if [ -n "$SEED_REQ" ]; then
  for org in OrgRO OrgSC OrgEC1 OrgEC2 OrgEC3; do
    expect_denied "$org cannot call RegisterReIDResult" \
      inv "$CHANNEL_STUDY" "$CC_SREID" \
      "{\"function\":\"RegisterReIDResult\",\"Args\":[\"$SEED_REQ\"]}" \
      "{\"wp\":\"$SEED_WP\"}" "$org" OrgSPI OrgRO
  done
fi

# --- RegisterReIdentifiedPII: only WPI --------------------------------------
echo "  RegisterReIdentifiedPII — only WPI"
for org in OrgIM OrgHDW OrgMO OrgRO OrgEC1 OrgEC2 OrgEC3; do
  expect_denied "$org cannot call RegisterReIdentifiedPII" \
    inv "$CHANNEL_WAREHOUSE" "$CC_WREID" \
    "{\"function\":\"RegisterReIdentifiedPII\",\"Args\":[\"deny-$org\"]}" \
    "{\"pii\":\"x\",\"approvals\":[]}" \
    "$org" OrgWPI OrgMO OrgEC1 OrgEC2
done

# --- GetReidentifiedPII: only MO --------------------------------------------
echo "  GetReidentifiedPII — only MO"
for org in OrgIM OrgWPI OrgHDW OrgRO OrgEC1 OrgEC2 OrgEC3; do
  expect_denied "$org cannot call GetReidentifiedPII" \
    q "$org" "$CHANNEL_WAREHOUSE" "$CC_WREID" \
    "{\"function\":\"GetReidentifiedPII\",\"Args\":[\"any\"]}"
done

print_summary "Function access control"