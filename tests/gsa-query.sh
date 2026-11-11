#!/usr/bin/env bash
set -euo pipefail

# tests/gsa-query.sh — the `-Q` family's installed + side-car surface
# (contract §B.3; the 2026-10-28 grammar cluster: I1, H7/H8, I3).
# Hermetic: a scratch workspace, a scratch pacman local DB behind the
# `pacman-conf DBPath` seam, a scratch state root whose binpkg index rows
# this fixture writes in the §J.4 storage format, and PATH pacman stubs
# that record their argv.
#
# Pinned here (( subshell ) sections, run one alone with
# GSA_QUERY_ONLY=<letter>, the letters being the `if ... only` blocks below):
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
#   e. `gsa -Qu` reports the stale set as
#      `id tracked=<ver> installed=<ver|-> built=<ver|->` (the
#      `prepare::stale_set` definition: the INSTALLED record when one
#      exists, else the newest built instance — a refused install never
#      vanishes from it);
#   f. `gsa -Qg` lists the group roster with counts (the -Sg content, moved
#      to the query family);
#   g. `-Si`/`-Ss`/`-Sg` are RETIRED (H7/H8): rc 2, a usage error naming
#      the new `-Q` home — never a silent re-route;
#   h. a `-Q` verb against a PRISTINE root creates no state (it must run
#      unprivileged and report the empty side-car, never mkdir/chown);
#   i. a CLOSED READER is normal Unix: `gsa -Q | head` must exit 0 with no
#      "Broken pipe" diagnostic, never route an EPIPE through the usage path.
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
        # The machine channel never carries a style escape (contract §L.9):
        # a captured stdout is the stable surface, whatever --color says.
        if grep -q $'\x1b' <<<"$FIXTURE_OUTPUT"; then
            fail "a: the -Q machine rows carried an escape byte:" "$FIXTURE_OUTPUT"
        fi
        # A listing has ONE row vocabulary: `--machine` changes nothing
        # (contract §L.9 — the mode selects the event grammar of the RUN
        # verbs; a listing emits no events). 2026-11-11 blind-review
        # finding: the help promised the mode for all families.
        plain=$FIXTURE_OUTPUT
        GSA_CONF="$conf" GSA_STATE_DIR="$state" run_engine_user "$ws" -Q --machine
        [ "$FIXTURE_RC" -eq 0 ] || fail "a: -Q --machine rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
        [ "$FIXTURE_OUTPUT" = "$plain" ] \
            || fail "a: --machine must leave a listing's rows byte-identical (§L.9): $FIXTURE_OUTPUT"
    )
fi

# ── b. -Qi: merged info — recipe + installed + side-car + topology ────────
if [ -z "$only" ] || [ "$only" = b ]; then
    (
        ws="$fixture/b/ws"
        state="$fixture/b/state"
        make_workspace "$ws" 1 1 low
        # A recipe with NO committed `.SRCINFO`: the recipe-section fields
        # must come from the read-only PKGBUILD scan, never `(scan)`/`(none)`
        # (blind-review finding, 2026-11-11).
        b_meta=$(printf '%s\n' \
            'pkgver=1.0.0' 'pkgrel=1' "arch=('x86_64')" \
            'url="https://example.invalid/foo"' "license=('MIT' 'Apache-2.0')" \
            "depends=('bar>=2')" 'makedepends=("$BUILDDEP")')
        add_package "$ws" foo "$b_meta"
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
            'URL : https://example.invalid/foo' \
            'Architecture : x86_64' \
            'Licenses : MIT, Apache-2.0' \
            'Depends On : bar>=2' \
            'Make Depends On : (dynamic)' \
            'Metadata-Source'; do
            grep -F "$probe" <<<"$flat" >/dev/null \
                || fail "b: merged info is missing '$probe': $FIXTURE_OUTPUT"
        done
        # The retired -Si content must survive in the recipe section.
        for probe in 'Make Depends On' 'pkgver() Function' 'Sources'; do
            grep -F "$probe" <<<"$FIXTURE_OUTPUT" >/dev/null \
                || fail "b: the recipe section lost '$probe': $FIXTURE_OUTPUT"
        done

        # An INSTALLED name no recipe owns resolves to its pacman fields:
        # `-Q` lists `loose`, and `-Qi loose` used to answer "unknown
        # reference (nearest candidates: foo)" (blind review, 2026-11-11).
        GSA_CONF="$conf" GSA_STATE_DIR="$state" run_engine_user "$ws" -Qi loose
        [ "$FIXTURE_RC" -eq 0 ] \
            || fail "b: -Qi over an installed non-recipe name rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
        flat=$(tr -s ' ' <<<"$FIXTURE_OUTPUT")
        for probe in 'Name : loose' 'Version : 0:3.0-1' 'not a house recipe'; do
            grep -F "$probe" <<<"$flat" >/dev/null \
                || fail "b: the installed-only block is missing '$probe': $FIXTURE_OUTPUT"
        done
        # Recipe metadata is DATA: an ESC sequence or a CR in `pkgdesc` must
        # not repaint the terminal, split the line, or reach `--machine`
        # (blind review, 2026-11-11).
        add_package "$ws" escape "$(printf 'pkgver=1.0.0\npkgrel=1\narch=(any)\npkgdesc="\033[31mRED-ALERT\rline-two keeps going"')"
        for mode in "" "--machine"; do
            GSA_CONF="$conf" GSA_STATE_DIR="$state" run_engine_user "$ws" -Qi escape $mode
            [ "$FIXTURE_RC" -eq 0 ] \
                || fail "b: -Qi escape$mode rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
            if printf '%s' "$FIXTURE_OUTPUT" | LC_ALL=C grep -q $'\033'; then
                fail "b: an escape byte reached the output (-Qi escape $mode): $FIXTURE_OUTPUT"
            fi
            if printf '%s' "$FIXTURE_OUTPUT" | LC_ALL=C grep -q $'\r'; then
                fail "b: a CR reached the output (-Qi escape $mode): $FIXTURE_OUTPUT"
            fi
            grep -F 'RED-ALERT line-two keeps going' <<<"$(tr -s ' ' <<<"$FIXTURE_OUTPUT")" >/dev/null \
                || fail "b: the description text was mangled (-Qi escape $mode): $FIXTURE_OUTPUT"
        done

        # A name that is neither a recipe nor installed keeps the hint.
        GSA_CONF="$conf" GSA_STATE_DIR="$state" run_engine_user "$ws" -Qi nosuchpkg
        [ "$FIXTURE_RC" -eq 2 ] \
            || fail "b: -Qi over an unknown name must stay rc 2, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        grep -F 'unknown reference' <<<"$FIXTURE_OUTPUT" >/dev/null \
            || fail "b: an unknown name must keep the unknown-reference error: $FIXTURE_OUTPUT"
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

# ── e. -Qu: the stale set as id tracked= installed= built= ────────────────
if [ -z "$only" ] || [ "$only" = e ]; then
    (
        ws="$fixture/e/ws"
        state="$fixture/e/state"
        db="$fixture/e/db"
        make_workspace "$ws" 1 1 low
        add_package "$ws" stale-demo "$(printf 'pkgver=2.0.0\npkgrel=1\narch=(any)')"
        add_package "$ws" fresh-demo "$(printf 'pkgver=1.0.0\npkgrel=1\narch=(any)')"
        add_package "$ws" refused-demo "$(printf 'pkgver=2.0.0\npkgrel=1\narch=(any)')"
        # Built instances beside the recipes (discovery is name-shaped):
        # stale-demo's newest built set is 1.0.0-1 (tracked 2.0.0-1), while
        # fresh-demo's is its tracked version (not stale). refused-demo's
        # archive IS its tracked version — the install was refused, so the
        # installed record, not the archive, decides (2026-11-11).
        : >"$ws/packages/stale-demo/stale-demo-1.0.0-1-any.pkg.tar.zst"
        : >"$ws/packages/fresh-demo/fresh-demo-1.0.0-1-any.pkg.tar.zst"
        : >"$ws/packages/refused-demo/refused-demo-2.0.0-1-any.pkg.tar.zst"
        # The scratch installed DB: fresh-demo is current, refused-demo is
        # one version behind its own archive.
        mkdir -p "$db/local/fresh-demo-1.0.0-1" "$db/local/refused-demo-1.0.0-1"
        printf '%%NAME%%\nfresh-demo\n\n%%VERSION%%\n1.0.0-1\n' \
            >"$db/local/fresh-demo-1.0.0-1/desc"
        printf '%%NAME%%\nrefused-demo\n\n%%VERSION%%\n1.0.0-1\n' \
            >"$db/local/refused-demo-1.0.0-1/desc"
        : >"$db/local/fresh-demo-1.0.0-1/files"
        : >"$db/local/refused-demo-1.0.0-1/files"
        make_pacman_stubs "$ws/bin" "$db"
        export PATH="$ws/bin:$PATH"
        GSA_CONF="$conf" GSA_STATE_DIR="$state" run_engine_user "$ws" -Qu
        [ "$FIXTURE_RC" -eq 0 ] || fail "e: rc=$FIXTURE_RC want 0: $FIXTURE_OUTPUT"
        grep -Fx 'stale-demo tracked=2.0.0-1 installed=- built=1.0.0-1' <<<"$FIXTURE_OUTPUT" >/dev/null \
            || fail "e: the built-set stale row is missing/wrong: $FIXTURE_OUTPUT"
        # A refused install must never vanish: the archive matches the
        # tracked version, yet the host still runs 1.0.0-1.
        grep -Fx 'refused-demo tracked=2.0.0-1 installed=0:1.0.0-1 built=2.0.0-1' <<<"$FIXTURE_OUTPUT" >/dev/null \
            || fail "e: a recipe whose INSTALL is behind its own archive is stale: $FIXTURE_OUTPUT"
        if grep -q 'fresh-demo' <<<"$FIXTURE_OUTPUT"; then
            fail "e: a recipe at its tracked version is not stale: $FIXTURE_OUTPUT"
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

# ── h. a query against a pristine root creates no state ───────────────────
if [ -z "$only" ] || [ "$only" = h ]; then
    (
        ws="$fixture/h/ws"
        state="$fixture/h/never"
        make_workspace "$ws" 1 1 low
        add_package "$ws" foo "$gsa_meta_any"
        make_local_db "$fixture/h/db"
        make_pacman_stubs "$ws/bin" "$fixture/h/db"
        export PATH="$ws/bin:$PATH"
        for verb in -Q -Qb -Qu; do
            GSA_CONF="$conf" GSA_STATE_DIR="$state" run_engine_user "$ws" "$verb"
            [ "$FIXTURE_RC" -eq 0 ] \
                || fail "h: $verb must read a pristine root without creating it (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
            [ ! -e "$state" ] \
                || fail "h: $verb created the state root $state (a query never owns state)"
        done
    )
fi

# ── i. a closed reader is normal Unix (SIGPIPE) ───────────────────────────
if [ -z "$only" ] || [ "$only" = i ]; then
    (
        ws="$fixture/i2/ws"
        state="$fixture/i2/state"
        make_workspace "$ws" 1 1 low
        add_package "$ws" foo "$gsa_meta_any"
        # Enough rows that the listing overflows a pipe buffer: with fewer,
        # the writer finishes before the reader closes and no EPIPE can ever
        # be observed (the pin would pass vacuously).
        db="$fixture/i2/db"
        mkdir -p "$db/local"
        for i in $(seq 1 2000); do
            dir="$db/local/bulk-$i-1.0-1"
            mkdir -p "$dir"
            printf '%%NAME%%\nbulk-%s\n\n%%VERSION%%\n1.0-1\n\n%%DESC%%\n%s\n' \
                "$i" "a bulk package row long enough to overflow the pipe buffer" >"$dir/desc"
            : >"$dir/files"
        done
        make_pacman_stubs "$ws/bin" "$db"
        export PATH="$ws/bin:$PATH"
        export GSA_CONF="$conf" GSA_STATE_DIR="$state"

        # `head -c 1` closes the reader as soon as the first byte lands, so
        # the engine's next write is an EPIPE — the ordinary Unix ending of
        # a paged listing, never an error.
        errlog="$fixture/i2/err"
        set +e
        bash -c '"$1" -Q 2>"$2" | head -c 1 >/dev/null; exit "${PIPESTATUS[0]}"' \
            _ "$engine" "$errlog"
        rc=$?
        set -e
        [ "$rc" -eq 0 ] \
            || fail "i: a closed reader must leave rc 0 (got $rc): $(cat "$errlog" 2>/dev/null)"
        if grep -qi 'broken pipe' "$errlog"; then
            fail "i: a closed reader must not print a broken-pipe diagnostic: $(cat "$errlog")"
        fi

        # The same listing still completes whole when nobody closes it.
        run_engine_user "$ws" -Q
        [ "$FIXTURE_RC" -eq 0 ] || fail "i: rc=$FIXTURE_RC want 0: $FIXTURE_OUTPUT"
        grep -c '^bulk-1 0:1.0-1$' <<<"$FIXTURE_OUTPUT" >/dev/null \
            || fail "i: the complete listing must carry every row: $FIXTURE_OUTPUT"
    )
fi

# ── j. `--state-dir` is accepted by every dispatched verb ─────────────────
# The same per-job flag set must survive read-only verbs: `-Qg -Qs -Ql -Qu
# -Qt -Sl -Bl` used to answer rc 2 "deferred to a later phase: --state-dir"
# while `GSA_STATE_DIR` was honoured by all of them, so one input had two
# answers (rule 73) and CI could not preflight with the flags it builds
# with (blind-review 2026-11-11, ci-fleet-operator).
if [ -z "$only" ] || [ "$only" = j ]; then
    (
        ws="$fixture/j/ws"
        state="$fixture/j/state"
        make_workspace "$ws" 1 1 low
        add_package "$ws" foo "$gsa_meta_any" git
        make_local_db "$fixture/j/db"
        make_pacman_stubs "$ws/bin" "$fixture/j/db"
        export PATH="$ws/bin:$PATH"
        export GSA_FAKE_PACMAN_LOG="$fixture/j/pacman.log"
        : >"$GSA_FAKE_PACMAN_LOG"
        for spelling in "-Q" "-Qi foo" "-Qg" "-Qs foo" "-Ql foo" "-Qu" "-Qb" \
            "-Qr" "-Qt" "-Sl" "-Bl foo" "-B --dry-run foo"; do
            # shellcheck disable=SC2086 # the spelling is the argv under test
            GSA_CONF="$conf" run_engine_user "$ws" $spelling --state-dir "$state"
            [ "$FIXTURE_RC" -eq 0 ] \
                || fail "j: '$spelling --state-dir' must be accepted (rc 0), got $FIXTURE_RC: $FIXTURE_OUTPUT"
            if grep -q 'deferred to a later phase' <<<"$FIXTURE_OUTPUT"; then
                fail "j: '$spelling --state-dir' must not call the flag deferred: $FIXTURE_OUTPUT"
            fi
        done
    )
fi

# ── k. -Qi on a narrow (20-column) terminal must RETURN ───────────────────
# The wrapper used `indent = 20` with the terminal width floored at 20, so at
# exactly 20 columns every wrapped field re-queued the same word forever:
# nothing printed, memory grew ~240 MB/s, 16 GB in a minute (blind-review
# 2026-11-11, locale-terminal). A pty is the only place a width exists.
if [ -z "$only" ] || [ "$only" = k ]; then
    (
        ws="$fixture/k/ws"
        state="$fixture/k/state"
        make_workspace "$ws" 1 1 low
        add_package "$ws" foo "$gsa_meta_any"
        make_local_db "$fixture/k/db"
        make_pacman_stubs "$ws/bin" "$fixture/k/db"
        export PATH="$ws/bin:$PATH"
        export GSA_FAKE_PACMAN_LOG="$fixture/k/pacman.log"
        : >"$GSA_FAKE_PACMAN_LOG"
        runner=$fixture/k/runner.sh
        {
            printf '#!/bin/bash\n'
            printf 'cd %q || exit 127\n' "$ws"
            printf 'stty cols 20 rows 40 2>/dev/null || true\n'
            printf 'exec env GSA_CONF=%q GSA_STATE_DIR=%q %q -Qi foo\n' \
                "$conf" "$state" "$engine"
        } >"$runner"
        set +e
        timeout 30 env TERM=dumb script -qec "/bin/bash $(printf %q "$runner")" /dev/null \
            >"$fixture/k/out" 2>&1
        rc=$?
        set -e
        [ "$rc" -eq 0 ] \
            || fail "k: -Qi on a 20-column terminal must return rc 0, got $rc (a hang here is the wrap loop):" "$fixture/k/out"
        grep -q 'Name' "$fixture/k/out" \
            || fail "k: the narrow-terminal -Qi rendered nothing:" "$fixture/k/out"
        # No line may exceed the terminal: the wrap budget is the width.
        # Engine notes are their own stream (and are not wrapped); the -Qi
        # body must stay inside the terminal.
        tr -d '\r' <"$fixture/k/out" | grep -v '^gsa:' >"$fixture/k/body"
        if awk 'length($0) > 21 { wide = 1 } END { exit !wide }' "$fixture/k/body"; then
            fail "k: a -Qi line ran past the 20-column terminal:" "$fixture/k/body"
        fi
    )
fi

# ── l. a non-UTF-8 argument is a usage error, never a panic ───────────────
# argv is bytes on Unix (a latin-1 directory name is legal), and
# `std::env::args()` panicked on any of them — rc 101 with a Rust backtrace,
# before a verb was classified (blind-review 2026-11-11, locale-terminal).
if [ -z "$only" ] || [ "$only" = l ]; then
    (
        ws="$fixture/l/ws"
        state="$fixture/l/state"
        make_workspace "$ws" 1 1 low
        add_package "$ws" foo "$gsa_meta_any"
        make_local_db "$fixture/l/db"
        make_pacman_stubs "$ws/bin" "$fixture/l/db"
        export PATH="$ws/bin:$PATH"
        export GSA_FAKE_PACMAN_LOG="$fixture/l/pacman.log"
        : >"$GSA_FAKE_PACMAN_LOG"
        bad_state=$'/work/st\xffate'
        bad_build=$'/work/bu\xffild'
        bad_pkg=$'h\xffllo'

        # check_bad WHAT ARG... — the run must answer the usage class, name
        # the encoding, and never panic.
        check_bad() {
            local what=$1
            shift
            GSA_CONF="$conf" run_engine_user "$ws" "$@"
            [ "$FIXTURE_RC" -eq 2 ] \
                || fail "l: $what must be a usage error (rc 2), got $FIXTURE_RC: $FIXTURE_OUTPUT"
            grep -q 'not valid UTF-8' <<<"$FIXTURE_OUTPUT" \
                || fail "l: $what must name the encoding problem: $FIXTURE_OUTPUT"
            if grep -q 'panicked at' <<<"$FIXTURE_OUTPUT"; then
                fail "l: $what panicked the engine: $FIXTURE_OUTPUT"
            fi
        }
        check_bad "a non-UTF-8 --state-dir" -Q --state-dir "$bad_state"
        check_bad "a non-UTF-8 --build-dir" -B --build-dir "$bad_build" --dry-run foo
        check_bad "a non-UTF-8 target" -Sl "$bad_pkg"
    )
fi

printf 'gsa-query: PASS\n'
