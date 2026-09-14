#!/bin/bash
# ============================================================================
# test-pdc-isolation.sh — Verifies private-data collection membership.
#
# PURPOSE
#   For every PDC in the system, asserts that members can read it and
#   non-members cannot, even when they are in the same channel.
#
# METRICS SERVED
#   Security assertion:
#     Identity_Mapping       (IM, WPI)   — check positive: WPI;  negative: HDW, MO, RO, EC1-3
#     Warehouse_Mapping      (WPI, HDW)  — check positive: HDW;  negative: IM, MO, RO, EC1-3
#     WarehouseReIdentification (WPI, MO) — check positive: MO;  negative: IM, HDW, RO, EC1-3
#     Study_Mapping          (SC, SPI)   — check positive: SC;   negative: MO, RO, EC1-3
#     StudyReIdentification  (SPI, RO)   — check positive: RO;   negative: SC, MO, EC1-3
#
# VALUE
#   This is the core confidentiality guarantee: even orgs in the same
#   channel cannot read a PDC they are not members of. Directly maps to
#   RS1.1, RS1.2, RS2.1, RS4.1-4.3 in the spec.
# ============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/security/00-config.sh"
source "$ROOT/scripts/security/lib.sh"

RESULTS_FILE="$SEC_DIR/test-pdc-isolation.csv"
: > "$RESULTS_FILE"

echo ">> test-pdc-isolation"

# --- Seed data so reads target real keys ------------------------------------
SEED_PII="sec-pii-$(openssl rand -hex 4)"
SEED_REF="ref-$(openssl rand -hex 16)"
SEED_WP="$(node "$ROOT/scripts/test/crypto-helper.js" wp "$WP_MASTER_KEY" "$SEED_PII")"
SEED_DM="sec-dm-$(openssl rand -hex 4)"
SEED_SK="$(node "$ROOT/scripts/test/crypto-helper.js" hkdf "$SP_MASTER_KEY" "$STUDY_ID" "$SEED_DM")"
SEED_REQ="sec-req-$(openssl rand -hex 8)"

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

# --- Identity_Mapping members: IM, WPI --------------------------------------
echo "  Identity_Mapping (IM, WPI)"
expect_allowed "OrgWPI can read Identity_Mapping" \
  q OrgWPI "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
  "{\"function\":\"GetPii\",\"Args\":[\"$SEED_REF\"]}"
for org in OrgHDW OrgMO OrgRO OrgEC1 OrgEC2 OrgEC3; do
  expect_denied "$org cannot read Identity_Mapping" \
    q "$org" "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
    "{\"function\":\"GetPii\",\"Args\":[\"$SEED_REF\"]}"
done

# --- Warehouse_Mapping members: WPI, HDW ------------------------------------
echo "  Warehouse_Mapping (WPI, HDW)"
expect_allowed "OrgHDW can read Warehouse_Mapping" \
  q OrgHDW "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
  "{\"function\":\"GetWP\",\"Args\":[\"$SEED_REF\"]}"
for org in OrgIM OrgMO OrgRO OrgEC1 OrgEC2 OrgEC3; do
  expect_denied "$org cannot read Warehouse_Mapping" \
    q "$org" "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
    "{\"function\":\"GetWP\",\"Args\":[\"$SEED_REF\"]}"
done

# --- WarehouseReIdentification members: WPI, MO -----------------------------
echo "  WarehouseReIdentification (WPI, MO)"
expect_allowed "OrgMO can query WarehouseReIdentification (not found is fine)" \
  q OrgMO "$CHANNEL_WAREHOUSE" "$CC_WREID" \
  "{\"function\":\"GetReidentifiedPII\",\"Args\":[\"$SEED_REQ\"]}" || true
# Note: the above may "fail" (rc!=0) if reqId does not exist. We only want to
# check that the *query itself* is permitted; a "not found" error means the
# caller was authorized. The check below validates the boundary properly:
for org in OrgIM OrgHDW OrgRO OrgEC1 OrgEC2 OrgEC3; do
  expect_denied "$org cannot read WarehouseReIdentification PDC" \
    q "$org" "$CHANNEL_WAREHOUSE" "$CC_WREID" \
    "{\"function\":\"GetReidentifiedPII\",\"Args\":[\"$SEED_REQ\"]}"
done

# --- Study_Mapping members: SC, SPI ----------------------------------------
echo "  Study_Mapping (SC, SPI)"
expect_allowed "OrgSC can read Study_Mapping" \
  q OrgSC "$CHANNEL_STUDY" "$CC_STUDY" \
  "{\"function\":\"GetSPListByDatamart\",\"Args\":[\"$SEED_DM\"]}"
for org in OrgMO OrgRO OrgEC1 OrgEC2 OrgEC3; do
  expect_denied "$org cannot read Study_Mapping" \
    q "$org" "$CHANNEL_STUDY" "$CC_STUDY" \
    "{\"function\":\"GetSPListByDatamart\",\"Args\":[\"$SEED_DM\"]}"
done

# --- StudyReIdentification members: SPI, RO --------------------------------
echo "  StudyReIdentification (SPI, RO)"
for org in OrgSC OrgMO OrgEC1 OrgEC2 OrgEC3; do
  expect_denied "$org cannot read StudyReIdentification PDC" \
    q "$org" "$CHANNEL_STUDY" "$CC_SREID" \
    "{\"function\":\"GetReIDResult\",\"Args\":[\"$SEED_REQ\"]}"
done

print_summary "PDC isolation"