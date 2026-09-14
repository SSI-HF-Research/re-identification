#!/bin/bash
# ============================================================================
# scenario-d-pdc-isolation.sh — Isolated PDC read/write latency per collection.
#
# PURPOSE
#   Times each PDC operation in isolation, with no other work interleaved.
#   Answers: which PDC is slowest to read from / write to?
#
# METRICS SERVED
#   M3 — reading/writing on each channel, each PDC (time)
#          D_identity_mapping_write       (2 endorsers)
#          D_warehouse_mapping_write      (2 endorsers)
#          D_study_mapping_write          (2 endorsers)
#          D_identity_mapping_read        (query)
#          D_warehouse_mapping_read       (query)
#          D_warehouse_mapping_read_reverse (query, reverse index)
#          D_study_mapping_read           (query)
#          D_study_mapping_read_reverse   (query, reverse index)
#          D_ledger_read_request          (baseline: ledger read vs PDC read)
#
# VALUE
#   Isolates the cost of each collection's read path vs its write path.
#   Comparing D_identity_mapping_write vs D_warehouse_mapping_write shows
#   the extra cost of the reverse index (1 write vs 2 writes per tx).
#   Comparing ledger_read_request vs the PDC reads shows whether the
#   PDC layer adds measurable overhead over plain ledger reads.
#
# CLI OVERHEAD
#   Every sample includes ~BASELINE_MS. Subtract for chaincode-only numbers.
#
# USAGE
#   PDC_ITERATIONS=30 ./scenario-d-pdc-isolation.sh
# ============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/bench/config.sh"
source "$ROOT/scripts/bench/lib.sh"

CSV="$BENCH_DIR/scenario-d-pdc-isolation.csv"
ensure_csv_header "$CSV"
DOCKERSTATS="$CSV.dockerstats"

echo ">> Scenario D: PDC isolation, iterations=$PDC_ITERATIONS"
echo ">> CSV: $CSV"

warmup_all

# Seed a fixed patient and datamart to read against
SEED_PII="seed-pii-$(openssl rand -hex 4)"
SEED_REF="ref-$(openssl rand -hex 16)"
SEED_WP="$(compute_wp "$SEED_PII")"
SEED_DM="seed-dm-$(openssl rand -hex 4)"
SEED_REQ="seed-req-$(openssl rand -hex 8)"

invoke "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
  '{"function":"RegisterIdentityReference","Args":[]}' \
  "{\"pii\":\"$SEED_PII\",\"identityReference\":\"$SEED_REF\"}" \
  OrgIM OrgIM OrgWPI >/dev/null
invoke "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
  "{\"function\":\"RegisterWP\",\"Args\":[\"$SEED_REF\"]}" \
  "{\"wp\":\"$SEED_WP\"}" OrgWPI OrgWPI OrgHDW >/dev/null
SK="$(compute_study_key "$STUDY_ID" "$SEED_DM")"
invoke "$CHANNEL_STUDY" "$CC_STUDY" \
  "{\"function\":\"RegisterSPBatch\",\"Args\":[\"$SEED_DM\"]}" \
  "{\"studyKey\":\"$SK\",\"wpList\":[\"$SEED_WP\"]}" OrgSPI OrgSPI OrgSC >/dev/null
SEED_SP="$(query OrgSC "$CHANNEL_STUDY" "$CC_STUDY" \
  "{\"function\":\"GetSPForWP\",\"Args\":[\"$SEED_DM\",\"$SEED_WP\"]}")"

# Seed a real ledger key so D_ledger_read_request returns 200
invoke "$CHANNEL_STUDY" "$CC_SREID" \
  "{\"function\":\"CreateReIDRequest\",\"Args\":[\"$STUDY_ID\",\"$SEED_DM\",\"$SEED_SP\"]}" \
  NA OrgRO OrgRO OrgSPI OrgSC OrgEC1 OrgEC2 >/dev/null 2>&1 || true

start_docker_stats "$DOCKERSTATS"

for iter in $(seq 1 "$PDC_ITERATIONS"); do
  out="$(mktemp)"

  # --- PDC writes (unique keys to avoid idempotency short-circuit) ----------
  p2="pdc-pii-${iter}-$(date +%s%N)"
  r2="pdc-ref-${iter}-$(openssl rand -hex 8)"

  time_cmd "$CSV" "D_identity_mapping_write" "$out" \
    "$ROOT/scripts/invokeCC.sh" "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
    '{"function":"RegisterIdentityReference","Args":[]}' \
    "{\"pii\":\"$p2\",\"identityReference\":\"$r2\"}" \
    OrgIM OrgIM OrgWPI

  w2="$(compute_wp "$p2")"
  time_cmd "$CSV" "D_warehouse_mapping_write" "$out" \
    "$ROOT/scripts/invokeCC.sh" "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
    "{\"function\":\"RegisterWP\",\"Args\":[\"$r2\"]}" \
    "{\"wp\":\"$w2\"}" OrgWPI OrgWPI OrgHDW

  dm2="pdc-dm-${iter}-$(openssl rand -hex 4)"
  sk2="$(compute_study_key "$STUDY_ID" "$dm2")"
  time_cmd "$CSV" "D_study_mapping_write" "$out" \
    "$ROOT/scripts/invokeCC.sh" "$CHANNEL_STUDY" "$CC_STUDY" \
    "{\"function\":\"RegisterSPBatch\",\"Args\":[\"$dm2\"]}" \
    "{\"studyKey\":\"$sk2\",\"wpList\":[\"$SEED_WP\"]}" \
    OrgSPI OrgSPI OrgSC

  # --- PDC reads ----------------------------------------------------------
  time_cmd "$CSV" "D_identity_mapping_read" "$out" \
    "$ROOT/scripts/queryCC.sh" OrgWPI "$CHANNEL_WAREHOUSE" "$CC_IDENTITY" \
    "{\"function\":\"GetPii\",\"Args\":[\"$SEED_REF\"]}"

  time_cmd "$CSV" "D_warehouse_mapping_read" "$out" \
    "$ROOT/scripts/queryCC.sh" OrgHDW "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
    "{\"function\":\"GetWP\",\"Args\":[\"$SEED_REF\"]}"

  time_cmd "$CSV" "D_warehouse_mapping_read_reverse" "$out" \
    "$ROOT/scripts/queryCC.sh" OrgWPI "$CHANNEL_WAREHOUSE" "$CC_WAREHOUSE" \
    "{\"function\":\"GetIdentityReferenceByWP\",\"Args\":[\"$SEED_WP\"]}"

  time_cmd "$CSV" "D_study_mapping_read" "$out" \
    "$ROOT/scripts/queryCC.sh" OrgSC "$CHANNEL_STUDY" "$CC_STUDY" \
    "{\"function\":\"GetSPForWP\",\"Args\":[\"$SEED_DM\",\"$SEED_WP\"]}"

  time_cmd "$CSV" "D_study_mapping_read_reverse" "$out" \
    "$ROOT/scripts/queryCC.sh" OrgSPI "$CHANNEL_STUDY" "$CC_STUDY" \
    "{\"function\":\"GetWPBySP\",\"Args\":[\"$SEED_SP\"]}"

  # --- Ledger read (baseline) -------------------------------------------
  time_cmd "$CSV" "D_ledger_read_request" "$out" \
    "$ROOT/scripts/queryCC.sh" OrgRO "$CHANNEL_STUDY" "$CC_SREID" \
    "{\"function\":\"GetReIDRequest\",\"Args\":[\"seed-not-found\"]}"

  rm -f "$out"
done

stop_docker_stats "$DOCKERSTATS"

echo ""
echo ">> Scenario D complete. CSV: $CSV"
echo ">> Analyze: python3 $ROOT/scripts/bench/analyze.py $CSV --warmup 3 --baseline $BASELINE_MS"