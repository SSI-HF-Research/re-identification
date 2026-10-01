#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
source scripts/utils.sh

# End-to-end flow:
# 1) register EC + SPI public keys on both channels
# 2) study side: request + K-of-N EC + SPI attestation + bundle export
# 3) warehouse side: verify EC quorum + SPI attestation, then recover PII
CTX="$(mktemp)"; trap 'rm -f "$CTX"' EXIT

infoln "=== Setup: register EC + SPI keys ==="
./scripts/test/setup-committee.sh

infoln ""
infoln "=== Study side: request + K-of-N + SPI attestation ==="
STUDY_OUT_FILE="$CTX" ./scripts/test/reid-study.sh

source "$CTX"

infoln ""
infoln "=== Warehouse side: verify K-of-N + SPI attestation + re-identify ==="
REQ_ID="$REQ_ID" \
WP="$WP" \
SPI_SIGNATURE="$SPI_SIGNATURE" \
APPROVALS_JSON="$APPROVALS_JSON" \
  ./scripts/test/reid-warehouse.sh

successln ""
successln "======================================================"
successln " Full re-identification — OK (K-of-N + SPI attestation)"
successln "======================================================"