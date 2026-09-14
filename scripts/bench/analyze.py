#!/usr/bin/env python3
# ============================================================================
# analyze.py — Aggregate a benchmark CSV produced by lib.sh's time_cmd.
#
# PURPOSE
#   Compute per-label statistics: n, successes, failures, min, p50, p95, p99,
#   max, mean, stdev. Optionally subtract a baseline (CLI overhead floor).
#
# CSV FORMAT
#   label,duration_ms,success,timestamp
#
# USAGE
#   python3 analyze.py <csv> [--warmup N] [--baseline MS] [--label L] [--json]
#
# METRICS SERVED
#   All of them — this is the common post-processing step.
#
# CLI OVERHEAD MITIGATION
#   --baseline MS subtracts a constant from every successful sample before
#   computing stats. Fill MS from scenario-f-cli-overhead.sh output.
#   --warmup N discards the first N samples per label to amortize cold-start.
# ============================================================================
import argparse
import csv
import json
import statistics
import sys
from collections import defaultdict
from pathlib import Path


def percentile(sorted_values, p):
    if not sorted_values:
        return None
    n = len(sorted_values)
    k = max(1, min(n, int(round(n * p / 100))))
    return sorted_values[k - 1]


def load(csv_path):
    by_label = defaultdict(list)
    with open(csv_path, newline="") as f:
        reader = csv.DictReader(f)
        for row in reader:
            label = row["label"]
            try:
                dur = int(row["duration_ms"])
                success = int(row["success"])
            except (ValueError, KeyError):
                continue
            by_label[label].append({
                "duration_ms": dur,
                "success": success,
                "timestamp": row.get("timestamp", ""),
            })
    return by_label


def summarize(samples, baseline_ms=0):
    successes = [s["duration_ms"] for s in samples if s["success"] == 1]
    failures = len(samples) - len(successes)
    if baseline_ms > 0:
        successes = [max(0, d - baseline_ms) for d in successes]
    if not successes:
        return {
            "n": len(samples), "successes": 0, "failures": failures,
            "min": None, "p50": None, "p95": None, "p99": None,
            "max": None, "mean": None, "stdev": None,
        }
    s = sorted(successes)
    return {
        "n": len(samples),
        "successes": len(s),
        "failures": failures,
        "min": s[0],
        "p50": percentile(s, 50),
        "p95": percentile(s, 95),
        "p99": percentile(s, 99),
        "max": s[-1],
        "mean": round(statistics.fmean(s), 2),
        "stdev": round(statistics.pstdev(s), 2) if len(s) > 1 else 0.0,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv", type=Path)
    ap.add_argument("--warmup", type=int, default=0,
                    help="discard the first N samples of each label")
    ap.add_argument("--baseline", type=int, default=0,
                    help="subtract this many ms from every successful sample")
    ap.add_argument("--label", type=str, default=None)
    ap.add_argument("--json", action="store_true")
    args = ap.parse_args()

    if not args.csv.is_file():
        print(f"file not found: {args.csv}", file=sys.stderr)
        sys.exit(1)

    by_label = load(args.csv)
    report = {}
    for label, samples in sorted(by_label.items()):
        if args.warmup > 0:
            samples = samples[args.warmup:]
        if args.label and label != args.label:
            continue
        report[label] = summarize(samples, args.baseline)

    if args.json:
        print(json.dumps(report, indent=2))
        return

    header = f"{'label':<40} {'n':>4} {'ok':>4} {'fail':>4} " \
             f"{'min':>6} {'p50':>6} {'p95':>6} {'p99':>6} {'max':>6} {'mean':>7} {'sd':>7}"
    print(header)
    print("-" * len(header))
    for label, r in report.items():
        if r["p50"] is None:
            print(f"{label:<40} {r['n']:>4} {r['successes']:>4} {r['failures']:>4} (no successful samples)")
            continue
        print(f"{label:<40} {r['n']:>4} {r['successes']:>4} {r['failures']:>4} "
              f"{r['min']:>6} {r['p50']:>6} {r['p95']:>6} {r['p99']:>6} {r['max']:>6} "
              f"{r['mean']:>7} {r['stdev']:>7}")


if __name__ == "__main__":
    main()