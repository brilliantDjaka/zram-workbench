# Journal

Diary of completed work on this repo. Newest first: the most recent event
section sits at the top; older events follow below.

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
