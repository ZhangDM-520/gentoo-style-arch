#!/usr/bin/env bash
set -euo pipefail

# vscodium-insiders-git foreign prebuild strip fixture.
#
# package() ships the vscode tree verbatim; the bundled node native modules
# carry per-platform payloads of which only linux-x64/glibc can load on this
# host. A foreign payload's ELF closure trips the engine's install gate
# (2026-10-21: install-refused on tree-sitter/prebuilds/linux-arm64/
# tree-sitter.node → ld-linux-aarch64.so.1; round 2 the same day:
# vite/node_modules/lightningcss-linux-x64-musl/lightningcss.linux-x64-musl.node
# → libc.musl-x86_64.so.1). `_strip_foreign_prebuilds` therefore drops
#   (1) every prebuilds/<platform>/ dir except linux-x64, and
#   (2) every *-musl platform-variant module dir — a musl-ABI native can
#       never load under glibc; the built package carried 5 (rspack,
#       rolldown, rollup, lightningcss, @napi-rs/canvas), each with a
#       -gnu sibling that stays.
# This fixture runs the REAL helper over a synthetic pkgdir and pins both
# rules plus their scope:
#
#   - prebuilds/linux-x64 survives (the loadable variant);
#   - every other prebuilds/<platform> dir goes (incl. the gate offender);
#   - *-musl module dirs go whole (incl. scoped @rollup/… dirs);
#   - their -gnu siblings survive (the runtime-selected variants);
#   - native modules OUTSIDE those two classes are untouched.
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

# musl platform-variant module dirs + their gnu siblings (the round-2 class)
nm="$pkgdir/usr/share/vscodium-insiders-git/resources/app/build/vite/node_modules"
mm="$pkgdir/usr/share/vscodium-insiders-git/resources/app/extensions/mermaid-markdown-features/node_modules"
mkdir -p "$nm/lightningcss-linux-x64-musl" "$nm/lightningcss-linux-x64-gnu" \
    "$nm/@rollup/rollup-linux-x64-musl" "$nm/@rollup/rollup-linux-x64-gnu" \
    "$mm/@napi-rs/canvas-linux-x64-musl"
printf 'elf\n' >"$nm/lightningcss-linux-x64-musl/lightningcss.linux-x64-musl.node"
printf 'elf\n' >"$nm/lightningcss-linux-x64-gnu/lightningcss.linux-x64-gnu.node"
printf 'elf\n' >"$nm/@rollup/rollup-linux-x64-musl/rollup.linux-x64-musl.node"
printf 'elf\n' >"$nm/@rollup/rollup-linux-x64-gnu/rollup.linux-x64-gnu.node"
printf 'elf\n' >"$mm/@napi-rs/canvas-linux-x64-musl/skia.linux-x64-musl.node"
printf '{}\n' >"$mm/@napi-rs/canvas-linux-x64-musl/package.json"

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

# ─── 3. scope: natives outside the two strip classes are untouched ───────
[[ -f "$pkgdir/app/build/Release/keytar.node" ]] || fail "a non-prebuild native module was touched"
[[ -f "$pkgdir/app/bin/arm64/dpapi.node" ]] || fail "a non-prebuild payload outside prebuilds/ was touched"

# ─── 4. musl platform-variant module dirs go (the round-2 gate class) ────
[[ ! -e "$nm/lightningcss-linux-x64-musl" ]] ||
    fail "the lightningcss musl variant (the round-2 gate offender) survived"
[[ ! -e "$nm/@rollup/rollup-linux-x64-musl" ]] ||
    fail "a scoped musl variant (@rollup) survived"
[[ ! -e "$mm/@napi-rs/canvas-linux-x64-musl" ]] ||
    fail "the @napi-rs/canvas musl variant survived (dir must go whole)"

# ─── 5. gnu siblings stay (the runtime-selected variants) ────────────────
[[ -f "$nm/lightningcss-linux-x64-gnu/lightningcss.linux-x64-gnu.node" ]] ||
    fail "the lightningcss gnu variant was stripped"
[[ -f "$nm/@rollup/rollup-linux-x64-gnu/rollup.linux-x64-gnu.node" ]] ||
    fail "a scoped gnu variant was stripped"

printf 'vscodium prebuilds fixture: PASS\n'
