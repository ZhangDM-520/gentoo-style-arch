#!/usr/bin/env bash
# tools/fmt.sh — check (or apply) workspace formatting with rustfmt directly.
#
# `cargo fmt` shells out to `cargo-fmt`, which aborts on the 2026-11 nightly
# toolchain this repository is built with (glibc malloc assertion at startup);
# `rustfmt` itself is fine. This script is therefore the one formatting
# command, so a contributor does not have to discover that difference.
#
#   tools/fmt.sh           # check; rc 1 when any file would change
#   tools/fmt.sh --write   # rewrite in place
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

mapfile -t files < <(find "$root/crates" -name '*.rs' -type f | sort)
if [ "${#files[@]}" -eq 0 ]; then
    printf 'fmt: no Rust sources under %s/crates\n' "$root" >&2
    exit 2
fi

if [ "${1:-}" = "--write" ]; then
    rustfmt --edition 2021 "${files[@]}"
else
    rustfmt --edition 2021 --check "${files[@]}"
fi
