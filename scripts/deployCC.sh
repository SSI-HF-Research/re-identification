#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$ROOT/bin:$PATH"
export FABRIC_CFG_PATH="$ROOT/network"
cd "$ROOT"

source scripts/utils.sh
source scripts/envvar.sh
source scripts/ccutils.sh

CHANNEL_NAME=$1; shift
CC_NAME=$1; shift
CC_SRC_PATH=$1; shift
CC_VERSION=$1; shift
CC_SEQUENCE=$1; shift
CC_COLL_CONFIG_PATH=$1; shift
ORGS=("$@")

[ "${#ORGS[@]}" -eq 0 ] && fatalln "provide at least one org (all members of the channel)"

if [ "$CC_COLL_CONFIG_PATH" = "NA" ]; then
  CC_COLL_CONFIG=""
else
  CC_COLL_CONFIG="--collections-config $CC_COLL_CONFIG_PATH"
fi
CC_END_POLICY=""

infoln "Deploy chaincode:"
infoln "  channel=$CHANNEL_NAME name=$CC_NAME version=$CC_VERSION sequence=$CC_SEQUENCE"
infoln "  orgs=${ORGS[*]}"

jq --version > /dev/null 2>&1 || fatalln "jq not found (sudo apt-get install jq)"

infoln "[1/6] package"
./scripts/packageCC.sh "$CC_NAME" "$CC_SRC_PATH" "$CC_VERSION"
PACKAGE_ID=$(peer lifecycle chaincode calculatepackageid "${CC_NAME}.tar.gz")
successln "  package-id=$PACKAGE_ID"

infoln "[2/6] install"
for org in "${ORGS[@]}"; do installChaincode "$org"; done

infoln "[3/6] approve"
for org in "${ORGS[@]}"; do approveForOrg "$org"; done

infoln "[4/6] check commit readiness"
EXPECTED_CHECKS=()
for org in "${ORGS[@]}"; do
  setGlobalsForOrg "$org"
  EXPECTED_CHECKS+=("\"${CORE_PEER_LOCALMSPID}\": true")
done
checkCommitReadiness "${ORGS[0]}" "${EXPECTED_CHECKS[@]}"

infoln "[5/6] commit"
commitChaincodeDefinition "${ORGS[@]}"

infoln "[6/6] confirm"
for org in "${ORGS[@]}"; do queryCommitted "$org"; done

successln "Chaincode deploy complete."