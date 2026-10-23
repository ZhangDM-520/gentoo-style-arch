#!/usr/bin/env bash
set -euo pipefail

# The run record — the machine block's contract, `format: 2`
# (docs/gsa-contract.md §H), driven through the NATIVE engine (`gsa`).
# Everything is synthetic: $TMPDIR workspaces with stub `makepkg`
# executables, no package is built, no pacman transaction runs.
#
# Behaviour kept from the fish-era fixture: ONE record on every exit path
# (success, failure, refusal-before-dispatch, deferral, interrupt), one
# outcome row per selected package in the `order:` sequence, the row's rc is
# the lane's own outcome code, and the continuation's `remaining:` is the
# resume set (the non-succeeded rows in row order).
#
# Pinned here (five ( subshell ) sections + an enum closure):
#   1. block shape + scalars — the markers exactly once each, `format: 2`,
#      the fixed-order scalars (selection-source / order / lanes /
#      normal-jobs / core-jobs / intensity / outcome / rc) over a
#      deterministic plan (--lanes 1 --jobs 2 --intensity low), one plan row
#      and one outcome row per selected package;
#   2. failure under --fail-fast (§I.3 — the fish-era failure policy): rc 1,
#      the failed row's rc is the lane's own 1, unstarted rows are
#      `never-started dispatch-stopped`, and the resume set is the failed
#      package BEFORE the unattempted one (a failed package must rebuild
#      before its dependents);
#   3. refusal before dispatch (§G.1 rc 3): nothing starts, every row is
#      `never-started`, everything remains. NOTE (gap G8): this pins the
#      record the engine actually emits on a refusal path — a FULL §H.2
#      record with plan rows — and the reason key that path produces;
#   4. deferral (the lane rc-99 amendment) and its parked dependent: the
#      deferring row is `deferred 99 …` (the rc is DATA in the row), only its
#      consumers park (`parked waits-on-deferred`), unrelated work builds,
#      and the run exits §G.1's deferral-only 5;
#   5. interrupt: one SIGINT mid-build tears the run down, the FULL record
#      (plan, outcomes, continuation) is emitted first, rc 130.
#
# Flip notes (docs/gsa-fixture-migration.md row `tests/run-record.sh`):
# the fish argv (`--no-deps`/`--no-sync`/`--allow-broken-rustc`) retires for
# the §B grammar: the scenarios are build-only (`gsa -B`), `--no-deps`
# becomes `--leaf`, and `--no-sync`/`--allow-broken-rustc` are dropped —
# neither is deferred to anything observable here (no version-sync provider,
# no rustc probe) and gsa refuses both spellings. The format: 1 rr_* pins
# re-pin through rr2_* against the format: 2 block (§H.2); exit codes follow
# §G.1 (fail-fast failure 1, refusal 3, deferral-only 5, interrupt 130).
# §6 R-2: the format:1 single-token reason rule is retired WITHOUT
# replacement — the v2 reason is the remainder of the row and rr2_body
# enforces that grammar (tests/gsa-v2-lib.sh pins the parser), so the old
# REASONS whitelist is gone (§L.2 makes reason keys additive anyway).
# §6 R-4: `blocked` is superseded by `parked` + reason `waits-on-deferred`
# (§H.3) — the behaviour is unchanged, only the spelling moved.
# Engine-coupled reason keys the fish triggers produced are re-driven on the
# engine's own paths and pin what the engine prints (gap G2/G8 evidence):
# the deferral trigger is now a makepkg rc-99 lane (reason
# `source-unfetchable` — the engine's only deferral key, lane.rs:7-10; the
# fish-era `anchoring-refused` anchor flow is not producible through a stub),
# and the refusal-before-dispatch trigger is a broken state root (reason
# `startup-refused`; `preflight-refused` is the -S sudo-preflight key and a
# build-only run cannot reach it). The run-level `outcome` scalar values are
# pinned per scenario as observed (gap G2: no contract vocabulary).
# The interrupted row's rc is the LANE's signal code (§H.3: 129/130/143) —
# teardown's SIGTERM makes it 143 in practice — while the run rc is INT's
# own 130 (§G.1).

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-run-record.XXXXXX")
# root-safe cleanup: engine state under $fixture is root-owned (W5 §B.10)
trap '/usr/bin/sudo -n rm -rf -- "$fixture" 2>/dev/null || rm -rf -- "$fixture" 2>/dev/null || true' EXIT

fail() {
    printf 'run record fixture: %s\n' "$1" >&2
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
        sed 's/^/    /' "$2" >&2
    fi
    exit 1
}

# ─── Stub-knob vocabulary (§D.2: declared in the change that adds them) ────
rr2_stub_knob GSA_FAKE_DEFER_PACKAGE "run-record makepkg stub: package id whose build exits 99 (deferral)"
rr2_stub_knob GSA_FAKE_ENGINE_PID "run-record engine wrapper: pidfile of the engine process to signal"

# ─── The engine under test: the INSTALLED binary (contract §L.10);
# GSA_TEST_GSA_BIN is the explicit pre-install override (rr-v2.bash) ──────────────────────
if [ -z "${GSA_TEST_GSA_BIN:-}" ]; then
    GSA_TEST_GSA_BIN=$(command -v gsa) || {
        printf 'contract §L.10: no installed gsa on PATH — install gsa-pm, or set GSA_TEST_GSA_BIN explicitly\n' >&2
        exit 1
    }
fi
gsa_bin="$GSA_TEST_GSA_BIN"
[ -x "$gsa_bin" ] || fail "the engine under test is not executable: $gsa_bin"
export GSA_TEST_ENGINE=gsa
export GSA_TEST_GSA_BIN="$gsa_bin"

# ─── Oracle helpers (inline: §D.2 keeps oracles in the fixture that gives
# them meaning) ─────────────────────────────────────────────────────────────

# write_stub_makepkg DIR — the scenario makepkg: a start marker for interrupt
# timing, one optional sleep, then the outcome the GSA_FAKE_* knobs name
# (fail 1 / defer 99 / else ok + archive).
write_stub_makepkg() {
    cat >"$1/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -eu
id=$(basename "$PWD")
[ -n "${GSA_FAKE_MARKER_DIR:-}" ] && : >"$GSA_FAKE_MARKER_DIR/$id"
sleep "${GSA_FAKE_BUILD_SECONDS:-0}"
if [ "${GSA_FAKE_FAIL_PACKAGE:-}" = "$id" ]; then exit 1; fi
if [ "${GSA_FAKE_DEFER_PACKAGE:-}" = "$id" ]; then exit 99; fi
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
exit 0
EOF
    chmod +x "$1/bin/makepkg"
}

# make_case_workspace DIR — three no-edge packages p1 p2 p3, one lane, the
# deterministic plan the scalar pins quote (lanes=1 jobs=2 intensity=low).
make_case_workspace() {
    local dir=$1 id
    make_workspace "$dir" 1 2 low
    for id in p1 p2 p3; do
        add_package "$dir" "$id" "$gsa_meta_any" git
    done
    write_stub_makepkg "$dir"
}

# The §H.3 status enum, produced END TO END by the scenarios below (the
# closure at the end proves it). The format:1 row-grammar/whitelist helpers
# retired: rr2_body IS the grammar test now, and §L.2 keeps the reason-key
# vocabulary additive, so per-scenario field pins carry the reasons.
STATUSES='succeeded failed deferred parked never-started interrupted'
seen_statuses=$fixture/seen-statuses
: >"$seen_statuses"

# record_ok OUT — one record on every exit path: the block markers exactly
# once each and the whole block parses under the strict `format: 2` grammar
# (scalars, plan rows, outcome rows, continuation).
record_ok() {
    local out=$1
    [ "$(grep -c '^--- run record begin ---$' "$out")" -eq 1 ] ||
        fail "$out: the block begin marker is not printed exactly once"
    [ "$(grep -c '^--- run record end ---$' "$out")" -eq 1 ] ||
        fail "$out: the block end marker is not printed exactly once"
    rr2_body <"$out" >/dev/null ||
        fail "$out: the run record does not parse as a complete format: 2 block" "$out"
}

# record_statuses OUT — accumulate the observed status enum for the closure.
record_statuses() {
    rr2_outcome_rows <"$1" | awk '{print $2}' >>"$seen_statuses"
}

# assert_rc RECORD-FILE — the process exit code IS the record's rc scalar.
assert_rc() {
    [ "$FIXTURE_RC" = "$(rr2_scalar rc <"$1")" ] ||
        fail "process exit $FIXTURE_RC disagrees with the record's rc scalar:" "$1"
}

# remaining_matches OUT — the continuation's `remaining:` is exactly the
# resume set the outcome rows imply (non-succeeded, in row order).
remaining_matches() {
    local out=$1 rows line
    rows=$(rr2_remaining <"$out" | tr '\n' ' ' | sed 's/ $//')
    line=$(rr2_continuation remaining <"$out")
    [ "$rows" = "$line" ] ||
        fail "continuation remaining [$line] != rows-derived remaining [$rows]:" "$out"
    printf '%s\n' "$rows"
}

# ─── 1. Success: block shape, scalars, one row per package ──────────────────
(
    set -euo pipefail
    ws="$fixture/success/ws"
    make_case_workspace "$ws"
    export PATH="$ws/bin:$PATH"
    export GSA_CPU_THREADS=8 GSA_MEMORY_GIB=16

    run_engine "$ws" -B --leaf --lanes 1 --jobs 2 --intensity low \
        --state-dir "$fixture/success/state" p1 p2 p3
    printf '%s\n' "$FIXTURE_OUTPUT" >"$fixture/s1.out"

    [ "$FIXTURE_RC" = 0 ] || fail "the all-success run exited $FIXTURE_RC:" "$fixture/s1.out"
    assert_rc "$fixture/s1.out"
    record_ok "$fixture/s1.out"
    record_statuses "$fixture/s1.out"

    # The fixed-order scalar set (§H.2); the budget values are the argv's
    # own overrides (--lanes 1 --jobs 2), not profile arithmetic.
    [ "$(rr2_scalar format <"$fixture/s1.out")" = 2 ] ||
        fail "unexpected record format:" "$fixture/s1.out"
    [ "$(rr2_scalar selection-source <"$fixture/s1.out")" = 'sets=p1,p2,p3 leaf=yes range=-' ] ||
        fail "selection-source wrong: $(rr2_scalar selection-source <"$fixture/s1.out")" "$fixture/s1.out"
    [ "$(rr2_scalar order <"$fixture/s1.out")" = 'p1 p2 p3' ] ||
        fail "order wrong: $(rr2_scalar order <"$fixture/s1.out")" "$fixture/s1.out"
    [ "$(rr2_scalar lanes <"$fixture/s1.out")" = 1 ] ||
        fail "lanes scalar wrong: $(rr2_scalar lanes <"$fixture/s1.out")" "$fixture/s1.out"
    [ "$(rr2_scalar normal-jobs <"$fixture/s1.out")" = 2 ] ||
        fail "normal-jobs scalar wrong: $(rr2_scalar normal-jobs <"$fixture/s1.out")" "$fixture/s1.out"
    [ "$(rr2_scalar core-jobs <"$fixture/s1.out")" = 2 ] ||
        fail "core-jobs scalar wrong: $(rr2_scalar core-jobs <"$fixture/s1.out")" "$fixture/s1.out"
    [ "$(rr2_scalar intensity <"$fixture/s1.out")" = low ] ||
        fail "intensity scalar wrong: $(rr2_scalar intensity <"$fixture/s1.out")" "$fixture/s1.out"
    # gap G2: the run-level outcome vocabulary is opaque — pin the value the
    # engine prints for this scenario class.
    [ "$(rr2_scalar outcome <"$fixture/s1.out")" = success ] ||
        fail "outcome wrong: $(rr2_scalar outcome <"$fixture/s1.out")" "$fixture/s1.out"

    # One plan row and one outcome row per selected package; row sequence
    # agreement with `order:` is the parser's cross-check (§C.5), the field
    # meanings are pinned here.
    [ "$(rr2_plan_rows <"$fixture/s1.out" | wc -l)" -eq 3 ] ||
        fail "expected 3 plan rows for 3 packages:" "$fixture/s1.out"
    [ "$(rr2_outcome_rows <"$fixture/s1.out" | wc -l)" -eq 3 ] ||
        fail "expected 3 outcome rows for 3 packages:" "$fixture/s1.out"
    for id in p1 p2 p3; do
        [ "$(rr2_plan "$id" plan <"$fixture/s1.out")" = build ] ||
            fail "$id is not planned as a plain build:" "$fixture/s1.out"
        [ "$(rr2_outcome "$id" status <"$fixture/s1.out")" = succeeded ] ||
            fail "$id did not succeed: $(rr2_outcome "$id" <"$fixture/s1.out")" "$fixture/s1.out"
        [ "$(rr2_outcome "$id" rc <"$fixture/s1.out")" = 0 ] ||
            fail "$id succeeded with rc $(rr2_outcome "$id" rc <"$fixture/s1.out")" "$fixture/s1.out"
        [ "$(rr2_outcome "$id" reason <"$fixture/s1.out")" = ok ] ||
            fail "$id reason wrong: $(rr2_outcome "$id" reason <"$fixture/s1.out")" "$fixture/s1.out"
    done

    # A clean run resumes nothing.
    [ -z "$(remaining_matches "$fixture/s1.out")" ] ||
        fail "a clean run must leave an empty resume set:" "$fixture/s1.out"

    # The continuation mirrors the run's own flags (§H.2) and never the
    # hidden seams.
    command=$(rr2_continuation command <"$fixture/s1.out")
    for flag in '--leaf' '--lanes 1' '--jobs 2' '--intensity low'; do
        case "$command" in
        *"$flag"*) ;;
        *) fail "continuation command dropped '$flag': $command" "$fixture/s1.out" ;;
        esac
    done
    for seam in --lane-job --stale-lock-check --install-decide --fetch-job; do
        rr2_continuation not-mirrored <"$fixture/s1.out" | tr ' ' '\n' | grep -Fx -- "$seam" >/dev/null \
            || fail "hidden seam $seam is not in the not-mirrored list:" "$fixture/s1.out"
    done
)

# ─── 2. Failure under --fail-fast: rc 1, dispatch stopped, resume set ───────
(
    set -euo pipefail
    ws="$fixture/failfast/ws"
    make_case_workspace "$ws"
    export PATH="$ws/bin:$PATH"
    export GSA_CPU_THREADS=8 GSA_MEMORY_GIB=16
    export GSA_FAKE_FAIL_PACKAGE=p2

    run_engine "$ws" -B --leaf --fail-fast --lanes 1 --jobs 2 --intensity low \
        --state-dir "$fixture/failfast/state" p1 p2 p3
    printf '%s\n' "$FIXTURE_OUTPUT" >"$fixture/s2.out"

    # §G.1: a build failure under --fail-fast is rc 1 (that code means
    # dispatch stopped; the default cone-stop policy would exit 4 — pinned
    # in tests/gsa-sched-v2.sh §1, deliberately not duplicated here).
    [ "$FIXTURE_RC" = 1 ] || fail "the failing run exited $FIXTURE_RC, want 1 (§G.1):" "$fixture/s2.out"
    assert_rc "$fixture/s2.out"
    record_ok "$fixture/s2.out"
    record_statuses "$fixture/s2.out"
    [ "$(rr2_scalar outcome <"$fixture/s2.out")" = failed ] ||
        fail "outcome wrong: $(rr2_scalar outcome <"$fixture/s2.out")" "$fixture/s2.out"

    [ "$(rr2_outcome p1 status <"$fixture/s2.out")" = succeeded ] ||
        fail "p1 row wrong: $(rr2_outcome p1 <"$fixture/s2.out")" "$fixture/s2.out"
    [ "$(rr2_outcome p2 status <"$fixture/s2.out")" = failed ] ||
        fail "p2 row wrong: $(rr2_outcome p2 <"$fixture/s2.out")" "$fixture/s2.out"
    # The row's rc is the lane's own exit status, not a summary guess.
    [ "$(rr2_outcome p2 rc <"$fixture/s2.out")" = 1 ] ||
        fail "p2 row rc is $(rr2_outcome p2 rc <"$fixture/s2.out"), want the makepkg status 1" "$fixture/s2.out"
    [ "$(rr2_outcome p2 reason <"$fixture/s2.out")" = build-failed ] ||
        fail "p2 reason wrong: $(rr2_outcome p2 reason <"$fixture/s2.out")" "$fixture/s2.out"
    [ "$(rr2_outcome p3 status <"$fixture/s2.out")" = never-started ] ||
        fail "p3 row wrong: $(rr2_outcome p3 <"$fixture/s2.out")" "$fixture/s2.out"
    [ "$(rr2_outcome p3 reason <"$fixture/s2.out")" = dispatch-stopped ] ||
        fail "p3 reason wrong: $(rr2_outcome p3 reason <"$fixture/s2.out")" "$fixture/s2.out"
    [ "$(rr2_outcome p3 rc <"$fixture/s2.out")" = - ] && [ "$(rr2_outcome p3 dur <"$fixture/s2.out")" = - ] ||
        fail "p3 never ran but carries rc/dur: $(rr2_outcome p3 <"$fixture/s2.out")" "$fixture/s2.out"

    # The resume set is the failed package BEFORE the unattempted one — a
    # failed package must rebuild before its dependents (2026-09-26).
    [ "$(remaining_matches "$fixture/s2.out")" = 'p2 p3' ] ||
        fail "resume set wrong: $(rr2_remaining <"$fixture/s2.out" | tr '\n' ' ')" "$fixture/s2.out"

    # The continuation restates the run's flags and ends with the resume set
    # (the fish-era prose suggestion, re-pinned from the record's fields).
    command=$(rr2_continuation command <"$fixture/s2.out")
    for flag in '--leaf' '--fail-fast' '--lanes 1' '--jobs 2' '--intensity low'; do
        case "$command" in
        *"$flag"*) ;;
        *) fail "continuation command dropped '$flag': $command" "$fixture/s2.out" ;;
        esac
    done
    case "$command" in
    *' p2 p3') ;;
    *) fail "continuation command does not end with the resume set: $command" "$fixture/s2.out" ;;
    esac
)

# ─── 3. Refusal before dispatch: rc 3, nothing starts, everything remains ───
(
    set -euo pipefail
    ws="$fixture/refusal/ws"
    make_case_workspace "$ws"
    export PATH="$ws/bin:$PATH"
    export GSA_CPU_THREADS=8 GSA_MEMORY_GIB=16
    # A regular file where the state root must be created: the engine's
    # startup refusal fires before any dispatch (refuse_before_dispatch,
    # build.rs) — the gsa successor of the fish-era sudo preflight refusal.
    : >"$fixture/refusal/not-a-dir"

    run_engine "$ws" -B --leaf --lanes 1 --jobs 2 --intensity low \
        --state-dir "$fixture/refusal/not-a-dir" p1 p2 p3
    printf '%s\n' "$FIXTURE_OUTPUT" >"$fixture/s3.out"

    [ "$FIXTURE_RC" = 3 ] || fail "the refused run exited $FIXTURE_RC, want 3 (§G.1):" "$fixture/s3.out"
    assert_rc "$fixture/s3.out"
    # gap G8 probe: the engine's refusal record IS the full §H.2 shape (plan
    # rows included), so the strict parser accepts it unweakened.
    record_ok "$fixture/s3.out"
    record_statuses "$fixture/s3.out"
    [ "$(rr2_scalar outcome <"$fixture/s3.out")" = refused ] ||
        fail "outcome wrong: $(rr2_scalar outcome <"$fixture/s3.out")" "$fixture/s3.out"
    for id in p1 p2 p3; do
        [ "$(rr2_plan "$id" plan <"$fixture/s3.out")" = build ] ||
            fail "$id is missing its plan row in the refusal record:" "$fixture/s3.out"
        # `startup-refused` is the additive key this refusal path carries
        # (the fish-era `preflight-refused` key belongs to the -S sudo
        # preflight, which a build-only run cannot reach).
        [ "$(rr2_outcome "$id" <"$fixture/s3.out")" = "$id never-started - - startup-refused" ] ||
            fail "$id row wrong: $(rr2_outcome "$id" <"$fixture/s3.out")" "$fixture/s3.out"
    done
    # Everything was refused, so everything must remain.
    [ "$(remaining_matches "$fixture/s3.out")" = 'p1 p2 p3' ] ||
        fail "resume set wrong: $(rr2_remaining <"$fixture/s3.out" | tr '\n' ' ')" "$fixture/s3.out"
)

# ─── 4. Deferral (rc 99): not a failure, parks only its consumers, rc 5 ─────
(
    set -euo pipefail
    ws="$fixture/defer/ws"
    make_workspace "$ws" 1 2 low
    add_package "$ws" defer-a "$gsa_meta_any" git
    add_package "$ws" dep-b "$gsa_meta_any" git
    add_package "$ws" plain-c "$gsa_meta_any" git
    # dep-b consumes defer-a over a build-order edge — its park's reason.
    set_topology_record "$ws" dep-b git defer-a
    write_stub_makepkg "$ws"
    export PATH="$ws/bin:$PATH"
    export GSA_CPU_THREADS=8 GSA_MEMORY_GIB=16
    export GSA_FAKE_DEFER_PACKAGE=defer-a

    run_engine "$ws" -B --leaf --lanes 1 --jobs 2 --intensity low \
        --state-dir "$fixture/defer/state" defer-a dep-b plain-c
    printf '%s\n' "$FIXTURE_OUTPUT" >"$fixture/s4.out"

    [ "$FIXTURE_RC" = 5 ] || fail "the deferral-only run exited $FIXTURE_RC, want 5 (§G.1):" "$fixture/s4.out"
    assert_rc "$fixture/s4.out"
    record_ok "$fixture/s4.out"
    record_statuses "$fixture/s4.out"
    [ "$(rr2_scalar outcome <"$fixture/s4.out")" = deferral ] ||
        fail "outcome wrong: $(rr2_scalar outcome <"$fixture/s4.out")" "$fixture/s4.out"

    # The rc-99 amendment is DATA in the row, not folklore: deferred, not
    # failed and not parked.
    [ "$(rr2_outcome defer-a status <"$fixture/s4.out")" = deferred ] ||
        fail "defer-a row wrong: $(rr2_outcome defer-a <"$fixture/s4.out")" "$fixture/s4.out"
    [ "$(rr2_outcome defer-a rc <"$fixture/s4.out")" = 99 ] ||
        fail "defer-a row rc is $(rr2_outcome defer-a rc <"$fixture/s4.out"), want 99" "$fixture/s4.out"
    # The engine's only deferral reason key (the fish-era anchoring-refused
    # trigger is not producible through a makepkg stub — flip notes above).
    [ "$(rr2_outcome defer-a reason <"$fixture/s4.out")" = source-unfetchable ] ||
        fail "defer-a reason wrong: $(rr2_outcome defer-a reason <"$fixture/s4.out")" "$fixture/s4.out"

    # §6 R-4: the `blocked` spelling is superseded by `parked` + the
    # waits-on-deferred reason (§H.3); the deferral semantics are unchanged.
    [ "$(rr2_outcome dep-b status <"$fixture/s4.out")" = parked ] ||
        fail "dep-b row wrong: $(rr2_outcome dep-b <"$fixture/s4.out")" "$fixture/s4.out"
    [ "$(rr2_outcome dep-b reason <"$fixture/s4.out")" = waits-on-deferred ] ||
        fail "dep-b reason wrong: $(rr2_outcome dep-b reason <"$fixture/s4.out")" "$fixture/s4.out"
    [ "$(rr2_outcome dep-b rc <"$fixture/s4.out")" = - ] ||
        fail "dep-b never ran but carries rc: $(rr2_outcome dep-b <"$fixture/s4.out")" "$fixture/s4.out"

    # The dispatch CONTINUED around the parked pair: plain-c built.
    [ "$(rr2_outcome plain-c status <"$fixture/s4.out")" = succeeded ] ||
        fail "plain-c row wrong: $(rr2_outcome plain-c <"$fixture/s4.out")" "$fixture/s4.out"

    [ "$(remaining_matches "$fixture/s4.out")" = 'defer-a dep-b' ] ||
        fail "resume set wrong: $(rr2_remaining <"$fixture/s4.out" | tr '\n' ' ')" "$fixture/s4.out"
)

# ─── 5. Interrupt: full record + continuation on the 130 path ───────────────
(
    set -euo pipefail
    ws="$fixture/interrupt/ws"
    make_case_workspace "$ws"
    export PATH="$ws/bin:$PATH"
    export GSA_CPU_THREADS=8 GSA_MEMORY_GIB=16
    # Event markers: the fixture waits for p1's start before signalling INT,
    # so the interrupt deterministically lands mid-build instead of racing
    # the pre-dispatch phase on wall-clock time.
    markerdir="$fixture/interrupt/markers"
    mkdir -p "$markerdir"
    export GSA_FAKE_MARKER_DIR="$markerdir"
    export GSA_FAKE_BUILD_SECONDS=20

    # The engine needs one SIGINT mid-build: run_engine performs the
    # invocation while a watcher signals the engine PID this wrapper records
    # (`exec` keeps the pid) once the stub build is provably in flight.
    pidfile="$fixture/interrupt/engine.pid"
    wrap="$fixture/interrupt/gsa-wrap"
    cat >"$wrap" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$\$" > "\${GSA_FAKE_ENGINE_PID:?}"
exec "$gsa_bin" "\$@"
EOF
    chmod +x "$wrap"
    (
        for _ in $(seq 1 400); do [ -s "$pidfile" ] && break; sleep 0.025; done
        [ -s "$pidfile" ] || exit 0
        for _ in $(seq 1 400); do [ -f "$markerdir/p1" ] && break; sleep 0.025; done
        # the engine is root under W5 (run_engine's sudo) — signal it through
        # the host's REAL sudo, never the PATH stub
        /usr/bin/sudo -n kill -INT "$(cat "$pidfile")" 2>/dev/null || true
    ) &
    watcher=$!
    GSA_TEST_GSA_BIN="$wrap" GSA_FAKE_ENGINE_PID="$pidfile" \
        run_engine "$ws" -B --leaf --lanes 1 --jobs 2 --intensity low \
        --state-dir "$fixture/interrupt/state" p1 p2 p3
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    printf '%s\n' "$FIXTURE_OUTPUT" >"$fixture/s5.out"

    # the signal landed mid-build (the stub had started)
    [ -f "$markerdir/p1" ] || fail "the interrupt did not land mid-build (no start marker)" "$fixture/s5.out"

    # An interrupted run exits with the signal's own status — INT's 130
    # (§G.1) — with the full record emitted first.
    [ "$FIXTURE_RC" = 130 ] || fail "the interrupted run exited $FIXTURE_RC, want 130:" "$fixture/s5.out"
    assert_rc "$fixture/s5.out"
    record_ok "$fixture/s5.out"
    record_statuses "$fixture/s5.out"
    [ "$(rr2_scalar outcome <"$fixture/s5.out")" = interrupted ] ||
        fail "outcome wrong: $(rr2_scalar outcome <"$fixture/s5.out")" "$fixture/s5.out"

    # The package in flight is interrupted-mid-build with the LANE's signal
    # code as its row rc (§H.3: 129/130/143 — teardown's SIGTERM makes 143
    # the observed value); the rest were never dispatched — and both facts
    # are in the record, not just in prose.
    [ "$(rr2_outcome p1 status <"$fixture/s5.out")" = interrupted ] ||
        fail "p1 row wrong: $(rr2_outcome p1 <"$fixture/s5.out")" "$fixture/s5.out"
    grep < <(rr2_outcome p1 rc <"$fixture/s5.out") -Eq '^(129|130|143)$' ||
        fail "an interrupted row's rc is not a signal lane code (§F.1): $(rr2_outcome p1 <"$fixture/s5.out")" "$fixture/s5.out"
    [ "$(rr2_outcome p1 reason <"$fixture/s5.out")" = interrupted-mid-build ] ||
        fail "p1 reason wrong: $(rr2_outcome p1 reason <"$fixture/s5.out")" "$fixture/s5.out"
    for id in p2 p3; do
        [ "$(rr2_outcome "$id" <"$fixture/s5.out")" = "$id never-started - - interrupted-before-start" ] ||
            fail "$id row wrong: $(rr2_outcome "$id" <"$fixture/s5.out")" "$fixture/s5.out"
    done

    # Continuation output on the interrupt path (the fish-era run used to
    # exit 130 with nothing to resume by): the command carries the plan
    # triple + the semantics flags the run used, and ends with the resume
    # set in row order; `remaining:` agrees with the rows.
    [ "$(remaining_matches "$fixture/s5.out")" = 'p1 p2 p3' ] ||
        fail "resume set wrong: $(rr2_remaining <"$fixture/s5.out" | tr '\n' ' ')" "$fixture/s5.out"
    command=$(rr2_continuation command <"$fixture/s5.out")
    for flag in '--leaf' '--lanes 1' '--jobs 2' '--intensity low'; do
        case "$command" in
        *"$flag"*) ;;
        *) fail "interrupted-run continuation dropped '$flag': $command" "$fixture/s5.out" ;;
        esac
    done
    case "$command" in
    *' p1 p2 p3') ;;
    *) fail "continuation command does not end with the resume set: $command" "$fixture/s5.out" ;;
    esac
)

# ─── 6. Enum closure: every §H.3 status was produced by some scenario ───────
for status in $STATUSES; do
    grep -qx "$status" "$seen_statuses" ||
        fail "status '$status' was never produced by any scenario — the enum pin is incomplete"
done

printf 'run record fixture: PASS (format: 2 block, scalars, rows, enum, continuation incl. interrupt 130)\n'
