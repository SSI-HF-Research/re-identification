#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$ROOT/bin:$PATH"
export FABRIC_CFG_PATH="$ROOT/network"
source "$ROOT/scripts/envvar.sh"

WAREHOUSE_CHANNEL_BLOCK="$ROOT/network/channel-artifacts/warehouse-channel.block"
STUDY_CHANNEL_BLOCK="$ROOT/network/channel-artifacts/study-channel.block"

echo ">> Peers of Warehouse Channel entering in warehouse-channel"
for org in setOrgIM setOrgWPI setOrgHDW setOrgMO setOrgRO setOrgEC1 setOrgEC2 setOrgEC3; do
  $org
  peer channel join -b "$WAREHOUSE_CHANNEL_BLOCK"
done

echo ""
echo ">> Peers of Study Channel entering in study-channel"
for org in setOrgSC setOrgSPI setOrgMO setOrgRO setOrgEC1 setOrgEC2 setOrgEC3; do
  $org
  peer channel join -b "$STUDY_CHANNEL_BLOCK"
done

echo ""
echo ">> ================================================"
echo ">> checking isolation between channels"
echo ">> ================================================"
for org in setOrgIM setOrgWPI setOrgHDW setOrgSC setOrgSPI setOrgMO setOrgRO setOrgEC1 setOrgEC2 setOrgEC3; do
  $org
  echo "--- $CORE_PEER_LOCALMSPID ($CORE_PEER_ADDRESS) is in the following channels: ---"
  peer channel list
done

echo ""
echo ">> If everything is correct:"
echo "   OrgIM / OrgWPI / OrgHDW  -> only warehouse-channel"
echo "   OrgSC / OrgSPI  -> only study-channel"
echo "   OrgMO / OrgRO / setOrgEC1 / setOrgEC2 / setOrgEC3 -> both channels"
