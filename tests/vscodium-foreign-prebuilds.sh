#!/usr/bin/env bash
set -euo pipefail

# vscodium-insiders-git foreign prebuild strip fixture.
#
# package() ships the vscode tree verbatim; the bundled node native modules
# carry per-platform prebuilds of which only linux-x64/ can load on this
# host. A foreign prebuild's ELF closure trips the engine's install gate
# (2026-10-21: install-refused on tree-sitter/prebuilds/linux-arm64/
# tree-sitter.node → ld-linux-aarch64.so.1), so `_strip_foreign_prebuilds`
# drops every prebuilds/<platform>/ dir except linux-x64. This fixture runs
# the REAL helper over a synthetic pkgdir and pins:
#
#   - prebuilds/linux-x64 survives (the loadable variant);
#   - every other prebuilds/<platform> dir goes (incl. the gate offender);
#   - native modules OUTSIDE prebuilds/ are untouched (scope is prebuilds).
#
# Everything happens in a scratch tree.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
recipe="$root/packages/git/vscodium-insiders-git"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-vscodium-prebuilds.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'vscodium prebuilds fixture: %s\n' "$1" >&2
    exit 1
}

# ─── Synthetic pkgdir ─────────────────────────────────────────────────────
pkgdir="$tmp/pkg"
ts="$pkgdir/usr/share/vscodium-insiders-git/resources/app/build/node_modules/tree-sitter/prebuilds"
mkdir -p "$ts/linux-x64" "$ts/linux-arm64" "$ts/darwin-arm64" "$ts/win32-x64"
mkdir -p "$pkgdir/app/build/Release" "$pkgdir/app/bin/arm64"
for d in linux-x64 linux-arm64 darwin-arm64 win32-x64; do
    printf 'elf\n' >"$ts/$d/tree-sitter.node"
done
printf 'elf\n' >"$pkgdir/app/build/Release/keytar.node"
printf 'pe\n' >"$pkgdir/app/bin/arm64/dpapi.node"

# ─── Run the real helper ──────────────────────────────────────────────────
{
    printf '%s\n' "source '$recipe/PKGBUILD'"
    printf '%s\n' "_strip_foreign_prebuilds '$pkgdir'"
} >"$tmp/wrapper.sh"
bash "$tmp/wrapper.sh" >"$tmp/out" 2>&1 || fail "the helper itself failed: $(cat "$tmp/out")"

# ─── 1. linux-x64 survives ────────────────────────────────────────────────
[[ -f "$ts/linux-x64/tree-sitter.node" ]] ||
    fail "the loadable linux-x64 prebuild was stripped"

# ─── 2. foreign prebuild dirs go (incl. the gate offender) ────────────────
[[ ! -e "$ts/linux-arm64" ]] || fail "the linux-arm64 prebuild (the gate offender) survived"
[[ ! -e "$ts/darwin-arm64" ]] || fail "a darwin prebuild survived"
[[ ! -e "$ts/win32-x64" ]] || fail "a win32 prebuild survived"

# ─── 3. scope: native modules outside prebuilds/ are untouched ────────────
[[ -f "$pkgdir/app/build/Release/keytar.node" ]] || fail "a non-prebuild native module was touched"
[[ -f "$pkgdir/app/bin/arm64/dpapi.node" ]] || fail "a non-prebuild payload outside prebuilds/ was touched"

printf 'vscodium prebuilds fixture: PASS\n'
