# Benchmarks — Performance of the PoC

## Pre-requisites

- Network up, chaincodes deployed, committee registered (`scripts/test/setup-committee.sh`)
- `flock`, `openssl`, `node`, `python3`, `jq`, `awk`, `column`, GNU `date` (with `+%s%N`)
- `invokeCC.sh` must support `CAPTURE_TXID_FILE` (needed by Scenario B)

## Scenarios

| Script | What it measures | Value added | Parameters |
|---|---|---|---|
| `scenario-f-cli-overhead.sh` | CLI + gRPC floor (query and invoke) | **Baseline** for every other measurement | `CLI_OVERHEAD_ITERATIONS` |
| `scenario-a-ingest.sh` | Pseudonymization pipeline + datamart assembly | Isolates cost per pseudonymization step (M1, M3, M5, M6) | `N_PATIENTS`, `BATCH_SIZE`, `CONCURRENCY` |
| `scenario-b-reid.sh` | Full re-identification flow, setup excluded | Defense number for the paper — the "reid is fast enough" claim (M4, M5, M6) | `REPEAT`, `CONCURRENCY_REID` |
| `scenario-c-load.sh` | Sustained load, ramp concurrency | Throughput ceiling and latency-degradation knee (M2, M6) | `LEVELS`, `OPS_PER_LEVEL` |
| `scenario-d-pdc-isolation.sh` | Isolated PDC read/write per collection | Pinpoints the slowest PDC (M3) | `PDC_ITERATIONS` |
| `scenario-e-payload-sweep.sh` | Study_Mapping write vs batch size | Empirical answer to "batch or per-patient" design choice (M3) | `PAYLOAD_SIZES` |

## ⚠ CLI overhead — read this before reporting numbers

Every operation in this suite spawns a **fresh `peer` CLI process** that pays:

| Step | Cost |
|---|---|
| Node.js CLI startup | ~250 ms |
| gRPC channel + TLS handshake | ~150 ms |
| Endorsement proposal → 2–5 peers | ~100–200 ms (parallel) |
| Orderer submit + wait for block cut | up to `BatchTimeout` (500 ms here) + propagation |
| Response processing | ~50 ms |

**Total floor per invoke: ~1.0–1.5 s. Per query: ~0.4–0.6 s.**

The chaincode itself (HMAC, JSON parse, one or two `putPrivateData` calls) runs in **~50–150 ms**. Everything above the floor is harness cost.

### How to handle this in the paper

1. **Always run `scenario-f-cli-overhead.sh` first.** It produces the baseline.
2. **Report both raw and adjusted numbers.** Raw for reproducibility, adjusted (`raw − baseline`) for chaincode-only claims.
   ```bash
   python3 analyze.py bench-results/scenario-b_*.csv --warmup 3 --baseline 1200