#!/usr/bin/env bash
# bench.sh - MEASURE-ONLY zram benchmark. Never switches algorithm.
#   devbox run bench [--bytes 10G --timeout 30 --settle 8 --repeats 2 --tag zstd:1]
# Metric groups: (1) ratio (2) speed (3) lag (4) cpu cost (5) stability.
set -uo pipefail

SYS="${ZRAM_SYS:-/sys/block/zram0}"
BYTES="10G"; TIMEOUT=35; SETTLE=8; REPEATS=2; COOLDOWN=5
OUT="results/results.csv"; TAG=""; PROBE_ITERS=200; PROBE_MEM_MB=1536
FIREFOX_TIMEOUT=60; NO_FIREFOX=0
QUICK=0; EXTREME=0

parse_probe_mem() { # accepts 512 / 512M / 2G -> MB
  local v="$1"
  case "$v" in
    *[Gg]) echo $(( ${v%[Gg]*} * 1024 )) ;;
    *[Mm]) echo "${v%[Mm]*}" ;;
    *) echo "$v" ;;
  esac
}

usage() {
  echo "Usage: devbox run bench [--bytes 10G --timeout 35 --settle 8 --repeats 2 --tag SPEC --out FILE --probe-iters 200 --probe-mem 1536M --firefox-timeout 60 --no-firefox --cooldown 5 --quick --extreme]"
  echo "  --quick:   4G/20s/settle 5/repeats 1/probe-mem 512M (smoke test)"
  echo "  --extreme: 20G/60s/settle 15/probe-mem 3072M (replicates manual test)"
  echo "  --probe-mem: swap-touch buffer (MB, e.g. 1536 / 1536M / 2G). Default 1536M."
  echo "  --no-firefox: skip firefox cold-start probe"
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
    --probe-mem) PROBE_MEM_MB="$(parse_probe_mem "${2:-}")"; shift 2 ;;
    --firefox-timeout) FIREFOX_TIMEOUT="${2:-}"; shift 2 ;;
    --no-firefox) NO_FIREFOX=1; shift ;;
    --quick) QUICK=1; shift ;;
    --extreme) EXTREME=1; shift ;;
    --help|-h) usage; exit 0 ;;
    --*) echo "unknown flag: $1" >&2; usage; exit 2 ;;
    *) echo "unexpected arg: $1" >&2; usage; exit 2 ;;
  esac
done
[[ "$QUICK" -eq 1 ]] && { BYTES="4G"; TIMEOUT=20; SETTLE=5; REPEATS=1; PROBE_ITERS=100; PROBE_MEM_MB=512; }
[[ "$EXTREME" -eq 1 ]] && { BYTES="20G"; TIMEOUT=60; SETTLE=15; PROBE_MEM_MB=3072; }

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
read_psi_total() { # prints "some_total full_total" (cumulative us)
  awk '/^some/ {for(i=1;i<=NF;i++) if($i~/^total=/){split($i,a,"="); s=a[2]}} /^full/ {for(i=1;i<=NF;i++) if($i~/^total=/){split($i,a,"="); f=a[2]}} END {print s+0, f+0}' /proc/pressure/memory 2>/dev/null || echo "0 0"
}
read_vmstat() { # prints "pswpin pswpout pgmajfault"
  awk '/^pswpin/{a=$2} /^pswpout/{b=$2} /^pgmajfault/{c=$2} END {print a+0, b+0, c+0}' /proc/vmstat 2>/dev/null || echo "0 0 0"
}
cpu_snapshot() { awk '/^cpu / {print $2, $3, $4, $5, $6, $7, $8, $9}' /proc/stat; }

if [[ ! -f "$OUT" ]]; then
  echo "timestamp,algo,repeat,hog_bytes,timeout_s,orig_bytes,compr_bytes,ratio,mem_used_total,same_pages,huge_pages,bogo_ops_per_s,fault_p50_us,fault_p99_us,fault_max_us,swap_p50_us,swap_p99_us,swap_max_us,firefox_s,python_s,pswpin_delta,pswpout_delta,pgmajfault_delta,psi_some_avg10,psi_full_avg10,psi_some_total_delta,psi_full_total_delta,cpu_usr_pct,cpu_sys_pct,failed_reads,failed_writes,notes" > "$OUT"
fi

ALGO_LABEL="${TAG:-$(current_algo)}"
echo "algo=$ALGO_LABEL hog=$BYTES timeout=${TIMEOUT}s settle=${SETTLE}s repeats=$REPEATS iters=$PROBE_ITERS probe_mem=${PROBE_MEM_MB}M firefox_timeout=${FIREFOX_TIMEOUT}s -> $OUT"
if [[ "$NO_FIREFOX" -eq 0 ]]; then
  command -v firefox >/dev/null || { echo "warning: firefox not found, app probe will report NA (use --no-firefox to silence)" >&2; }
fi

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

run_swap_probe() { # run_swap_probe <mem_mb> <iters> <outfile>: forces real swapout+decompress, prints "p50 p99 max" (us)
  # Dirty buffer, then sleep to let kswapd age it out under hog pressure, then random re-touch.
  # Without the sleep the pages stay hot/resident (0.4us) and never exercise zram decompress.
  local mem_mb="$1" iters="$2" out="$3"
  python3 - "$mem_mb" "$iters" "$out" <<'EOF'
import random, sys, time
mem_mb = int(sys.argv[1]); iters = int(sys.argv[2]); out = sys.argv[3]
n = mem_mb * 1024 * 1024
buf = bytearray(n)
for i in range(0, n, 4096):  # dirty every page -> real allocation, swappable under hog
    buf[i] = (i >> 12) & 0xFF
time.sleep(3)  # let hog pressure + kswapd reclaim these pages to zram
rnd = random.Random(1234)
lat = []
for _ in range(iters):
    off = rnd.randrange(0, n // 4096) * 4096
    t0 = time.perf_counter()
    s = buf[off]  # may major-fault through zram decompress
    t1 = time.perf_counter()
    lat.append((t1 - t0) * 1e6)
lat.sort()
def pct(p): return lat[min(len(lat) - 1, int(p * len(lat)))]
with open(out, "w") as f:
    f.write("\n".join(f"{x:.1f}" for x in lat) + "\n")
print(f"{pct(0.50):.1f} {pct(0.99):.1f} {lat[-1]:.1f}")
EOF
}

run_firefox_probe() { # run_firefox_probe <timeout_s> <repeat_tag>: cold start headless screenshot, prints seconds or NA
  local timeout_s="$1" rtag="$2"
  if [[ "$NO_FIREFOX" -eq 1 ]]; then echo "NA"; return 0; fi
  command -v firefox >/dev/null || { echo "NA"; return 0; }
  command -v timeout >/dev/null || timeout_s=0
  local prof shot
  prof="$(mktemp -d /tmp/ff-bench-XXXXXX 2>/dev/null || echo /tmp/ff-bench-fallback)"
  mkdir -p "$prof"
  shot="results/firefox-${ALGO_LABEL//\//_}-${rtag}.png"
  local t0 t1 dt rc
  t0="$(date +%s.%N)"
  if [[ "$timeout_s" -gt 0 ]]; then
    timeout "$timeout_s" firefox --headless --no-remote --profile "$prof" --screenshot="$shot" about:blank >/dev/null 2>&1
    rc=$?
  else
    firefox --headless --no-remote --profile "$prof" --screenshot="$shot" about:blank >/dev/null 2>&1
    rc=$?
  fi
  t1="$(date +%s.%N)"
  rm -rf "$prof"
  if [[ "$rc" -ne 0 ]]; then echo "NA"; return 0; fi
  dt="$(python3 -c "print(f'{(float($t1)-float($t0)):.2f}')")"
  echo "$dt"
}

run_python_probe() { # cold-ish interpreter startup under pressure, prints seconds
  local t0 t1
  t0="$(date +%s.%N)"
  python3 -c "import os, sys, json, re, collections" 2>/dev/null
  t1="$(date +%s.%N)"
  python3 -c "print(f'{(float($t1)-float($t0)):.3f}')"
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
  # shellcheck disable=SC2207
  VM_PRE=($(read_vmstat))
  # shellcheck disable=SC2207
  PSIT_PRE=($(read_psi_total))
  PLAT="results/probe-${ALGO_LABEL//\//_}-r${r}.txt"
  # shellcheck disable=SC2207
  PROBE=($(run_probe "$PROBE_ITERS" "$PLAT"))
  SLAT="results/swap-${ALGO_LABEL//\//_}-r${r}.txt"
  # shellcheck disable=SC2207
  SWAP_PROBE=($(run_swap_probe "$PROBE_MEM_MB" "$PROBE_ITERS" "$SLAT"))
  FF_TIME="$(run_firefox_probe "$FIREFOX_TIMEOUT" "r${r}")"
  PY_TIME="$(run_python_probe)"
  CPU_POST=($(cpu_snapshot))
  # shellcheck disable=SC2207
  VM_POST=($(read_vmstat))
  # shellcheck disable=SC2207
  PSIT_POST=($(read_psi_total))
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
  PSWPIN_D=$(( VM_POST[0] - VM_PRE[0] )); PSWPOUT_D=$(( VM_POST[1] - VM_PRE[1] )); PGMAJ_D=$(( VM_POST[2] - VM_PRE[2] ))
  PSIT_SOME_D=$(( PSIT_POST[0] - PSIT_PRE[0] )); PSIT_FULL_D=$(( PSIT_POST[1] - PSIT_PRE[1] ))
  echo "${TS},${ALGO_LABEL},${r},${BYTES},${TIMEOUT},${ORIG},${COMPR},${RATIO},${MEMUSED},${SAME},${HUGE},${BOGO},${PROBE[0]},${PROBE[1]},${PROBE[2]},${SWAP_PROBE[0]},${SWAP_PROBE[1]},${SWAP_PROBE[2]},${FF_TIME},${PY_TIME},${PSWPIN_D},${PSWPOUT_D},${PGMAJ_D},${PSI_POST[0]},${PSI_POST[1]},${PSIT_SOME_D},${PSIT_FULL_D},${CPU_USR},${CPU_SYS},${IO[0]},${IO[1]},${HLOG}" >> "$OUT"
  echo "ratio=$RATIO bogo=${BOGO}/s fault_p99=${PROBE[1]}us swap_p99=${SWAP_PROBE[1]}us swap_max=${SWAP_PROBE[2]}us ff=${FF_TIME}s py=${PY_TIME}s pswpin/out=${PSWPIN_D}/${PSWPOUT_D} majflt=${PGMAJ_D} psi_full_total=${PSIT_FULL_D} usr=${CPU_USR}% sys=${CPU_SYS}%"
  sync 2>/dev/null || true
  [[ "$r" -lt "$REPEATS" ]] && sleep "$COOLDOWN"
done

echo "wrote $OUT"
