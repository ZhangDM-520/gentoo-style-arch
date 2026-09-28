#!/usr/bin/env bash
set -euo pipefail

# Pin the ripgrep Rust PGO contract (the mold-git family shape):
#
#  1. build() is the three-phase family: phase 1 instruments with
#     -Cprofile-generate and CARGO_PROFILE_RELEASE_LTO=false, training runs
#     exercise the instrumented rg (profile destination exported and later
#     unset, pattern runs status-guarded because rg exits 1 on no-match),
#     and the final rebuild carries -Cprofile-use + CARGO_PROFILE_RELEASE_LTO=fat
#     + CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1 + -Cstrip=symbols after
#     llvm-profdata merge.
#  2. Floor guard + fallback: a pgo_min_profraw threshold is compared against
#     the produced .profraw count and a missed floor falls back to a plain
#     fat-LTO build — never a merge of an empty profile.
#  3. verify_no_profile_instrumentation "$pkgdir" is the LAST statement of
#     package(), unweakened (never `|| return 1`: bash returns the last
#     command's status, so a discarded gate guarded nothing).
#  4. options=(!debug strip !lto) — rust LTO is per-phase, and the profile-use
#     phase strips symbols on purpose.
#
# Static inspection only — this never runs a build.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
recipe="packages/stable/ripgrep"
pkgbuild="$root/$recipe/PKGBUILD"

fail() {
    printf 'ripgrep-pgo: %s\n' "$1" >&2
    exit 1
}

test -f "$pkgbuild" || fail "missing PKGBUILD: $recipe/PKGBUILD"

# The recipe must parse at all.
if ! err=$(bash -n "$pkgbuild" 2>&1); then
    fail "bash -n rejected the PKGBUILD: $err"
fi

line_of() {
    grep -nF -m1 -- "$1" "$pkgbuild" | cut -d: -f1 || true
}

# ---- Phase 1: instrumented build ----------------------------------------
grep -Fq -- '-Cprofile-generate=${_pgo_dir}' "$pkgbuild" ||
    fail "phase 1 lacks -Cprofile-generate=\${_pgo_dir}"
grep -Fq 'CARGO_PROFILE_RELEASE_LTO=false' "$pkgbuild" ||
    fail "phase 1 does not set CARGO_PROFILE_RELEASE_LTO=false"
grep -Fq 'unset RUSTC_WRAPPER' "$pkgbuild" ||
    fail "PGO phases do not force-disable compiler wrappers (sccache)"

# ---- Phase 2: profile-use optimized build -------------------------------
grep -Fq -- '-Cprofile-use=${_pgo_dir}/merged.profdata' "$pkgbuild" ||
    fail "final rebuild lacks -Cprofile-use=\${_pgo_dir}/merged.profdata"
grep -Fq 'llvm-profdata merge' "$pkgbuild" ||
    fail "profiles are never merged (no llvm-profdata merge)"
grep -Fq 'CARGO_PROFILE_RELEASE_LTO=fat' "$pkgbuild" ||
    fail "final rebuild does not set CARGO_PROFILE_RELEASE_LTO=fat"
grep -Fq 'CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1' "$pkgbuild" ||
    fail "final rebuild does not set CARGO_PROFILE_RELEASE_CODEGEN_UNITS=1"
grep -Fq -- '-Cstrip=symbols' "$pkgbuild" ||
    fail "final rebuild does not carry -Cstrip=symbols"

# Ordering: instrument before use, LTO=false before LTO=fat.
gen_line=$(line_of '-Cprofile-generate=${_pgo_dir}')
use_line=$(line_of '-Cprofile-use=${_pgo_dir}/merged.profdata')
lto_off_line=$(line_of 'CARGO_PROFILE_RELEASE_LTO=false')
lto_fat_line=$(line_of 'CARGO_PROFILE_RELEASE_LTO=fat')
[[ -n $gen_line && -n $use_line ]] || fail "phase flag lines not found"
(( gen_line < use_line )) ||
    fail "-Cprofile-generate (line $gen_line) does not precede -Cprofile-use (line $use_line)"
(( lto_off_line < lto_fat_line )) ||
    fail "LTO=false (line $lto_off_line) does not precede LTO=fat (line $lto_fat_line)"

# ---- Training run shape -------------------------------------------------
grep -Fq 'LLVM_PROFILE_FILE="${_pgo_dir}/rg-%p-%m.profraw"' "$pkgbuild" ||
    fail "training runs do not export LLVM_PROFILE_FILE into the PGO dir"
grep -Fq 'unset LLVM_PROFILE_FILE' "$pkgbuild" ||
    fail "LLVM_PROFILE_FILE leaks past the training runs"
guarded=$(grep -cF '>/dev/null || true' "$pkgbuild" || true)
(( guarded >= 4 )) ||
    fail "too few status-guarded training runs ($guarded; rg exits 1 on no-match)"

# ---- Floor guard + fallback --------------------------------------------
grep -Eq 'local pgo_min_profraw=' "$pkgbuild" ||
    fail "no pgo_min_profraw floor threshold"
grep -Fq 'profraw_count <= pgo_min_profraw' "$pkgbuild" ||
    fail "produced .profraw count is not compared against pgo_min_profraw"
grep -Fq 'falling back to a plain fat-LTO build' "$pkgbuild" ||
    fail "no fallback warning when the profile floor is missed"
fat_builds=$(grep -cF 'CARGO_PROFILE_RELEASE_LTO=fat' "$pkgbuild" || true)
(( fat_builds >= 2 )) ||
    fail "fallback and final rebuild must each build fat-LTO (found $fat_builds)"

# ---- options=(!debug strip !lto) ---------------------------------------
grep -Fq 'options=(!debug strip !lto)' "$pkgbuild" ||
    fail "options=(!debug strip !lto) is missing"

# ---- Gate: last statement of package(), unweakened ---------------------
last_stmt=$(awk '
    /^package\(\)/ { in_pkg = 1; next }
    in_pkg && /^}/ { exit }
    in_pkg && $0 !~ /^[[:space:]]*($|#)/ { line = $0 }
    END { print line }
' "$pkgbuild")
[[ $last_stmt =~ ^[[:space:]]*verify_no_profile_instrumentation[[:space:]]+\"\$pkgdir\" ]] ||
    fail "package() does not end with verify_no_profile_instrumentation \"\$pkgdir\" (last statement: ${last_stmt:-<none>})"
if grep -E 'verify_no_profile_instrumentation.*\|\|' "$pkgbuild" >/dev/null; then
    fail "verify_no_profile_instrumentation is || -weakened (the gate is fatal on purpose)"
fi
grep -Fq 'source "$startdir/../../../lib/pgo.sh"' "$pkgbuild" ||
    fail "recipe does not source the shared gate module lib/pgo.sh"

printf 'ripgrep-pgo fixture: PASS\n'
