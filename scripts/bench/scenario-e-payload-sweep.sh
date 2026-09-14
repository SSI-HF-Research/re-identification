#!/bin/bash
# ============================================================================
# scenario-e-payload-sweep.sh — Payload size sweep for Study_Mapping writes.
#
# PURPOSE
#   Measures how RegisterSPBatch write latency grows with batch size, and
#   finds the practical ceiling (endorsement failure, timeout, or
#   payload rejection).
#
# METRICS SERVED
#   M3 — payload effect on PDC write latency
#          E_register_sp_batch_payload_<N> for each N in PAYLOAD_SIZES
#
# VALUE
#   Directly informs the design decision documented in the PoC's Phase 2:
#   "single list per datamart vs. one write per patient". The result is the
#   empirical answer to that open question.
#
# CLI OVERHEAD
#   At large payload sizes (>500), CLI overhead is amortized: the network
#   and PDC write dominate. At small sizes the CLI is the floor.
#
# USAGE
#   PAYLOAD_SIZES="1 10 100 500 1000" ./scenario-e-payload-sweep.sh
# ============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT/scripts/bench/config.sh"
source "$ROOT/scripts/bench/lib.sh"

CSV="$BENCH_DIR/scenario-e-payload-sweep.csv"
ensure_csv_header "$CSV"
DOCKERSTATS="$CSV.dockerstats"

echo ">> Scenario E: payload sizes=$PAYLOAD_SIZES"
echo ">> CSV: $CSV"

warmup_all
start_docker_stats "$DOCKERSTATS"

for size in $PAYLOAD_SIZES; do
  echo ">> size=$size WPs/batch"

  wp_list_json="["
  for ((k=0; k<size; k++)); do
    [ "$k" -gt 0 ] && wp_list_json+=","
    wp_list_json+="\"wp-$(openssl rand -hex 32)\""
  done
  wp_list_json+="]"

  dm="payload-dm-${size}-$(openssl rand -hex 4)"
  sk="$(compute_study_key "$STUDY_ID" "$dm")"

  out="$(mktemp)"
  time_cmd "$CSV" "E_register_sp_batch_payload_${size}" "$out" \
    "$ROOT/scripts/invokeCC.sh" "$CHANNEL_STUDY" "$CC_STUDY" \
    "{\"function\":\"RegisterSPBatch\",\"Args\":[\"$dm\"]}" \
    "{\"studyKey\":\"$sk\",\"wpList\":$wp_list_json}" \
    OrgSPI OrgSPI OrgSC
  rc=$?
  rm -f "$out"

  [ $rc -eq 0 ] && echo "   ok   size=$size" || echo "   FAIL size=$size (see CSV)"
done

stop_docker_stats "$DOCKERSTATS"

echo ""
echo ">> Scenario E complete. CSV: $CSV"