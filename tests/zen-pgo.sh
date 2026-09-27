#!/usr/bin/env bash
set -euo pipefail

# Pins the zen-browser PGO workload contract: prepare() applies the local
# 0007 patch, the deprecated Speedometer 2.0 entry is removed, Speedometer 3
# trains through the in-tree sp3_httpd entry (root path, auto-start, 120 s
# extendedTimeout), and .SRCINFO agrees with the PKGBUILD on pkgrel.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
recipe="packages/stable/zen-browser-pgo"
pkgbuild="$root/$recipe/PKGBUILD"
patch="$root/$recipe/0007-pgo-speedometer3.patch"

fail() {
    printf 'zen-pgo-workload: %s\n' "$1" >&2
    exit 1
}

test -f "$pkgbuild" || fail "missing $recipe/PKGBUILD"
test -f "$patch" || fail "missing $recipe/0007-pgo-speedometer3.patch"

grep -Fq 'patch -Np1 -i "$srcdir/0007-pgo-speedometer3.patch"' "$pkgbuild" ||
    fail "prepare() does not apply 0007-pgo-speedometer3.patch"

vars=$(bash -c '
    source "$1" || exit 1
    printf "pkgrel=%s\n" "$pkgrel"
    printf "src=%s\n" "${source[@]}"
' _ "$pkgbuild") || fail "cannot source the PKGBUILD"

grep -Fxq 'src=0007-pgo-speedometer3.patch' <<<"$vars" ||
    fail "0007-pgo-speedometer3.patch not listed in source=()"

pkgrel=$(grep -F 'pkgrel=' <<<"$vars" | cut -d= -f2)
srcinfo_pkgrel=$(awk -F' = ' '$1 == "\tpkgrel" || $1 == "pkgrel" { print $2 }' \
    "$root/$recipe/.SRCINFO")
test -n "$srcinfo_pkgrel" || fail ".SRCINFO has no pkgrel"
[[ $pkgrel == "$srcinfo_pkgrel" ]] ||
    fail ".SRCINFO pkgrel ($srcinfo_pkgrel) != PKGBUILD pkgrel ($pkgrel)"

# Rebuild the hunk states from the patch itself: post = context + added,
# pre = context + removed. A single one-deletion hunk proves every other
# workload entry survives byte-for-byte by construction.
[[ $(grep -c '^diff --git' "$patch") -eq 1 ]] ||
    fail "patch must touch exactly one file"
grep -Fq 'diff --git a/build/pgo/index.html b/build/pgo/index.html' "$patch" ||
    fail "patch does not target build/pgo/index.html"

mapfile -t body < <(awk '/^@@/ { in_hunk = 1; next }
                        in_hunk && /^-- ?$/ { exit }
                        in_hunk' "$patch")
((${#body[@]} > 0)) || fail "patch has no hunk body"

post=$(printf '%s\n' "${body[@]}" | grep -E '^[+ ]' | cut -c2- || true)
pre=$(printf '%s\n' "${body[@]}" | grep -E '^[- ]' | cut -c2- || true)

deletions=$(printf '%s\n' "${body[@]}" | grep -c '^-' || true)
additions=$(printf '%s\n' "${body[@]}" | grep -c '^+' || true)
[[ $deletions -eq 1 && $additions -eq 0 ]] ||
    fail "expected exactly one removed line and no additions (got -$deletions/+$additions)"

grep -Fq 'webkit/PerformanceTests/Speedometer/index.html' <<<"$pre" ||
    fail "pre-state does not contain the deprecated Speedometer 2.0 entry"
grep -Fq 'webkit/PerformanceTests/Speedometer/index.html' <<<"$post" &&
    fail "post-state still references Speedometer 2.0"

# The surviving SP3 entry: root-path URL served by profileserver's sp3_httpd
# (port 8000), the harness auto-start parameter, and the 120 s dwell.
grep -Fq 'http://localhost:8000/index.html?startAutomatically=true' <<<"$post" ||
    fail "post-state lacks the Speedometer3 auto-start entry"
grep -Fq 'startAutomatically' <<<"$post" ||
    fail "post-state lacks the auto-start parameter"
sp3_block=$(grep -A2 -F 'http://localhost:8000/index.html?startAutomatically=true' \
    <<<"$post")
grep -Fq 'extendedTimeout' <<<"$sp3_block" ||
    fail "Speedometer3 entry does not carry the extendedTimeout dwell"

# Workload-only change: no profileserver.py edit anywhere in the recipe.
grep -En '(sed|patch).*(profileserver\.py)' "$pkgbuild" &&
    fail "recipe edits profileserver.py — the workload fix must not need it"

printf 'zen-pgo-workload fixture: PASS\n'

# ==== zen-pgo-speedometer.sh ====
(

# Recipe hygiene for zen-browser-pgo: every local source exists and is visible
# to Git, the Speedometer3 workload patch carries its real sha256 (never SKIP),
# PGP checking stays on, options stay pacman-7-legal, and the patch is a valid
# single-file unified diff.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
recipe="packages/stable/zen-browser-pgo"
pkgbuild="$root/$recipe/PKGBUILD"
patch="$root/$recipe/0007-pgo-speedometer3.patch"

fail() {
    printf 'zen-pgo-speedometer: %s\n' "$1" >&2
    exit 1
}

test -f "$pkgbuild" || fail "missing $recipe/PKGBUILD"
test -f "$patch" || fail "missing $recipe/0007-pgo-speedometer3.patch"

vars=$(bash -c '
    source "$1" || exit 1
    printf "src=%s\n" "${source[@]}"
    printf "sum=%s\n" "${sha256sums[@]}"
    printf "opt=%s\n" "${options[@]}"
' _ "$pkgbuild") || fail "cannot source the PKGBUILD"

mapfile -t sources < <(grep -F 'src=' <<<"$vars" | cut -d= -f2-)
mapfile -t sums < <(grep -F 'sum=' <<<"$vars" | cut -d= -f2-)
mapfile -t opts < <(grep -F 'opt=' <<<"$vars" | cut -d= -f2-)

[[ ${#sources[@]} -eq ${#sums[@]} ]] ||
    fail "source=() (${#sources[@]}) and sha256sums=() (${#sums[@]}) differ in length"

# .SRCINFO freshness is owned by tests/srcinfo-freshness.sh (it regenerates and
# diffs every recipe from the --topology channel), so it is not re-asserted here.

declare -A sum_of
for i in "${!sources[@]}"; do
    src=${sources[$i]}
    case "$src" in
        *://* | *::*) continue ;;
    esac
    [[ -e $root/$recipe/$src ]] || fail "missing local source: $recipe/$src"
    git -C "$root" check-ignore -q -- "$recipe/$src" &&
        fail "local source hidden by .gitignore: $recipe/$src"
    sum_of["$src"]=${sums[$i]}
done

# The Speedometer3 workload patch: listed in source=() and pinned to the real
# digest of the file on disk; a drifted sum or SKIP silently unpins it.
recorded=${sum_of[0007-pgo-speedometer3.patch]:-}
[[ -n $recorded ]] || fail "0007-pgo-speedometer3.patch not listed in source=()"
[[ $recorded =~ ^[0-9a-f]{64}$ ]] ||
    fail "0007 checksum is not a sha256 digest: $recorded"
actual=$(sha256sum "$patch" | cut -d' ' -f1)
[[ $actual == "$recorded" ]] ||
    fail "0007 sha256sums ($recorded) != file digest ($actual)"

# Source verification discipline: never bypass PGP checking.
grep -Fq -- '--skippgpcheck' "$pkgbuild" && fail "bypasses PGP checking"

# pacman 7.x rejects !check/autodeps in options (recipe lint).
for opt in "${opts[@]}"; do
    case "$opt" in
        '!check' | 'autodeps') fail "invalid options entry: $opt" ;;
    esac
done

# Structural validity of the unified diff.
for marker in '--- a/build/pgo/index.html' '+++ b/build/pgo/index.html' '@@'; do
    grep -Fq -- "$marker" "$patch" ||
        fail "patch lacks unified-diff marker: $marker"
done
[[ $(grep -c '^diff --git' "$patch") -eq 1 ]] ||
    fail "patch must contain exactly one file diff"

printf 'zen-pgo-speedometer fixture: PASS\n'
)
