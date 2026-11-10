#!/usr/bin/env bash
# tools/perf/matrix.sh — the review's measurement set, as one reproducible run.
#
#   tools/perf/matrix.sh [--out FILE] [--cheap N] [--heavy N] [--cold]
#
# Emits a markdown table: one row per workload with the bench.sh RESULT
# (min / median / IQR), plus a metadata block naming the engine, the recipe
# store commit, the kernel and the pin set. `--cold` adds a second table of
# one-run page-cache-dropped rows for the workloads whose cost is I/O-bound.
#
# Cheap workloads default to 5 scored runs, the closure-sized plans to 3: a
# 20 s workload at 7 repetitions would cost a coffee, and its own IQR is what
# decides whether a difference is real.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
. "$root/tools/perf/lib.sh"
out=/dev/stdout
cheap=5
heavy=3
cold=0

while [ $# -gt 0 ]; do
    case $1 in
    --out) out=${2:?--out needs a path}; shift 2 ;;
    --cheap) cheap=${2:?--cheap needs a count}; shift 2 ;;
    --heavy) heavy=${2:?--heavy needs a count}; shift 2 ;;
    --cold) cold=1; shift ;;
    *) printf 'matrix: unknown argument %s\n' "$1" >&2; exit 2 ;;
    esac
done

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/gsa-matrix.XXXXXX")
trap 'command rm -rf -- "$tmpdir"' EXIT

run_bench() { # runs label cmd...
    local runs=$1 label=$2
    shift 2
    local log=$tmpdir/log
    "$root/tools/perf/bench.sh" --runs "$runs" --label "$label" -- "$@" >"$log" 2>&1 || true
    local result
    result=$(grep '^RESULT' "$log" | tail -1)
    if [ -z "$result" ]; then
        printf '| %s | **failed** | | | | |\n' "$label"
        return 0
    fi
    local min median iqr mode
    min=$(sed -n 's/.*min=\([0-9.]*\).*/\1/p' <<<"$result")
    median=$(sed -n 's/.*median=\([0-9.]*\).*/\1/p' <<<"$result")
    iqr=$(sed -n 's/.*iqr=\([0-9.]*\).*/\1/p' <<<"$result")
    mode=$(sed -n 's/.*mode=\([a-z]*\).*/\1/p' <<<"$result")
    printf '| `%s` | %s | %s | %s | %s |\n' "$label" "$min" "$median" "$iqr" "$mode"
}

{
    printf '# Whole-workspace performance matrix\n\n'
    printf '```\n'
    printf 'engine:   %s\n' "$(perf_engine_id gsa)"
    printf 'store:    %s\n' "$(perf_store_commit)"
    printf 'kernel:   %s\n' "$(uname -r)"
    printf 'pins:     %s\n' "$(perf_pins)"
    printf 'load:     %s\n' "$(perf_load)"
    printf 'date:     %s\n' "$(date -Iseconds)"
    printf '```\n\n'
    printf '## Warm (median of scored runs, first discarded)\n\n'
    printf '| workload | min ms | median ms | IQR ms | mode |\n| --- | --- | --- | --- | --- |\n'

    run_bench "$cheap" 'gsa --help' gsa --help
    run_bench "$cheap" 'gsa -Qt' gsa -Qt
    run_bench "$cheap" 'gsa -Sl' gsa -Sl
    run_bench "$cheap" 'gsa -Q' gsa -Q
    run_bench "$cheap" 'gsa -Qi zlib-ng-git' gsa -Qi zlib-ng-git
    run_bench "$cheap" 'gsa -Qa zlib-ng-git' gsa -Qa zlib-ng-git
    # The completion seam runs once per TAB, so its cost is a latency
    # budget: a flag position must not reach a store read.
    run_bench "$cheap" 'gsa --complete -S ""' gsa --complete -S ""
    run_bench "$cheap" 'gsa --complete -S --toolchain' gsa --complete -S --toolchain ""
    run_bench 2 'gsa -Ma' gsa -Ma
    run_bench "$cheap" 'gsa -S --dry-run --leaf zlib-ng-git' gsa -S --dry-run --leaf zlib-ng-git
    run_bench "$heavy" 'gsa -S --dry-run @core' gsa -S --dry-run @core
    run_bench "$heavy" 'gsa -S --dry-run @git' gsa -S --dry-run @git
    run_bench 3 'stub-run 8' "$root/tools/perf/stub-run.sh" --packages 8
    run_bench 3 'stub-run 32' "$root/tools/perf/stub-run.sh" --packages 32
    run_bench 2 'stub-run 128' "$root/tools/perf/stub-run.sh" --packages 128

    if [ "$cold" = 1 ]; then
        printf '\n## Cold (one run, `vm.drop_caches=3` before it)\n\n'
        printf '| workload | ms |\n| --- | --- |\n'
        for workload in '@core' '@git'; do
            log=$tmpdir/cold
            "$root/tools/perf/bench.sh" --cold --label "gsa -S --dry-run $workload" \
                -- gsa -S --dry-run "$workload" >"$log" 2>&1 || true
            ms=$(sed -n 's/.*median=\([0-9.]*\).*/\1/p' <<<"$(grep '^RESULT' "$log" | tail -1)")
            printf '| `gsa -S --dry-run %s` | %s |\n' "$workload" "${ms:-failed}"
        done
    fi
} >"$out"

printf 'matrix written to %s\n' "$out"
