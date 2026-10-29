#!/usr/bin/env bash
set -euo pipefail

# app group + TTY multi-select prompt fixture — FULLY FLIPPED to the native
# engine (`gsa`, docs/gsa-contract.md §B.4/§B.5/§C/§C.4/§G.1/§H.2): the
# loader/selection sections (`gsa 1`-`gsa 7`) and the PTY multi-select prompt
# sections (5-12) all run through the engine — the §C.4 prompt landed in
# crates/gsa-cli (prompt.rs + select.rs's build_selection_for_build) and the
# fish build-all.fish driver is gone from this fixture. See
# docs/gsa-fixture-migration.md row `tests/app-group.sh`.
#
# Pins (decisions recorded in docs/NOTE.md 2026-09-23; bracket = the surface
# that pins each today):
#   1. loader demands config/topology.conf (a missing file = rc 2 naming it;
#      a record naming no group is rc 2 naming the record and its line; the
#      roster is the builder's six names — git, stable, core, misc, app,
#      build-tools)      [gsa 1]
#   2. an app group with NO member refuses (rc 2, `selection resolved to no
#      packages` §C.1) — never a phantom member      [gsa 2]
#   3. a non-TTY run takes the whole group silently and the group's edges
#      never pull upstream — a build-order edge to a non-app workspace
#      package must NOT drag that package into the run (expansion walks
#      CONSUMERS only, §C.3)      [gsa 3]
#   4. a listing never prompts (a prompt on a PTY with no input would
#      abort/hang, so exit 0 with the whole list proves silence) and never
#      builds (zero makepkg spawns)      [gsa 4]
#   5. on a PTY: Enter = whole group, numbers = the checked subset (plus its
#      consumers), q = non-zero abort; and ONLY an `@app` selection prompts —
#      a positional app member builds without a menu (§C.4, fish-era
#      `test "$g" = app`)      [fish 5-7 — engine gap]
#   6. -g app combined with -g git: the union of both groups' expansions
#      dedupes into one topological order and its rows are the anchor space
#      for ranges (§C.3/§C.5)      [gsa 6]; the prompt filtering only the
#      app portion is fish 8      [engine gap]
#   7. a REAL build of a subset builds exactly the subset plus its consumers,
#      and the run record's `order:` says so (§H.2)      [gsa 7]; the
#      prompt-mediated version (checked subset, recorded selection) is fish
#      9      [engine gap]
#   8. app-cluster=<name> members share ONE toggle row labelled
#      '<name> [member ids]' (a cluster member never renders its own row);
#      toggling that row checks/clears EVERY member at once, and the
#      "N checked" notice counts ROWS — a checked cluster reads "1 checked"
#      while its run record selects all of the members
#   9. an untagged member's row toggles independently of the cluster row
#  10. all-unchecked + Enter still builds the whole group, cluster members
#      included
#      [8-10: fish 10-12 — engine gap; cluster presentation is prompt-side
#       only (§C.4), and the engine's listing keeps the members separate]
#
# Flip notes:
#   * argv: `--list`/`-l` -> `gsa -Sl`, `-g app` -> `@app` (§B.4/§B.9/§C.2),
#     `-n` -> `gsa -B --dry-run`. DEVIATION from the inventory row's
#     `gsa -S @app --dry-run`: the scenario is build-only (§B.5 — the fish
#     `-n` built and installed nothing), and `gsa -S … --dry-run` plans
#     `build-install` rows (install semantics this fixture never pins;
#     measured 2026-10-12: `gsa -S @app --dry-run` renders
#     `appN build-install ok` and transacts nothing itself).
#   * expectations are DERIVED (docs/MEMORY.md rule 25(j)): membership is a
#     transitive-consumer closure computed from `gsa -Qt` rows (§B.3 — the
#     only topology channel, never config/), anchors come from the `gsa -Sl`
#     output itself, and recorded selections from the run record — never
#     pinned counts.
#   * prose: byte-pinned diagnostics retire to meaning, except the loader
#     roster pin (the inventory's KEEP cell covers old :143-157 and gsa
#     prints the same six-name list — measured). The `prompt skipped` and
#     `the app list is empty` sentences are fish rendering; their meanings
#     (a silent whole-group selection; a refusal aimed at an empty app list)
#     re-pin structurally.
#   * rr-format1: the ≈16 `rr_scalar`/`rr_row` sites (old :293-302, :349,
#     :366) all sit in kept-fish prompt scenarios (prompt-recorded
#     selections — engine gap) and stay `format: 1` until the prompt lands;
#     the same record semantics re-pin on the engine as `format: 2` through
#     rr2_* in `gsa 7`.
#   * dry-run records parse through the strict rr2_body reader like every
#     other `format: 2` block: the §H.2 budget-conformance amendment renders
#     `lanes`/`normal-jobs`/`core-jobs` as `0` — never `-` — for a record
#     whose run dispatched nothing, and the pins assert those zeros
#     (tests/project.sh's early lenient extractor retired with its shape).
#   * kept-fish sections 5/6 cross-check their prompt anchors against the
#     scenario-4 listing file ($fixture/o4), which the flip now produces with
#     `gsa -Sl @app` — the row shape (`<index>. <id>`) is shared and both
#     engines agree on this topology's app order (measured), so the kept
#     assertions are byte-unchanged.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-app-fixture.XXXXXX")
trap '/usr/bin/sudo -n rm -rf -- "$fixture" 2>/dev/null || rm -rf -- "$fixture" 2>/dev/null || true' EXIT

fail() {
    printf '%s\n' "$1" >&2
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
        sed 's/^/    /' "$2" >&2
    fi
    exit 1
}

# The engine under test: the INSTALLED binary (contract §L.10);
# GSA_TEST_GSA_BIN is the explicit pre-install override (rr-v2.bash). The fish half below
# still runs build-all.fish from the same workspace verbatim.
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

# ── Synthetic workspace: five fake packages, one topology record each ───────
make_workspace "$fixture" auto auto xhigh
install_fish_oracle "$fixture"

# pkgver=1 (not the helper's $gsa_meta_any default) keeps these PKGBUILDs
# byte-identical to the hand-written skeleton this replaced.
for pair in "git:gitp1" "misc:extdep" "app:app1 app2 app3"; do
    grp=${pair%%:*}
    members=${pair#*:}
    for id in $members; do
        add_package "$fixture" "$id" $'pkgver=1\npkgrel=1\narch=(any)' "$grp"
    done
done

# app2 consumes extdep (a NON-app workspace package — upstream, must never be
# pulled in) and app3 consumes app2 (in-group edge: fixes build order, and
# makes app3 a consumer a checked app2 must pull along).
set_topology_record "$fixture" app2 app 'extdep'
set_topology_record "$fixture" app3 app 'app2'

cat >"$fixture/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -eu
id=$(basename "$PWD")
printf 'fake makepkg %s\n' "$PWD"
# SPAWN/END log: which packages a run actually built. This is the gsa half's
# built/unbuilt channel — its ABSENCE is the "a listing never builds" pin,
# and `gsa 7` falsifies the channel by requiring spawns for built packages.
[ -n "${GSA_FAKE_SPAWN_LOG:-}" ] && printf 'SPAWN %s\n' "$id" >>"$GSA_FAKE_SPAWN_LOG"
sleep "${GSA_FAKE_BUILD_SECONDS:-0.05}"
[ -n "${GSA_FAKE_SPAWN_LOG:-}" ] && printf 'END %s\n' "$id" >>"$GSA_FAKE_SPAWN_LOG"
: >"$PWD/$id-1-1-any.pkg.tar.zst"
EOF
chmod +x "$fixture/bin/makepkg"

# The same rows as 'anchor name' pairs — the printed anchor VALUES (the
# pairing a later range filter relies on), not just the names. Anchors are
# unfiltered-closure positions, so a prompt-filtered run prints gaps.
order_pairs() {
    sed -n '/Build order (dry run):/,/^Total:/p' "$1" \
        | grep -E '^ +[0-9]+\. ' | awk '{sub(/\.$/, "", $1); print $1, $2}' | tr -d '\r'
}

# First menu render of a capture (a toggle input RE-renders the menu; the row
# structure is decided in the first render, before any input is consumed):
# from the "choose what to build" header through the input hint line.
first_menu() {
    awk '/choose what to build/ { seen = 1 }
         seen { print }
         seen && /numbers toggle/ { exit }' "$1" | sed 's/\r$//'
}

# The numbered toggle rows of that first render, labels only — the data a
# row-count/label pin asserts on (never a full-screen snapshot).
menu_rows() {
    first_menu "$1" | sed -n 's/^ *\[.\] *[0-9]*\. //p'
}

# ── gsa-half helpers: structural readers and derivations ────────────────────

# listing_rows / listing_pairs — the `gsa -Sl` index rows of a capture, as
# bare names, or as 'anchor name' pairs (CR-stripped for PTY captures). The
# indices ARE the anchor semantics (§C.3: ranges address the listing's rows),
# so the row rendering is data here; no heading or footer wording is matched
# (tests/scheduler-dispatch-order.sh's listing_rows approach).
listing_rows() {
    awk '{ sub(/\r$/, "") } /^ *[0-9]+\.[ ]/ { print $2 }' "$@"
}

listing_pairs() {
    awk '{ sub(/\r$/, "") }
         /^ *[0-9]+\.[ ]/ { sub(/^ */, ""); sub(/\.$/, "", $1); print $1, $2 }' "$@"
}

# qt_ids / group_members — the `gsa -Qt` topology channel (`id|path|groups|
# edges|tags`, §B.3): the only topology reader. Every membership and
# expansion expectation below closes over these rows, never over config/.
qt_ids() {
    awk -F'|' '{ print $1 }' "$1"
}

group_members() { # QT-FILE GROUP — ids whose record lists GROUP, sorted
    awk -F'|' -v g="$2" \
        '{ n = split($3, gs, ","); for (i = 1; i <= n; i++) if (gs[i] == g) print $1 }' "$1" | sort
}

# expanded_set QT-FILE SEEDS-FILE — the seeds plus their transitive
# CONSUMERS (§C.3: a record listing B in `edges` consumes B), sorted: the set
# a selection must resolve to. Prerequisites are never expanded — a seed's
# upstream is in the set only if something else seeds or consumes it.
expanded_set() {
    awk -F'|' '
        NR == FNR { seed[$1] = 1; next }
        {
            n = split($4, es, ",")
            for (i = 1; i <= n; i++) if (es[i] != "") cons[es[i]] = cons[es[i]] " " $1
        }
        END {
            for (s in seed) { seen[s] = 1; queue[++q] = s }
            while (q > 0) {
                cur = queue[q--]
                m = split(cons[cur], cs, " ")
                for (i = 1; i <= m; i++) \
                    if (cs[i] != "" && !(cs[i] in seen)) { seen[cs[i]] = 1; queue[++q] = cs[i] }
            }
            for (k in seen) print k
        }' "$2" "$1" | sort
}

# assert_topological QT-FILE ORDER-LINE — every build-order edge's
# prerequisite precedes its consumer in ORDER (§C.5: one order everywhere).
assert_topological() {
    awk -F'|' -v order="$2" '
        BEGIN { n = split(order, ids, " "); for (i = 1; i <= n; i++) pos[ids[i]] = i }
        {
            m = split($4, es, ",")
            for (i = 1; i <= m; i++) \
                if (es[i] != "" && pos[$1] && pos[es[i]] && !(pos[es[i]] < pos[$1])) {
                    printf("order %s is not topological: %s must precede %s\n", order, es[i], $1) > "/dev/stderr"
                    bad = 1
                }
        }
        END { exit bad }' "$1" || fail "the reported order violates the fixture's build-order edges"
}

# sorted_ids IDS — the space-separated id list as sorted lines (set compares).
sorted_ids() {
    printf '%s\n' $1 | sort
}

# run_pty_gsa / run_pty_gsa_user <input printf fmt> <outfile> [args...] —
# the gsa twins of run_pty: the engine under a PTY with scripted stdin
# (proves a listing never reads its input; nothing here asserts colours or
# rendering). The ROOT SEAM is rr2_engine_argv — run_pty_gsa models
# `sudo gsa` (the real-build sections: a mutation the engine refuses for a
# plain user, contract §B.10) exactly like run_engine; run_pty_gsa_user is
# the unprivileged twin (the dry-run/read shapes run_engine_user models)
# and the ONLY shape where a typed EOF (^D) reaches the engine — sudo's
# PTY pump swallows the EOF condition (measured: the inner side sees a NUL
# and blocks). script(1) -c hands its command string to $SHELL (fish on
# this host) and the argv carries %q-quoted values, so the invocation is
# staged through a small bash runner and the string script parses stays
# plain argv.
_run_pty_gsa_mode() {
    local mode=$1 input="$2" out="$3"
    shift 3
    local -a argv=()
    rr2_engine_argv "$mode" "$fixture" argv "$@"
    local runner="$fixture/.rr2-pty-runner.sh"
    {
        printf '#!/bin/bash\n'
        printf 'cd %q || exit 127\n' "$fixture"
        printf 'exec'
        printf ' %q' "${argv[@]}"
        printf '\n'
    } >"$runner"
    set +e
    printf '%b' "$input" | \
        timeout 60 env TERM=dumb \
            script -qec "/bin/bash $(printf %q "$runner")" /dev/null >"$out" 2>&1
    RC=$?
    set -e
    return "$RC"
}

run_pty_gsa() {
    _run_pty_gsa_mode sudo "$@"
}

run_pty_gsa_user() {
    _run_pty_gsa_mode user "$@"
}

# ── gsa 1. Loader: a missing topology file is an error; the roster is six
# names (flipped: `--list` -> `gsa -Sl` as the loader driver; rc 2 §G.1) ────
mv "$fixture/config/topology.conf" "$fixture/topology.conf.bak"
run_engine "$fixture" -Sl
printf '%s\n' "$FIXTURE_OUTPUT" >"$fixture/o1"
if [ "$FIXTURE_RC" = 0 ]; then
    fail "loader accepted a workspace without config/topology.conf" "$fixture/o1"
fi
[ "$FIXTURE_RC" = 2 ] \
    || fail "missing-config error is not a usage error (rc=$FIXTURE_RC, want 2 §G.1)" "$fixture/o1"
grep -q 'config/topology.conf' "$fixture/o1" \
    || fail "loader error does not name the missing config/topology.conf" "$fixture/o1"
mv "$fixture/topology.conf.bak" "$fixture/config/topology.conf"
# The loader's roster wording is its own closed six-name list — pin the text
# it prints, not just "some roster" (KEEP cell :143-157; gsa prints the same
# list — measured 2026-10-12).
set_topology_record "$fixture" gitp1 '' ''
run_engine "$fixture" -Sl
printf '%s\n' "$FIXTURE_OUTPUT" >"$fixture/o1g"
if [ "$FIXTURE_RC" = 0 ]; then
    fail "loader accepted a record naming no group" "$fixture/o1g"
fi
[ "$FIXTURE_RC" = 2 ] \
    || fail "no-group refusal is not a usage error (rc=$FIXTURE_RC, want 2 §G.1)" "$fixture/o1g"
grep -q 'gitp1' "$fixture/o1g" \
    || fail "loader error does not name the offending record gitp1" "$fixture/o1g"
# §G.1/§C.5 name the offender WITH its line — derived from the file itself.
want_line=$(grep -n '^gitp1|' "$fixture/config/topology.conf" | cut -d: -f1)
grep -q "topology.conf:$want_line:" "$fixture/o1g" \
    || fail "loader error does not name the offending record's line $want_line" "$fixture/o1g"
grep -qF 'names no group (allowed: git,stable,core,misc,app,build-tools)' "$fixture/o1g" \
    || fail "loader roster wording is not the six-name list" "$fixture/o1g"
set_topology_record "$fixture" gitp1 git ''

# ── gsa 2. Empty app membership: refuse with a usage error naming the
# no-selection reason (§C.1), never a phantom member (flipped: `-n -g app`
# -> `gsa -B --dry-run @app`) ───────────────────────────────────────────────
# App members keep their category-group membership in the real tree, so mirror
# that here: app1..app3 records move to the git group while no record carries
# app in its groups field.
set_topology_record "$fixture" app1 git ''
set_topology_record "$fixture" app2 git 'extdep'
set_topology_record "$fixture" app3 git 'app2'
run_engine "$fixture" -B --dry-run @app
printf '%s\n' "$FIXTURE_OUTPUT" >"$fixture/o2"
if [ "$FIXTURE_RC" = 0 ]; then
    fail "-B --dry-run @app succeeded with no app-group member" "$fixture/o2"
fi
[ "$FIXTURE_RC" = 2 ] \
    || fail "empty app membership is not a usage error (rc=$FIXTURE_RC, want 2 §G.1)" "$fixture/o2"
# The fish-era 'the app list is empty' populate hint is fish rendering
# (retired); the kept meaning is a refusal AIMED at the empty selection — the
# §C.1 reason key is named.
grep -q 'selection resolved to no packages' "$fixture/o2" \
    || fail "empty app membership lacks the no-selection error" "$fixture/o2"
# No phantom member: the refusal carries neither listing rows nor a record.
grep -qE '^ *[0-9]+\. ' "$fixture/o2" \
    && fail "empty app membership invented a member row" "$fixture/o2"
grep -q -- '--- run record begin ---' "$fixture/o2" \
    && fail "empty app membership produced a run record" "$fixture/o2"
# The listing surface refuses the same way (a selection that resolves to zero
# packages is never a successful no-op).
run_engine "$fixture" -Sl @app
printf '%s\n' "$FIXTURE_OUTPUT" >"$fixture/o2l"
[ "$FIXTURE_RC" = 2 ] \
    || fail "-Sl @app with no member is not a usage error (rc=$FIXTURE_RC)" "$fixture/o2l"
grep -q 'selection resolved to no packages' "$fixture/o2l" \
    || fail "the listing refusal lacks the no-selection error" "$fixture/o2l"
set_topology_record "$fixture" app1 app ''
set_topology_record "$fixture" app2 app 'extdep'
set_topology_record "$fixture" app3 app 'app2'

# ── gsa 3. Non-TTY: whole group silently, upstream never pulled ────────────
# (flipped: `-n -g app` -> `gsa -B --dry-run @app`; build-only §B.5 — see the
# header's deviation note). The `prompt skipped` sentence is fish rendering
# (retired): the engine has no prompt at all, so the kept meaning is a
# non-TTY run taking the WHOLE group with no interactive selection — pinned
# by the selection itself below.
#
# The topology channel snapshot (§B.3) every derivation below closes over.
run_engine "$fixture" -Qt
[ "$FIXTURE_RC" = 0 ] || fail "gsa -Qt failed (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
printf '%s\n' "$FIXTURE_OUTPUT" >"$fixture/topology-channel.txt"
qt="$fixture/topology-channel.txt"
group_members "$qt" app >"$fixture/app.seeds"
expanded_set "$qt" "$fixture/app.seeds" >"$fixture/app.expected"

run_engine "$fixture" -B --dry-run @app
printf '%s\n' "$FIXTURE_OUTPUT" >"$fixture/o3"
[ "$FIXTURE_RC" = 0 ] || fail "non-TTY -B --dry-run @app failed" "$fixture/o3"
rr2_body <<<"$FIXTURE_OUTPUT" >/dev/null \
    || fail "the non-TTY dry-run record is not strict format: 2 (§H.2)" "$fixture/o3"
order=$(rr2_scalar order <<<"$FIXTURE_OUTPUT")
[ "$(sorted_ids "$order")" = "$(cat "$fixture/app.expected")" ] \
    || fail "non-TTY selection [$(sorted_ids "$order" | tr '\n' ' ')] != @app members + consumers [$(tr '\n' ' ' <"$fixture/app.expected")] (derived from gsa -Qt)" "$fixture/o3"
assert_topological "$qt" "$order"
[ "$(rr2_scalar selection-source <<<"$FIXTURE_OUTPUT")" = 'sets=@app leaf=no range=-' ] \
    || fail "the non-TTY run did not record expanded selection: $(rr2_scalar selection-source <<<"$FIXTURE_OUTPUT")" "$fixture/o3"
# §H.2 budget conformance: a record whose run dispatched nothing renders
# `lanes`/`normal-jobs`/`core-jobs` as `0` — never `-`.
for budget in lanes normal-jobs core-jobs; do
    [ "$(rr2_scalar "$budget" <<<"$FIXTURE_OUTPUT")" = 0 ] \
        || fail "dry-run budget scalar $budget is [$(rr2_scalar "$budget" <<<"$FIXTURE_OUTPUT")], want 0 (§H.2)" "$fixture/o3"
done
# The count is DATA (the record's rows — the derived set above), never a
# pinned count; and that set excludes extdep, the non-app workspace package
# app2 consumes. Expansion walks CONSUMERS only (§C.3): a build-order edge to
# a non-app package must never drag it in.
grep < <(printf '%s\n' $order) -qx extdep \
    && fail "app group pulled its non-app prerequisite extdep into the run" "$fixture/o3"
grep < <(printf '%s\n' $order) -qx gitp1 \
    && fail "app group pulled the unrelated git member gitp1 into the run" "$fixture/o3"

# ── gsa 4. -Sl: whole group, no prompt, no build (flipped: `-l -g app` ->
# `gsa -Sl @app`) ───────────────────────────────────────────────────────────
# The listed rows carry the membership (the header count is rendering): the
# rows are the data channel and must equal the derived selection. This is the
# listing file the kept fish sections 5/6 cross-check their prompt anchors
# against (header flip note).
GSA_FAKE_SPAWN_LOG="$fixture/o4.spawn" run_engine "$fixture" -Sl @app
printf '%s\n' "$FIXTURE_OUTPUT" >"$fixture/o4"
[ "$FIXTURE_RC" = 0 ] || fail "gsa -Sl @app failed (rc=$FIXTURE_RC)" "$fixture/o4"
rows=$(listing_rows <"$fixture/o4")
[ "$(sorted_ids "$rows")" = "$(cat "$fixture/app.expected")" ] \
    || fail "-Sl @app rows [$(sorted_ids "$rows" | tr '\n' ' ')] != derived selection [$(tr '\n' ' ' <"$fixture/app.expected")]" "$fixture/o4"
assert_topological "$qt" "$(printf '%s\n' $rows | paste -sd' ' -)"
# A listing performs NO build: zero makepkg spawns (the spawn channel is
# falsified in gsa 7, which requires a spawn for every built package) and no
# run record — a listing never starts a run.
[ ! -s "$fixture/o4.spawn" ] \
    || fail "the listing built packages (makepkg spawned):" "$fixture/o4.spawn"
grep -q -- '--- run record begin ---' "$fixture/o4" \
    && fail "the listing emitted a run record (it must never start a run)" "$fixture/o4"
# Never prompts — on a PTY with no input available a prompting listing would
# block (timeout) or abort on EOF; exit 0 with the whole list proves it never
# reads. The prompt MEANING kept here: gsa's listing path cannot prompt — the
# engine has no prompt code at all (header, engine-gap note), and §C.4 says
# listings take the whole group silently even on a TTY.
if ! run_pty_gsa '' "$fixture/o4p" -Sl @app; then
    fail "gsa -Sl @app on a PTY exited non-zero (it must never prompt)" "$fixture/o4p"
fi
[ "$(listing_rows <"$fixture/o4p")" = "$rows" ] \
    || fail "gsa -Sl @app on a PTY did not list the whole selection: got [$(listing_rows <"$fixture/o4p" | tr '\n' ' ')]" "$fixture/o4p"

# ── gsa 5. Anchor positions: range indices address the UNFILTERED selection
# (§C.3) — derived from the `gsa -Sl` output itself ─────────────────────────
# The full listing's 'anchor name' pairs are the unfiltered anchor map; a
# ranged listing keeps the anchors it addresses. (The prompt-filtered GAP
# half — anchors not renumbering after the prompt drops rows — is fish 6/8,
# engine gap.)
run_engine "$fixture" -Sl @app 2..3
printf '%s\n' "$FIXTURE_OUTPUT" >"$fixture/o5r"
[ "$FIXTURE_RC" = 0 ] || fail "gsa -Sl @app 2..3 failed (rc=$FIXTURE_RC)" "$fixture/o5r"
want_pairs=$(listing_pairs <"$fixture/o4" | sed -n '2,3p')
got_pairs=$(listing_pairs <"$fixture/o5r")
[ "$got_pairs" = "$want_pairs" ] \
    || fail "range 2..3 anchors wrong: got [$(echo "$got_pairs" | tr '\n' '|')], want [$(echo "$want_pairs" | tr '\n' '|')] (unfiltered positions from gsa -Sl @app)" "$fixture/o5r"
# Open-ended ranges keep the same anchors to the end of the selection.
run_engine "$fixture" -Sl @app 2..
printf '%s\n' "$FIXTURE_OUTPUT" >"$fixture/o5b"
[ "$FIXTURE_RC" = 0 ] || fail "gsa -Sl @app 2.. failed (rc=$FIXTURE_RC)" "$fixture/o5b"
want_tail=$(listing_pairs <"$fixture/o4" | sed -n '2,$p')
[ "$(listing_pairs <"$fixture/o5b")" = "$want_tail" ] \
    || fail "open-ended 2.. rows [$(listing_pairs <"$fixture/o5b" | tr '\n' '|')] but the listing from anchor 2 on is [$(echo "$want_tail" | tr '\n' '|')]" "$fixture/o5b"
# The dry run of the same range plans exactly those rows — one order
# everywhere (§C.5).
run_engine "$fixture" -B --dry-run @app 2..3
printf '%s\n' "$FIXTURE_OUTPUT" >"$fixture/o5d"
[ "$FIXTURE_RC" = 0 ] || fail "gsa -B --dry-run @app 2..3 failed (rc=$FIXTURE_RC)" "$fixture/o5d"
rr2_body <<<"$FIXTURE_OUTPUT" >/dev/null \
    || fail "the ranged dry-run record is not strict format: 2 (§H.2)" "$fixture/o5d"
[ "$(rr2_scalar order <<<"$FIXTURE_OUTPUT")" = "$(listing_rows <"$fixture/o5r" | paste -sd' ' -)" ] \
    || fail "ranged dry-run order [$(rr2_scalar order <<<"$FIXTURE_OUTPUT")] but the ranged listing is [$(listing_rows <"$fixture/o5r" | paste -sd' ' -)]" "$fixture/o5d"
[ "$(rr2_scalar selection-source <<<"$FIXTURE_OUTPUT")" = 'sets=@app leaf=no range=2..3' ] \
    || fail "the ranged dry run did not record its selection source: $(rr2_scalar selection-source <<<"$FIXTURE_OUTPUT")" "$fixture/o5d"

# ── gsa 6. Mixed groups: @app combined with @git is the deduplicated union of
# both expansions in one topological order (§C.3/§C.5) ──────────────────────
# (flipped: `-g app -g git` -> `@app @git`). The prompt half — the filter
# touching ONLY the app portion — is fish 8 (engine gap).
{ group_members "$qt" app; group_members "$qt" git; } >"$fixture/o6.seeds"
expanded_set "$qt" "$fixture/o6.seeds" >"$fixture/o6.expected"
run_engine "$fixture" -Sl @app @git
printf '%s\n' "$FIXTURE_OUTPUT" >"$fixture/o6"
[ "$FIXTURE_RC" = 0 ] || fail "gsa -Sl @app @git failed (rc=$FIXTURE_RC)" "$fixture/o6"
rows6=$(listing_rows <"$fixture/o6")
[ "$(sorted_ids "$rows6")" = "$(cat "$fixture/o6.expected")" ] \
    || fail "combined selection [$(sorted_ids "$rows6" | tr '\n' ' ')] != union of both expansions [$(tr '\n' ' ' <"$fixture/o6.expected")]" "$fixture/o6"
[ -z "$(printf '%s\n' $rows6 | sort | uniq -d)" ] \
    || fail "the combined selection lists a package twice (it must dedupe)" "$fixture/o6"
assert_topological "$qt" "$(printf '%s\n' $rows6 | paste -sd' ' -)"
# The combined listing is the anchor space (kept meaning of old :262-280:
# ranges address the UNFILTERED combined closure).
run_engine "$fixture" -Sl @app @git 3..4
printf '%s\n' "$FIXTURE_OUTPUT" >"$fixture/o6r"
[ "$FIXTURE_RC" = 0 ] || fail "gsa -Sl @app @git 3..4 failed (rc=$FIXTURE_RC)" "$fixture/o6r"
[ "$(listing_pairs <"$fixture/o6r")" = "$(listing_pairs <"$fixture/o6" | sed -n '3,4p')" ] \
    || fail "combined-range anchors wrong: got [$(listing_pairs <"$fixture/o6r" | tr '\n' '|')], want [$(listing_pairs <"$fixture/o6" | sed -n '3,4p' | tr '\n' '|')]" "$fixture/o6r"

# ── gsa 7. Real build: the named subset plus its consumers, recorded ───────
# (flipped from fish 9's build half — `subset selected -> builds exactly
# subset + consumer closure`, old :305-313; the prompt-mediated selection and
# its format: 1 record pins stay in fish 9 — engine gap. Build-only §B.5.)
echo app2 >"$fixture/o7.seeds"
expanded_set "$qt" "$fixture/o7.seeds" >"$fixture/o7.expected"
GSA_FAKE_SPAWN_LOG="$fixture/o7.spawn" PATH="$fixture/bin:$PATH" \
    run_engine "$fixture" -B --state-dir "$fixture/state-g7" app2
printf '%s\n' "$FIXTURE_OUTPUT" >"$fixture/o7"
[ "$FIXTURE_RC" = 0 ] || fail "gsa -B app2 failed (rc=$FIXTURE_RC)" "$fixture/o7"
rr2_body <"$fixture/o7" >/dev/null \
    || fail "the build run emitted no complete format: 2 record:" "$fixture/o7"
[ "$(rr2_scalar outcome <"$fixture/o7")" = "success" ] \
    || fail "recorded outcome is not success: $(rr2_scalar outcome <"$fixture/o7")" "$fixture/o7"
[ "$(rr2_scalar rc <"$fixture/o7")" = "$FIXTURE_RC" ] \
    || fail "the record's rc scalar disagrees with the process exit code:" "$fixture/o7"
# Recorded selection = the named subset plus its transitive consumers
# (§H.2 `order:`), derived from `gsa -Qt` — never a pinned count.
order7=$(rr2_scalar order <"$fixture/o7")
[ "$(sorted_ids "$order7")" = "$(cat "$fixture/o7.expected")" ] \
    || fail "recorded selection [$(sorted_ids "$order7" | tr '\n' ' ')] != app2 + its consumers [$(tr '\n' ' ' <"$fixture/o7.expected")]" "$fixture/o7"
assert_topological "$qt" "$order7"
[ "$(rr2_scalar selection-source <"$fixture/o7")" = 'sets=app2 leaf=no range=-' ] \
    || fail "the build did not record expanded selection: $(rr2_scalar selection-source <"$fixture/o7")" "$fixture/o7"
# Plan rows are build rows (§B.5 build-only); outcome rows `succeeded 0 … ok`
# (§H.2/§H.3) for the subset AND the consumers carried along.
for pkg in $order7; do
    [ "$(rr2_plan "$pkg" plan <"$fixture/o7")" = "build" ] \
        || fail "$pkg is not planned as a build (§B.5): $(rr2_plan "$pkg" <"$fixture/o7")" "$fixture/o7"
    [ "$(rr2_outcome "$pkg" status <"$fixture/o7")" = "succeeded" ] \
        || fail "$pkg row is not succeeded: $(rr2_outcome "$pkg" <"$fixture/o7")" "$fixture/o7"
    [ "$(rr2_outcome "$pkg" rc <"$fixture/o7")" = "0" ] \
        || fail "$pkg row rc is not 0: $(rr2_outcome "$pkg" <"$fixture/o7")" "$fixture/o7"
    [ "$(rr2_outcome "$pkg" reason <"$fixture/o7")" = "ok" ] \
        || fail "$pkg row reason is not ok: $(rr2_outcome "$pkg" <"$fixture/o7")" "$fixture/o7"
    grep -qx "SPAWN $pkg" "$fixture/o7.spawn" \
        || fail "subset/consumer $pkg was not built (no makepkg spawn)" "$fixture/o7.spawn"
done
# Everything else in the workspace — including extdep, app2's UPSTREAM —
# stays unbuilt (the derived complement of the closure, never a pinned list).
comm -23 <(qt_ids "$qt" | sort) "$fixture/o7.expected" >"$fixture/o7.unbuilt"
while read -r pkg; do
    if grep -q "^SPAWN $pkg$" "$fixture/o7.spawn"; then
        fail "unselected package $pkg was built" "$fixture/o7.spawn"
    fi
done <"$fixture/o7.unbuilt"
# The continuation's `remaining:` matches the rows-derived set (both empty).
[ "$(rr2_remaining <"$fixture/o7" | tr '\n' ' ' | sed 's/ $//')" = "$(rr2_continuation remaining <"$fixture/o7")" ] \
    || fail "continuation remaining disagrees with the rows-derived set:" "$fixture/o7"

# ── 5-12. PTY multi-select prompt (§C.4) — engine-driven ────────────────────
# The prompt landed in crates/gsa-cli (prompt.rs + select.rs's
# build_selection_for_build), so these sections drive `gsa` through
# run_pty_gsa. Every capture is CR-stripped before parsing (script(1)'s PTY
# slave maps \n to \r\n); expectations derive from `gsa -Qt` (rule 25(j)).

# ── 5. PTY + Enter: menu renders, whole group builds ────────────────────────
run_pty_gsa '\n' "$fixture/o5" -B --state-dir "$fixture/state-5" --dry-run @app \
    || fail "PTY -B --dry-run @app with plain Enter failed" "$fixture/o5"
grep -q 'choose what to build' "$fixture/o5" \
    || fail "prompt menu did not render on a PTY" "$fixture/o5"
grep -qF '[ ]' "$fixture/o5" \
    || fail "prompt menu rendered without unchecked entries" "$fixture/o5"
sed 's/\r$//' "$fixture/o5" >"$fixture/o5.clean"
order5=$(rr2_scalar order <"$fixture/o5.clean")
[ "$(sorted_ids "$order5")" = "$(cat "$fixture/app.expected")" ] \
    || fail "Enter should build the whole group, got [$(echo $order5)]" "$fixture/o5"
# Enter drops nothing, so the plan rows are the plain 1..3 anchors of the
# unfiltered closure — identical to the -Sl @app listing from scenario 4.
pairs5=$(order_pairs "$fixture/o5.clean")
[ "$pairs5" = "$(listing_pairs <"$fixture/o4")" ] \
    || fail "unfiltered prompted anchors diverge from the -Sl listing: got [$(echo "$pairs5" | tr '\n' '|')], listing [$(listing_pairs <"$fixture/o4" | tr '\n' '|')]" "$fixture/o5"

# ONLY an @app selection prompts (§C.4): a positional app member builds
# without a menu — the positive twin is the menu grep in the §5 Enter run.
run_pty_gsa '' "$fixture/o5n" -B --state-dir "$fixture/state-5n" --dry-run app2 \
    || fail "PTY -B --dry-run app2 failed" "$fixture/o5n"
grep -q 'choose what to build' "$fixture/o5n" \
    && fail "a positional app member rendered the @app prompt" "$fixture/o5n"

# ── 6. PTY + toggle: only the checked subset — plus its consumers ──────────
# Row 2 is app2's row (build order); app3 consumes app2, so consumer expansion
# carries it along. The menu renders only the group's own rows.
echo app2 >"$fixture/o6.seeds"
expanded_set "$qt" "$fixture/o6.seeds" >"$fixture/o6.expected"
run_pty_gsa '2\n\n' "$fixture/o6p" -B --state-dir "$fixture/state-6p" --dry-run @app \
    || fail "PTY -B --dry-run @app with toggle input failed" "$fixture/o6p"
grep -qF '[x]' "$fixture/o6p" \
    || fail "toggled menu entry did not render as checked" "$fixture/o6p"
sed 's/\r$//' "$fixture/o6p" >"$fixture/o6p.clean"
order6=$(rr2_scalar order <"$fixture/o6p.clean")
[ "$(sorted_ids "$order6")" = "$(cat "$fixture/o6.expected")" ] \
    || fail "checked-only selection wrong: got [$(echo $order6)], want [$(tr '\n' ' ' <"$fixture/o6.expected")]" "$fixture/o6p"
# The plan anchors are the UNFILTERED closure positions: app2/app3 sit at 2/3
# in the whole @app selection (the -Sl listing from scenario 4), even though
# the prompt dropped app1 — the gap at 1 is intended and honest (owner
# directive 2026-10-08: anchors must not renumber after prompt filtering).
pairs6=$(order_pairs "$fixture/o6p.clean")
expected6_pairs=$(listing_pairs <"$fixture/o4" | grep -E ' (app2|app3)$')
[ "$pairs6" = "$expected6_pairs" ] \
    || fail "toggled preview anchors wrong: got [$(echo "$pairs6" | tr '\n' '|')], want [$(echo "$expected6_pairs" | tr '\n' '|')] (unfiltered positions, gaps intended)" "$fixture/o6p"
while read -r num name; do
    lnum=$(listing_pairs <"$fixture/o4" | awk -v n="$name" '$2 == n { print $1 }')
    [ "$lnum" = "$num" ] \
        || fail "anchor drift: $name printed as $num in the prompted run but $lnum in the -Sl @app listing" "$fixture/o6p"
done <<<"$pairs6"

# The expansion note counts the POST-PROMPT closure (§C.4: the prompt
# filters before the ordinary pipeline runs) — the checked subset expands to
# its consumers only, never to the unfiltered group's leftovers.
note6=$(grep -o 'consumer expansion added [0-9]* of the [0-9]* selected packages' "$fixture/o6p.clean" | head -1)
expected6_note="consumer expansion added $(($(wc -l <"$fixture/o6.expected") - $(wc -l <"$fixture/o6.seeds"))) of the $(wc -l <"$fixture/o6.expected") selected packages"
[ "$note6" = "$expected6_note" ] \
    || fail "expansion note does not count the post-prompt closure: got [$note6], want [$expected6_note]" "$fixture/o6p"

# ── 7. PTY + q: abort with non-zero ─────────────────────────────────────────
if run_pty_gsa 'q\n' "$fixture/o7p" -B --state-dir "$fixture/state-7p" --dry-run @app; then
    fail "-B --dry-run @app accepted 'q' (abort must exit non-zero)" "$fixture/o7p"
fi
grep -q 'app selection aborted' "$fixture/o7p" \
    || fail "abort path did not report the abort" "$fixture/o7p"
# The abort is exactly ONE line (fish parity: the reason rides on it) — the
# prompt and the caller must never both print it.
[ "$(grep -c 'app selection aborted' "$fixture/o7p")" = 1 ] \
    || fail "'q' abort printed more than one abort line" "$fixture/o7p"
# EOF (a literal EOT on the PTY — a PTY slave has no hangup) aborts the
# same way: non-zero, one line, reason attached. The unprivileged twin is
# required here: sudo's PTY pump swallows the EOF condition (run_pty_gsa
# header).
if run_pty_gsa_user '\004' "$fixture/o7c" -B --state-dir "$fixture/state-7c" --dry-run @app; then
    fail "-B --dry-run @app accepted input EOF (abort must exit non-zero)" "$fixture/o7c"
fi
grep -q 'app selection aborted (input closed)' "$fixture/o7c" \
    || fail "EOF abort did not name its reason" "$fixture/o7c"
[ "$(grep -c 'app selection aborted' "$fixture/o7c")" = 1 ] \
    || fail "EOF abort printed more than one abort line" "$fixture/o7c"

# ── 8. Combined @app @git: only the app portion is filtered ─────────────────
{ echo app1; group_members "$qt" git; } >"$fixture/o8.seeds"
expanded_set "$qt" "$fixture/o8.seeds" >"$fixture/o8.expected"
run_pty_gsa '1\n\n' "$fixture/o8p" -B --state-dir "$fixture/state-8p" --dry-run @app @git \
    || fail "PTY -B --dry-run @app @git with toggle input failed" "$fixture/o8p"
sed 's/\r$//' "$fixture/o8p" >"$fixture/o8p.clean"
order8=$(rr2_scalar order <"$fixture/o8p.clean")
[ "$(sorted_ids "$order8")" = "$(cat "$fixture/o8.expected")" ] \
    || fail "combined selection wrong: got [$(echo $order8)], want [$(tr '\n' ' ' <"$fixture/o8.expected")]" "$fixture/o8p"
# The combined -Sl closure is the anchor space: checked rows keep their
# unfiltered positions, with gaps where the prompt dropped rows — pinned
# against the matching listing.
run_engine "$fixture" -Sl @app @git
printf '%s\n' "$FIXTURE_OUTPUT" >"$fixture/o8l"
pairs8=$(order_pairs "$fixture/o8p.clean")
expected8_pairs=$(listing_pairs <"$fixture/o8l" | awk -v names="$order8" '
    BEGIN { n = split(names, a, " "); for (i = 1; i <= n; i++) keep[a[i]] = 1 }
    keep[$2] { print $1, $2 }')
[ "$pairs8" = "$expected8_pairs" ] \
    || fail "combined-run anchors wrong: got [$(echo "$pairs8" | tr '\n' '|')], want [$(echo "$expected8_pairs" | tr '\n' '|')] (unfiltered positions in the @app @git closure)" "$fixture/o8p"
while read -r num name; do
    lnum=$(listing_pairs <"$fixture/o8l" | awk -v n="$name" '$2 == n { print $1 }')
    [ "$lnum" = "$num" ] \
        || fail "anchor drift in combined selection: $name printed as $num in the prompted run but $lnum in the -Sl @app @git listing" "$fixture/o8p"
done <<<"$pairs8"

# ── 9. Real build prompts too, and builds the checked subset + consumers ────
GSA_FAKE_SPAWN_LOG="$fixture/o9.spawn" PATH="$fixture/bin:$PATH" \
    run_pty_gsa '2\n\n' "$fixture/o9" -B --state-dir "$fixture/state-9" @app \
    || fail "PTY build @app with toggle input failed" "$fixture/o9"
grep -q 'choose what to build' "$fixture/o9" \
    || fail "real build did not prompt" "$fixture/o9"
sed 's/\r$//' "$fixture/o9" >"$fixture/o9.clean"
# Checked app2 expands to app2 + its consumer app3 (app3's edge names app2).
[ "$(sorted_ids "$(rr2_scalar order <"$fixture/o9.clean")")" = "$(cat "$fixture/o6.expected")" ] \
    || fail "recorded selection is not the checked subset plus consumers: $(rr2_scalar order <"$fixture/o9.clean")" "$fixture/o9"
[ "$(rr2_scalar outcome <"$fixture/o9.clean")" = "success" ] \
    || fail "recorded outcome is not success: $(rr2_scalar outcome <"$fixture/o9.clean")" "$fixture/o9"
for pkg in $order6; do
    [ "$(rr2_outcome "$pkg" status <"$fixture/o9.clean")" = "succeeded" ] \
        || fail "$pkg row is not succeeded" "$fixture/o9"
    [ "$(rr2_outcome "$pkg" rc <"$fixture/o9.clean")" = "0" ] \
        || fail "$pkg row rc is not 0" "$fixture/o9"
    [ "$(rr2_outcome "$pkg" reason <"$fixture/o9.clean")" = "ok" ] \
        || fail "$pkg row reason is not ok" "$fixture/o9"
    grep -qx "SPAWN $pkg" "$fixture/o9.spawn" \
        || fail "checked package $pkg was not built" "$fixture/o9"
done
# Everything else — including extdep, app2's UPSTREAM — stays unbuilt.
comm -23 <(qt_ids "$qt" | sort) "$fixture/o6.expected" >"$fixture/o9.unbuilt"
while read -r pkg; do
    grep -q "^SPAWN $pkg$" "$fixture/o9.spawn" \
        && fail "unselected package $pkg was built" "$fixture/o9.spawn"
done <"$fixture/o9.unbuilt"

# ── 10. app-cluster: ONE shared row, and toggling it selects every member ───
# Two app members share app-cluster=fcitx5 (the real tree's fcitx-family
# shape); app1 stays an untagged plain member. Rendering pins are row counts
# and labels, never a full-screen snapshot. The records are re-tagged here
# and restored once the cluster cases are done.
set_topology_record "$fixture" app2 app 'extdep' 'app-cluster=fcitx5'
set_topology_record "$fixture" app3 app 'app2' 'app-cluster=fcitx5'
echo app2 >"$fixture/o10.seeds"
expanded_set "$qt" "$fixture/o10.seeds" >"$fixture/o10.expected"

GSA_FAKE_SPAWN_LOG="$fixture/o10.spawn" PATH="$fixture/bin:$PATH" \
    run_pty_gsa '2\n\n' "$fixture/o10" -B --state-dir "$fixture/state-10" @app \
    || fail "PTY cluster-toggle run failed" "$fixture/o10"
# Exactly two rows: one plain, one cluster — and no per-member row for a
# cluster member anywhere in the first render.
rows10=$(menu_rows "$fixture/o10")
expected10=$(printf 'app1\nfcitx5 [app2 app3]')
[ "$rows10" = "$expected10" ] \
    || fail "cluster menu rows wrong: got [$(echo "$rows10" | tr '\n' '|')], want [app1|fcitx5 [app2 app3]]" "$fixture/o10"
[ "$(first_menu "$fixture/o10" | grep -cE '^ *\[.\] *[0-9]+\.')" = 2 ] \
    || fail "expected exactly 2 toggle rows (one plain + one cluster)" "$fixture/o10"
first_menu "$fixture/o10" | grep -E '^ *\[.\] *[0-9]+\. (app2|app3)$' \
    && fail "a cluster member rendered its own row" "$fixture/o10"
grep -q 'choose what to build (3 packages)' "$fixture/o10" \
    || fail "prompt header does not count the 3 packages behind the 2 rows" "$fixture/o10"
# Toggling the cluster row marks THAT row checked...
grep -qF '[x]  2. fcitx5 [app2 app3]' "$fixture/o10" \
    || fail "toggling row 2 did not check the cluster row" "$fixture/o10"
# ...and the "N checked" notice counts ROWS (a checked cluster = 1 — intended).
grep -q '1 checked' "$fixture/o10" \
    || fail "checked cluster row did not report 1 checked row" "$fixture/o10"
grep -q '2 checked' "$fixture/o10" \
    && fail "the N-checked notice counted members, not rows" "$fixture/o10"
# But the RUN carries every member (build order: app2 before its dependent
# app3) and never the plain member.
sed 's/\r$//' "$fixture/o10" >"$fixture/o10.clean"
[ "$(sorted_ids "$(rr2_scalar order <"$fixture/o10.clean")")" = "$(cat "$fixture/o10.expected")" ] \
    || fail "cluster row did not select exactly its members: got [$(rr2_scalar order <"$fixture/o10.clean")], want [$(tr '\n' ' ' <"$fixture/o10.expected")]" "$fixture/o10"
assert_topological "$qt" "$(rr2_scalar order <"$fixture/o10.clean")"
[ "$(rr2_scalar outcome <"$fixture/o10.clean")" = "success" ] \
    || fail "cluster-toggle run outcome is not success" "$fixture/o10"
while read -r member; do
    [ "$(rr2_outcome "$member" status <"$fixture/o10.clean")" = "succeeded" ] \
        || fail "$member row is not succeeded" "$fixture/o10"
    grep -qx "SPAWN $member" "$fixture/o10.spawn" \
        || fail "cluster member $member was not built" "$fixture/o10"
done <"$fixture/o10.expected"
# The derived complement — the plain member included — stays unbuilt.
comm -23 <(qt_ids "$qt" | sort) "$fixture/o10.expected" >"$fixture/o10.unbuilt"
while read -r pkg; do
    grep -q "^SPAWN $pkg$" "$fixture/o10.spawn" \
        && fail "unselected package $pkg was built by the cluster row" "$fixture/o10"
done <"$fixture/o10.unbuilt"

# ── 11. The plain member's row toggles independently of the cluster ─────────
# Row 1 is the plain member's row (scenario input); its selection derives
# from the topology like every other expectation.
echo app1 >"$fixture/o11.seeds"
expanded_set "$qt" "$fixture/o11.seeds" >"$fixture/o11.expected"
GSA_FAKE_SPAWN_LOG="$fixture/o11.spawn" PATH="$fixture/bin:$PATH" \
    run_pty_gsa '1\n\n' "$fixture/o11" -B --state-dir "$fixture/state-11" @app \
    || fail "PTY plain-member toggle run failed" "$fixture/o11"
sed 's/\r$//' "$fixture/o11" >"$fixture/o11.clean"
[ "$(sorted_ids "$(rr2_scalar order <"$fixture/o11.clean")")" = "$(cat "$fixture/o11.expected")" ] \
    || fail "plain row did not select exactly its own member: got [$(rr2_scalar order <"$fixture/o11.clean")], want [$(tr '\n' ' ' <"$fixture/o11.expected")]" "$fixture/o11"
assert_topological "$qt" "$(rr2_scalar order <"$fixture/o11.clean")"
while read -r pkg; do
    [ "$(rr2_outcome "$pkg" status <"$fixture/o11.clean")" = "succeeded" ] \
        || fail "$pkg row is not succeeded" "$fixture/o11"
done <"$fixture/o11.expected"
# The derived complement — the cluster's members included — stays unbuilt.
comm -23 <(qt_ids "$qt" | sort) "$fixture/o11.expected" >"$fixture/o11.unbuilt"
while read -r pkg; do
    grep -q "^SPAWN $pkg$" "$fixture/o11.spawn" \
        && fail "unselected package $pkg was dragged in by the plain row" "$fixture/o11"
done <"$fixture/o11.unbuilt"

# ── 12. All-unchecked + Enter still builds the whole group, cluster included ─
GSA_FAKE_SPAWN_LOG="$fixture/o12.spawn" PATH="$fixture/bin:$PATH" \
    run_pty_gsa '\n' "$fixture/o12" -B --state-dir "$fixture/state-12" @app \
    || fail "PTY whole-group cluster run failed" "$fixture/o12"
sed 's/\r$//' "$fixture/o12" >"$fixture/o12.clean"
[ "$(sorted_ids "$(rr2_scalar order <"$fixture/o12.clean")")" = "$(cat "$fixture/app.expected")" ] \
    || fail "Enter did not build the whole group: got [$(rr2_scalar order <"$fixture/o12.clean")], want [$(tr '\n' ' ' <"$fixture/app.expected")]" "$fixture/o12"
assert_topological "$qt" "$(rr2_scalar order <"$fixture/o12.clean")"
while read -r pkg; do
    [ "$(rr2_outcome "$pkg" status <"$fixture/o12.clean")" = "succeeded" ] \
        || fail "$pkg row is not succeeded" "$fixture/o12"
    grep -qx "SPAWN $pkg" "$fixture/o12.spawn" \
        || fail "$pkg was not built" "$fixture/o12"
done <"$fixture/app.expected"

# Restore the untagged records the cluster scenario started from.
set_topology_record "$fixture" app2 app 'extdep'
set_topology_record "$fixture" app3 app 'app2'

printf 'app group fixture: PASS\n'
