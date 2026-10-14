#!/usr/bin/env bash
set -euo pipefail

# tests/log-ownership.sh — log/state-file ownership and crash-forensics
# contract (2026-09-23 incident: a root-mode run that dies mid-flight leaves
# the in-flight per-package logs root-owned, and the next UNPRIVILEGED run
# dies at the log redirect with a misleading "BUILD FAILED (rc=125)" before
# the build even starts). The contract: never a silent truncate of crash
# evidence — the artifact is PRESERVED and the failure is NAMED.
#
# PARTIAL FLIP to the NATIVE engine (docs/gsa-fixture-migration.md row
# `tests/log-ownership.sh`, Phase 2): this file now drives BOTH engines — the
# scenarios the Phase-2 engine expresses run the built `gsa` through
# run_engine (GSA_TEST_ENGINE=gsa) and assert on `format: 2` records
# (rr2_*), while the scenarios whose behaviour the engine does not implement
# yet keep driving the FROZEN fish oracle unchanged (tests/assets/, installed
# per scratch workspace by install_fish_oracle — docs/gsa-fixture-migration.md
# §3 fish-driven deviation, 2026-10-14; each marked with its engine gap
# below).
#
# Engine mapping (measured against crates/gsa-build/src/lane.rs and
# crates/gsa-sched/src/lock.rs — re-probe on mismatch):
#   * §J.5's quarantine (`<path>.stale.<epoch>.<pid>`, preserved + announced)
#     is the WRONG-OWNER branch of the write-time ownership gate: it needs a
#     foreign uid, which a fixture cannot produce without sudo (below). A
#     same-owner 0444 log is the gate's OTHER outcome — the lane publishes
#     `failed … log-unwritable` (§H.3 reason key) and the log content is
#     preserved byte-for-byte (the engine appends, never truncates). The
#     fish-era "quarantine-and-rebuild" round trip therefore re-pins as
#     preservation + naming (run record + `--lane-job` seam output), not as a
#     rebuild; the engine fails the lane closed instead.
#   * The stale runtime artifact sweep (fish R-F34) is `sweep_orphans` (§K.3):
#     under `runs/` it collects `*.tmp.*` and dead runs' abandoned
#     `.result`/`.park` files at run start (inside the run lock) and after the
#     run; the current run's own artifacts survive; unrelated makepkg
#     processes are never touched. The fish name shapes (`.pacman-shim.tmp.*`,
#     `toolchains/*.tmp.*`, `*.gsa-vcs-revisions.tmp.*`) are fish runtime
#     state the engine never creates.
#   * dispatcher.log is fish-only: the engine's forensics channel is the run
#     record (§H.1, emitted on the interrupt path). The dispatcher-forensics
#     meaning — what was running is honestly labelled, the children die —
#     re-pins from the record rows + ps, and the `--lane-job` spawn check
#     re-pins to the §D.1 seam spelling.
#
# Engine-gap sections, kept fish-driven on the FROZEN ORACLE until the
# surface lands (docs/gsa-fixture-migration.md §3 fish-driven deviation):
#   * unremovable-leftover naming (`cannot remove stale runtime artifact` +
#     `or: sudo rm -f <path>`): the engine's sweep is silent best-effort
#     (lock.rs `let _ = std::fs::remove_file`).
#   * root-mode chown repair (§J.5's root supervisor half): the engine has no
#     in-run root-repair path — `gsa -Md`'s wrong-owner rows stay report-only
#     even under `--fix` ("the root supervisor's startup repair owns that
#     remedy", crates/gsa-maint/src/doctor.rs; measured 2026-10-14, after
#     `-M` landed live at the Phase 5 cutover).
# No longer an engine gap (2026-10-14): the stale-listing shape below
# re-pins BEHAVIORALLY against `gsa -Ma` in the scratch workspace (§B.7's
# "stale runtime artifacts" family) — the fish-source grep retires per
# docs/gsa-fixture-migration.md §6 R-1.
#
# Portability note (fish sections): fixtures never use sudo, so a genuinely
# root-owned file cannot be produced here. A user-owned 0444 file is the same
# class for the FISH predicate (test -w by the build user; open-for-write
# fails with the same EACCES either way). For the ENGINE the two classes
# diverge by design (its ownership gate is uid-based), which is why the
# engine section pins `log-unwritable` while the root-mode branch needs real
# root and is argued in docs/NOTE.md.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-log-ownership.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf 'log-ownership: %s\n' "$1" >&2
    [[ $# -ge 2 ]] && printf '%s\n' "$2" >&2
    exit 1
}

# ─── The engine under test: built into the fixture tree (scratch only) ──────
cargo build --offline --quiet --target-dir "$fixture/cargo" -p gsa-cli \
    --manifest-path "$gsa_repo_root/Cargo.toml" \
    || fail "cannot build the gsa binary for the fixture"
gsa_bin="$fixture/cargo/debug/gsa"
[ -x "$gsa_bin" ] || fail "cargo did not produce $gsa_bin"
export GSA_TEST_ENGINE=gsa
export GSA_TEST_GSA_BIN="$gsa_bin"

# ─── Stub-knob vocabulary (§D.2: declared in the change that adds them) ─────
rr2_stub_knob GSA_FAKE_ENGINE_PID "log-ownership engine wrapper: pidfile of the engine process to signal"

make_case_workspace() { # $1 = sandbox dir
    local dir=$1
    make_workspace "$dir" 1 2 low
    add_package "$dir" p1 "$gsa_meta_any"

    cat >"$dir/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(basename "$PWD")
# Scenario knob (fixture-defined, like GSA_FAKE_FAIL_PACKAGE): hold the lane open
# so a signal can land mid-run while the dispatcher is alive.
sleep "${GSA_FAKE_BUILD_SLEEP:-0}"
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
printf 'fake makepkg %s\n' "$PWD"
exit 0
EOF
    chmod +x "$dir/bin/makepkg"

    stub_sudo "$dir"
}

# ─── Run B meets run A's poisoned log ────────────────────────────────────────
# Engine mapping (see header): the §J.5 gate quarantines only WRONG-OWNER
# state files (a foreign uid is unproducible fixture-side); a same-owner 0444
# log is the `log-unwritable` class (crates/gsa-build/src/lane.rs): the lane
# fails CLOSED, the run records `failed … log-unwritable` (§H.3), and the
# crashed run's content is preserved byte-for-byte — the engine opens logs
# append-only and this open fails, so nothing writes, nothing truncates,
# nothing renames.
(
    set -euo pipefail
    dir="$fixture/poisoned"
    make_case_workspace "$dir"
    mkdir -p "$dir/state/logs"
    sentinel='SENTINEL run-A crash evidence'
    printf '%s\n' "$sentinel" >"$dir/state/logs/p1.log"
    chmod 0444 "$dir/state/logs/p1.log" # the log-unwritable class (see header)

    export PATH="$dir/bin:$PATH"
    export GSA_CPU_THREADS=8 GSA_MEMORY_GIB=16
    run_engine "$dir" -B --leaf --state-dir "$dir/state" p1
    output=$FIXTURE_OUTPUT
    printf '%s\n' "$output" >"$dir/output.txt"

    # §G.1: a cone-stop run with a failed row exits 4 — the fish-era
    # "quarantine-and-rebuild rc 0" is not engine behaviour (header mapping).
    if [[ $FIXTURE_RC != 4 ]]; then
        fail "cone-stop run with a failed row must exit 4 (§G.1), got $FIXTURE_RC" "$dir/output.txt"
    fi
    if [[ $FIXTURE_RC != "$(rr2_scalar rc <<<"$output")" ]]; then
        fail "the record's rc scalar disagrees with the process exit code" "$dir/output.txt"
    fi
    # The failure is NAMED, in the record: not the fish-era "rc=125" lane row
    # (a lost reap), and not a plain build failure — the §H.3 reason key of
    # this class is `log-unwritable`.
    if [[ $(rr2_outcome p1 status <<<"$output") != failed ]]; then
        fail "the poisoned-log package is not recorded as failed:" "$dir/output.txt"
    fi
    if [[ $(rr2_outcome p1 rc <<<"$output") != 1 ]]; then
        fail "the log-unwritable class is lane code 1 (§F.1), not the fish-era 125:" "$dir/output.txt"
    fi
    if [[ $(rr2_outcome p1 reason <<<"$output") != log-unwritable ]]; then
        fail "want reason key 'log-unwritable' (§H.3), got '$(rr2_outcome p1 reason <<<"$output")':" "$dir/output.txt"
    fi
    remaining_rows=$(rr2_remaining <<<"$output" | tr '\n' ' ' | sed 's/ $//')
    if [[ $remaining_rows != "$(rr2_continuation remaining <<<"$output")" ]]; then
        fail "continuation remaining disagrees with the rows-derived set [$remaining_rows]" "$dir/output.txt"
    fi

    # KEEP (quarantine preservation → preservation): the crashed run's content
    # survives byte-for-byte at its path — never a silent truncate, never a
    # silent destroy, even though the run failed closed on it.
    log="$dir/state/logs/p1.log"
    if ! printf '%s\n' "$sentinel" | cmp -s - "$log"; then
        fail "the poisoned log lost the crashed run's content (silent truncate?)" \
            "$(cat "$log" 2>/dev/null)"
    fi
    # No quarantine rename happened: `.stale.<epoch>.<pid>` is the
    # WRONG-OWNER branch of the same §J.5 gate (header mapping) — a
    # same-owner 0444 file must take the log-unwritable path instead.
    shopt -s nullglob
    stale=("$dir"/state/logs/*.stale.*)
    shopt -u nullglob
    if ((${#stale[@]} != 0)); then
        fail "a same-owner poisoned log must take the log-unwritable path, not quarantine:" \
            "$(ls -la "$dir/state/logs")"
    fi

    # KEEP (named): the §D.1 seam names the preserved artifact — the direct
    # lane child publishes the typed row (`v2 …`, §F.2) and its diagnostic
    # names the log path (§L.3: seam output, not prose rendering).
    mkdir -p "$dir/seam"
    export GSA_STATE_DIR="$dir/state"
    run_engine "$dir" --lane-job p1 "$dir/seam/p1.result" 2
    if [[ $FIXTURE_RC != 1 ]]; then
        fail "a lane child's exit code IS its outcome code (§G.2), want 1, got $FIXTURE_RC" "$FIXTURE_OUTPUT"
    fi
    wire=$(cat "$dir/seam/p1.result" 2>/dev/null || true)
    if [[ $wire != "v2 p1 1 0 log-unwritable" ]]; then
        fail "want wire row 'v2 p1 1 0 log-unwritable' (§F.2/§H.3), got '$wire'"
    fi
    if ! grep -qF -- "$log" <<<"$FIXTURE_OUTPUT"; then
        fail "the seam diagnostic does not name the preserved log path" "$FIXTURE_OUTPUT"
    fi
)

# ─── interrupt forensics (dispatcher forensics re-pinned) ───────────────────
# The fish engine recorded signals in dispatcher.log (a poisoned one used to
# swallow the forensics behind its own 2>/dev/null). The engine has no
# dispatcher.log at all: its forensics channel is the RUN RECORD (§H.1,
# emitted on the interrupt path) plus honest lane rows. The KEEP meaning
# re-pins here: one SIGINT mid-build, and (a) what was running is honestly
# labelled (`interrupted … interrupted-mid-build`, never a build failure),
# (b) what never launched is told apart (`never-started …
# interrupted-before-start`), (c) the full record is emitted first and the run
# exits 130 (§G.1), and (d) the children die (§K.3). The lane-spawn check
# re-pins to the §D.1 seam spelling `gsa --lane-job <pkg> <result-path>
# <jobs> <flags…>`.
(
    set -euo pipefail
    dir="$fixture/interrupt"
    make_case_workspace "$dir"
    add_package "$dir" p2 "$gsa_meta_any"
    set_topology_record "$dir" p2 git p1 # p2 cannot start before p1 settles

    export PATH="$dir/bin:$PATH"
    export GSA_CPU_THREADS=8 GSA_MEMORY_GIB=16
    export GSA_FAKE_BUILD_SLEEP=30 # the stub holds the lane open for the signal

    # The engine needs one SIGINT mid-build; reach its PID through a one-line
    # wrapper that records its own pid before `exec` (gsa-sched-v2 §4
    # technique) — run_engine still performs the invocation.
    pidfile="$fixture/interrupt/engine.pid"
    argvfile="$fixture/interrupt/lane-argv.txt"
    wrap="$fixture/interrupt/gsa-wrap"
    cat >"$wrap" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$\$" > "\${GSA_FAKE_ENGINE_PID:?}"
exec "$gsa_bin" "\$@"
EOF
    chmod +x "$wrap"
    (
        for _ in $(seq 400); do [ -s "$pidfile" ] && break; sleep 0.025; done
        [ -s "$pidfile" ] || exit 0
        # Interrupt only while a lane is provably in flight (the stub makepkg
        # holds it open for 30 s). The captured lane argv is the §D.1 seam
        # spelling this section re-pins.
        for _ in $(seq 400); do
            if pgrep -f -- "--lane-job .*${dir}/state" >/dev/null 2>&1; then
                pgrep -af -- "--lane-job .*${dir}/state" >"$argvfile"
                break
            fi
            sleep 0.025
        done
        kill -INT "$(cat "$pidfile")" 2>/dev/null || true
    ) &
    watcher=$!
    GSA_TEST_GSA_BIN="$wrap" GSA_FAKE_ENGINE_PID="$pidfile" \
        run_engine "$dir" -B --leaf --state-dir "$dir/state" p1 p2
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    output=$FIXTURE_OUTPUT
    printf '%s\n' "$output" >"$dir/output.txt"

    # The lane was in flight, and its argv is the §D.1 seam spelling
    # `--lane-job <pkg> <result-path> <jobs>`.
    if [[ ! -s $argvfile ]]; then
        fail "lane child never spawned (cannot drive the signal scenario)" "$dir/output.txt"
    fi
    if ! grep -qF -- "--lane-job p1 $dir/state/runs/" "$argvfile"; then
        fail "the lane argv is not the §D.1 seam spelling --lane-job <pkg> <result-path> <jobs>:" \
            "$(cat "$argvfile")"
    fi
    if ! grep -qE -- '\.result [0-9]+$' "$argvfile"; then
        fail "the lane argv does not carry <result-path> <jobs>:" "$(cat "$argvfile")"
    fi

    # §G.1: an interrupted run exits 130 and the record agrees.
    if [[ $FIXTURE_RC != 130 ]]; then
        fail "an interrupted run exits 130 (§G.1), got $FIXTURE_RC" "$dir/output.txt"
    fi
    if [[ $FIXTURE_RC != "$(rr2_scalar rc <<<"$output")" ]]; then
        fail "the record's rc scalar disagrees with the process exit code" "$dir/output.txt"
    fi
    if [[ $(rr2_scalar outcome <<<"$output") != interrupted ]]; then
        fail "the record does not record outcome 'interrupted':" "$dir/output.txt"
    fi
    # The FULL record is emitted first (rr2_body parses every section).
    rr2_body <<<"$output" >/dev/null \
        || fail "the interrupted run emitted no complete run record:" "$dir/output.txt"
    for pkg in p1 p2; do
        if [[ -z $(rr2_plan "$pkg" plan <<<"$output") ]]; then
            fail "the interrupted record is missing the plan row of $pkg:" "$dir/output.txt"
        fi
    done
    # What was running is honestly labelled (§H.3): interrupted, not failed —
    # the fish dispatcher.log forensics line is retired as rendering (§L.3).
    if [[ $(rr2_outcome p1 status <<<"$output") != interrupted ]]; then
        fail "the in-flight package is not recorded as interrupted:" "$dir/output.txt"
    fi
    if ! rr2_outcome p1 rc <<<"$output" | grep -Eq '^(129|130|143)$'; then
        fail "an interrupted row's rc is not a signal lane code (§F.1):" "$dir/output.txt"
    fi
    if [[ $(rr2_outcome p1 reason <<<"$output") != interrupted-mid-build ]]; then
        fail "want reason key 'interrupted-mid-build' (§H.3), got '$(rr2_outcome p1 reason <<<"$output")':" "$dir/output.txt"
    fi
    # What never launched is told apart.
    if [[ $(rr2_outcome p2 status <<<"$output") != never-started ]]; then
        fail "the unlaunched package is not recorded as never-started:" "$dir/output.txt"
    fi
    if [[ $(rr2_outcome p2 reason <<<"$output") != interrupted-before-start ]]; then
        fail "want reason 'interrupted-before-start' (§H.3), got '$(rr2_outcome p2 reason <<<"$output")':" "$dir/output.txt"
    fi
    remaining_rows=$(rr2_remaining <<<"$output" | tr '\n' ' ' | sed 's/ $//')
    if [[ $remaining_rows != "$(rr2_continuation remaining <<<"$output")" ]]; then
        fail "continuation remaining disagrees with the rows-derived set [$remaining_rows]" "$dir/output.txt"
    fi

    # The children died (§K.3): nothing of this workspace survives teardown.
    if ps -eo args= | grep -F "$dir" | grep -v grep >/dev/null; then
        fail "a lane child of $dir survived the interrupt teardown" "$dir/output.txt"
    fi
)

# ─── Stale run-artifact sweep (§K.3; fish-era R-F34 re-mapped) ─────────────
# A crashed run leaves half-written runtime files behind. With the run lock
# held nothing alive can own them, so the engine's sweep_orphans
# (crates/gsa-sched/src/lock.rs) collects them at run start (before dispatch)
# and after the run: under `runs/` — `*.tmp.*` of any run plus dead runs'
# abandoned `.result`/`.park` files — and it reaps dead runs' `--lane-job`/
# `--fetch-job` processes; unrelated `makepkg` processes are never touched.
# The current run's own artifacts survive.
#
# Mapping from the fish shapes (header): `.pacman-shim.tmp.<pid>`,
# `toolchains/<pkg>.tmp.<pid>` and `<archive>.gsa-vcs-revisions.tmp.*` are
# fish runtime state the engine never creates (its state is `logs/<pkg>.log`,
# `runs/<run-id>/<pkg>.result`, `locks/`), so the KEEP meaning — crash
# leftovers are reaped at run start, loudly non-fatal, while the live run's
# own artifacts survive — re-pins against the `runs/` observable below. The
# unremovable-leftover naming half of R-F34 has NO engine equivalent (the
# sweep is silent best-effort) and keeps its fish-oracle section below.

# 1. behavioral: dead-run leftovers are swept at RUN START (the build-time
#    snapshot proves the sweep already ran before the first dispatch) while
#    the current run's own result and its fresh PACMAN shim (locks/pacman-shim,
#    no `.tmp.` in its name) survive.
(
    set -euo pipefail
    dir="$fixture/stale-sweep"
    make_case_workspace "$dir"
    mkdir -p "$dir/state/logs" "$dir/state/runs/dead-run"
    printf 'stale\n' >"$dir/state/runs/dead-run/dead.tmp.12345"
    printf 'stale\n' >"$dir/state/runs/dead-run/dead.result"
    printf 'stale\n' >"$dir/state/runs/dead-run/dead.park"
    mkdir -p "$dir/obs"

    # The scenario makepkg: snapshot the state tree at build time (a run-start
    # sweep has already happened by then), then build.
    cat >"$dir/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(basename "$PWD")
find "${GSA_STATE_DIR:?}" | sort >"${GSA_FAKE_DIR:?}/state-at-build"
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
printf 'fake makepkg %s\n' "$PWD"
exit 0
EOF
    chmod +x "$dir/bin/makepkg"

    export PATH="$dir/bin:$PATH"
    export GSA_CPU_THREADS=8 GSA_MEMORY_GIB=16
    export GSA_FAKE_DIR="$dir/obs"
    run_engine "$dir" -B --leaf --state-dir "$dir/state" p1
    output=$FIXTURE_OUTPUT
    printf '%s\n' "$output" >"$dir/output.txt"

    if [[ $FIXTURE_RC != 0 ]]; then
        fail "the trivial sweep run must succeed (the sweep is non-fatal), rc=$FIXTURE_RC" "$dir/output.txt"
    fi
    if [[ $(rr2_outcome p1 status <<<"$output") != succeeded ]]; then
        fail "the sweep run did not record p1 as succeeded:" "$dir/output.txt"
    fi
    # Run-start sweep: at build time the dead run's leftovers were already
    # gone — the sweep ran under the run lock, before any dispatch.
    if grep -qF 'dead-run' "$dir/obs/state-at-build"; then
        fail "dead-run leftovers survived until build time (sweep did not run at run start):" \
            "$(cat "$dir/obs/state-at-build")"
    fi
    if grep -qE '\.tmp\.' "$dir/obs/state-at-build"; then
        fail "a *.tmp.* leftover survived until build time:" \
            "$(cat "$dir/obs/state-at-build")"
    fi
    if [[ -e $dir/state/runs/dead-run ]]; then
        fail "the emptied dead-run directory survived the sweep: $dir/state/runs/dead-run" "$dir/output.txt"
    fi
    # The current run's own artifacts survive: its result row is that run's
    # record, not litter.
    own=("$dir"/state/runs/*/*.result)
    if ((${#own[@]} != 1)) || [[ ! -f ${own[0]} ]]; then
        fail "the current run's own result did not survive the sweep:" \
            "$(find "$dir/state/runs" | sort)"
    fi
    # …and the run's own fresh PACMAN shim survives (§K.3; no `.tmp.` in its
    # name — the engine's counterpart of the fish-era `.pacman-shim`).
    if [[ ! -f $dir/state/locks/pacman-shim ]]; then
        fail "the run's own PACMAN shim is gone — the sweep must collect *.tmp.* names only" \
            "$(ls -la "$dir/state/locks")"
    fi
)

# 1b. behavioral: the sweep's reach is BOUNDED — staging trees are excluded.
#     The fish-era `find -prune` vs `-not -path` implementation pin (now §6
#     R-1, retired) guarded this behaviour: the sweep must not descend into
#     VCS clones and build trees just to discard their hits — minutes of I/O
#     before the first dispatch. For the engine the swept scope is `runs/`
#     (§K.3), so the decoys carry the SWEPT NAME SHAPE (`*.tmp.*`) in the
#     out-of-scope trees and one swept-shape file inside `runs/` proves the
#     scenario still collects what it should. The decoys sit in p2, which the
#     run does not build: the build path itself legitimately wipes a built
#     recipe's src/pkg/build, which would race the assertion.
(
    set -euo pipefail
    dir="$fixture/stale-sweep-staging"
    make_case_workspace "$dir"
    add_package "$dir" p2 "$gsa_meta_any"
    mkdir -p "$dir/state/logs" "$dir/state/runs/dead-run" \
        "$dir/packages/p2/src/deep/clone" "$dir/packages/p2/build"
    printf 'stale\n' >"$dir/state/runs/dead-run/x.tmp.SWEPT"
    printf 'stale\n' >"$dir/packages/p2/src/deep/clone/x.tmp.DECOY1"
    printf 'stale\n' >"$dir/packages/p2/build/x.tmp.DECOY2"
    printf 'stale\n' >"$dir/state/logs/x.tmp.DECOY3"

    export PATH="$dir/bin:$PATH"
    export GSA_CPU_THREADS=8 GSA_MEMORY_GIB=16
    run_engine "$dir" -B --leaf --state-dir "$dir/state" p1
    output=$FIXTURE_OUTPUT
    printf '%s\n' "$output" >"$dir/output.txt"

    if [[ $FIXTURE_RC != 0 ]]; then
        fail "the decoy sweep run must succeed, rc=$FIXTURE_RC" "$dir/output.txt"
    fi
    if [[ -e $dir/state/runs/dead-run/x.tmp.SWEPT ]]; then
        fail "a swept-scope *.tmp.* leftover must be collected:" "$dir/output.txt"
    fi
    for decoy in \
        "$dir/packages/p2/src/deep/clone/x.tmp.DECOY1" \
        "$dir/packages/p2/build/x.tmp.DECOY2" \
        "$dir/state/logs/x.tmp.DECOY3"; do
        if [[ ! -e $decoy ]]; then
            fail "the sweep reached outside runs/ and removed: $decoy" "$dir/output.txt"
        fi
    done
)

# 2. KEPT FISH (engine gap): an unremovable leftover is named with its
#    operator command (rm -f fails inside a read-only directory) and never
#    breaks the run. The engine's sweep_orphans is silent best-effort
#    (`let _ = std::fs::remove_file`, crates/gsa-sched/src/lock.rs) and names
#    nothing, so this half of the R-F34 contract cannot flip yet — a
#    deliberate fish-driven deviation on the FROZEN ORACLE
#    (docs/gsa-fixture-migration.md §3, 2026-10-14), its fish argv unchanged.
dir="$fixture/stale-unremovable"
make_case_workspace "$dir"
install_fish_oracle "$dir" # §3 fish-driven deviation; frozen oracle (2026-10-14)
mkdir -p "$dir/state/logs/trapped"
printf 'stale\n' >"$dir/state/logs/trapped/f.tmp.9"
chmod 555 "$dir/state/logs/trapped" # rm -f needs write permission on the DIRECTORY

set +e
output=$(
    PATH="$dir/bin:$PATH" \
        GSA_STATE_DIR="$dir/state" \
        GSA_CPU_THREADS=8 \
        GSA_MEMORY_GIB=16 \
        fish "$dir/build-all.fish" --no-deps --allow-broken-rustc --no-sync p1 \
        2>&1
)
rc=$?
set -e
# Restore before any assertion can fail — the EXIT trap's rm -rf cannot
# unlink inside a 555 directory.
chmod 755 "$dir/state/logs/trapped"
if ((rc != 0)); then
    fail "an unremovable leftover must not break the run (the sweep is best-effort), rc=$rc" "$output"
fi
grep -q 'cannot remove stale runtime artifact' <<<"$output" ||
    fail "the unremovable leftover was silenced (want 'cannot remove stale runtime artifact')" "$output"
grep 'or: sudo rm -f' <<<"$output" |
    grep -F -- "$dir/state/logs/trapped/f.tmp.9" >/dev/null ||
    fail "the unremovable leftover carries no 'or: sudo rm -f <path>' operator line naming it" "$output"
if [[ ! -e $dir/state/logs/trapped/f.tmp.9 ]]; then
    fail "the read-only-directory leftover vanished — the scenario proved nothing" "$output"
fi

# 3. KEPT (re-pinned behaviorally, 2026-10-14): the audit's stale-artifact
#    listing must LIST the same name shapes the sweep collects. The
#    fish-source grep of the `--audit` "Stale runtime/error artifacts:"
#    section retires per docs/gsa-fixture-migration.md §6 R-1 (gsa is a
#    shipped binary; the root engine is a migration shim and lib/audit.fish
#    is gone), and the listing re-pins against `gsa -Ma` (§B.7's "stale
#    runtime artifacts" family) IN THE SCRATCH WORKSPACE ONLY — `-Ma` probes
#    installed packages and must never run against the real tree. Measured
#    2026-10-14: two `-Ma` runs over one planted workspace are byte-identical
#    (rc 0), so the minimal pin is one planted file per pinned name shape,
#    each named by its `stale-artifact` row.
(
    set -euo pipefail
    dir="$fixture/stale-listing"
    make_case_workspace "$dir"
    mkdir -p "$dir/state/logs" "$dir/packages/p1"
    printf 'stale\n' >"$dir/state/logs/y.tmp.9"
    printf 'stale\n' >"$dir/packages/p1/z.gsa-vcs-revisions.tmp.9"

    export PATH="$dir/bin:$PATH"
    run_engine "$dir" -Ma --state-dir "$dir/state"
    output=$FIXTURE_OUTPUT
    printf '%s\n' "$output" >"$dir/output.txt"

    # Report-only by contract (§E.4): exit 0, read the report.
    if [[ $FIXTURE_RC != 0 ]]; then
        fail "gsa -Ma is report-only (exit 0), rc=$FIXTURE_RC" "$dir/output.txt"
    fi
    grep -qF -- "stale-artifact $dir/state/logs/y.tmp.9 tmp-artifact" <<<"$output" ||
        fail "the audit stale listing no longer covers '*.tmp.*' state-dir leftovers" "$dir/output.txt"
    # `*.gsa-vcs-revisions.tmp.*` is fish runtime state the native engine
    # never creates (header) — the listing must still COVER it so legacy
    # package-tree litter stays reportable.
    grep -qF -- "stale-artifact $dir/packages/p1/z.gsa-vcs-revisions.tmp.9 vcs-revisions-tmp" <<<"$output" ||
        fail "the audit stale listing no longer covers '*.gsa-vcs-revisions.tmp.*' package-tree leftovers" "$dir/output.txt"
)

# (2026-10-12: the `find -prune` vs `-not -path` sweep-implementation greps
#  are retired WITHOUT replacement — docs/gsa-fixture-migration.md §6 R-1;
#  the staging-exclusion BEHAVIOUR keeps at section 1b above.)

printf 'log-ownership fixture: PASS\n'

# ==== log-ownership-root.sh ====
(

# Root-mode half of the 2026-09-23 log-ownership contract (the unprivileged
# half is pinned by the flipped engine sections above).
#
# KEPT FISH (engine gap): `gsa` has no root-repair path — §J.5's write-time
# ownership gate only quarantines wrong-owner files (the root-supervisor
# chown repair is a later phase: `gsa -Md`'s wrong-owner rows stay
# report-only even under `--fix`, crates/gsa-maint/src/doctor.rs, measured
# 2026-10-14). This whole section therefore keeps driving the FROZEN ORACLE
# (docs/gsa-fixture-migration.md §3 fish-driven deviation; row
# `tests/log-ownership.sh`).
#
# In root mode the supervisor's shell opens every log, so before the fix the
# per-package log was created root-owned at lane spawn and only repaired at
# package exit (chown -R "$_BUILD_USER": "$pkg_path" "$LOG_DIR") — an
# interrupted run left the in-flight logs poisoned for the next unprivileged
# run. The contract this fixture pins:
#   * ownership is decided at WRITE time: an unopenable log is repaired in
#     place (chown + owner-writable) BEFORE any redirect opens it, loudly;
#   * root mode repairs in place and NEVER quarantines — .stale.* renames are
#     the unprivileged recovery path only;
#   * nothing root-owned survives: the run completes rc=0 with the build
#     running as the invoking user.
#
# Portability: a fixture cannot create genuinely root-owned files without
# sudo, so the poison combines the real shape (0644) with a `stat` stub that
# reports owner "root" for exactly that path — the builder's root-mode
# predicate is `stat -c %U`, so it sees precisely what it would see on the
# real incident, while the file stays writable so the repaired run can
# actually write. The `id` stub makes the builder believe it runs under sudo
# (SUDO_USER set); the `chown` stub records every invocation (a real chown to
# the current owner would be a no-op anyway). Assertions key on a PER-FILE,
# non-`-R` chown naming the poisoned log plus the announced repair — the
# pre-write-time repair — which the startup/exit `chown -R` sweeps can never
# produce (they name directories, never the log file).

fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-log-ownership-root.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf 'log-ownership-root: %s\n' "$1" >&2
    [[ $# -ge 2 ]] && printf '%s\n' "$2" >&2
    exit 1
}

dir="$fixture/rootmode"
make_workspace "$dir" 2 2 low
install_fish_oracle "$dir" # §3 fish-driven deviation; frozen oracle (2026-10-14)
for id in p1 p2; do
    add_package "$dir" "$id" "$gsa_meta_any"
done

cat >"$dir/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(basename "$PWD")
mkdir -p "$GSA_FAKE_MARKER_DIR"
touch "$GSA_FAKE_MARKER_DIR/$id"
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
printf 'fake makepkg %s\n' "$PWD"
exit 0
EOF

# Pretend-root identity: `id -un` answers "root" only when the fixture asks
# for root mode; everything else falls through to the real id.
cat >"$dir/bin/id" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == -un && ${GSA_FAKE_ROOT_MODE:-0} == 1 ]]; then
    echo root
    exit 0
fi
exec /usr/bin/id "$@"
EOF

# Record every sudo invocation; `sudo -u <user> cmd…` drops the impersonation
# pair (the fixture really runs as the build user) and execs the rest. Leading
# sudo flags are dropped first (including --preserve-env, which host fish `sudo`
# wrapper functions inject).
cat >"$dir/bin/sudo" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GSA_FAKE_SUDO_LOG:?fixture forgot GSA_FAKE_SUDO_LOG}"
while [[ ${1:-} == -* ]]; do
    [[ ${1:-} == -u ]] && break
    shift
done
if [[ ${1:-} == -u && $# -ge 2 ]]; then
    shift 2
fi
((${#@})) || exit 0
exec "$@"
EOF

# Record every chown invocation and succeed. The helper's follow-up chmod
# (real, unstubbed) is what makes the poisoned file writable again; owner is
# already correct in the fixture, so a no-op chown + real chmod + stat
# verify is exactly the repair sequence asserted below.
cat >"$dir/bin/chown" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${GSA_FAKE_CHOWN_LOG:?fixture forgot GSA_FAKE_CHOWN_LOG}"
exit 0
EOF

# Lie about ownership of exactly one path: fixtures cannot chown to root, but
# the root-mode repair branch keys on `stat -c %U`. Every other stat (mtime
# skip-checks, %A/%a modes) falls through to the real binary.
cat >"$dir/bin/stat" <<'EOF'
#!/usr/bin/env bash
if [[ -n ${GSA_FAKE_ROOT_FILE:-} && ${1:-} == -c && ${2:-} == %U &&
    ${*: -1} == "$GSA_FAKE_ROOT_FILE" ]]; then
    echo root
    exit 0
fi
exec /usr/bin/stat "$@"
EOF

chmod +x "$dir/bin/makepkg" "$dir/bin/id" "$dir/bin/sudo" "$dir/bin/chown" \
    "$dir/bin/stat"

# Poison p1's log: run-A content, mode exactly like a real root-owned 0644
# log, owner reported as "root" by the stat stub (GSA_FAKE_ROOT_FILE).
mkdir -p "$dir/state/logs"
printf 'SENTINEL run-A crash evidence\n' >"$dir/state/logs/p1.log"

# Resolve the real user BEFORE the PATH prefix exists: bash expands prefixed
# assignments sequentially, so `id -un` inside the prefix would hit the stub
# (GSA_FAKE_ROOT_MODE is already set by then) and answer "root".
fixture_user=$(id -un)

set +e
output=$(
    PATH="$dir/bin:$PATH" \
        GSA_STATE_DIR="$dir/state" \
        GSA_FAKE_ROOT_MODE=1 \
        SUDO_USER="$fixture_user" \
        GSA_FAKE_SUDO_LOG="$dir/state/sudo.log" \
        GSA_FAKE_CHOWN_LOG="$dir/state/chown.log" \
        GSA_FAKE_ROOT_FILE="$dir/state/logs/p1.log" \
        GSA_FAKE_MARKER_DIR="$dir/state/built" \
        GSA_CPU_THREADS=8 \
        GSA_MEMORY_GIB=16 \
        fish "$dir/build-all.fish" --no-deps --allow-broken-rustc --no-sync p1 p2 \
        2>&1
)
rc=$?
set -e

if ((rc != 0)); then
    fail "root-mode run over a poisoned log must succeed via write-time repair, rc=$rc" "$output"
fi
if grep -q 'rc=125' <<<"$output"; then
    fail "misleading rc=125 lane row reappeared (log open failed before the build)" "$output"
fi
if grep -q 'An error occurred while redirecting file' <<<"$output"; then
    fail "fish redirect error escaped (the poisoned log was not repaired in time)" "$output"
fi
if ! grep -q 'repaired root-owned runtime file' <<<"$output"; then
    fail "write-time repair was not announced (must be loud, not silent)" "$output"
fi
if ! grep 'repaired root-owned runtime file' <<<"$output" |
    grep -F -- 'logs/p1.log' >/dev/null; then
    fail "repair announcement does not name the poisoned log" "$output"
fi

chownlog="$dir/state/chown.log"
[[ -f $chownlog ]] || fail "chown stub never invoked — no ownership repair ran" "$output"
# The pre-write-time repair: names the poisoned FILE, without -R (the exit
# chown -R names only directories and can never satisfy this).
if ! grep -v -- '-R' "$chownlog" | grep -F -- "logs/p1.log" >/dev/null; then
    fail "no per-file chown naming the poisoned log before it was opened:" \
        "$(cat "$chownlog")"
fi

# Root mode repairs IN PLACE — quarantine (.stale.*) is unprivileged-only.
shopt -s nullglob
stale=("$dir"/state/logs/*.stale.*)
shopt -u nullglob
if ((${#stale[@]} != 0)); then
    fail "root mode quarantined instead of repairing in place:" "$(ls -la "$dir/state/logs")"
fi

log="$dir/state/logs/p1.log"
[[ -w $log ]] || fail "log still not writable after repair: $log"
if ! grep -q 'fake makepkg' "$log"; then
    fail "build log missing stub makepkg output — the build never ran" \
        "$(cat "$log" 2>/dev/null)"
fi
for id in p1 p2; do
    [[ -f $dir/state/built/$id ]] ||
        fail "package $id never built — repair must not abort the run" "$output"
done

printf 'log-ownership-root fixture: PASS\n'
)
