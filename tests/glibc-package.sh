#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root" || exit 1

recipe=packages/core/glibc-git
builder=$root/build-all.fish

fail() {
    printf 'glibc package fixture: %s\n' "$1" >&2
    exit 1
}

[[ -f $recipe/PKGBUILD ]] || fail "missing $recipe/PKGBUILD"
[[ -f $recipe/.SRCINFO ]] || fail "missing $recipe/.SRCINFO"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-glibc-package.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

makepkg --printsrcinfo --dir "$recipe" >"$tmp/.SRCINFO" ||
    fail 'makepkg --printsrcinfo failed'
cmp -s "$tmp/.SRCINFO" "$recipe/.SRCINFO" ||
    fail 'committed .SRCINFO differs from PKGBUILD metadata'

pkgver=$(sed -n 's/^[[:space:]]*pkgver = //p' "$tmp/.SRCINFO" | head -n1)
[[ -n $pkgver ]] || fail 'pkgver is missing from .SRCINFO'
[[ $(vercmp "$pkgver" 2.40) -ge 0 ]] ||
    fail "glibc version $pkgver does not satisfy the workspace >=2.40 floor"

for pkgname in glibc-git lib32-glibc-git glibc-locales-git; do
    grep -Fqx "pkgname = $pkgname" "$tmp/.SRCINFO" ||
        fail "missing split output $pkgname"
done

for provide in "glibc=$pkgver" "lib32-glibc=$pkgver" "glibc-locales=$pkgver"; do
    grep -Fqx "$(printf '\tprovides = %s' "$provide")" "$tmp/.SRCINFO" ||
        fail "missing versioned provide $provide"
done

exact_dep=$(printf '\tdepends = glibc-git=%s' "$pkgver")
[[ $(grep -Fxc "$exact_dep" "$tmp/.SRCINFO") -eq 2 ]] ||
    fail 'lib32 and locales outputs must depend on the matching glibc-git version'

topology=$(fish "$builder" --topology) || fail 'builder --topology failed'
grep -Fqx 'glibc-git|packages/core/glibc-git|core|linux-api-headers|' \
    <<<"$topology" || fail 'glibc-git topology row or linux-api-headers edge is missing'
grep -Fqx 'gcc-snapshot|packages/core/gcc-snapshot|core|glibc-git|version-sync=nvchecker' \
    <<<"$topology" || fail 'gcc-snapshot topology row, edge, or version-sync opt-in is missing'

for pkgname in lib32-glibc-git glibc-locales-git; do
    output=$(fish "$builder" --dry-run --no-deps "$pkgname" 2>&1) ||
        fail "builder rejected split output $pkgname: $output"
    rows=$(sed -n 's/^ *[0-9][0-9]*\. //p' <<<"$output")
    [[ $rows == glibc-git ]] ||
        fail "$pkgname should resolve to the single glibc-git recipe, got: $rows"
done

output=$(fish "$builder" --dry-run linux-api-headers 2>&1) ||
    fail "builder could not dry-run the glibc toolchain chain: $output"
rows=$(sed -n 's/^ *[0-9][0-9]*\. //p' <<<"$output")
awk '
    $0 == "linux-api-headers" { headers = NR }
    $0 == "glibc-git" { glibc = NR }
    $0 == "gcc-snapshot" { gcc = NR }
    END { exit !(headers > 0 && headers < glibc && glibc < gcc) }
' <<<"$rows" || fail "expected linux-api-headers, glibc-git, gcc-snapshot order; got: $rows"

printf 'glibc package fixture: PASS (split metadata, topology, aliases, and consumer order)\n'
