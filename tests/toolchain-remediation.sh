#!/usr/bin/env bash
set -euo pipefail

# Regression fixture for the 2026-10-02 owner rule: a failing toolchain
# sanity probe (the llvm-snapshot ABI-skew guard, 2026-09-25 incident) no
# longer aborts the dispatch — the builder FORCE-BUILDS the at-risk chain to
# reconcile it and refuses only if that remediation build fails too. The
# probe stays loud (its verbatim error is asserted below) but must not start
# refusing builds while remediation is possible.
#
# Four scenarios, one workspace each, all offline (PATH stubs only):
#
#   A. narrow remediation: the probe implicates rust-git (a known consumer of
#      the installed llvm-git in the topology's ABI direction) — rust-git is
#      FORCE-BUILT even though it was never in the selection, nothing else may
#      compile until the rebuild lands, the re-probe passes and the run
#      finishes successfully with the held-back consumer.
#
#   B. narrow remediation insufficient → escalate to the whole core group:
#      the general tool-clang/llvm consumer chain, not just rustc. A core
#      member (tc1, an llvm consumer standing in for the tool-clang chain)
#      reconciles what the rust-git rebuild alone could not. The narrow
#      attempt is NOT repeated inside the core phase.
#
#   C. broken consumer unidentified narrowly (rust-git is installed on the
#      system but is not a buildable package here) → the plan degrades
#      straight to the whole core group.
#
#   D. the remediation build itself fails → the ONE refusal left: stop
#      dispatch, loud refusal, non-zero exit, held-back consumer never built.
#
# Section C of tests/abi-batch-policy.sh pins the remaining "remediation
# impossible" refusal (a probe failure with no identifiable chain at all).
#
# The fake rustc dies exactly like the real one did while the llvm-skew
# marker exists; llvm-git's build creates it (this run's own install broke
# rustc), and the remediation rebuilds clear it (rust-git only when the
# scenario says a rust rebuild is enough, the core consumers always).

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-toolchain-remediation.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf 'toolchain-remediation fixture: %s\n' "$*" >&2
    exit 1
}

add_meta_package() { # $1 = dir, $2 = id
    add_package "$1" "$2" "$gsa_meta_any"
}

# install_stubs DIR — the shared stub set (per-scenario behaviour is keyed by
# env in the stubs' vocabulary): sudo passthrough, a marker-driven rustc, a
# pacman whose -Q answers come from GSA_FAKE_INSTALLED_DIR, and a makepkg that
# logs every BUILD and drives the skew marker.
install_stubs() {
    local dir=$1
    stub_sudo "$dir"

    cat >"$dir/bin/rustc" <<'EOF'
#!/usr/bin/env bash
set -u
if [[ -e ${GSA_FAKE_MARKER_DIR:-/no-such-marker-dir}/llvm-skew ]]; then
    exit 127
fi
exit 0
EOF
    chmod +x "$dir/bin/rustc"

    cat >"$dir/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'pacman %s\n' "$*" >>"${GSA_FAKE_PACMAN_LOG:?}"
case ${1:-} in
-Q)
    [[ -e ${GSA_FAKE_INSTALLED_DIR:?}/${2:-} ]] && exit 0
    exit 1
    ;;
-Qp | -Qi) exit 1 ;;
esac
exit 0
EOF
    chmod +x "$dir/bin/pacman"

    cat >"$dir/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(basename "$PWD")
printf 'BUILD %s\n' "$id" >>"${GSA_FAKE_SPAWN_LOG:?}"
if [[ ${GSA_FAKE_FAIL_PACKAGE:-} == "$id" ]]; then
    printf 'simulated build failure for %s\n' "$id" >&2
    exit 1
fi
case $id in
llvm-git)
    # This run's own llvm install lands the new LLVM ABI and breaks rustc.
    mkdir -p "${GSA_FAKE_MARKER_DIR:?}"
    : >"$GSA_FAKE_MARKER_DIR/llvm-skew"
    ;;
rust-git)
    # The narrow remediation reconciles the system only when the scenario
    # says a rust rebuild is enough.
    if [[ ${GSA_FAKE_RUST_FIX:-0} == 1 ]]; then
        rm -f "$GSA_FAKE_MARKER_DIR/llvm-skew"
    fi
    ;;
tc1 | c2)
    # The general tool-clang/llvm consumer chain: these reconcile.
    rm -f "$GSA_FAKE_MARKER_DIR/llvm-skew"
    ;;
p2)
    rustc --version || {
        printf 'p2: dispatched against a broken rustc\n' >&2
        exit 1
    }
    ;;
esac
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
exit 0
EOF
    chmod +x "$dir/bin/makepkg"
}

# prepare DIR — directories + the "rust-git is installed" system state the
# probe needs to engage at all (check_rustc_sanity short-circuits otherwise).
prepare() {
    local dir=$1
    install_stubs "$dir"
    mkdir -p "$dir/state/skew" "$dir/installed"
    make_install_conf "$dir/pacman.conf" # this case's IgnorePkg registration target (never the host's)
    : >"$dir/installed/rust-git"
}

# run_scenario DIR [ARGS...] — always returns 0; outcome in
# FIXTURE_OUTPUT/FIXTURE_RC. Scenario knobs ride as GSA_FAKE_RUST_FIX /
# GSA_FAKE_FAIL_PACKAGE in the caller's environment.
run_scenario() {
    local dir=$1
    shift
    run_builder env \
        PATH="$dir/bin:$PATH" \
        GSA_STATE_DIR="$dir/state" \
        _IGNOREPKG_CONF="$dir/pacman.conf" \
        GSA_FAKE_MARKER_DIR="$dir/state/skew" \
        GSA_FAKE_INSTALLED_DIR="$dir/installed" \
        GSA_FAKE_SPAWN_LOG="$dir/spawn.log" \
        GSA_FAKE_PACMAN_LOG="$dir/pacman.log" \
        GSA_FAKE_RUST_FIX="${GSA_FAKE_RUST_FIX:-0}" \
        GSA_FAKE_FAIL_PACKAGE="${GSA_FAKE_FAIL_PACKAGE:-}" \
        GSA_CPU_THREADS=8 \
        GSA_MEMORY_GIB=16 \
        fish "$dir/build-all.fish" "$@"
}

# assert_builds LOGFILE EXPECTED... — the makepkg stub's BUILD log must match
# the expected ids in exactly this order (the remediation ordering is the
# contract: force-build first, held-back work only after it lands).
assert_builds() {
    local log=$1
    shift
    local actual expected
    actual=$(cat "$log" 2>/dev/null || true)
    expected=$(printf 'BUILD %s\n' "$@")
    if [[ $actual != "$expected" ]]; then
        fail "build sequence mismatch
--- expected ---
$expected
--- actual ($log) ---
$actual"
    fi
}

# ─── A. narrow remediation: rust-git force-built, run resumes and succeeds ───
dir_a="$fixture/narrow"
make_workspace "$dir_a" 1 2 low
add_meta_package "$dir_a" llvm-git
add_meta_package "$dir_a" rust-git
add_meta_package "$dir_a" p2
set_topology_record "$dir_a" rust-git core 'llvm-git'
set_topology_record "$dir_a" p2 git 'llvm-git,rust-git'
prepare "$dir_a"

GSA_FAKE_RUST_FIX=1 run_scenario "$dir_a" --no-deps -i --no-sync llvm-git p2
out_a=$FIXTURE_OUTPUT
rc_a=$FIXTURE_RC
if [[ $rc_a -ne 0 ]]; then
    printf 'A: the remediation run failed (rc=%d) although the rust-git rebuild reconciles rustc:\n%s\n' \
        "$rc_a" "$out_a" >&2
    exit 1
fi
if ! grep -Fq 'All builds succeeded!' <<<"$out_a"; then
    printf 'A: the run did not report success:\n%s\n' "$out_a" >&2
    exit 1
fi
# The probe stays LOUD: the verbatim incident message and the probe's own
# recovery text are both part of the log contract.
for want in \
    'rustc sanity probe failed after llvm-git was installed' \
    "this run's own llvm install broke rustc" \
    'rustc is BROKEN' \
    'FORCE-BUILDS the at-risk' \
    'toolchain remediation (phase narrow): force-building rust-git' \
    'toolchain remediation reconciled' \
    'resuming dispatch'; do
    if ! grep -Fq "$want" <<<"$out_a"; then
        printf 'A: output is missing %q:\n%s\n' "$want" "$out_a" >&2
        exit 1
    fi
done
if grep -Fq 'refusing to continue' <<<"$out_a"; then
    printf 'A: the run refused although remediation was possible:\n%s\n' "$out_a" >&2
    exit 1
fi
# rust-git was NEVER selected — the force-build put it in the pass, before
# the held-back consumer p2 (which must not compile against broken rustc).
assert_builds "$dir_a/spawn.log" llvm-git rust-git p2
if [[ $(rr_scalar outcome <<<"$out_a") != success ]]; then
    printf 'A: run record did not report success:\n%s\n' "$out_a" >&2
    exit 1
fi
if [[ $(rr_row rust-git status <<<"$out_a") != succeeded ]]; then
    printf 'A: the force-built rust-git has no succeeded run-record row:\n%s\n' "$out_a" >&2
    exit 1
fi

# ─── B. narrow insufficient → whole core group (tool-clang/llvm chain) ───────
dir_b="$fixture/escalate"
make_workspace "$dir_b" 1 2 low
add_meta_package "$dir_b" llvm-git
add_meta_package "$dir_b" rust-git
add_meta_package "$dir_b" tc1
add_meta_package "$dir_b" c2
add_meta_package "$dir_b" p2
set_topology_record "$dir_b" llvm-git core ''
set_topology_record "$dir_b" rust-git core 'llvm-git'
set_topology_record "$dir_b" tc1 core 'llvm-git'
set_topology_record "$dir_b" c2 core ''
set_topology_record "$dir_b" p2 git 'llvm-git,rust-git'
prepare "$dir_b"

# GSA_FAKE_RUST_FIX stays 0: the rust-git rebuild does NOT reconcile, the
# general llvm consumer chain (tc1) does.
run_scenario "$dir_b" --no-deps -i --no-sync llvm-git p2
out_b=$FIXTURE_OUTPUT
rc_b=$FIXTURE_RC
if [[ $rc_b -ne 0 ]]; then
    printf 'B: the escalating remediation run failed (rc=%d):\n%s\n' "$rc_b" "$out_b" >&2
    exit 1
fi
if ! grep -Fq 'All builds succeeded!' <<<"$out_b"; then
    printf 'B: the run did not report success:\n%s\n' "$out_b" >&2
    exit 1
fi
for want in \
    'remediation by rust-git was insufficient' \
    'Escalating to a full core-group force-build' \
    'toolchain remediation (phase core): force-building llvm-git, tc1, c2' \
    'toolchain remediation reconciled'; do
    if ! grep -Fq "$want" <<<"$out_b"; then
        printf 'B: output is missing %q:\n%s\n' "$want" "$out_b" >&2
        exit 1
    fi
done
# The narrow attempt is made once and NOT repeated inside the core phase;
# llvm-git is rebuilt by the core phase (whole group means whole group).
rust_builds=$(grep -cx 'BUILD rust-git' "$dir_b/spawn.log" || true)
llvm_builds=$(grep -cx 'BUILD llvm-git' "$dir_b/spawn.log" || true)
if [[ $rust_builds != 1 ]]; then
    printf 'B: rust-git was force-built %s times (expected 1 narrow attempt):\n%s\n' \
        "$rust_builds" "$(cat "$dir_b/spawn.log")" >&2
    exit 1
fi
if [[ $llvm_builds != 2 ]]; then
    printf 'B: llvm-git was built %s times (expected initial + core escalation):\n%s\n' \
        "$llvm_builds" "$(cat "$dir_b/spawn.log")" >&2
    exit 1
fi
assert_builds "$dir_b/spawn.log" llvm-git rust-git llvm-git tc1 c2 p2

# ─── C. broken consumer unidentified → core group from the start ────────────
dir_c="$fixture/unknown-consumer"
make_workspace "$dir_c" 1 2 low
add_meta_package "$dir_c" llvm-git
add_meta_package "$dir_c" tc1
add_meta_package "$dir_c" p2
set_topology_record "$dir_c" llvm-git core ''
set_topology_record "$dir_c" tc1 core 'llvm-git'
set_topology_record "$dir_c" p2 git 'llvm-git'
prepare "$dir_c"

# rust-git is installed on the system (so the probe engages) but is not a
# package of this workspace: the narrow consumer cannot be identified.
run_scenario "$dir_c" --no-deps -i --no-sync llvm-git p2
out_c=$FIXTURE_OUTPUT
rc_c=$FIXTURE_RC
if [[ $rc_c -ne 0 ]]; then
    printf 'C: the core-group remediation run failed (rc=%d):\n%s\n' "$rc_c" "$out_c" >&2
    exit 1
fi
if ! grep -Fq 'All builds succeeded!' <<<"$out_c"; then
    printf 'C: the run did not report success:\n%s\n' "$out_c" >&2
    exit 1
fi
for want in \
    'toolchain remediation (phase core): force-building llvm-git, tc1' \
    'toolchain remediation reconciled'; do
    if ! grep -Fq "$want" <<<"$out_c"; then
        printf 'C: output is missing %q:\n%s\n' "$want" "$out_c" >&2
        exit 1
    fi
done
assert_builds "$dir_c/spawn.log" llvm-git llvm-git tc1 p2

# ─── D. the remediation build fails → the one refusal left ──────────────────
dir_d="$fixture/remediation-fails"
make_workspace "$dir_d" 1 2 low
add_meta_package "$dir_d" llvm-git
add_meta_package "$dir_d" rust-git
add_meta_package "$dir_d" p2
set_topology_record "$dir_d" rust-git core 'llvm-git'
set_topology_record "$dir_d" p2 git 'llvm-git,rust-git'
prepare "$dir_d"

GSA_FAKE_FAIL_PACKAGE=rust-git run_scenario "$dir_d" --no-deps -i --no-sync llvm-git p2
out_d=$FIXTURE_OUTPUT
rc_d=$FIXTURE_RC
if [[ $rc_d -eq 0 ]]; then
    printf 'D: the run succeeded although the remediation build failed:\n%s\n' "$out_d" >&2
    exit 1
fi
for want in \
    'toolchain remediation build for rust-git failed' \
    'refusing to continue' \
    'rebuild rust-git in the same pass'; do
    if ! grep -Fq "$want" <<<"$out_d"; then
        printf 'D: output is missing %q:\n%s\n' "$want" "$out_d" >&2
        exit 1
    fi
done
if grep -Fq 'All builds succeeded!' <<<"$out_d"; then
    printf 'D: success was reported after the remediation build failed:\n%s\n' "$out_d" >&2
    exit 1
fi
if grep -Fq 'BUILD p2' "$dir_d/spawn.log" 2>/dev/null; then
    printf 'D: p2 was dispatched although remediation never reconciled:\n%s\n' \
        "$(cat "$dir_d/spawn.log")" >&2
    exit 1
fi
if ! grep -Fq 'BUILD rust-git' "$dir_d/spawn.log" 2>/dev/null; then
    printf 'D: the remediation build was never attempted:\n%s\n' \
        "$(cat "$dir_d/spawn.log" 2>/dev/null)" >&2
    exit 1
fi

printf 'toolchain-remediation fixture: PASS\n'
