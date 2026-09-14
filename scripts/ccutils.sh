#!/bin/bash
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/utils.sh"
source "$ROOT/scripts/envvar.sh"

: "${DELAY:=3}"
: "${MAX_RETRY:=5}"
: "${ORDERER_ADDRESS:=localhost:7050}"
: "${ORDERER_HOSTNAME_OVERRIDE:=orderer.example.com}"
: "${FABRIC_LOG_FILE:=log.txt}"

installChaincode() {
  local org="$1"
  setGlobalsForOrg "$org"
  if peer lifecycle chaincode install "${CC_NAME}.tar.gz" >"$FABRIC_LOG_FILE" 2>&1; then
    successln "  [$org] installed"
  else
    if grep -q "chaincode already successfully installed" "$FABRIC_LOG_FILE"; then
      warnln "  [$org] already installed"
    else
      cat "$FABRIC_LOG_FILE"
      fatalln "  [$org] install failed"
    fi
  fi
}

approveForOrg() {
  local org="$1"
  setGlobalsForOrg "$org"
  peer lifecycle chaincode approveformyorg \
    -o "$ORDERER_ADDRESS" --ordererTLSHostnameOverride "$ORDERER_HOSTNAME_OVERRIDE" \
    --tls --cafile "$ORDERER_CA" \
    --channelID "$CHANNEL_NAME" --name "$CC_NAME" --version "$CC_VERSION" \
    --package-id "$PACKAGE_ID" --sequence "$CC_SEQUENCE" \
    $CC_COLL_CONFIG $CC_END_POLICY >"$FABRIC_LOG_FILE" 2>&1
  local res=$?
  if [ $res -ne 0 ]; then
    cat "$FABRIC_LOG_FILE"
    fatalln "  [$org] approve failed"
  fi
  successln "  [$org] approved"
}

checkCommitReadiness() {
  local org="$1"; shift
  setGlobalsForOrg "$org"
  local rc=1 COUNTER=1
  while [ $rc -ne 0 ] && [ $COUNTER -lt $MAX_RETRY ]; do
    sleep $DELAY
    peer lifecycle chaincode checkcommitreadiness \
      --channelID "$CHANNEL_NAME" --name "$CC_NAME" --version "$CC_VERSION" \
      --sequence "$CC_SEQUENCE" $CC_COLL_CONFIG $CC_END_POLICY --output json >"$FABRIC_LOG_FILE" 2>&1
    rc=0
    for check in "$@"; do
      grep -F "$check" "$FABRIC_LOG_FILE" >/dev/null || rc=1
    done
    COUNTER=$((COUNTER + 1))
  done
  if [ $rc -ne 0 ]; then
    cat "$FABRIC_LOG_FILE"
    fatalln "  commit readiness did not match"
  fi
  successln "  commit readiness OK"
}

commitChaincodeDefinition() {
  parsePeerConnectionParameters "$@"
  peer lifecycle chaincode commit \
    -o "$ORDERER_ADDRESS" --ordererTLSHostnameOverride "$ORDERER_HOSTNAME_OVERRIDE" \
    --tls --cafile "$ORDERER_CA" \
    --channelID "$CHANNEL_NAME" --name "$CC_NAME" \
    "${PEER_CONN_PARMS[@]}" \
    --version "$CC_VERSION" --sequence "$CC_SEQUENCE" \
    $CC_COLL_CONFIG $CC_END_POLICY >"$FABRIC_LOG_FILE" 2>&1
  local res=$?
  if [ $res -ne 0 ]; then
    cat "$FABRIC_LOG_FILE"
    fatalln "  commit failed"
  fi
  successln "  committed"
}

queryCommitted() {
  local org="$1"
  setGlobalsForOrg "$org"
  peer lifecycle chaincode querycommitted \
    --channelID "$CHANNEL_NAME" --name "$CC_NAME" >"$FABRIC_LOG_FILE" 2>&1
  local res=$?
  if [ $res -ne 0 ]; then
    cat "$FABRIC_LOG_FILE"
    fatalln "  [$org] querycommitted failed"
  fi
  successln "  [$org] committed definition OK"
}