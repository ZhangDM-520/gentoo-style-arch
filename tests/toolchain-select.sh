#!/usr/bin/env bash
set -euo pipefail

# Toolchain selection (contract §B.11): which compiler family a lane is
# configured for, and the rung that decided it.
#
# Pins (one behaviour per section):
#   A. nothing declared, nothing marked  -> gcc (the built-in default)
#   B. a PKGBUILD driver marker          -> clang (the PKGBUILD scan)
#   C. a topology `toolchain=` tag beats the scan          [tag > scan]
#   D. --toolchain beats the tag                           [flag > tag]
#   E. two families and no decision      -> the lane REFUSES (toolchain-ambiguous);
#      a guess here would configure half the build with the wrong flags
#   F. --toolchain <other> is a usage error naming both alternatives
#
# The resolved family and its rung are asserted on the LANE LOG line
# (`toolchain <family> (<source>)` in <state>/logs/<pkg>.log), which is the
# surface an operator reads when asking "why was that built with clang?".

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-toolchain.XXXXXX")
# The engine runs as root (a build run is privileged), so its state root is
# root-owned by design (§J.5): the scratch tree needs the same privilege to
# disappear.
trap '/usr/bin/sudo -n rm -rf -- "$fixture" 2>/dev/null || rm -rf -- "$fixture" 2>/dev/null || true' EXIT

fail() {
    printf 'toolchain-select: %s\n' "$1" >&2
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
        sed 's/^/    /' "$2" >&2
    fi
    exit 1
}

ws="$fixture/ws"
make_workspace "$ws" 1 1 low
stub_makepkg "$ws"
export PATH="$ws/bin:$PATH"

# The lane's per-package log the selection line lands in (the rr2 guard pins
# the state root beside the workspace).
lane_log() { printf '%s\n' "$ws/../.rr2-state/logs/$1.log"; }

# want_selection PKG FAMILY SOURCE — the lane recorded the expected decision.
want_selection() {
    local log
    log=$(lane_log "$1")
    [ -f "$log" ] || fail "no lane log for $1 at $log"
    grep -Fq "toolchain $2 ($3)" "$log" ||
        fail "$1: want 'toolchain $2 ($3)' in the lane log" "$log"
}

# ── A. the default ──────────────────────────────────────────────────────────
add_package "$ws" p1
run_engine "$ws" -B --leaf p1
[ "$FIXTURE_RC" -eq 0 ] || fail 'A: the plain build did not succeed'
want_selection p1 gcc 'the built-in default'

# ── B. the scan ─────────────────────────────────────────────────────────────
add_package "$ws" p2 'build() {
  CC=clang make
}'
run_engine "$ws" -B --leaf p2
[ "$FIXTURE_RC" -eq 0 ] || fail 'B: the clang build did not succeed'
want_selection p2 clang 'the PKGBUILD scan'

# A `clang` makedepend alone is NOT evidence: bindgen and BPF helpers need
# clang while the C/C++ build stays gcc.
add_package "$ws" p3 'makedepends=(clang)'
run_engine "$ws" -B --leaf p3
want_selection p3 gcc 'the built-in default'

# ── C. the tag beats the scan ───────────────────────────────────────────────
add_package "$ws" p4 'build() {
  CC=gcc make
}'
set_topology_record "$ws" p4 misc '' 'toolchain=clang'
run_engine "$ws" -B --leaf p4
[ "$FIXTURE_RC" -eq 0 ] || fail 'C: the tagged build did not succeed'
want_selection p4 clang 'the topology record'

# ── D. the flag beats the tag ───────────────────────────────────────────────
run_engine "$ws" -B --leaf --toolchain gcc p4
[ "$FIXTURE_RC" -eq 0 ] || fail 'D: --toolchain did not override the tag'
want_selection p4 gcc '--toolchain'

# ── E. two families, no decision: refuse, never guess ───────────────────────
add_package "$ws" p5 'prepare() {
  CC=clang ./configure
  CXX=g++ make
}'
run_engine "$ws" -B --leaf p5
[ "$FIXTURE_RC" -ne 0 ] || fail 'E: an ambiguous recipe built anyway'
# The lane owns the refusal prose (the supervisor reports the typed reason):
# read the per-package log, not the run's stdout.
p5_log=$(lane_log p5)
grep -Fq 'names both compilers' "$p5_log" ||
    fail 'E: the refusal does not name the ambiguity' "$p5_log"
grep -Fq 'CC=clang' "$p5_log" && grep -Fq 'CXX=g++' "$p5_log" ||
    fail 'E: the refusal does not name both markers' "$p5_log"
grep -Eq '^p5 failed [0-9]+ [0-9]+ toolchain-ambiguous$' <<<"$FIXTURE_OUTPUT" ||
    fail 'E: the outcome row does not carry toolchain-ambiguous'$'\n'"$FIXTURE_OUTPUT"
# A decision still wins: the same recipe under --toolchain builds.
run_engine "$ws" -B --leaf --toolchain clang p5
[ "$FIXTURE_RC" -eq 0 ] || fail 'E: --toolchain did not resolve the ambiguity'
want_selection p5 clang '--toolchain'

# ── F. a typo names both alternatives (usage class, rc 2) ───────────────────
run_engine "$ws" -B --leaf --toolchain icx p1
[ "$FIXTURE_RC" -eq 2 ] || fail "F: want rc 2 for a bad --toolchain, got $FIXTURE_RC"
grep -Fq "unknown toolchain 'icx'" <<<"$FIXTURE_OUTPUT" ||
    fail 'F: the refusal does not name the value:'$'\n'"$FIXTURE_OUTPUT"
grep -Fq 'gcc, clang' <<<"$FIXTURE_OUTPUT" ||
    fail 'F: the refusal does not name the alternatives:'$'\n'"$FIXTURE_OUTPUT"

# ── G. the marker's identity follows the family ─────────────────────────────
# `--build-identity` is the seam the drift gate and the fixtures share: the
# family prefix must match the config the lane was handed.
gcc_id=$("$GSA_TEST_GSA_BIN" --build-identity gcc)
clang_id=$("$GSA_TEST_GSA_BIN" --build-identity clang)
case $gcc_id in gcc\|*) ;; *) fail "G: gcc identity has the wrong family: $gcc_id" ;; esac
case $clang_id in clang\|*) ;; *) fail "G: clang identity has the wrong family: $clang_id" ;; esac
[[ $gcc_id != "$clang_id" ]] || fail 'G: both families produced one identity'

printf 'toolchain-select: PASS (default, scan, tag, flag, ambiguity refusal, typo)\n'
