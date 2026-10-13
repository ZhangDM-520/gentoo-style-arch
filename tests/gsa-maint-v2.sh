#!/usr/bin/env bash
set -euo pipefail

# tests/gsa-maint-v2.sh — the `-M` maintain surface of the NATIVE engine
# (`gsa`, crates/gsa-maint + crates/gsa-cli/src/maint.rs; contract
# docs/gsa-contract.md §B.7/§E.2/§E.4/§G.1/§J/§K.3/§H/§L). Everything here is
# synthetic: $TMPDIR workspaces, stub `makepkg`/`sudo`/`pacman` executables,
# scratch `pacman.conf`/`config/sets/` targets and a `--state-dir` override on
# EVERY engine call — the real `/var/lib/gsa` is never read or written
# (asserted inside each section and again at fixture end). Expectations are
# DERIVED (contract §L.3): expected rows are computed from the synthetic
# state and files each section itself created (paths, seeded closure names,
# seeded history records, mtime ordering), never from pinned opaque counts;
# where a summary carries a count (`audit <family> N finding(s)`,
# `doctor report N finding(s)`) the fixture recomputes N from the row stream.
#
# Pinned here (eight ( subshell ) sections; run one alone with
# GSA_MAINT_V2_ONLY=a…h):
#   a. `-Ma` audit report is report-only (§E.4): rc 0 on a synthetic
#      workspace that deliberately carries findings (unregistered recipe
#      dir, legacy `.Stable/` path reference, stale `.tmp.` artifact); rows
#      follow the §E.2 grammar `<subject> <action> <reason…>` and each
#      family summary agrees with its own finding rows.
#   b. `-Md` report vs `--fix`: a deleted archive leaves an orphan index
#      ROW, a staged archive beside a recipe with no row is an orphan
#      ARCHIVE; the report names both (rc 0), `--fix` tombstones the row and
#      reindexes the archive with rows naming each action (rc 0), and the
#      re-report shows both findings gone.
#   c. `-Mi` IgnorePkg closure of a scratch `pacman.conf` (never
#      /etc/pacman.conf): one entry declared by a committed recipe (in-use),
#      one declared by nothing (stale), one wanted name missing from the
#      closure. Default reports drift; `--prune` removes ONLY the stale name
#      (the declared one survives — the pruning-safety assertion) and
#      `--backfill` adds the missing declared name; mutation stays in the
#      scratch conf.
#   d. `-Ml` log browse/tail/retention: synthetic `<state>/logs/` files
#      incl. rotated `<pkg>.log.N` siblings with fixture-set mtimes; the
#      listing rows name every log, `--tail <ref>` renders the tail,
#      `--keep N` keeps the N newest per stem (mtime order DERIVED from the
#      timestamps the section set) and deletes the rest with `keep`/`pruned`
#      rows.
#   e. `-Mm` mirrors: one git-source group whose canonical is missing (the
#      other twin earns a dangling `link` row) with a populated non-git
#      member (`skip`, never replaced), and one group of two real git
#      clones (`git init` under GIT_CONFIG_COUNT=0). Confirmation model:
#      `--dry-run` renders rc 0 and mutates nothing, without `--noconfirm`
#      the plan prints and the run stops rc 3 `confirmation-required`
#      applying NOTHING, with `--noconfirm` it applies (dangling link
#      created, populated dir untouched). As root the verb refuses (the
#      refusal itself is asserted and the section notes the skip).
#   f. `-Ms`/`-Mw` sets: a committed `config/sets/` file and the state kv
#      store drift apart; listing REPORTS the drift and leaves the config
#      bytes byte-identical; `--add`/`--remove` edit the kv side only (rows
#      name the edit); a computed set (`@stale`) as edit target refuses;
#      the `--add`+`--remove` fence is rc 2.
#   g. `-Mh` run history: two real stub `-B` runs land real records; the
#      list shows both with their continuations; `--show <id>` re-renders a
#      stored record byte-identical to the block its run emitted (diff);
#      `--prune` retention over a seeded history (finished + unfinished
#      records) keeps every unfinished record as a resume pointer, prunes
#      the oldest finished ones beyond the budget and compacts
#      history.jsonl. Also the §J.3 override check (flag beats env, env
#      alone relocates the root) with the /var/lib/gsa assertion.
#   h. `-Mc`/`-Mcc`/`-Mccc` + safety + continuation pin + rc classes:
#      strength 1 prunes only the selection's trees/archives, strength 2
#      sweeps every archive, strength 3 additionally pulls sources after
#      the same confirmation model (downloads, companions, staging trees
#      and the pulled source-clone directory are all removed — the clone
#      recursively — the row and the filesystem agree, never a silent
#      half-state); an archive whose recipe is named in the
#      newest stored run record's `remaining:` earns
#      `keep … referenced-by-run` and its file survives every strength, and
#      a symlinked archive is never deleted or followed (its outside target
#      survives). A `flock(1)` holder on `<state>/locks/run.lock` makes a
#      mutating verb refuse rc 3 `run-in-flight` without touching anything.
#      The build run's `format: 2` block (rr-v2.bash) carries every -M
#      spelling and sub-flag in `not-mirrored:` and its `command:` never
#      contains an `-M` token. rc classes asserted by exact code: usage 2
#      (bare `-M`, `-Mc` without selection), refusal 3 (confirmation,
#      run-in-flight).
#
# Red-first (contract §L.4): the pruning-safety deliverable is mutation-
# probed during development — breaking `protect::referenced_by_run` in
# crates/gsa-maint/src/protect.rs (returning an empty set) makes section h
# fail NAMED (`keep referenced-by-run` row missing / the referenced archive
# deleted) while the unreferenced rows stay green; the probe restores the
# source byte-identically (sha256 + `git diff -- crates/gsa-maint/src`), and
# `touch`es it, then the fixture goes green again. The probe's red message,
# restore proof and green rerun are recorded in the change report.
#
# House conventions: `( subshell )` sections (each an isolated scenario with
# its own workspace AND its own state root), inline oracle stubs (§D.2),
# `fail()` prefixes, and tests/lib/rr-v2.bash's `format: 2` parser +
# run_engine with GSA_TEST_ENGINE=gsa.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"

fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-maint-v2.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf '%s\n' "$1" >&2
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
        sed 's/^/    /' "$2" >&2
    fi
    exit 1
}

# Section filter: GSA_MAINT_V2_ONLY=<a..h> runs exactly one section.
want() { [ -z "${GSA_MAINT_V2_ONLY:-}" ] || [ "${GSA_MAINT_V2_ONLY}" = "$1" ]; }

# The real /var/lib/gsa must never move under this fixture (§J.3: every
# state root here is an override). Fingerprint the tree (names, sizes,
# mtimes) now; re-checked inside every section and at fixture end.
varlib_fingerprint() {
    (find /var/lib/gsa -printf '%p %s %T@\n' 2>/dev/null || true) | sort | md5sum
}
varlib_before=$(varlib_fingerprint)
assert_varlib_unchanged() {
    local now
    now=$(varlib_fingerprint)
    [ "$now" = "$varlib_before" ] ||
        fail "the real /var/lib/gsa moved under tests/gsa-maint-v2.sh — every state root must be a --state-dir/GSA_STATE_DIR override (§J.3)"
}

# ─── The engine under test: built into the fixture tree (scratch only).
# GSA_TEST_GSA_BIN, when already set to an executable, is that engine (the
# rr-v2.bash run_engine convention) and the scratch build is skipped. ──────
if [ -z "${GSA_TEST_GSA_BIN:-}" ]; then
    cargo build --offline --quiet --target-dir "$fixture/cargo" -p gsa-cli \
        --manifest-path "$gsa_repo_root/Cargo.toml" \
        || fail "cannot build the gsa binary for the fixture"
    GSA_TEST_GSA_BIN="$fixture/cargo/debug/gsa"
fi
[ -x "$GSA_TEST_GSA_BIN" ] || fail "the engine under test is not executable: $GSA_TEST_GSA_BIN"
export GSA_TEST_ENGINE=gsa
export GSA_TEST_GSA_BIN

# ─── Oracle stubs and derivation helpers (inline: §D.2 keeps oracles in the
# fixture that gives them meaning) ──────────────────────────────────────────

# stage_pkginfo STAGE PKGBASE PKGNAME PKGVER — the staged `.PKGINFO` of one
# hand-built archive (the metadata truth rule 9 makes authoritative).
stage_pkginfo() {
    local stage=$1 base=$2 name=$3 ver=$4
    mkdir -p "$stage"
    {
        printf 'pkgbase = %s\n' "$base"
        printf 'pkgname = %s\n' "$name"
        printf 'pkgver = %s\n' "$ver"
        printf 'arch = any\n'
    } >"$stage/.PKGINFO"
}

# make_archive OUT STAGE — one real `.pkg.tar.zst` from a prepared stage dir.
# The stage is consumed.
make_archive() {
    local out=$1 stage=$2
    mkdir -p "$(dirname "$out")"
    tar --zstd -cf "$out" -C "$stage" .PKGINFO
    rm -rf -- "$stage"
}

# write_stub_makepkg DIR — the scenario makepkg: one real `.pkg.tar.zst` per
# build beside the recipe, carrying its own `.PKGINFO` truth (the hash-bound
# index registration reads it).
write_stub_makepkg() {
    cat >"$1/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
case " $* " in
*" --verifysource "*) exit 0 ;; # fetch children are advisory here
esac
id=$(basename "$PWD")
stage="$PWD/.stage-$id-$$"
mkdir -p "$stage"
{
    printf 'pkgbase = %s\n' "$id"
    printf 'pkgname = %s\n' "$id"
    printf 'pkgver = 1.0.0-1\n'
    printf 'arch = any\n'
} >"$stage/.PKGINFO"
tar --zstd -cf "$PWD/$id-1.0.0-1-any.pkg.tar.zst" -C "$stage" .PKGINFO
rm -rf "$stage"
exit 0
EOF
    chmod +x "$1/bin/makepkg"
}

# maint_ws DIR — one workspace with the stubs on PATH (the sudo/pacman
# passthroughs keep any accidental escalation away from the host).
maint_ws() {
    local ws=$1
    write_stub_makepkg "$ws"
    stub_sudo "$ws"
    stub_pacman "$ws"
    export PATH="$ws/bin:$PATH"
    : >"$ws/bin/.pacman.log"
    export GSA_FAKE_PACMAN_LOG="$ws/bin/.pacman.log"
}

# rows_shape TEXT — the §E.2 row grammar: every line is
# `<subject> <action> [reason…]` (≥2 fields, single-line, no stray edges).
rows_shape() {
    printf '%s\n' "$1" | awk '
        NF < 2 || $0 ~ /^ / || $0 ~ / $/ { print; bad = 1 }
        END { exit bad }
    '
}

# has_row TEXT NEEDLE [DESC] — one full row fragment must be present.
has_row() {
    printf '%s\n' "$1" | grep -F -- "$2" >/dev/null ||
        fail "missing row ($3): '$2' in:
$1"
}

# absent_row TEXT NEEDLE [DESC] — no row may carry this fragment.
absent_row() {
    if printf '%s\n' "$1" | grep -F -- "$2" >/dev/null; then
        fail "unexpected row ($3): '$2' in:
$1"
    fi
}

# ─── a. -Ma: the audit report is report-only, even with findings (§E.4) ────
if want a; then
    (
        set -euo pipefail
        ws="$fixture/a/ws"
        state="$fixture/a/state"
        make_workspace "$ws" 1 auto low
        add_package "$ws" auda "$gsa_meta_any" git

        # Three seeded findings, one per family this section pins.
        mkdir -p "$ws/packages/ghost"
        printf 'pkgname=ghost\n' >"$ws/packages/ghost/PKGBUILD" # package-drift
        printf 'old .Stable/ layout note\n' >"$ws/legacy-note.txt" # legacy-layout
        mkdir -p "$state"
        printf 'dead temp\n' >"$state/junk.tmp.1" # stale-artifact

        run_engine "$ws" -Ma --state-dir "$state"
        [ "$FIXTURE_RC" = 0 ] || fail "-Ma is report-only and exits 0 even with findings (§E.4), got $FIXTURE_RC: $FIXTURE_OUTPUT"
        rows_shape "$FIXTURE_OUTPUT" ||
            fail "-Ma rows must follow <subject> <action> <reason…> (§E.2): $FIXTURE_OUTPUT"

        # The seeded findings are named (derived from the artifacts above).
        has_row "$FIXTURE_OUTPUT" "package-drift packages/ghost unregistered-recipe-dir" "unregistered recipe dir"
        has_row "$FIXTURE_OUTPUT" "legacy-layout $ws/legacy-note.txt:1 .Stable/" "legacy layout reference"
        has_row "$FIXTURE_OUTPUT" "stale-artifact $state/junk.tmp.1 tmp-artifact" "stale tmp artifact"

        # Report-only means findings never change rc — prove findings exist.
        [ "$(printf '%s\n' "$FIXTURE_OUTPUT" | grep -c ' unregistered-recipe-dir')" -ge 1 ] ||
            fail "-Ma must actually report findings (else rc 0 proves nothing): $FIXTURE_OUTPUT"

        # Each family summary agrees with its own finding rows (derived).
        for family in legacy-layout package-drift toolchain-edge stale-artifact \
            recipe-contract version-sync-skew installed-pgo; do
            summary=$(printf '%s\n' "$FIXTURE_OUTPUT" |
                awk -v f="$family" '$1 == "audit" && $2 == f { print; exit }')
            [ -n "$summary" ] || fail "-Ma must summarise family $family: $FIXTURE_OUTPUT"
            count=$(printf '%s\n' "$FIXTURE_OUTPUT" | awk -v f="$family" '$1 == f' | wc -l)
            case $summary in
            *" clean")
                [ "$count" = 0 ] ||
                    fail "family $family says clean but has $count finding rows: $FIXTURE_OUTPUT"
                ;;
            *" $count finding(s)") ;;
            *)
                fail "family $family summary disagrees with its rows ('$summary' vs $count rows): $FIXTURE_OUTPUT"
                ;;
            esac
        done
        assert_varlib_unchanged
    )
fi

# ─── b. -Md: report vs --fix over orphan rows and orphan archives ──────────
if want b; then
    (
        set -euo pipefail
        ws="$fixture/b/ws"
        state="$fixture/b/state"
        make_workspace "$ws" 1 auto low
        maint_ws "$ws"
        add_package "$ws" doca "$gsa_meta_any" git
        add_package "$ws" docb "$gsa_meta_any" git

        # Orphan ROW: a real build registers its archive, then the archive
        # disappears — the row outlives its referent.
        run_engine "$ws" -B --no-prefetch --leaf --state-dir "$state" docb
        [ "$FIXTURE_RC" = 0 ] || fail "the seeding build is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        gone="$ws/packages/docb/docb-1.0.0-1-any.pkg.tar.zst"
        [ -f "$gone" ] || fail "the stub build produced no archive: $gone"
        rm -f "$gone"

        # Orphan ARCHIVE: staged beside a recipe, no index row at all.
        stage="$fixture/b/stage"
        stage_pkginfo "$stage" doca doca 9.9.9-1
        ghost="$ws/packages/doca/doca-9.9.9-1-any.pkg.tar.zst"
        make_archive "$ghost" "$stage"

        run_engine "$ws" -Md --state-dir "$state"
        [ "$FIXTURE_RC" = 0 ] || fail "-Md reports and exits 0 (§E.4), got $FIXTURE_RC: $FIXTURE_OUTPUT"
        has_row "$FIXTURE_OUTPUT" "$gone orphan-row archive-gone docb instance=1" "orphan index row"
        has_row "$FIXTURE_OUTPUT" "$ghost orphan-archive no-index-row doca" "orphan archive"
        # The summary count is the row stream's own (derived, not pinned).
        summary=$(printf '%s\n' "$FIXTURE_OUTPUT" | awk '$1 == "doctor" && $2 == "report" { print; exit }')
        [ -n "$summary" ] || fail "-Md must lead with a doctor report row: $FIXTURE_OUTPUT"
        findings=$(printf '%s\n' "$FIXTURE_OUTPUT" | tail -n +2 | wc -l)
        case $summary in
        *" $findings finding(s)") ;;
        *) fail "doctor summary disagrees with its rows ('$summary' vs $findings rows): $FIXTURE_OUTPUT" ;;
        esac

        # --fix applies exactly the named repairs (rc 0).
        run_engine "$ws" -Md --fix --state-dir "$state"
        [ "$FIXTURE_RC" = 0 ] || fail "-Md --fix succeeds on clean repairs, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        has_row "$FIXTURE_OUTPUT" "$gone tombstoned orphan-row docb instance=1" "orphan-row tombstone"
        has_row "$FIXTURE_OUTPUT" "$ghost reindexed doca instance=1" "orphan-archive reindex"

        # Re-report: both seeded findings are gone (derived from the seeds).
        run_engine "$ws" -Md --state-dir "$state"
        [ "$FIXTURE_RC" = 0 ] || fail "-Md after --fix is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        absent_row "$FIXTURE_OUTPUT" "orphan-row" "orphan row must be tombstoned"
        absent_row "$FIXTURE_OUTPUT" "orphan-archive" "orphan archive must be reindexed"
        assert_varlib_unchanged
    )
fi

# ─── c. -Mi: the IgnorePkg closure of a scratch pacman.conf ────────────────
if want c; then
    (
        set -euo pipefail
        ws="$fixture/c/ws"
        state="$fixture/c/state"
        make_workspace "$ws" 1 auto low
        add_package "$ws" ignorea "$gsa_meta_any" git
        add_package "$ws" ignoreb "$gsa_meta_any" git

        # The closure under test: NEVER /etc/pacman.conf (§B.7's target is
        # the conf the verb is pointed at). `ignorea` is declared by a
        # committed recipe (in use), `gsamaintv2ghost` is declared by
        # nothing (stale), `ignoreb` is wanted but missing.
        conf="$ws/pacman.conf"
        make_install_conf "$conf"
        printf 'IgnorePkg = ignorea gsamaintv2ghost\n' >>"$conf"

        run_engine "$ws" -Mi --config "$conf" --state-dir "$state"
        [ "$FIXTURE_RC" = 0 ] || fail "-Mi reports drift and exits 0 (§E.4), got $FIXTURE_RC: $FIXTURE_OUTPUT"
        has_row "$FIXTURE_OUTPUT" "ignorea in-use in-use declared-by ignorea" "declared entry is in use"
        has_row "$FIXTURE_OUTPUT" "gsamaintv2ghost stale stale archives-gone" "undeclared entry is stale"
        has_row "$FIXTURE_OUTPUT" "ignoreb missing declared-by ignoreb" "wanted name is missing"

        # --prune removes ONLY the stale name; the declared one survives —
        # the keep-in-use pruning guard (crates/gsa-maint/src/ignorepkg.rs).
        run_engine "$ws" -Mi --prune --config "$conf" --state-dir "$state"
        [ "$FIXTURE_RC" = 0 ] || fail "-Mi --prune is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        has_row "$FIXTURE_OUTPUT" "ignorea keep in-use declared-by ignorea" "keep in-use row"
        has_row "$FIXTURE_OUTPUT" "gsamaintv2ghost remove stale archives-gone" "remove stale row"
        grep -q '^IgnorePkg = .*ignorea' "$conf" ||
            fail "the declared name must survive the prune (pruning safety): $(cat "$conf")"
        if grep -q 'gsamaintv2ghost' "$conf"; then
            fail "the stale name must leave the closure: $(cat "$conf")"
        fi

        # --backfill adds exactly the missing wanted name.
        run_engine "$ws" -Mi --backfill --config "$conf" --state-dir "$state"
        [ "$FIXTURE_RC" = 0 ] || fail "-Mi --backfill is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        has_row "$FIXTURE_OUTPUT" "ignorea present in-closure" "already-covered name"
        has_row "$FIXTURE_OUTPUT" "ignoreb add appended" "backfilled name"
        grep -q '^IgnorePkg = .*ignoreb' "$conf" ||
            fail "the backfill must add the missing declared name: $(cat "$conf")"
        assert_varlib_unchanged
    )
fi

# ─── d. -Ml: log browse, tail and retention over <state>/logs ──────────────
if want d; then
    (
        set -euo pipefail
        ws="$fixture/d/ws"
        state="$fixture/d/state"
        make_workspace "$ws" 1 auto low
        add_package "$ws" loga "$gsa_meta_any" git
        add_package "$ws" logb "$gsa_meta_any" git
        logs="$state/logs"
        mkdir -p "$logs"

        # Fixture-set mtimes make "newest N" DERIVED and deterministic:
        # loga.log is newest, loga.log.3 oldest (rotated siblings share the
        # `loga` stem), logb.log a single-file stem.
        printf 'line one\nTAIL-MARKER-NEW\n' >"$logs/loga.log"
        printf 'rotated 1\n' >"$logs/loga.log.1"
        printf 'rotated 2\n' >"$logs/loga.log.2"
        printf 'rotated 3\n' >"$logs/loga.log.3"
        printf 'b log\n' >"$logs/logb.log"
        printf 'not a log\n' >"$logs/stray.txt"
        touch -d '2020-01-04 00:00' "$logs/loga.log"
        touch -d '2020-01-03 00:00' "$logs/loga.log.1"
        touch -d '2020-01-02 00:00' "$logs/loga.log.2"
        touch -d '2020-01-01 00:00' "$logs/loga.log.3"
        touch -d '2020-01-05 00:00' "$logs/logb.log"

        run_engine "$ws" -Ml --state-dir "$state"
        [ "$FIXTURE_RC" = 0 ] || fail "-Ml lists logs at rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        for f in loga.log loga.log.1 loga.log.2 loga.log.3 logb.log; do
            has_row "$FIXTURE_OUTPUT" "$logs/$f" "log listing names $f"
        done
        absent_row "$FIXTURE_OUTPUT" "stray.txt" "a non-log file is never listed"
        has_row "$FIXTURE_OUTPUT" "loga log " "stem row for the loga family"
        has_row "$FIXTURE_OUTPUT" "logb log " "stem row for logb"

        # --tail renders the tail of the stem's own log (the recipe id
        # resolves through the ordinary §C.1 layer).
        run_engine "$ws" -Ml --tail loga --state-dir "$state"
        [ "$FIXTURE_RC" = 0 ] || fail "-Ml --tail is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        has_row "$FIXTURE_OUTPUT" "loga log " "the tail pass names the log"
        has_row "$FIXTURE_OUTPUT" "TAIL-MARKER-NEW" "the tail carries the log's last lines"

        # --keep N: keep the N NEWEST per stem (mtime order above), prune
        # the rest loudly; a ≤N stem is untouched and says `keep`.
        run_engine "$ws" -Ml --keep 2 --state-dir "$state"
        [ "$FIXTURE_RC" = 0 ] || fail "-Ml --keep is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        for kept in loga.log loga.log.1 logb.log; do
            has_row "$FIXTURE_OUTPUT" "$logs/$kept keep log-retention keep=2" "kept log $kept"
            [ -f "$logs/$kept" ] || fail "the retention prune must keep $kept"
        done
        for pruned in loga.log.2 loga.log.3; do
            has_row "$FIXTURE_OUTPUT" "$logs/$pruned pruned log-retention keep=2" "pruned log $pruned"
            [ ! -f "$logs/$pruned" ] || fail "the retention prune must delete $pruned"
        done
        assert_varlib_unchanged
    )
fi

# ─── e. -Mm: mirrors dedupe and its confirmation model ─────────────────────
if want e; then
    (
        set -euo pipefail
        ws="$fixture/e/ws"
        state="$fixture/e/state"
        make_workspace "$ws" 1 auto low

        # Group 1 (one effective git URL): mfirst's local clone is MISSING
        # (it still ranks above a populated non-git dir, so it is the
        # canonical and the twin's link is dangling until a build fills it),
        # msecond is a populated non-Git directory (skip, never replaced),
        # mthird is missing and becomes the link.
        for id in mfirst msecond mthird; do
            add_package "$ws" "$id" 'pkgver=1.0.0
pkgrel=1
arch=(any)
source=("git+https://example.invalid/mirror.git")' git
        done
        mkdir -p "$ws/packages/msecond/mirror"
        printf 'payload\n' >"$ws/packages/msecond/mirror/keepme"

        # Group 2: two real git clones of one URL (git under the
        # GIT_CONFIG_COUNT=0 hardening; the first path wins canonical).
        for id in gfirst gsecond; do
            add_package "$ws" "$id" 'pkgver=1.0.0
pkgrel=1
arch=(any)
source=("git+https://example.invalid/clone.git")' git
            mkdir -p "$ws/packages/$id/clone"
            GIT_CONFIG_COUNT=0 git -C "$ws/packages/$id/clone" init -q 2>/dev/null
            GIT_CONFIG_COUNT=0 git -C "$ws/packages/$id/clone" remote add origin \
                git+https://example.invalid/clone.git
        done

        if [ "$(id -u)" = 0 ]; then
            # As root the verb refuses (docs/source-sharing.md) — the
            # refusal IS the assertion here.
            run_engine "$ws" -Mm --noconfirm --state-dir "$state"
            [ "$FIXTURE_RC" = 3 ] || fail "as root -Mm must refuse (rc 3), got $FIXTURE_RC: $FIXTURE_OUTPUT"
            printf '%s\n' "$FIXTURE_OUTPUT" | grep -F "must run as the build user" >/dev/null ||
                fail "the root refusal must say why: $FIXTURE_OUTPUT"
            echo "skip: -Mm apply model (fixture runs as root; the engine's refusal was asserted)"
        else
            # --dry-run: the plan renders, rc 0, nothing is touched.
            run_engine "$ws" -Mm --dry-run --state-dir "$state"
            [ "$FIXTURE_RC" = 0 ] || fail "-Mm --dry-run is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
            has_row "$FIXTURE_OUTPUT" "link planned -> ../mfirst/mirror" "planned dangling link"
            has_row "$FIXTURE_OUTPUT" "skip populated-non-git msecond" "populated non-git skip row"
            has_row "$FIXTURE_OUTPUT" "skip populated-non-git gsecond" "second clone is never replaced"
            has_row "$FIXTURE_OUTPUT" "canonical mirror git+https://example.invalid/mirror.git" "canonical row"
            [ ! -e "$ws/packages/mthird/mirror" ] || fail "--dry-run must not create the link"
            [ -f "$ws/packages/msecond/mirror/keepme" ] || fail "--dry-run must not touch the populated dir"

            # Without --noconfirm the plan prints and the run STOPS rc 3
            # (the engine never prompts, §K.3) — nothing applied.
            run_engine "$ws" -Mm --state-dir "$state"
            [ "$FIXTURE_RC" = 3 ] || fail "-Mm without --noconfirm must stop rc 3, got $FIXTURE_RC: $FIXTURE_OUTPUT"
            printf '%s\n' "$FIXTURE_OUTPUT" | grep -F "confirmation-required" >/dev/null ||
                fail "the stop must name confirmation-required: $FIXTURE_OUTPUT"
            has_row "$FIXTURE_OUTPUT" "link planned -> ../mfirst/mirror" "the plan is printed"
            [ ! -e "$ws/packages/mthird/mirror" ] || fail "the unconfirmed run must apply nothing"
            [ -f "$ws/packages/msecond/mirror/keepme" ] || fail "the unconfirmed run must apply nothing"

            # --noconfirm applies: the link lands (dangling at its missing
            # canonical), the populated non-git dir survives untouched.
            run_engine "$ws" -Mm --noconfirm --state-dir "$state"
            [ "$FIXTURE_RC" = 0 ] || fail "-Mm --noconfirm is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
            has_row "$FIXTURE_OUTPUT" "link applied -> ../mfirst/mirror" "applied link row"
            [ -L "$ws/packages/mthird/mirror" ] || fail "the twin must become a symlink"
            [ "$(readlink "$ws/packages/mthird/mirror")" = "../mfirst/mirror" ] ||
                fail "the link target is the relative canonical path, got $(readlink "$ws/packages/mthird/mirror")"
            [ ! -e "$ws/packages/mthird/mirror" ] || fail "the link must dangle until the canonical is built"
            [ -f "$ws/packages/msecond/mirror/keepme" ] ||
                fail "a populated non-git dir is never replaced (docs/source-sharing.md)"
            [ -d "$ws/packages/gsecond/clone" ] && [ ! -L "$ws/packages/gsecond/clone" ] ||
                fail "the second clone is skipped, never linked over"
        fi
        assert_varlib_unchanged
    )
fi

# ─── f. -Ms/-Mw: named sets and world over config/sets vs the kv store ─────
if want f; then
    (
        set -euo pipefail
        ws="$fixture/f/ws"
        state="$fixture/f/state"
        make_workspace "$ws" 1 auto low
        add_package "$ws" seta "$gsa_meta_any" git
        add_package "$ws" setb "$gsa_meta_any" git
        add_package "$ws" setc "$gsa_meta_any" git

        # The committed source (read-only for every -M verb).
        mkdir -p "$ws/config/sets"
        printf '# fixture team\nseta\nsetb\n' >"$ws/config/sets/toolchain"
        config_sha() { sha256sum "$ws/config/sets/toolchain" | awk '{print $1}'; }
        config_before=$(config_sha)

        # Drift is REPORTED, never auto-fixed (§B.7).
        run_engine "$ws" -Ms --state-dir "$state"
        [ "$FIXTURE_RC" = 0 ] || fail "-Ms lists sets at rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        has_row "$FIXTURE_OUTPUT" "toolchain user 0 member(s)" "empty kv side"
        has_row "$FIXTURE_OUTPUT" "toolchain drift only-in-config seta" "config-only member"
        has_row "$FIXTURE_OUTPUT" "toolchain drift only-in-config setb" "config-only member"
        has_row "$FIXTURE_OUTPUT" "stale computed " "computed sets are listed"
        [ "$(config_sha)" = "$config_before" ] || fail "a listing must never rewrite config/sets"

        # --add/--remove edit the kv side ONLY; the rows name the edit.
        run_engine "$ws" -Ms --add toolchain setc --state-dir "$state"
        [ "$FIXTURE_RC" = 0 ] || fail "-Ms --add is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        has_row "$FIXTURE_OUTPUT" "toolchain added setc" "add row names the edit"
        run_engine "$ws" -Ms toolchain --state-dir "$state"
        [ "$FIXTURE_RC" = 0 ] || fail "-Ms <name> is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        has_row "$FIXTURE_OUTPUT" "toolchain user 1 member(s)" "kv-side member count"
        has_row "$FIXTURE_OUTPUT" "toolchain member setc" "kv-side member row"
        has_row "$FIXTURE_OUTPUT" "toolchain drift only-in-state setc" "state-only member"
        [ "$(config_sha)" = "$config_before" ] || fail "an edit must never rewrite config/sets"
        run_engine "$ws" -Ms --remove toolchain setc --state-dir "$state"
        [ "$FIXTURE_RC" = 0 ] || fail "-Ms --remove is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        has_row "$FIXTURE_OUTPUT" "toolchain removed setc" "remove row names the edit"

        # A computed set is listed but never editable (§B.7).
        run_engine "$ws" -Ms @stale --state-dir "$state"
        [ "$FIXTURE_RC" = 0 ] || fail "listing @stale is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        has_row "$FIXTURE_OUTPUT" "stale computed " "computed listing"
        run_engine "$ws" -Ms --add @stale seta --state-dir "$state"
        # An edit aimed at a computed set is a USAGE error (§G.1 — the
        # adapter gates the name before any kv work).
        [ "$FIXTURE_RC" = 2 ] ||
            fail "a computed-set edit is usage (rc 2), got $FIXTURE_RC: $FIXTURE_OUTPUT"
        printf '%s\n' "$FIXTURE_OUTPUT" | grep -F "computed set" >/dev/null ||
            fail "the refusal must name the computed set: $FIXTURE_OUTPUT"
        [ "$(config_sha)" = "$config_before" ] || fail "a refused edit must never rewrite config/sets"

        # The --add/--remove alternative fence is usage (rc 2).
        run_engine "$ws" -Ms --add --remove seta --state-dir "$state"
        [ "$FIXTURE_RC" = 2 ] || fail "--add with --remove is a usage error (rc 2), got $FIXTURE_RC: $FIXTURE_OUTPUT"

        # World: the explicitly wanted set lives in the kv store only.
        run_engine "$ws" -Mw --add seta --state-dir "$state"
        [ "$FIXTURE_RC" = 0 ] || fail "-Mw --add is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        has_row "$FIXTURE_OUTPUT" "world added seta" "world add row names the edit"
        run_engine "$ws" -Mw --state-dir "$state"
        [ "$FIXTURE_RC" = 0 ] || fail "-Mw lists at rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        has_row "$FIXTURE_OUTPUT" "world user 1 member(s)" "world member count"
        has_row "$FIXTURE_OUTPUT" "world member seta" "world member row"
        has_row "$FIXTURE_OUTPUT" "world drift only-in-state seta" "world drift row"
        run_engine "$ws" -Mw --remove seta --state-dir "$state"
        [ "$FIXTURE_RC" = 0 ] || fail "-Mw --remove is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        has_row "$FIXTURE_OUTPUT" "world removed seta" "world remove row names the edit"
        [ "$(config_sha)" = "$config_before" ] ||
            fail "config/sets must stay byte-identical across the whole -Ms/-Mw pass"
        assert_varlib_unchanged
    )
fi

# ─── g. -Mh: run history listing, byte-identical --show, retention prune ───
if want g; then
    (
        set -euo pipefail
        ws="$fixture/g/ws"
        state="$fixture/g/state"
        make_workspace "$ws" 1 auto low
        maint_ws "$ws"
        add_package "$ws" histone "$gsa_meta_any" git
        add_package "$ws" histtwo "$gsa_meta_any" git

        # Two real recorded runs (stub -B builds), their emitted blocks.
        run_engine "$ws" -B --no-prefetch --leaf --state-dir "$state" histone
        [ "$FIXTURE_RC" = 0 ] || fail "history run 1 is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        printf '%s\n' "$FIXTURE_OUTPUT" |
            sed -n '/^--- run record begin ---$/,/^--- run record end ---$/p' >"$fixture/g/emitted1"
        [ -s "$fixture/g/emitted1" ] || fail "run 1 emitted no machine block: $FIXTURE_OUTPUT"
        run_engine "$ws" -B --no-prefetch --leaf --state-dir "$state" histtwo
        [ "$FIXTURE_RC" = 0 ] || fail "history run 2 is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        printf '%s\n' "$FIXTURE_OUTPUT" |
            sed -n '/^--- run record begin ---$/,/^--- run record end ---$/p' >"$fixture/g/emitted2"
        [ -s "$fixture/g/emitted2" ] || fail "run 2 emitted no machine block: $FIXTURE_OUTPUT"

        # The listing shows both runs with their continuations (rc 0,
        # empty remaining, the restated gsa command).
        run_engine "$ws" -Mh --state-dir "$state"
        [ "$FIXTURE_RC" = 0 ] || fail "-Mh lists at rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        rows=$(printf '%s\n' "$FIXTURE_OUTPUT")
        [ "$(printf '%s\n' "$rows" | wc -l)" = 2 ] || fail "-Mh must list 2 recorded runs: $rows"
        printf '%s\n' "$rows" | awk '$1 == "1" && $3 == "0" && $4 == "0"' | grep -F "gsa" >/dev/null ||
            fail "run 1's list row carries its rc/remaining/command: $rows"
        printf '%s\n' "$rows" | awk '$1 == "2" && $3 == "0" && $4 == "0"' | grep -F "gsa" >/dev/null ||
            fail "run 2's list row carries its rc/remaining/command: $rows"

        # --show re-renders one stored record BYTE-IDENTICAL to the block
        # its run emitted (§H.1: persistence is storage of the structure).
        run_engine "$ws" -Mh --show 1 --state-dir "$state"
        [ "$FIXTURE_RC" = 0 ] || fail "-Mh --show is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        printf '%s\n' "$FIXTURE_OUTPUT" >"$fixture/g/show1"
        diff -u "$fixture/g/emitted1" "$fixture/g/show1" >/dev/null ||
            fail "--show 1 is not byte-identical to run 1's emitted block:
$(diff -u "$fixture/g/emitted1" "$fixture/g/show1" || true)"
        run_engine "$ws" -Mh --show 2 --state-dir "$state"
        [ "$FIXTURE_RC" = 0 ] || fail "-Mh --show 2 is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        printf '%s\n' "$FIXTURE_OUTPUT" >"$fixture/g/show2"
        diff -u "$fixture/g/emitted2" "$fixture/g/show2" >/dev/null ||
            fail "--show 2 is not byte-identical to run 2's emitted block:
$(diff -u "$fixture/g/emitted2" "$fixture/g/show2" || true)"

        # ── state override (§J.3): flag beats env; env alone relocates ──
        export GSA_STATE_DIR="$fixture/g/env-state"
        run_engine "$ws" -Mh --state-dir "$state"
        [ "$FIXTURE_RC" = 0 ] || fail "the flag-override read is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        [ ! -e "$fixture/g/env-state" ] ||
            fail "--state-dir must beat GSA_STATE_DIR (§J.3): the env root was created"
        run_engine "$ws" -Mh
        [ "$FIXTURE_RC" = 0 ] || fail "the env-override read is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        [ -d "$fixture/g/env-state/runs" ] ||
            fail "GSA_STATE_DIR must relocate the state root (§J.3)"
        unset GSA_STATE_DIR
        assert_varlib_unchanged

        # ── retention (--prune) over a seeded history ────────────────────
        # Seed from the engine's own wire line so the store shape can never
        # drift from the fixture's writer: run 1's record is finished
        # (remaining []), copied + rewritten as the finished bulk and as the
        # UNFINISHED records (remaining non-empty) that retention must keep
        # as resume pointers.
        hist="$state/runs/history.jsonl"
        base=$(head -n 1 "$hist")
        case $base in
        *'"remaining":[]'*) ;;
        *) fail "the seeding record must carry an empty remaining list: $base" ;;
        esac
        unfinished_line=$(printf '%s\n' "$base" |
            sed 's/"remaining":\[\]/"remaining":["histone"]/')
        [ "$unfinished_line" != "$base" ] ||
            fail "the unfinished seed did not take (wire shape drift?): $base"
        seed_finished=55
        seed_unfinished=2
        for _ in $(seq 1 "$seed_finished"); do
            printf '%s\n' "$base" >>"$hist"
        done
        for _ in $(seq 1 "$seed_unfinished"); do
            printf '%s\n' "$unfinished_line" >>"$hist"
        done

        # Derived retention math (history.rs: newest RUN_HISTORY_KEEP=50
        # finished records + every unfinished one survive).
        finished=$((2 + seed_finished))
        keep_budget=50
        pruned=$((finished - keep_budget))
        kept=$((keep_budget + seed_unfinished))
        total=$((finished + seed_unfinished))

        run_engine "$ws" -Mh --prune --state-dir "$state"
        [ "$FIXTURE_RC" = 0 ] || fail "-Mh --prune is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        for id in $(seq 1 "$pruned"); do
            has_row "$FIXTURE_OUTPUT" "$id pruned retention keep=50 remaining-0" "pruned record $id"
        done
        for id in $(seq $((pruned + 1)) "$finished"); do
            has_row "$FIXTURE_OUTPUT" "$id keep retention newest" "kept record $id"
        done
        for id in $(seq $((finished + 1)) "$total"); do
            has_row "$FIXTURE_OUTPUT" "$id keep resume-pointer remaining-unfinished" "unfinished record $id"
        done
        lines=$(wc -l <"$hist")
        [ "$lines" = "$kept" ] ||
            fail "the compaction must rewrite history.jsonl to $kept records, got $lines"
        run_engine "$ws" -Mh --state-dir "$state"
        [ "$FIXTURE_RC" = 0 ] || fail "-Mh after prune is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        [ "$(printf '%s\n' "$FIXTURE_OUTPUT" | wc -l)" = "$kept" ] ||
            fail "the listing must show the $kept surviving records: $FIXTURE_OUTPUT"
    )
fi

# ─── h. prune strengths + pruning safety + run-in-flight + pins + rc ───────
if want h; then
    (
        set -euo pipefail
        ws="$fixture/h/ws"
        state="$fixture/h/state"
        make_workspace "$ws" 1 auto low
        maint_ws "$ws"
        add_package "$ws" pralpha 'pkgver=1.0.0
pkgrel=1
arch=(any)
source=("git+https://example.invalid/hsrc.git")' git
        add_package "$ws" prbeta 'pkgver=1.0.0
pkgrel=1
arch=(any)
source=("https://example.invalid/bsrc.tar.gz")' git
        add_package "$ws" prgamma 'pkgver=1.0.0
pkgrel=1
arch=(any)
source=("git+https://example.invalid/gsrc.git")' git
        # Strength-3's download-extension set (the root .gitignore's
        # `*.<ext>` patterns, prune.rs download_patterns).
        printf '*.tar.gz\n' >"$ws/.gitignore"

        # One real build run: archives beside the recipes, index rows, and
        # the format: 2 record whose continuation the pin asserts.
        run_engine "$ws" -B --no-prefetch --state-dir "$state" pralpha prbeta prgamma
        [ "$FIXTURE_RC" = 0 ] || fail "the seeding build is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        rr2_body <<<"$FIXTURE_OUTPUT" >/dev/null ||
            fail "the build run must emit a strict format: 2 block: $FIXTURE_OUTPUT"

        # Continuation hygiene (§H.2/§L.1): every -M spelling and sub-flag
        # is not-mirrored, and the command never replays an -M token.
        nm=$(rr2_continuation not-mirrored <<<"$FIXTURE_OUTPUT")
        for token in -Ma -Mc -Mcc -Mccc -Md -Mi -Ml -Mm -Ms -Mw -Mh \
            --fix --prune --backfill --tail --keep --show --add --remove --noconfirm; do
            case " $nm " in
            *" $token "*) ;;
            *) fail "continuation not-mirrored must list $token (§L.1), got: $nm" ;;
            esac
        done
        cmd=$(rr2_continuation command <<<"$FIXTURE_OUTPUT")
        for token in $cmd; do
            case $token in
            -M*) fail "the continuation command must never carry an -M token (§H.2): $cmd" ;;
            esac
        done

        # The stored record the pruning guard consults: the newest run
        # record's `remaining:` names pralpha, so pralpha's files earn
        # `keep referenced-by-run` and survive EVERY strength (protect.rs).
        hist="$state/runs/history.jsonl"
        base=$(head -n 1 "$hist")
        case $base in
        *'"remaining":[]'*) ;;
        *) fail "the seeding record must carry an empty remaining list: $base" ;;
        esac
        protected_line=$(printf '%s\n' "$base" |
            sed 's/"remaining":\[\]/"remaining":["pralpha"]/')
        [ "$protected_line" != "$base" ] ||
            fail "the protected seed did not take (wire shape drift?): $base"
        printf '%s\n' "$protected_line" >>"$hist"

        # Synthetic makepkg state beside the recipes (§J.2).
        for id in pralpha prbeta prgamma; do
            for tree in src pkg build; do
                mkdir -p "$ws/packages/$id/$tree"
                printf 'tree\n' >"$ws/packages/$id/$tree/file"
            done
        done
        mkdir -p "$ws/packages/pralpha/hsrc" # VCS source clone (pulled)
        printf 'clone\n' >"$ws/packages/pralpha/hsrc/README"
        printf 'download\n' >"$ws/packages/prbeta/bsrc.tar.gz" # URL download
        printf 'sig\n' >"$ws/packages/prbeta/bsrc.tar.gz.sig" # its companion
        mkdir -p "$ws/packages/prgamma/gsrc"
        printf 'clone\n' >"$ws/packages/prgamma/gsrc/README"
        printf 'vcs\n' >"$ws/packages/prgamma/prgamma-1.0.0-1-any.pkg.tar.zst.gsa-vcs-revisions"
        # A symlinked archive whose target lives OUTSIDE the workspace: it
        # must survive, and following it must never delete the target.
        outside="$fixture/h/outside.txt"
        printf 'outside\n' >"$outside"
        ln -s "$outside" "$ws/packages/prbeta/prbeta-link-1.0.0-1-any.pkg.tar.zst"

        # ── run-in-flight gate (§K.3): a mutating verb refuses rc 3 ──────
        mkdir -p "$state/locks"
        : >"$state/locks/run.lock"
        ready="$fixture/h/lock.ready"
        # flock(1) in fd mode: the subshell holds the flock through fd 9 and
        # execs `sleep`, so the background pid IS the lock holder and
        # killing it releases the lock (a forked `flock … sleep` child would
        # outlive its killer and keep the lock fd).
        (
            exec 9>>"$state/locks/run.lock"
            flock -x 9
            : >"$ready"
            exec sleep 30
        ) &
        holder=$!
        for _ in $(seq 1 100); do
            [ -f "$ready" ] && break
            sleep 0.05
        done
        [ -f "$ready" ] || fail "the flock holder never took the run lock"
        run_engine "$ws" -Mc --state-dir "$state" prbeta
        [ "$FIXTURE_RC" = 3 ] || fail "a mutating verb under a held run lock is rc 3 (§K.3), got $FIXTURE_RC: $FIXTURE_OUTPUT"
        printf '%s\n' "$FIXTURE_OUTPUT" | grep -F "run-in-flight" >/dev/null ||
            fail "the refusal must name run-in-flight: $FIXTURE_OUTPUT"
        [ -f "$ws/packages/prbeta/prbeta-1.0.0-1-any.pkg.tar.zst" ] ||
            fail "a refused prune must delete nothing"
        [ -f "$ws/packages/prbeta/src/file" ] ||
            fail "a refused prune must delete no trees"
        kill "$holder" 2>/dev/null || true
        wait "$holder" 2>/dev/null || true

        # ── rc classes by exact code (§G.1) ──────────────────────────────
        run_engine "$ws" -M --state-dir "$state"
        [ "$FIXTURE_RC" = 2 ] || fail "bare -M is a usage error (rc 2), got $FIXTURE_RC: $FIXTURE_OUTPUT"
        run_engine "$ws" -Mc --state-dir "$state"
        [ "$FIXTURE_RC" = 2 ] || fail "-Mc without a selection is a usage error (rc 2), got $FIXTURE_RC: $FIXTURE_OUTPUT"

        # ── strength 1 (-Mc): the selection's trees + archives only ──────
        run_engine "$ws" -Mc --state-dir "$state" pralpha prbeta
        [ "$FIXTURE_RC" = 0 ] || fail "-Mc is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        # The referenced recipe keeps everything, its archive named.
        has_row "$FIXTURE_OUTPUT" "$ws/packages/pralpha/pralpha-1.0.0-1-any.pkg.tar.zst keep referenced-by-run" "referenced archive kept"
        for tree in src pkg build; do
            has_row "$FIXTURE_OUTPUT" "$ws/packages/pralpha/$tree keep referenced-by-run" "referenced tree $tree kept"
            [ -d "$ws/packages/pralpha/$tree" ] || fail "referenced pralpha/$tree must survive strength 1"
        done
        [ -f "$ws/packages/pralpha/pralpha-1.0.0-1-any.pkg.tar.zst" ] ||
            fail "the run-referenced archive must survive strength 1"
        # The unreferenced selection member is pruned, its symlink kept.
        for tree in src pkg build; do
            has_row "$FIXTURE_OUTPUT" "$ws/packages/prbeta/$tree pruned staging" "pruned tree $tree"
            [ ! -e "$ws/packages/prbeta/$tree" ] || fail "prbeta/$tree must be pruned"
        done
        has_row "$FIXTURE_OUTPUT" "$ws/packages/prbeta/prbeta-1.0.0-1-any.pkg.tar.zst pruned archive" "pruned archive"
        [ ! -f "$ws/packages/prbeta/prbeta-1.0.0-1-any.pkg.tar.zst" ] ||
            fail "the unreferenced archive must be pruned"
        has_row "$FIXTURE_OUTPUT" "$ws/packages/prbeta/prbeta-link-1.0.0-1-any.pkg.tar.zst keep symlink" "symlink preserved"
        [ -L "$ws/packages/prbeta/prbeta-link-1.0.0-1-any.pkg.tar.zst" ] ||
            fail "the symlinked archive must never be deleted"
        [ -f "$outside" ] || fail "pruning must never follow a symlink (outside target deleted)"
        # Strength 1 prunes ONLY the selection.
        absent_row "$FIXTURE_OUTPUT" "prgamma" "strength 1 must not touch an unselected recipe"
        [ -f "$ws/packages/prgamma/prgamma-1.0.0-1-any.pkg.tar.zst" ] ||
            fail "an unselected recipe's archive must survive strength 1"

        # ── strength 2 (-Mcc): every archive in the workspace ────────────
        run_engine "$ws" -Mcc --state-dir "$state"
        [ "$FIXTURE_RC" = 0 ] || fail "-Mcc is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        has_row "$FIXTURE_OUTPUT" "$ws/packages/pralpha/pralpha-1.0.0-1-any.pkg.tar.zst keep referenced-by-run" "referenced archive kept at strength 2"
        [ -f "$ws/packages/pralpha/pralpha-1.0.0-1-any.pkg.tar.zst" ] ||
            fail "the run-referenced archive must survive strength 2"
        has_row "$FIXTURE_OUTPUT" "$ws/packages/prgamma/prgamma-1.0.0-1-any.pkg.tar.zst pruned archive" "workspace-wide archive sweep"
        [ ! -f "$ws/packages/prgamma/prgamma-1.0.0-1-any.pkg.tar.zst" ] ||
            fail "strength 2 sweeps every unreferenced archive"
        has_row "$FIXTURE_OUTPUT" "$ws/packages/prgamma/prgamma-1.0.0-1-any.pkg.tar.zst.gsa-vcs-revisions pruned vcs-sidecar" "vcs sidecar sweep"
        has_row "$FIXTURE_OUTPUT" "$ws/packages/prbeta/prbeta-link-1.0.0-1-any.pkg.tar.zst keep symlink" "symlink preserved at strength 2"
        [ -L "$ws/packages/prbeta/prbeta-link-1.0.0-1-any.pkg.tar.zst" ] ||
            fail "the symlinked archive must survive strength 2"
        [ -f "$outside" ] || fail "strength 2 must never follow the symlink"

        # ── strength 3 (-Mccc): confirmation model + pulled sources ──────
        run_engine "$ws" -Mccc --state-dir "$state"
        [ "$FIXTURE_RC" = 3 ] || fail "-Mccc without --noconfirm stops rc 3, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        printf '%s\n' "$FIXTURE_OUTPUT" | grep -F "confirmation-required" >/dev/null ||
            fail "the stop must name confirmation-required: $FIXTURE_OUTPUT"
        has_row "$FIXTURE_OUTPUT" "$ws/packages/prbeta/bsrc.tar.gz prune source-download" "the plan lists the pulled download"
        has_row "$FIXTURE_OUTPUT" "$ws/packages/prgamma/gsrc prune source-clone" "the plan lists the source clone"
        # Nothing is deleted by the unconfirmed run.
        [ -f "$ws/packages/prbeta/bsrc.tar.gz" ] && [ -f "$ws/packages/prbeta/bsrc.tar.gz.sig" ] ||
            fail "the unconfirmed strength-3 run must delete no sources"
        [ -d "$ws/packages/prgamma/gsrc" ] || fail "the unconfirmed strength-3 run must delete no clones"
        [ -d "$ws/packages/prgamma/src" ] || fail "the unconfirmed strength-3 run must delete no trees"

        run_engine "$ws" -Mccc --noconfirm --state-dir "$state"
        [ "$FIXTURE_RC" = 0 ] || fail "-Mccc --noconfirm is rc 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
        has_row "$FIXTURE_OUTPUT" "$ws/packages/prbeta/bsrc.tar.gz pruned source-download" "download pruned"
        has_row "$FIXTURE_OUTPUT" "$ws/packages/prbeta/bsrc.tar.gz.sig pruned source-companion" "companion pruned"
        [ ! -e "$ws/packages/prbeta/bsrc.tar.gz" ] && [ ! -e "$ws/packages/prbeta/bsrc.tar.gz.sig" ] ||
            fail "strength 3 must remove the pulled download and its companion"
        for tree in src pkg build; do
            [ ! -e "$ws/packages/prgamma/$tree" ] || fail "strength 3 must remove prgamma/$tree"
        done
        # The pulled source clone is a directory target: strength 3 removes
        # it recursively and the row agrees with the filesystem.
        clone_row=$(printf '%s\n' "$FIXTURE_OUTPUT" | grep -F "$ws/packages/prgamma/gsrc " || true)
        case $clone_row in
        *" pruned source-clone"*)
            [ ! -e "$ws/packages/prgamma/gsrc" ] ||
                fail "a pruned source clone must be gone: $clone_row"
            ;;
        *)
            fail "strength 3 must prune the source clone with a coherent row: '$clone_row'"
            ;;
        esac
        # The referenced recipe keeps everything — including its pulled
        # sources — and the symlink/outside target still survive.
        has_row "$FIXTURE_OUTPUT" "$ws/packages/pralpha/pralpha-1.0.0-1-any.pkg.tar.zst keep referenced-by-run" "referenced archive kept at strength 3"
        has_row "$FIXTURE_OUTPUT" "$ws/packages/pralpha/hsrc keep referenced-by-run" "referenced clone kept at strength 3"
        [ -f "$ws/packages/pralpha/pralpha-1.0.0-1-any.pkg.tar.zst" ] &&
            [ -d "$ws/packages/pralpha/hsrc" ] ||
            fail "a run-referenced recipe keeps its files at every strength (protect.rs)"
        [ -L "$ws/packages/prbeta/prbeta-link-1.0.0-1-any.pkg.tar.zst" ] ||
            fail "the symlinked archive must survive every strength"
        [ -f "$outside" ] || fail "strength 3 must never follow the symlink"
        assert_varlib_unchanged
    )
fi

# ─── the fixture never touched the real state root (§J.3) ──────────────────
assert_varlib_unchanged
