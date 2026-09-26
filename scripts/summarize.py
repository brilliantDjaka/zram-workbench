#!/usr/bin/env python3
"""summarize.py - mean-across-repeats markdown table from results.csv.

Usage: python3 scripts/summarize.py [results/results.csv]
Sorts by p99 fault latency, then PSI-full (your 'no lag' goal first).
"""
import csv
import sys
from collections import defaultdict


def main(path):
    rows = defaultdict(list)
    try:
        with open(path) as f:
            for r in csv.DictReader(f):
                rows[r["algo"]].append(r)
    except FileNotFoundError:
        print("(no results yet)")
        return

    def mean(rs, k):
        vs = [float(x[k]) for x in rs if x[k] not in ("", "NA")]
        return sum(vs) / len(vs) if vs else float("nan")

    print("| algo | ratio | bogo/s | p50us | p99us | PSI-full | usr% | sys% | n |")
    print("|---|---|---|---|---|---|---|---|---|")
    for algo, rs in sorted(
        rows.items(),
        key=lambda kv: (mean(kv[1], "fault_p99_us"), mean(kv[1], "psi_full_avg10")),
    ):
        print(
            f"| {algo} | {mean(rs, 'ratio'):.2f} | {mean(rs, 'bogo_ops_per_s'):.0f} "
            f"| {mean(rs, 'fault_p50_us'):.0f} | {mean(rs, 'fault_p99_us'):.0f} "
            f"| {mean(rs, 'psi_full_avg10'):.2f} | {mean(rs, 'cpu_usr_pct'):.1f} "
            f"| {mean(rs, 'cpu_sys_pct'):.1f} | {len(rs)} |"
        )
    print("\nVerdict: lowest p99 + PSI-full wins (your 'no lag' goal).")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "results/results.csv")
