#!/bin/bash
# ============================================================================
# test-k-of-n-signatures.sh — Verifies the K-of-N approval enforcement and
# cryptographic signature validation.
#
# PURPOSE
#   Exercises every failure mode of the committee-approval flow:
#     - tampered signature
#     - signature for wrong request
#     - duplicate approval from the same EC member
#     - fewer than K approvals
#     - unknown EC member
#     - malformed decision value
#     - attempt to register result before threshold is reached
#     - attempt to register result without approvals at all
#
# METRICS SERVED
#   Security assertion (RS5.1, RS4.4, and the K-of-N verification in the
#   warehouse-reid chaincode).
#
# VALUE
#   The K-of-N committee is the primary authorization mechanism in the
#   system. If any of these tests pass, the whole scheme is broken.
# ============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/security/00-config.sh"
source "$ROOT/scripts/security/lib.sh"

RESULTS_FILE="$SEC_DIR/test-k-of-n-signatures.csv"
: > "$RESULTS_FILE"

echo ">> test-k-of-n-signatures"

# --- Seed patient + datamart + request --------------------------------------
PII="kofn-pii-$(openssl rand -hex 4)"
REF="ref-$(openssl rand -hex 16)"
WP="$(node "$ROOT/scripts/test/crypto-helper.js" wp "$WP_MASTER_KEY" "$PII")"
DM="kofn-dm-$(openssl rand -hex 4)"
SK="$(node "$ROOT/scripts/test/crypto-helper.js" hkdf "$SP_MASTER_KEY" "$STUDY_ID" "$DM")"

inv "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
  '{"function":"RegisterIdentityReference","Args":[]}' \
  "{\"pii\":\"$PII\",\"identityReference\":\"$REF\"}" \
  OrgIM OrgIM OrgWPI >/dev/null 2>&1
inv "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
  "{\"function\":\"RegisterWP\",\"Args\":[\"$REF\"]}" \
  "{\"wp\":\"$WP\"}" OrgWPI OrgWPI OrgHDW >/dev/null 2>&1
inv "$CHANNEL_STUDY" "$CC_STUDY" \
  "{\"function\":\"RegisterSPBatch\",\"Args\":[\"$DM\"]}" \
  "{\"studyKey\":\"$SK\",\"wpList\":[\"$WP\"]}" \
  OrgSPI OrgSPI OrgSC >/dev/null 2>&1
SP="$(q OrgSC "$CHANNEL_STUDY" "$CC_STUDY" \
  "{\"function\":\"GetSPForWP\",\"Args\":[\"$DM\",\"$WP\"]}")"

TXFILE="$(mktemp)"
CAPTURE_TXID_FILE="$TXFILE" "$ROOT/scripts/invokeCC.sh" \
  "$CHANNEL_STUDY" "$CC_SREID" \
  "{\"function\":\"CreateReIDRequest\",\"Args\":[\"$STUDY_ID\",\"$DM\",\"$SP\"]}" \
  NA OrgRO OrgRO OrgSPI OrgSC OrgEC1 OrgEC2 >/dev/null 2>&1
REQ_ID="$(cat "$TXFILE")"; rm -f "$TXFILE"

if [ -z "$REQ_ID" ]; then
  echo "  FATAL: could not seed a reid request — aborting"
  exit 1
fi
echo "  seeded reqId=$REQ_ID"

# --- 1) RegisterReIDResult before threshold ---------------------------------
echo "  1) RegisterReIDResult before any approval"
expect_denied "RegisterReIDResult before any approval" \
  inv "$CHANNEL_STUDY" "$CC_SREID" \
  "{\"function\":\"RegisterReIDResult\",\"Args\":[\"$REQ_ID\"]}" \
  "{\"wp\":\"$WP\"}" OrgSPI OrgSPI OrgRO

# --- 2) RegisterReIdentifiedPII with no approvals ---------------------------
echo "  2) RegisterReIdentifiedPII with empty approvals"
expect_denied "RegisterReIdentifiedPII with [] approvals" \
  inv "$CHANNEL_WAREHOUSE" "$CC_WREID" \
  "{\"function\":\"RegisterReIdentifiedPII\",\"Args\":[\"$REQ_ID\"]}" \
  "{\"pii\":\"$PII\",\"approvals\":[]}" \
  OrgWPI OrgWPI OrgMO OrgEC1 OrgEC2

# --- 3) Tampered signature --------------------------------------------------
echo "  3) Tampered signature"
SIG1="$(node "$ROOT/scripts/test/ec-sign.js" sign ec1.example.com "reid_approval:${REQ_ID}:approve")"
TAMPERED="${SIG1:0:8}AAAA${SIG1:12}"
APPROVALS_TAMPERED="[{\"mspId\":\"OrgEC1MSP\",\"decision\":\"approve\",\"signature\":\"$TAMPERED\"}]"
inv "$CHANNEL_STUDY" "$CC_SREID" \
  "{\"function\":\"SignReIDRequest\",\"Args\":[\"$REQ_ID\",\"approve\",\"$TAMPERED\"]}" \
  NA OrgEC1 OrgEC1 OrgEC2 OrgEC3 OrgSPI OrgRO >/dev/null 2>&1 || true
expect_denied "RegisterReIdentifiedPII with tampered signature" \
  inv "$CHANNEL_WAREHOUSE" "$CC_WREID" \
  "{\"function\":\"RegisterReIdentifiedPII\",\"Args\":[\"$REQ_ID\"]}" \
  "{\"pii\":\"$PII\",\"approvals\":$APPROVALS_TAMPERED}" \
  OrgWPI OrgWPI OrgMO OrgEC1 OrgEC2

# --- 4) Signature for a different request -----------------------------------
echo "  4) Signature bound to a different reqId"
FAKE_REQ="fake-$(openssl rand -hex 8)"
SIG_FAKE="$(node "$ROOT/scripts/test/ec-sign.js" sign ec1.example.com "reid_approval:${FAKE_REQ}:approve")"
SIG2_FAKE="$(node "$ROOT/scripts/test/ec-sign.js" sign ec2.example.com "reid_approval:${FAKE_REQ}:approve")"
WRONG_REQ_APPROVALS="[{\"mspId\":\"OrgEC1MSP\",\"decision\":\"approve\",\"signature\":\"$SIG_FAKE\"},{\"mspId\":\"OrgEC2MSP\",\"decision\":\"approve\",\"signature\":\"$SIG2_FAKE\"}]"
expect_denied "Signatures bound to wrong reqId rejected" \
  inv "$CHANNEL_WAREHOUSE" "$CC_WREID" \
  "{\"function\":\"RegisterReIdentifiedPII\",\"Args\":[\"$REQ_ID\"]}" \
  "{\"pii\":\"$PII\",\"approvals\":$WRONG_REQ_APPROVALS}" \
  OrgWPI OrgWPI OrgMO OrgEC1 OrgEC2

# --- 5) Only one valid approval (below K=2) ---------------------------------
echo "  5) Only one valid approval"
SIG1="$(node "$ROOT/scripts/test/ec-sign.js" sign ec1.example.com "reid_approval:${REQ_ID}:approve")"
ONE_APPROVAL="[{\"mspId\":\"OrgEC1MSP\",\"decision\":\"approve\",\"signature\":\"$SIG1\"}]"
expect_denied "RegisterReIdentifiedPII with only 1 approval" \
  inv "$CHANNEL_WAREHOUSE" "$CC_WREID" \
  "{\"function\":\"RegisterReIdentifiedPII\",\"Args\":[\"$REQ_ID\"]}" \
  "{\"pii\":\"$PII\",\"approvals\":$ONE_APPROVAL}" \
  OrgWPI OrgWPI OrgMO OrgEC1 OrgEC2

# --- 6) Duplicate approvals from the same EC --------------------------------
echo "  6) Duplicate approvals from the same EC member"
DUP_APPROVAL="[{\"mspId\":\"OrgEC1MSP\",\"decision\":\"approve\",\"signature\":\"$SIG1\"},{\"mspId\":\"OrgEC1MSP\",\"decision\":\"approve\",\"signature\":\"$SIG1\"}]"
expect_denied "RegisterReIdentifiedPII with duplicate EC1 approvals" \
  inv "$CHANNEL_WAREHOUSE" "$CC_WREID" \
  "{\"function\":\"RegisterReIdentifiedPII\",\"Args\":[\"$REQ_ID\"]}" \
  "{\"pii\":\"$PII\",\"approvals\":$DUP_APPROVAL}" \
  OrgWPI OrgWPI OrgMO OrgEC1 OrgEC2

# --- 7) Unknown EC member ---------------------------------------------------
echo "  7) Unknown EC member"
UNKNOWN_APPROVAL="[{\"mspId\":\"OrgFAKEMSP\",\"decision\":\"approve\",\"signature\":\"$SIG1\"}]"
expect_denied "RegisterReIdentifiedPII with unknown EC mspId" \
  inv "$CHANNEL_WAREHOUSE" "$CC_WREID" \
  "{\"function\":\"RegisterReIdentifiedPII\",\"Args\":[\"$REQ_ID\"]}" \
  "{\"pii\":\"$PII\",\"approvals\":$UNKNOWN_APPROVAL}" \
  OrgWPI OrgWPI OrgMO OrgEC1 OrgEC2

# --- 8) Malformed decision value --------------------------------------------
echo "  8) Invalid decision value"
expect_denied "SignReIDRequest with decision='maybe'" \
  inv "$CHANNEL_STUDY" "$CC_SREID" \
  "{\"function\":\"SignReIDRequest\",\"Args\":[\"$REQ_ID\",\"maybe\",\"$SIG1\"]}" \
  NA OrgEC1 OrgEC1 OrgEC2 OrgEC3 OrgSPI OrgRO

# --- 9) Legitimate flow: EC1 then EC2 reaches threshold ---------------------
echo "  9) Legitimate K-of-N flow: EC1 + EC2"
inv "$CHANNEL_STUDY" "$CC_SREID" \
  "{\"function\":\"SignReIDRequest\",\"Args\":[\"$REQ_ID\",\"approve\",\"$SIG1\"]}" \
  NA OrgEC1 OrgEC1 OrgEC2 OrgEC3 OrgSPI OrgRO >/dev/null 2>&1
SIG2="$(node "$ROOT/scripts/test/ec-sign.js" sign ec2.example.com "reid_approval:${REQ_ID}:approve")"
inv "$CHANNEL_STUDY" "$CC_SREID" \
  "{\"function\":\"SignReIDRequest\",\"Args\":[\"$REQ_ID\",\"approve\",\"$SIG2\"]}" \
  NA OrgEC2 OrgEC1 OrgEC2 OrgEC3 OrgSPI OrgRO >/dev/null 2>&1
APPROVALS_OK="[{\"mspId\":\"OrgEC1MSP\",\"decision\":\"approve\",\"signature\":\"$SIG1\"},{\"mspId\":\"OrgEC2MSP\",\"decision\":\"approve\",\"signature\":\"$SIG2\"}]"
expect_allowed "RegisterReIdentifiedPII with valid 2-of-3 approvals" \
  inv "$CHANNEL_WAREHOUSE" "$CC_WREID" \
  "{\"function\":\"RegisterReIdentifiedPII\",\"Args\":[\"$REQ_ID\"]}" \
  "{\"pii\":\"$PII\",\"approvals\":$APPROVALS_OK}" \
  OrgWPI OrgWPI OrgMO OrgEC1 OrgEC2

print_summary "K-of-N and signature validation"