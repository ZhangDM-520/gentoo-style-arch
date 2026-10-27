#!/usr/bin/env bash
set -euo pipefail

# tests/gsa-query.sh — the `-Q` family's installed + side-car surface
# (contract §B.3; the 2026-10-28 grammar cluster: I1, H7/H8, I3).
# Hermetic: a scratch workspace, a scratch pacman local DB behind the
# `pacman-conf DBPath` seam, a scratch state root whose binpkg index rows
# this fixture writes in the §J.4 storage format, and PATH pacman stubs
# that record their argv.
#
# Pinned here (seven ( subshell ) sections, run one alone with
# GSA_QUERY_ONLY=a…g):
#   a. `gsa -Q` lists the INSTALLED packages (never the recipe universe)
#      with the side-car columns `abi= built= instances=` exactly where an
#      index row exists (§B.3 "where a side-car row exists");
#   b. `gsa -Qi` is MERGED info: recipe fields (Make Depends On, Sources,
#      pkgver() Function — the retired -Si content), the installed record,
#      the side-car record (ABI-Token, Subscriptions-In/Out,
#      Binpkg-Instances, VCS-Baseline) and the topology record in one
#      block;
#   c. `gsa -Qs` searches installed names/descriptions (pacman `-Qs`
#      semantics — the installed DB, not the buildable universe);
#   d. `gsa -Ql`/`gsa -Qo` are pacman delegates: the argv reaches pacman
#      verbatim and its stdout and exit code pass through (H8);
#   e. `gsa -Qu` reports the stale set as `id tracked=<pv-pr> built=<pv-pr>`
#      (the `prepare::stale_set` definition — tracked moved past the newest
#      built instance);
#   f. `gsa -Qg` lists the group roster with counts (the -Sg content, moved
#      to the query family);
#   g. `-Si`/`-Ss`/`-Sg` are RETIRED (H7/H8): rc 2, a usage error naming
#      the new `-Q` home — never a silent re-route.
#
# House conventions: ( subshell ) sections, `fail()` prefixes, rr-v2.bash's
# run_engine_user (queries are read-only, §B.10).

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"

fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-query.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

engine=${GSA_TEST_GSA_BIN:-gsa}
only=${GSA_QUERY_ONLY:-}

fail() {
    printf 'gsa-query fixture: %s\n' "$1" >&2
    exit 1
}

# An empty gsa.conf: the auto-read layers must never steer a fixture.
conf="$fixture/gsa.conf"
: >"$conf"

# make_local_db DIR — the scratch pacman local DB: foo installed WITH a
# side-car row in the workspace, bar installed with none, loose installed
# with no recipe at all.
make_local_db() {
    local db=$1
    mkdir -p "$db/local/foo-1.0-1" "$db/local/bar-2.0-1" "$db/local/loose-3.0-1"
    cat >"$db/local/foo-1.0-1/desc" <<'EOF'
%NAME%
foo

%VERSION%
1.0-1

%BASE%
foo

%DESC%
the foo widget

%PROVIDES%
libfoo.so=1-64

%DEPENDS%
bar
EOF
    printf 'usr/lib/libfoo.so.1\n' >"$db/local/foo-1.0-1/files"
    cat >"$db/local/bar-2.0-1/desc" <<'EOF'
%NAME%
bar

%VERSION%
2.0-1

%DESC%
the bar library
EOF
    : >"$db/local/bar-2.0-1/files"
    cat >"$db/local/loose-3.0-1/desc" <<'EOF'
%NAME%
loose

%VERSION%
3.0-1

%DESC%
no recipe, no side-car row
EOF
    : >"$db/local/loose-3.0-1/files"
}

# make_pacman_stubs DIR DB — `pacman-conf DBPath` answers the scratch DB;
# `pacman` records its argv to GSA_FAKE_PACMAN_LOG and answers per its
# first argument (-Ql prints a file list and exits 0; -Qo prints an owner
# line and exits 1 — the not-found rc shape).
make_pacman_stubs() {
    local dir=$1 db=$2
    mkdir -p "$dir"
    cat >"$dir/pacman-conf" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$db"
EOF
    cat >"$dir/pacman" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"${GSA_FAKE_PACMAN_LOG:?}"
case "${1:-}" in
-Ql)
    printf '%s is owned by %s\n' "${2:-}" "${2:-}"
    exit 0
    ;;
-Qo)
    printf 'error: No package owns %s\n' "${2:-}" >&2
    exit 1
    ;;
esac
exit 0
EOF
    chmod +x "$dir/pacman-conf" "$dir/pacman"
}

# write_index_row STATE JSON — one §J.4 row in the append-only index
# (storage format: `{"op":"row", …flattened IndexRow…}`).
write_index_row() {
    local state=$1 json=$2
    mkdir -p "$state/index"
    printf '%s\n' "$json" >>"$state/index/binpkg.jsonl"
}

# ── a. -Q: installed rows + side-car columns exactly where rows exist ─────
if [ -z "$only" ] || [ "$only" = a ]; then
    (
        ws="$fixture/a/ws"
        state="$fixture/a/state"
        make_workspace "$ws" 1 1 low
        add_package "$ws" foo "$gsa_meta_any"
        add_package "$ws" notinstalled "$gsa_meta_any"
        make_local_db "$fixture/a/db"
        make_pacman_stubs "$ws/bin" "$fixture/a/db"
        export PATH="$ws/bin:$PATH"
        write_index_row "$state" \
            '{"op":"row","recipe_id":"foo","pkgbase":"foo","pkgnames":["foo"],"version":"1.0-1","archive":"/x/foo-1.0-1-any.pkg.tar.zst","sha256":"00","size":1,"built_at":0,"abi_token":"tok-1","provides":[],"vcs_baseline":"abc123","instance":1}'
        GSA_CONF="$conf" GSA_STATE_DIR="$state" run_engine_user "$ws" -Q
        [ "$FIXTURE_RC" -eq 0 ] || fail "a: rc=$FIXTURE_RC want 0: $FIXTURE_OUTPUT"
        grep -Fx 'foo 0:1.0-1 abi=tok-1 built=1.0-1 instances=1' <<<"$FIXTURE_OUTPUT" >/dev/null \
            || fail "a: the side-car row's columns are missing:" "$FIXTURE_OUTPUT"
        grep -Fx 'bar 0:2.0-1' <<<"$FIXTURE_OUTPUT" >/dev/null \
            || fail "a: an installed package with no side-car row must list plain:" "$FIXTURE_OUTPUT"
        grep -Fx 'loose 0:3.0-1' <<<"$FIXTURE_OUTPUT" >/dev/null \
            || fail "a: every installed package must list:" "$FIXTURE_OUTPUT"
        # The recipe universe must not leak (I1): the uninstalled recipe
        # `notinstalled` never appears — the rows are the installed DB
        # exactly (and the -Fx pins leave no room for extra columns).
        if grep -q 'notinstalled' <<<"$FIXTURE_OUTPUT"; then
            fail "a: a recipe with no installed record leaked into -Q:" "$FIXTURE_OUTPUT"
        fi
    )
fi

# ── b. -Qi: merged info — recipe + installed + side-car + topology ────────
if [ -z "$only" ] || [ "$only" = b ]; then
    (
        ws="$fixture/b/ws"
        state="$fixture/b/state"
        make_workspace "$ws" 1 1 low
        add_package "$ws" foo "$gsa_meta_any"
        make_local_db "$fixture/b/db"
        make_pacman_stubs "$ws/bin" "$fixture/b/db"
        export PATH="$ws/bin:$PATH"
        write_index_row "$state" \
            '{"op":"row","recipe_id":"foo","pkgbase":"foo","pkgnames":["foo"],"version":"1.0-1","archive":"/x/foo-1.0-1-any.pkg.tar.zst","sha256":"00","size":1,"built_at":0,"abi_token":"tok-1","provides":[],"vcs_baseline":"abc123","instance":1}'
        GSA_CONF="$conf" GSA_STATE_DIR="$state" run_engine_user "$ws" -Qi foo
        [ "$FIXTURE_RC" -eq 0 ] || fail "b: rc=$FIXTURE_RC want 0: $FIXTURE_OUTPUT"
        # field() pads labels to 18 columns — squeeze runs of spaces so the
        # probes read `Label : value` regardless of label length.
        flat=$(tr -s ' ' <<<"$FIXTURE_OUTPUT")
        for probe in \
            'Name : foo' \
            'Installed-Version : 0:1.0-1' \
            'Installed-Provides: libfoo.so=1-64' \
            'ABI-Token : tok-1' \
            'Built-Version : 1.0-1' \
            'Binpkg-Instances : 1' \
            'VCS-Baseline : abc123' \
            'Subscriptions-In : (none)' \
            'Subscriptions-Out : (none)' \
            'Recipe-Id : foo' \
            'Metadata-Source'; do
            grep -F "$probe" <<<"$flat" >/dev/null \
                || fail "b: merged info is missing '$probe': $FIXTURE_OUTPUT"
        done
        # The retired -Si content must survive in the recipe section.
        for probe in 'Make Depends On' 'pkgver() Function' 'Sources'; do
            grep -F "$probe" <<<"$FIXTURE_OUTPUT" >/dev/null \
                || fail "b: the recipe section lost '$probe': $FIXTURE_OUTPUT"
        done
    )
fi

# ── c. -Qs: installed names/descriptions (pacman -Qs semantics) ───────────
if [ -z "$only" ] || [ "$only" = c ]; then
    (
        ws="$fixture/c/ws"
        state="$fixture/c/state"
        make_workspace "$ws" 1 1 low
        add_package "$ws" foo "$gsa_meta_any"
        make_local_db "$fixture/c/db"
        make_pacman_stubs "$ws/bin" "$fixture/c/db"
        export PATH="$ws/bin:$PATH"
        GSA_CONF="$conf" GSA_STATE_DIR="$state" run_engine_user "$ws" -Qs widget
        [ "$FIXTURE_RC" -eq 0 ] || fail "c: rc=$FIXTURE_RC want 0: $FIXTURE_OUTPUT"
        grep -Fx 'foo 0:1.0-1' <<<"$FIXTURE_OUTPUT" >/dev/null \
            || fail "c: the description search must hit foo: $FIXTURE_OUTPUT"
        grep -Fx '    the foo widget' <<<"$FIXTURE_OUTPUT" >/dev/null \
            || fail "c: the hit row must carry the indented description: $FIXTURE_OUTPUT"
        GSA_CONF="$conf" GSA_STATE_DIR="$state" run_engine_user "$ws" -Qs nomatch-at-all
        [ "$FIXTURE_RC" -eq 0 ] || fail "c: rc=$FIXTURE_RC want 0: $FIXTURE_OUTPUT"
        [ -z "$FIXTURE_OUTPUT" ] \
            || fail "c: a no-match search must print nothing: $FIXTURE_OUTPUT"
    )
fi

# ── d. -Ql/-Qo: pacman delegates (argv verbatim, stdout/rc through) ───────
if [ -z "$only" ] || [ "$only" = d ]; then
    (
        ws="$fixture/d/ws"
        state="$fixture/d/state"
        log="$fixture/d/pacman.log"
        make_workspace "$ws" 1 1 low
        add_package "$ws" foo "$gsa_meta_any"
        make_local_db "$fixture/d/db"
        make_pacman_stubs "$ws/bin" "$fixture/d/db"
        export PATH="$ws/bin:$PATH"
        GSA_CONF="$conf" GSA_STATE_DIR="$state" GSA_FAKE_PACMAN_LOG="$log" \
            run_engine_user "$ws" -Ql foo
        [ "$FIXTURE_RC" -eq 0 ] || fail "d: -Ql rc=$FIXTURE_RC want the pacman rc 0: $FIXTURE_OUTPUT"
        grep -Fx -- '-Ql foo' "$log" >/dev/null \
            || fail "d: -Ql never reached pacman verbatim: $(cat "$log" 2>&1)"
        grep -F 'foo is owned by foo' <<<"$FIXTURE_OUTPUT" >/dev/null \
            || fail "d: pacman's stdout must pass through: $FIXTURE_OUTPUT"
        GSA_CONF="$conf" GSA_STATE_DIR="$state" GSA_FAKE_PACMAN_LOG="$log" \
            run_engine_user "$ws" -Qo /nope || true
        [ "$FIXTURE_RC" -eq 1 ] || fail "d: -Qo must pass the pacman rc 1 through, got rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
        grep -Fx -- '-Qo /nope' "$log" >/dev/null \
            || fail "d: -Qo never reached pacman verbatim: $(cat "$log" 2>&1)"
    )
fi

# ── e. -Qu: the stale set as id tracked= built= ───────────────────────────
if [ -z "$only" ] || [ "$only" = e ]; then
    (
        ws="$fixture/e/ws"
        state="$fixture/e/state"
        make_workspace "$ws" 1 1 low
        add_package "$ws" stale-demo "$(printf 'pkgver=2.0.0\npkgrel=1\narch=(any)')"
        add_package "$ws" fresh-demo "$(printf 'pkgver=1.0.0\npkgrel=1\narch=(any)')"
        # Built instances beside the recipes (discovery is name-shaped):
        # stale-demo's newest built set is 1.0.0-1 (tracked 2.0.0-1), while
        # fresh-demo's is its tracked version (not stale).
        : >"$ws/packages/stale-demo/stale-demo-1.0.0-1-any.pkg.tar.zst"
        : >"$ws/packages/fresh-demo/fresh-demo-1.0.0-1-any.pkg.tar.zst"
        make_pacman_stubs "$ws/bin" "$fixture/e/db"
        export PATH="$ws/bin:$PATH"
        GSA_CONF="$conf" GSA_STATE_DIR="$state" run_engine_user "$ws" -Qu
        [ "$FIXTURE_RC" -eq 0 ] || fail "e: rc=$FIXTURE_RC want 0: $FIXTURE_OUTPUT"
        grep -Fx 'stale-demo tracked=2.0.0-1 built=1.0.0-1' <<<"$FIXTURE_OUTPUT" >/dev/null \
            || fail "e: the stale row is missing/wrong: $FIXTURE_OUTPUT"
        if grep -q 'fresh-demo' <<<"$FIXTURE_OUTPUT"; then
            fail "e: a recipe whose built set matches the tracked version is not stale: $FIXTURE_OUTPUT"
        fi
    )
fi

# ── f. -Qg: the group roster (the -Sg content, moved) ─────────────────────
if [ -z "$only" ] || [ "$only" = f ]; then
    (
        ws="$fixture/f/ws"
        state="$fixture/f/state"
        make_workspace "$ws" 1 1 low
        add_package "$ws" foo "$gsa_meta_any" git
        make_local_db "$fixture/f/db"
        make_pacman_stubs "$ws/bin" "$fixture/f/db"
        export PATH="$ws/bin:$PATH"
        GSA_CONF="$conf" GSA_STATE_DIR="$state" run_engine_user "$ws" -Qg
        [ "$FIXTURE_RC" -eq 0 ] || fail "f: rc=$FIXTURE_RC want 0: $FIXTURE_OUTPUT"
        grep -E '^git +1 packages$' <<<"$FIXTURE_OUTPUT" >/dev/null \
            || fail "f: the roster must count the git group's members: $FIXTURE_OUTPUT"
    )
fi

# ── g. -Si/-Ss/-Sg retired: named usage errors pointing at -Q ─────────────
if [ -z "$only" ] || [ "$only" = g ]; then
    (
        ws="$fixture/g/ws"
        state="$fixture/g/state"
        make_workspace "$ws" 1 1 low
        add_package "$ws" foo "$gsa_meta_any"
        make_local_db "$fixture/g/db"
        make_pacman_stubs "$ws/bin" "$fixture/g/db"
        export PATH="$ws/bin:$PATH"
        for pair in '-Si|gsa -Qi' '-Ss|gsa -Qs' '-Sg|gsa -Qg'; do
            spelling=${pair%%|*}
            moved_to=${pair##*|}
            GSA_CONF="$conf" GSA_STATE_DIR="$state" run_engine_user "$ws" "$spelling" foo || true
            [ "$FIXTURE_RC" -eq 2 ] \
                || fail "g: $spelling must answer rc 2, got rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
            grep -F 'retired' <<<"$FIXTURE_OUTPUT" >/dev/null \
                || fail "g: $spelling must say it is retired: $FIXTURE_OUTPUT"
            grep -F "$moved_to" <<<"$FIXTURE_OUTPUT" >/dev/null \
                || fail "g: $spelling must name its new home $moved_to: $FIXTURE_OUTPUT"
        done
    )
fi

printf 'gsa-query: PASS\n'
