#!/usr/bin/env bash
# status.sh - read-only zram overview (no root, never switches anything).
set -uo pipefail

DEV="${ZRAM_DEV:-/dev/zram0}"
SYS="${ZRAM_SYS:-/sys/block/zram0}"

echo "== zramctl =="
zramctl 2>&1 || echo "(zramctl unavailable)"
echo
echo "== ${SYS}/comp_algorithm =="
cat "${SYS}/comp_algorithm" 2>&1 || echo "(unreadable)"
echo
echo "== ${SYS}/mm_stat =="
echo "# orig_data_size compr_data_size mem_used_total mem_limit mem_used_max same_pages pages_compacted huge_pages huge_since"
cat "${SYS}/mm_stat" 2>&1 || echo "(unreadable)"
echo
echo "== ${SYS}/io_stat =="
echo "# failed_reads failed_writes invalid_io notify_free"
cat "${SYS}/io_stat" 2>&1 || echo "(unreadable)"
echo
echo "== PSI /proc/pressure/memory =="
cat /proc/pressure/memory 2>&1 || echo "(no PSI)"
echo
echo "== memory =="
free -h 2>&1
grep -E "MemTotal|MemAvailable|SwapTotal|SwapFree" /proc/meminfo 2>&1
