#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/network"
export PATH="$ROOT/bin:$PATH"

ORDERER_CA=crypto-config/ordererOrganizations/example.com/orderers/orderer.example.com/tls/ca.crt
ORDERER_ADMIN_TLS_SIGN_CERT=crypto-config/ordererOrganizations/example.com/orderers/orderer.example.com/tls/server.crt
ORDERER_ADMIN_TLS_PRIVATE_KEY=crypto-config/ordererOrganizations/example.com/orderers/orderer.example.com/tls/server.key

echo ">> associating orderer to warehouse-channel"
osnadmin channel join \
  --channelID warehouse-channel \
  --config-block channel-artifacts/warehouse-channel.block \
  -o localhost:7053 \
  --ca-file "$ORDERER_CA" \
  --client-cert "$ORDERER_ADMIN_TLS_SIGN_CERT" \
  --client-key "$ORDERER_ADMIN_TLS_PRIVATE_KEY"

echo ""
echo ">> associating orderer to study-channel"
osnadmin channel join \
  --channelID study-channel \
  --config-block channel-artifacts/study-channel.block \
  -o localhost:7053 \
  --ca-file "$ORDERER_CA" \
  --client-cert "$ORDERER_ADMIN_TLS_SIGN_CERT" \
  --client-key "$ORDERER_ADMIN_TLS_PRIVATE_KEY"

echo ""
echo ">> checking channels in orderer:"
osnadmin channel list \
  -o localhost:7053 \
  --ca-file "$ORDERER_CA" \
  --client-cert "$ORDERER_ADMIN_TLS_SIGN_CERT" \
  --client-key "$ORDERER_ADMIN_TLS_PRIVATE_KEY"
