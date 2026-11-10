#!/usr/bin/env bash
# tools/perf/bench.sh — repeated timing with a recorded noise floor.
#
#   tools/perf/bench.sh [--runs N] [--cold] [--label NAME] -- CMD [ARG...]
#
# Warm mode (default) runs CMD N times (default 7), DISCARDS the first as a
# page-cache warm-up, and reports min, median and the IQR of the rest. A
# difference smaller than the IQR is "not measured", not "faster".
#
# `--cold` drops the page cache once and takes ONE run, printed separately: the
# installed-ELF probe is I/O-bound and a warm median hides that. Needs
# passwordless sudo for `vm.drop_caches=3`.
#
# Every run is pinned to Zen 5 cores (0-3 and their SMT siblings 12-15) so a
# Zen 5c core cannot decide a 15% difference, and the header prints what a
# later reader needs to reproduce the row.
set -euo pipefail

runs=7
cold=0
label=""

usage() {
    sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
}

while [ $# -gt 0 ]; do
    case $1 in
    --runs) runs=${2:?--runs needs a count}; shift 2 ;;
    --cold) cold=1; shift ;;
    --label) label=${2:?--label needs a value}; shift 2 ;;
    --) shift; break ;;
    *) break ;;
    esac
done
[ $# -gt 0 ] || { usage; exit 2; }
[ -n "$label" ] || label="$*"

pins=${GSA_PERF_CPUS:-0-3,12-15}

now_us() {
    local t=${EPOCHREALTIME/./}
    printf '%s\n' "$t"
}

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

printf 'workload: %s\n' "$label"
printf 'command:  %s\n' "$*"
printf 'pins:     %s\n' "$pins"
printf 'store:    %s\n' "$(perf_store_commit)"
printf 'engine:   %s\n' "$(perf_engine_id "$1")"
printf 'kernel:   %s   load: %s\n' "$(uname -r)" "$(perf_load)"

timed_run() {
    local start end
    start=$(now_us)
    taskset -c "$pins" "$@" >/dev/null 2>&1
    end=$(now_us)
    printf '%s\n' $(( (end - start) / 1000 ))
}

summarise() {
    sort -n | awk '
    { v[NR] = $1 }
    END {
        n = NR
        med = (n % 2) ? v[(n + 1) / 2] : (v[n / 2] + v[n / 2 + 1]) / 2
        h = int(n / 2)
        q1 = (h % 2) ? v[(h + 1) / 2] : (v[h / 2] + v[h / 2 + 1]) / 2
        s = n - h + 1
        q3 = (h % 2) ? v[s + (h - 1) / 2] : (v[s + h / 2 - 1] + v[s + h / 2]) / 2
        printf "min=%d  median=%.1f  q1=%.1f  q3=%.1f  iqr=%.1f  n=%d\n", v[1], med, q1, q3, q3 - q1, n
        printf "RESULT min=%d median=%.1f iqr=%.1f runs=%d mode=warm\n", v[1], med, q3 - q1, n
    }'
}

if [ "$cold" = 1 ]; then
    sudo sysctl -qw vm.drop_caches=3
    ms=$(timed_run "$@")
    printf '\ncold (one run, page cache dropped): %s ms\n' "$ms"
    printf 'RESULT min=%s median=%s iqr=0 runs=1 mode=cold\n' "$ms" "$ms"
    exit 0
fi

samples=()
for i in $(seq 1 "$runs"); do
    ms=$(timed_run "$@")
    if [ "$i" = 1 ]; then
        printf '\nwarm-up (dropped): %s ms\n' "$ms"
        continue
    fi
    samples+=("$ms")
    printf 'run %d: %s ms\n' "$i" "$ms"
done

[ ${#samples[@]} -gt 0 ] || { printf 'bench: no scored runs\n' >&2; exit 2; }
printf '\n'
printf '%s\n' "${samples[@]}" | summarise
