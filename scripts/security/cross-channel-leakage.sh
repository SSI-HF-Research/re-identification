#!/bin/bash
# ============================================================================
# test-cross-channel-leakage.sh — Attempts to bridge information between
# channels using only legitimate function calls.
#
# PURPOSE
#   Models an adversary (RO, MO, or a compromised org) trying to correlate
#   data across the two channels without the required authorization path.
#   Every attempt must fail because no single actor has access to the full
#   PII → ref → WP → SP chain.
#
# METRICS SERVED
#   Security assertion (RS4.5 — no shortcut through existing read functions).
#
# VALUE
#   Directly proves the "no shortcut" claim in the spec. If any of these
#   succeeded, an attacker could skip the K-of-N committee.
# ============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/security/00-config.sh"
source "$ROOT/scripts/security/lib.sh"

RESULTS_FILE="$SEC_DIR/test-cross-channel-leakage.csv"
: > "$RESULTS_FILE"

echo ">> test-cross-channel-leakage"

# --- Seed an approved request so we have both SP and WP ---------------------
PII="leak-pii-$(openssl rand -hex 4)"
REF="ref-$(openssl rand -hex 16)"
WP="$(node "$ROOT/scripts/test/crypto-helper.js" wp "$WP_MASTER_KEY" "$PII")"
DM="leak-dm-$(openssl rand -hex 4)"
SK="$(node "$ROOT/scripts/test/crypto-helper.js" hkdf "$SP_MASTER_KEY" "$STUDY_ID" "$DM")"

inv "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
  '{"function":"RegisterIdentityReference","Args":[]}' \
  "{\"pii\":\"$PII\",\"identityReference\":\"$REF\"}" OrgIM OrgIM OrgWPI >/dev/null 2>&1
inv "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
  "{\"function\":\"RegisterWP\",\"Args\":[\"$REF\"]}" \
  "{\"wp\":\"$WP\"}" OrgWPI OrgWPI OrgHDW >/dev/null 2>&1
inv "$CHANNEL_STUDY" "$CC_STUDY" \
  "{\"function\":\"RegisterSPBatch\",\"Args\":[\"$DM\"]}" \
  "{\"studyKey\":\"$SK\",\"wpList\":[\"$WP\"]}" OrgSPI OrgSPI OrgSC >/dev/null 2>&1
SP="$(q OrgSC "$CHANNEL_STUDY" "$CC_STUDY" \
  "{\"function\":\"GetSPForWP\",\"Args\":[\"$DM\",\"$WP\"]}")"

# --- RO has WP but must not reach PII ---------------------------------------
echo "  RO — knows WP, must not reach PII"
expect_denied "RO cannot read Identity_Mapping to get PII from ref" \
  q OrgRO "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
  "{\"function\":\"GetPii\",\"Args\":[\"$REF\"]}"
expect_denied "RO cannot read Warehouse_Mapping directly" \
  q OrgRO "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
  "{\"function\":\"GetWP\",\"Args\":[\"$REF\"]}"
expect_denied "RO cannot read WarehouseReIdentification" \
  q OrgRO "$CHANNEL_WAREHOUSE" "$CC_WREID" \
  "{\"function\":\"GetReidentifiedPII\",\"Args\":[\"any\"]}"

# --- MO has read access to WarehouseReIdentification but must not reach
#     the pseudonymization graph through it --------------------------------
echo "  MO — authorized only for final PII, must not access pseudonymization"
expect_denied "MO cannot read Identity_Mapping" \
  q OrgMO "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
  "{\"function\":\"GetPii\",\"Args\":[\"$REF\"]}"
expect_denied "MO cannot read Warehouse_Mapping" \
  q OrgMO "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
  "{\"function\":\"GetWP\",\"Args\":[\"$REF\"]}"
expect_denied "MO cannot read Study_Mapping" \
  q OrgMO "$CHANNEL_STUDY" "$CC_STUDY" \
  "{\"function\":\"GetSPListByDatamart\",\"Args\":[\"$DM\"]}"

# --- SPI has SP but must not reach WP through any cross-channel path --------
echo "  SPI — knows SP, must not reach WP or PII except via study-mapping"
expect_denied "SPI cannot read Warehouse_Mapping" \
  q OrgSPI "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
  "{\"function\":\"GetWP\",\"Args\":[\"$REF\"]}"
expect_denied "SPI cannot read Identity_Mapping" \
  q OrgSPI "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
  "{\"function\":\"GetPii\",\"Args\":[\"$REF\"]}"
expect_denied "SPI cannot read WarehouseReIdentification" \
  q OrgSPI "$CHANNEL_WAREHOUSE" "$CC_WREID" \
  "{\"function\":\"GetReidentifiedPII\",\"Args\":[\"any\"]}"

# --- SC only sees Study_Mapping; must not reach WP ---------------------------
echo "  SC — knows study data, must not reach WP"
expect_denied "SC cannot read Warehouse_Mapping" \
  q OrgSC "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
  "{\"function\":\"GetWP\",\"Args\":[\"$REF\"]}"
expect_denied "SC cannot read Identity_Mapping" \
  q OrgSC "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
  "{\"function\":\"GetPii\",\"Args\":[\"$REF\"]}"

# --- HDW has WP but must not reach PII --------------------------------------
echo "  HDW — knows WP, must not reach PII"
expect_denied "HDW cannot read Identity_Mapping" \
  q OrgHDW "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
  "{\"function\":\"GetPii\",\"Args\":[\"$REF\"]}"
expect_denied "HDW cannot read WarehouseReIdentification" \
  q OrgHDW "$CHANNEL_WAREHOUSE" "$CC_WREID" \
  "{\"function\":\"GetReidentifiedPII\",\"Args\":[\"any\"]}"

# --- EC members are approvers, not data readers -----------------------------
echo "  EC1/2/3 — approvers, must not read any PDC"
for org in OrgEC1 OrgEC2 OrgEC3; do
  expect_denied "$org cannot read Identity_Mapping" \
    q "$org" "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
    "{\"function\":\"GetPii\",\"Args\":[\"$REF\"]}"
  expect_denied "$org cannot read Warehouse_Mapping" \
    q "$org" "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
    "{\"function\":\"GetWP\",\"Args\":[\"$REF\"]}"
  expect_denied "$org cannot read Study_Mapping" \
    q "$org" "$CHANNEL_STUDY" "$CC_STUDY" \
    "{\"function\":\"GetSPListByDatamart\",\"Args\":[\"$DM\"]}"
done

print_summary "Cross-channel leakage"