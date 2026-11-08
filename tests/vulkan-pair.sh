#!/usr/bin/env bash
set -euo pipefail

# Policy fixture for the coupled Vulkan pair — 2026-09-25 incident
# (docs/JOURNAL.md "vulkan pair" section): a `-s` batch kept vulkan-headers-git
# at 1.4.363 while vulkan-icd-loader-git fetched upstream v1.4.364, whose
# CMake requires VulkanHeaders >= its own ${PROJECT_VERSION} — a cryptic
# "not compatible with the version requested" error mid-build().
#
# The live fix is a paired rebuild with -i (never -s: the skip predicate is
# stale-by-construction for VCS recipes). What this fixture pins is the
# hardening: the loader declares a VERSIONED vulkan-headers makedepends
# derived from its own pkgver base, so a stale provider fails at
# "Checking buildtime dependencies" with an actionable message instead.
#
# Read-only: asserts on committed recipe text; mutates nothing.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
loader="$root/packages/git/vulkan-icd-loader-git"
headers="$root/packages/git/vulkan-headers-git"

fail() {
    printf 'vulkan-pair fixture: %s\n' "$*" >&2
    exit 1
}

pkb="$loader/PKGBUILD"
srcinfo="$loader/.SRCINFO"
[[ -f $pkb ]] || fail "loader PKGBUILD missing: $pkb"
[[ -f $srcinfo ]] || fail "loader .SRCINFO missing: $srcinfo"

# 1. The constraint must be declared dynamically from pkgver, and carry
#    epoch 1. An epoch-less constraint would be satisfied by ANY epoch-1
#    build regardless of its version — the silent-wrong direction.
grep -Fq '"vulkan-headers>=1:${pkgver%%.r*}"' "$pkb" ||
    fail "PKGBUILD does not version-pin its vulkan-headers makedepends (expected \"vulkan-headers>=1:\${pkgver%%.r*}\")"

# 2. The expanded constraint must appear in .SRCINFO, derived from the
#    .SRCINFO pkgver itself — a hand-edited pair that srcinfo-freshness only
#    reports as "fields differ" is a specific bug here.
ver=$(sed -n 's/^[[:space:]]*pkgver = //p' "$srcinfo")
[[ -n $ver ]] || fail "cannot read pkgver from .SRCINFO"
base=${ver%%.r*}
grep -Fq "makedepends = vulkan-headers>=1:$base" "$srcinfo" ||
    fail ".SRCINFO lacks 'makedepends = vulkan-headers>=1:$base'"

# 3. The pair must stay comparable: the headers recipe provides with epoch 1,
#    the loader constrains with epoch 1. If either side drops its epoch the
#    two stop comparing on the same version axis — update both together.
grep -Fq '$_pkgname=1:$pkgver' "$headers/PKGBUILD" ||
    fail "vulkan-headers-git no longer provides \$_pkgname with epoch 1 (update the loader constraint and this fixture together)"

printf 'vulkan-pair fixture: PASS\n'
