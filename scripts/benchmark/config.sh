#!/bin/bash

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

CHANNEL_WAREHOUSE="${CHANNEL_WAREHOUSE:-warehouse-channel}"
CHANNEL_STUDY="${CHANNEL_STUDY:-study-channel}"

CC_IDENTITY="${CC_IDENTITY:-identity-mapping}"
CC_WAREHOUSE="${CC_WAREHOUSE:-warehouse-mapping}"
CC_STUDY="${CC_STUDY:-study-mapping}"
CC_SREID="${CC_SREID:-study-reidentification}"
CC_WREID="${CC_WREID:-warehouse-reidentification}"

WP_MASTER_KEY="${WP_MASTER_KEY:-bench-wp-master-key}"
SP_MASTER_KEY="${SP_MASTER_KEY:-bench-sp-master-key}"
STUDY_ID="${STUDY_ID:-bench-study}"

# A
N_PATIENTS="${N_PATIENTS:-50}"
BATCH_SIZE="${BATCH_SIZE:-10}"
CONCURRENCY="${CONCURRENCY:-1}"

# B
REPEAT="${REPEAT:-5}"
CONCURRENCY_REID="${CONCURRENCY_REID:-1}"

# C
LEVELS="${LEVELS:-1 2 4 8 16}"
OPS_PER_LEVEL="${OPS_PER_LEVEL:-20}"

BENCH_DIR="${BENCH_DIR:-$ROOT/bench-results}"
mkdir -p "$BENCH_DIR"
