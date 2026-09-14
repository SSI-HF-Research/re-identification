#!/bin/bash
# ============================================================================
# test-channel-isolation.sh — Verifies channel membership boundaries.
#
# PURPOSE
#   Asserts that orgs NOT in a channel cannot query chaincodes deployed to
#   that channel. This is the outermost layer of isolation: if it fails,
#   nothing downstream matters.
#
# METRICS SERVED
#   Security assertion:
#     - HDW / WPI-only orgs cannot query study-channel
#     - SC / SPI-only orgs cannot query warehouse-channel
#     - Orgs that belong to both (MO, RO, EC1, EC2, EC3) can query both
#
# VALUE
#   Proves the channel-level boundary that the whole pseudonymization
#   architecture depends on. Without this, PDC isolation is moot.
# ============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/security/00-config.sh"
source "$ROOT/scripts/security/lib.sh"

RESULTS_FILE="$SEC_DIR/test-channel-isolation.csv"
: > "$RESULTS_FILE"

echo ">> test-channel-isolation"

# --- Only-in-warehouse orgs must NOT read study-channel ---------------------
for org in OrgIM OrgWPI OrgHDW; do
  expect_denied "$org cannot query study-channel/study-mapping" \
    q "$org" "$CHANNEL_STUDY" "$CC_STUDY" \
    '{"function":"testChaincode","Args":[]}'
done

# --- Only-in-study orgs must NOT read warehouse-channel ---------------------
for org in OrgSC OrgSPI; do
  expect_denied "$org cannot query warehouse-channel/identity-mapping" \
    q "$org" "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
    '{"function":"testChaincode","Args":[]}'
done

# --- Both-channel orgs must be able to query both ---------------------------
for org in OrgMO OrgRO OrgEC1 OrgEC2 OrgEC3; do
  expect_allowed "$org can query warehouse-channel/identity-mapping" \
    q "$org" "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
    '{"function":"testChaincode","Args":[]}'
  expect_allowed "$org can query study-channel/study-mapping" \
    q "$org" "$CHANNEL_STUDY" "$CC_STUDY" \
    '{"function":"testChaincode","Args":[]}'
done

print_summary "Channel isolation"