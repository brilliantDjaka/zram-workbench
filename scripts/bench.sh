#!/usr/bin/env bash
# bench.sh - MEASURE-ONLY zram benchmark. Never switches algorithm.
#   devbox run bench [--bytes 10G --timeout 30 --settle 8 --repeats 2 --tag zstd:1]
# Metric groups: (1) ratio (2) speed (3) lag (4) cpu cost (5) stability.
set -uo pipefail

SYS="${ZRAM_SYS:-/sys/block/zram0}"
BYTES="10G"; TIMEOUT=30; SETTLE=8; REPEATS=2; COOLDOWN=5
OUT="results/results.csv"; TAG=""; PROBE_ITERS=200
QUICK=0; EXTREME=0

usage() {
  echo "Usage: devbox run bench [--bytes 10G --timeout 30 --settle 8 --repeats 2 --tag SPEC --out FILE --probe-iters 200 --cooldown 5 --quick --extreme]"
  echo "  --quick:   4G/20s/settle 5/repeats 1 (smoke test)"
  echo "  --extreme: 20G/60s/settle 15 (replicates manual test)"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bytes) BYTES="${2:-}"; shift 2 ;;
    --timeout) TIMEOUT="${2:-}"; shift 2 ;;
    --settle) SETTLE="${2:-}"; shift 2 ;;
    --repeats) REPEATS="${2:-}"; shift 2 ;;
    --out) OUT="${2:-}"; shift 2 ;;
    --tag) TAG="${2:-}"; shift 2 ;;
    --cooldown) COOLDOWN="${2:-}"; shift 2 ;;
    --probe-iters) PROBE_ITERS="${2:-}"; shift 2 ;;
    --quick) QUICK=1; shift ;;
    --extreme) EXTREME=1; shift ;;
    --help|-h) usage; exit 0 ;;
    --*) echo "unknown flag: $1" >&2; usage; exit 2 ;;
    *) echo "unexpected arg: $1" >&2; usage; exit 2 ;;
  esac
done
[[ "$QUICK" -eq 1 ]] && { BYTES="4G"; TIMEOUT=20; SETTLE=5; REPEATS=1; PROBE_ITERS=100; }
[[ "$EXTREME" -eq 1 ]] && { BYTES="20G"; TIMEOUT=60; SETTLE=15; }

command -v stress-ng >/dev/null || { echo "missing stress-ng; run via: devbox run bench" >&2; exit 1; }
command -v python3 >/dev/null || { echo "missing python3" >&2; exit 1; }
[[ -d "$SYS" ]] || { echo "no zram sysfs: $SYS" >&2; exit 1; }
mkdir -p "$(dirname "$OUT")" results

current_algo() { sed -E 's/.*\[([^]]+)\].*/\1/' "$SYS/comp_algorithm" 2>/dev/null || echo unknown; }
read_mm()  { cat "$SYS/mm_stat" 2>/dev/null || echo "0 0 0 0 0 0 0 0 0"; }
read_io()  { cat "$SYS/io_stat" 2>/dev/null || echo "0 0 0 0"; }
read_psi() { # prints "some_avg10 full_avg10"
  awk '/^some/ {s=$3} /^full/ {f=$3} END {print s+0, f+0}' /proc/pressure/memory 2>/dev/null || echo "0 0"
}
cpu_snapshot() { awk '/^cpu / {print $2, $3, $4, $5, $6, $7, $8, $9}' /proc/stat; }

if [[ ! -f "$OUT" ]]; then
  echo "timestamp,algo,repeat,hog_bytes,timeout_s,orig_bytes,compr_bytes,ratio,mem_used_total,same_pages,huge_pages,bogo_ops_per_s,fault_p50_us,fault_p99_us,fault_max_us,psi_some_avg10,psi_full_avg10,cpu_usr_pct,cpu_sys_pct,failed_reads,failed_writes,notes" > "$OUT"
fi

ALGO_LABEL="${TAG:-$(current_algo)}"
echo "algo=$ALGO_LABEL hog=$BYTES timeout=${TIMEOUT}s settle=${SETTLE}s repeats=$REPEATS iters=$PROBE_ITERS -> $OUT"

run_probe() { # run_probe <iters> <outfile>: small competing workload, prints "p50 p99 max" (us)
  local iters="$1" out="$2"
  python3 - "$iters" "$out" <<'EOF'
import random, sys, time
iters = int(sys.argv[1]); out = sys.argv[2]
buf = bytearray(4 * 1024 * 1024)  # 4MB retained -> random reads fault under pressure
for i in range(0, len(buf), 4096):
    buf[i] = i & 0xFF
lat = []
rnd = random.Random(1234)
for _ in range(iters):
    t0 = time.perf_counter()
    b = bytearray(4096)
    for j in range(0, 4096, 64):
        b[j] = (j * 31) & 0xFF
    base = rnd.randrange(0, len(buf) - 4096)
    s = 0
    for _ in range(16):
        s += buf[base + rnd.randrange(0, 4096)]
    t1 = time.perf_counter()
    lat.append((t1 - t0) * 1e6)
lat.sort()
def pct(p): return lat[min(len(lat) - 1, int(p * len(lat)))]
with open(out, "w") as f:
    f.write("\n".join(f"{x:.1f}" for x in lat) + "\n")
print(f"{pct(0.50):.1f} {pct(0.99):.1f} {lat[-1]:.1f}")
EOF
}

for ((r = 1; r <= REPEATS; r++)); do
  echo "--- repeat $r/$REPEATS ---"
  # pre-sample
  # shellcheck disable=SC2207
  MM_PRE=($(read_mm)); IO_PRE=($(read_io)); PSI_PRE=($(read_psi))
  # hog in background
  HLOG="results/hog-${ALGO_LABEL//\//_}-r${r}.log"
  stress-ng --vm 1 --vm-bytes "$BYTES" --vm-keep --timeout "$TIMEOUT" --metrics-brief >"$HLOG" 2>&1 &
  HOG_PID=$!
  sleep "$SETTLE"
  if ! kill -0 "$HOG_PID" 2>/dev/null; then echo "warning: hog exited during settle (timeout too short?)" >&2; fi
  CPU_PRE=($(cpu_snapshot))
  PLAT="results/probe-${ALGO_LABEL//\//_}-r${r}.txt"
  # shellcheck disable=SC2207
  PROBE=($(run_probe "$PROBE_ITERS" "$PLAT"))
  CPU_POST=($(cpu_snapshot))
  # shellcheck disable=SC2207
  PSI_POST=($(read_psi))
  wait "$HOG_PID" 2>/dev/null || true
  # shellcheck disable=SC2207
  MM=($(read_mm)); IO=($(read_io))
  ORIG="${MM[0]}"; COMPR="${MM[1]}"; MEMUSED="${MM[2]}"; SAME="${MM[5]}"; HUGE="${MM[7]}"
  RATIO="$(python3 -c "o=float($ORIG); c=float($COMPR); print(f'{(o/c if c>0 else 1.0):.3f}')")"
  BOGO="$(awk '/metrc:/ && $4=="vm" {v=$(NF-1)} END {print v}' "$HLOG")"
  BOGO="${BOGO:-NA}"
  # cpu % from /proc/stat deltas over probe window
  read -r CPU_USR CPU_SYS <<<"$(python3 - "${CPU_PRE[*]}" "${CPU_POST[*]}" "$(nproc)" <<'EOF'
import sys
pre = list(map(float, sys.argv[1].split())); post = list(map(float, sys.argv[2].split()))
d = [b - a for a, b in zip(pre, post)]
tot = sum(d) or 1.0
usr = (d[0] + d[1]) / tot * 100.0
sys_ = d[2] / tot * 100.0
print(f"{usr:.1f} {sys_:.1f}")
EOF
)"
  TS="$(date -u +%FT%TZ)"
  echo "${TS},${ALGO_LABEL},${r},${BYTES},${TIMEOUT},${ORIG},${COMPR},${RATIO},${MEMUSED},${SAME},${HUGE},${BOGO},${PROBE[0]},${PROBE[1]},${PROBE[2]},${PSI_POST[0]},${PSI_POST[1]},${CPU_USR},${CPU_SYS},${IO[0]},${IO[1]},${HLOG}" >> "$OUT"
  echo "ratio=$RATIO bogo=${BOGO}/s p50=${PROBE[0]}us p99=${PROBE[1]}us max=${PROBE[2]}us psi_some=${PSI_POST[0]} psi_full=${PSI_POST[1]} usr=${CPU_USR}% sys=${CPU_SYS}%"
  sync 2>/dev/null || true
  [[ "$r" -lt "$REPEATS" ]] && sleep "$COOLDOWN"
done

echo "wrote $OUT"
