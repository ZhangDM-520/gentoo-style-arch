#!/usr/bin/env bash
set -euo pipefail

# tests/gsa-sched-v2.sh — Phase-2 scheduler semantics of the NATIVE engine
# (`gsa`, docs/gsa-contract.md §D/§F/§G/§H/§I/§K). Everything here is
# synthetic: $TMPDIR workspaces with stub `makepkg` executables, no package
# is built, no pacman transaction runs, nothing outside the fixture tree is
# written. Expectations are DERIVED from the topology the fixture wrote and
# the run record the run produced (rule 25(j) / contract §L.3) — never from
# pinned counts: cone membership is a transitive-closure computation over the
# fixture's own build-order edges, the expected exit code is computed from
# the outcome rows by §G.1's precedence, and `remaining:` is cross-checked
# against the set the rows imply.
#
# Pinned here (eight ( subshell ) sections, one per scenario):
#   1. cone-stop (the DEFAULT): a failure parks exactly its consumer cone
#      (`parked waits-on-failed` rows), unrelated work runs to completion,
#      rc is §G.1's 4 for a cone-stop run with >=1 failed row.
#   2. --fail-fast: dispatch stops on the first failure (unstarted packages
#      are `never-started dispatch-stopped`, nothing is parked), rc 1.
#   3. deferral (lane rc 99) is NOT a park and NOT a failure: the deferring
#      row is `deferred 99 <reason>`, only its consumers park
#      (`waits-on-deferred`), unrelated work runs even under --fail-fast,
#      rc is §G.1's deferral-only 5.
#   4. interrupt: one SIGINT mid-build tears the run down, the FULL run
#      record (plan, outcomes, continuation) is emitted first, rc 130.
#   5. the result codec at the `--lane-job` seam (§D.1/§F.2): every outcome
#      class publishes exactly one wire line (`v2 <pkg> <code> <dur>
#      <reason>`) that round-trips byte-identically, atomically (no `.tmp.*`
#      survives), and the lane's exit code IS its outcome code (§G.2); bad
#      payloads are rc 2 naming the argument; verification-bypass flags are
#      refused; `gsa --help` hides the seams and lists the build flags.
#   6. `--stale-lock-check` (§D.1): the pacman-lock probe reports
#      free / present-idle / held, identifies holders via /proc fd scan, and
#      NEVER deletes db.lck; extra arguments are rc 2.
#   7. the makepkg PACMAN shim path survives the recipe cwd (§K.1): a
#      relative `--state-dir` still hands makepkg an ABSOLUTE shim path —
#      makepkg runs with the recipe's cwd, so a relative one would not exist
#      there and the build dies with "An unknown error has occurred".
#   8. a broken stand-down: a park marker that cannot be written settles the
#      node as `failed 125 park-marker-unwritable` AND kills the parked
#      lane's process group — a rogue lane must not build on past a
#      stand-down that could not be delivered.
#
# House conventions: `( subshell )` sections (each an isolated scenario with
# its own workspace), inline oracle stubs (§D.2), `fail()` prefixes, and
# tests/lib/rr-v2.bash's `format: 2` parser + run_engine with
# GSA_TEST_ENGINE=gsa. The interrupt section needs the engine's PID to signal
# it mid-run, so its `gsa` is reached through a one-line wrapper that records
# its own pid before `exec` — run_engine still performs the invocation.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"

fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-sched-v2.XXXXXX")
# root-safe cleanup: engine state under $fixture is root-owned (W5 §B.10)
trap '/usr/bin/sudo -n rm -rf -- "$fixture" 2>/dev/null || rm -rf -- "$fixture" 2>/dev/null || true' EXIT

fail() {
    printf '%s\n' "$1" >&2
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
        sed 's/^/    /' "$2" >&2
    fi
    exit 1
}

# ─── Stub-knob vocabulary (§D.2: declared here in the change that adds them) ─
rr2_stub_knob GSA_FAKE_DEFER_PACKAGE "gsa-sched-v2 makepkg stub: package id whose build exits 99 (deferral)"
rr2_stub_knob GSA_FAKE_ENGINE_PID "gsa-sched-v2 engine wrapper: pidfile of the engine process to signal"
rr2_stub_knob GSA_FAKE_PARK_SABOTAGE_PACKAGE "gsa-sched-v2 makepkg stub: package id whose stand-down the fixture sabotages and whose stub dies only by SIGKILL (TERM-proof)"
rr2_stub_knob GSA_FAKE_SLOW_PACKAGE "gsa-sched-v2 makepkg stub: package id whose build sleeps GSA_FAKE_SLOW_SECONDS instead of GSA_FAKE_BUILD_SECONDS"
rr2_stub_knob GSA_FAKE_SLOW_SECONDS "gsa-sched-v2 makepkg stub: sleep duration for GSA_FAKE_SLOW_PACKAGE"

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

# ─── Oracle stubs and derivation helpers (inline: §D.2 keeps oracles in the
# fixture that gives them meaning) ──────────────────────────────────────────

# write_stub_makepkg DIR — the scenario makepkg: SPAWN/END lines and a start
# marker for dispatch/interrupt observation, one sleep per build, then the
# outcome the GSA_FAKE_* knobs name (fail 1 / defer 99 / else ok).
write_stub_makepkg() {
    cat >"$1/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -eu
id=$(basename "$PWD")
printf 'SPAWN %s %s\n' "$id" "$(date +%s%N)" >>"${GSA_FAKE_SPAWN_LOG:?}"
[ -n "${GSA_FAKE_MARKER_DIR:-}" ] && : >"$GSA_FAKE_MARKER_DIR/$id"
if [ "${GSA_FAKE_PARK_SABOTAGE_PACKAGE:-}" = "$id" ]; then
    # This package's stand-down is sabotaged out-of-band (the fixture turns
    # its park-marker path into a directory, through the host's REAL sudo —
    # the run dir is root-owned and this stub runs as the build user). The
    # stub ignores TERM/INT/HUP so the scenario proves the kill is a real
    # SIGKILL: a TERM stand-down leaves this build running.
    trap '' TERM INT HUP
fi
if [ "${GSA_FAKE_SLOW_PACKAGE:-}" = "$id" ]; then
    sleep "${GSA_FAKE_SLOW_SECONDS:-8}"
else
    sleep "${GSA_FAKE_BUILD_SECONDS:-0}"
fi
printf 'END %s %s\n' "$id" "$(date +%s%N)" >>"${GSA_FAKE_SPAWN_LOG:?}"
if [ "${GSA_FAKE_FAIL_PACKAGE:-}" = "$id" ]; then exit 1; fi
if [ "${GSA_FAKE_DEFER_PACKAGE:-}" = "$id" ]; then exit 99; fi
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
exit 0
EOF
    chmod +x "$1/bin/makepkg"
}

# consumers_closure EDGES-FILE ROOT — the transitive consumer cone of ROOT
# over the fixture's own build-order edges (`consumer prereq` per line), one
# id per line. This is how every parked-set expectation is derived.
consumers_closure() {
    awk -v root="$2" '
        { edge[++n] = $1; pre[n] = $2 }
        END {
            seen[root] = 1; queue[1] = root; q = 1
            while (q > 0) {
                cur = queue[q--]
                for (i = 1; i <= n; i++) {
                    if (pre[i] == cur && !(edge[i] in seen)) {
                        seen[edge[i]] = 1; queue[++q] = edge[i]
                    }
                }
            }
            for (k in seen) if (k != root) print k
        }' "$1" | sort
}

# expected_rc POLICY INTERRUPTED — the run exit code §G.1 derives from the
# outcome rows on stdin (usage/refusal are pre-run classes and never appear
# here). The rows are the record's; this function only applies the contract.
expected_rc() {
    awk -v policy="$1" -v interrupted="$2" '
        { counts[$2]++ }
        END {
            if (interrupted == 1) { print 130; exit }
            if (counts["failed"] > 0) { print (policy == "fail-fast") ? 1 : 4; exit }
            if (counts["deferred"] > 0 || counts["parked"] > 0) { print 5; exit }
            print 0
        }'
}

# assert_order_respects_edges EDGES-FILE — the record's `order:` must be a
# topological order of the fixture's edges (contract §C.5: one order
# everywhere), derived from the topology, not from a pinned string.
assert_order_respects_edges() {
    local order
    order=$(rr2_scalar order <<<"$FIXTURE_OUTPUT")
    awk -v order="$order" '
        BEGIN { n = split(order, ids, " "); for (i = 1; i <= n; i++) pos[ids[i]] = i }
        pos[$2] && pos[$1] && !(pos[$2] < pos[$1]) {
            printf("order %s is not topological: %s must precede %s\n", order, $2, $1) > "/dev/stderr"
            bad = 1
        }
        END { exit bad }' "$1" || fail "the run-record order violates the fixture topology"
}

# codec_roundtrip PKG CODE DUR-REASON-REGEX REASON FILE — §F.2 at the seam:
# exactly one wire line, parseable under the codec grammar, re-encoding
# byte-identically (round-trip), with no `.tmp.*` publication residue.
codec_roundtrip() {
    local pkg=$1 code=$2 dur_re=$3 reason=$4 file=$5
    [ -f "$file" ] || fail "--lane-job published no result at $file"
    [ "$(wc -l <"$file")" -eq 1 ] || fail "--lane-job result is not exactly one line:" "$file"
    read -r wire_pkg_ver wire_pkg wire_code wire_dur wire_reason <"$file" \
        || fail "cannot read the wire line of $file"
    [ "$wire_pkg_ver" = "v2" ] || fail "wire version is '$wire_pkg_ver', want v2:" "$file"
    [ "$wire_pkg" = "$pkg" ] || fail "wire package is '$wire_pkg', want '$pkg':" "$file"
    case "$wire_code" in
    0 | 1 | 98 | 99 | 125 | 129 | 130 | 143) ;;
    *) fail "wire code '$wire_code' is not a §F.1 lane code:" "$file" ;;
    esac
    [ "$wire_code" = "$code" ] || fail "wire code is '$wire_code', want '$code':" "$file"
    vgrep "$wire_dur" -Eq "$dur_re" \
        || fail "wire duration '$wire_dur' does not match $dur_re:" "$file"
    [ "$wire_reason" = "$reason" ] || fail "wire reason is '$wire_reason', want '$reason':" "$file"
    printf '%s\n' "$wire_pkg_ver $wire_pkg $wire_code $wire_dur $wire_reason" | cmp -s - "$file" \
        || fail "the wire line does not re-encode byte-identically (round-trip):" "$file"
    if grep < <(find "$(dirname "$file")" -maxdepth 1 -name "$(basename "$file").tmp.*" -print -quit) -q .; then
        fail "atomic publication left a temp name beside $file"
    fi
}

# ─── 1. cone-stop (default): parks exactly the consumer cone, rc 4 ──────────
(
    set -euo pipefail
    ws="$fixture/cone/ws"
    make_workspace "$ws" 4 auto xhigh
    add_package "$ws" a "$gsa_meta_any" git
    add_package "$ws" b "$gsa_meta_any" git
    add_package "$ws" c "$gsa_meta_any" git
    add_package "$ws" u "$gsa_meta_any" git
    set_topology_record "$ws" b git a
    set_topology_record "$ws" c git b
    # the fixture's build-order edges (consumer prereq) — the derivation
    # source for the expected cone and the order check
    edges="$fixture/cone/edges"
    printf 'b a\nc b\n' >"$edges"
    write_stub_makepkg "$ws"
    export PATH="$ws/bin:$PATH"
    export GSA_FAKE_SPAWN_LOG="$fixture/cone/spawn.log"
    export GSA_FAKE_FAIL_PACKAGE=a

    run_engine "$ws" -B --state-dir "$fixture/cone/state" a u
    {
        echo "$FIXTURE_OUTPUT"
    } >"$fixture/cone/output.txt"

    rows=$(rr2_outcome_rows <<<"$FIXTURE_OUTPUT")
    expected=$(printf '%s\n' "$rows" | expected_rc cone-stop 0)
    [ "$FIXTURE_RC" = "$expected" ] \
        || fail "cone-stop rc=$FIXTURE_RC, want $expected (§G.1 from the rows):" "$fixture/cone/output.txt"
    [ "$FIXTURE_RC" = "$(rr2_scalar rc <<<"$FIXTURE_OUTPUT")" ] \
        || fail "the record's rc scalar disagrees with the process exit code:" "$fixture/cone/output.txt"
    [ "$(rr2_scalar outcome <<<"$FIXTURE_OUTPUT")" = "failed" ] \
        || fail "a cone-stop run with a failure must record outcome 'failed':" "$fixture/cone/output.txt"

    # the failure itself
    [ "$(rr2_outcome a status <<<"$FIXTURE_OUTPUT")" = "failed" ] \
        || fail "the failing package is not recorded as failed:" "$fixture/cone/output.txt"
    [ "$(rr2_outcome a rc <<<"$FIXTURE_OUTPUT")" = "1" ] \
        || fail "a build failure is lane code 1 (§F.1):" "$fixture/cone/output.txt"

    # parked set == the consumer cone of `a`, computed from the edges
    parked=$(printf '%s\n' "$rows" | awk '$2 == "parked" { print $1 }' | sort)
    cone=$(consumers_closure "$edges" a)
    [ "$parked" = "$cone" ] \
        || fail "parked set [$parked] != consumer cone of a [$cone] (derived from $edges):" "$fixture/cone/output.txt"
    for pkg in $cone; do
        [ "$(rr2_outcome "$pkg" status <<<"$FIXTURE_OUTPUT")" = "parked" ] \
            || fail "cone member $pkg is not parked:" "$fixture/cone/output.txt"
        [ "$(rr2_outcome "$pkg" reason <<<"$FIXTURE_OUTPUT")" = "waits-on-failed" ] \
            || fail "cone member $pkg does not carry the waits-on-failed reason (§H.3):" "$fixture/cone/output.txt"
    done

    # unrelated work runs to completion (u consumes nothing the failure parked)
    [ "$(rr2_outcome u status <<<"$FIXTURE_OUTPUT")" = "succeeded" ] \
        || fail "unrelated package u did not run to completion:" "$fixture/cone/output.txt"

    # record self-consistency: topological order, remaining set from rows
    assert_order_respects_edges "$edges"
    remaining_rows=$(rr2_remaining <<<"$FIXTURE_OUTPUT" | tr '\n' ' ' | sed 's/ $//')
    remaining_line=$(rr2_continuation remaining <<<"$FIXTURE_OUTPUT")
    [ "$remaining_rows" = "$remaining_line" ] \
        || fail "continuation remaining [$remaining_line] != rows-derived remaining [$remaining_rows]"

    # H3 (argv-scoped §H.2): this run's argv carried no hidden seam, so a
    # seam may appear in NEITHER the command NOR the not-mirrored line —
    # the line lists only the run's own spellings the command drops, never
    # a roster.
    nm=$(rr2_continuation not-mirrored <<<"$FIXTURE_OUTPUT")
    cmd=$(rr2_continuation command <<<"$FIXTURE_OUTPUT")
    for seam in --lane-job --stale-lock-check --install-decide --fetch-job; do
        case " $nm " in
        *" $seam "*) fail "hidden seam $seam must not be listed (the run carried none): $nm" ;;
        esac
        case " $cmd " in
        *" $seam "*) fail "hidden seam $seam leaked into the command: $cmd" ;;
        esac
    done
    [ "$nm" = "-" ] ||
        fail "a plain build run mirrors everything it carried (H3), not-mirrored: $nm"

    # child-process hygiene: nothing survives the run (§K.3)
    if ps -eo args= | grep -F "$ws" | grep -v grep >/dev/null; then
        fail "a lane child of $ws remained after the run"
    fi
)

# ─── 2. --fail-fast: dispatch stops, nothing parks, rc 1 ────────────────────
(
    set -euo pipefail
    ws="$fixture/failfast/ws"
    make_workspace "$ws" 1 auto xhigh
    add_package "$ws" a "$gsa_meta_any" git
    add_package "$ws" b "$gsa_meta_any" git
    add_package "$ws" c "$gsa_meta_any" git
    add_package "$ws" u "$gsa_meta_any" git
    set_topology_record "$ws" b git a
    set_topology_record "$ws" c git b
    edges="$fixture/failfast/edges"
    printf 'b a\nc b\n' >"$edges"
    write_stub_makepkg "$ws"
    export PATH="$ws/bin:$PATH"
    export GSA_FAKE_SPAWN_LOG="$fixture/failfast/spawn.log"
    export GSA_FAKE_FAIL_PACKAGE=a
    # one lane serialises dispatch: the first failure is the only dispatch
    export GSA_LANES=1

    run_engine "$ws" -B --state-dir "$fixture/failfast/state" --fail-fast a u
    {
        echo "$FIXTURE_OUTPUT"
    } >"$fixture/failfast/output.txt"

    rows=$(rr2_outcome_rows <<<"$FIXTURE_OUTPUT")
    expected=$(printf '%s\n' "$rows" | expected_rc fail-fast 0)
    [ "$FIXTURE_RC" = "$expected" ] \
        || fail "fail-fast rc=$FIXTURE_RC, want $expected (§G.1 from the rows):" "$fixture/failfast/output.txt"
    [ "$FIXTURE_RC" = 1 ] || fail "a fail-fast build failure is rc 1 (§G.1): $FIXTURE_RC"

    # dispatch stopped: every row except the failure never started, and
    # nothing is parked (fail-fast stops dispatch; it does not park)
    failed=$(printf '%s\n' "$rows" | awk '$2 == "failed" { print $1 }')
    [ "$failed" = "a" ] || fail "expected exactly the failing package in failed rows, got [$failed]"
    if grep < <(printf '%s\n' "$rows" | awk '$2 == "parked"') -q .; then
        fail "--fail-fast must not park rows:" "$fixture/failfast/output.txt"
    fi
    for pkg in b c u; do
        [ "$(rr2_outcome "$pkg" status <<<"$FIXTURE_OUTPUT")" = "never-started" ] \
            || fail "$pkg was dispatched after the fail-fast stop:" "$fixture/failfast/output.txt"
        [ "$(rr2_outcome "$pkg" reason <<<"$FIXTURE_OUTPUT")" = "dispatch-stopped" ] \
            || fail "$pkg does not carry the dispatch-stopped reason (§I.3):" "$fixture/failfast/output.txt"
    done

    assert_order_respects_edges "$edges"
    remaining_rows=$(rr2_remaining <<<"$FIXTURE_OUTPUT" | tr '\n' ' ' | sed 's/ $//')
    [ "$remaining_rows" = "$(rr2_continuation remaining <<<"$FIXTURE_OUTPUT")" ] \
        || fail "continuation remaining disagrees with the rows-derated set"
)

# ─── 3. deferral (99) is neither a park nor a failure, even under --fail-fast ─
(
    set -euo pipefail
    ws="$fixture/defer/ws"
    make_workspace "$ws" 4 auto xhigh
    add_package "$ws" a "$gsa_meta_any" git
    add_package "$ws" b "$gsa_meta_any" git
    add_package "$ws" c "$gsa_meta_any" git
    add_package "$ws" u "$gsa_meta_any" git
    set_topology_record "$ws" b git a
    set_topology_record "$ws" c git b
    edges="$fixture/defer/edges"
    printf 'b a\nc b\n' >"$edges"
    write_stub_makepkg "$ws"
    export PATH="$ws/bin:$PATH"
    export GSA_FAKE_SPAWN_LOG="$fixture/defer/spawn.log"
    export GSA_FAKE_DEFER_PACKAGE=a

    for policy in cone-stop fail-fast; do
        flags=()
        [ "$policy" = "fail-fast" ] && flags=(--fail-fast)
        run_engine "$ws" -B --state-dir "$fixture/defer/state-$policy" ${flags[@]+"${flags[@]}"} a u
        {
            echo "$FIXTURE_OUTPUT"
        } >"$fixture/defer/output-$policy.txt"

        rows=$(rr2_outcome_rows <<<"$FIXTURE_OUTPUT")
        expected=$(printf '%s\n' "$rows" | expected_rc "$policy" 0)
        [ "$FIXTURE_RC" = "$expected" ] \
            || fail "$policy deferral rc=$FIXTURE_RC, want $expected (§G.1 from the rows):" "$fixture/defer/output-$policy.txt"
        [ "$FIXTURE_RC" = 5 ] || fail "$policy deferral-only must exit 5 (§G.1), got $FIXTURE_RC"

        # deferral != parked: the deferring row defers, only its cone parks
        [ "$(rr2_outcome a status <<<"$FIXTURE_OUTPUT")" = "deferred" ] \
            || fail "$policy: the deferring package must be deferred, not parked:" "$fixture/defer/output-$policy.txt"
        [ "$(rr2_outcome a rc <<<"$FIXTURE_OUTPUT")" = "99" ] \
            || fail "$policy: deferral is lane code 99 (§F.1):" "$fixture/defer/output-$policy.txt"
        grep < <(rr2_outcome a reason <<<"$FIXTURE_OUTPUT") -Eq '^(anchoring-refused|upstream-unverified|source-unfetchable)$' \
            || fail "$policy: deferral reason is not a §H.3 deferral key:" "$fixture/defer/output-$policy.txt"

        cone=$(consumers_closure "$edges" a)
        for pkg in $cone; do
            [ "$(rr2_outcome "$pkg" status <<<"$FIXTURE_OUTPUT")" = "parked" ] \
                || fail "$policy: consumer $pkg of a deferral must park:" "$fixture/defer/output-$policy.txt"
            [ "$(rr2_outcome "$pkg" reason <<<"$FIXTURE_OUTPUT")" = "waits-on-deferred" ] \
                || fail "$policy: consumer $pkg must carry waits-on-deferred, not a failure park reason:" "$fixture/defer/output-$policy.txt"
        done

        # a deferral never stops dispatch — unrelated work completes even
        # under --fail-fast (§I.3)
        [ "$(rr2_outcome u status <<<"$FIXTURE_OUTPUT")" = "succeeded" ] \
            || fail "$policy: unrelated package u did not run despite the deferral:" "$fixture/defer/output-$policy.txt"
        assert_order_respects_edges "$edges"
    done
)

# ─── 4. interrupt: rc 130 with the FULL record emitted first ────────────────
(
    set -euo pipefail
    ws="$fixture/interrupt/ws"
    make_workspace "$ws" 4 auto xhigh
    add_package "$ws" slow "$gsa_meta_any" git
    add_package "$ws" after "$gsa_meta_any" git
    set_topology_record "$ws" after git slow
    write_stub_makepkg "$ws"
    export PATH="$ws/bin:$PATH"
    export GSA_FAKE_SPAWN_LOG="$fixture/interrupt/spawn.log"
    markerdir="$fixture/interrupt/markers"
    mkdir -p "$markerdir"
    export GSA_FAKE_MARKER_DIR="$markerdir"
    export GSA_FAKE_BUILD_SECONDS=20

    # The engine needs one SIGINT mid-build; run_engine performs the
    # invocation while a watcher signals the engine PID the wrapper records
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
        for _ in $(seq 1 400); do [ -f "$markerdir/slow" ] && break; sleep 0.025; done
        # the engine is root under W5 (run_engine's sudo) — signal it through
        # the host's REAL sudo, never the PATH stub
        /usr/bin/sudo -n kill -INT "$(cat "$pidfile")" 2>/dev/null || true
    ) &
    watcher=$!
    GSA_TEST_GSA_BIN="$wrap" GSA_FAKE_ENGINE_PID="$pidfile" \
        run_engine "$ws" -B --state-dir "$fixture/interrupt/state" slow after
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    {
        echo "$FIXTURE_OUTPUT"
    } >"$fixture/interrupt/output.txt"

    # the signal landed mid-build (the stub had started)
    [ -f "$markerdir/slow" ] || fail "the interrupt did not land mid-build (no start marker)"

    rows=$(rr2_outcome_rows <<<"$FIXTURE_OUTPUT")
    expected=$(printf '%s\n' "$rows" | expected_rc cone-stop 1)
    [ "$FIXTURE_RC" = "$expected" ] \
        || fail "interrupted run rc=$FIXTURE_RC, want $expected (§G.1):" "$fixture/interrupt/output.txt"
    [ "$FIXTURE_RC" = 130 ] || fail "an interrupted run exits 130 (§G.1), got $FIXTURE_RC"
    [ "$(rr2_scalar outcome <<<"$FIXTURE_OUTPUT")" = "interrupted" ] \
        || fail "the record does not record outcome 'interrupted':" "$fixture/interrupt/output.txt"

    # the FULL record is emitted: every section parses (rr2_body), plan rows
    # are complete, and what started / what never launched are told apart
    rr2_body <<<"$FIXTURE_OUTPUT" >/dev/null \
        || fail "the interrupted run emitted no complete run record:" "$fixture/interrupt/output.txt"
    for pkg in slow after; do
        [ -n "$(rr2_plan "$pkg" plan <<<"$FIXTURE_OUTPUT")" ] \
            || fail "the interrupted record is missing the plan row of $pkg:" "$fixture/interrupt/output.txt"
    done
    [ "$(rr2_outcome slow status <<<"$FIXTURE_OUTPUT")" = "interrupted" ] \
        || fail "the in-flight package is not recorded as interrupted (§H.3):" "$fixture/interrupt/output.txt"
    grep < <(rr2_outcome slow rc <<<"$FIXTURE_OUTPUT") -Eq '^(129|130|143)$' \
        || fail "an interrupted row's rc is not a signal lane code (§F.1):" "$fixture/interrupt/output.txt"
    [ "$(rr2_outcome after status <<<"$FIXTURE_OUTPUT")" = "never-started" ] \
        || fail "the unlaunched package is not recorded as never-started:" "$fixture/interrupt/output.txt"
    [ "$(rr2_outcome after reason <<<"$FIXTURE_OUTPUT")" = "interrupted-before-start" ] \
        || fail "the unlaunched package lacks the interrupted-before-start reason (§I.3):" "$fixture/interrupt/output.txt"

    remaining_rows=$(rr2_remaining <<<"$FIXTURE_OUTPUT" | tr '\n' ' ' | sed 's/ $//')
    [ "$remaining_rows" = "$(rr2_continuation remaining <<<"$FIXTURE_OUTPUT")" ] \
        || fail "continuation remaining disagrees with the rows-derived set:" "$fixture/interrupt/output.txt"
    [ -n "$(rr2_continuation command <<<"$FIXTURE_OUTPUT")" ] \
        || fail "the interrupted record has no continuation command:" "$fixture/interrupt/output.txt"

    # teardown drained the children (§K.3)
    if ps -eo args= | grep -F "$ws" | grep -v grep >/dev/null; then
        fail "a lane child of $ws survived the interrupt teardown"
    fi
)

# ─── 5. result codec at the --lane-job seam (§D.1/§F.2/§G.2) ────────────────
(
    set -euo pipefail
    ws="$fixture/codec/ws"
    make_workspace "$ws" 4 auto xhigh
    add_package "$ws" okp "$gsa_meta_any" git
    add_package "$ws" failp "$gsa_meta_any" git
    add_package "$ws" deferp "$gsa_meta_any" git
    add_package "$ws" parkp "$gsa_meta_any" git
    write_stub_makepkg "$ws"
    export PATH="$ws/bin:$PATH"
    export GSA_FAKE_SPAWN_LOG="$fixture/codec/spawn.log"
    # a direct seam call gets no supervisor env: the lane child resolves its
    # build log under GSA_STATE_DIR (§J.1) exactly as a supervised lane does
    export GSA_STATE_DIR="$fixture/codec/state"
    results="$fixture/codec/results"
    mkdir -p "$results"

    # ok → `v2 <pkg> 0 <dur> ok`, exit 0 (a lane's exit code IS its outcome)
    run_engine "$ws" --lane-job okp "$results/okp.result" 4
    [ "$FIXTURE_RC" = 0 ] || fail "an ok lane child must exit 0 (§G.2), got $FIXTURE_RC"
    codec_roundtrip okp 0 '^[0-9]+$' ok "$results/okp.result"

    # build failure → `failed 1 build-failed`, exit 1
    GSA_FAKE_FAIL_PACKAGE=failp run_engine "$ws" --lane-job failp "$results/failp.result" 4
    [ "$FIXTURE_RC" = 1 ] || fail "a failing lane child must exit 1 (§G.2), got $FIXTURE_RC"
    codec_roundtrip failp 1 '^[0-9]+$' build-failed "$results/failp.result"

    # deferral (makepkg 99) → `defer 99 source-unfetchable`, exit 99
    GSA_FAKE_DEFER_PACKAGE=deferp run_engine "$ws" --lane-job deferp "$results/deferp.result" 4
    [ "$FIXTURE_RC" = 99 ] || fail "a deferring lane child must exit 99 (§G.2), got $FIXTURE_RC"
    codec_roundtrip deferp 99 '^[0-9]+$' source-unfetchable "$results/deferp.result"

    # a park marker published before the build → `parked 98 <reason>`, exit 98
    printf 'waits-on-failed\n' >"$results/parkp.result.park"
    run_engine "$ws" --lane-job parkp "$results/parkp.result" 4
    [ "$FIXTURE_RC" = 98 ] || fail "a standing-down lane child must exit 98 (§G.2), got $FIXTURE_RC"
    codec_roundtrip parkp 98 '^0$' waits-on-failed "$results/parkp.result"

    # invalid payloads are rc 2 with a message naming the argument (§D.1)
    run_engine "$ws" --lane-job okp "$results/bad1.result" 0
    [ "$FIXTURE_RC" = 2 ] || fail "jobs=0 must be a usage error, got $FIXTURE_RC"
    vgrep "$FIXTURE_OUTPUT" -F "jobs '0'" >/dev/null \
        || fail "the jobs refusal does not name the argument: $FIXTURE_OUTPUT"
    run_engine "$ws" --lane-job okp "$results/bad2.result" 2 --skippgpcheck
    [ "$FIXTURE_RC" = 2 ] || fail "a verification-bypass flag must be a usage error, got $FIXTURE_RC"
    vgrep "$FIXTURE_OUTPUT" -F -- "--skippgpcheck" >/dev/null \
        || fail "the flag refusal does not name the flag: $FIXTURE_OUTPUT"
    vgrep "$FIXTURE_OUTPUT" -F "never weakened" >/dev/null \
        || fail "the flag refusal must state verification is never weakened: $FIXTURE_OUTPUT"
    run_engine "$ws" --lane-job "bad pkg" "$results/bad3.result" 2
    [ "$FIXTURE_RC" = 2 ] || fail "a malformed package id must be a usage error, got $FIXTURE_RC"
    run_engine "$ws" --lane-job
    [ "$FIXTURE_RC" = 2 ] || fail "a missing payload must be a usage error, got $FIXTURE_RC"
    # none of the refusals published a result
    grep < <(find "$results" -maxdepth 1 -name 'bad*.result' -print -quit) -q . \
        && fail "a refused --lane-job payload published a result file"

    # coherence (§L.1/§D.1): the roster lists the build flags; the hidden
    # seams are excluded from --help
    run_engine "$ws" --help
    help=$FIXTURE_OUTPUT
    for flag in --dry-run --leaf --fail-fast --lanes --jobs --intensity --state-dir; do
        printf '%s\n' "$help" | grep -F -- "$flag" >/dev/null \
            || fail "--help must list $flag (§L.1)"
    done
    for seam in --lane-job --stale-lock-check --install-decide; do
        if printf '%s\n' "$help" | grep -F -- "$seam" >/dev/null; then
            fail "--help must hide the $seam seam (§D.1)"
        fi
    done
)

# ─── 6. --stale-lock-check: probe only, never deletes db.lck (§D.1) ─────────
(
    set -euo pipefail
    ws="$fixture/lock/ws"
    make_workspace "$ws" 4 auto xhigh
    add_package "$ws" p "$gsa_meta_any" git
    db="$fixture/lock/db"
    mkdir -p "$db"
    # the probe resolves pacman's DBPath like makepkg does: `pacman-conf`
    cat >"$ws/bin/pacman-conf" <<EOF
#!/usr/bin/env bash
set -u
if [ "\${1:-}" = DBPath ]; then
    printf '%s\n' "$db"
    exit 0
fi
exit 1
EOF
    chmod +x "$ws/bin/pacman-conf"
    export PATH="$ws/bin:$PATH"

    # free: no db.lck at all
    run_engine "$ws" --stale-lock-check
    [ "$FIXTURE_RC" = 0 ] || fail "the lock probe is report-only (rc 0), got $FIXTURE_RC"
    vgrep "$FIXTURE_OUTPUT" -F "status: free" >/dev/null \
        || fail "a lock-free database must report status: free: $FIXTURE_OUTPUT"

    # present-idle: db.lck exists, no open holder
    : >"$db/db.lck"
    run_engine "$ws" --stale-lock-check
    [ "$FIXTURE_RC" = 0 ] || fail "the lock probe is report-only (rc 0), got $FIXTURE_RC"
    vgrep "$FIXTURE_OUTPUT" -F "status: present-idle" >/dev/null \
        || fail "an idle db.lck must report status: present-idle: $FIXTURE_OUTPUT"
    [ -f "$db/db.lck" ] || fail "the probe deleted db.lck (it must never delete)"
    vgrep "$FIXTURE_OUTPUT" -F "db.lck is never deleted" >/dev/null \
        || fail "the probe must state db.lck is never deleted: $FIXTURE_OUTPUT"

    # held: this section holds db.lck open — the fd scan must find the holder
    exec 9>"$db/db.lck"
    run_engine "$ws" --stale-lock-check
    exec 9>&-
    [ "$FIXTURE_RC" = 0 ] || fail "the lock probe is report-only (rc 0), got $FIXTURE_RC"
    vgrep "$FIXTURE_OUTPUT" -F "status: held" >/dev/null \
        || fail "an open holder must report status: held: $FIXTURE_OUTPUT"
    vgrep "$FIXTURE_OUTPUT" -F "holder: " >/dev/null \
        || fail "the probe must identify the holder: $FIXTURE_OUTPUT"
    [ -f "$db/db.lck" ] || fail "the probe deleted a held db.lck (it must never delete)"

    # invalid invocation: rc 2 naming the argument (§D.1)
    run_engine "$ws" --stale-lock-check extra
    [ "$FIXTURE_RC" = 2 ] || fail "--stale-lock-check with arguments must be rc 2, got $FIXTURE_RC"
    vgrep "$FIXTURE_OUTPUT" -F "takes no arguments" >/dev/null \
        || fail "the arity refusal does not name the argument: $FIXTURE_OUTPUT"
)

# ─── 7. makepkg's PACMAN shim path survives the recipe cwd (§K.1) ──────────
# makepkg runs with the RECIPE's cwd: a relative `--state-dir` must never hand
# it a relative `PACMAN` shim path — the shim would not exist there and
# `makepkg -sf` dies with a bare "An unknown error has occurred" (real-tree
# smoke, 2026-10-14). The lane hands makepkg an ABSOLUTE path.
(
    set -euo pipefail
    ws="$fixture/relstate/ws"
    make_workspace "$ws" 1 1 low
    add_package "$ws" p1 "$gsa_meta_any" git
    cat >"$ws/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -eu
printf 'PACMAN=%s\n' "${PACMAN:-}" >>"${GSA_FAKE_PACMAN_ENV_LOG:?}"
: >"$PWD/$(basename "$PWD")-1.0.0-1-any.pkg.tar.zst"
exit 0
EOF
    chmod +x "$ws/bin/makepkg"
    export PATH="$ws/bin:$PATH"
    export GSA_FAKE_PACMAN_ENV_LOG="$fixture/relstate/pacman-env.log"
    export GSA_FAKE_SPAWN_LOG="$fixture/relstate/spawn.log"
    : >"$GSA_FAKE_PACMAN_ENV_LOG"

    # the state root is RELATIVE on purpose (run_engine cds into $ws)
    run_engine "$ws" -B --state-dir state --leaf --no-prefetch --allow-broken-rustc p1
    [ "$FIXTURE_RC" = 0 ] \
        || fail "relative state root build rc=$FIXTURE_RC, want 0:" "$FIXTURE_OUTPUT"
    [ -s "$GSA_FAKE_PACMAN_ENV_LOG" ] \
        || fail "the makepkg stub never ran:" "$FIXTURE_OUTPUT"
    if grep < <(grep -v '^PACMAN=/' "$GSA_FAKE_PACMAN_ENV_LOG") -q .; then
        fail "makepkg saw a non-absolute PACMAN path (it runs with the recipe's cwd):" "$GSA_FAKE_PACMAN_ENV_LOG"
    fi
    grep -q '^PACMAN=.*/state/locks/pacman-shim$' "$GSA_FAKE_PACMAN_ENV_LOG" \
        || fail "no makepkg invocation saw the state root's pacman shim:" "$GSA_FAKE_PACMAN_ENV_LOG"
)

# ─── 8. broken stand-down: an unwritable park marker settles the node as lost
#        125 AND kills the parked lane's process group (§F.1: a stand-down
#        that cannot be delivered must not leave a rogue lane building) ─────
(
    set -euo pipefail
    ws="$fixture/parkkill/ws"
    make_workspace "$ws" 2 auto xhigh
    add_package "$ws" base "$gsa_meta_any" git
    add_package "$ws" a "$gsa_meta_any" git
    add_package "$ws" b "$gsa_meta_any" git
    # ONE anchored coupled batch (crates/gsa-cli/src/build.rs `build_batches`
    # — one batch per anchor, never one per severity): `base` is the anchor
    # (abi=must, no abi-tagged dependency) and a/b its abi=must members
    # (both consume base; a and b carry NO edge to each other — two
    # unrelated abi=must anchors would be TWO batches and never park each
    # other). The anchor's build lands first (the edge orders a and b after
    # it), then both member lanes dispatch at once, and a's failure parks
    # its IN-FLIGHT batch mate b with reason `coupled-batch` through the
    # marker handshake (gsa-sched machine.rs mate parking) — the one path
    # that writes a park marker for a live lane (a Pending consumer just
    # settles as a parked row).
    set_topology_record "$ws" base git '' 'abi=must'
    set_topology_record "$ws" a git base 'abi=must'
    set_topology_record "$ws" b git base 'abi=must'
    write_stub_makepkg "$ws"
    export PATH="$ws/bin:$PATH"
    export GSA_FAKE_SPAWN_LOG="$fixture/parkkill/spawn.log"
    export GSA_FAKE_FAIL_PACKAGE=a
    # a builds 2 s then fails; b builds for 8 s after the fixture breaks its
    # stand-down channel — the stand-down demand lands mid-build, and any
    # survivor is observable for seconds afterwards.
    export GSA_FAKE_BUILD_SECONDS=2
    export GSA_FAKE_SLOW_PACKAGE=b
    export GSA_FAKE_SLOW_SECONDS=8
    export GSA_FAKE_PARK_SABOTAGE_PACKAGE=b

    # The watcher stages the sabotage (the run dir is root-owned under the
    # sudo engine, so the marker path becomes a directory through the host's
    # REAL sudo — EISDIR defeats even root's write) once b is provably
    # building, then samples the lane argv (log-ownership's pgrep idiom) 1 s
    # after the failure that demanded the stand-down (a's END line, which
    # precedes the marker write) and records any survivor as a verdict file.
    verdict="$fixture/parkkill/lane-survived"
    (
        for _ in $(seq 1 800); do
            grep -q '^SPAWN b ' "$GSA_FAKE_SPAWN_LOG" 2>/dev/null && break
            sleep 0.025
        done
        for d in "$fixture/parkkill/state/runs/"*; do
            if [ -d "$d" ]; then /usr/bin/sudo -n mkdir -p "$d/b.result.park"; fi
        done
        for _ in $(seq 1 800); do
            grep -q '^END a ' "$GSA_FAKE_SPAWN_LOG" 2>/dev/null && break
            sleep 0.025
        done
        sleep 1
        if pgrep -f -- "--lane-job b " >/dev/null 2>&1; then
            pgrep -af -- "--lane-job b " >"$verdict" 2>/dev/null || : >"$verdict"
        fi
    ) &
    watcher=$!

    run_engine "$ws" -B --state-dir "$fixture/parkkill/state" base a b
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    {
        echo "$FIXTURE_OUTPUT"
    } >"$fixture/parkkill/output.txt"

    rows=$(rr2_outcome_rows <<<"$FIXTURE_OUTPUT")
    expected=$(printf '%s\n' "$rows" | expected_rc cone-stop 0)
    [ "$FIXTURE_RC" = "$expected" ] \
        || fail "broken stand-down rc=$FIXTURE_RC, want $expected (§G.1 from the rows):" "$fixture/parkkill/output.txt"
    [ "$FIXTURE_RC" = "$(rr2_scalar rc <<<"$FIXTURE_OUTPUT")" ] \
        || fail "the record's rc scalar disagrees with the process exit code:" "$fixture/parkkill/output.txt"

    # (a) the node settles loudly as lost 125 park-marker-unwritable
    [ "$(rr2_outcome a status <<<"$FIXTURE_OUTPUT")" = "failed" ] \
        || fail "the failing package is not recorded as failed:" "$fixture/parkkill/output.txt"
    [ "$(rr2_outcome b status <<<"$FIXTURE_OUTPUT")" = "failed" ] \
        || fail "the broken stand-down must settle b as failed (§F.1):" "$fixture/parkkill/output.txt"
    [ "$(rr2_outcome b rc <<<"$FIXTURE_OUTPUT")" = "125" ] \
        || fail "the broken stand-down settles as lost (125):" "$fixture/parkkill/output.txt"
    [ "$(rr2_outcome b reason <<<"$FIXTURE_OUTPUT")" = "park-marker-unwritable" ] \
        || fail "the row does not name the broken handshake (§H.3):" "$fixture/parkkill/output.txt"
    vgrep "$FIXTURE_OUTPUT" -F "park marker" >/dev/null \
        || fail "the marker failure is loud:" "$fixture/parkkill/output.txt"
    vgrep "$FIXTURE_OUTPUT" -F "cannot be written" >/dev/null \
        || fail "the marker failure is loud:" "$fixture/parkkill/output.txt"
    vgrep "$FIXTURE_OUTPUT" -F "late lane result for b ignored" >/dev/null \
        || fail "the late result of the settled node is ignored, loudly:" "$fixture/parkkill/output.txt"

    # (b) the rogue lane is GONE and never built: a stand-down that cannot be
    # delivered must not leave the lane building (shared SRCDEST/build caches)
    if [ -f "$verdict" ]; then
        fail "the rogue lane survived the broken stand-down:" "$verdict"
    fi
    [ ! -f "$ws/packages/b/b-1.0.0-1-any.pkg.tar.zst" ] \
        || fail "the rogue lane kept building after its stand-down failed:" "$fixture/parkkill/output.txt"

    # child-process hygiene: nothing survives the run (§K.3)
    if ps -eo args= | grep -F "$ws" | grep -v grep >/dev/null; then
        fail "a lane child of $ws remained after the run"
    fi
)

printf 'gsa-sched-v2 fixture: PASS\n'
