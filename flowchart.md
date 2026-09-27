# bench-all flow

How `devbox run bench-all` walks the zram compression matrix: **apply → bench → cooldown**, per
algorithm, then restore and summarize.

**How to read this.** Every node is annotated with `file:line` (relative to this repo). Diagrams
match the tree at commit `a469044`. Line references inside a diagram are relative to the script
named in that section's heading.

The harness splits responsibility three ways (see `AGENTS.md`:3):

| Layer | Script | Owns | Privileged? |
|---|---|---|---|
| order | `scripts/bench-all.sh` | which config runs next, restore point, cooldown | no |
| state | `scripts/apply-zram.sh` | mutating `/sys/block/zram0` | **yes** (`sudo tee`) |
| numbers | `scripts/bench.sh` | load generation + measurement only | no |

---

## 1. Who calls whom

```mermaid
flowchart TD
  U["user terminal: devbox run bench-all (flags)"] --> DX["devbox injects packages + aliases (devbox.json:3-19)"]
  DX --> GEN[".devbox/gen/scripts/bench-all.sh runs: bash scripts/bench-all.sh (devbox.json:15)"]
  GEN --> BA["scripts/bench-all.sh - sequencer, owns ORDER"]
  BA -->|"per spec, step 1"| AP["scripts/apply-zram.sh - PRIVILEGED, owns STATE"]
  BA -->|"per spec, step 2"| BE["scripts/bench.sh - measure-only, owns NUMBERS"]
  BA -->|"once, after the loop"| SU["scripts/summarize.py - mean per algo, markdown table"]
  AP -->|"sysw writes via sudo tee (apply-zram.sh:68-74)"| ZSYS["/sys/block/zram0: reset, algorithm_params, comp_algorithm, disksize"]
  AP -->|"swapon -p 100"| DEV["/dev/zram0 (mkswap + swapon)"]
  BE -->|"reads counters only"| KSTATS["mm_stat, io_stat, /proc/pressure/memory, /proc/vmstat, /proc/stat"]
  BE --> ART["results/results.csv + hog/probe/swap/firefox artifacts"]
  SU --> ART
  ST["scripts/status.sh - read-only overview, NOT in this path"]:::side
  classDef side stroke-dasharray: 4 4, color: #777
```

`bench.sh` never writes `comp_algorithm` — the only reason it appears in the privileged path is
that the hog it starts makes `apply-zram.sh`'s guards relevant (§3).

---

## 2. Main sequencer (`scripts/bench-all.sh`)

```mermaid
flowchart TD
  S0["start: set -uo pipefail, no -e yet (:4)"] --> S1["MATRIX = 11 specs (:6)<br/>COOLDOWN=10 DRYRUN=0 FROM empty RESTORE=1 (:7)"]
  S1 --> P{"flag kind? (:16-36)"}
  P -->|"own flags"| OWN["--cooldown / --dry-run / --from / --no-restore<br/>consumed by the sequencer (:21, :29-31)"]
  P -->|"forwarded flags"| FW["--quick --extreme --repeats --bytes --timeout --settle<br/>--probe-iters --probe-mem --firefox-timeout --no-firefox<br/>appended verbatim to BENCH_EXTRA (:18-28)"]
  P -->|"--help"| H0["usage; exit 0 (:32)"]
  P -->|"unknown flag or positional"| H2["stderr + usage; exit 2 (:33-34)"]
  OWN --> R
  FW --> R["read start state (:38-39)<br/>START_ALGO = bracketed value in SYS/comp_algorithm, fallback lz4"]
  R --> TR["register trap INT TERM (:47)"]
  TR --> FR{"--from given? (:51)"}
  FR -->|"yes"| FS{"spec present in matrix? (:53-56)"}
  FS -->|"no"| F2["unknown --from; exit 2 (:57)"]
  FS -->|"yes"| FT["SPECS = FROM .. end of matrix (:58)"]
  FR -->|"no"| FA["SPECS = full MATRIX (:50)"]
  FT --> DR
  FA --> DR{"DRYRUN? (:61)"}
  DR -->|"yes"| DP["print apply s, bench --tag s, sleep N per spec; exit 0 (:62-63)<br/>no sysfs writes, and restore is skipped too (gated at :43)"]
  DR -->|"no"| SETE["set -e (:67)"]

  subgraph LOOP["for s in SPECS (:68-75) - one config at a time, list order only"]
    L1["echo banner for s (:69)"] --> L2["bash scripts/apply-zram.sh s (:70)"]
    L2 --> AO{"apply exit 0?"}
    AO -->|"no"| ABORT
    AO -->|"yes"| L3["sleep 3 to settle after swapon (:71)"]
    L3 --> L4["bash scripts/bench.sh --tag s plus BENCH_EXTRA (:72)"]
    L4 --> BO{"bench exit 0?"}
    BO -->|"no"| ABORT
    BO -->|"yes"| L5["sync, failure tolerated (:73)"]
    L5 --> L6["sleep COOLDOWN, default 10s (:74)"]
  end

  SETE --> L1
  L6 -->|"next spec"| L1
  L6 -->|"matrix done"| CR["cleanup_restore: re-apply START_ALGO<br/>skipped if RESTORE=0 or DRYRUN=1; failure tolerated (:42-46, :77)"]
  CR --> TC["trap cleared (:78)"]
  TC --> SUM["python3 scripts/summarize.py results/results.csv (:80-82)"]
  SUM --> OK["exit 0"]

  INT["Ctrl-C or SIGTERM during the loop"] --> IH["trap handler: echo interrupted, cleanup_restore, exit 130 (:47)"]

  ABORT["set -e aborts the whole run<br/>NO restore: only INT and TERM are trapped (:47)"]:::danger
  ABORT --> X1["child exit code propagates, zram left on the failing config"]

  classDef danger fill:#ffe0e0,stroke:#c33,color:#900
```

### The asymmetry worth memorizing

| Event | Restore of `START_ALGO`? | Exit code |
|---|---|---|
| loop completes | yes (`:77`) | 0 |
| Ctrl-C / SIGTERM | yes, then exit (`:47`) | 130 |
| `apply-zram.sh` or `bench.sh` fails | **no** — no `ERR`/`EXIT` trap | child's code |
| `--dry-run` | never attempted (`:43`) | 0 |
| `--no-restore` | never attempted (`:43`) | 0 |

The comment at `:66` says "fail fast on error but always restore"; only the interrupt path
actually restores. Resume a truncated run with `--from <spec>` (`:50-59`).

Two small traps in the code itself: `--repeats` is captured at `:20` but never used by the
sequencer (the repeat loop lives in `bench.sh:172`), and value flags `shift 2` without a
`${2:-}` guard (`:20-30`), so a missing value trips `set -u` rather than printing usage.

`START_ALGO` is read from sysfs, which reports bare `zstd` and not `zstd:8` — so a run that
started on a zstd *level* restores unlevelled `zstd` (`:39` → `:45`).

---

## 3. Sub-flow: `apply-zram.sh` (the privileged step)

```mermaid
flowchart TD
  A0["set -euo pipefail (:7); parse flags, one positional SPEC (:23-32)"] --> A1{"SPEC present?"}
  A1 -->|"no"| E2["usage; exit 2 (:34)"]
  A1 -->|"yes"| A2["normalize spec (:37): strip spaces, zstd(level=8) becomes zstd:8<br/>split ALGO and LEVEL (:38-40)"]
  A2 --> A3{"ALGO whitelisted: lzo-rle lzo lz4 lz4hc zstd deflate 842?"}
  A3 -->|"no"| E2b["unsupported algo, prints kernel list; exit 2 (:44)"]
  A3 -->|"yes"| A4{"LEVEL set?"}
  A4 -->|"algo not zstd or lz4hc"| A5["note: level ignored; LEVEL cleared (:48-51)"]
  A4 -->|"non-numeric"| E2c["bad level; exit 2 (:47)"]
  A4 -->|"kept"| A7["warn only when outside usual 1..22, kernels vary (:54-58)"]
  A5 --> A8
  A7 --> A8{"SYS directory exists?"}
  A8 -->|"no"| E1["no such device sysfs; exit 1 (:60)"]
  A8 -->|"yes"| A9["snapshot PREV_ALGO + PREV_DISKSIZE (:62-63)"]
  A9 --> A10["DISKSIZE = current value, else 22.5G when disksize is 0 (:64-66)"]
  A10 --> G1{"stress-ng vm hog already running?"}
  G1 -->|"yes, no --force"| R1["refusing: kill it first; exit 1 (:77-80)"]
  G1 -->|"no or --force"| G2{"SwapUsed exceeds MemAvailable?"}
  G2 -->|"yes, no --force"| R2["refusing: swapoff would OOM; exit 1 (:81-90)"]
  G2 -->|"no or --force"| RP["register restore_prev on INT TERM (:92-101)"]
  RP --> AD{"dry-run?"}
  AD -->|"yes"| ADY["print the planned mutation chain; exit 0 (:103-106)"]
  AD -->|"no"| CHAIN

  subgraph CHAIN["mutation chain, echoed under set -x (:108-118)"]
    direction TB
    M1["swapoff DEV, tolerated"] --> M2["reset = 1 via sysw"]
    M2 --> M3{"LEVEL set?"}
    M3 -->|"yes"| M4["algorithm_params: algo=ALGO level=LEVEL (:111-113)"]
    M3 -->|"no"| M5
    M4 --> M5["comp_algorithm = ALGO"] --> M6["disksize = DISKSIZE"] --> M7["mkswap DEV"] --> M8["swapon -p 100 DEV"]
  end

  CHAIN --> V["verify: cat comp_algorithm + zramctl (:120-121)"]
```

`sysw` (`:70-74`) is the privilege boundary: direct `>` redirect when `EUID` is 0, otherwise
`echo | sudo tee`. This is the only script in the harness that writes kernel state, and the only
one that may prompt for a password.

Note `restore_prev` (`:92-101`) unwinds to `PREV_ALGO` **and** `PREV_DISKSIZE`, and it runs on
interrupt only — a mid-chain failure under `set -e` leaves the device in whatever state the last
successful write produced.

The two guards exist for one reason each: a running hog would be swapped-out-from under, and
`swapoff` forces every swapped page back into RAM — with `SwapUsed > MemAvailable` that is the
OOM that killed the 16G run (`JOURNAL.md`:27-32).

---

## 4. Sub-flow: `bench.sh` (measure-only)

```mermaid
flowchart TD
  B0["set -uo pipefail (:5); defaults BYTES=10G TIMEOUT=35 SETTLE=8 REPEATS=2 COOLDOWN=5 (:8-11)"] --> B1["parse flags (:30-49); unknown flag or extra positional: exit 2"]
  B1 --> B2{"preset flag?"}
  B2 -->|"--quick"| Q["4G / 20s / settle 5 / 1 repeat / 100 iters / 512M (:50)"]
  B2 -->|"--extreme"| X["20G / 60s / settle 15 / 3072M (:51)"]
  B2 -->|"none"| N["keep built-in defaults"]
  Q --> PF
  X --> PF
  N --> PF{"preflight: stress-ng, python3, SYS dir (:53-55)"}
  PF -->|"missing"| E1["exit 1 - this is bench-all's de-facto devbox check"]
  PF -->|"ok"| HD["mkdir results; write 32-column CSV header only when OUT is absent (:56, :72-74)"]
  HD --> AL["ALGO_LABEL = --tag if given, else live current_algo (:58, :76)"]
  AL --> FF{"NO_FIREFOX=0 and firefox absent? (:78-80)"}
  FF -->|"yes"| WARN["warning only; the probe will report NA"]
  FF -->|"no"| LOOPB
  WARN --> LOOPB["repeat loop r = 1 to REPEATS (:172) - see section 5"]
  LOOPB --> DONE["echo wrote OUT (:230); exit 0"]
```

### Defaults, and why they are what they are

| Knob | default | `--quick` | `--extreme` | Reason |
|---|---|---|---|---|
| `BYTES` (hog) | 10G | 4G | 20G | 16G on this 14.9 GiB box is what `systemd-oomd` killed; a plain `bench-all` forwards nothing, so the default itself must be safe (`JOURNAL.md`:20-25) |
| `TIMEOUT` | 35s | 20s | 60s | raised from 30s: probes need the `timeout - settle` window, 35-8 = 27s (`JOURNAL.md`:6-11) |
| `SETTLE` | 8s | 5s | 15s | wait for the hog to reach steady pressure before probing |
| `REPEATS` | 2 | 1 | 2 | means per algo in the summary table |
| `PROBE_MEM_MB` | 1536 | 512 | 3072 | swap-touch buffer that must actually get reclaimed |
| `PROBE_ITERS` | 200 | 100 | 200 | latency samples |
| `FIREFOX_TIMEOUT` | 60s | 60s | 60s | hard cap via `timeout`; firefox never aborts a run |
| `COOLDOWN` (inter-repeat) | 5s | 5s | 5s | `bench.sh:8`, distinct from bench-all's 10s inter-algo cooldown |

Stale comment: the header example at `bench.sh:3` still says `--timeout 30`, while the real
default is `TIMEOUT=35` (`:8`) and `usage()` prints 35 (`:23`).

---

## 5. One repeat, in wall-clock order

```mermaid
sequenceDiagram
  autonumber
  participant S as bench.sh repeat loop
  participant H as stress-ng hog (background)
  participant K as kernel: kswapd + zram0
  participant P as probes
  participant C as results.csv

  S->>S: pre-sample mm_stat, io_stat, PSI avg10 (:176)
  S->>H: launch --vm 1 --vm-bytes 10G --vm-keep --timeout 35 --metrics-brief into hog-algo-r.log (:178-180)
  activate H
  H->>K: sustained reclaim pressure for 35s
  S->>S: sleep SETTLE 8s (:181)
  S->>H: kill -0 alive? warn "hog exited during settle" if not (:182)
  S->>S: window snapshots: /proc/stat, vmstat, PSI total (:183-187)
  S->>P: probe 1 fault-latency, 4MB resident buffer, 200 iters (:82-109, :190)
  P->>K: touches resident pages only (does not really reach zram)
  P-->>C: fault_p50/p99/max_us into probe-algo-r.txt
  S->>P: probe 2 swap-touch: dirty 1536M page by page (:111-137, :193)
  P->>K: 1536M of dirty anonymous pages
  P->>P: sleep 3 so kswapd plus hog reclaim them into zram (:122)
  K->>K: pages swapped out, compressed with the active algo
  P->>K: 200 random single-byte re-touches
  K-->>P: major faults, decompress on read
  P-->>C: swap_p50/p99/max_us into swap-algo-r.txt (the discriminating metric)
  S->>P: probe 3 firefox cold-start, timeout 60s, headless screenshot (:139-162, :194)
  P->>K: real app working set under the hog
  P-->>C: firefox_s (NA on any nonzero rc) + firefox-algo-r.png
  S->>P: probe 4 python3 stdlib startup (:164-170, :195)
  P-->>C: python_s
  S->>S: post-snapshots: /proc/stat, vmstat, PSI total, PSI avg10 (:196-202)
  S->>H: wait for hog, tolerated (:203)
  deactivate H
  S->>K: final mm_stat + io_stat (:205)
  S->>S: derive ratio, bogo from metrc line, cpu usr/sys pct, pswp and PSI deltas (:206-223)
  S->>C: append one 32-column row (:224)
  S-->>S: console one-liner ratio / bogo / p99s / ff / pswp / psi / cpu (:225)
  S->>S: sync, then sleep COOLDOWN 5s if more repeats remain (:226-227)
```

Timeline band for the default configuration (probes must fit inside the 27s window):

```text
t=0s        8s                              ~35s        35s+overage
|--sleep 8--|                               |           
|           | fault probe | swap-touch:     |           |
|           | (200 iters) | dirty + sleep 3 |           |
|           |             | + 200 faults    |           |
|           |             | firefox (<=60s cap, ~1s)    |
|           |             | python startup  |           |
|  stress-ng --vm 1 --vm-bytes 10G --timeout 35 --------|  (background, waits gate it)
             ^window opens (:183)                        ^window closes (:196)
```

Why the swap-touch probe sleeps: `bench.sh:112-113` records that without the 3s pause the buffer
stays hot and resident at roughly 0.4 µs, so zram decompression is never exercised — which is
exactly the flaw that made the old fault probe useless (`JOURNAL.md`:15-16, flat ~15 µs across
all algorithms with PSI 0/0).

---

## 6. Artifacts and exit codes

Nothing in `results/` is tracked — `.gitignore:5-6` excludes it as machine-specific output.

| Artifact | Written by | Notes |
|---|---|---|
| `results/results.csv` | `bench.sh:72-74` header, `:224` row | 32 columns, one row per repeat, **appended**; bench-all passes no `--out`, so the whole matrix lands in one file |
| `results/hog-<algo>-r<r>.log` | `bench.sh:178-179` | `stress-ng --metrics-brief` output; the `metrc:` line yields bogo ops/s; path also stored in the `notes` column |
| `results/probe-<algo>-r<r>.txt` | `bench.sh:188` | raw µs samples, fault probe |
| `results/swap-<algo>-r<r>.txt` | `bench.sh:191` | raw µs samples, swap-touch probe |
| `results/firefox-<algo>-r<r>.png` | `bench.sh:147, :151` | screenshot of `about:blank` from a throwaway `mktemp -d` profile |
| archived run dirs, e.g. `results/2026-09-26_1906_run/` | manual | full 11-algo x 2-repeat runs |
| summary table | `bench-all.sh:82` → `summarize.py` | means per algo, sorted by swap p99, then firefox s, then PSI-full-total (`summarize.py:35-50`); falls back to a fault-only table for old CSVs (`summarize.py:53-66`) |

In filenames `<algo>` is the `--tag` value with `/` replaced by `_` (`bench.sh:147, :178, :188`);
the current matrix contains no slashes.

| Script | exit 0 | exit 1 | exit 2 | exit 130 |
|---|---|---|---|---|
| `bench-all.sh` | completed run, `--help`, `--dry-run` | none of its own | usage, unknown flag, unknown `--from` | interrupt, **after** restore |
| `apply-zram.sh` | switch applied, `--help`, `--dry-run` | missing sysfs dir, hog guard, SwapUsed guard | missing spec, bad algo, bad level, unknown flag | interrupt, **after** `restore_prev` |
| `bench.sh` | rows written | preflight: no stress-ng, no python3, no `$SYS` | usage, unknown flag, extra positional | none; probes degrade to `NA` instead of failing (`:141-142, :159`) |

---

## 7. Running it

```bash
devbox run bench-all -- --dry-run                        # print the plan, touch nothing
devbox run bench-all -- --quick                          # one repeat, 4G, fastest real signal
devbox run bench-all                                     # full matrix at OOM-safe 10G/35s/8s
devbox run bench-all -- --from zstd:8 --no-restore       # resume, keep last algo active
```

- Run through `devbox` (packages at `devbox.json:3-10`); `bench.sh` exits 1 without `stress-ng`.
- Paths are relative (`scripts/...`, `results/...`), so the working directory must be the repo root.
- `apply-zram.sh` may prompt for `sudo`, so the full matrix is an **interactive** run
  (`JOURNAL.md`:32). Expect roughly 11 configs x (35s hog + 3s settle + cooldown + per-algo apply
  overhead) x repeats.
- A small box is not the constraint on hog size alone — the swap probe needs enough `--bytes` and
  `--probe-mem` that kswapd actually evicts, otherwise `swap_p99` stays flat near 1 µs
  (`JOURNAL.md`:18).
- Check live state without touching it: `devbox run status`.

**Read next:** `JOURNAL.md` (why each default moved), then the scripts themselves —
`scripts/bench-all.sh` is 83 lines.
