#!/usr/bin/env bash
set -euo pipefail

# AUTO-REGISTER IgnorePkg — the dynamic registration behind docs/MEMORY.md
# rule 9's write half (the read half is the report-only closure lint,
# tests/recipe-contract.sh). The seam computes the workspace pkgname universe
# (pkgbase+pkgname of every committed .SRCINFO) and appends the names the
# target pacman.conf does not cover as cumulative `IgnorePkg =` lines
# (~10 names/line) INSIDE [options].
#
# Flip notes (docs/gsa-fixture-migration.md row `tests/ignorepkg-register.sh`;
# argv map §B.9/§D.1/§B.8, rc remaps §G.1, prose retirement §L.3):
# `--register-ignorepkg <conf>` -> `gsa -Mi --backfill --config <conf>` (§B.7;
# the registration target is named explicitly by `--config`, gap G6 — the
# fish `_IGNOREPKG_CONF` seam retires), `fish … --install p1` -> `gsa -S
# --leaf … p1` (§B.4; `--no-deps`->`--leaf`, `--install` is -S's own
# semantics), `-fi`->`-Sf` (§B.4), and the write-path-in-isolation cases ride
# the hidden `gsa --install-register <conf> <subject> <names…>` seam (§D.1).
# The unmirrorable fish-era `--allow-broken-rustc`/`--no-sync` drop (see
# tests/resume-command.sh's DEVIATION). The conf-mutation semantics (byte-exact
# placement/chunking, dated pre-image, idempotence,
# second-write-kept-pre-image, [options]-only closure, repo-section warning)
# are KEEP and pin byte-exact against the engine's shared walker
# (crates/gsa-install/src/register.rs) — it is the same splice. Prose
# byte-pins re-pin to the engine's own seam wording or to row/file state
# (§L.3): the registration lines are
# `register-ignorepkg: backup <conf>.bak-<date> (pre-image)` /
# `already present (kept as the day's pre-image)` / `<subject>, appended N
# name(s) as M IgnorePkg line(s)` with the subject `N name(s) from M
# archive(s)`, the rows of `gsa -Mi` are §E.2-framed
# (`<name> present in-closure|add appended|missing …`), and `--install-decide`
# rows go through rr2_decisions (the R-5 tab codec has no v2 form). rc
# remaps: the seam refusal of case d moves 1 -> 3 (§G.1 "refusals→3"); the
# hidden-seam usage errors stay rc 2 (§D.1).
#
# DEVIATION 1 (N8a/N8c stay FISH-DRIVEN — inventory row run-shapes cell :877
# `--skip` / :927 `-s -fi`): the engine's `--skip`/`--skip-built` are
# parse-and-refuse rc 2 (deferred to a later phase; `gsa --help` "Deferred
# (parse and refuse)"), so a freshness CLAIM cannot be driven through it. The
# kept behaviour (acceptance-time registration for a skip CLAIM, and the
# claim + forced transaction of `-s -fi`) keeps its fish-era shape against
# the FROZEN fish oracle (docs/gsa-fixture-migration.md §3 staging rules: no
# engine in the workspace since the cutover; run_fish_gen installs it).
# DEVIATION 2 (N6 stays FISH-DRIVEN — inventory pins cell "acceptance-time
# registration for builds/skip claims"): the engine registers ACCEPTED
# archives only in the install step (`install_built_package`,
# crates/gsa-install/src/lib.rs — install AND skip rows), and a build-only
# run registers nothing (its `register` hook is the binpkg index, and `-B`
# even rejects `--config` as deferred). The 2026-10-06 pipewire leak shape
# (build-only acceptance registers before any foreign transaction) has no
# engine surface yet, so the site keeps its fish-era pin.
# DEVIATION 3 (N4 stays FISH-DRIVEN — inventory pins cell "bounded db.lck
# wait"): the engine's bounded wait is a HARDCODED 300 s
# (crates/gsa-install/src/register.rs `wait_for_db_lock`) with no knob, so a
# timeout-refusal probe would add five minutes to the battery. The fast
# timeout (`_PACMAN_LOCK_WAIT_S=1`) keeps its fish-era pin; the engine-side
# wait itself is pinned by N3 (live holder -> wait note -> names land).
# DEVIATION 4 (cases h/i stay FISH-DRIVEN — inventory KEEP cell conf-mutation
# semantics :503-671): the loud named findings for a recipe dir with no
# committed .SRCINFO and for a stale .SRCINFO have no engine counterpart —
# `RecipeDb::load` (crates/gsa-recipe/src/lib.rs) FALLS BACK to a PKGBUILD
# scan when .SRCINFO is missing and nothing checks .SRCINFO freshness at
# registration time, so the engine would silently register scan-derived
# names where fish refused. The write-blocked-on-unverifiable-universe
# behaviour keeps its fish-era pin (reported as a contract gap).
# DEVIATION 5 (case d, rc + probe shape): the refusal is rc 3 now (§G.1), and
# the engine escalates by running the WRITE itself through `sudo -n cp`
# (register.rs `backup_and_write`) rather than probing `sudo -n true` first;
# the old probe-regex pin retires and the kept behaviour re-pins as: a
# non-writable target with a dead credential refuses with NOTHING changed and
# touches sudo only non-interactively. The engine escalates on an unwritable
# conf DIRECTORY (its writability test is on the parent), so the scenario
# chmods the directory, not the file.
# DEVIATION 6 (case e second pin): an empty conf path is a read REFUSAL on
# the engine (rc 1, §E.5 seam vocabulary — `cannot read`), not the fish
# usage error rc 2; the kept behaviour (a bad conf argument is loud and
# mutates nothing) re-pins with the engine's class.
# DEVIATION 7 (N3 clearance prose): the engine reports the bounded WAIT
# (`waiting for the pacman database lock to clear … never deleting it`) but
# never prints fish's `cleared after N s`; the wait-then-land behaviour
# re-pins as the wait note + registration landing + U-time coverage. The
# engine's wait engages only for a LIVE holder (`lock_has_live_holder` scans
# /proc fds), so the fixture holds the lock open itself — the fish-era
# file-only GSA_FAKE_DB_SEED seeding would be treated as a stale lock and
# proceed (a behaviour tests/gsa-install-v2.sh pins).
# DEVIATION 8 (N5 workspace shape — engine gap, not a pin change): the
# engine's binpkg retention keeps N=1 instance for a leaf recipe
# (crates/gsa-state/src/index.rs `Retention::from_graph`) and prunes older
# instances BY PATH, so a same-version rebuild (identical archive filename)
# has its own archive deleted before the install step and the run refuses
# `install-refused empty-list` (measured on the snapshot engine). N5's p1 is
# therefore a `core` member (hub budget N=2) so its two consecutive
# same-version runs both survive; the path-collision itself is reported as a
# gap (a just-registered instance's archive must never be the prune target).
#
# Contract pinned here (fixture paths are user-writable — NO sudo, ever,
# except case d's deliberate dead-credential escalation):
#   a. appended lines land inside [options] only (after the last existing
#      IgnorePkg line there, before the next section header), exactly the
#      missing names, ~10 names per line — pinned byte-exact, so ANY
#      placement/idempotence/chunking drift fails this case;
#   b. second run adds nothing: the -Mi rows are all `present in-closure`,
#      the file stays byte-identical (idempotence);
#   c. an IgnorePkg line inside a repo section is dropped by pacman — its
#      names are NOT counted as covered (they get appended) and a warning
#      naming the repo section appears, exactly once;
#   d. non-writable target + failing sudo = refusal, file unchanged
#      byte-for-byte, no backup (DEVIATION 5/6 for its rc and probe shape);
#   e. bad usage = rc 2 on the hidden seam (§D.1 vocabulary);
#   f. after the backfill the closure report carries NO `missing` row — the
#      post-check verification is the empty missing set (record-derived);
#   g. the dated pre-image backup (.bak-YYYYMMDD) is created exactly once and
#      keeps the original content across the idempotent second run;
#   h. a recipe dir with NO .SRCINFO is a loud NAMED finding that blocks the
#      write (refusal, file unchanged) — never a silent skip (DEVIATION 4);
#   i. (extra) a stale .SRCINFO (literal pkgver drift, the bettbox class) is
#      named and blocks the same way (DEVIATION 4);
#   j. a second same-day WRITE (a new recipe grows the universe) proceeds
#      instead of refusing on the existing dated backup, and that backup is
#      KEPT as the day's original pre-image.
#
# Install-pipeline sections (N1–N5), each in its own `( subshell )`: the
# registration step of the ONE install pipeline — the offline backfill above
# is only the same core seen from the maintain side:
#   N1 register-before-install ordering — the pacman stub ORACLES the conf at
#      `pacman -U` transaction time (the only place that can observe the
#      ordering) and records `U-time: covered p1`;
#   N2 --no-register-ignorepkg — conf byte-identical, the warn line lands,
#      the install itself still runs (registration skip ≠ install skip) and
#      the oracle records `U-time: NOT covered: p1`;
#   N3 a LIVE-held db.lck (open fd — see DEVIATION 7) is waited on, then the
#      registration lands and `pacman -U` runs;
#   N4 db.lck never cleared + a 1 s bound — the run FAILS, the refusal names
#      the timeout, NO pacman -U, conf unchanged (FISH-DRIVEN, DEVIATION 3);
#   N5 idempotent second install run — nothing re-appended, conf
#      byte-identical, exactly one dated backup.
#
# Acceptance-time sections (N6–N8), each in its own `( subshell )` — the
# registration that runs when a build (or an -s/--skip-built claim) is
# ACCEPTED. The real failure mode they reproduce (2026-10-06 pipewire set): a
# build-only run leaves its archives in the workspace and a later FOREIGN
# transaction installs them while the conf does not cover their names:
#   N6 the leak itself — a split, EPOCH'd build-only run must have every
#      archive name covered BEFORE any transaction exists (FISH-DRIVEN,
#      DEVIATION 2), one output's .PKGINFO carrying an extra pkgname the
#      recipe metadata does not know (rung 1 authority);
#   N7 split outputs through the install pipeline — ONE transaction covering
#      pkgbase + every output at U-time (names from the archives' own
#      .PKGINFO, rung 1);
#   N8a an -s freshness CLAIM with nothing to install — the claimed set's
#      names land in the conf even though this run never installs
#      (FISH-DRIVEN, DEVIATION 1);
#   N8b same-version skip rows — the `--install-decide` seam frames them as
#      §E.2 `skip already-current <version>` rows (the R-5 re-pin), the run
#      records the same plan, registration lands, and the skip rows run NO
#      transaction;
#   N8c -s + -fi — the claim plus FORCE rows: the forced transaction runs and
#      finds every name covered (FISH-DRIVEN, DEVIATION 1).
#
# rc vocabulary under test: 0 = success (closure complete afterwards), 2 =
# bad usage (hidden seams, §D.1), 3 = refusal that changed nothing (§G.1),
# 1 = the §E.5 seam refusal (case e's unreadable conf only).

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/tests/lib/fixture-lib.bash"
source "$root/tests/lib/rr-v2.bash"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-ignorepkg-register.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'ignorepkg-register fixture: %s\n' "$1" >&2
    exit 1
}

# ─── The engine under test: built into the fixture tree (scratch only).
# GSA_TEST_GSA_BIN, when already set to an executable, is that engine (the
# rr-v2.bash run_engine convention) and the scratch build is skipped. ──────
if [ -z "${GSA_TEST_GSA_BIN:-}" ]; then
    cargo build --offline --quiet --target-dir "$tmp/cargo" -p gsa-cli \
        --manifest-path "$gsa_repo_root/Cargo.toml" ||
        fail "cannot build the gsa binary for the fixture"
    GSA_TEST_GSA_BIN="$tmp/cargo/debug/gsa"
fi
[ -x "$GSA_TEST_GSA_BIN" ] || fail "the engine under test is not executable: $GSA_TEST_GSA_BIN"
export GSA_TEST_ENGINE=gsa
export GSA_TEST_GSA_BIN

# ─── shared synthesis helpers ───────────────────────────────────────────────

# tripwire_sudo DIR — inline scenario stub: log the invocation and FAIL. On a
# user-writable target the seam must never call it (a/b/g/j assert the log
# stays empty); with a non-writable target it is the dead `sudo -n`
# credential the engine must fail fast on (case d).
tripwire_sudo() {
    cat >"$1/bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'sudo %s\n' "$*" >>"${GSA_FAKE_SUDO_LOG:?}"
exit 1
EOF
    chmod +x "$1/bin/sudo"
}

# fake_db_conf DIR — the pacman-conf stub answering `pacman-conf DBPath` with
# the fixture's fabricated DB root (the -Mi installed-DB probe and the
# registration's db.lck wait must never read the host's /var/lib/pacman).
fake_db_conf() {
    cat >"$1/bin/pacman-conf" <<'EOF'
#!/usr/bin/env bash
set -u
if [[ ${1:-} == DBPath ]]; then
    printf '%s\n' "${GSA_FAKE_DB_PATH:?fixture forgot GSA_FAKE_DB_PATH}"
    exit 0
fi
exit 1
EOF
    chmod +x "$1/bin/pacman-conf"
}

# add_recipe WS CHANNEL ID — a real-shape recipe dir (packages/<channel>/<id>)
# with a one-line PKGBUILD and a committed .SRCINFO carrying pkgbase/pkgname
# (the only fields the universe scan reads), plus its topology record (the
# engine's declared-name universe walks the topology, not the directories).
add_recipe() {
    local ws=$1 channel=$2 id=$3
    mkdir -p "$ws/packages/$channel/$id"
    printf 'pkgname=%s\n' "$id" >"$ws/packages/$channel/$id/PKGBUILD"
    printf 'pkgbase = %s\npkgname = %s\n' "$id" "$id" \
        >"$ws/packages/$channel/$id/.SRCINFO"
    printf '%s|packages/%s/%s|%s|\n' "$id" "$channel" "$id" "$channel" \
        >>"$ws/config/topology.conf"
}

# make_conf PATH — the synthetic pacman.conf: [options] carries a duplicate
# name in its first IgnorePkg line (must be counted once) and the repo section
# below carries an IgnorePkg line that must be IGNORED with a warning.
make_conf() {
    cat >"$1" <<'EOF'
# synthetic pacman.conf — the register seam's playground
[options]
HoldPkg = pacman glibc
IgnorePkg = alpha-git alpha-git beta-git
IgnorePkg = beta-git pre-covered

[multilib]
Include = /etc/pacman.d/mirrorlist
IgnorePkg = ghost-one
EOF
}

# make_register_ws DIR — synthetic workspace: two one-line recipes, ONE SPLIT
# recipe (pkgbase + 13 outputs, the vlc/texlive shape) and ghost-one whose name
# only ever appears in a REPO-section IgnorePkg line. Universe = 17 names.
make_register_ws() {
    local ws=$1
    make_workspace "$ws" 1 2 low
    tripwire_sudo "$ws"
    fake_db_conf "$ws"
    add_recipe "$ws" git alpha-git
    add_recipe "$ws" git beta-git
    add_recipe "$ws" misc ghost-one
    mkdir -p "$ws/packages/stable/split-demo"
    {
        printf 'pkgbase=split-demo\n'
        printf 'pkgname=('
        printf 'split-demo-%s ' {1..13}
        printf ')\n'
    } >"$ws/packages/stable/split-demo/PKGBUILD"
    {
        printf 'pkgbase = split-demo\n'
        for i in {1..13}; do
            printf 'pkgname = split-demo-%s\n' "$i"
        done
    } >"$ws/packages/stable/split-demo/.SRCINFO"
    printf 'split-demo|packages/stable/split-demo|stable|\n' \
        >>"$ws/config/topology.conf"
}

# run_backfill WS CONF [ARG...] — the offline backfill through the engine's
# public verb (`gsa -Mi --backfill`, §B.7 — today's hidden
# `--register-ignorepkg`), the target conf named explicitly (gap G6). Always
# returns 0 — a refusing engine is the fixture's data (FIXTURE_RC).
run_backfill() {
    local ws=$1 conf=$2
    shift 2
    export PATH="$ws/bin:$PATH"
    export GSA_STATE_DIR="$ws/state"
    export GSA_FAKE_DB_PATH="$ws/state/var/pacman"
    export GSA_FAKE_SUDO_LOG="$ws/sudo.log"
    mkdir -p "$GSA_FAKE_DB_PATH"
    run_engine "$ws" -Mi --backfill --config "$conf" "$@"
}

# run_fish_register WS CONF [ARG...] — the FISH-era backfill seam, kept only
# for the DEVIATION 4 findings (cases h/i). Same capture contract as
# run_backfill.
run_fish_register() {
    local ws=$1 conf=$2
    shift 2
    # DEVIATION 4's findings (h/i) are semantics of the RETIRED fish engine
    # the native engine does not have (§4 inventory row
    # `tests/ignorepkg-register.sh`, KEEP cell conf-mutation semantics), and
    # §3 staging rules leave the scratch workspace engineless since the
    # cutover — so drive the FROZEN oracle, installed beside the workspace
    # for this deliberate fish-driven deviation only.
    install_fish_oracle "$ws"
    run_builder env LC_ALL=C \
        PATH="$ws/bin:$PATH" \
        GSA_STATE_DIR="$ws/state" \
        GSA_FAKE_SUDO_LOG="$ws/sudo.log" \
        fish "$ws/build-all.fish" --register-ignorepkg "$conf" "$@"
}

no_backup() {
    local conf=$1 baks=()
    shopt -s nullglob
    baks=("$conf".bak-*)
    shopt -u nullglob
    ((${#baks[@]} == 0)) ||
        fail "$2: expected no backup next to $conf, got: ${baks[*]}"
}

# conf_covers CONF NAME... — the [options]-closure check every section asserts
# on: a name counts only as an IgnorePkg token INSIDE [options] (a repo-section
# line never covers). Mirrors the pacman stub's own U-time oracle.
conf_covers() {
    local conf=$1 n covered
    shift
    covered=$(awk '
        /^\[/ { inopt = ($0 == "[options]") }
        inopt && /^IgnorePkg/ { sub(/^IgnorePkg *= */, ""); print }
    ' "$conf")
    for n in "$@"; do
        tr ' ' '\n' <<<"$covered" | grep -qxF -- "$n" || return 1
    done
    return 0
}

# ─── main scenario: one workspace + one conf feeding cases a, b, c, f, g, j ─
ws=$tmp/ws-main
make_register_ws "$ws"
conf=$tmp/main/pacman.conf
mkdir -p "$tmp/main"
make_conf "$conf"
cp "$conf" "$conf.orig"

# The contract's byte-exact spine: the 15 missing names in LC_ALL=C sort order
# (~10 per cumulative line). Case (a) compares the WHOLE resulting file
# against this — a broken placement (e.g. appending past the repo section), a
# broken idempotence (appending twice) or a broken chunker (15 on one line)
# all fail it. The engine's walker is the port of the fish one and must
# splice byte-identically.
exp_line1='IgnorePkg = ghost-one split-demo split-demo-1 split-demo-10 split-demo-11 split-demo-12 split-demo-13 split-demo-2 split-demo-3 split-demo-4'
exp_line2='IgnorePkg = split-demo-5 split-demo-6 split-demo-7 split-demo-8 split-demo-9'
[[ $(wc -w <<<"$exp_line1") == 12 ]] ||
    fail "a: exp_line1 must carry exactly 10 names, got: $exp_line1"
[[ $(wc -w <<<"$exp_line2") == 7 ]] ||
    fail "a: exp_line2 must carry exactly 5 names, got: $exp_line2"
build_expected_conf() {
    local src=$1 dst=$2 line
    while IFS= read -r line; do
        printf '%s\n' "$line"
        if [[ $line == 'IgnorePkg = beta-git pre-covered' ]]; then
            printf '%s\n%s\n' "$exp_line1" "$exp_line2"
        fi
    done <"$src" >"$dst"
}
build_expected_conf "$conf.orig" "$conf.expected"

run_backfill "$ws" "$conf"
((FIXTURE_RC == 0)) ||
    fail "a: rc 0 expected (closure complete afterwards), got rc=$FIXTURE_RC: $FIXTURE_OUTPUT"

# ─── a. placement, exact missing names, ~10 names/line ───────────────────────
cmp "$conf" "$conf.expected" >/dev/null ||
    fail "a: appended lines landed wrong (want exactly the missing names, ~10/line, after the last [options] IgnorePkg and before [multilib]): $(diff "$conf.expected" "$conf" || true)"
grep -Fq 'IgnorePkg inside repo section [multilib]' <<<"$FIXTURE_OUTPUT" ||
    fail "a: the [options] insertion must not touch the repo section, output: $FIXTURE_OUTPUT"
printf 'a: append lands in [options] only, exact missing names, 10/line OK\n'

# ─── c. repo-section names are not covered (ghost-one is appended) + warning ─
grep -Fq 'ghost-one' <<<"$exp_line1" ||
    fail "c: ghost-one must ride the appended lines — a repo-section IgnorePkg never covers a name"
[[ $(grep -c 'IgnorePkg inside repo section' <<<"$FIXTURE_OUTPUT") == 1 ]] ||
    fail "c: exactly one repo-drop warning expected, got: $FIXTURE_OUTPUT"
printf 'c: repo-section IgnorePkg ignored + warned OK\n'

# ─── f. post-check: the closure report's missing set is empty ────────────────
# The fish prose (`verification comm -23 … empty`) retires (§L.3): the empty
# missing set is DATA now — the report rows (§E.2) carry `missing` for wanted
# names the closure does not cover, and after a complete backfill there are
# none.
run_engine "$ws" -Mi --config "$conf"
((FIXTURE_RC == 0)) ||
    fail "f: the closure report must run clean, got rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
rows=$FIXTURE_OUTPUT
if printf '%s\n' "$rows" | awk '$2 == "missing" { found = 1 } END { exit !found }'; then
    fail "f: the closure report still names missing names after the backfill: $rows"
fi
conf_covers "$conf" alpha-git beta-git ghost-one split-demo \
    split-demo-1 split-demo-2 split-demo-3 split-demo-4 split-demo-5 \
    split-demo-6 split-demo-7 split-demo-8 split-demo-9 split-demo-10 \
    split-demo-11 split-demo-12 split-demo-13 ||
    fail "f: every universe name must be covered in [options] after the backfill: $(cat "$conf")"
printf 'f: post-check missing set empty OK\n'

# ─── g. dated pre-image backup, exactly once, original content ───────────────
shopt -s nullglob
baks=("$conf".bak-*)
shopt -u nullglob
((${#baks[@]} == 1)) ||
    fail "g: expected exactly one dated backup, got: ${baks[*]:-none}"
[[ ${baks[0]} == "$conf".bak-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9] ]] ||
    fail "g: backup must be <conf>.bak-YYYYMMDD, got: ${baks[0]}"
cmp "${baks[0]}" "$conf.orig" >/dev/null ||
    fail "g: the backup must be the PRE-image (original content)"
[[ ! -s $ws/sudo.log ]] ||
    fail "g: a user-writable target must never invoke sudo: $(cat "$ws/sudo.log")"
printf 'g: dated pre-image backup created exactly once OK\n'

# ─── b. second run is idempotent: rows all present, file byte-identical ──────
# `no changes needed` has no engine rendering (§L.3): idempotence re-pins as
# the `-Mi --backfill` rows (`present in-closure`, zero `add`) and byte
# identity of the conf (the KEEP behaviour).
cp "$conf" "$conf.after1"
run_backfill "$ws" "$conf"
((FIXTURE_RC == 0)) ||
    fail "b: idempotent re-run must exit 0, got rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
if printf '%s\n' "$FIXTURE_OUTPUT" | awk '$2 == "add" { found = 1 } END { exit !found }'; then
    fail "b: the idempotent re-run planned additions, output: $FIXTURE_OUTPUT"
fi
[[ $(printf '%s\n' "$FIXTURE_OUTPUT" | awk '$2 == "present"' | wc -l) == 17 ]] ||
    fail "b: the re-run must report all 17 universe names as present, output: $FIXTURE_OUTPUT"
cmp "$conf" "$conf.after1" >/dev/null ||
    fail "b: idempotent re-run rewrote the file: $(diff "$conf.after1" "$conf" || true)"
shopt -s nullglob
baks=("$conf".bak-*)
shopt -u nullglob
((${#baks[@]} == 1)) ||
    fail "b: the backup must be created exactly once, got: ${baks[*]:-none}"
cmp "${baks[0]}" "$conf.orig" >/dev/null ||
    fail "b: the single backup must keep the original content"
[[ ! -s $ws/sudo.log ]] ||
    fail "b: a user-writable target must never invoke sudo: $(cat "$ws/sudo.log")"
printf 'b: second run adds nothing (idempotent) OK\n'

# ─── j. second same-day WRITE proceeds; the dated backup stays the pre-image ─
# The universe grows (a recipe landed between two registrations), so this run
# WRITES again: the engine keeps the existing dated backup as the day's
# original pre-image (`already present (kept as the day's pre-image)`) and
# appends only the new name.
add_recipe "$ws" git delta-git
run_backfill "$ws" "$conf"
((FIXTURE_RC == 0)) ||
    fail "j: a second write of the day must proceed (rc 0), got rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
grep -Fq "kept as the day's pre-image" <<<"$FIXTURE_OUTPUT" ||
    fail "j: expected the kept-pre-image line, got: $FIXTURE_OUTPUT"
grep -Fq 'delta-git' "$conf" ||
    fail "j: delta-git must be appended to the closure: $(cat "$conf")"
conf_covers "$conf" delta-git ||
    fail "j: delta-git must land inside [options]: $(cat "$conf")"
shopt -s nullglob
baks=("$conf".bak-*)
shopt -u nullglob
((${#baks[@]} == 1)) ||
    fail "j: the dated backup must still be exactly one, got: ${baks[*]:-none}"
cmp "${baks[0]}" "$conf.orig" >/dev/null ||
    fail "j: the kept backup must stay the ORIGINAL pre-image, it was rewritten"
printf 'j: second write proceeds, original .bak kept OK\n'

# ─── d. non-writable target + dead sudo = refusal, file unchanged ────────────
# DEVIATION 5: rc 3 (§G.1) and the escalation is the engine's own `sudo -n cp`
# write path (the fish `sudo -n true` probe pin retires). The engine tests the
# conf DIRECTORY's writability, so the scenario is a 0555 directory; the
# subshell restores it so the fixture tree stays removable.
if [[ $(id -u) == 0 ]]; then
    printf 'd: skipped — running as root, a 0555 directory is still writable there\n'
else
    (
        fail() {
            printf 'ignorepkg-register d: %s\n' "$1" >&2
            exit 1
        }
        ws_d=$tmp/ws-d
        make_register_ws "$ws_d"
        mkdir -p "$tmp/d"
        conf_d=$tmp/d/pacman.conf
        make_conf "$conf_d"
        cp "$conf_d" "$conf_d.orig"
        chmod 555 "$tmp/d"
        trap 'chmod 755 "$tmp/d" 2>/dev/null || true' EXIT
        run_backfill "$ws_d" "$conf_d"
        ((FIXTURE_RC == 3)) ||
            fail "refusal rc 3 expected (§G.1), got rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
        grep -Fq 'cannot write backup' <<<"$FIXTURE_OUTPUT" ||
            fail "the refusal must name the blocked backup write, got: $FIXTURE_OUTPUT"
        grep -Fq 'nothing changed' <<<"$FIXTURE_OUTPUT" ||
            fail "the refusal must say nothing changed, got: $FIXTURE_OUTPUT"
        cmp "$conf_d" "$conf_d.orig" >/dev/null ||
            fail "the conf must be unchanged byte-for-byte after the refusal"
        no_backup "$conf_d" d
        # The only escalation is non-interactive (`sudo -n cp …`): the engine
        # runs the write itself through `sudo -n` and never probes or prompts
        # (§K.3 "the builder never prompts").
        [[ $(wc -l <"$ws_d/sudo.log") == 1 ]] ||
            fail "exactly one escalation attempt expected, log: $(cat "$ws_d/sudo.log" 2>/dev/null || true)"
        grep -Eq -- '^sudo -n cp -p -- ' "$ws_d/sudo.log" ||
            fail "the escalation must be the non-interactive 'sudo -n cp -p', log: $(cat "$ws_d/sudo.log")"
        printf 'd: non-writable target + dead sudo = rc 3, byte-identical OK\n'
    )
fi

# ─── e. bad usage = rc 2 on the hidden seam (§D.1 vocabulary) ────────────────
run_engine "$ws" --register-ignorepkg "$conf" extra
((FIXTURE_RC == 2)) ||
    fail "e: too many args must be rc 2, got rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
grep -Fq 'takes at most one <conf> argument' <<<"$FIXTURE_OUTPUT" ||
    fail "e: bad usage must name the argument error, got: $FIXTURE_OUTPUT"
# DEVIATION 6: an empty conf path is a read REFUSAL (seam rc 1), never a
# silent success — and it mutates nothing.
run_engine "$ws" --register-ignorepkg ''
((FIXTURE_RC == 1)) ||
    fail "e: an empty conf path must refuse (seam rc 1), got rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
grep -Fq 'cannot read' <<<"$FIXTURE_OUTPUT" ||
    fail "e: the refusal must name the unreadable conf, got: $FIXTURE_OUTPUT"
printf 'e: bad usage rc 2 / unreadable conf refused OK\n'

# ─── S. the hidden write-path seam (--install-register, §D.1) ───────────────
# The registration write path in isolation (the run path shares it verbatim):
# dated pre-image, [options] splice, idempotence, rc 2 usage vocabulary.
(
    fail() {
        printf 'ignorepkg-register seam: %s\n' "$1" >&2
        exit 1
    }
    ws_s=$tmp/ws-seam
    make_register_ws "$ws_s"
    conf_s=$tmp/seam/pacman.conf
    mkdir -p "$tmp/seam"
    make_conf "$conf_s"
    export PATH="$ws_s/bin:$PATH"
    export GSA_STATE_DIR="$ws_s/state"
    export GSA_FAKE_DB_PATH="$ws_s/state/var/pacman"
    export GSA_FAKE_SUDO_LOG="$ws_s/sudo.log"
    mkdir -p "$GSA_FAKE_DB_PATH"
    run_engine "$ws_s" --install-register "$conf_s" fixture alpha-git delta-git
    ((FIXTURE_RC == 0)) ||
        fail "the seam write must succeed, got rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
    conf_covers "$conf_s" alpha-git delta-git ||
        fail "the seam must splice its names into [options]: $(cat "$conf_s")"
    shopt -s nullglob
    baks=("$conf_s".bak-*)
    shopt -u nullglob
    ((${#baks[@]} == 1)) ||
        fail "the seam must leave exactly one dated backup, got: ${baks[*]:-none}"
    run_engine "$ws_s" --install-register "$conf_s" fixture alpha-git delta-git
    ((FIXTURE_RC == 0)) ||
        fail "the idempotent seam re-call must succeed, got rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
    grep -Fq 'registered 0 IgnorePkg name(s)' <<<"$FIXTURE_OUTPUT" ||
        fail "the idempotent re-call must report zero additions: $FIXTURE_OUTPUT"
    run_engine "$ws_s" --install-register "$conf_s" fixture
    ((FIXTURE_RC == 2)) ||
        fail "a nameless seam call must be rc 2 (§D.1), got rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
    printf 'seam: --install-register write, idempotence, usage OK\n'
)

# ─── h. recipe dir missing .SRCINFO = loud named finding, write blocked ──────
# FISH-DRIVEN — DEVIATION 4 (the engine falls back to a PKGBUILD scan and
# would silently register; the finding has no engine surface).
ws_h=$tmp/ws-h
make_workspace "$ws_h" 1 2 low
tripwire_sudo "$ws_h"
add_recipe "$ws_h" git good-git
mkdir -p "$ws_h/packages/misc/omega"
printf 'pkgname=omega\n' >"$ws_h/packages/misc/omega/PKGBUILD"
conf_h=$tmp/h/pacman.conf
mkdir -p "$tmp/h"
make_conf "$conf_h"
cp "$conf_h" "$conf_h.orig"
run_fish_register "$ws_h" "$conf_h"
((FIXTURE_RC == 1)) ||
    fail "h: an unverifiable universe must refuse (rc 1), got rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
grep -Fq 'packages/misc/omega' <<<"$FIXTURE_OUTPUT" ||
    fail "h: the finding must NAME the recipe dir, got: $FIXTURE_OUTPUT"
grep -Fq 'no .SRCINFO committed' <<<"$FIXTURE_OUTPUT" ||
    fail "h: the finding must say the .SRCINFO is missing, got: $FIXTURE_OUTPUT"
cmp "$conf_h" "$conf_h.orig" >/dev/null ||
    fail "h: refusal must leave the conf unchanged"
no_backup "$conf_h" h
printf 'h: missing .SRCINFO = loud named finding, blocked OK (fish-driven)\n'

# ─── i. stale .SRCINFO (literal pkgver drift) = named finding, blocked ───────
# FISH-DRIVEN — DEVIATION 4 (no engine .SRCINFO freshness check).
ws_i=$tmp/ws-i
make_workspace "$ws_i" 1 2 low
tripwire_sudo "$ws_i"
add_recipe "$ws_i" git good-git
mkdir -p "$ws_i/packages/misc/sigma"
printf 'pkgname=sigma\npkgver=2.0.0\n' >"$ws_i/packages/misc/sigma/PKGBUILD"
printf 'pkgbase = sigma\npkgname = sigma\npkgver = 1.0.0\n' \
    >"$ws_i/packages/misc/sigma/.SRCINFO"
conf_i=$tmp/i/pacman.conf
mkdir -p "$tmp/i"
make_conf "$conf_i"
cp "$conf_i" "$conf_i.orig"
run_fish_register "$ws_i" "$conf_i"
((FIXTURE_RC == 1)) ||
    fail "i: a stale .SRCINFO must refuse (rc 1), got rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
grep -Fq 'packages/misc/sigma' <<<"$FIXTURE_OUTPUT" ||
    fail "i: the finding must NAME the recipe dir, got: $FIXTURE_OUTPUT"
grep -Fq 'stale .SRCINFO' <<<"$FIXTURE_OUTPUT" ||
    fail "i: the finding must say the .SRCINFO is stale, got: $FIXTURE_OUTPUT"
grep -Fq 'pkgver' <<<"$FIXTURE_OUTPUT" ||
    fail "i: the finding must name the drifted field, got: $FIXTURE_OUTPUT"
cmp "$conf_i" "$conf_i.orig" >/dev/null ||
    fail "i: refusal must leave the conf unchanged"
no_backup "$conf_i" i
printf 'i: stale .SRCINFO = named finding, blocked OK (fish-driven)\n'

# ─── fish-era install runners (N4 and the DEVIATION 1/2 sections) ───────────
# make_install_ws DIR — the FISH-era one-package workspace (empty stub
# archives — the fish engine needs no .PKGINFO payloads): the trivial stubs
# plus the two ORACLE stubs, pacman recording whether the target conf ALREADY
# covers the expected names at `pacman -U` transaction time, and makepkg able
# to drop a db.lck at build end (GSA_FAKE_DB_SEED=1) so the registration's
# bounded lock wait sees one deterministically.
make_install_ws() {
    local ws=$1
    make_workspace "$ws" 1 1 low
    add_package "$ws" p1 "$gsa_meta_any"
    make_install_conf "$ws/pacman.conf"
    stub_sudo "$ws"
    cat >"$ws/bin/pacman-conf" <<'EOF'
#!/usr/bin/env bash
# DBPath oracle: never probe the host's real /var/lib/pacman/db.lck.
if [[ ${1:-} == DBPath ]]; then
    printf '%s\n' "${GSA_FAKE_DB_PATH:?fixture forgot GSA_FAKE_DB_PATH}"
    exit 0
fi
exit 1
EOF
    cat >"$ws/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(basename "$PWD")
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
if [[ ${GSA_FAKE_DB_SEED:-0} == 1 ]]; then
    mkdir -p "${GSA_FAKE_DB_PATH:?}/local"
    : >"${GSA_FAKE_DB_PATH}/db.lck"
fi
printf 'fake makepkg %s\n' "$PWD"
exit 0
EOF
    cat >"$ws/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'pacman %s\n' "$*" >>"${GSA_FAKE_PACMAN_LOG:?}"
if [[ ${1:-} == -Qp || ${1:-} == -Qi ]]; then
    # Doubt installs: an unanswered version probe keeps the archive in the
    # transaction (install_skip_reason's conservative direction).
    exit 1
fi
if [[ ${1:-} == -U ]]; then
    conf=${GSA_FAKE_EXPECT_CONF:?fixture forgot GSA_FAKE_EXPECT_CONF}
    covered=$(awk '
        /^\[/ { inopt = ($0 == "[options]") }
        inopt && /^IgnorePkg/ { sub(/^IgnorePkg *= */, ""); print }
    ' "$conf")
    state=covered
    for n in ${GSA_FAKE_EXPECT_NAMES:?fixture forgot GSA_FAKE_EXPECT_NAMES}; do
        tr ' ' '\n' <<<"$covered" | grep -qxF -- "$n" || state="NOT covered: $n"
    done
    printf 'U-time: %s %s\n' "$state" "${GSA_FAKE_EXPECT_NAMES}" \
        >>"${GSA_FAKE_PACMAN_LOG}"
fi
exit 0
EOF
    chmod +x "$ws/bin/"*
}

# run_install WS [VAR=VAL ...] [BUILD-ARG ...] — one FISH install-pipeline run
# against the workspace stubs (N4 only): VAR=VAL arguments are extra
# stub/fixture env, anything else is appended to the builder's own arguments
# (the selection is always `--install p1`). _IGNOREPKG_CONF is the WORKSPACE
# conf: without it the fish registration would rewrite the host's
# /etc/pacman.conf (the battery must be non-mutating).
run_install() {
    local ws=$1 arg
    shift
    local envs=() build=()
    for arg in "$@"; do
        if [[ $arg == *=* ]]; then
            envs+=("$arg")
        else
            build+=("$arg")
        fi
    done
    # N4's fast timeout is DEVIATION 3: a fish-era semantics with no engine
    # surface (§4 inventory row `tests/ignorepkg-register.sh`, pins cell
    # "bounded db.lck wait"; §3 staging rules leave no engine in the
    # workspace), so this run drives the FROZEN oracle, installed beside the
    # workspace for this deliberate fish-driven deviation only.
    install_fish_oracle "$ws"
    run_builder env PATH="$ws/bin:$PATH" LC_ALL=C \
        GSA_STATE_DIR="$ws/state" \
        _IGNOREPKG_CONF="$ws/pacman.conf" \
        GSA_FAKE_PACMAN_LOG="$ws/pacman.log" \
        GSA_FAKE_DB_PATH="$ws/state/var/pacman" \
        GSA_FAKE_EXPECT_CONF="$ws/pacman.conf" \
        GSA_FAKE_EXPECT_NAMES=p1 \
        "${envs[@]}" \
        fish "$ws/build-all.fish" --allow-broken-rustc --no-deps --no-sync \
            --lanes 1 --jobs 1 --install p1 "${build[@]}"
}

# run_text WS — everything the FISH run said, wherever its sink put it (the
# lane transcript plus the captured stdout/stderr).
run_text() {
    printf '%s\n' "$FIXTURE_OUTPUT"
    cat "$1/state/logs"/*.log 2>/dev/null
}

# ─── engine install-pipeline helpers (N1–N3, N5) ────────────────────────────
# make_engine_install_ws DIR — one package (p1) and the engine's stubs: a
# REAL-archive makepkg (staged .PKGINFO tar — an empty file is
# `refuse empty-list`, ENGINE FACTS), the U-time oracle pacman, sudo
# passthrough and the pacman-conf DBPath stub. p1 is a `core` member on
# purpose (DEVIATION 8): the engine's binpkg retention (N=1 for leaves,
# crates/gsa-state/src/index.rs `Retention::from_graph`) deletes an older
# instance's archive by PATH, and a same-version rebuild writes the SAME
# filename — so the prune eats the archive the run is about to install
# (`install-refused empty-list`). A hub (`core`) budget of 2 lets N5's two
# consecutive same-version runs both survive; the collision itself is
# reported as a gap, not pinned.
make_engine_install_ws() {
    local ws=$1
    make_workspace "$ws" 1 1 low
    add_package "$ws" p1 "$gsa_meta_any" core
    stub_sudo "$ws"
    fake_db_conf "$ws"
    cat >"$ws/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(basename "$PWD")
stage="$PWD/.stage-$id"
mkdir -p "$stage"
{
    printf 'pkgbase = %s\n' "$id"
    printf 'pkgname = %s\n' "$id"
    printf 'pkgver = 1.0.0-1\n'
    printf 'arch = any\n'
} >"$stage/.PKGINFO"
tar --zstd -cf "$PWD/$id-1.0.0-1-any.pkg.tar.zst" -C "$stage" .PKGINFO
rm -rf "$stage"
printf 'fake makepkg %s\n' "$PWD"
exit 0
EOF
    cat >"$ws/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'pacman %s\n' "$*" >>"${GSA_FAKE_PACMAN_LOG:?}"
if [[ ${1:-} == -Qp || ${1:-} == -Qi ]]; then
    # Doubt installs: an unanswered version probe keeps the archive in the
    # transaction (install_skip_reason's conservative direction).
    exit 1
fi
if [[ ${1:-} == -U ]]; then
    conf=${GSA_FAKE_EXPECT_CONF:?fixture forgot GSA_FAKE_EXPECT_CONF}
    covered=$(awk '
        /^\[/ { inopt = ($0 == "[options]") }
        inopt && /^IgnorePkg/ { sub(/^IgnorePkg *= */, ""); print }
    ' "$conf")
    state=covered
    for n in ${GSA_FAKE_EXPECT_NAMES:?fixture forgot GSA_FAKE_EXPECT_NAMES}; do
        tr ' ' '\n' <<<"$covered" | grep -qxF -- "$n" || state="NOT covered: $n"
    done
    printf 'U-time: %s %s\n' "$state" "${GSA_FAKE_EXPECT_NAMES}" \
        >>"${GSA_FAKE_PACMAN_LOG}"
fi
exit 0
EOF
    chmod +x "$ws/bin/"*
}

# run_s WS [FLAG...] — one engine install run for p1 (flags ride before the
# targets; the registration target is always the WORKSPACE conf, gap G6).
run_s() {
    local ws=$1
    shift
    export PATH="$ws/bin:$PATH"
    export GSA_STATE_DIR="$ws/state"
    export GSA_FAKE_DB_PATH="$ws/state/var/pacman"
    mkdir -p "$GSA_FAKE_DB_PATH"
    run_engine "$ws" -S --leaf --lanes 1 --jobs 1 "$@" --config "$ws/pacman.conf" p1
}

# ─── N1. register-before-install ordering ────────────────────────────────────
(
    fail() {
        printf 'ignorepkg-register N1: %s\n' "$1" >&2
        exit 1
    }
    ws=$tmp/ws-n1
    make_engine_install_ws "$ws"
    export GSA_FAKE_PACMAN_LOG="$ws/pacman.log"
    export GSA_FAKE_EXPECT_CONF="$ws/pacman.conf"
    export GSA_FAKE_EXPECT_NAMES=p1
    run_s "$ws"
    ((FIXTURE_RC == 0)) ||
        fail "install run must succeed, got rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
    rr2_body <<<"$FIXTURE_OUTPUT" >/dev/null ||
        fail "the run emitted no complete format: 2 record: $FIXTURE_OUTPUT"
    [[ $(rr2_scalar outcome <<<"$FIXTURE_OUTPUT") == success ]] ||
        fail "record outcome is not success: $FIXTURE_OUTPUT"
    [[ $(rr2_plan p1 plan <<<"$FIXTURE_OUTPUT") == build-install ]] ||
        fail "p1 must be planned build-install: $FIXTURE_OUTPUT"
    [[ $(rr2_outcome p1 status <<<"$FIXTURE_OUTPUT") == succeeded ]] ||
        fail "p1 must succeed: $FIXTURE_OUTPUT"
    grep -qF 'U-time: covered p1' "$ws/pacman.log" ||
        fail "the conf must already cover p1 at pacman -U time (registration before install): $(cat "$ws/pacman.log" 2>/dev/null || true)"
    grep -q 'pacman -U' "$ws/pacman.log" ||
        fail "the transaction never ran: $(cat "$ws/pacman.log" 2>/dev/null || true)"
    conf_covers "$ws/pacman.conf" p1 ||
        fail "p1 must be in the [options] closure after the run: $(cat "$ws/pacman.conf")"
    grep -qF '1 name(s) from 1 archive(s), appended 1 name(s)' <<<"$FIXTURE_OUTPUT" ||
        fail "the registration summary must report 1 name from 1 archive appended (derived from the staged set): $FIXTURE_OUTPUT"
    printf 'N1: names are registered before pacman -U OK\n'
)

# ─── N2. --no-register-ignorepkg: conf untouched, install still runs ─────────
(
    fail() {
        printf 'ignorepkg-register N2: %s\n' "$1" >&2
        exit 1
    }
    ws=$tmp/ws-n2
    make_engine_install_ws "$ws"
    cp "$ws/pacman.conf" "$ws/pacman.conf.orig"
    export GSA_FAKE_PACMAN_LOG="$ws/pacman.log"
    export GSA_FAKE_EXPECT_CONF="$ws/pacman.conf"
    export GSA_FAKE_EXPECT_NAMES=p1
    run_s "$ws" --no-register-ignorepkg
    ((FIXTURE_RC == 0)) ||
        fail "a skipped registration must not fail the run, got rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
    cmp "$ws/pacman.conf" "$ws/pacman.conf.orig" >/dev/null ||
        fail "the conf must stay byte-identical when registration is skipped: $(diff "$ws/pacman.conf.orig" "$ws/pacman.conf" || true)"
    grep -qF 'IgnorePkg registration skipped (--no-register-ignorepkg)' <<<"$FIXTURE_OUTPUT" ||
        fail "the skip must be announced (loud warn): $FIXTURE_OUTPUT"
    grep -q 'pacman -U' "$ws/pacman.log" ||
        fail "registration skip must NOT skip the install: $(cat "$ws/pacman.log" 2>/dev/null || true)"
    grep -qF 'U-time: NOT covered: p1' "$ws/pacman.log" ||
        fail "the oracle must observe the unregistered conf at -U time: $(cat "$ws/pacman.log" 2>/dev/null || true)"
    shopt -s nullglob
    baks=("$ws/pacman.conf".bak-*)
    shopt -u nullglob
    ((${#baks[@]} == 0)) ||
        fail "a skipped registration must not even back up: ${baks[*]}"
    printf 'N2: --no-register-ignorepkg skips the write loudly, install runs OK\n'
)

# ─── N3. live-held db.lck → the bounded wait reports, then it lands ─────────
# DEVIATION 7: the engine waits only for a LIVE holder (a /proc fd scan), so
# the fixture holds the lock open itself and releases it after 2 s; the
# engine's clearance has no message of its own — the wait note plus the
# landed registration is the observable.
(
    fail() {
        printf 'ignorepkg-register N3: %s\n' "$1" >&2
        exit 1
    }
    ws=$tmp/ws-n3
    make_engine_install_ws "$ws"
    export GSA_FAKE_PACMAN_LOG="$ws/pacman.log"
    export GSA_FAKE_EXPECT_CONF="$ws/pacman.conf"
    export GSA_FAKE_EXPECT_NAMES=p1
    export GSA_FAKE_DB_PATH="$ws/state/var/pacman"
    mkdir -p "$GSA_FAKE_DB_PATH"
    exec 9>"$GSA_FAKE_DB_PATH/db.lck"
    ( sleep 2; rm -f -- "$GSA_FAKE_DB_PATH/db.lck" ) &
    holder=$!
    run_s "$ws"
    exec 9>&-
    wait "$holder" 2>/dev/null
    ((FIXTURE_RC == 0)) ||
        fail "the bounded wait must proceed once the lock clears, got rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
    grep -q 'waiting for the pacman database lock to clear' <<<"$FIXTURE_OUTPUT" ||
        fail "the wait must be reported while the lock is held: $FIXTURE_OUTPUT"
    grep -qF 'U-time: covered p1' "$ws/pacman.log" ||
        fail "registration must land before pacman -U once the lock clears: $(cat "$ws/pacman.log" 2>/dev/null || true)"
    conf_covers "$ws/pacman.conf" p1 ||
        fail "p1 must be registered after the deferred write: $(cat "$ws/pacman.conf")"
    printf 'N3: live-held db.lck is waited on, then the registration lands OK\n'
)

# ─── N4. db.lck never clears + 1 s bound → refuse, fail, no pacman -U ────────
# FISH-DRIVEN — DEVIATION 3 (the engine's wait bound is a hardcoded 300 s
# with no knob; the fast timeout keeps its fish-era pin).
(
    fail() {
        printf 'ignorepkg-register N4: %s\n' "$1" >&2
        exit 1
    }
    ws=$tmp/ws-n4
    make_install_ws "$ws"
    cp "$ws/pacman.conf" "$ws/pacman.conf.orig"
    run_install "$ws" GSA_FAKE_DB_SEED=1 _PACMAN_LOCK_WAIT_S=1
    ((FIXTURE_RC != 0)) ||
        fail "an unregistrable set must fail the run, got rc=0: $(run_text "$ws")"
    text=$(run_text "$ws")
    grep -q 'pacman database lock still present after 1 s' <<<"$text" ||
        fail "the timeout must name the bounded wait: $text"
    grep -q 'refusing to install' <<<"$text" ||
        fail "the refusal must be explicit: $text"
    if grep -q 'pacman -U' "$ws/pacman.log" 2>/dev/null; then
        fail "no transaction may run on a refused registration: $(cat "$ws/pacman.log")"
    fi
    cmp "$ws/pacman.conf" "$ws/pacman.conf.orig" >/dev/null ||
        fail "the conf must stay unchanged on the timeout refusal: $(diff "$ws/pacman.conf.orig" "$ws/pacman.conf" || true)"
    printf 'N4: lock timeout refuses the install and fails the run OK (fish-driven)\n'
)

# ─── N5. idempotent second install run ───────────────────────────────────────
(
    fail() {
        printf 'ignorepkg-register N5: %s\n' "$1" >&2
        exit 1
    }
    ws=$tmp/ws-n5
    make_engine_install_ws "$ws"
    export GSA_FAKE_PACMAN_LOG="$ws/pacman.log"
    export GSA_FAKE_EXPECT_CONF="$ws/pacman.conf"
    export GSA_FAKE_EXPECT_NAMES=p1
    run_s "$ws"
    ((FIXTURE_RC == 0)) ||
        fail "first install run must succeed, got rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
    cp "$ws/pacman.conf" "$ws/pacman.conf.after1"
    run_s "$ws"
    ((FIXTURE_RC == 0)) ||
        fail "second install run must succeed, got rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
    rr2_body <<<"$FIXTURE_OUTPUT" >/dev/null ||
        fail "the second run emitted no complete format: 2 record: $FIXTURE_OUTPUT"
    [[ $(rr2_scalar outcome <<<"$FIXTURE_OUTPUT") == success ]] ||
        fail "second run outcome is not success: $FIXTURE_OUTPUT"
    # `no changes needed` retires (§L.3): the second run re-appends nothing —
    # no `appended` line at all — and the conf is byte-identical.
    if grep -q 'appended' <<<"$FIXTURE_OUTPUT"; then
        fail "the second run must not re-append names: $FIXTURE_OUTPUT"
    fi
    cmp "$ws/pacman.conf" "$ws/pacman.conf.after1" >/dev/null ||
        fail "the second run must not rewrite the conf: $(diff "$ws/pacman.conf.after1" "$ws/pacman.conf" || true)"
    shopt -s nullglob
    baks=("$ws/pacman.conf".bak-*)
    shopt -u nullglob
    ((${#baks[@]} == 1)) ||
        fail "two install runs must leave exactly one dated backup, got: ${baks[*]:-none}"
    printf 'N5: second install run is idempotent OK\n'
)

# make_fish_split_ws WS ID EPOCH OUTPUT... — a SPLIT recipe (pkgbase ID, one
# pkgname per OUTPUT) whose makepkg stub writes REAL package archives: a tar
# member .PKGINFO per output is what rung 1 of the registration reads.
# EPOCH=1 stamps `1:2.0-1` filenames (the shape real makepkg writes).
# GSA_FAKE_PKGVER is the version token in the filenames; GSA_FAKE_PKGINFO_EXTRA
# adds a pkgname line to one output's .PKGINFO only (N6's rung-1 pin).
make_fish_split_ws() {
    local ws=$1 id=$2 epoch=$3 out
    shift 3
    make_workspace "$ws" 1 1 low
    stub_sudo "$ws"
    mkdir -p "$ws/packages/$id"
    {
        printf 'pkgbase=%s\n' "$id"
        printf 'pkgname=('
        printf '%s ' "$@"
        printf ')\n'
        if [[ $epoch == 1 ]]; then
            printf 'epoch=1\n'
        fi
        printf 'pkgver=2.0\npkgrel=1\narch=(any)\n'
    } >"$ws/packages/$id/PKGBUILD"
    {
        printf 'pkgbase = %s\n' "$id"
        for out in "$@"; do
            printf 'pkgname = %s\n' "$out"
        done
        printf 'pkgver = 2.0\npkgrel = 1\n'
        if [[ $epoch == 1 ]]; then
            printf 'epoch = 1\n'
        fi
    } >"$ws/packages/$id/.SRCINFO"
    printf '%s|packages/%s|git|\n' "$id" "$id" >>"$ws/config/topology.conf"
    cat >"$ws/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -eu
id=$(basename "$PWD")
printf '%s\n' "$id" >>"${GSA_FAKE_MAKEPKG_LOG:?}"
field() { awk -v k="$1" -F' = ' '$1 == k { print $2; exit }' .SRCINFO; }
epoch=$(field epoch)
ver="${epoch:+$epoch:}$(field pkgver)-$(field pkgrel)"
stage="$PWD/.pkginfo-stage"
rm -rf "$stage"; mkdir -p "$stage"
while read -r out; do
    {
        printf 'pkgbase = %s\n' "$id"
        printf 'pkgname = %s\n' "$out"
        extra=$(printf '%s\n' "${GSA_FAKE_PKGINFO_EXTRA:-}" | awk -F= -v o="$out" '$1 == o { print $2 }')
        if [[ -n $extra ]]; then
            printf 'pkgname = %s\n' "$extra"
        fi
    } >"$stage/.PKGINFO"
    tar -cf "$PWD/$out-$ver-any.pkg.tar.zst" -C "$stage" .PKGINFO
done < <(awk -F' = ' '$1 == "pkgname" { print $2 }' .SRCINFO)
rm -rf "$stage"
exit 0
EOF
    cat >"$ws/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'pacman %s\n' "$*" >>"${GSA_FAKE_PACMAN_LOG:?}"
case ${1:-} in
-Qp)
    [[ ${GSA_FAKE_PROBE_MODE:-doubt} == answered ]] || exit 1
    base=$(basename -- "${3:-}")
    printf '%s %s\n' "${base%"-${GSA_FAKE_PKGVER:?}-any.pkg.tar.zst"}" "$GSA_FAKE_PKGVER"
    exit 0
    ;;
-Qi)
    [[ ${GSA_FAKE_PROBE_MODE:-doubt} == answered ]] || exit 1
    printf 'Name            : %s\nVersion         : %s\nInstall Date    : 2099-10-09 00:00:00\n' \
        "${3:-}" "$GSA_FAKE_PKGVER"
    exit 0
    ;;
-U)
    conf=${GSA_FAKE_EXPECT_CONF:?fixture forgot GSA_FAKE_EXPECT_CONF}
    covered=$(awk '
        /^\[/ { inopt = ($0 == "[options]") }
        inopt && /^IgnorePkg/ { sub(/^IgnorePkg *= */, ""); print }
    ' "$conf")
    state=covered
    for n in ${GSA_FAKE_EXPECT_NAMES:?fixture forgot GSA_FAKE_EXPECT_NAMES}; do
        tr ' ' '\n' <<<"$covered" | grep -qxF -- "$n" || state="NOT covered: $n"
    done
    printf 'U-time: %s %s\n' "$state" "${GSA_FAKE_EXPECT_NAMES}" \
        >>"${GSA_FAKE_PACMAN_LOG}"
    ;;
esac
exit 0
EOF
    chmod +x "$ws/bin/makepkg" "$ws/bin/pacman"
}

# prebuild_split WS ID — stage the "already built" state a skip claim sees:
# the stub makepkg IS the archive factory (called directly, marker cleared
# afterwards so an unwanted rebuild is still observable), and the toolchain
# record matches the running compiler so build_package's drift clean cannot
# delete the set (package_toolchain_state_matches).
prebuild_split() {
    local ws=$1 id=$2 gcc_id
    if command -v gcc >/dev/null 2>&1; then
        gcc_id=$(env LC_ALL=C gcc --version | head -1)
    else
        gcc_id='gcc unavailable'
    fi
    mkdir -p "$ws/state/toolchains"
    printf '%s\n%s\n' "$ws/packages/$id" "$gcc_id" >"$ws/state/toolchains/$id"
    ( cd "$ws/packages/$id" && GSA_FAKE_MAKEPKG_LOG="$ws/makepkg.log" "$ws/bin/makepkg" >/dev/null )
    : >"$ws/makepkg.log"
}

# run_fish_gen WS SEL EXPECT_NAMES [VAR=VAL ...] [BUILD-ARG ...] — the
# fish-driven N6/N8a/N8c runner (run_install's parameterised twin).
run_fish_gen() {
    local ws=$1 sel=$2 names=$3 arg
    shift 3
    local envs=() build=()
    for arg in "$@"; do
        if [[ $arg == *=* && $arg != -* ]]; then
            envs+=("$arg")
        else
            build+=("$arg")
        fi
    done
    # N6/N8a/N8c's acceptance-time registration is DEVIATION 1/2: fish-era
    # semantics with no engine surface (§4 inventory row
    # `tests/ignorepkg-register.sh`, run-shapes cell :877 `--skip`/:927
    # `-s -fi`; §3 staging rules leave no engine in the workspace), so these
    # runs drive the FROZEN oracle, installed beside the workspace for the
    # deliberate fish-driven deviations only.
    install_fish_oracle "$ws"
    run_builder env PATH="$ws/bin:$PATH" LC_ALL=C \
        GSA_STATE_DIR="$ws/state" \
        _IGNOREPKG_CONF="$ws/pacman.conf" \
        GSA_FAKE_PACMAN_LOG="$ws/pacman.log" \
        GSA_FAKE_MAKEPKG_LOG="$ws/makepkg.log" \
        GSA_FAKE_SUDO_LOG="$ws/sudo.log" \
        GSA_FAKE_EXPECT_CONF="$ws/pacman.conf" \
        GSA_FAKE_EXPECT_NAMES="$names" \
        "${envs[@]}" \
        fish "$ws/build-all.fish" --allow-broken-rustc --no-deps --no-sync \
            --lanes 1 --jobs 1 "${build[@]}" "$sel"
}

# ─── N6. the real leak: build-only acceptance must register first ────────────
# FISH-DRIVEN — DEVIATION 2 (the engine has no build-acceptance registration).
(
    fail() {
        printf 'ignorepkg-register N6: %s\n' "$1" >&2
        exit 1
    }
    ws=$tmp/ws-n6
    make_fish_split_ws "$ws" p6 1 p6-a p6-b p6-legacy
    # N6 builds only: the registration target is user-writable, so a tripwire
    # sudo (fails, logs) proves nothing escalates on the acceptance path.
    tripwire_sudo "$ws"
    run_fish_gen "$ws" p6 "p6 p6-a p6-b p6-legacy p6-extra" \
        GSA_FAKE_PKGVER='1:2.0-1' GSA_FAKE_PKGINFO_EXTRA='p6-b=p6-extra'
    ((FIXTURE_RC == 0)) ||
        fail "the build-only run must succeed, got rc=$FIXTURE_RC: $(run_text "$ws")"
    text=$(run_text "$ws")
    grep -q 'appended' <<<"$text" ||
        fail "the acceptance-time registration must report its write: $text"
    # p6-extra exists ONLY in the archives' .PKGINFO — no recipe metadata can
    # produce it, so this coverage failing is rung 1 regressing behind the
    # recipe-dir fallback.
    conf_covers "$ws/pacman.conf" p6 p6-a p6-b p6-legacy p6-extra ||
        fail "build acceptance must cover pkgbase + every output + the .PKGINFO-only name: $(cat "$ws/pacman.conf")"
    [[ ! -s $ws/sudo.log ]] ||
        fail "a user-writable registration target must never invoke sudo: $(cat "$ws/sudo.log" 2>/dev/null || true)"
    if grep -q 'pacman -U' "$ws/pacman.log" 2>/dev/null; then
        fail "a build-only run must not transact: $(cat "$ws/pacman.log")"
    fi
    # FOREIGN transaction — the 2026-10-06 pipewire leak shape: the archives
    # are installed later by something outside this run's install pipeline.
    GSA_FAKE_PACMAN_LOG="$ws/pacman.log" GSA_FAKE_EXPECT_CONF="$ws/pacman.conf" \
        GSA_FAKE_EXPECT_NAMES='p6 p6-a p6-b p6-legacy p6-extra' \
        "$ws/bin/pacman" -U "$ws/packages/p6/"*.pkg.tar.zst >/dev/null 2>&1
    grep -qF 'U-time: covered' "$ws/pacman.log" ||
        fail "the foreign transaction found unregistered names — the leak is open: $(cat "$ws/pacman.log" 2>/dev/null || true)"
    printf 'N6: build-only acceptance registers before any transaction OK (fish-driven)\n'
)

# ─── engine split workspace (N7/N8b) ────────────────────────────────────────
# make_engine_split_ws WS ID OUTPUT... — the engine-shape split recipe: the
# stub makepkg writes one real `.pkg.tar.zst` per output whose .PKGINFO
# carries pkgbase/pkgname/pkgver/arch (the engine's discovery and name
# authority read the archive's own .PKGINFO — rung 1).
make_engine_split_ws() {
    local ws=$1 id=$2 out
    shift 2
    make_workspace "$ws" 1 1 low
    stub_sudo "$ws"
    fake_db_conf "$ws"
    mkdir -p "$ws/packages/$id"
    {
        printf 'pkgbase=%s\n' "$id"
        printf 'pkgname=('
        printf '%s ' "$@"
        printf ')\n'
        printf 'pkgver=2.0\npkgrel=1\narch=(any)\n'
    } >"$ws/packages/$id/PKGBUILD"
    {
        printf 'pkgbase = %s\n' "$id"
        for out in "$@"; do
            printf 'pkgname = %s\n' "$out"
        done
        printf 'pkgver = 2.0\npkgrel = 1\n'
    } >"$ws/packages/$id/.SRCINFO"
    printf '%s|packages/%s|git|\n' "$id" "$id" >>"$ws/config/topology.conf"
    cat >"$ws/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -eu
id=$(basename "$PWD")
field() { awk -v k="$1" -F' = ' '$1 == k { print $2; exit }' .SRCINFO; }
ver="$(field pkgver)-$(field pkgrel)"
stage="$PWD/.pkginfo-stage"
rm -rf "$stage"; mkdir -p "$stage"
while read -r out; do
    {
        printf 'pkgbase = %s\n' "$id"
        printf 'pkgname = %s\n' "$out"
        printf 'pkgver = %s\n' "$ver"
        printf 'arch = any\n'
    } >"$stage/.PKGINFO"
    tar --zstd -cf "$PWD/$out-$ver-any.pkg.tar.zst" -C "$stage" .PKGINFO
done < <(awk -F' = ' '$1 == "pkgname" { print $2 }' .SRCINFO)
rm -rf "$stage"
exit 0
EOF
    cat >"$ws/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'pacman %s\n' "$*" >>"${GSA_FAKE_PACMAN_LOG:?}"
if [[ ${1:-} == -Qp || ${1:-} == -Qi ]]; then
    exit 1
fi
if [[ ${1:-} == -U ]]; then
    conf=${GSA_FAKE_EXPECT_CONF:?fixture forgot GSA_FAKE_EXPECT_CONF}
    covered=$(awk '
        /^\[/ { inopt = ($0 == "[options]") }
        inopt && /^IgnorePkg/ { sub(/^IgnorePkg *= */, ""); print }
    ' "$conf")
    state=covered
    for n in ${GSA_FAKE_EXPECT_NAMES:?fixture forgot GSA_FAKE_EXPECT_NAMES}; do
        tr ' ' '\n' <<<"$covered" | grep -qxF -- "$n" || state="NOT covered: $n"
    done
    printf 'U-time: %s %s\n' "$state" "${GSA_FAKE_EXPECT_NAMES}" \
        >>"${GSA_FAKE_PACMAN_LOG}"
fi
exit 0
EOF
    chmod +x "$ws/bin/makepkg" "$ws/bin/pacman"
}

# db_install NAME VERSION [PROVIDE…] — one fabricated pacman local-DB entry in
# the ENGINE's layout (`$GSA_FAKE_DB_PATH/local/<name>-<ver>/{desc,files}`,
# read through `pacman-conf DBPath`; never the host DB). The entry directory's
# mtime IS the install date (crates/gsa-install localdb.rs).
db_install() {
    local name=$1 version=$2 dir
    shift 2
    dir="$GSA_FAKE_DB_PATH/local/$name-$version"
    mkdir -p "$dir"
    {
        printf '%%NAME%%\n%s\n\n' "$name"
        printf '%%VERSION%%\n%s\n\n' "$version"
        printf '%%BASE%%\n%s\n' "$name"
        if (($#)); then
            printf '\n%%PROVIDES%%\n'
            printf '%s\n' "$@"
        fi
    } >"$dir/desc"
    printf '%%FILES%%\n' >"$dir/files"
    printf '%s\n' "$dir"
}

# ─── N7. split outputs through the install pipeline, rung 1 payloads ─────────
(
    fail() {
        printf 'ignorepkg-register N7: %s\n' "$1" >&2
        exit 1
    }
    ws=$tmp/ws-n7
    make_engine_split_ws "$ws" p7 p7-a p7-b
    export PATH="$ws/bin:$PATH"
    export GSA_STATE_DIR="$ws/state"
    export GSA_FAKE_PACMAN_LOG="$ws/pacman.log"
    export GSA_FAKE_EXPECT_CONF="$ws/pacman.conf"
    export GSA_FAKE_EXPECT_NAMES='p7 p7-a p7-b'
    export GSA_FAKE_DB_PATH="$ws/state/var/pacman"
    mkdir -p "$GSA_FAKE_DB_PATH"
    run_engine "$ws" -S --leaf --lanes 1 --jobs 1 --config "$ws/pacman.conf" p7
    ((FIXTURE_RC == 0)) ||
        fail "the install run must succeed, got rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
    rr2_body <<<"$FIXTURE_OUTPUT" >/dev/null ||
        fail "the run emitted no complete format: 2 record: $FIXTURE_OUTPUT"
    [[ $(rr2_scalar outcome <<<"$FIXTURE_OUTPUT") == success ]] ||
        fail "record outcome is not success: $FIXTURE_OUTPUT"
    [[ $(grep -c 'pacman -U' "$ws/pacman.log") == 1 ]] ||
        fail "exactly ONE transaction must cover the split set: $(cat "$ws/pacman.log" 2>/dev/null || true)"
    grep -qF 'U-time: covered p7 p7-a p7-b' "$ws/pacman.log" ||
        fail "pkgbase + every output must be covered at -U time: $(cat "$ws/pacman.log" 2>/dev/null || true)"
    grep -qF 'p7-a-2.0-1-any.pkg.tar.zst' "$ws/pacman.log" &&
        grep -qF 'p7-b-2.0-1-any.pkg.tar.zst' "$ws/pacman.log" ||
        fail "the one transaction must name both output archives: $(cat "$ws/pacman.log")"
    conf_covers "$ws/pacman.conf" p7 p7-a p7-b ||
        fail "the closure must carry pkgbase + every output (names from the archives' .PKGINFO): $(cat "$ws/pacman.conf")"
    printf 'N7: split outputs register before the single transaction OK\n'
)

# ─── N8a. an -s freshness CLAIM registers with nothing to install ────────────
# FISH-DRIVEN — DEVIATION 1 (`--skip` is parse-and-refuse on the engine).
(
    fail() {
        printf 'ignorepkg-register N8a: %s\n' "$1" >&2
        exit 1
    }
    ws=$tmp/ws-n8a
    make_fish_split_ws "$ws" p8 0 p8-a p8-b
    prebuild_split "$ws" p8
    run_fish_gen "$ws" p8 "p8 p8-a p8-b" \
        GSA_FAKE_PKGVER='2.0-1' GSA_FAKE_PROBE_MODE=answered -s
    ((FIXTURE_RC == 0)) ||
        fail "the skip claim must succeed, got rc=$FIXTURE_RC: $(run_text "$ws")"
    # Lane mode is ALWAYS quiet: the `already built` line is a non-quiet-only
    # render, so the claim's observable is that makepkg never ran while the
    # claimed set's names landed in the conf — with no build there is no
    # post-build hook either, so that write can only be the skip CLAIM's.
    [[ ! -s $ws/makepkg.log ]] ||
        fail "a claimed-fresh package must not rebuild: $(cat "$ws/makepkg.log")"
    if grep -q 'pacman -U' "$ws/pacman.log" 2>/dev/null; then
        fail "a build-only skip claim must not transact: $(cat "$ws/pacman.log")"
    fi
    conf_covers "$ws/pacman.conf" p8 p8-a p8-b ||
        fail "the skip CLAIM must register the claimed set (a foreign install of it is otherwise unprotected): $(cat "$ws/pacman.conf")"
    printf 'N8a: skip-claim acceptance registers without any install OK (fish-driven)\n'
)

# ─── N8b. same-version skip rows: registered, but no transaction ─────────────
# The R-5 re-pin: the skip rows are §E.2 DATA through the hidden
# `--install-decide` seam (rr2_decisions), and the -S run proves the kept
# behaviour — the skip rows transact nothing while their names register. The
# fabricated local DB's entries carry a 2099 install date (mtime), so the
# same-version rule skips deterministically even though the run rebuilds.
(
    fail() {
        printf 'ignorepkg-register N8b: %s\n' "$1" >&2
        exit 1
    }
    ws=$tmp/ws-n8b
    make_engine_split_ws "$ws" p8 p8-a p8-b
    export PATH="$ws/bin:$PATH"
    export GSA_STATE_DIR="$ws/state"
    export GSA_FAKE_PACMAN_LOG="$ws/pacman.log"
    export GSA_FAKE_EXPECT_CONF="$ws/pacman.conf"
    export GSA_FAKE_EXPECT_NAMES='p8 p8-a p8-b'
    export GSA_FAKE_DB_PATH="$ws/state/var/pacman"
    mkdir -p "$GSA_FAKE_DB_PATH"
    ( cd "$ws/packages/p8" && "$ws/bin/makepkg" >/dev/null )
    ver=2.0-1
    canon="0:$ver" # the engine's canonical version folds the (zero) epoch in
    for out in p8-a p8-b; do
        touch -d '2099-10-09 00:00:00' "$(db_install "$out" "$ver")"
    done
    archives=("$ws/packages/p8/"*.pkg.tar.zst)
    ((${#archives[@]} == 2)) ||
        fail "the split set must stage exactly 2 archives, got: ${archives[*]}"
    run_engine "$ws" --install-decide checked "${archives[@]}"
    ((FIXTURE_RC == 0)) ||
        fail "a skip-only plan is rc 0 (§E.5), got rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
    rows=$(rr2_decisions <<<"$FIXTURE_OUTPUT") ||
        fail "the seam rows are not §E.2-framed: $FIXTURE_OUTPUT"
    [[ $(wc -l <<<"$rows") == 2 ]] ||
        fail "one decision row per staged archive expected, got rows: $rows"
    if printf '%s\n' "$rows" | awk '$2 == "skip" && $3 == "already-current" { ok++ } END { exit !(ok == 2) }'; then
        :
    else
        fail "both rows must be 'skip already-current' (§E.3), got rows: $rows"
    fi
    [[ $(grep -cF "already-current $canon" <<<"$FIXTURE_OUTPUT") == 2 ]] ||
        fail "each skip row must name the installed version $canon: $FIXTURE_OUTPUT"
    run_engine "$ws" -S --leaf --lanes 1 --jobs 1 --config "$ws/pacman.conf" p8
    ((FIXTURE_RC == 0)) ||
        fail "a same-version skip plan must not fail the run, got rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
    rr2_body <<<"$FIXTURE_OUTPUT" >/dev/null ||
        fail "the run emitted no complete format: 2 record: $FIXTURE_OUTPUT"
    [[ $(rr2_scalar outcome <<<"$FIXTURE_OUTPUT") == success ]] ||
        fail "record outcome is not success: $FIXTURE_OUTPUT"
    if grep -q 'pacman -U' "$ws/pacman.log" 2>/dev/null; then
        fail "skip rows must run no transaction: $(cat "$ws/pacman.log")"
    fi
    conf_covers "$ws/pacman.conf" p8 p8-a p8-b ||
        fail "skip rows are archives this run keeps — their names must be registered: $(cat "$ws/pacman.conf")"
    shopt -s nullglob
    baks=("$ws/pacman.conf".bak-*)
    shopt -u nullglob
    ((${#baks[@]} == 1)) ||
        fail "the registration must leave exactly one dated backup, got: ${baks[*]:-none}"
    printf 'N8b: same-version skip rows register and transact nothing OK\n'
)

# ─── N8c. -s + -fi: the claim plus forced rows ───────────────────────────────
# FISH-DRIVEN — DEVIATION 1 (`--skip` is parse-and-refuse on the engine).
(
    fail() {
        printf 'ignorepkg-register N8c: %s\n' "$1" >&2
        exit 1
    }
    ws=$tmp/ws-n8c
    make_fish_split_ws "$ws" p8 0 p8-a p8-b
    prebuild_split "$ws" p8
    run_fish_gen "$ws" p8 "p8 p8-a p8-b" \
        GSA_FAKE_PKGVER='2.0-1' GSA_FAKE_PROBE_MODE=answered -s -fi
    ((FIXTURE_RC == 0)) ||
        fail "the forced install of a claimed set must succeed, got rc=$FIXTURE_RC: $(run_text "$ws")"
    grep -q 'pacman -U' "$ws/pacman.log" ||
        fail "-fi must bypass the same-version skip and transact: $(cat "$ws/pacman.log" 2>/dev/null || true)"
    grep -qF 'U-time: covered p8 p8-a p8-b' "$ws/pacman.log" ||
        fail "the forced transaction must find every name covered: $(cat "$ws/pacman.log" 2>/dev/null || true)"
    conf_covers "$ws/pacman.conf" p8 p8-a p8-b ||
        fail "the closure must carry the claimed set: $(cat "$ws/pacman.conf")"
    printf 'N8c: -s + -fi forces the transaction with every name covered OK (fish-driven)\n'
)

printf 'ignorepkg-register fixture: PASS\n'
