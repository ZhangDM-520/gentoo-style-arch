#!/usr/bin/env bash
set -euo pipefail

# tests/toolchain-drift.sh — the GCC build-identity drift gate
# (crates/gsa-recipe/src/toolchain.rs: gcc_identity/check_identity/write_marker/
# clean_targets, docs/gsa-contract.md §J.1), driven through the NATIVE engine
# (`gsa -B`). Synthetic $TMPDIR workspaces with stub `gcc`/`makepkg`/`pacman`:
# no package is built, no pacman transaction runs, nothing outside the fixture
# tree is written and no host toolchain is touched — the rustc sanity probe is
# kept off the host by the pacman stub answering "rust-git absent"
# (`pacman -Q …` → 1), so the probe skips before it ever resolves `rustc`.
#
# The gate contract pinned here (docs/build-guide.md "Skip and resume"):
#   * per-recipe marker `<state-dir>/toolchains/<id>`; missing or changed ⇒
#     ONE-TIME CLEAN (recipe `src/`, `pkg/`, `build/` trees + built archives +
#     `*.gsa-vcs-revisions` VCS baselines) and rebuild EVEN under --skip, with
#     the drift message naming the previous and current identity;
#   * the marker is written ONLY after a successful build AND its VCS revision
#     baselines were recorded (`record_vcs_archive_revisions` per archive
#     first): a FAILED build — or a build whose baseline recording fails —
#     leaves the previous marker (or none), so the retry drifts and re-cleans;
#   * an unchanged identity keeps its cached tree and archive and skips.
#
# Flip notes (docs/gsa-fixture-migration.md row `tests/toolchain-drift.sh`):
# the fish argv `fish build-all.fish --allow-broken-rustc --no-deps --no-sync`
# becomes `gsa -B --leaf --no-sync` (§B.8; the inventory row's `-S` spelling is
# a doc slip — these runs are build-only). `--allow-broken-rustc` drops: the
# probe never engages. Fish `-s` becomes `--skip`. The fish `-Qp`-only pacman
# stub keeps its contract (the freshness payload gate still shells `pacman
# -Qp`). The scenario prose pins re-pin to the merged FIXTURE_OUTPUT (the
# gate's policy/prose rides the run's STDERR; the stub makepkg's own markers
# ride the per-package lane log the summary names — asserted there), and every
# run gains `format: 2`
# run-record pins (§H.2–§H.3 via tests/lib/rr-v2.bash: order covers exactly the
# plan/outcome subjects, and row rc follows the §H.3 status table). Two
# scenarios GAIN coverage the fish fixture could not express: the clean targets
# as DATA (trees + archives + `.gsa-vcs-revisions`) and the baseline-before-
# marker ordering (a build whose VCS baseline recording fails writes no
# marker). `--no-prefetch` keeps the runs hermetic: no fetch-ahead child may
# ever touch stub sources.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"

fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-toolchain-drift.XXXXXX")
trap '/usr/bin/sudo -n rm -rf -- "$fixture" 2>/dev/null || rm -rf -- "$fixture" 2>/dev/null || true' EXIT

fail() {
    printf 'toolchain drift fixture: %s\n' "$1" >&2
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
        sed 's/^/    /' "$2" >&2
    fi
    exit 1
}

# ─── Stub-knob vocabulary (§D.2: declared in the change that adds them) ─────
rr2_stub_knob GSA_FAKE_GCC_VERSION "toolchain-drift gcc stub: reported compiler identity"
rr2_stub_knob GSA_FAKE_MAKEPKG_COUNT "install-archive-guard makepkg stub: invocation counter"
rr2_stub_knob GSA_FAKE_FAIL_PACKAGE "trivial makepkg stub: package id whose build must fail"
rr2_stub_knob GSA_FAKE_CHECKOUT_MODE "toolchain-drift makepkg stub: shape of the fabricated \$srcdir checkout for p2-src (git|plain)"

# ─── The engine under test: scratch build only when GSA_TEST_GSA_BIN is not
# already set (the rr-v2.bash run_engine convention) ──────────────────────
if [ -z "${GSA_TEST_GSA_BIN:-}" ]; then
    cargo build --offline --quiet --target-dir "$fixture/cargo" -p gsa-cli \
        --manifest-path "$gsa_repo_root/Cargo.toml" \
        || fail "cannot build the gsa binary for the fixture"
    GSA_TEST_GSA_BIN="$fixture/cargo/debug/gsa"
fi
gsa_bin="$GSA_TEST_GSA_BIN"
[ -x "$gsa_bin" ] || fail "cargo did not produce $gsa_bin"
export GSA_TEST_ENGINE=gsa
export GSA_TEST_GSA_BIN="$gsa_bin"

# ─── The workspace: p1 (no VCS sources, the fish scenario carrier) and p2
# (one VCS source whose baseline recording is exercised end to end) ──────────
ws="$fixture/workspace"
make_workspace "$ws" 1 2 low
add_package "$ws" p1 "$gsa_meta_any"
add_package "$ws" p2 \
    "${gsa_meta_any}"$'\nsource=(p2-src::git+file://'"$fixture"'/remote/p2-src.git)'

# The toolchain probe's toolchain is stubbed away; the drift identity is the
# gcc stub's `--version` first line (toolchain.rs: gcc_identity).
cat >"$ws/bin/gcc" <<'EOF'
#!/usr/bin/env bash
set -u
[[ ${1:-} == --version ]] || exit 2
printf 'gcc (fixture) %s\n' "${GSA_FAKE_GCC_VERSION:?}"
EOF
chmod +x "$ws/bin/gcc"

# The scenario makepkg: the invocation counter, the stale-LTO guard (a drift
# clean that runs AFTER makepkg leaves `src/stale-lto.o` behind and the build
# refuses with 92), the simulated partial failure, and the fabrication of the
# `$srcdir` checkout the VCS baseline recorder reads; the archive is a real
# minimal zstd package so the engine's `.PKGINFO`-truth discovery sees it.
cat >"$ws/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -eu
id=$(basename "$PWD")
printf 'run\n' >>"${GSA_FAKE_MAKEPKG_COUNT:?}"
mkdir -p "$PWD/src"
if [[ -e "$PWD/src/stale-lto.o" ]]; then
    printf 'stale LTO object survived the compiler-drift clean\n' >&2
    exit 92
fi
if [[ "${GSA_FAKE_FAIL_PACKAGE:-}" == "$id" ]]; then
    : >"$PWD/src/stale-lto.o"
    printf 'simulated makepkg failure after partial compilation\n' >&2
    exit 1
fi
if [[ -n "${GSA_FAKE_CHECKOUT_MODE:-}" ]]; then
    mkdir -p "$PWD/src/p2-src"
    case "$GSA_FAKE_CHECKOUT_MODE" in
    git)
        GIT_CONFIG_COUNT=0 git -C "$PWD/src/p2-src" init -q
        GIT_CONFIG_COUNT=0 git -C "$PWD/src/p2-src" \
            -c user.name=fixture -c user.email=fixture@invalid \
            commit -q --allow-empty -m fixture
        ;;
    plain)
        # Not a git checkout: the baseline's `git rev-parse` must fail closed.
        printf 'not a gitfile\n' >"$PWD/src/p2-src/.git"
        ;;
    *)
        printf 'unknown GSA_FAKE_CHECKOUT_MODE %s\n' "$GSA_FAKE_CHECKOUT_MODE" >&2
        exit 93
        ;;
    esac
fi
: >"$PWD/src/fresh-lto.o"
# A real (minimal) package archive: the engine discovers built archives by
# their `.PKGINFO` truth (gsa-install discover_recipe), and the VCS baseline
# recorder binds to the archive it discovers — a bare touch file registers
# zero archives and would vacuously pass the baseline-before-marker gate.
mkdir -p "$PWD/src/pkgroot"
printf 'pkgname = %s\npkgver = 1.0.0-1\narch = any\n' "$id" \
    >"$PWD/src/pkgroot/.PKGINFO"
tar -C "$PWD/src/pkgroot" -cf "$PWD/src/pkg.tar" .PKGINFO
zstd -q -f -o "$PWD/$id-1.0.0-1-any.pkg.tar.zst" "$PWD/src/pkg.tar"
rm -rf "$PWD/src/pkgroot" "$PWD/src/pkg.tar"
EOF
chmod +x "$ws/bin/makepkg"

cat >"$ws/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -u
# The skip gate payload-probes archives with `pacman -Qp`; this scenario tests
# compiler-drift cleaning, not archive integrity, so the probe answers
# "readable". `pacman -Q rust-git` answering absent keeps the rustc sanity
# probe off the host toolchain (it must skip, never run the host rustc).
# Anything else is unexpected on this path and fails closed.
case "${1:-}" in
    -Qp) exit 0 ;;
esac
exit 1
EOF
chmod +x "$ws/bin/pacman"

# ENGINE DEFECT ISOLATION (recorded in the flip report; this fixture asserts
# no index behaviour): the binpkg-index retention sweep of `register_instance`
# (crates/gsa-state/src/index.rs — "retention pruned … (archive)") deletes the
# pruned instance's archive PATH without checking whether a KEPT row still
# references it, and a same-version rebuild's instances share ONE path
# (PKGDEST=$startdir). Measured repro: two consecutive `gsa -B` runs of one
# package end with NO archive ("retention pruned p1 instance 1
# (p1-1.0.0-1-any.pkg.tar.zst)" deletes the file instance 2 just registered),
# which starves a later --skip claim AND runs before the post-build VCS
# baseline step, so a rebuild's baseline cannot fingerprint its archive and
# the toolchain marker never advances. Pre-creating the index store as a
# directory disables the registration (its read path is best-effort — "ABI
# wave check skipped" — and a failing registration is a note, never a run
# failure), keeping the drift-gate subject — the baselines-then-marker half of
# the hook is the production path — under test instead of the sweep. Drop this
# when the sweep stops deleting paths that kept rows still reference.
mkdir -p "$ws/state/index/binpkg.jsonl"

export PATH="$ws/bin:$PATH"
export GSA_FAKE_MAKEPKG_COUNT="$fixture/makepkg.count"

# ─── Driver: one build-only run per case, output merged into FIXTURE_OUTPUT
# and archived per case for failure dumps (prose lives on STDERR) ────────────
run_case() { # $1 = case label, $2 = gcc identity line; rest = extra gsa args
    local label=$1 identity=$2
    shift 2
    export GSA_FAKE_GCC_VERSION="$identity"
    run_engine "$ws" -B --leaf --no-sync --no-prefetch --state-dir "$ws/state" "$@"
    printf '%s\n' "$FIXTURE_OUTPUT" >"$fixture/out-$label.txt"
    return 0
}

makepkg_runs() {
    grep -c '^run$' "$fixture/makepkg.count" 2>/dev/null || true
}

# ─── Run-record pins (§H.2–§H.3): every run emits exactly one complete
# format: 2 block, `order:` covers exactly the plan/outcome subjects, and
# every row's rc is the §H.3 lane code for its status ────────────────────────
assert_record() { # $1 = case label, $2 = expected order scalar
    local out="$fixture/out-$1.txt" order plan outcome
    rr2_body <"$out" >/dev/null \
        || fail "$1: no complete format: 2 run record:" "$out"
    [ "$(rr2_scalar order <"$out")" = "$2" ] \
        || fail "$1: order is not exactly [$2]:" "$out"
    order=$(rr2_scalar order <"$out" | tr ' ' '\n' | sed '/^$/d' | sort | tr '\n' ' ')
    plan=$(rr2_plan_rows <"$out" | awk '{print $1}' | sort | tr '\n' ' ')
    outcome=$(rr2_outcome_rows <"$out" | awk '{print $1}' | sort | tr '\n' ' ')
    [ "$order" = "$plan" ] \
        || fail "$1: order [$order] does not cover exactly the plan subjects [$plan]:" "$out"
    [ "$order" = "$outcome" ] \
        || fail "$1: order [$order] does not cover exactly the outcome subjects [$outcome]:" "$out"
    local pkg status rc dur reason
    while read -r pkg status rc dur reason; do
        case "$status:$rc" in
        succeeded:0 | succeeded:- | \
        failed:1 | failed:125 | failed:- | \
        deferred:99 | \
        parked:98 | parked:- | \
        never-started:- | \
        interrupted:129 | interrupted:130 | interrupted:143 | interrupted:-) ;;
        *) fail "$1: row '$pkg $status $rc $dur $reason' breaks the §H.3 status/rc rules:" "$out" ;;
        esac
    done < <(rr2_outcome_rows <"$out")
    [ "$FIXTURE_RC" = "$(rr2_scalar rc <"$out")" ] \
        || fail "$1: process exit $FIXTURE_RC disagrees with the record's rc scalar:" "$out"
}

assert_row() { # $1 = label, $2 = pkg, $3 = status, $4 = rc (a skipped
    # package never runs a lane, so its row carries rc `-`; a built one 0;
    # a failed one the lane's 1); plan checked by caller
    local out="$fixture/out-$1.txt"
    [ "$(rr2_outcome "$2" status <"$out")" = "$3" ] \
        || fail "$1: $2 outcome status is not $3:" "$out"
    [ "$(rr2_outcome "$2" rc <"$out")" = "$4" ] \
        || fail "$1: $2 outcome rc is not $4:" "$out"
}

assert_plan() { # $1 = label, $2 = pkg, $3 = plan action
    local out="$fixture/out-$1.txt"
    [ "$(rr2_plan "$2" plan <"$out")" = "$3" ] \
        || fail "$1: $2 plan row is not '$3' (the drift gate must decide before --skip):" "$out"
}

assert_no_clean_message() { # $1 = label — an unchanged identity must not clean
    if grep -Fq 'cleaning cached build artifacts' "$fixture/out-$1.txt"; then
        fail "$1: an unchanged compiler identity must not clean cached artifacts:" \
            "$fixture/out-$1.txt"
    fi
}

assert_msg() { # $1 = label, $2 = required message (substring, prefix-agnostic)
    grep -Fq -- "$2" "$fixture/out-$1.txt" \
        || fail "$1: missing message '$2':" "$fixture/out-$1.txt"
}

# The stub makepkg's own markers are lane-child output: the engine routes
# them to the per-package log ($state/logs/<pkg>.log), not the console, so
# these pins read the log the run record's summary names. Only the ENGINE's
# policy/prose (the drift messages) is pinned to the merged FIXTURE_OUTPUT.
assert_pkg_log() { # $1 = label, $2 = pkg, $3 = required message (substring)
    local log="$ws/state/logs/$2.log"
    [ -f "$log" ] || fail "$1: no per-package log $log:" "$fixture/out-$1.txt"
    grep -Fq -- "$3" "$log"         || fail "$1: missing message '$3' in $log:" "$fixture/out-$1.txt"
}

assert_no_pkg_log() { # $1 = label, $2 = pkg, $3 = forbidden message (substring)
    local log="$ws/state/logs/$2.log"
    if [ -f "$log" ] && grep -Fq -- "$3" "$log"; then
        fail "$1: forbidden message '$3' in $log:" "$fixture/out-$1.txt"
    fi
}

marker_p1="$ws/state/toolchains/p1"
marker_p2="$ws/state/toolchains/p2"
# The stub reports the bare version; the identity line gcc_identity records is
# the stub's FIRST --version line, prefix included.
VERSION_A='17.0.0 20260906'
VERSION_B='17.0.0 20260920'
IDENT_A="gcc (fixture) $VERSION_A"
IDENT_B="gcc (fixture) $VERSION_B"

assert_marker() { # $1 = marker path, $2 = expected identity line
    [ -f "$1" ] || fail "marker $1 was not written after the successful build"
    [ "$(cat "$1")" = "$2" ] \
        || fail "marker $1 holds '$(cat "$1")', want '$2'"
}

assert_no_marker() { # $1 = marker path
    [ ! -e "$1" ] || fail "marker $1 exists although its VCS baselines never recorded"
}

sidecar_p2="$ws/packages/p2/p2-1.0.0-1-any.pkg.tar.zst.gsa-vcs-revisions"

# ─── 1. One-time clean of a MISSING marker, then the initial build ──────────
# Seed every clean-target class the drift clean owns: the three trees, a stale
# archive and a stale VCS baseline sidecar. The makepkg stale-LTO guard proves
# the clean ran BEFORE the rebuild; the post-run checks prove the DATA targets
# are gone.
mkdir -p "$ws/packages/p1/src" "$ws/packages/p1/pkg" "$ws/packages/p1/build"
: >"$ws/packages/p1/src/stale-lto.o"
: >"$ws/packages/p1/pkg/stale-pkg.o"
: >"$ws/packages/p1/build/stale-build.o"
: >"$ws/packages/p1/p1-0.9.0-1-any.pkg.tar.zst"
printf 'gsa-vcs-revisions\t2\n' \
    >"$ws/packages/p1/p1-0.9.0-1-any.pkg.tar.zst.gsa-vcs-revisions"

run_case one-time-clean "$VERSION_A" p1
if [ "$FIXTURE_RC" != 0 ]; then
    fail "initial build failed:" "$fixture/out-one-time-clean.txt"
fi
assert_msg one-time-clean 'GCC build identity missing; cleaning cached build artifacts (one-time clean)'
assert_record one-time-clean p1
assert_plan one-time-clean p1 build
assert_row one-time-clean p1 succeeded 0
[ "$(makepkg_runs)" = 1 ] || fail "initial build did not run makepkg exactly once:" "$fixture/out-one-time-clean.txt"
for stale in \
    "$ws/packages/p1/src/stale-lto.o" \
    "$ws/packages/p1/pkg" \
    "$ws/packages/p1/build" \
    "$ws/packages/p1/p1-0.9.0-1-any.pkg.tar.zst" \
    "$ws/packages/p1/p1-0.9.0-1-any.pkg.tar.zst.gsa-vcs-revisions"; do
    [ ! -e "$stale" ] || fail "one-time clean left clean-target $stale behind:" \
        "$fixture/out-one-time-clean.txt"
done
[ -f "$ws/packages/p1/src/fresh-lto.o" ] \
    || fail "the initial build produced no fresh build tree:" "$fixture/out-one-time-clean.txt"
assert_marker "$marker_p1" "$IDENT_A"

# ─── 2. Unchanged identity under --skip: skip, keep the tree and archive ────
: >"$ws/packages/p1/src/stale-lto.o"
run_case same-skip "$VERSION_A" --skip p1
if [ "$FIXTURE_RC" != 0 ]; then
    fail "same-toolchain skip failed:" "$fixture/out-same-skip.txt"
fi
assert_record same-skip p1
assert_plan same-skip p1 skip
assert_row same-skip p1 succeeded -
assert_no_clean_message same-skip
[ "$(makepkg_runs)" = 1 ] \
    || fail "same-toolchain run did not skip while preserving its build tree:" "$fixture/out-same-skip.txt"
[ -e "$ws/packages/p1/src/stale-lto.o" ] \
    || fail "an unchanged identity must preserve the completed build tree:" "$fixture/out-same-skip.txt"
assert_marker "$marker_p1" "$IDENT_A"

# ─── 3. Drift overrides --skip and cleans before makepkg. The build FAILS
# after partial compilation: the new identity must NOT be committed, so the
# retry below drifts again and re-cleans (the caller contract) ──────────────
export GSA_FAKE_FAIL_PACKAGE=p1
run_case drift-fail "$VERSION_B" --skip p1
unset GSA_FAKE_FAIL_PACKAGE
if [ "$FIXTURE_RC" = 0 ]; then
    fail "compiler drift was ignored by --skip:" "$fixture/out-drift-fail.txt"
fi
assert_msg drift-fail 'GCC build identity missing or changed; cleaning cached build artifacts (previous: gcc (fixture) 17.0.0 20260906; current: gcc (fixture) 17.0.0 20260920)'
assert_record drift-fail p1
assert_plan drift-fail p1 build
assert_row drift-fail p1 failed 1
[ "$FIXTURE_RC" = 4 ] \
    || fail "a cone-stop run with one failed row exits §G.1's 4, got $FIXTURE_RC:" "$fixture/out-drift-fail.txt"
assert_no_pkg_log drift-fail p1 'stale LTO object survived'
assert_pkg_log drift-fail p1 'simulated makepkg failure after partial compilation'
[ "$(makepkg_runs)" = 2 ] \
    || fail "the drift build did not dispatch makepkg:" "$fixture/out-drift-fail.txt"
assert_marker "$marker_p1" "$IDENT_A"

# ─── 4. The retry drifts AGAIN (the failed attempt left the old marker), so
# it cleans the failed attempt's partial tree and rebuilds ──────────────────
run_case drift-retry "$VERSION_B" --skip p1
if [ "$FIXTURE_RC" != 0 ]; then
    fail "retry after the failed drift build did not clean and rebuild:" "$fixture/out-drift-retry.txt"
fi
assert_msg drift-retry 'GCC build identity missing or changed; cleaning cached build artifacts (previous: gcc (fixture) 17.0.0 20260906; current: gcc (fixture) 17.0.0 20260920)'
assert_record drift-retry p1
assert_plan drift-retry p1 build
assert_row drift-retry p1 succeeded 0
assert_no_pkg_log drift-retry p1 'stale LTO object survived'
[ "$(makepkg_runs)" = 3 ] \
    || fail "expected initial, failed-drift and successful retry builds; saw $(makepkg_runs):" \
        "$fixture/out-drift-retry.txt"
assert_marker "$marker_p1" "$IDENT_B"

# ─── 5. Unchanged (new) identity under --skip: the completed rebuild skips ──
run_case post-skip "$VERSION_B" --skip p1
if [ "$FIXTURE_RC" != 0 ]; then
    fail "same-toolchain post-rebuild skip failed:" "$fixture/out-post-skip.txt"
fi
assert_record post-skip p1
assert_plan post-skip p1 skip
assert_row post-skip p1 succeeded -
assert_no_clean_message post-skip
[ "$(makepkg_runs)" = 3 ] \
    || fail "unchanged compiler identity did not skip the completed rebuild:" "$fixture/out-post-skip.txt"
assert_marker "$marker_p1" "$IDENT_B"

# ─── 6. Marker only AFTER baselines (positive): p2 builds from a real git
# checkout its makepkg stub fabricated in $srcdir — the VCS revision baseline
# records FIRST (a `*.gsa-vcs-revisions` sidecar), then the marker ──────────
export GSA_FAKE_CHECKOUT_MODE=git
run_case baseline-ok "$VERSION_A" p2
unset GSA_FAKE_CHECKOUT_MODE
if [ "$FIXTURE_RC" != 0 ]; then
    fail "p2's baseline build failed:" "$fixture/out-baseline-ok.txt"
fi
assert_msg baseline-ok 'GCC build identity missing; cleaning cached build artifacts (one-time clean)'
assert_record baseline-ok p2
assert_plan baseline-ok p2 build
assert_row baseline-ok p2 succeeded 0
[ "$(makepkg_runs)" = 4 ] || fail "p2 did not build:" "$fixture/out-baseline-ok.txt"
[ -f "$sidecar_p2" ] \
    || fail "the VCS revision baseline was not recorded beside the archive:" "$fixture/out-baseline-ok.txt"
[ "$(head -n 1 "$sidecar_p2")" = "$(printf 'gsa-vcs-revisions\t2')" ] \
    || fail "the baseline sidecar is not a manifest format 2 record:" "$fixture/out-baseline-ok.txt"
assert_marker "$marker_p2" "$IDENT_A"

# ─── 7. Marker only AFTER baselines (negative): the checkout the baseline
# must fingerprint is NOT a git repo, so the baseline recording fails CLOSED
# — the build still succeeds but the marker is NOT written (it keeps the old
# identity, so the next run drifts and re-cleans) ──────────────────────────
export GSA_FAKE_CHECKOUT_MODE=plain
run_case baseline-fail "$VERSION_B" p2
unset GSA_FAKE_CHECKOUT_MODE
if [ "$FIXTURE_RC" != 0 ]; then
    fail "p2's build should succeed even when its baseline cannot record:" \
        "$fixture/out-baseline-fail.txt"
fi
assert_msg baseline-fail 'GCC build identity missing or changed; cleaning cached build artifacts (previous: gcc (fixture) 17.0.0 20260906; current: gcc (fixture) 17.0.0 20260920)'
assert_msg baseline-fail 'vcs baseline: p2:'
assert_record baseline-fail p2
assert_plan baseline-fail p2 build
assert_row baseline-fail p2 succeeded 0
[ "$(makepkg_runs)" = 5 ] || fail "p2 did not build:" "$fixture/out-baseline-fail.txt"
[ ! -e "$sidecar_p2" ] \
    || fail "a failed baseline recording published a VCS sidecar:" "$fixture/out-baseline-fail.txt"
assert_marker "$marker_p2" "$IDENT_A"

# ─── 8. The failed-baseline attempt left the marker at the old identity, so
# the retry drifts again, re-cleans, and only then re-blesses the marker ────
export GSA_FAKE_CHECKOUT_MODE=git
run_case baseline-retry "$VERSION_B" p2
unset GSA_FAKE_CHECKOUT_MODE
if [ "$FIXTURE_RC" != 0 ]; then
    fail "p2's baseline retry failed:" "$fixture/out-baseline-retry.txt"
fi
assert_msg baseline-retry 'GCC build identity missing or changed; cleaning cached build artifacts (previous: gcc (fixture) 17.0.0 20260906; current: gcc (fixture) 17.0.0 20260920)'
assert_record baseline-retry p2
assert_plan baseline-retry p2 build
assert_row baseline-retry p2 succeeded 0
[ "$(makepkg_runs)" = 6 ] || fail "p2 did not rebuild:" "$fixture/out-baseline-retry.txt"
[ -f "$sidecar_p2" ] \
    || fail "the retry did not re-record its VCS revision baseline:" "$fixture/out-baseline-retry.txt"
assert_marker "$marker_p2" "$IDENT_B"

printf 'toolchain drift fixture: PASS (one-time clean, skip-preserve, drift clean + retry, baseline-before-marker)\n'
