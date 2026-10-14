#!/usr/bin/env bash
set -euo pipefail

# tests/gsa-v2-lib.sh — self-test for tests/lib/rr-v2.bash, the v2 fixture
# library that the staged engine migration introduces (docs/gsa-fixture-
# migration.md). Pinned here:
#   1. the golden `format: 2` block (the annotated example of
#      docs/gsa-contract.md §H.4 with its `<-` comments stripped) parses
#      STRICTLY: every scalar, plan row, outcome row (incl. `parked` with
#      `- -`), and continuation line extracts correctly, and the derived
#      resume set agrees with the `remaining:` continuation line.
#   2. every malformed-block shape is REJECTED with a reason on stderr that
#      names what broke (format: 1 blocks, scalar order/duplication, bad
#      plan/status values, bad rc shapes and status/code mismatches, unknown
#      continuation keys, missing/duplicate sections, two blocks, stray
#      markers, control characters, row/order disagreement).
#   3. run_engine dispatches to the selected engine (gsa by default since the
#      Phase 5 cutover; GSA_TEST_ENGINE=fish runs the frozen oracle copy) and
#      captures output and exit status like run_builder.
#   4. the GSA_FAKE_* stub-knob registry (§D.2) accepts declared knobs and
#      rejects non-GSA_FAKE_* names and conflicting redeclarations.
#
# The fixture is non-mutating and $TMPDIR-scoped like every battery member:
# all scratch lives in one mktemp tree removed by the trap, and nothing it
# writes is read by any sibling fixture, so it is parallel-safe.

source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-v2-lib.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf '%s\n' "$1" >&2
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
        sed 's/^/    /' "$2" >&2
    fi
    exit 1
}

# The golden format: 2 block: docs/gsa-contract.md §H.4's annotated example,
# comments removed. It is the parser fixture §L.2 requires a grammar change to
# update in the same change.
cat >"$fixture/golden.txt" <<'EOF'
--- run record begin ---
format: 2
selection-source: sets=@git leaf=no range=-
order: glib2-git gtk4-git gimp-git niri-spicy-git
lanes: 2
normal-jobs: 6
core-jobs: 4
intensity: xhigh
outcome: failed
rc: 4
--- plan ---
glib2-git build-install ok
gtk4-git build-install ok
gimp-git build-install ok
niri-spicy-git build-install ok
--- outcome ---
glib2-git failed 1 812 build-failed
gtk4-git parked - - waits-on-failed
gimp-git parked - - waits-on-failed
niri-spicy-git succeeded 0 1450 ok
--- continuation ---
command: gsa -S glib2-git gtk4-git gimp-git
remaining: glib2-git gtk4-git gimp-git
not-mirrored: -Mcc -Mccc -Sy
env-required: GSA_STATE_DIR
--- run record end ---
EOF

# ─── 1. Golden block: strict parse and field extraction ─────────────────────
(
    set -euo pipefail
    # rr2_body validates and extracts the block body (markers stripped) from
    # the RAW stream; the accessors below take that same raw stream.
    body=$(rr2_body <"$fixture/golden.txt") || fail "rr2_body rejects the golden format: 2 block"
    [[ $body == *"format: 2"* ]] || fail "rr2_body body lost the scalars"
    [[ $body != *"run record begin"* ]] || fail "rr2_body body still carries the begin marker"

    rr2_scalar format <"$fixture/golden.txt" | grep -Fx 2 >/dev/null \
        || fail "rr2_scalar format = [$(rr2_scalar format <"$fixture/golden.txt")], want [2]"
    [[ $(rr2_scalar selection-source <"$fixture/golden.txt") == "sets=@git leaf=no range=-" ]] \
        || fail "rr2_scalar selection-source = [$(rr2_scalar selection-source <"$fixture/golden.txt")]"
    [[ $(rr2_scalar order <"$fixture/golden.txt") == "glib2-git gtk4-git gimp-git niri-spicy-git" ]] \
        || fail "rr2_scalar order = [$(rr2_scalar order <"$fixture/golden.txt")]"
    [[ $(rr2_scalar lanes <"$fixture/golden.txt") == 2 ]] || fail "rr2_scalar lanes wrong"
    [[ $(rr2_scalar normal-jobs <"$fixture/golden.txt") == 6 ]] || fail "rr2_scalar normal-jobs wrong"
    [[ $(rr2_scalar core-jobs <"$fixture/golden.txt") == 4 ]] || fail "rr2_scalar core-jobs wrong"
    [[ $(rr2_scalar intensity <"$fixture/golden.txt") == xhigh ]] || fail "rr2_scalar intensity wrong"
    [[ $(rr2_scalar outcome <"$fixture/golden.txt") == failed ]] || fail "rr2_scalar outcome wrong"
    [[ $(rr2_scalar rc <"$fixture/golden.txt") == 4 ]] || fail "rr2_scalar rc wrong"

    # plan rows: full set in order, plan value and reason extract per package
    rows=$(rr2_plan_rows <"$fixture/golden.txt" | tr '\n' ' ')
    [[ $rows == "glib2-git build-install ok gtk4-git build-install ok gimp-git build-install ok niri-spicy-git build-install ok " ]] \
        || fail "rr2_plan_rows = [$rows], want the four §H.4 plan rows"
    [[ $(rr2_plan gtk4-git <"$fixture/golden.txt") == "gtk4-git build-install ok" ]] \
        || fail "rr2_plan gtk4-git = [$(rr2_plan gtk4-git <"$fixture/golden.txt")]"
    [[ $(rr2_plan gimp-git plan <"$fixture/golden.txt") == build-install ]] \
        || fail "rr2_plan gimp-git plan wrong"
    [[ $(rr2_plan glib2-git reason <"$fixture/golden.txt") == ok ]] \
        || fail "rr2_plan glib2-git reason wrong"

    # outcome rows: statuses incl. parked with rc/dur `-`, reasons as remainder
    [[ $(rr2_outcome_rows <"$fixture/golden.txt" | wc -l) == 4 ]] \
        || fail "rr2_outcome_rows lost a row"
    [[ $(rr2_outcome glib2-git status <"$fixture/golden.txt") == failed ]] \
        || fail "rr2_outcome glib2-git status wrong"
    [[ $(rr2_outcome glib2-git rc <"$fixture/golden.txt") == 1 ]] || fail "rr2_outcome glib2-git rc wrong"
    [[ $(rr2_outcome glib2-git dur <"$fixture/golden.txt") == 812 ]] || fail "rr2_outcome glib2-git dur wrong"
    [[ $(rr2_outcome glib2-git reason <"$fixture/golden.txt") == build-failed ]] \
        || fail "rr2_outcome glib2-git reason wrong"
    [[ $(rr2_outcome gtk4-git status <"$fixture/golden.txt") == parked ]] \
        || fail "rr2_outcome gtk4-git status = [$(rr2_outcome gtk4-git status <"$fixture/golden.txt")], want parked"
    [[ $(rr2_outcome gtk4-git rc <"$fixture/golden.txt") == - ]] || fail "parked row rc must be -"
    [[ $(rr2_outcome gtk4-git dur <"$fixture/golden.txt") == - ]] || fail "parked row dur must be -"
    [[ $(rr2_outcome gtk4-git reason <"$fixture/golden.txt") == waits-on-failed ]] \
        || fail "rr2_outcome gtk4-git reason = [$(rr2_outcome gtk4-git reason <"$fixture/golden.txt")]"
    [[ $(rr2_outcome niri-spicy-git status <"$fixture/golden.txt") == succeeded ]] \
        || fail "rr2_outcome niri-spicy-git status wrong"

    # continuation lines, and derived vs declared resume set
    [[ $(rr2_continuation command <"$fixture/golden.txt") == "gsa -S glib2-git gtk4-git gimp-git" ]] \
        || fail "rr2_continuation command wrong"
    [[ $(rr2_continuation remaining <"$fixture/golden.txt") == "glib2-git gtk4-git gimp-git" ]] \
        || fail "rr2_continuation remaining wrong"
    [[ $(rr2_continuation not-mirrored <"$fixture/golden.txt") == "-Mcc -Mccc -Sy" ]] \
        || fail "rr2_continuation not-mirrored wrong"
    [[ $(rr2_continuation env-required <"$fixture/golden.txt") == "GSA_STATE_DIR" ]] \
        || fail "rr2_continuation env-required wrong"
    derived=$(rr2_remaining <"$fixture/golden.txt" | tr '\n' ' ')
    [[ ${derived% } == "glib2-git gtk4-git gimp-git" ]] \
        || fail "rr2_remaining = [$derived], want the three non-succeeded rows"
    [[ $(rr2_remaining <"$fixture/golden.txt" | tr '\n' ' ') == "$(rr2_continuation remaining <"$fixture/golden.txt" | sed 's/$/ /')" ]] \
        || fail "derived resume set disagrees with the remaining: continuation line"

    # §H.2: extension scalars append after the fixed set without a format bump
    sed 's/^--- plan ---$/extra-note: hello\n--- plan ---/' "$fixture/golden.txt" >"$fixture/extended.txt"
    rr2_body <"$fixture/extended.txt" >/dev/null \
        || fail "an extension scalar after the fixed set is rejected"
    [[ $(rr2_scalar extra-note <"$fixture/extended.txt") == hello ]] \
        || fail "rr2_scalar extra-note = [$(rr2_scalar extra-note <"$fixture/extended.txt")]"

    # accessor failures name what is missing
    if rr2_scalar nosuch-key <"$fixture/golden.txt" >/dev/null 2>"$fixture/s1.err"; then
        fail "rr2_scalar accepted an absent key"
    fi
    grep -F 'no nosuch-key scalar' "$fixture/s1.err" >/dev/null \
        || fail "rr2_scalar absence reason missing" "$fixture/s1.err"
    if rr2_outcome glib2-git flux <"$fixture/golden.txt" >/dev/null 2>"$fixture/s2.err"; then
        fail "rr2_outcome accepted an unknown field"
    fi
    grep -F 'unknown field flux' "$fixture/s2.err" >/dev/null \
        || fail "rr2_outcome field reason missing" "$fixture/s2.err"
)

# ─── 2. Malformed blocks are rejected with a reason ─────────────────────────
# Each case derives from the golden block, breaks exactly one thing, and
# asserts the rejection names it. The reason strings are rr2_body's, so a
# parser change that loses a diagnostic fails here.
(
    set -euo pipefail
    g="$fixture/golden.txt"

    expect_reject() { # $1 = case name, $2 = reason substring, block on stdin
        local name=$1 want=$2
        if rr2_body >"$fixture/$name.body" 2>"$fixture/$name.err"; then
            fail "$name: the malformed block was ACCEPTED"
        fi
        grep -F "$want" "$fixture/$name.err" >/dev/null \
            || fail "$name: rejection reason does not name '$want'" "$fixture/$name.err"
    }

    sed 's/^format: 2$/format: 1/' "$g" | expect_reject format-one 'unsupported format 1'
    grep -v '^rc: 4$' "$g" | expect_reject missing-scalar 'missing scalar rc'
    awk '{ if ($0 == "lanes: 2") { held = $0; next } print; if ($0 == "normal-jobs: 6") print held }' "$g" \
        | expect_reject scalar-order 'want lanes next'
    awk '1; /^rc: 4$/{print}' "$g" | expect_reject duplicate-scalar 'duplicate scalar rc'
    sed 's/^lanes: 2$/lanes: two/' "$g" | expect_reject noninteger-scalar 'must be a non-negative integer'
    sed 's/glib2-git build-install ok/glib2-git assemble ok/' "$g" \
        | expect_reject unknown-plan 'unknown plan value assemble'
    sed 's/^gtk4-git build-install ok$/gtk4-git build-install/' "$g" \
        | expect_reject plan-no-reason 'malformed plan row'
    sed 's/niri-spicy-git succeeded 0 1450 ok/niri-spicy-git completed 0 1450 ok/' "$g" \
        | expect_reject unknown-status 'unknown outcome status completed'
    sed 's/glib2-git failed 1 812 build-failed/glib2-git failed x 812 build-failed/' "$g" \
        | expect_reject bad-rc 'is not an integer or -'
    sed 's/glib2-git failed 1 812 build-failed/glib2-git succeeded 1 812 ok/' "$g" \
        | expect_reject rc-status-mismatch 'is not a lane code for status succeeded'
    sed 's/gtk4-git parked - - waits-on-failed/gtk4-git never-started 1 3 dispatch-stopped/' "$g" \
        | expect_reject neverstarted-rc 'is not a lane code for status never-started'
    sed 's/^env-required: GSA_STATE_DIR$/env-required: GSA_STATE_DIR\nreplay: gsa -S p1/' "$g" \
        | expect_reject unknown-cont-key 'unknown continuation key replay'
    awk '1; /^command: /{print}' "$g" | expect_reject duplicate-cont-key 'duplicate continuation key command'
    awk '/^--- outcome ---$/{print "--- run record end ---"; exit} {print}' "$g" \
        | expect_reject missing-section 'missing section outcome'
    cat "$g" "$g" | expect_reject two-blocks 'exactly one run-record block'
    sed 's/^--- plan ---$/--- summary ---/' "$g" | expect_reject stray-marker 'unexpected marker line'
    sed 's/glib2-git build-install ok/glib2-git\tbuild-install ok/' "$g" \
        | expect_reject control-char 'control character'
    awk '1; /^glib2-git build-install ok$/{print}' "$g" | expect_reject duplicate-plan-row 'duplicate plan row'
    awk '
        /^glib2-git failed 1 812 build-failed$/ { held = $0; next }
        /^niri-spicy-git succeeded 0 1450 ok$/ { print; print held; next }
        { print }
    ' "$g" | expect_reject order-mismatch 'does not match order scalar position'
    printf 'prose only, no block\n' | expect_reject no-block 'no run-record block found'
    sed '$d' "$g" | expect_reject unclosed 'is not closed'
)

# ─── 3. run_engine: engine dispatch and capture ─────────────────────────────
(
    set -euo pipefail
    ws="$fixture/engine/ws"
    mkdir -p "$ws" "$fixture/engine/bin"
    : >"$ws/build-all.fish"
    for name in fish gsa; do
        cat >"$fixture/engine/bin/$name" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s %s\n' "$(basename "$0")" "$*" >>"${GSA_FAKE_ENGINE_LOG:?}"
printf 'engine stdout: %s\n' "$*"
printf 'engine stderr: %s\n' "$*" >&2
exit "${GSA_FAKE_ENGINE_RC:-0}"
EOF
        chmod +x "$fixture/engine/bin/$name"
    done
    export PATH="$fixture/engine/bin:$PATH"
    export GSA_FAKE_ENGINE_LOG="$fixture/engine/engine.log"
    export GSA_TEST_GSA_BIN="$fixture/engine/bin/gsa"

    # default engine (no GSA_TEST_ENGINE) is the NATIVE one since the Phase 5
    # cutover: `gsa …` run inside the workspace
    unset GSA_TEST_ENGINE
    run_engine "$ws" -Sl @git
    ((FIXTURE_RC == 0)) || fail "run_engine gsa rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
    [[ $(tail -n1 "$GSA_FAKE_ENGINE_LOG") == "gsa -Sl @git" ]] \
        || fail "run_engine default argv = [$(tail -n1 "$GSA_FAKE_ENGINE_LOG")] (want the native engine)"
    [[ $FIXTURE_OUTPUT == *"engine stdout:"*"-Sl @git"* ]] \
        || fail "run_engine lost engine stdout: $FIXTURE_OUTPUT"
    [[ $FIXTURE_OUTPUT == *"engine stderr:"*"-Sl @git"* ]] \
        || fail "run_engine does not capture stderr (2>&1): $FIXTURE_OUTPUT"

    # GSA_TEST_ENGINE=fish runs the FROZEN ORACLE copy beside the workspace
    # (tests/lib/fixture-lib.bash install_fish_oracle) — oracle comparison
    # only, never an engine
    export GSA_TEST_ENGINE=fish
    run_engine "$ws" -Sl @git
    ((FIXTURE_RC == 0)) || fail "run_engine fish rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
    [[ $(tail -n1 "$GSA_FAKE_ENGINE_LOG") == "fish $ws/build-all.fish -Sl @git" ]] \
        || fail "run_engine fish argv = [$(tail -n1 "$GSA_FAKE_ENGINE_LOG")]"
    unset GSA_TEST_ENGINE

    # the engine's exit status passes through untouched (like run_builder)
    export GSA_FAKE_ENGINE_RC=7
    run_engine "$ws" -S p1
    ((FIXTURE_RC == 7)) || fail "run_engine rc passthrough: got $FIXTURE_RC, want 7"
    unset GSA_FAKE_ENGINE_RC

    # an unknown engine is a loud usage error naming the value
    export GSA_TEST_ENGINE=bogus
    run_engine "$ws" 2>"$fixture/engine/unknown.err"
    ((FIXTURE_RC == 2)) || fail "unknown engine rc=$FIXTURE_RC, want 2"
    grep -F "unknown engine 'bogus'" "$fixture/engine/unknown.err" >/dev/null \
        || fail "unknown-engine reason missing" "$fixture/engine/unknown.err"
    unset GSA_TEST_ENGINE
)

# ─── 4. GSA_FAKE_* stub-knob registry (§D.2) ────────────────────────────────
(
    set -euo pipefail
    rr2_stub_knobs >"$fixture/knobs.txt"
    grep -F $'GSA_FAKE_ENGINE_LOG\t' "$fixture/knobs.txt" >/dev/null \
        || fail "GSA_FAKE_ENGINE_LOG is not declared in the knob vocabulary" "$fixture/knobs.txt"
    grep -F $'GSA_FAKE_ENGINE_RC\t' "$fixture/knobs.txt" >/dev/null \
        || fail "GSA_FAKE_ENGINE_RC is not declared in the knob vocabulary"
    grep -F $'GSA_FAKE_SUDO_MODE\t' "$fixture/knobs.txt" >/dev/null \
        || fail "carried knob GSA_FAKE_SUDO_MODE is missing from the v2 vocabulary"

    if rr2_stub_knob GSA_LANES 'engine input' 2>"$fixture/knobs.err"; then
        fail "rr2_stub_knob accepted an engine-input name"
    fi
    grep -F 'is not a GSA_FAKE_* name' "$fixture/knobs.err" >/dev/null \
        || fail "non-GSA_FAKE_* rejection reason missing" "$fixture/knobs.err"

    rr2_stub_knob GSA_FAKE_PROBE 'self-test knob' >/dev/null
    if rr2_stub_knob GSA_FAKE_PROBE 'a different description' 2>"$fixture/knobs2.err"; then
        fail "rr2_stub_knob accepted a conflicting redeclaration"
    fi
    grep -F 'redeclared with a different description' "$fixture/knobs2.err" >/dev/null \
        || fail "redeclaration rejection reason missing" "$fixture/knobs2.err"
)

printf 'gsa v2 library fixture: PASS\n'
