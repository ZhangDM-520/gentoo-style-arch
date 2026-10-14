#!/usr/bin/env bash
set -euo pipefail

# tests/toolchain-remediation.sh — the 2026-10-02 owner rule on the NATIVE
# engine (`gsa`, docs/gsa-contract.md §G.1/§H/§I): a failing toolchain sanity
# probe (the llvm-snapshot ABI-skew guard, 2026-09-25 incident) no longer
# aborts the dispatch — the engine FORCE-BUILDS the at-risk chain to
# reconcile it and refuses only if that remediation build fails too. The
# probe stays loud (its verbatim error is asserted below) but must not start
# refusing builds while remediation is possible.
#
# Five scenarios, one workspace each, all offline (PATH stubs only), driven
# as `gsa -S` INSTALL runs — the mid-run trigger is install-only (it re-probes
# after the successful install of llvm-git/llvm-libs-git):
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
#      dispatch, the probe-refusal block, rc 3 (§G.1 refusal class), the
#      held-back consumer never built.
#
#   E. the whole core group lands but the probe STILL fails → the escalation
#      ladder's refusal end: `core-group remediation rebuilt … and the sanity
#      probe still fails`, the same probe-refusal block, rc 3.
#
# Section C of tests/abi-batch-policy.sh pins the remaining "remediation
# impossible" refusal (a probe failure with no identifiable chain at all).
#
# The fake rustc dies exactly like the real one did while the llvm-skew
# marker exists; llvm-git's build creates it (this run's own install broke
# rustc), and the remediation rebuilds clear it (rust-git only when the
# scenario says a rust rebuild is enough, the core consumers always — never
# under GSA_FAKE_NO_RECONCILE).
#
# Flip notes (fish-era build-all.fish fixture → the native engine, REWRITE
# class): the driver is tests/lib/rr-v2.bash's run_engine with
# GSA_TEST_ENGINE=gsa and `gsa -S --leaf` replacing `fish build-all.fish
# --no-deps -i`; `--no-sync` and the per-run knobs keep their meaning;
# `_IGNOREPKG_CONF` retires for `--config` (the engine's IgnorePkg
# registration target); the format: 1 rr_* pins re-pin through rr2_* against
# the format: 2 block, with `order:` covering exactly the plan/outcome
# subjects (the activated remediation latents appended after the selection,
# as the fish `_RR_ORDER` did) and the rc rules of §H.3 (succeeded 0|-,
# failed 1|125|-, deferred 99, parked 98|-, never-started -); the fish
# `All builds succeeded!` prose retires for record assertions (outcome/rc
# scalars). The probe stubs gain the engine's two extra process-boundary
# probes — `cargo --version` (the documented cargo probe) and `pacman-conf
# DBPath` (the local-DB root, answered from fixture state — never the host's)
# — and the makepkg stub now ships a real `.pkg.tar.zst` with a `.PKGINFO`,
# because the engine's install pipeline takes archive truth from the archive
# itself. The scenario coverage, the marker-flipping stub mechanism and the
# expected shapes (build order, `order:`) are unchanged from the fish era.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"

fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-toolchain-remediation.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf 'toolchain-remediation fixture: %s\n' "$1" >&2
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
        sed 's/^/    /' "$2" >&2
    fi
    exit 1
}

# ─── Stub-knob vocabulary (§D.2: declared here in the change that adds them) ─
rr2_stub_knob GSA_FAKE_RUST_FIX "toolchain-remediation makepkg stub: the rust-git rebuild clears the llvm-skew marker"
rr2_stub_knob GSA_FAKE_NO_RECONCILE "toolchain-remediation makepkg stub: no consumer rebuild clears the llvm-skew marker"

# ─── The engine under test: built into the fixture tree (scratch only) ──────
cargo build --offline --quiet --target-dir "$fixture/cargo" -p gsa-cli \
    --manifest-path "$gsa_repo_root/Cargo.toml" \
    || fail "cannot build the gsa binary for the fixture"
gsa_bin="$fixture/cargo/debug/gsa"
[ -x "$gsa_bin" ] || fail "cargo did not produce $gsa_bin"
export GSA_TEST_ENGINE=gsa
export GSA_TEST_GSA_BIN="$gsa_bin"

add_meta_package() { # $1 = dir, $2 = id
    add_package "$1" "$2" "$gsa_meta_any"
}

# install_stubs DIR — the shared stub set (per-scenario behaviour is keyed by
# env in the stubs' vocabulary): sudo passthrough, marker-driven rustc/cargo
# (the engine's trivial compile and `cargo --version` probes), a pacman whose
# `pacman -Q` answers come from GSA_FAKE_INSTALLED_DIR (the probe's rust-git
# gate), a pacman-conf answering DBPath from fixture state, and a makepkg
# that logs every BUILD and drives the skew marker.
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

    cat >"$dir/bin/cargo" <<'EOF'
#!/usr/bin/env bash
set -u
if [[ -e ${GSA_FAKE_MARKER_DIR:-/no-such-marker-dir}/llvm-skew ]]; then
    exit 127
fi
exit 0
EOF
    chmod +x "$dir/bin/cargo"

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

    cat >"$dir/bin/pacman-conf" <<'EOF'
#!/usr/bin/env bash
set -u
if [[ ${1:-} == DBPath ]]; then
    printf '%s\n' "${GSA_FAKE_DB_PATH:?}"
fi
exit 0
EOF
    chmod +x "$dir/bin/pacman-conf"

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
    # The general tool-clang/llvm consumer chain: these reconcile — unless
    # the scenario says nothing may (E's core-fail refusal end).
    if [[ ${GSA_FAKE_NO_RECONCILE:-0} != 1 ]]; then
        rm -f "$GSA_FAKE_MARKER_DIR/llvm-skew"
    fi
    ;;
p2)
    rustc --version || {
        printf 'p2: dispatched against a broken rustc\n' >&2
        exit 1
    }
    ;;
esac
# A real archive with its own .PKGINFO truth: the engine's install pipeline
# discovers candidates from the archive itself (never a glob-all fallback).
stage="$PWD/.stage-$id"
mkdir -p "$stage"
{
    printf 'pkgbase = %s\n' "$id"
    printf 'pkgname = %s\n' "$id"
    printf 'pkgver = 1.0.0-1\n'
    printf 'arch = any\n'
} >"$stage/.PKGINFO"
tar --zstd -cf "$PWD/$id-1.0.0-1-any.pkg.tar.zst" -C "$stage" .PKGINFO
rm -rf -- "$stage"
exit 0
EOF
    chmod +x "$dir/bin/makepkg"
}

# prepare DIR — directories + the "rust-git is installed" system state the
# probe needs to engage at all (the probe short-circuits otherwise), an
# empty fabricated local DB (never the host's), and this run's IgnorePkg
# registration target.
prepare() {
    local dir=$1
    install_stubs "$dir"
    mkdir -p "$dir/state/skew" "$dir/installed" "$dir/db/local"
    make_install_conf "$dir/pacman.conf" # this case's IgnorePkg registration target (never the host's)
    : >"$dir/installed/rust-git"
}

# run_scenario DIR [ARGS...] — always returns 0; outcome in
# FIXTURE_OUTPUT/FIXTURE_RC. Scenario knobs ride as GSA_FAKE_RUST_FIX /
# GSA_FAKE_NO_RECONCILE / GSA_FAKE_FAIL_PACKAGE in the caller's environment.
run_scenario() {
    local dir=$1
    shift
    export PATH="$dir/bin:$PATH"
    export GSA_FAKE_MARKER_DIR="$dir/state/skew"
    export GSA_FAKE_INSTALLED_DIR="$dir/installed"
    export GSA_FAKE_SPAWN_LOG="$dir/spawn.log"
    export GSA_FAKE_PACMAN_LOG="$dir/pacman.log"
    export GSA_FAKE_DB_PATH="$dir/db"
    export GSA_CPU_THREADS=8 GSA_MEMORY_GIB=16
    run_engine "$dir" -S --leaf --no-sync --lanes 1 --jobs 2 --intensity low \
        --state-dir "$dir/state" --config "$dir/pacman.conf" "$@"
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

# assert_record OUTFILE — the run-record consistency the rr-v2 rules demand:
# `order:` covers exactly the plan/outcome subjects (same list, same order),
# every outcome row's rc is its status's allowed code (succeeded 0|-,
# failed 1|125|-, deferred 99, parked 98|-, never-started -), the record's
# rc scalar is the process exit code, and the continuation's `remaining:` is
# the rows-derived resume set.
assert_record() {
    local out=$1
    local order plan_subs out_subs remaining_rows remaining_line
    order=$(rr2_scalar order <<<"$FIXTURE_OUTPUT")
    plan_subs=$(rr2_plan_rows <<<"$FIXTURE_OUTPUT" | awk '{printf "%s ", $1}' | sed 's/ $//')
    out_subs=$(rr2_outcome_rows <<<"$FIXTURE_OUTPUT" | awk '{printf "%s ", $1}' | sed 's/ $//')
    if [[ $order != "$plan_subs" || $order != "$out_subs" ]]; then
        fail "order: [$order] does not cover exactly the plan subjects [$plan_subs] and outcome subjects [$out_subs]" "$out"
    fi
    rr2_outcome_rows <<<"$FIXTURE_OUTPUT" | awk '
        $2 == "succeeded" && !($3 == "0" || $3 == "-") { print "succeeded rc " $3 ": " $1; bad = 1 }
        $2 == "failed" && !($3 == "1" || $3 == "125" || $3 == "-") { print "failed rc " $3 ": " $1; bad = 1 }
        $2 == "deferred" && $3 != "99" { print "deferred rc " $3 ": " $1; bad = 1 }
        $2 == "parked" && !($3 == "98" || $3 == "-") { print "parked rc " $3 ": " $1; bad = 1 }
        $2 == "never-started" && $3 != "-" { print "never-started rc " $3 ": " $1; bad = 1 }
        END { exit bad }' \
        || fail "outcome rows violate the rr-v2 rc rules (§H.3)" "$out"
    if [[ $(rr2_scalar rc <<<"$FIXTURE_OUTPUT") != "$FIXTURE_RC" ]]; then
        fail "the record's rc scalar disagrees with the process exit code ($FIXTURE_RC)" "$out"
    fi
    remaining_rows=$(rr2_remaining <<<"$FIXTURE_OUTPUT" | tr '\n' ' ' | sed 's/ $//')
    remaining_line=$(rr2_continuation remaining <<<"$FIXTURE_OUTPUT")
    if [[ $remaining_rows != "$remaining_line" ]]; then
        fail "continuation remaining [$remaining_line] != rows-derived remaining [$remaining_rows]" "$out"
    fi
}

# require_msgs OUTFILE SCENARIO MSG... — every message must appear in the
# merged run output (policy/prose rides the engine's stderr, captured merged).
require_msgs() {
    local out=$1 scenario=$2
    shift 2
    local want
    for want in "$@"; do
        grep -Fq -- "$want" <<<"$FIXTURE_OUTPUT" \
            || fail "$scenario: output is missing '$want'" "$out"
    done
}

# The probe-risk block and the probe-refusal block, verbatim (the engine
# prints them line by line; one grep per line — a multiline pattern would
# match line-wise and weaken the block assertion to any single line).
RISK_BLOCK_LINES=(
    '  Toolchain risk detected for the tool-clang/llvm consumer chain — not'
    '  just rustc. Owner rule 2026-10-02: the builder FORCE-BUILDS the at-risk'
    '  chain to reconcile it — first rust-git (rust), or the whole core group'
    '  when the broken consumer cannot be identified narrowly — and refuses'
    '  only if that remediation build also fails. This probe stays loud but'
    '  does not refuse builds while remediation is possible.'
)
REFUSAL_BLOCK_LINE='  The selection must rebuild rust-git in the same pass before anything'

# ─── A. narrow remediation: rust-git force-built, run resumes and succeeds ───
(
    set -euo pipefail
    dir_a="$fixture/narrow"
    make_workspace "$dir_a" 1 2 low
    add_meta_package "$dir_a" llvm-git
    add_meta_package "$dir_a" rust-git
    add_meta_package "$dir_a" p2
    set_topology_record "$dir_a" rust-git core 'llvm-git'
    set_topology_record "$dir_a" p2 git 'llvm-git,rust-git'
    prepare "$dir_a"
    export GSA_FAKE_RUST_FIX=1

    run_scenario "$dir_a" llvm-git p2
    echo "$FIXTURE_OUTPUT" >"$fixture/a.txt"
    out_a="$fixture/a.txt"

    # The remediation run succeeds (the rust-git rebuild reconciles rustc):
    # the §G.1 success class, and the record says the same.
    if [[ $FIXTURE_RC -ne 0 ]]; then
        fail "A: the remediation run failed (rc=$FIXTURE_RC) although the rust-git rebuild reconciles rustc" "$out_a"
    fi
    if [[ $(rr2_scalar outcome <<<"$FIXTURE_OUTPUT") != success ]]; then
        fail "A: run record did not report success" "$out_a"
    fi
    assert_record "$out_a"

    # The probe stays LOUD: the verbatim incident message, the probe detail
    # and the risk block are all part of the log contract.
    require_msgs "$out_a" A \
        'rustc sanity probe failed after llvm-git was installed' \
        "this run's own llvm install broke rustc" \
        'rustc is BROKEN' \
        "${RISK_BLOCK_LINES[@]}" \
        'toolchain remediation (phase narrow): force-building rust-git to reconcile the at-risk chain before anything else compiles' \
        'toolchain remediation reconciled the at-risk chain (rebuilt rust-git) — rustc sanity probe passes, resuming dispatch'
    if grep -Fq 'refusing to continue' <<<"$FIXTURE_OUTPUT"; then
        fail "A: the run refused although remediation was possible" "$out_a"
    fi

    # rust-git was NEVER selected — the force-build put it in the pass,
    # before the held-back consumer p2 (which must not compile against a
    # broken rustc: its stub fails if dispatched while the marker stands).
    assert_builds "$dir_a/spawn.log" llvm-git rust-git p2
    if [[ $(rr2_scalar order <<<"$FIXTURE_OUTPUT") != 'llvm-git p2 rust-git' ]]; then
        fail "A: unexpected run-record order '$(rr2_scalar order <<<"$FIXTURE_OUTPUT")'" "$out_a"
    fi
    if [[ $(rr2_outcome rust-git status <<<"$FIXTURE_OUTPUT") != succeeded ]]; then
        fail "A: the force-built rust-git has no succeeded run-record row" "$out_a"
    fi
    if [[ $(rr2_outcome p2 status <<<"$FIXTURE_OUTPUT") != succeeded ]]; then
        fail "A: the held-back consumer p2 did not run to completion" "$out_a"
    fi
)

# ─── B. narrow insufficient → whole core group (tool-clang/llvm chain) ───────
(
    set -euo pipefail
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
    run_scenario "$dir_b" llvm-git p2
    echo "$FIXTURE_OUTPUT" >"$fixture/b.txt"
    out_b="$fixture/b.txt"

    if [[ $FIXTURE_RC -ne 0 ]]; then
        fail "B: the escalating remediation run failed (rc=$FIXTURE_RC)" "$out_b"
    fi
    if [[ $(rr2_scalar outcome <<<"$FIXTURE_OUTPUT") != success ]]; then
        fail "B: run record did not report success" "$out_b"
    fi
    assert_record "$out_b"
    require_msgs "$out_b" B \
        'remediation by rust-git was insufficient — the tool-clang/llvm consumer chain is still broken' \
        '  Escalating to a full core-group force-build (owner rule 2026-10-02).' \
        'toolchain remediation (phase core): force-building llvm-git, tc1, c2' \
        'toolchain remediation reconciled'

    # The narrow attempt is made once and NOT repeated inside the core phase;
    # llvm-git is rebuilt by the core phase (whole group means whole group).
    rust_builds=$(grep -cx 'BUILD rust-git' "$dir_b/spawn.log" || true)
    llvm_builds=$(grep -cx 'BUILD llvm-git' "$dir_b/spawn.log" || true)
    if [[ $rust_builds != 1 ]]; then
        fail "B: rust-git was force-built $rust_builds times (expected 1 narrow attempt): $(cat "$dir_b/spawn.log")" "$out_b"
    fi
    if [[ $llvm_builds != 2 ]]; then
        fail "B: llvm-git was built $llvm_builds times (expected initial + core escalation): $(cat "$dir_b/spawn.log")" "$out_b"
    fi
    assert_builds "$dir_b/spawn.log" llvm-git rust-git llvm-git tc1 c2 p2
    if [[ $(rr2_scalar order <<<"$FIXTURE_OUTPUT") != 'llvm-git p2 rust-git tc1 c2' ]]; then
        fail "B: unexpected run-record order '$(rr2_scalar order <<<"$FIXTURE_OUTPUT")'" "$out_b"
    fi
)

# ─── C. broken consumer unidentified → core group from the start ────────────
(
    set -euo pipefail
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
    run_scenario "$dir_c" llvm-git p2
    echo "$FIXTURE_OUTPUT" >"$fixture/c.txt"
    out_c="$fixture/c.txt"

    if [[ $FIXTURE_RC -ne 0 ]]; then
        fail "C: the core-group remediation run failed (rc=$FIXTURE_RC)" "$out_c"
    fi
    if [[ $(rr2_scalar outcome <<<"$FIXTURE_OUTPUT") != success ]]; then
        fail "C: run record did not report success" "$out_c"
    fi
    assert_record "$out_c"
    require_msgs "$out_c" C \
        'toolchain remediation (phase core): force-building llvm-git, tc1' \
        'toolchain remediation reconciled'
    assert_builds "$dir_c/spawn.log" llvm-git llvm-git tc1 p2
    if [[ $(rr2_scalar order <<<"$FIXTURE_OUTPUT") != 'llvm-git p2 tc1' ]]; then
        fail "C: unexpected run-record order '$(rr2_scalar order <<<"$FIXTURE_OUTPUT")'" "$out_c"
    fi
)

# ─── D. the remediation build fails → the one refusal left ──────────────────
(
    set -euo pipefail
    dir_d="$fixture/remediation-fails"
    make_workspace "$dir_d" 1 2 low
    add_meta_package "$dir_d" llvm-git
    add_meta_package "$dir_d" rust-git
    add_meta_package "$dir_d" p2
    set_topology_record "$dir_d" rust-git core 'llvm-git'
    set_topology_record "$dir_d" p2 git 'llvm-git,rust-git'
    prepare "$dir_d"
    export GSA_FAKE_FAIL_PACKAGE=rust-git

    run_scenario "$dir_d" llvm-git p2
    echo "$FIXTURE_OUTPUT" >"$fixture/d.txt"
    out_d="$fixture/d.txt"

    # The remediation build failed → the refusal class: stop dispatch, the
    # probe-refusal block, §G.1 rc 3.
    if [[ $FIXTURE_RC -eq 0 ]]; then
        fail "D: the run succeeded although the remediation build failed" "$out_d"
    fi
    if [[ $FIXTURE_RC -ne 3 ]]; then
        fail "D: a remediation refusal is §G.1 rc 3, got $FIXTURE_RC" "$out_d"
    fi
    if [[ $(rr2_scalar outcome <<<"$FIXTURE_OUTPUT") != refused ]]; then
        fail "D: run record did not report outcome 'refused'" "$out_d"
    fi
    assert_record "$out_d"
    require_msgs "$out_d" D \
        'toolchain remediation build for rust-git failed — the at-risk chain could not be reconciled; refusing to continue' \
        "$REFUSAL_BLOCK_LINE"
    if grep -Fq 'All builds succeeded!' <<<"$FIXTURE_OUTPUT"; then
        fail "D: success was reported after the remediation build failed" "$out_d"
    fi

    # p2 must never compile against the unreconciled toolchain.
    if grep -Fq 'BUILD p2' "$dir_d/spawn.log" 2>/dev/null; then
        fail "D: p2 was dispatched although remediation never reconciled: $(cat "$dir_d/spawn.log")" "$out_d"
    fi
    if ! grep -Fq 'BUILD rust-git' "$dir_d/spawn.log" 2>/dev/null; then
        fail "D: the remediation build was never attempted: $(cat "$dir_d/spawn.log" 2>/dev/null)" "$out_d"
    fi
    assert_builds "$dir_d/spawn.log" llvm-git rust-git
    if [[ $(rr2_scalar order <<<"$FIXTURE_OUTPUT") != 'llvm-git p2 rust-git' ]]; then
        fail "D: unexpected run-record order '$(rr2_scalar order <<<"$FIXTURE_OUTPUT")'" "$out_d"
    fi
    if [[ $(rr2_outcome rust-git status <<<"$FIXTURE_OUTPUT") != failed ]]; then
        fail "D: the failed remediation build has no failed run-record row" "$out_d"
    fi
    if [[ $(rr2_outcome p2 status <<<"$FIXTURE_OUTPUT") != never-started ]]; then
        fail "D: p2 must be never-started after the refusal" "$out_d"
    fi
)

# ─── E. core-group remediation lands but the probe still fails → refusal ────
(
    set -euo pipefail
    dir_e="$fixture/core-fails"
    make_workspace "$dir_e" 1 2 low
    add_meta_package "$dir_e" llvm-git
    add_meta_package "$dir_e" rust-git
    add_meta_package "$dir_e" tc1
    add_meta_package "$dir_e" c2
    add_meta_package "$dir_e" p2
    set_topology_record "$dir_e" llvm-git core ''
    set_topology_record "$dir_e" rust-git core 'llvm-git'
    set_topology_record "$dir_e" tc1 core 'llvm-git'
    set_topology_record "$dir_e" c2 core ''
    set_topology_record "$dir_e" p2 git 'llvm-git,rust-git'
    prepare "$dir_e"

    # Nothing reconciles the skew: the narrow attempt and the whole core
    # group build fine but the re-probe keeps failing — the escalation
    # ladder's refusal end.
    export GSA_FAKE_NO_RECONCILE=1
    run_scenario "$dir_e" llvm-git p2
    echo "$FIXTURE_OUTPUT" >"$fixture/e.txt"
    out_e="$fixture/e.txt"

    if [[ $FIXTURE_RC -ne 3 ]]; then
        fail "E: the core-fail refusal is §G.1 rc 3, got $FIXTURE_RC" "$out_e"
    fi
    if [[ $(rr2_scalar outcome <<<"$FIXTURE_OUTPUT") != refused ]]; then
        fail "E: run record did not report outcome 'refused'" "$out_e"
    fi
    assert_record "$out_e"
    require_msgs "$out_e" E \
        'remediation by rust-git was insufficient — the tool-clang/llvm consumer chain is still broken' \
        'toolchain remediation (phase core): force-building llvm-git, tc1, c2' \
        'core-group remediation rebuilt rust-git, llvm-git, tc1, c2 and the sanity probe still fails — refusing to continue' \
        "$REFUSAL_BLOCK_LINE"
    if grep -Fq 'BUILD p2' "$dir_e/spawn.log" 2>/dev/null; then
        fail "E: p2 was dispatched although the chain never reconciled: $(cat "$dir_e/spawn.log")" "$out_e"
    fi
    assert_builds "$dir_e/spawn.log" llvm-git rust-git llvm-git tc1 c2
    if [[ $(rr2_outcome p2 status <<<"$FIXTURE_OUTPUT") != never-started ]]; then
        fail "E: p2 must be never-started after the refusal" "$out_e"
    fi
)

printf 'toolchain-remediation fixture: PASS\n'
