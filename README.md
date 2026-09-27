# zram-workbench

Devbox-based benchmark harness for comparing zram compression algorithms under memory pressure.

Three scripts split the job:

| Script | Role | Privileged? |
|---|---|---|
| `scripts/bench-all.sh` | sequencer: apply → bench → cooldown per algo, then restore + summarize | no |
| `scripts/apply-zram.sh` | mutates `/sys/block/zram0` (reset, algorithm, disksize, mkswap/swapon) | yes (`sudo`) |
| `scripts/bench.sh` | load generation + measurement only (`stress-ng` hog + probes → `results/results.csv`) | no |

Plus: `scripts/status.sh` (read-only overview) and `scripts/summarize.py` (mean-per-algo table).

## Prereqs

- Linux with zram (`/sys/block/zram0`, `/dev/zram0`)
- [devbox](https://www.jetify.com/devbox) — provides `stress-ng`, `python3`, etc. (`devbox.json`)
- `sudo` access (only `apply-zram.sh` needs it)
- Run from the repo root (paths are relative: `scripts/...`, `results/...`)

## Quick start

```bash
devbox run status                          # read-only, check current zram state
devbox run bench-all -- --dry-run          # print the plan, touch nothing
devbox run bench-all -- --quick            # fastest real signal (4G hog, 1 repeat)
devbox run bench-all                       # full 11-algo matrix at safe defaults
```

Full matrix: `lzo-rle lzo lz4 lz4hc zstd:1 zstd:3 zstd:8 zstd:15 zstd:19 deflate 842`.

Useful flags (`bench-all` forwards size/probe flags to `bench.sh`):

```bash
devbox run bench-all -- --from zstd:8 --no-restore   # resume from a spec, leave last algo active
devbox run bench-all -- --quick --cooldown 5         # shorter cooldown between algos
devbox run summarize results/results.csv             # re-print summary table
```

Defaults are OOM-safe for a ~15 GiB box (10G hog / 35s timeout / 8s settle). On a 14.9 GiB machine, 16G hogs get killed by `systemd-oomd`. See `JOURNAL.md` for history.

## Results

`results/` is gitignored (machine-specific). Each run appends rows to `results/results.csv` plus per-repeat hog/probe/firefox artifacts. See `flowchart.md` for the full pipeline diagram.
