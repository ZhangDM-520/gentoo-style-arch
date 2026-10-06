#!/usr/bin/env bash
# The builder must refuse to install a PGO archive whose payload still carries
# phase-1 instrumentation. Such a binary bakes absolute `.gcda` destinations
# into .rodata and libgcov recreates that whole tree on every invocation
# (2026-09-20: five files in cmake-git and xorg-xwayland-git rebuilt 779 files
# under ~/Projects from one command each).
#
# This asserts the install gate directly, with hand-placed archives and no
# makepkg at all: the property belongs to `install_all`/`install_pkgs_now`, not
# to any one recipe. Payloads cover the outcomes:
#
#   pgo-bad    PGO recipe, instrumented usr/bin      -> refuse, install nothing
#   deep-bad   PGO recipe, instrumented usr/libexec   -> refuse. Completeness:
#              a leak outside usr/bin and usr/lib is still a leak
#   rust-bad   Rust PGO recipe (-Cprofile-generate), payload baking a
#              pgo-data/*.profraw destination -> refuse. The gate must name
#              rustc's spelling of the flag, not only C's -fprofile-generate
#   pgo-clean  PGO recipe, clean payload, metadata and a doc that quotes a
#              .gcda path -> install. Precision: a mere mention is not a leak
#   plain-bad  non-PGO recipe, instrumented payload   -> install. Gate: a recipe
#              that never instruments cannot leak, so it is never unrolled
#   rust-clean Rust PGO recipe, clean payload         -> install (a Rust recipe
#              that really replaced its phase-3 flags must not be refused)
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-pgo-payload.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

make_workspace "$fixture" auto auto xhigh
make_install_conf "$fixture/pacman.conf" # this run's IgnorePkg registration target (never the host's)

# A recipe counts as PGO to the gate purely by naming an instrumenting flag,
# so the gate and the payload are varied independently.
add_recipe() {
    local id="$1" instrumenting="$2" extra
    case "$instrumenting" in
        yes) extra='pkgver=1.0
pkgrel=1
arch=(x86_64)
build() {
  CFLAGS+=" -fprofile-generate"
}' ;;
        rust) extra='pkgver=1.0
pkgrel=1
arch=(x86_64)
build() {
  RUSTFLAGS+=" -Cprofile-generate=$srcdir/pgo-data"
}' ;;
        *) extra='pkgver=1.0
pkgrel=1
arch=(x86_64)
build() {
  :
}' ;;
    esac
    add_package "$fixture" "$id" "$extra"
}

leak_path() { printf '/home/someone/build/pgo-fixture/%s/src/A.dir/b.cxx.gcda' "$1"; }
rust_leak_path() { printf '/home/someone/build/pgo-fixture/%s/src/pgo-data/mold-%%p.profraw' "$1"; }

# $1 recipe id, $2 "" | usr/bin | usr/libexec  (where the leak is baked)
# $3 gcda (default) | profraw — which kind of baked destination the leak is
add_archive() {
    local id="$1" where="$2" stage leak
    stage=$(mktemp -d "$fixture/stage.XXXXXX")
    if [[ "${3:-gcda}" == profraw ]]; then
        leak=$(rust_leak_path "$id")
    else
        leak=$(leak_path "$id")
    fi
    mkdir -p "$stage/usr/bin" "$stage/usr/lib" "$stage/usr/libexec" \
        "$stage/usr/share/doc/$id"
    # Metadata is never a leak: .BUILDINFO records the build's own flags.
    printf 'format = 2\npkgname = %s\nbuildenv = CFLAGS=-O2 -fprofile-generate\n' \
        "$id" >"$stage/.BUILDINFO"
    printf 'pkgname = %s\npkgver = 1.0\n' "$id" >"$stage/.PKGINFO"
    # A doc that *quotes* a .gcda path in prose must not fail the package: the
    # predicate matches a standalone absolute path, not a mention inside a line.
    printf 'coverage notes: rebuild %s\n' "$(leak_path "$id")" \
        >"$stage/usr/share/doc/$id/notes.txt"
    printf 'code\0/usr/lib/clean.so\0code\n' >"$stage/usr/bin/$id"
    printf 'data\n' >"$stage/usr/lib/lib$id.so"
    case "$where" in
        usr/bin) printf 'code\0%s\0code\n' "$leak" >"$stage/usr/bin/$id" ;;
        usr/libexec) printf 'code\0%s\0code\n' "$leak" >"$stage/usr/libexec/$id-helper" ;;
    esac
    tar --zstd -cf "$fixture/packages/$id/$id-1.0-1-x86_64.pkg.tar.zst" \
        -C "$stage" .
    rm -rf -- "$stage"
}

archive_of() { printf '%s/packages/%s/%s-1.0-1-x86_64.pkg.tar.zst' "$fixture" "$1" "$1"; }

add_recipe pgo-bad yes
add_recipe deep-bad yes
add_recipe pgo-clean yes
add_recipe plain-bad no
add_recipe rust-bad rust
add_recipe rust-clean rust
add_archive pgo-bad usr/bin
add_archive deep-bad usr/libexec
add_archive pgo-clean ""
add_archive plain-bad usr/bin
add_archive rust-bad usr/bin profraw
add_archive rust-clean ""

cat >"$fixture/bin/pacman" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GSA_FAKE_PACMAN_LOG"
EOF
chmod +x "$fixture/bin/pacman"

cat >"$fixture/bin/sudo" <<'EOF'
#!/usr/bin/env bash
# Run what it was given; leading sudo flags are dropped (including
# --preserve-env, which host fish `sudo` wrapper functions inject).
while [[ ${1:-} == -* ]]; do
    shift
done
exec "$@"
EOF
chmod +x "$fixture/bin/sudo"

: >"$fixture/pacman.log"
export GSA_FAKE_PACMAN_LOG="$fixture/pacman.log"
# Parallel-soundness: the payload check extracts into "$TMPDIR"/gsa-pgo-verify.*,
# so counting that pattern in the shared battery $TMPDIR races against any
# concurrent fixture exercising the same seam (observed "0 -> 1" flake,
# 2026-10-06). Give the runs a private $TMPDIR and count there — the
# assertion is unchanged and unambiguous.
export TMPDIR="$fixture/tmp"
mkdir -p "$TMPDIR"
temp_root="$TMPDIR"
leftovers_before=$(find "$temp_root" -maxdepth 1 -name 'gsa-pgo-verify.*' 2>/dev/null | wc -l)

# status-returning wrapper over the helper's capture runner
run_case() {
    run_builder env \
        PATH="$fixture/bin:$PATH" \
        GSA_STATE_DIR="$fixture/state" \
        _IGNOREPKG_CONF="$fixture/pacman.conf" \
        fish "$fixture/build-all.fish" --installall
    printf '%s\n' "$FIXTURE_OUTPUT"
    return "$FIXTURE_RC"
}

# $1 archive basename, $2 member the refusal must name
refuses() {
    local output
    if output=$(run_case); then
        printf 'instrumented payload in %s was installed instead of refused:\n%s\n' \
            "$1" "$output" >&2
        exit 1
    fi
    if ! printf '%s\n' "$output" | grep -F -- "$2" >/dev/null; then
        printf 'refusal for %s did not name %s:\n%s\n' "$1" "$2" "$output" >&2
        exit 1
    fi
    if ! printf '%s\n' "$output" | grep -F -- 'libgcov would recreate its build tree' >/dev/null; then
        printf 'refusal for %s did not explain the consequence:\n%s\n' "$1" "$output" >&2
        exit 1
    fi
    if [[ -s "$fixture/pacman.log" ]]; then
        printf 'pacman ran even though %s failed the payload check:\n' "$1" >&2
        cat "$fixture/pacman.log" >&2
        exit 1
    fi
}

# ── Case A: an instrumented usr/bin payload is refused, and nothing installed
refuses pgo-bad './usr/bin/pgo-bad'

# ── Case B: a leak under usr/libexec is refused too, not only usr/bin and usr/lib
rm -f "$(archive_of pgo-bad)"
refuses deep-bad './usr/libexec/deep-bad-helper'

# ── Case D: a Rust -Cprofile-generate recipe with a baked .profraw destination
# is refused by name — the gate must match rustc's flag spelling and the
# LLVM runtime's file extension, not only C's -fprofile-generate/.gcda.
rm -f "$(archive_of deep-bad)"
refuses rust-bad './usr/bin/rust-bad'

# ── Case C: a clean PGO archive installs, and the non-PGO one is not unrolled
rm -f "$(archive_of rust-bad)"
if ! output=$(run_case); then
    printf 'clean payloads were incorrectly refused:\n%s\n' "$output" >&2
    exit 1
fi
for expected in pgo-clean plain-bad rust-clean; do
    if ! grep -F "$expected-1.0-1-x86_64.pkg.tar.zst" "$fixture/pacman.log" >/dev/null; then
        printf '%s was not installed:\n' "$expected" >&2
        cat "$fixture/pacman.log" >&2
        exit 1
    fi
done

# The check is read-only: it must not leave the payload unrolled, and must not
# consume or rewrite the archive it inspected.
leftovers_after=$(find "$temp_root" -maxdepth 1 -name 'gsa-pgo-verify.*' 2>/dev/null | wc -l)
if [[ "$leftovers_after" -ne "$leftovers_before" ]]; then
    printf 'payload check left its temp extraction behind (%s -> %s)\n' \
        "$leftovers_before" "$leftovers_after" >&2
    exit 1
fi
if [[ ! -s "$(archive_of pgo-clean)" ]]; then
    printf 'payload check consumed the archive it inspected\n' >&2
    exit 1
fi

printf 'PGO payload guard fixture: PASS\n'
