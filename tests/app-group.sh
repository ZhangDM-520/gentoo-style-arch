#!/usr/bin/env bash
set -euo pipefail

# app group + TTY multi-select prompt fixture — PARTIAL FLIP: this file
# drives BOTH engines. Everything the NATIVE engine (`gsa`,
# docs/gsa-contract.md §B.4/§B.5/§C/§G.1/§H.2) expresses runs through
# tests/lib/rr-v2.bash's run_engine (sections `gsa 1`-`gsa 7` below); the PTY
# multi-select prompt sections stay fish-driven and byte-unchanged (the
# numbered sections 5-12 at the bottom) because the engine has NO app prompt:
# §C.4 carries the prompt and the `app-cluster` prompt rows as contract, but
# no prompt/multi-select code exists in crates/gsa-cli (measured 2026-10-12 —
# `grep -rniE 'read_line|stdin|toggle|multi.?select' crates/gsa-cli/src/`
# finds none; the only `prompt` hit is a comment saying the engine never
# prompts). See docs/gsa-fixture-migration.md row `tests/app-group.sh`.
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
#      consumers), q = non-zero abort      [fish 5-7 — engine gap]
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
#   * dry-run records render `lanes: -`, which tests/lib/rr-v2.bash's rr2_body
#     rejects (strict integer rule, §8 G12 of the migration doc); dry-run
#     scalars are read through the local rr_dry_scalar extractor
#     (tests/project.sh's pattern). Real-run records parse through rr2_*. Do
#     not weaken rr-v2.bash.
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

# Read-only helpers. Each captures combined output into $out/$err files and
# returns the builder's status (caller asserts with ||-style checks under -e).
run_quiet() { # <outfile> [args...] — stdin /dev/null (never a TTY)
    local out="$1"
    shift
    fish "$fixture/build-all.fish" "$@" </dev/null >"$out" 2>&1
}

run_pty() { # <input printf fmt> <outfile> <state-dir> [args...] — PTY stdin
    local input="$1" out="$2" state="$3"
    shift 3
    set +e
    # TERM=dumb on purpose: fish's terminal capability queries (DA1) have no
    # responder under script(1)'s PTY, and fish then consumes the piped toggle
    # input as bogus query replies (observed: "2" swallowed mid-exchange, the
    # next read hanging until the timeout). A dumb terminal skips the queries
    # entirely — the FD-level `test -t 0` the seam keys on stays true, and
    # nothing in this fixture asserts colours or the dashboard.
    printf '%b' "$input" | \
        timeout 60 env TERM=dumb \
            script -qec "PATH=\"$fixture/bin:\$PATH\" GSA_STATE_DIR='$state' \
                fish '$fixture/build-all.fish' $*" /dev/null >"$out" 2>&1
    RC=$?
    set -e
    return "$RC"
}

# Extract just the numbered package sequence from a dry-run preview.
# PTY runs carry \r (the slave's ONLCR maps every \n) — strip it, or each
# field compares as "app1\r" against the expected literal.
order_seq() {
    sed -n '/Build order (dry run):/,/^Total:/p' "$1" \
        | grep -E '^ +[0-9]+\. ' | awk '{print $2}' | tr -d '\r'
}

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

# Same numbered rows as a `-l` listing prints (the listing has no run record:
# listing/dry-run runs never start a build, so the rows ARE the data channel).
listed_seq() {
    sed -n '/Selected packages in build order/,$p' "$1" \
        | grep -E '^ +[0-9]+\. ' | awk '{print $2}' | tr -d '\r'
}

# A `-l` listing as 'anchor name' pairs — the unfiltered anchor map a
# prompted run's printed indices must agree with.
listed_pairs() {
    sed -n '/Selected packages in build order/,$p' "$1" \
        | grep -E '^ +[0-9]+\. ' | awk '{sub(/\.$/, "", $1); print $1, $2}' | tr -d '\r'
}

# The fish half's whole-group pin (kept): Enter builds exactly these three.
# The gsa half derives its expectations instead (rule 25(j)) and never uses
# this constant.
expected3=$(printf 'app1\napp2\napp3')

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

# rr_dry_scalar KEY — one scalar of a `--dry-run` run record, read from
# $FIXTURE_OUTPUT. rr2_body rejects that record shape (it renders `lanes: -`
# and the parser's integer rule is strict — tests/project.sh's recorded
# deviation, and rr-v2.bash is NOT weakened), so dry-run scalars go through
# this extractor; real-run records parse through rr2_* unchanged.
rr_dry_scalar() {
    printf '%s\n' "$FIXTURE_OUTPUT" | awk -v key="$1" '
        /^--- run record begin ---$/ { inb = 1; next }
        /^--- plan ---$/ { exit }
        inb {
            p = index($0, ":")
            if (p && substr($0, 1, p - 1) == key) {
                v = substr($0, p + 1); sub(/^ /, "", v); print v; found = 1; exit
            }
        }
        END {
            if (!found) {
                printf("rr_dry_scalar: no %s scalar in the dry-run record\n", key) > "/dev/stderr"
                exit 1
            }
        }'
}

# run_pty_gsa <input printf fmt> <outfile> [args...] — the gsa twin of
# run_pty: the engine under a PTY with scripted stdin (proves a listing never
# reads its input; nothing here asserts colours or rendering).
run_pty_gsa() {
    local input="$1" out="$2"
    shift 2
    set +e
    printf '%b' "$input" | \
        timeout 60 env TERM=dumb \
            script -qec "cd '$fixture' && PATH=\"$fixture/bin:\$PATH\" '$gsa_bin' $*" /dev/null >"$out" 2>&1
    RC=$?
    set -e
    return "$RC"
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
order=$(rr_dry_scalar order)
[ "$(sorted_ids "$order")" = "$(cat "$fixture/app.expected")" ] \
    || fail "non-TTY selection [$(sorted_ids "$order" | tr '\n' ' ')] != @app members + consumers [$(tr '\n' ' ' <"$fixture/app.expected")] (derived from gsa -Qt)" "$fixture/o3"
assert_topological "$qt" "$order"
[ "$(rr_dry_scalar selection-source)" = 'sets=@app leaf=no range=-' ] \
    || fail "the non-TTY run did not record expanded selection: $(rr_dry_scalar selection-source)" "$fixture/o3"
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
[ "$(rr_dry_scalar order)" = "$(listing_rows <"$fixture/o5r" | paste -sd' ' -)" ] \
    || fail "ranged dry-run order [$(rr_dry_scalar order)] but the ranged listing is [$(listing_rows <"$fixture/o5r" | paste -sd' ' -)]" "$fixture/o5d"
[ "$(rr_dry_scalar selection-source)" = 'sets=@app leaf=no range=2..3' ] \
    || fail "the ranged dry run did not record its selection source: $(rr_dry_scalar selection-source)" "$fixture/o5d"

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

# ── fish half — KEPT byte-unchanged: the PTY multi-select prompt ───────────
# These sections drive `fish build-all.fish` through run_quiet/run_pty because
# the behaviour they pin lives in the §C.4 prompt, which the engine does not
# implement yet (header engine-gap note). Their `format: 1` rr_scalar/rr_row
# pins (old :293-302, :349, :366) come along until the prompt lands. Do not
# flip these piecemeal: when gsa grows a prompt, re-contract the whole section.

# ── 5. PTY + Enter: menu renders, whole group builds ────────────────────────
run_pty '\n' "$fixture/o5" "$fixture/state-5" -n -g app \
    || fail "PTY -n -g app with plain Enter failed" "$fixture/o5"
grep -q 'choose what to build' "$fixture/o5" \
    || fail "prompt menu did not render on a PTY" "$fixture/o5"
grep -qF '[ ]' "$fixture/o5" \
    || fail "prompt menu rendered without unchecked entries" "$fixture/o5"
seq5=$(order_seq "$fixture/o5")
[ "$seq5" = "$expected3" ] \
    || fail "Enter should build the whole group, got [$(echo "$seq5" | tr '\n' ' ')]" "$fixture/o5"
# Enter drops nothing, so the printed anchors are the plain 1..3 of the
# unfiltered closure — identical to the -l -g app listing from scenario 4.
pairs5=$(order_pairs "$fixture/o5")
[ "$pairs5" = "$(listed_pairs "$fixture/o4")" ] \
    || fail "unfiltered prompted anchors diverge from the -l listing: got [$(echo "$pairs5" | tr '\n' '|')], listing [$(listed_pairs "$fixture/o4" | tr '\n' '|')]" "$fixture/o5"

# ── 6. PTY + toggle: only the checked subset — plus its consumers ──────────
# Row 2 checks app2; app3 consumes app2, so consumer expansion carries it
# along (app2 first). The menu still renders only the group's own rows.
run_pty '2\n\n' "$fixture/o6" "$fixture/state-6" -n -g app \
    || fail "PTY -n -g app with toggle input failed" "$fixture/o6"
grep -qF '[x]' "$fixture/o6" \
    || fail "toggled menu entry did not render as checked" "$fixture/o6"
seq6=$(order_seq "$fixture/o6")
expected6=$(printf 'app2\napp3')
[ "$seq6" = "$expected6" ] \
    || fail "checked-only preview wrong: got [$(echo "$seq6" | tr '\n' ' ')], want [app2 app3]" "$fixture/o6"
# The printed anchors are the UNFILTERED closure positions: app2/app3 sit at
# 2/3 in the whole -g app selection (the -l listing from scenario 4), even
# though the prompt dropped app1 — the gap at 1 is intended and honest (owner
# directive 2026-10-08: anchors must not renumber after prompt filtering).
pairs6=$(order_pairs "$fixture/o6")
expected6_pairs=$(printf '2 app2\n3 app3')
[ "$pairs6" = "$expected6_pairs" ] \
    || fail "toggled preview anchors wrong: got [$(echo "$pairs6" | tr '\n' '|')], want [2 app2|3 app3] (unfiltered positions, gaps intended)" "$fixture/o6"
# Cross-check against the -l -g app listing: the same package carries the
# same index in a prompted run and in the listing, whatever was toggled.
while read -r num name; do
    lnum=$(listed_pairs "$fixture/o4" | awk -v n="$name" '$2 == n { print $1 }')
    [ "$lnum" = "$num" ] \
        || fail "anchor drift: $name printed as $num in the prompted run but $lnum in the -l -g app listing" "$fixture/o6"
done <<<"$pairs6"

# ── 7. PTY + q: abort with non-zero ─────────────────────────────────────────
if run_pty 'q\n' "$fixture/o7" "$fixture/state-7" -n -g app; then
    fail "-n -g app accepted 'q' (abort must exit non-zero)" "$fixture/o7"
fi
grep -q 'app selection aborted' "$fixture/o7" \
    || fail "abort path did not report the abort" "$fixture/o7"

# ── 8. Combined -g app -g git: only the app portion is filtered ─────────────
run_pty '1\n\n' "$fixture/o8" "$fixture/state-8" -n -g app -g git \
    || fail "PTY -n -g app -g git failed" "$fixture/o8"
seq8=$(order_seq "$fixture/o8")
expected8=$(printf 'app1\ngitp1')
[ "$seq8" = "$expected8" ] \
    || fail "combined selection wrong: got [$(echo "$seq8" | tr '\n' ' ')], want [app1 gitp1]" "$fixture/o8"
# The combined -g app -g git closure is the anchor space here: app1/gitp1
# keep their unfiltered positions 1/3, with a gap where the prompt dropped
# the app2/app3 rows — pinned against the matching -l listing.
run_quiet "$fixture/o8l" -l -g app -g git \
    || fail "-l -g app -g git failed" "$fixture/o8l"
pairs8=$(order_pairs "$fixture/o8")
expected8_pairs=$(printf '1 app1\n3 gitp1')
[ "$pairs8" = "$expected8_pairs" ] \
    || fail "combined-run anchors wrong: got [$(echo "$pairs8" | tr '\n' '|')], want [1 app1|3 gitp1] (unfiltered positions in the app+git closure)" "$fixture/o8"
while read -r num name; do
    lnum=$(listed_pairs "$fixture/o8l" | awk -v n="$name" '$2 == n { print $1 }')
    [ "$lnum" = "$num" ] \
        || fail "anchor drift in combined selection: $name printed as $num in the prompted run but $lnum in the -l -g app -g git listing" "$fixture/o8"
done <<<"$pairs8"

# ── 9. Real build prompts too, and builds the checked subset + consumers ────
run_pty '2\n\n' "$fixture/o9" "$fixture/state-9" \
    -g app --allow-broken-rustc --no-sync \
    || fail "PTY build -g app with toggle input failed" "$fixture/o9"
grep -q 'choose what to build' "$fixture/o9" \
    || fail "real build did not prompt" "$fixture/o9"
# The real build emits a run record (PTY capture — the parsers strip the
# slave's \r): the prompt's answer decided the SELECTION, and the record says
# what that selection was and what happened to it. Checked app2 expands to
# app2 + its consumer app3 (app3's edge names app2).
[ "$(rr_scalar order <"$fixture/o9")" = "app2 app3" ] \
    || fail "recorded selection is not exactly app2 app3 (checked app2 plus its consumer app3): $(rr_scalar order <"$fixture/o9")" "$fixture/o9"
[ "$(rr_scalar outcome <"$fixture/o9")" = "success" ] \
    || fail "recorded outcome is not success: $(rr_scalar outcome <"$fixture/o9")" "$fixture/o9"
[ "$(rr_row app2 status <"$fixture/o9")" = "succeeded" ] \
    || fail "app2 row is not succeeded: $(rr_row app2 <"$fixture/o9")" "$fixture/o9"
[ "$(rr_row app2 rc <"$fixture/o9")" = "0" ] \
    || fail "app2 row rc is not 0: $(rr_row app2 <"$fixture/o9")" "$fixture/o9"
[ "$(rr_row app2 reason <"$fixture/o9")" = "ok" ] \
    || fail "app2 row reason is not ok: $(rr_row app2 <"$fixture/o9")" "$fixture/o9"
[ "$(rr_row app3 status <"$fixture/o9")" = "succeeded" ] \
    || fail "app3 row is not succeeded: $(rr_row app3 <"$fixture/o9")" "$fixture/o9"
[ -f "$fixture/state-9/logs/app2.log" ] \
    || fail "checked package app2 was not built" "$fixture/o9"
# app3 rides in as app2's CONSUMER; everything else — including extdep, which
# is app2's UPSTREAM — must stay unbuilt.
[ -f "$fixture/state-9/logs/app3.log" ] \
    || fail "consumer app3 was not built alongside checked app2" "$fixture/o9"
for unbuilt in app1 extdep gitp1; do
    [ -f "$fixture/state-9/logs/$unbuilt.log" ] \
        && fail "unselected package $unbuilt was built" "$fixture/o9"
done

# ── 10. app-cluster: ONE shared row, and toggling it selects every member ───
# Two app members share app-cluster=fcitx5 (the real tree's fcitx-family shape,
# at two members); app1 stays an untagged plain member. Rendering pins are the
# scenario's row counts and labels, never a full-screen snapshot. The scenario
# re-tags the records and restores them once the cluster cases are done.
set_topology_record "$fixture" app2 app 'extdep' 'app-cluster=fcitx5'
set_topology_record "$fixture" app3 app 'app2' 'app-cluster=fcitx5'

run_pty '2\n\n' "$fixture/o10" "$fixture/state-10" \
    -g app --allow-broken-rustc --no-sync \
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
# But the RUN carries every member (topo order: app2 before its dependent
# app3) and never the plain member.
[ "$(rr_scalar order <"$fixture/o10")" = "app2 app3" ] \
    || fail "cluster row did not select both members: $(rr_scalar order <"$fixture/o10")" "$fixture/o10"
[ "$(rr_scalar outcome <"$fixture/o10")" = "success" ] \
    || fail "cluster-toggle run outcome is not success: $(rr_scalar outcome <"$fixture/o10")" "$fixture/o10"
for member in app2 app3; do
    [ "$(rr_row $member status <"$fixture/o10")" = "succeeded" ] \
        || fail "$member row is not succeeded: $(rr_row $member <"$fixture/o10")" "$fixture/o10"
    [ -f "$fixture/state-10/logs/$member.log" ] \
        || fail "cluster member $member was not built" "$fixture/o10"
done
[ -f "$fixture/state-10/logs/app1.log" ] \
    && fail "plain member app1 was built by the cluster row" "$fixture/o10"

# ── 11. The plain member's row toggles independently of the cluster ─────────
run_pty '1\n\n' "$fixture/o11" "$fixture/state-11" \
    -g app --allow-broken-rustc --no-sync \
    || fail "PTY plain-member toggle run failed" "$fixture/o11"
[ "$(rr_scalar order <"$fixture/o11")" = "app1" ] \
    || fail "plain row did not select exactly app1: $(rr_scalar order <"$fixture/o11")" "$fixture/o11"
[ "$(rr_row app1 status <"$fixture/o11")" = "succeeded" ] \
    || fail "app1 row is not succeeded: $(rr_row app1 <"$fixture/o11")" "$fixture/o11"
for member in app2 app3; do
    [ -f "$fixture/state-11/logs/$member.log" ] \
        && fail "cluster member $member was dragged in by the plain row" "$fixture/o11"
done

# ── 12. All-unchecked + Enter still builds the whole group, cluster included ─
run_pty '\n' "$fixture/o12" "$fixture/state-12" \
    -g app --allow-broken-rustc --no-sync \
    || fail "PTY whole-group cluster run failed" "$fixture/o12"
[ "$(rr_scalar order <"$fixture/o12")" = "app1 app2 app3" ] \
    || fail "Enter did not build the whole group: $(rr_scalar order <"$fixture/o12")" "$fixture/o12"
for pkg in app1 app2 app3; do
    [ "$(rr_row $pkg status <"$fixture/o12")" = "succeeded" ] \
        || fail "$pkg row is not succeeded: $(rr_row $pkg <"$fixture/o12")" "$fixture/o12"
done

# Restore the untagged records the cluster scenario started from.
set_topology_record "$fixture" app2 app 'extdep'
set_topology_record "$fixture" app3 app 'app2'

printf 'app group fixture: PASS\n'
