#!/bin/bash
# ============================================================================
# 00-config.sh — Central configuration for the benchmark suite.
#
# PURPOSE
#   Single source of truth for channel names, chaincode names, crypto keys,
#   default parameters, and operational flags. Override any value by exporting
#   it in the shell before calling a scenario script.
#
# METRICS SERVED
#   - Defines the values every scenario depends on (no metric of its own).
#
# MITIGATION OF CLI OVERHEAD
#   - COLLECT_DOCKER_STATS: 1 Hz container stats to correlate latency with
#     resource saturation (the CLI itself is a large contributor).
#   - WARMUP_ENABLED: forces a testChaincode call on every chaincode before
#     measurement so cold-start cost is not paid on the first sample.
#   - BASELINE_MS: when set, analyze.py subtracts it from every sample. Fill
#     it from scenario-f-cli-overhead.sh.
# ============================================================================

# --- Channels / chaincodes --------------------------------------------------
CHANNEL_WAREHOUSE="${CHANNEL_WAREHOUSE:-warehouse-channel}"
CHANNEL_STUDY="${CHANNEL_STUDY:-study-channel}"
CC_IDENTITY="${CC_IDENTITY:-identity-mapping}"
CC_WAREHOUSE="${CC_WAREHOUSE:-warehouse-mapping}"
CC_STUDY="${CC_STUDY:-study-mapping}"
CC_SREID="${CC_SREID:-study-reidentification}"
CC_WREID="${CC_WREID:-warehouse-reidentification}"

# --- Crypto / domain --------------------------------------------------------
WP_MASTER_KEY="${WP_MASTER_KEY:-test-wp-master-key}"
SP_MASTER_KEY="${SP_MASTER_KEY:-test-sp-master-key}"
STUDY_ID="${STUDY_ID:-study-poc}"

# --- Output paths -----------------------------------------------------------
BENCH_DIR="${BENCH_DIR:-$ROOT/bench-results}"
mkdir -p "$BENCH_DIR"

# --- Operational flags ------------------------------------------------------
COLLECT_DOCKER_STATS="${COLLECT_DOCKER_STATS:-1}"
DOCKER_STATS_INTERVAL="${DOCKER_STATS_INTERVAL:-1}"
WARMUP_ENABLED="${WARMUP_ENABLED:-1}"

# Baseline CLI overhead in ms. Set this after running scenario-f.
# analyze.py --baseline N will subtract it from every successful sample.
BASELINE_MS="${BASELINE_MS:-0}"

# --- Scenario defaults ------------------------------------------------------
N_PATIENTS="${N_PATIENTS:-100}"
BATCH_SIZE="${BATCH_SIZE:-20}"
CONCURRENCY="${CONCURRENCY:-8}"
REPEAT="${REPEAT:-20}"
CONCURRENCY_REID="${CONCURRENCY_REID:-1}"
LEVELS="${LEVELS:-1 2 4 8 16}"
OPS_PER_LEVEL="${OPS_PER_LEVEL:-50}"
PDC_ITERATIONS="${PDC_ITERATIONS:-20}"
PAYLOAD_SIZES="${PAYLOAD_SIZES:-1 10 100 500 1000}"
CLI_OVERHEAD_ITERATIONS="${CLI_OVERHEAD_ITERATIONS:-30}"