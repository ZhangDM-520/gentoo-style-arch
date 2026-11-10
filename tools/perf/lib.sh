#!/usr/bin/env bash
# tools/perf/lib.sh — the metadata every perf row carries, in one place.
#
# Sourced by bench.sh, matrix.sh and probe.sh; never executed. A measurement
# that cannot name the binary it measured is not reproducible, and `gsa` has no
# `--version` spelling (contract §B), so identity is the resolved path, the
# digest of its bytes and the package that owns it.
set -euo pipefail

perf_engine_id() { # BIN
    local bin=$1 path sha pkg
    path=$(command -v -- "$bin" 2>/dev/null || true)
    [ -n "$path" ] || path=$bin
    sha=$(sha256sum -- "$path" 2>/dev/null | cut -c1-12 || true)
    pkg=$(pacman -Qo -- "$path" 2>/dev/null | sed 's/.* is owned by //' || true)
    printf '%s  sha256:%s  %s' "$path" "${sha:-unreadable}" "${pkg:-unowned}"
}

perf_store_commit() {
    local store=${GSA_RECIPES_DIR:-$HOME/.local/share/gsa/recipes}
    git -C "$store" rev-parse --short HEAD 2>/dev/null || printf -- '-'
}

perf_pins() {
    printf '%s' "${GSA_PERF_CPUS:-0-3,12-15}"
}

perf_load() {
    cut -d' ' -f1-3 /proc/loadavg
}
