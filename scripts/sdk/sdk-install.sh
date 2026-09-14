#!/bin/bash
# ============================================================================
# install.sh — Installs the fabric-gateway client dependencies.
# Run once before using USE_SDK=1 in the benchmark suite.
# ============================================================================
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

if [ ! -f package.json ]; then
  echo "!! package.json missing"
  exit 1
fi

echo ">> npm install (fabric-gateway + grpc-js)"
npm install --no-audit --no-fund
echo ">> OK. Node modules installed in $HERE/node_modules"