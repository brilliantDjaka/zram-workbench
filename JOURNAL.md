# Journal

Diary of completed work on this repo. Newest first: the most recent event
section sits at the top; older events follow below.

## 2026-09-26 18:45 - Default hog timeout 30s to 35s for swap age-out + firefox room

- **What:** Changed `bench.sh` built-in default `TIMEOUT` from 30 to 35 (usage text updated). `--quick` (20s) and `--extreme` (60s) unchanged.
- **Why:** New per-repeat probes (swap-touch dirty + 3s age-out sleep + firefox cold-start) need a ~27s window (`timeout - settle`) so the hog stays alive through the probes; at 30s the window was 22s and firefox under thrash could outlive the hog.
- **Changes:** `scripts/bench.sh` line 8: `TIMEOUT=35`.
- **Tests / Verification:** `bash -n`, `bench --help` shows new default, `bench-all --dry-run` with no args forwards empty extras (defaults apply).

## 2026-09-26 18:38 - Rework lag/speed metrics: swap-touch + firefox cold-start + pswp deltas

- **What:** Replaced the microsecond-only lag story with three new probes in `bench.sh`: (1) swap-touch buffer (dirty 1536M, sleep 3s to age out, random re-touch timing per-page faults through zram decompress), (2) app cold-start (`firefox --headless --no-remote` screenshot on a fresh profile + `python3` stdlib import timing), (3) swap/stall counters (`pswpin/pswpout/pgmajfault` deltas from `/proc/vmstat` + PSI `total` deltas, not just instant avg10).
- **Why:** The old 4MB `run_probe` never faulted to zram (~15us flat across all algos, PSI 0/0 in all 22 rows), and `glxgears` was rejected as a metric (RSS ~10MB never swaps, FPS vsync/GPU-bound, needs DISPLAY passthrough). Firefox 156 exists on the box and cold-starts in ~0.75s idle, so it works as a felt-lag proxy.
- **Changes:** `scripts/bench.sh`: new flags `--probe-mem` (default 1536M, quick 512M, extreme 3072M), `--firefox-timeout 60`, `--no-firefox`; new CSV columns `swap_p50/p99/max_us, firefox_s, python_s, pswpin/out/pgmajfault_delta, psi_some/full_total_delta`. `scripts/bench-all.sh` forwards the three new flags. `scripts/summarize.py` prints/sorts by the new columns (backward-compatible with old fault-only CSVs).
- **Tests / Verification:** `bash -n` + `bench --help` + `bench-all --dry-run` forwarding OK; old `results-1822` CSV still summarizes. Live smoke: `--quick` run clean (`ff=1.04s`); 10G single-repeat run clean (`bogo=61595/s, pswpout=343k, psi_full_total=419k` — counters catch pressure the old avg10=0 missed). Note: at safe 10G the swap probe stays resident (~1us); faults/tails appear under heavier pressure — raise `--bytes`/`--probe-mem` for stronger discrimination. Test artifacts removed from `results/`.

## 2026-09-26 17:27 - Default bench hog to safe 10G/30s/8s so plain bench-all won't OOM

- **What:** Changed `bench.sh` built-in defaults from `16G/45s/15s` to `10G/30s/8s` (usage text updated too).
- **Why:** Plain `devbox run bench-all` forwards no size flags, so it ran the old 16G defaults — the exact config `systemd-oomd` killed. The user prefers the short command, so the defaults themselves must be safe on this 14.9G box. Explicit flags and `--extreme` still override for bigger machines.
- **Changes:** `scripts/bench.sh` lines 3, 9, 13: `BYTES="10G"; TIMEOUT=30; SETTLE=8`.
- **Tests / Verification:** `bench.sh --help` shows new defaults; `bench-all.sh --dry-run` with no args forwards empty extras (defaults apply). Live 10G run previously verified clean (`bogo=65808/s, p99=32.5us`).

## 2026-09-26 17:20 - Diagnose systemd-oomd kill, add bench-all size passthrough, reset for 10G matrix

- **What:** Diagnosed why the benchmark run died with a GNOME "device memory is nearly full" warning, patched `bench-all.sh` to forward hog-size flags, archived the unusable 16G rows, and verified a 10G hog runs clean.
- **Why:** `journalctl` showed `systemd-oomd` killed the whole Ghostty scope (terminal + bench script + stress-ng) after memory pressure stayed at Avg10 74.79% > 60% limit for >30s. Root cause: `--vm-bytes 16G` on a 14.9G RAM box plus desktop overhead guarantees sustained over-limit pressure; hog logs showed `bogo ops 0.00` (pure thrash) and `lz4hc-r2.log` was truncated mid-run.
- **Changes:** `scripts/bench-all.sh` now accepts `--bytes/--timeout/--settle/--probe-iters` and forwards them to `bench.sh` (previously only `--quick/--extreme/--repeats` were forwarded, so the matrix was stuck at 16G). Archived the mixed results to `results/results-16G-thrash-20260926.csv` and reset `results/results.csv` to header-only for a clean 10G matrix. Created `JOURNAL.md` and `AGENTS.md` with the journal maintenance rule.
- **Tests / Verification:** `bench-all.sh --bytes 10G --timeout 30 --settle 8 --repeats 2 --dry-run` confirms correct forwarding for all 11 algos. Live `bench.sh --tag lz4hc --bytes 10G --timeout 30 --settle 8 --repeats 1`: `bogo=65808/s, p99=32.5us, max=40.2us, sys=8.2%, psi 0/0` vs the 16G row's `bogo=0.00, max=3644.9us, sys=25.8%`. Full 10G matrix not run here — `apply-zram.sh` needs `sudo` (password prompt), so the user runs `devbox run bench-all -- --bytes 10G --timeout 30 --settle 8 --repeats 2` in their own terminal.
