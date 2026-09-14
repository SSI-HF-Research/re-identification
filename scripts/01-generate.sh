#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/network"
export PATH="$ROOT/bin:$PATH"
export FABRIC_CFG_PATH="$ROOT/network"

rm -rf crypto-config channel-artifacts
mkdir -p channel-artifacts

echo ">> [1/2] generating cryptographic material (cryptogen)"
cryptogen generate --config=crypto-config.yaml --output=crypto-config

echo ">> [2/2] generating config blocks for the channels (configtxgen)"
configtxgen -profile WarehouseChannel -outputBlock channel-artifacts/warehouse-channel.block -channelID warehouse-channel
configtxgen -profile StudyChannel -outputBlock channel-artifacts/study-channel.block -channelID study-channel

echo ">> OK. artifacts generated in network/crypto-config and network/channel-artifacts"
