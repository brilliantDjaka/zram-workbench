#!/usr/bin/env bash
# apply-zram.sh - PRIVILEGED zram switcher. Quiesce-checked, restores prev on failure.
# Usage:
#   devbox run apply <spec> [--disksize 22.5G] [--dry-run] [--force]
# Specs: lzo-rle | lzo | lz4 | lz4hc | deflate | 842 | zstd:1 | zstd:3 | zstd:8 | zstd:15 | zstd:19
#   also accepts "zstd(level=8)" style (normalized).
set -euo pipefail

DEV="${ZRAM_DEV:-/dev/zram0}"
ZNAME="$(basename "$DEV")"
SYS="${ZRAM_SYS:-/sys/block/${ZNAME}}"
DISKSIZE=""
DRYRUN=0
FORCE=0
SPEC=""

usage() {
  sed -n '2,8p' "$0"
  echo "Options: [--disksize SIZE] [--dry-run] [--force] [--help]"
  echo "Example: devbox run apply zstd:1"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --disksize) DISKSIZE="${2:-}"; shift 2 ;;
    --dry-run) DRYRUN=1; shift ;;
    --force) FORCE=1; shift ;;
    --help|-h) usage; exit 0 ;;
    --*) echo "unknown flag: $1" >&2; usage; exit 2 ;;
    *) if [[ -z "$SPEC" ]]; then SPEC="$1"; else echo "unexpected arg: $1" >&2; exit 2; fi; shift ;;
  esac
done

[[ -z "$SPEC" ]] && { echo "missing <spec>" >&2; usage; exit 2; }

# Normalize spec: "zstd(level=8)" -> "zstd:8"; strip spaces.
NORM="$(echo "$SPEC" | tr -d ' ' | sed -E 's/\(level=/:/; s/\(algo=//; s/[)]//g')"
ALGO="${NORM%%:*}"
LEVEL=""
if [[ "$NORM" == *:* ]]; then LEVEL="${NORM##*:}"; fi

case "$ALGO" in
  lzo-rle|lzo|lz4|lz4hc|zstd|deflate|842) ;;
  *) echo "unsupported algo: $ALGO (kernel: $(cat "$SYS/comp_algorithm" 2>/dev/null || echo '?'))" >&2; exit 2 ;;
esac
if [[ -n "$LEVEL" ]]; then
  [[ "$LEVEL" =~ ^-?[0-9]+$ ]] || { echo "bad level: $LEVEL" >&2; exit 2; }
  if [[ "$ALGO" != "zstd" && "$ALGO" != "lz4hc" ]]; then
    echo "note: level is only meaningful for zstd/lz4hc; ignoring for $ALGO" >&2
    LEVEL=""
  fi
fi
# zstd kernel range 1..22 (0=default=3). Clamp-check, don't hard-fail (kernels vary).
if [[ "$ALGO" == "zstd" && -n "$LEVEL" ]]; then
  if [[ "$LEVEL" -lt 1 || "$LEVEL" -gt 22 ]]; then
    echo "warning: zstd level $LEVEL outside usual 1..22; kernel may reject (EINVAL)" >&2
  fi
fi

[[ -d "$SYS" ]] || { echo "no such device sysfs: $SYS" >&2; exit 1; }

PREV_ALGO="$(sed -E 's/.*\[([^]]+)\].*/\1/' "$SYS/comp_algorithm" 2>/dev/null || echo unknown)"
PREV_DISKSIZE="$(cat "$SYS/disksize" 2>/dev/null || echo 0)"
if [[ -z "$DISKSIZE" ]]; then
  if [[ "$PREV_DISKSIZE" != "0" ]]; then DISKSIZE="$PREV_DISKSIZE"; else DISKSIZE="22.5G"; fi
fi

SUDO=""
[[ "${EUID:-$(id -u)}" -ne 0 ]] && SUDO="sudo"
sysw() { # sysw <file> <value>: sudo-safe sysfs write
  local f="$1" v="$2"
  if [[ -z "$SUDO" ]]; then echo "$v" > "$f";
  else echo "$v" | $SUDO tee "$f" >/dev/null; fi
}

# ---- safety checks (no state change yet) ----
if pgrep -f "stress-ng.*--vm" >/dev/null 2>&1; then
  echo "refusing: stress-ng --vm hog appears to be running (kill it first, or --force)" >&2
  [[ "$FORCE" -eq 1 ]] || exit 1
fi
MEMAVAIL_KB="$(awk '/MemAvailable/ {print $2}' /proc/meminfo)"
SWAPTOT_KB="$(awk '/SwapTotal/ {print $2}' /proc/meminfo)"
SWAPFREE_KB="$(awk '/SwapFree/ {print $2}' /proc/meminfo)"
SWAPUSED_KB=$((SWAPTOT_KB - SWAPFREE_KB))
echo "prev=$PREV_ALGO disksize=$PREV_DISKSIZE target=$ALGO${LEVEL:+ level=$LEVEL} new_disksize=$DISKSIZE"
echo "mem: MemAvailable=${MEMAVAIL_KB}kB SwapUsed=${SWAPUSED_KB}kB"
if [[ "$SWAPUSED_KB" -gt "$MEMAVAIL_KB" && "$FORCE" -ne 1 ]]; then
  echo "refusing: SwapUsed > MemAvailable; swapoff would OOM. Close hog/browser first, or --force." >&2
  exit 1
fi

restore_prev() {
  echo "restoring prev algo $PREV_ALGO ..." >&2
  $SUDO swapoff "$DEV" 2>/dev/null || true
  sysw "$SYS/reset" 1 || true
  sysw "$SYS/comp_algorithm" "$PREV_ALGO" || true
  sysw "$SYS/disksize" "$PREV_DISKSIZE" || true
  $SUDO mkswap "$DEV" >/dev/null 2>&1 || true
  $SUDO swapon -p 100 "$DEV" 2>/dev/null || true
}
trap 'echo "interrupted; restoring..."; restore_prev; exit 130' INT TERM

if [[ "$DRYRUN" -eq 1 ]]; then
  echo "[dry-run] would run: swapoff $DEV; reset; ${LEVEL:+algorithm_params algo=$ALGO level=$LEVEL;} comp_algorithm=$ALGO; disksize=$DISKSIZE; mkswap; swapon -p 100 $DEV"
  exit 0
fi

set -x
$SUDO swapoff "$DEV" 2>/dev/null || true
sysw "$SYS/reset" 1
if [[ -n "$LEVEL" ]]; then
  sysw "$SYS/algorithm_params" "algo=${ALGO} level=${LEVEL}"
fi
sysw "$SYS/comp_algorithm" "$ALGO"
sysw "$SYS/disksize" "$DISKSIZE"
$SUDO mkswap "$DEV" >/dev/null
$SUDO swapon -p 100 "$DEV"
set +x

echo "active: $(cat "$SYS/comp_algorithm")"
zramctl "$DEV" || true
