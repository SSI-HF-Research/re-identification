#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$ROOT/bin:$PATH"
export FABRIC_CFG_PATH="$ROOT/network"
cd "$ROOT"
source scripts/utils.sh
source scripts/envvar.sh

CHANNEL_NAME=$1; shift
CC_NAME=$1; shift
CTOR_JSON=$1; shift
TRANSIENT_JSON=$1; shift
CALLER_ORG=$1; shift
ENDORSER_ORGS=("$@")

[ "${#ENDORSER_ORGS[@]}" -eq 0 ] && fatalln "provide at least one endorser org"

setGlobalsForOrg "$CALLER_ORG"
CALLER_MSP="$CORE_PEER_LOCALMSPID"

PEER_CONN_PARMS=()
for org in "${ENDORSER_ORGS[@]}"; do
  saved_addr="$CORE_PEER_ADDRESS"
  saved_tls="$CORE_PEER_TLS_ROOTCERT_FILE"
  saved_msp="$CORE_PEER_LOCALMSPID"
  saved_cfg="$CORE_PEER_MSPCONFIGPATH"

  setGlobalsForOrg "$org"
  PEER_CONN_PARMS+=(--peerAddresses "$CORE_PEER_ADDRESS" --tlsRootCertFiles "$CORE_PEER_TLS_ROOTCERT_FILE")

  export CORE_PEER_ADDRESS="$saved_addr"
  export CORE_PEER_TLS_ROOTCERT_FILE="$saved_tls"
  export CORE_PEER_LOCALMSPID="$saved_msp"
  export CORE_PEER_MSPCONFIGPATH="$saved_cfg"
done

TRANSIENT_FLAG=()
if [ "$TRANSIENT_JSON" != "NA" ]; then
  TRANSIENT_ENCODED=$(echo -n "$TRANSIENT_JSON" | jq -c -r 'to_entries | map({key: .key, value: (.value | @base64)}) | from_entries')
  TRANSIENT_FLAG=(--transient "$TRANSIENT_ENCODED")
fi

infoln "Invoke $CC_NAME on $CHANNEL_NAME"
infoln "  caller=$CALLER_MSP"
infoln "  endorsers=${ENDORSER_ORGS[*]}"
set +e
INVOKE_OUTPUT=$(peer chaincode invoke \
  -o "${ORDERER_ADDRESS:-localhost:7050}" \
  --ordererTLSHostnameOverride "${ORDERER_HOSTNAME_OVERRIDE:-orderer.example.com}" \
  --tls --cafile "$ORDERER_CA" \
  -C "$CHANNEL_NAME" -n "$CC_NAME" -c "$CTOR_JSON" \
  --waitForEvent --waitForEventTimeout 30s \
  "${TRANSIENT_FLAG[@]}" "${PEER_CONN_PARMS[@]}" 2>&1)
INVOKE_RC=$?
set -e

echo "$INVOKE_OUTPUT"

if [ "$INVOKE_RC" -ne 0 ]; then
  exit "$INVOKE_RC"
fi

if [ -n "${CAPTURE_TXID_FILE:-}" ]; then
  RESULT=$(echo "$INVOKE_OUTPUT" \
    | grep -oE 'payload:"[^"]*"' \
    | head -n1 \
    | sed -E 's/payload:"(.*)"/\1/') || true

  if [ -z "$RESULT" ]; then
    RESULT=$(echo "$INVOKE_OUTPUT" \
      | grep -oE 'txid \[[0-9a-f]+\]' \
      | head -n1 \
      | sed -E 's/txid \[(.*)\]/\1/') || true
  fi

  if [ -n "$RESULT" ]; then
    echo "$RESULT" > "$CAPTURE_TXID_FILE"
  fi
fi