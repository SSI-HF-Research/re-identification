#!/bin/bash
# usage: queryCC.sh <org> <channel> <cc_name> '<ctor_json>'
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$ROOT/bin:$PATH"
export FABRIC_CFG_PATH="$ROOT/network"
cd "$ROOT"
source scripts/utils.sh
source scripts/envvar.sh

ORG=$1; shift
CHANNEL_NAME=$1; shift
CC_NAME=$1; shift
CTOR_JSON=$1; shift

setGlobalsForOrg "$ORG"
peer chaincode query -C "$CHANNEL_NAME" -n "$CC_NAME" -c "$CTOR_JSON"