#!/usr/bin/env python3
"""
analyze.py — aggregate benchmark CSV into per-label statistics.

Usage:
    python3 analyze.py <csv_file> [--warmup N]

CSV format (produced by time_cmd):
    label,duration_ms,success,timestamp
"""
import argparse
import csv
import sys
from collections import defaultdict


def percentile(sorted_vals, p):
    if not sorted_vals:
        return 0
    n = len(sorted_vals)
    idx = int(n * p / 100)
    idx = max(0, min(idx, n - 1))
    return sorted_vals[idx]


def fmt_num(x):
    return f"{x:.1f}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv", help="CSV file to analyze")
    ap.add_argument("--warmup", type=int, default=0,
                    help="number of initial samples per label to discard")
    args = ap.parse_args()

    buckets = defaultdict(list)
    fails = defaultdict(int)

    with open(args.csv, newline="") as f:
        reader = csv.DictReader(f)
        # tolerate BOM and trailing whitespace in header
        reader.fieldnames = [h.strip().lstrip("\ufeff") for h in reader.fieldnames]

        for row in reader:
            label = row["label"].strip()
            try:
                ms = float(row["duration_ms"])
            except (KeyError, ValueError):
                continue
            ok = row.get("success", "1").strip()
            if ok != "1":
                fails[label] += 1
                continue
            buckets[label].append(ms)

    print(f"File: {args.csv}  (warmup={args.warmup})")
    print(f"{'label':<40} {'n':>6} {'fail':>5} "
          f"{'mean':>9} {'p50':>9} {'p95':>9} {'p99':>9} "
          f"{'min':>9} {'max':>9}   (ms)")
    print("-" * 120)

    for label in sorted(buckets.keys()):
        vals = buckets[label]
        if args.warmup > 0 and len(vals) > args.warmup:
            vals = vals[args.warmup:]
        vals = sorted(vals)
        if not vals:
            continue

        n = len(vals)
        mean = sum(vals) / n
        p50 = percentile(vals, 50)
        p95 = percentile(vals, 95)
        p99 = percentile(vals, 99)
        mn = vals[0]
        mx = vals[-1]

        print(f"{label:<40} {n:>6} {fails[label]:>5} "
              f"{fmt_num(mean):>9} {fmt_num(p50):>9} {fmt_num(p95):>9} {fmt_num(p99):>9} "
              f"{fmt_num(mn):>9} {fmt_num(mx):>9}")


if __name__ == "__main__":
    main()