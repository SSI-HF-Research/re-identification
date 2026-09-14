#!/bin/bash
# ============================================================================
# scenario-f-cli-overhead.sh — Measure the CLI floor (baseline).
#
# PURPOSE
#   Every other scenario's numbers include the cost of spawning the Fabric
#   peer CLI, opening a gRPC channel, doing TLS, and waiting for commit.
#   This script measures that floor so you can subtract it and report
#   chaincode-only costs.
#
# METRICS SERVED
#   F_query_floor    — trivial query (testChaincode) round-trip
#   F_invoke_floor   — trivial idempotent invoke (re-register existing ref)
#
# VALUE
#   Produces BASELINE_MS for analyze.py --baseline. Enables the paper to
#   state: "raw measurement X ms; chaincode-only X - F ms". Without this
#   number every claim about chaincode latency is indefensible.
#
# HOW TO USE
#   Run this once per configuration. Copy the F_query_floor p50 into
#   BASELINE_MS and re-run the other scenarios with `--baseline MS`.
#
# USAGE
#   CLI_OVERHEAD_ITERATIONS=50 ./scenario-f-cli-overhead.sh
# ============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/bench/config.sh"
source "$ROOT/scripts/bench/lib.sh"

CSV="$BENCH_DIR/scenario-f-cli-overhead.csv"
ensure_csv_header "$CSV"
DOCKERSTATS="$CSV.dockerstats"

echo ">> Scenario F: CLI overhead floor, iterations=$CLI_OVERHEAD_ITERATIONS"
echo ">> CSV: $CSV"

warmup_all
start_docker_stats "$DOCKERSTATS"

# Seed one idempotency anchor so the invoke_floor uses a real, existing ref
ANCHOR_PII="anchor-pii-$(openssl rand -hex 4)"
ANCHOR_REF="anchor-ref-$(openssl rand -hex 8)"
invoke "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
  '{"function":"RegisterIdentityReference","Args":[]}' \
  "{\"pii\":\"$ANCHOR_PII\",\"identityReference\":\"$ANCHOR_REF\"}" \
  OrgIM OrgIM OrgWPI >/dev/null 2>&1 || true

for iter in $(seq 1 "$CLI_OVERHEAD_ITERATIONS"); do
  out="$(mktemp)"

  # Query floor — trivial chaincode function, no state read
  time_cmd "$CSV" "F_query_floor" "$out" \
    "$ROOT/scripts/queryCC.sh" OrgIM "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
    '{"function":"testChaincode","Args":[]}'

  # Invoke floor — idempotent register, returns early, no state change
  time_cmd "$CSV" "F_invoke_floor" "$out" \
    "$ROOT/scripts/invokeCC.sh" "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
    '{"function":"RegisterIdentityReference","Args":[]}' \
    "{\"pii\":\"$ANCHOR_PII\",\"identityReference\":\"$ANCHOR_REF\"}" \
    OrgIM OrgIM OrgWPI

  rm -f "$out"
done

stop_docker_stats "$DOCKERSTATS"

echo ""
echo ">> Scenario F complete. CSV: $CSV"
echo ">> To compute the baseline:"
echo "   python3 $ROOT/scripts/bench/analyze.py $CSV --warmup 5"
echo "   Copy the p50 of F_query_floor into BASELINE_MS and re-run other scenarios"
echo "   with:  analyze.py <csv> --baseline <BASELINE_MS>"