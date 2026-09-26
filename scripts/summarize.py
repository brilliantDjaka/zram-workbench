#!/usr/bin/env python3
"""summarize.py - mean-across-repeats markdown table from results.csv.

Usage: python3 scripts/summarize.py [results/results.csv]
Sorts by swap p99, then firefox cold-start, then PSI-full-total (your 'no lag' goal first).
Handles both old CSVs (fault-only) and new CSVs (swap+firefox+pswp).
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
        vs = []
        for x in rs:
            v = x.get(k, "")
            if v in ("", "NA", None):
                continue
            try:
                vs.append(float(v))
            except ValueError:
                continue
        return sum(vs) / len(vs) if vs else float("nan")

    has_swap = any("swap_p99_us" in r for rs in rows.values() for r in rs)
    has_ff = any("firefox_s" in r for rs in rows.values() for r in rs)
    if has_swap:
        print("| algo | ratio | bogo/s | swap p99us | swap maxus | firefox s | python s | pswpin | pswpout | PSI-full-total | usr% | sys% | n |")
        print("|---|---|---|---|---|---|---|---|---|---|---|---|---|---|")
        sort_key = lambda kv: (mean(kv[1], "swap_p99_us"), mean(kv[1], "firefox_s"), mean(kv[1], "psi_full_total_delta"))
        for algo, rs in sorted(rows.items(), key=sort_key):
            print(
                f"| {algo} | {mean(rs, 'ratio'):.2f} | {mean(rs, 'bogo_ops_per_s'):.0f} "
                f"| {mean(rs, 'swap_p99_us'):.0f} | {mean(rs, 'swap_max_us'):.0f} "
                f"| {mean(rs, 'firefox_s'):.2f} | {mean(rs, 'python_s'):.3f} "
                f"| {mean(rs, 'pswpin_delta'):.0f} | {mean(rs, 'pswpout_delta'):.0f} "
                f"| {mean(rs, 'psi_full_total_delta'):.0f} | {mean(rs, 'cpu_usr_pct'):.1f} "
                f"| {mean(rs, 'cpu_sys_pct'):.1f} | {len(rs)} |"
            )
        print("\nVerdict: lowest swap-p99 + firefox-s + PSI-full-total wins (your 'no lag' goal).")
        if has_ff is False:
            pass
    else:
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
