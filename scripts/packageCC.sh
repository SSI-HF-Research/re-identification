#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$ROOT/bin:$PATH"
export FABRIC_CFG_PATH="$ROOT/network"
source "$ROOT/scripts/utils.sh"

CC_NAME=$1
CC_SRC_PATH=$2
CC_VERSION=$3
PACKAGE_LOG="${PACKAGE_LOG:-${FABRIC_LOG_FILE:-log.txt}}"

infoln "  packaging $CC_NAME v$CC_VERSION"
pushd "$CC_SRC_PATH" >/dev/null
npm install --silent >/dev/null 2>&1
npm run build --silent >/dev/null 2>&1
popd >/dev/null

peer lifecycle chaincode package "${CC_NAME}.tar.gz" \
  --path "$CC_SRC_PATH" --lang node --label "${CC_NAME}_${CC_VERSION}" >"$PACKAGE_LOG" 2>&1
res=$?
if [ $res -ne 0 ]; then
  cat "$PACKAGE_LOG"
  fatalln "  packaging failed"
fi
successln "  package created: ${CC_NAME}.tar.gz"