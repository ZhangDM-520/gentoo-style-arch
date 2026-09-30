#!/usr/bin/env bash
set -euo pipefail

# app group + TTY multi-select prompt fixture.
#
# Pins (decisions recorded in docs/NOTE.md 2026-09-23):
#   1. loader demands config/topology.conf (a missing file = error; group
#      membership rides in each record's groups field, and the roster is the
#      builder's five names — git, stable, core, misc, app)
#   2. an app group with NO member refuses with a targeted hint (no phantom member)
#   3. non-TTY -n -g app builds the whole group and says the prompt was
#      skipped; the group's edges never pull upstream — a local dependency
#      edge to a non-app workspace package must NOT drag that package into
#      the run (expansion walks consumers only)
#   4. -l never prompts (a prompt on a PTY with no input would abort/hang,
#      so exit 0 with the whole group proves silence)
#   5. on a PTY: Enter = whole group, numbers = the checked subset (plus its
#      consumers), q = non-zero abort
#   6. -g app combined with -g git: the filter touches only the app portion
#   7. a REAL build prompts too and builds the checked subset plus its
#      consumers
#   8. app-cluster=<name> members share ONE toggle row labelled
#      '<name> [member ids]' (a cluster member never renders its own row);
#      toggling that row checks/clears EVERY member at once, and the
#      "N checked" notice counts ROWS — a checked cluster reads "1 checked"
#      while its run record selects all of the members
#   9. an untagged member's row toggles independently of the cluster row
#  10. all-unchecked + Enter still builds the whole group, cluster members
#      included

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-app-fixture.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf '%s\n' "$1" >&2
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
        sed 's/^/    /' "$2" >&2
    fi
    exit 1
}

# ── Synthetic workspace: five fake packages, one topology record each ───────
make_workspace "$fixture" auto auto xhigh

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
printf 'fake makepkg %s\n' "$PWD"
sleep "${GSA_FAKE_BUILD_SECONDS:-0.05}"
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

# ── 1. Loader: a missing topology file is an error; the roster is five names ─
mv "$fixture/config/topology.conf" "$fixture/topology.conf.bak"
if run_quiet "$fixture/o1" --list; then
    fail "loader accepted a workspace without config/topology.conf" "$fixture/o1"
fi
grep -q 'topology not found:' "$fixture/o1" \
    || fail "loader error does not name the missing config/topology.conf" "$fixture/o1"
mv "$fixture/topology.conf.bak" "$fixture/config/topology.conf"
# The loader's roster wording is its own closed five-name list — pin the text
# it prints, not just "some roster".
set_topology_record "$fixture" gitp1 '' ''
if run_quiet "$fixture/o1g" --list; then
    fail "loader accepted a record naming no group" "$fixture/o1g"
fi
grep -q 'names no group (allowed: git,stable,core,misc,app)' "$fixture/o1g" \
    || fail "loader roster wording is not the five-name list" "$fixture/o1g"
set_topology_record "$fixture" gitp1 git ''

# ── 2. Empty app membership: refuse with a hint, never a phantom member ─────
# App members keep their category-group membership in the real tree, so mirror
# that here: app1..app3 records move to the git group while no record carries
# app in its groups field.
set_topology_record "$fixture" app1 git ''
set_topology_record "$fixture" app2 git 'extdep'
set_topology_record "$fixture" app3 git 'app2'
if run_quiet "$fixture/o2" -n -g app; then
    fail "-n -g app succeeded with no app-group member" "$fixture/o2"
fi
grep -q 'the app list is empty' "$fixture/o2" \
    || fail "empty app membership lacks the populate hint" "$fixture/o2"
grep -q 'selection resolved to no packages' "$fixture/o2" \
    || fail "empty app membership lacks the no-selection error" "$fixture/o2"
set_topology_record "$fixture" app1 app ''
set_topology_record "$fixture" app2 app 'extdep'
set_topology_record "$fixture" app3 app 'app2'

# ── 3. Non-TTY: whole group, prompt skipped, upstream never pulled ─────────
run_quiet "$fixture/o3" -n -g app \
    || fail "non-TTY -n -g app failed" "$fixture/o3"
grep -q 'prompt skipped' "$fixture/o3" \
    || fail "non-TTY -g app did not report the skipped prompt" "$fixture/o3"
grep -q 'choose what to build' "$fixture/o3" \
    && fail "prompt rendered without a TTY" "$fixture/o3"
seq3=$(order_seq "$fixture/o3")
expected3=$(printf 'app1\napp2\napp3')
[ "$seq3" = "$expected3" ] \
    || fail "non-TTY order wrong: got [$(echo "$seq3" | tr '\n' ' ')], want [app1 app2 app3]" "$fixture/o3"
grep -q 'extdep' <(order_seq "$fixture/o3") \
    && fail "app group pulled its non-app dependency extdep into the run" "$fixture/o3"
# The count is DATA (the listed rows); the "Total: N packages" sentence is
# rendering, pinned once in tests/dashboard.sh's prose section.
[ "$(order_seq "$fixture/o3" | grep -c .)" = 3 ] \
    || fail "non-TTY -n -g app did not preview exactly 3 packages" "$fixture/o3"

# ── 4. -l: whole group, no prompt (non-TTY and on a PTY) ────────────────────
run_quiet "$fixture/o4" -l -g app \
    || fail "-l -g app failed" "$fixture/o4"
# The listed rows carry the membership (the header count is rendering).
[ "$(listed_seq "$fixture/o4")" = "$expected3" ] \
    || fail "-l -g app did not list all three members: got [$(listed_seq "$fixture/o4" | tr '\n' ' ')]" "$fixture/o4"
grep -q 'choose what to build' "$fixture/o4" \
    && fail "-l prompted on a pipe" "$fixture/o4"
# On a PTY with no input available: a prompting -l would block (timeout) or
# abort on EOF — exit 0 with the full list proves it never reads.
if ! run_pty '' "$fixture/o4p" "$fixture/state-l" -l -g app; then
    fail "-l -g app on a PTY exited non-zero (it must never prompt)" "$fixture/o4p"
fi
[ "$(listed_seq "$fixture/o4p")" = "$expected3" ] \
    || fail "-l -g app on a PTY did not list all three members: got [$(listed_seq "$fixture/o4p" | tr '\n' ' ')]" "$fixture/o4p"

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
