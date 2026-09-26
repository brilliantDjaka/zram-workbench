#!/usr/bin/env bash
# bench-all.sh - safe sequencer: apply -> bench -> cooldown per algo, restore start algo at end.
#   devbox run bench-all [--quick] [--extreme] [--repeats N] [--cooldown S] [--bytes SIZE] [--timeout S] [--settle S] [--probe-iters N] [--probe-mem SIZE] [--firefox-timeout S] [--no-firefox] [--dry-run] [--from SPEC] [--no-restore]
set -uo pipefail

MATRIX=(lzo-rle lzo lz4 lz4hc zstd:1 zstd:3 zstd:8 zstd:15 zstd:19 deflate 842)
REPEATS=""; COOLDOWN=10; DRYRUN=0; FROM=""; RESTORE=1
BENCH_EXTRA=()

usage() {
  echo "Usage: devbox run bench-all [--quick] [--extreme] [--repeats N] [--cooldown S] [--bytes SIZE] [--timeout S] [--settle S] [--probe-iters N] [--probe-mem SIZE] [--firefox-timeout S] [--no-firefox] [--dry-run] [--from SPEC] [--no-restore]"
  echo "Matrix: ${MATRIX[*]}"
  echo "  --bytes/--timeout/--settle/--probe-iters/--probe-mem/--firefox-timeout/--no-firefox are forwarded to bench.sh (e.g. --bytes 10G for 14GiB RAM boxes)"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --quick) BENCH_EXTRA+=(--quick); shift ;;
    --extreme) BENCH_EXTRA+=(--extreme); shift ;;
    --repeats) REPEATS="$2"; BENCH_EXTRA+=(--repeats "$2"); shift 2 ;;
    --cooldown) COOLDOWN="$2"; shift 2 ;;
    --bytes) BENCH_EXTRA+=(--bytes "$2"); shift 2 ;;
    --timeout) BENCH_EXTRA+=(--timeout "$2"); shift 2 ;;
    --settle) BENCH_EXTRA+=(--settle "$2"); shift 2 ;;
    --probe-iters) BENCH_EXTRA+=(--probe-iters "$2"); shift 2 ;;
    --probe-mem) BENCH_EXTRA+=(--probe-mem "$2"); shift 2 ;;
    --firefox-timeout) BENCH_EXTRA+=(--firefox-timeout "$2"); shift 2 ;;
    --no-firefox) BENCH_EXTRA+=(--no-firefox); shift ;;
    --dry-run) DRYRUN=1; shift ;;
    --from) FROM="$2"; shift 2 ;;
    --no-restore) RESTORE=0; shift ;;
    --help|-h) usage; exit 0 ;;
    --*) echo "unknown flag: $1" >&2; usage; exit 2 ;;
    *) echo "unexpected arg: $1" >&2; usage; exit 2 ;;
  esac
done

SYS="${ZRAM_SYS:-/sys/block/zram0}"
START_ALGO="$(sed -E 's/.*\[([^]]+)\].*/\1/' "$SYS/comp_algorithm" 2>/dev/null || echo lz4)"
echo "start_algo=$START_ALGO matrix=${#MATRIX[@]} cooldown=${COOLDOWN}s restore=$RESTORE extra=[${BENCH_EXTRA[*]}]"

cleanup_restore() {
  [[ "$RESTORE" -eq 1 && "$DRYRUN" -eq 0 ]] || return 0
  echo "restoring $START_ALGO ..."
  bash scripts/apply-zram.sh "$START_ALGO" || true
}
trap 'echo "interrupted; restoring..."; cleanup_restore; exit 130' INT TERM

# optional resume point
SPECS=("${MATRIX[@]}")
if [[ -n "$FROM" ]]; then
  FOUND=0; REST=()
  for s in "${SPECS[@]}"; do
    [[ "$s" == "$FROM" ]] && FOUND=1
    [[ "$FOUND" -eq 1 ]] && REST+=("$s")
  done
  [[ "$FOUND" -eq 1 ]] || { echo "unknown --from $FROM" >&2; exit 2; }
  SPECS=("${REST[@]}")
fi

if [[ "$DRYRUN" -eq 1 ]]; then
  for s in "${SPECS[@]}"; do echo "[dry-run] apply $s -> bench --tag $s ${BENCH_EXTRA[*]} -> sleep $COOLDOWN"; done
  exit 0
fi

# fail fast on error but always restore
set -e
for s in "${SPECS[@]}"; do
  echo "===== $s ====="
  bash scripts/apply-zram.sh "$s"
  sleep 3
  bash scripts/bench.sh --tag "$s" "${BENCH_EXTRA[@]}"
  sync 2>/dev/null || true
  sleep "$COOLDOWN"
done

cleanup_restore
trap - INT TERM

echo
echo "===== summary (mean across repeats, this file) ====="
python3 scripts/summarize.py results/results.csv
