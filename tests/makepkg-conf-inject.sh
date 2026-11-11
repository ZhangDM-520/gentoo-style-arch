#!/usr/bin/env bash
set -euo pipefail

# Engine-owned makepkg configuration (contract §B.11): every lane is handed
# `makepkg --config <generated composite>` and the host's makepkg.conf is
# never consulted.
#
# Pins (one behaviour per section):
#   A. the lane's argv carries `--config <build root>/lane-makepkg-gcc.conf`
#   B. the composite layers built-in universal + gcc bodies, then the site
#      file, then the engine-owned paths  (user over baseline, engine last)
#   C. no `/etc/makepkg.conf`, no drop-in glob, no `~/.makepkg.conf` anywhere
#   D. the `srcdest` key reaches the composite as an engine-owned path
#   E. a clang selection writes its OWN composite (no FFLAGS), while the
#      UNIVERSAL `RUSTFLAGS` rides both families (rustc is not a C family)
#      and carries the same `-fuse-ld=` as the family LDFLAGS — cargo never
#      reads LDFLAGS, so a Rust-only package would link with bfd
#   F. the composite EXPORTS `RUSTFLAGS`: a child process (cargo) sees it,
#      which makepkg's own buildenv list never does for that variable
#   G. each family's shipped CFLAGS/CXXFLAGS are accepted by that family's
#      compiler (GCC-only passes stay out of the clang body) and the
#      universal RUSTFLAGS by rustc — a missing compiler is a loud SKIP,
#      never a pass
#   H. `--print-conf <family>` is byte-identical to the body the composite
#      carries, which is what `gsa-pm` installs into `/etc/gsa`
#
# The makepkg stubs are oracle-shaped (they record their argv), so they stay
# inline in this fixture rather than becoming a shared helper.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-mkconf.XXXXXX")
trap '/usr/bin/sudo -n rm -rf -- "$fixture" 2>/dev/null || rm -rf -- "$fixture" 2>/dev/null || true' EXIT

fail() {
    printf 'makepkg-conf-inject: %s\n' "$1" >&2
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
        sed 's/^/    /' "$2" >&2
    fi
    exit 1
}

ws="$fixture/ws"
conf_dir="$ws/../.rr2-conf"
# rr2 only guards GSA_BUILD_DIR when the caller did not pin one — the battery
# pins one PER FIXTURE (tests/run-all.sh), so the root under test is whatever
# this run resolved, not a fixture-local guess.
build_conf="${GSA_BUILD_DIR:-$ws/../.rr2-build}"
make_workspace "$ws" 1 1 low

# The recording makepkg: logs argv and the environment knobs the composite
# re-asserts, then produces the archive the run expects.
cat >"$ws/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -eu
id=$(basename "$PWD")
printf 'argv %s\n' "$*" >>"${GSA_FAKE_MKCONF_LOG:?}"
printf 'lanebuilddir %s\n' "${GSA_LANE_BUILDDIR:-}" >>"$GSA_FAKE_MKCONF_LOG"
printf 'lanesrcdest %s\n' "${GSA_LANE_SRCDEST:-}" >>"$GSA_FAKE_MKCONF_LOG"
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
exit 0
EOF
chmod +x "$ws/bin/makepkg"
export PATH="$ws/bin:$PATH"
export GSA_FAKE_MKCONF_LOG="$fixture/makepkg.log"

# A site file the composite must source (the baseline half of "user over
# baseline"); the fixture's conf dir IS the baseline here, since
# GSA_CONF_DIR collapses the resolution to one directory.
printf '# site tuning\nOPTIONS+=(nostrip)\n' >"$conf_dir/gcc-makepkg.conf"
printf 'srcdest = %s\n' "$fixture/srcdest" >>"$conf_dir/gsa.conf"
mkdir -p "$fixture/srcdest"

add_package "$ws" p1
run_engine "$ws" -B --leaf p1
[ "$FIXTURE_RC" -eq 0 ] || fail 'A: the build did not succeed:'$'\n'"$FIXTURE_OUTPUT"

# ── A. the lane was handed --config ─────────────────────────────────────────
grep -Eq -- "--config [^ ]*/lane-makepkg-gcc\.conf" "$GSA_FAKE_MKCONF_LOG" ||
    fail 'A: makepkg argv carries no --config lane-makepkg-gcc.conf' "$GSA_FAKE_MKCONF_LOG"

composite="$build_conf/lane-makepkg-gcc.conf"
[ -f "$composite" ] || fail "A: the composite is missing at $composite"

# ── B. the layering order ───────────────────────────────────────────────────
universal=$(grep -n 'gsa universal makepkg settings' "$composite" | cut -d: -f1)
gcc_body=$(grep -n 'gsa gcc makepkg settings' "$composite" | cut -d: -f1)
site=$(grep -n "$conf_dir/gcc-makepkg.conf" "$composite" | cut -d: -f1)
paths=$(grep -n 'BUILDDIR="\${GSA_LANE_BUILDDIR' "$composite" | cut -d: -f1)
[ -n "$universal" ] && [ -n "$gcc_body" ] && [ -n "$site" ] && [ -n "$paths" ] ||
    fail 'B: the composite is missing one of universal/gcc/site/paths' "$composite"
[ "$universal" -lt "$gcc_body" ] || fail 'B: the compiler body must follow the universal body' "$composite"
[ "$gcc_body" -lt "$site" ] || fail 'B: the site file must override the built-ins' "$composite"
[ "$site" -lt "$paths" ] || fail 'B: the engine-owned paths must be re-asserted LAST' "$composite"
# PKGEXT is part of the engine's discovery/index contract, so the LAST
# assignment must be the engine's: a site body that changed it built an
# archive nothing could find and every later `-S` refused on an empty list
# (blind-review 2026-11-11, embedded-cross-compiler F11).
pkgext=$(grep -n "^PKGEXT='\.pkg\.tar\.zst'$" "$composite" | tail -n 1 | cut -d: -f1)
[ -n "$pkgext" ] && [ "$site" -lt "$pkgext" ] ||
    fail 'B: the engine must re-assert PKGEXT after the site file' "$composite"
# The site file is SOURCED, not inlined: its content stays the operator's
# (one file, one owner), and the guard makes a missing file a no-op.
grep -Fq "source '$conf_dir/gcc-makepkg.conf'" "$composite" ||
    fail 'B: the site file is not sourced by the composite' "$composite"

# ── C. the host config is never sourced ─────────────────────────────────────
for token in /etc/makepkg.conf makepkg.conf.d '.makepkg.conf' gsa.conf; do
    if grep -Fq "$token" "$composite"; then
        fail "C: the composite references '$token' (the host config or the engine key file)" "$composite"
    fi
done

# ── D. the engine owns the paths ────────────────────────────────────────────
for token in GSA_LANE_BUILDDIR GSA_LANE_PKGDIR GSA_LANE_PKGDEST GSA_LANE_SRCDEST; do
    grep -Fq "$token" "$composite" || fail "D: the composite does not re-assert $token" "$composite"
done
grep -Fq "lanesrcdest $fixture/srcdest" "$GSA_FAKE_MKCONF_LOG" ||
    fail 'D: the srcdest key did not reach the lane environment' "$GSA_FAKE_MKCONF_LOG"

# ── E. a clang lane gets its own composite ──────────────────────────────────
add_package "$ws" p2 'build() {
  CC=clang make
}'
run_engine "$ws" -B --leaf p2
[ "$FIXTURE_RC" -eq 0 ] || fail 'E: the clang build did not succeed:'$'\n'"$FIXTURE_OUTPUT"
clang_composite="$build_conf/lane-makepkg-clang.conf"
[ -f "$clang_composite" ] || fail "E: the clang composite is missing at $clang_composite"
# RUSTFLAGS is UNIVERSAL (rustc's target is not a gcc/clang choice), so both
# composites carry the same native value, and the `-C link-arg` names the same
# linker the family LDFLAGS ships — cargo ignores LDFLAGS entirely.
for c in "$composite" "$clang_composite"; do
    grep -Fq 'RUSTFLAGS="-C opt-level=3 -C target-cpu=native -C link-arg=-fuse-ld=mold"' "$c" ||
        fail "E: $c lost the universal native/mold RUSTFLAGS" "$c"
    grep -Fq -- '-march=native -mtune=native' "$c" ||
        fail "E: $c does not ship a native -march/-mtune" "$c"
done
# …while the Fortran half stays gcc's alone and the GCC-only passes stay out
# of the clang body (clang hard-rejects them).
grep -Fq 'FFLAGS=' "$clang_composite" && fail 'E: the clang composite carries gcc FFLAGS' "$clang_composite"
grep -Fq 'FFLAGS=' "$composite" || fail 'E: the gcc composite lost FFLAGS' "$composite"
for gcc_only in -fipa-pta -fprefetch-loop-arrays -fira-hoist-pressure -fstack-reuse; do
    grep -Fq -- "$gcc_only" "$clang_composite" && fail "E: the clang composite carries $gcc_only" "$clang_composite"
done
grep -Fq -- '-fipa-pta' "$composite" || fail 'E: the gcc composite lost -fipa-pta' "$composite"
grep -Fq "lanesrcdest $fixture/srcdest" "$GSA_FAKE_MKCONF_LOG" ||
    fail 'E: the fetch/lane environment lost the source cache' "$GSA_FAKE_MKCONF_LOG"

# ── F. the composite exports RUSTFLAGS ──────────────────────────────────────
# Sourcing the composite is exactly what makepkg does; the question is
# whether a CHILD process sees the value (makepkg exports only its buildenv
# list, so without the `export` line cargo keeps its generic target).
child_env=$(env -u RUSTFLAGS bash --noprofile --norc -c '
  set +u
  source "$1" >/dev/null 2>&1
  env | grep "^RUSTFLAGS=" || true
' _ "$composite")
vgrep "$child_env" -Fq 'target-cpu=native' ||
    fail 'F: a child process does not inherit RUSTFLAGS from the composite:'$'\n'"$child_env"
vgrep "$child_env" -Fq -- '-C link-arg=-fuse-ld=mold' ||
    fail 'F: the child process RUSTFLAGS lost the mold link arg:'$'\n'"$child_env"

# ── F'. the composite exports NINJAFLAGS, the lane job count's other home ───
# `ninja`, `cmake --build` and `meson compile` read the job count from the
# environment; makepkg exports only its buildenv list, so a plain assignment
# bound `make` and left every other build system at its default (blind
# review, 2026-11-11).
ninja_env=$(GSA_LANE_NINJAFLAGS=-j7 bash --noprofile --norc -c '
  set +u
  source "$1" >/dev/null 2>&1
  env | grep "^NINJAFLAGS=" || true
' _ "$composite")
vgrep "$ninja_env" -Fq 'NINJAFLAGS=-j7' ||
    fail "F': a child process does not inherit NINJAFLAGS from the composite:"$'\n'"$ninja_env"

# ── F''. a site file that is not valid shell is a REFUSAL, not a degraded build ─
# The composite used to source site files inside a `[ -r ] &&` chain: a syntax
# error aborted only that file, the lane built with the floor body, and the run
# reported success — a silently different build behind a green record (blind
# review, 2026-11-11). The identity's `bash -n` check refuses first.
bad_conf="$fixture/bad-site"
mkdir -p "$bad_conf"
printf 'CFLAGS="unterminated\n' >"$bad_conf/gcc-makepkg.conf"
set +e
bad_out=$(GSA_CONF_DIR="$bad_conf" "$GSA_TEST_GSA_BIN" --build-identity gcc 2>&1)
bad_rc=$?
set -e
[ "$bad_rc" -ne 0 ] \
    || fail "F'': --build-identity accepted a site body it cannot source (rc=$bad_rc): $bad_out"
grep -Fq 'is not valid shell' <<<"$bad_out" \
    || fail "F'': the refusal does not name the invalid site body: $bad_out"
grep -Fq "$bad_conf/gcc-makepkg.conf" <<<"$bad_out" \
    || fail "F'': the refusal does not name the file: $bad_out"

# ── G. each family's flags are accepted by that family's compiler ───────────
# The bodies are shipped text, so the only proof that clang will not choke on
# the clang composite (or gcc on the gcc one) is to hand them to the driver.
# Absent compiler = loud SKIP: the battery must never pass by not checking.
compile_probe() {
    local compiler=$1 lang=$2 composite_file=$3
    if ! command -v "$compiler" >/dev/null 2>&1; then
        printf 'makepkg-conf-inject: SKIP section G for %s (compiler not installed)\n' "$compiler" >&2
        return 0
    fi
    local flags
    flags=$(bash --noprofile --norc -c '
      set +u
      source "$1" >/dev/null 2>&1
      if [ "$2" = c++ ]; then printf %s "${CXXFLAGS:-}"; else printf %s "${CFLAGS:-}"; fi
    ' _ "$composite_file" "$lang")
    [ -n "$flags" ] || fail "G: $compiler composite sets no $lang flags" "$composite_file"
    # Word-splitting is the point: the flags are a shell-assigned list.
    # shellcheck disable=SC2086
    printf 'int main(void){return 0;}\n' |
        "$compiler" -x "$lang" -fsyntax-only -Werror $flags - 2>"$fixture/g.log" ||
        fail "G: $compiler rejects its own shipped $lang flags:"$'\n'"$(cat "$fixture/g.log")"
}
compile_probe gcc c "$composite"
compile_probe gcc c++ "$composite"
compile_probe clang c "$clang_composite"
compile_probe clang c++ "$clang_composite"

# The universal body also names a Rust LINK argument, which only a real link
# can prove: rustc accepts any `-C link-arg` string, and a driver that cannot
# run the named linker fails at the end. Absent rustc or mold is a loud SKIP,
# because the same host could not build a Rust package at all.
if ! command -v rustc >/dev/null 2>&1; then
    printf 'makepkg-conf-inject: SKIP section G for rustc (rustc not installed)\n' >&2
elif ! command -v mold >/dev/null 2>&1; then
    printf 'makepkg-conf-inject: SKIP section G for rustc (mold not installed)\n' >&2
else
    rustflags=$(bash --noprofile --norc -c '
      set +u
      source "$1" >/dev/null 2>&1
      printf %s "${RUSTFLAGS:-}"
    ' _ "$composite")
    [ -n "$rustflags" ] || fail 'G: the composite sets no RUSTFLAGS' "$composite"
    printf 'fn main() {}\n' >"$fixture/g.rs"
    # Word-splitting is the point: the flags are a shell-assigned list.
    # shellcheck disable=SC2086
    rustc --edition 2021 -o "$fixture/g-rust" $rustflags "$fixture/g.rs" 2>"$fixture/g-rust.log" ||
        fail 'G: rustc rejects its own shipped RUSTFLAGS:'$'\n'"$(cat "$fixture/g-rust.log")"
fi

# ── H. --print-conf IS the body the composite carries ───────────────────────
for family in gcc clang; do
    composite_file="$composite"
    [ "$family" = clang ] && composite_file="$clang_composite"
    run_engine "$ws" --print-conf "$family"
    [ "$FIXTURE_RC" -eq 0 ] || fail "H: --print-conf $family failed:"$'\n'"$FIXTURE_OUTPUT"
    printed="$fixture/print-$family.conf"
    printf '%s\n' "$FIXTURE_OUTPUT" >"$printed"
    # The composite embeds the body verbatim, so the printed lines must appear
    # there as one contiguous block starting at the body's own header — that is
    # what makes `/etc/gsa/<family>-makepkg.conf` the binary's own text rather
    # than a copy that can drift.
    header=$(head -n 1 "$printed")
    n=$(wc -l <"$printed")
    start=$(grep -nFx -- "$header" "$composite_file" | head -n 1 | cut -d: -f1)
    [ -n "$start" ] || fail "H: the $family body header is not in the composite" "$composite_file"
    sed -n "${start},$((start + n - 1))p" "$composite_file" >"$fixture/embed-$family.conf"
    diff -u "$printed" "$fixture/embed-$family.conf" ||
        fail "H: --print-conf $family differs from the embedded body" "$printed"
done

printf 'makepkg-conf-inject: PASS (argv, layering, no host config, engine paths, per-family files, exported RUSTFLAGS, compiler acceptance, --print-conf)\n'
