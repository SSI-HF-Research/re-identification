#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
source scripts/utils.sh

# End-to-end flow:
# 1) register the committee public keys,
# 2) execute the study-side request and K-of-N approval flow,
# 3) verify the approvals on the warehouse side and recover the original PII.
CTX="$(mktemp)"; trap 'rm -f "$CTX"' EXIT

infoln "=== Setup: register committee keys ==="
./scripts/test/setup-committee.sh

infoln ""
infoln "=== Study side: request + K-of-N + resolve ==="
STUDY_OUT_FILE="$CTX" ./scripts/test/reid-study.sh

source "$CTX"

infoln ""
infoln "=== Warehouse side: verify K-of-N + re-identify ==="
REQ_ID="$REQ_ID" WP="$WP" APPROVALS_JSON="$APPROVALS_JSON" \
  ./scripts/test/reid-warehouse.sh

successln ""
successln "======================================================"
successln " Full re-identification — OK: K-of-N (K=2/3) validated on-chain"
successln "======================================================"