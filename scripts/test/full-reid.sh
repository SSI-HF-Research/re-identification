#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
source scripts/utils.sh

CTX="$(mktemp)"; trap 'rm -f "$CTX"' EXIT

infoln "=== Setup: registrar committee keys ==="
./scripts/test/setup-committee.sh

infoln ""
infoln "=== Lado study: request + K-of-N + resolve ==="
STUDY_OUT_FILE="$CTX" ./scripts/test/reid-study.sh

source "$CTX"

infoln ""
infoln "=== Lado warehouse: verifica K-of-N + reidentifica ==="
REQ_ID="$REQ_ID" WP="$WP" APPROVALS_JSON="$APPROVALS_JSON" \
  ./scripts/test/reid-warehouse.sh

successln ""
successln "======================================================"
successln " Fase 5 E2E — OK: K-of-N (K=2/3) validado on-chain"
successln "======================================================"