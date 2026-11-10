#!/usr/bin/env bash
# tools/perf/probe.sh — where a workload's cost actually goes.
#
#   tools/perf/probe.sh [--top N] [--heaptrack] -- CMD [ARG...]
#
# Three views, cheap to cheap:
#   1. syscall summary (`strace -f -c`) — the syscall that dominates is usually
#      the cost;
#   2. open-path classes (`strace -f -e trace=openat`) — which tree the engine
#      reads, as a count per top-level directory and per known root (recipe
#      store, pacman local db, /usr);
#   3. optionally `heaptrack` — allocations and peak RSS for a workload whose
#      page faults suggest churn.
#
# Sample counts and peak memory are what to compare across a before/after: they
# do not move with CPU frequency, so a hybrid core cannot fake a win.
set -euo pipefail

top=10
heap=0
while [ $# -gt 0 ]; do
    case $1 in
    --top) top=${2:?--top needs a count}; shift 2 ;;
    --heaptrack) heap=1; shift ;;
    --) shift; break ;;
    *) break ;;
    esac
done
[ $# -gt 0 ] || { sed -n '2,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

scratch=$(mktemp -d "${TMPDIR:-/tmp}/gsa-perf.XXXXXX")
trap 'command rm -rf -- "$scratch"' EXIT

printf '=== syscalls (top %s) ===\n' "$top"
strace -f -c -o "$scratch/syscalls" "$@" >/dev/null 2>&1 || true
sed -n '1,3p' "$scratch/syscalls"
tail -n +4 "$scratch/syscalls" | sort -k2 -rn | head -"$top"

printf '\n=== openat by tree ===\n'
strace -f -e trace=openat -o "$scratch/openat" "$@" >/dev/null 2>&1 || true
total=$(grep -c 'openat(' "$scratch/openat" || true)
printf 'openat total: %s\n' "${total:-0}"
grep -o '"[^"]*"' "$scratch/openat" | tr -d '"' | grep '^/' |
    sed -E 's#^(/[^/]+/[^/]+)/.*#\1#; s#^(/[^/]+)/.*#\1#' |
    sort | uniq -c | sort -rn | head -"$top"
printf 'one line per known root:\n'
for known in "$HOME/.local/share/gsa/recipes" /var/lib/pacman/local /usr /etc /proc; do
    n=$(grep -c "openat([^,]*, \"$known" "$scratch/openat" || true)
    printf '  %-40s %s\n' "$known" "${n:-0}"
done

if [ "$heap" = 1 ]; then
    printf '\n=== heap (heaptrack) ===\n'
    if command -v heaptrack >/dev/null 2>&1; then
        heaptrack -o "$scratch/heap" "$@" >/dev/null 2>&1 || true
        if [ -f "$scratch/heap.zst" ]; then
            heaptrack_print "$scratch/heap.zst" 2>/dev/null |
                grep -E 'total runtime|peak memory|calls to allocation|total memory allocated' | head -6
        else
            printf 'heaptrack produced no data\n'
        fi
    else
        printf 'heaptrack not installed — skipped\n'
    fi
fi
