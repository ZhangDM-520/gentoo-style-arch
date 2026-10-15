#!/usr/bin/env bash
# The engine must refuse to install a PGO archive whose payload still carries
# phase-1 instrumentation. Such a binary bakes absolute `.gcda` destinations
# into .rodata and libgcov recreates that whole tree on every invocation
# (2026-09-20: five files in cmake-git and xorg-xwayland-git rebuilt 779 files
# under ~/Projects from one command each).
#
# This asserts the install gate directly, with hand-placed archives and no
# makepkg at all: the property belongs to the install decision pipeline
# (contract §E.1), not to any one recipe. Payloads cover the outcomes:
#
#   pgo-bad    PGO recipe, instrumented usr/bin      -> refuse, install nothing
#   deep-bad   PGO recipe, instrumented usr/libexec   -> refuse. Completeness:
#              a leak outside usr/bin and usr/lib is still a leak
#   rust-bad   Rust PGO recipe (-Cprofile-generate), payload baking a
#              pgo-data/*.profraw destination -> refuse. The gate must name
#              rustc's spelling of the flag, not only C's -fprofile-generate
#   pgo-mention PGO recipe, clean binary, a doc that QUOTES a .gcda path in
#              prose -> refuse on the ENGINE (see DEVIATION below; fish
#              installed it — "a mere mention is not a leak")
#   pgo-clean  PGO recipe, clean payload             -> install (a clean PGO
#              archive must not be refused)
#   plain-bad  non-PGO recipe, instrumented payload   -> install. Gate: a recipe
#              that never instruments cannot leak, so it is never unrolled
#   rust-clean Rust PGO recipe, clean payload         -> install (a Rust recipe
#              that really replaced its phase-3 flags must not be refused)
set -euo pipefail

# Flip notes (docs/gsa-fixture-migration.md row `tests/pgo-payload-guard.sh`):
# argv `--installall` flips to `gsa -Ua` (§B.6, force mode inherent); the
# `_IGNOREPKG_CONF` fixture seam flips to the engine's `--config PATH`
# registration target (gap G6 — the engine names its conf explicitly). The
# refusal meanings re-pin as §E.2 rows through the hidden
# `gsa --install-decide <checked|force> <archive…>` seam (§D.1):
# `<pkgbase> refuse pgo-hit <archive> <member>` + `pgo-instrumented` — the row
# detail names the offending MEMBER, so the old prose byte-pins (the refusal
# format string and the `libgcov would recreate its build tree` explanation)
# retire as rendering (§L.3) with their meanings carried by the row detail and
# the run record's `install-refused pgo-hit …` outcome reason (§H.2). rc: the
# seam is 1 (§E.5: a plan with a refuse row), the `-Ua` run is 3 (§G.1: a
# refusal reached execution); both were "non-zero" before. The gate order is
# the §E.1 order — the PGO payload gate fires before the force branch, so
# `-Ua`'s force mode never bypasses it.
# DEVIATION (inventory pins :147-210: "a doc that quotes a .gcda path in prose
# must not fail the package — the predicate matches a standalone absolute
# path, not a mention inside a line"): the fish predicate was LINE-anchored
# over `strings` output (build-all.fish `pgo_payload_refusals`, `grep -E
# '^[^:]+: /…'`; lib/pgo.sh:124 `strings | grep -qE '^/…'`) — a path merely
# quoted mid-line was not a hit. The engine's predicate is WHITESPACE-TOKEN
# based (crates/gsa-recipe/src/pkginfo.rs `pgo_token_hit`; its own test pins
# `noise /build/pkg/src/x.gcda tail` as a hit), so any absolute
# `.gcda`/`.profraw` token anywhere in any member IS a hit — stricter,
# fail-closed. The `pgo-mention` case pins that engine truth (refused, row
# naming the doc member); if the predicate is ever aligned back to the fish
# line-anchored meaning, this fixture fails loudly and the deviation retires.
#
# Nothing here touches the real repository: the workspace is synthetic, under
# $TMPDIR, the state root is redirected under it, and the pacman/sudo stubs
# keep every transaction and escalation inside the fixture tree.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-pgo-payload.XXXXXX")
trap '/usr/bin/sudo -n rm -rf -- "$fixture" 2>/dev/null || rm -rf -- "$fixture" 2>/dev/null || true' EXIT

fail() {
    printf 'PGO payload guard fixture: %s\n' "$1" >&2
    exit 1
}

# ─── The engine under test: built into the fixture tree (scratch only).
# GSA_TEST_GSA_BIN, when already set to an executable, is that engine (the
# rr-v2.bash run_engine convention) and the scratch build is skipped. ──────
if [ -z "${GSA_TEST_GSA_BIN:-}" ]; then
    cargo build --offline --quiet --target-dir "$fixture/cargo" -p gsa-cli \
        --manifest-path "$gsa_repo_root/Cargo.toml" ||
        fail "cannot build the gsa binary for the fixture"
    GSA_TEST_GSA_BIN="$fixture/cargo/debug/gsa"
fi
[ -x "$GSA_TEST_GSA_BIN" ] || fail "the engine under test is not executable: $GSA_TEST_GSA_BIN"
export GSA_TEST_ENGINE=gsa
export GSA_TEST_GSA_BIN

make_workspace "$fixture" auto auto xhigh
make_install_conf "$fixture/pacman.conf" # this run's IgnorePkg registration target (--config; never the host's)
export GSA_STATE_DIR="$fixture/state"

# A recipe counts as PGO to the gate purely by naming an instrumenting flag,
# so the gate and the payload are varied independently.
add_recipe() {
    local id="$1" instrumenting="$2" extra
    case "$instrumenting" in
    yes)
        extra='pkgver=1.0
pkgrel=1
arch=(x86_64)
build() {
  CFLAGS+=" -fprofile-generate"
}' ;;
    rust)
        extra='pkgver=1.0
pkgrel=1
arch=(x86_64)
build() {
  RUSTFLAGS+=" -Cprofile-generate=$srcdir/pgo-data"
}' ;;
    *)
        extra='pkgver=1.0
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
# $4 no (default) | yes — stage the doc that QUOTES the leak path in prose
#                        (the DEVIATION witness; see the header)
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
    printf 'pkgname = %s\npkgver = 1.0\narch = x86_64\n' "$id" >"$stage/.PKGINFO"
    if [[ "${4:-no}" == yes ]]; then
        # A doc that *quotes* a .gcda path in prose. Fish installed this
        # ("a mere mention is not a leak", line-anchored predicate); the
        # engine's token predicate hits it (DEVIATION in the header).
        printf 'coverage notes: rebuild %s\n' "$leak" \
            >"$stage/usr/share/doc/$id/notes.txt"
    fi
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
add_recipe pgo-mention yes
add_recipe plain-bad no
add_recipe rust-bad rust
add_recipe rust-clean rust
add_archive pgo-bad usr/bin
add_archive deep-bad usr/libexec
add_archive pgo-clean ""
add_archive pgo-mention "" gcda yes
add_archive plain-bad usr/bin gcda yes
add_archive rust-bad usr/bin profraw
add_archive rust-clean ""

cat >"$fixture/bin/pacman" <<'EOF'
#!/usr/bin/env bash
printf 'pacman %s\n' "$*" >>"$GSA_FAKE_PACMAN_LOG"
EOF
chmod +x "$fixture/bin/pacman"

cat >"$fixture/bin/sudo" <<'EOF'
#!/usr/bin/env bash
# Run what it was given; leading sudo flags are dropped (including
# --preserve-env, which host fish `sudo` wrapper functions inject).
printf 'sudo %s\n' "$*" >>"$GSA_FAKE_SUDO_LOG"
while [[ ${1:-} == -* ]]; do
    shift
done
exec "$@"
EOF
chmod +x "$fixture/bin/sudo"

cat >"$fixture/bin/pacman-conf" <<'EOF'
#!/usr/bin/env bash
# The installed-DB probe answers the fixture's fabricated root, never the
# host's /var/lib/pacman (docs/NOTE.md: fixtures never read host state).
[ "${1:-}" = DBPath ] && printf '%s\n' "${GSA_FAKE_DB_PATH:?}"
exit 0
EOF
chmod +x "$fixture/bin/pacman-conf"
mkdir -p "$fixture/db"

: >"$fixture/pacman.log"
: >"$fixture/sudo.log"
export GSA_FAKE_PACMAN_LOG="$fixture/pacman.log"
export GSA_FAKE_SUDO_LOG="$fixture/sudo.log"
export GSA_FAKE_DB_PATH="$fixture/db"
export PATH="$fixture/bin:$PATH"
# Parallel-soundness: the payload scan must not leave temp state anywhere the
# shared battery $TMPDIR could observe. Give the runs a private $TMPDIR and
# count there — the assertion is unchanged and unambiguous.
export TMPDIR="$fixture/tmp"
mkdir -p "$TMPDIR"
temp_root="$TMPDIR"
leftovers_before=$(find "$temp_root" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l)

# status-returning wrapper over the helper's capture runner: the -Ua run
# (force mode; install every discovered archive in ONE transaction).
run_case() {
    run_engine "$fixture" -Ua --config "$fixture/pacman.conf"
    printf '%s\n' "$FIXTURE_OUTPUT"
    return "$FIXTURE_RC"
}

# seam_rows — the §E.2 decision rows for every archive still staged, straight
# from the hidden `--install-decide` seam (§D.1: prints rows, touches nothing).
seam_rows() {
    run_engine "$fixture" --install-decide checked $(find "$fixture/packages" -name '*.pkg.tar.zst' | sort)
    printf '%s\n' "$FIXTURE_OUTPUT"
    return "$FIXTURE_RC"
}

# $1 pkgbase, $2 member substring the refusal rows must name
refuses() {
    local id=$1 member=$2 output rows rc
    if output=$(seam_rows); then rc=0; else rc=$?; fi
    if [[ $rc != 1 ]]; then
        printf 'install seam for %s exited %s (want 1: a refuse row, §E.5):\n%s\n' "$id" "$rc" "$output" >&2
        exit 1
    fi
    rows=$output
    vgrep "$rows" -Eq "^$id refuse pgo-hit " ||
        { printf 'refusal rows for %s carry no pgo-hit row (§E.3):\n%s\n' "$id" "$rows" >&2; exit 1; }
    vgrep "$rows" -Eq "^$id refuse pgo-instrumented " ||
        { printf 'refusal rows for %s carry no pgo-instrumented row (§E.3):\n%s\n' "$id" "$rows" >&2; exit 1; }
    printf '%s\n' "$rows" | grep -F -- "$member" >/dev/null ||
        { printf 'refusal rows for %s did not name the member %s:\n%s\n' "$id" "$member" "$rows" >&2; exit 1; }

    : >"$fixture/pacman.log"
    : >"$fixture/sudo.log"
    cp "$fixture/pacman.conf" "$fixture/pacman.conf.pre"
    if output=$(run_case); then
        printf 'instrumented payload in %s was installed instead of refused:\n%s\n' \
            "$id" "$output" >&2
        exit 1
    fi
    vgrep "$output" -Eq "install-refused pgo-" ||
        { printf 'the -Ua run for %s did not carry install-refused pgo-* outcome rows:\n%s\n' "$id" "$output" >&2; exit 1; }
    printf '%s\n' "$output" | grep -F -- "$member" >/dev/null ||
        { printf 'the -Ua refusal for %s did not name %s:\n%s\n' "$id" "$member" "$output" >&2; exit 1; }
    if [[ -s "$fixture/pacman.log" ]]; then
        printf 'pacman ran even though %s failed the payload check:\n' "$id" >&2
        cat "$fixture/pacman.log" >&2
        exit 1
    fi
    if [[ -s "$fixture/sudo.log" ]]; then
        printf 'sudo ran even though %s failed the payload check:\n' "$id" >&2
        cat "$fixture/sudo.log" >&2
        exit 1
    fi
    cmp -s "$fixture/pacman.conf" "$fixture/pacman.conf.pre" ||
        { printf 'a refusing run for %s rewrote the IgnorePkg closure\n' "$id" >&2; exit 1; }
}

# ── Case A: an instrumented usr/bin payload is refused, and nothing installed
refuses pgo-bad 'usr/bin/pgo-bad'

# ── Case B: a leak under usr/libexec is refused too, not only usr/bin and usr/lib
rm -f "$(archive_of pgo-bad)"
refuses deep-bad 'usr/libexec/deep-bad-helper'

# ── Case D: a Rust -Cprofile-generate recipe with a baked .profraw destination
# is refused by name — the gate must match rustc's flag spelling and the
# LLVM runtime's file extension, not only C's -fprofile-generate/.gcda.
rm -f "$(archive_of deep-bad)"
refuses rust-bad 'usr/bin/rust-bad'

# ── Case E (DEVIATION witness): a doc that QUOTES a .gcda path in prose is a
# hit on the engine (token predicate) where fish installed it (line-anchored).
rm -f "$(archive_of rust-bad)"
refuses pgo-mention 'usr/share/doc/pgo-mention/notes.txt'

# ── Case C: clean PGO archives install, and the non-PGO one is not unrolled
rm -f "$(archive_of pgo-mention)"
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

# The check is read-only: it must not leave scratch state behind, and must not
# consume or rewrite the archive it inspected.
leftovers_after=$(find "$temp_root" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l)
if [[ "$leftovers_after" -ne "$leftovers_before" ]]; then
    printf 'the install pipeline left temp state behind (%s -> %s)\n' \
        "$leftovers_before" "$leftovers_after" >&2
    exit 1
fi
if [[ ! -s "$(archive_of pgo-clean)" ]]; then
    printf 'the payload check consumed the archive it inspected\n' >&2
    exit 1
fi

printf 'PGO payload guard fixture: PASS\n'
