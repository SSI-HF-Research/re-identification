# Benchmarks — Scenarios A, B, C

This benchmark suite measures the cost of the main operations in the privacy-preserving re-identification workflow on Hyperledger Fabric. The goal is to quantify how long each pipeline stage takes, how it scales with workload and concurrency, and which part of the process dominates the end-to-end latency.

The scripts generate CSV files under `bench-results/` with the format:
`label,duration_ms,success,timestamp`

These measurements are intended to support the evaluation section of the article.

## Prerequisites
- Network already running; all chaincodes deployed and the committee (EC1/EC2/EC3)
  already registered via `setup-committee.sh`
- `flock`, `openssl`, `node`, `python3`, `jq`, `awk`, GNU `date` (supports `+%s%N`)
- Scripts placed in `scripts/bench/` inside your project, alongside
  `invokeCC.sh`, `queryCC.sh`, `utils.sh`, `envvar.sh`, and the `scripts/test/`
  folder (`crypto-helper.js`, `ec-sign.js`)


## What is being done
Each scenario exercises a specific part of the workflow and records duration in milliseconds for each operation. The main idea is to isolate the cost of each stage rather than measuring only an aggregate end-to-end time. The scripts:

- prepare synthetic datasets and identities
- submit transactions to Fabric chaincodes under controlled concurrency
- capture successful and failed operations
- write one or more CSV files with labeled measurement samples
- allow benchmarking of different workload sizes and parallelism levels

This makes it possible to compare the cost of ingestion, re-identification, reading/writing across channels, and overall scalability.

## Scenarios

| Script | Goal | Metric(s) measured | Main parameters |
|---|---|---|---|
| `scenario-a-ingest.sh` | Measure pseudo-anonymization and channel-level data writing operations; evaluate how the ingestion pipeline behaves under different patient counts and batch sizes | `N_PATIENTS`, `BATCH_SIZE`, `CONCURRENCY` |
| `scenario-b-reid.sh` | Measure the re-identification process, including request creation and follow-up operations; evaluate latency and concurrency impact | `REPEAT`, `CONCURRENCY_REID` |
| `scenario-c-load.sh` | Measure the transaction latency and throughput under multi-level load; evaluate how the system scales with parallel demand | `LEVELS`, `OPS_PER_LEVEL` |

### Scenario A — ingestion / pseudo-anonymization
Goal: quantify how long it takes to process patient data and write the relevant records to the appropriate channels/PDCs. This is the part that corresponds to pseudo-anonymization and downstream data organization.

Metrics:
- time to pseudo-anonymize or transform each data level
- time spent reading/writing on each channel or PDC
- part of the protection/re-identification flow that executes as part of ingestion
- scalability as load, concurrency, and batch size change

### Scenario B — re-identification workflow
Goal: quantify the total time spent in re-identification operations, including request creation and the chaincode logic that links identities to the corresponding data. This is the core privacy-sensitive workflow in the study.

Metrics:
- total time for the re-identification process
- additional steps in the identity/privacy pipeline
- scalability under repeated re-identification attempts and concurrent workers

### Scenario C — throughput/load test
Goal: evaluate transaction latency and maximum throughput under increasing load, representing the workload that the network must sustain during normal operation.

Metrics:
- transaction latency and maximum throughput
- scaling behavior across increasing levels of parallelism and requests per level

## Analyzing the results

Each scenario writes one or more CSV files in `bench-results/` with the format:
`label,duration_ms,success,timestamp`.

`--warmup N` removes the first `N` samples of each label before computing means and percentiles. This is useful to reduce the impact of cold gRPC connections and Node JIT warm-up at the beginning of execution. A value between 5 and 10 is usually a good starting point.

## Methodological recommendations
- Run each configuration at least ~30 times (adjust `REPEAT`/`OPS_PER_LEVEL`) before reporting percentiles with confidence
- Change only one variable at a time (N, batch size, concurrency) — do not combine multiple modifications in the same run, otherwise you cannot infer cause and effect
- Report p50, p95, and p99, not just the average — the long tail often matters more in distributed systems
- Keep the environment controlled: use the same machine, avoid competing CPU load during measurement, and document hardware specs in the article


## Summary of the benchmark goals

The benchmark suite is designed to answer four main questions:

1. How much time does each stage of the workflow take?
2. Which stage dominates the end-to-end processing delay?
3. How does the system behave under different workloads and concurrency levels?
4. Does the solution scale acceptably for the expected operational load?

Depending on the section of the article, the CSV outputs can be used to report:
- average and percentile latency
- throughput under increasing load
- bottlenecks in ingestion vs. re-identification
- scalability trends as concurrency or data volume increases
