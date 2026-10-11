#!/usr/bin/env bash
set -euo pipefail

# AUTO-REGISTER IgnorePkg (build-all.fish --register-ignorepkg): the mutation
# seam behind docs/MEMORY.md rule 9's write half — the read half is the
# report-only --audit closure lint (tests/recipe-contract.sh walks it). The
# seam computes the workspace pkgname universe (pkgbase+pkgname of every
# committed .SRCINFO) and appends the names the target pacman.conf does not
# cover as cumulative `IgnorePkg =` lines (~10 names/line) INSIDE [options].
#
# Contract pinned here (fixture paths are user-writable — NO sudo, ever):
#   a. appended lines land inside [options] only (after the last existing
#      IgnorePkg line there, before the next section header), exactly the
#      missing names, ~10 names per line — pinned byte-exact, so ANY
#      placement/idempotence/chunking drift fails this case;
#   b. second run = `no changes needed`, file byte-identical (idempotence);
#   c. an IgnorePkg line inside a repo section is dropped by pacman — its
#      names are NOT counted as covered (they get appended) and a warning
#      naming the repo section appears;
#   d. non-writable conf + failing sudo stub = rc 1, `sudo cannot modify …
#      non-interactively`, file unchanged byte-for-byte, no backup;
#   e. bad usage = rc 2 (mirroring --install-decide's vocabulary);
#   f. the post-check prints the comm -23 verification as an EMPTY missing set;
#   g. the dated pre-image backup (.bak-YYYYMMDD) is created exactly once and
#      keeps the original content across the idempotent second run;
#   h. a recipe dir with NO .SRCINFO is a loud NAMED finding that blocks the
#      write (refusal, file unchanged) — never a silent skip;
#   i. (extra) a stale .SRCINFO (literal pkgver drift, the bettbox class) is
#      named and blocks the same way;
#   j. a second same-day WRITE (a new recipe grows the universe) proceeds
#      instead of refusing on the existing dated backup, and that backup is
#      KEPT as the day's original pre-image (2026-10-05 semantics: the
#      install-time registration runs on every install, so a differing dated
#      backup is the normal state after the first write of the day).
#
# Install-pipeline sections (N1–N5), each in its own `( subshell )`: the
# registration step of the ONE install pipeline (install_register_ignorepkg →
# the hidden --install-register seam under the builder pacman mutex) —
# `--register-ignorepkg` above is only the offline backfill of the same core:
#   N1 register-before-install ordering — the pacman stub ORACLES the conf at
#      `pacman -U` transaction time (the only place that can observe the
#      ordering) and records `U-time: covered p1`;
#   N2 --no-register-ignorepkg — conf byte-identical, the warn line lands,
#      the install itself still runs (registration skip ≠ install skip) and
#      the oracle records `U-time: NOT covered: p1`;
#   N3 db.lck lands at build end and is cleared 2 s later — the bounded wait
#      reports, proceeds, names land, `pacman -U` runs;
#   N4 db.lck never cleared + _PACMAN_LOCK_WAIT_S=1 — the run FAILS, the
#      refusal names the timeout, NO pacman -U, conf unchanged;
#   N5 idempotent second install run — `no changes needed`, conf
#      byte-identical, exactly one dated backup.
#
# Acceptance-time sections (N6–N8), each in its own `( subshell )` — the
# registration that runs when a build (or an -s/--skip-built claim) is
# ACCEPTED, before this run may ever install anything. The real failure mode
# they reproduce (2026-10-06 pipewire set): a build-only run leaves its
# archives in the workspace and a later FOREIGN transaction — hand-run
# cross-recipe pacman -U, an AUR helper — installs them while /etc/pacman.conf
# does not cover their names. Split outputs and real tar .PKGINFO payloads
# throughout (stub archives are EMPTY elsewhere in this file, so only these
# sections exercise rung 1 of install_register_names):
#   N6 the leak itself — a split, EPOCH'd build-only run (no -i at all) must
#      have every archive name covered BEFORE any transaction exists, proven
#      by a foreign stub pacman -U run afterwards whose oracle reads the conf
#      at transaction time; one output's .PKGINFO carries an extra pkgname the
#      recipe metadata does not know, so the coverage can only come from the
#      archive itself (rung 1 authority);
#   N7 split outputs through the install pipeline — one transaction covering
#      pkgbase + every output at U-time;
#   N8a an -s freshness CLAIM with nothing to install — the claimed set's
#      names land in the conf even though this run never installs;
#   N8b same-version skip rows — registration lands, but the skip rows run NO
#      transaction;
#   N8c -s + -fi — the claim plus FORCE rows: the forced transaction runs and
#      finds every name covered.
#
# Mutation probes — all RUN on 2026-10-05, each red at its own named assertion,
# each reversed by pasting the original line back (never `git checkout`/
# `git stash`). Anchors are function names, not line numbers:
#   M-N1 ordering: move the `install_register_ignorepkg` call in install_execute
#      (build-all.fish's Dynamic IgnorePkg registration block) to AFTER the
#      pacman transaction → N1 red (`U-time: NOT covered: p1`);
#   M-N2 skip flag: make the `_IGNOREPKG_REGISTER = 0` check in
#      install_register_ignorepkg unreachable (`if false`) → N2 red (the conf
#      gains `IgnorePkg = p1`);
#   M-N3 bounded wait: `return 0` at the top of pacman_lock_wait_clear → N3 red
#      (no wait report, the write lands through the held lock);
#   M-N4 timeout refusal: flip pacman_lock_wait_clear's final `return 1` (its
#      "still present" path) to `return 0` → N4 red (run succeeds, the
#      transaction runs) while N1–N3 stay green;
#   M-j  backup semantics: re-add `return 1` after the kept-pre-image line in
#      register_ignorepkg_names (lib/audit.fish) → j red (second write refused);
#   M-idem idempotence: `if test (count $missing) -gt 0` → `if true` in
#      register_ignorepkg_names, with case b's twin assertion suspended for
#      that run → N5 red (the second install run rewrites instead of reporting
#      `no changes needed`);
#   M-N6 acceptance hooks: delete the two acceptance-time
#      `install_register_ignorepkg` calls in build_package (the skip-claim
#      block and the post-build block) → N6 red (conf empty at the foreign
#      transaction) and N8a red (nothing registers on a skip claim), while
#      N1–N5 stay green — that split is exactly what the leak was.
#
# rc vocabulary under test: 0 = closure complete afterwards (nothing to
# append counts), 1 = refusal with nothing changed, 2 = bad usage.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/tests/lib/fixture-lib.bash"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-ignorepkg-register.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'ignorepkg-register fixture: %s\n' "$1" >&2
    exit 1
}

# tripwire_sudo DIR — inline scenario stub: log the invocation and FAIL. On a
# user-writable target the seam must never call it (case a/b assert the log
# stays empty); with a non-writable target it is the dead `sudo -n` credential
# the builder must fail fast on (case d).
tripwire_sudo() {
    cat >"$1/bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'sudo %s\n' "$*" >>"${GSA_FAKE_SUDO_LOG:?}"
exit 1
EOF
    chmod +x "$1/bin/sudo"
}

# add_recipe WS CHANNEL ID — a real-shape recipe dir (packages/<channel>/<id>)
# with a one-line PKGBUILD and a committed .SRCINFO carrying pkgbase/pkgname
# (the only fields the universe scan reads).
add_recipe() {
    local ws=$1 channel=$2 id=$3
    mkdir -p "$ws/packages/$channel/$id"
    printf 'pkgname=%s\n' "$id" >"$ws/packages/$channel/$id/PKGBUILD"
    printf 'pkgbase = %s\npkgname = %s\n' "$id" "$id" \
        >"$ws/packages/$channel/$id/.SRCINFO"
}

# make_register_ws DIR — synthetic workspace: two one-line recipes, ONE SPLIT
# recipe (pkgbase + 13 outputs, the vlc/texlive shape) and ghost-one whose name
# only ever appears in a REPO-section IgnorePkg line. Universe = 17 names.
make_register_ws() {
    local ws=$1
    make_workspace "$ws" 1 2 low
    tripwire_sudo "$ws"
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

# run_register WS CONF [ARG...] — builder run through the capture helper with
# the fixture stubs on PATH and LC_ALL=C (the seam's sort order is pinned, so
# the byte-exact expectations hold in any host locale). Always returns 0 — a
# refusing builder is the fixture's data, asserted on via FIXTURE_RC.
run_register() {
    local ws=$1 conf=$2
    shift 2
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

# ─── install-pipeline helpers (N1–N5) ────────────────────────────────────────
# conf_covers CONF NAME... — the [options]-closure check the N sections assert
# on: a name counts only as an IgnorePkg token INSIDE [options] (a repo-section
# line never covers). Mirrors the pacman stub's own oracle.
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

# make_install_ws DIR — one package (p1), the trivial stubs plus the two
# ORACLE stubs: pacman records whether the target conf ALREADY covers the
# expected names at `pacman -U` transaction time (never enforces — the fixture
# asserts the recorded line so the red lands on the named check), and makepkg
# can drop a db.lck at build end (GSA_FAKE_DB_SEED=1) so the registration's
# bounded lock wait sees one deterministically: preflight has already passed,
# and nothing between build end and registration looks at the lock.
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

# run_install WS [VAR=VAL ...] [BUILD-ARG ...] — one install-pipeline run
# against the workspace stubs: VAR=VAL arguments are extra stub/fixture env,
# anything else is appended to the builder's own arguments (the selection is
# always `--install p1`). _IGNOREPKG_CONF is the WORKSPACE conf: without it
# the registration would rewrite the host's /etc/pacman.conf (the battery
# must be non-mutating).
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

# run_text WS — everything the run said, wherever its sink put it (the lane
# transcript plus the captured stdout/stderr).
run_text() {
    printf '%s\n' "$FIXTURE_OUTPUT"
    cat "$1/state/logs"/*.log 2>/dev/null
}

# ─── acceptance-time helpers (N6–N8) ─────────────────────────────────────────
# make_split_ws WS ID EPOCH OUTPUT... — a SPLIT recipe (pkgbase ID, one
# pkgname per OUTPUT) whose makepkg stub writes REAL package archives: a tar
# member .PKGINFO per output is what rung 1 of install_register_names reads,
# so N6–N8 exercise the authority path instead of the empty-archive recipe
# fallback every other section uses. EPOCH=1 stamps an epoch'd version —
# archive filenames carry `1:2.0-1`, the shape real makepkg writes (see
# /var/cache/pacman/pkg/*:*), and `pkgbuild_version` folds the epoch into the
# discovery stem the same way. The pacman stub is the U-time oracle from
# make_install_ws plus an `answered` probe mode (GSA_FAKE_PROBE_MODE=answered:
# -Qp/-Qi report the archive's version as already installed with an install
# date in 2099), which is exactly what the freshness payload gate and
# install_skip_reason's same-version skip row need; the default `doubt` mode
# keeps both queries failing, so a plan installs rather than skips.
# GSA_FAKE_PKGVER is the version token in the archive filenames (`2.0-1`, or
# `1:2.0-1` when EPOCH=1); GSA_FAKE_PKGINFO_EXTRA='OUTPUT=extra-name' adds a
# pkgname line to one output's .PKGINFO only (N6's rung-1 authority pin).
make_split_ws() {
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

# run_gen WS SEL EXPECT_NAMES [VAR=VAL ...] [BUILD-ARG ...] — the N6–N8 runner
# (run_install's parameterised twin: the selection and the U-time oracle's
# expected names are arguments, so a split recipe can assert pkgbase + every
# output). VAR=VAL arguments are extra stub env; anything else rides the
# builder's own arguments. _IGNOREPKG_CONF is the WORKSPACE conf — without it
# the registration would rewrite the host's /etc/pacman.conf.
run_gen() {
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

# ─── main scenario: one workspace + one conf feeding cases a, b, c, f, g ─────
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
# all fail it.
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

run_register "$ws" "$conf"
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

# ─── f. post-check shows an empty missing set ────────────────────────────────
grep -Fq 'verification comm -23 (universe vs closure after): empty' \
    <<<"$FIXTURE_OUTPUT" ||
    fail "f: post-check must print the empty comm -23 result, got: $FIXTURE_OUTPUT"
printf 'f: post-check verification empty OK\n'

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

# ─── b. second run is idempotent: no changes needed, file byte-identical ─────
cp "$conf" "$conf.after1"
run_register "$ws" "$conf"
((FIXTURE_RC == 0)) ||
    fail "b: idempotent re-run must exit 0, got rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
grep -Fq 'no changes needed' <<<"$FIXTURE_OUTPUT" ||
    fail "b: expected the 'no changes needed' summary, got: $FIXTURE_OUTPUT"
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
printf 'b: second run = no changes (idempotent) OK\n'

# ─── j. second same-day WRITE proceeds; the dated backup stays the pre-image ─
# The universe grows (a recipe landed between two registrations), so this run
# WRITES again: the pre-2026-10-05 semantics refused on the differing dated
# backup — which broke every second registration of the day.
add_recipe "$ws" git delta-git
run_register "$ws" "$conf"
((FIXTURE_RC == 0)) ||
    fail "j: a second write of the day must proceed (rc 0), got rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
grep -Fq 'kept as the day'"'"'s pre-image' <<<"$FIXTURE_OUTPUT" ||
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

# ─── d. non-writable conf + failing sudo = rc 1, file unchanged ──────────────
if [[ $(id -u) == 0 ]]; then
    printf 'd: skipped — running as root, a 0444 conf is still writable there\n'
else
    ws_d=$tmp/ws-d
    make_register_ws "$ws_d"
    conf_d=$tmp/d/pacman.conf
    mkdir -p "$tmp/d"
    make_conf "$conf_d"
    cp "$conf_d" "$conf_d.orig"
    chmod 444 "$conf_d"
    run_register "$ws_d" "$conf_d"
    ((FIXTURE_RC == 1)) ||
        fail "d: refusal rc 1 expected, got rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
    grep -Fq "sudo cannot modify $conf_d non-interactively" <<<"$FIXTURE_OUTPUT" ||
        fail "d: expected the non-interactive sudo refusal naming $conf_d, got: $FIXTURE_OUTPUT"
    cmp "$conf_d" "$conf_d.orig" >/dev/null ||
        fail "d: the conf must be unchanged byte-for-byte after the refusal"
    no_backup "$conf_d" d
    # The known host fish wrapper around sudo re-execs it with --preserve-env
    # injected (tests/lib/fixture-lib.bash stub_sudo documents it); what the
    # seam must probe is the NON-INTERACTIVE `sudo -n true` — a probe that can
    # never prompt — and nothing more.
    grep -Eq -- '^sudo (--preserve-env(=[^ ]*)? )?-n true$' "$ws_d/sudo.log" ||
        fail "d: the seam must probe exactly the non-interactive 'sudo -n true' before refusing, log: $(cat "$ws_d/sudo.log" 2>/dev/null || true)"
    printf 'd: non-writable conf + dead sudo = rc 1, byte-identical OK\n'
fi

# ─── e. bad usage = rc 2 (the --install-decide vocabulary) ───────────────────
run_register "$ws" "$conf" extra
((FIXTURE_RC == 2)) ||
    fail "e: too many args must be rc 2, got rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
grep -Fq 'Error:' <<<"$FIXTURE_OUTPUT" ||
    fail "e: bad usage must name the error, got: $FIXTURE_OUTPUT"
run_register "$ws" "$conf" ''
((FIXTURE_RC == 2)) ||
    fail "e: an empty conf path must be rc 2, got rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
printf 'e: bad usage rc 2 OK\n'

# ─── h. recipe dir missing .SRCINFO = loud named finding, write blocked ──────
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
run_register "$ws_h" "$conf_h"
((FIXTURE_RC == 1)) ||
    fail "h: an unverifiable universe must refuse (rc 1), got rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
grep -Fq 'packages/misc/omega' <<<"$FIXTURE_OUTPUT" ||
    fail "h: the finding must NAME the recipe dir, got: $FIXTURE_OUTPUT"
grep -Fq 'no .SRCINFO committed' <<<"$FIXTURE_OUTPUT" ||
    fail "h: the finding must say the .SRCINFO is missing, got: $FIXTURE_OUTPUT"
cmp "$conf_h" "$conf_h.orig" >/dev/null ||
    fail "h: refusal must leave the conf unchanged"
no_backup "$conf_h" h
printf 'h: missing .SRCINFO = loud named finding, blocked OK\n'

# ─── i. stale .SRCINFO (literal pkgver drift) = named finding, blocked ───────
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
run_register "$ws_i" "$conf_i"
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
printf 'i: stale .SRCINFO = loud named finding, blocked OK\n'

# ─── N1. register-before-install ordering ────────────────────────────────────
(
    fail() {
        printf 'ignorepkg-register N1: %s\n' "$1" >&2
        exit 1
    }
    ws=$tmp/ws-n1
    make_install_ws "$ws"
    run_install "$ws"
    ((FIXTURE_RC == 0)) ||
        fail "install run must succeed, got rc=$FIXTURE_RC: $(run_text "$ws")"
    grep -qF 'U-time: covered p1' "$ws/pacman.log" ||
        fail "the conf must already cover p1 at pacman -U time (registration before install): $(cat "$ws/pacman.log" 2>/dev/null || true)"
    grep -q 'pacman -U' "$ws/pacman.log" ||
        fail "the transaction never ran: $(cat "$ws/pacman.log" 2>/dev/null || true)"
    conf_covers "$ws/pacman.conf" p1 ||
        fail "p1 must be in the [options] closure after the run: $(cat "$ws/pacman.conf")"
    grep -q 'appended 1 name(s)' <(run_text "$ws") ||
        fail "the registration summary must report the appended name: $(run_text "$ws")"
    printf 'N1: names are registered before pacman -U OK\n'
)

# ─── N2. --no-register-ignorepkg: conf untouched, install still runs ─────────
(
    fail() {
        printf 'ignorepkg-register N2: %s\n' "$1" >&2
        exit 1
    }
    ws=$tmp/ws-n2
    make_install_ws "$ws"
    cp "$ws/pacman.conf" "$ws/pacman.conf.orig"
    run_install "$ws" --no-register-ignorepkg
    ((FIXTURE_RC == 0)) ||
        fail "a skipped registration must not fail the run, got rc=$FIXTURE_RC: $(run_text "$ws")"
    cmp "$ws/pacman.conf" "$ws/pacman.conf.orig" >/dev/null ||
        fail "the conf must stay byte-identical when registration is skipped: $(diff "$ws/pacman.conf.orig" "$ws/pacman.conf" || true)"
    grep -qF 'IgnorePkg registration skipped (--no-register-ignorepkg)' <(run_text "$ws") ||
        fail "the skip must be announced (loud warn): $(run_text "$ws")"
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

# ─── N3. db.lck held at build end, cleared 2 s later → wait, then register ───
(
    fail() {
        printf 'ignorepkg-register N3: %s\n' "$1" >&2
        exit 1
    }
    ws=$tmp/ws-n3
    make_install_ws "$ws"
    (
        # Bounded holder: exits on its own even if the run never seeds a lock.
        for _ in $(seq 1 300); do
            [[ -e $ws/state/var/pacman/db.lck ]] && break
            sleep 0.1
        done
        sleep 2
        rm -f -- "$ws/state/var/pacman/db.lck"
    ) &
    holder=$!
    run_install "$ws" GSA_FAKE_DB_SEED=1 _PACMAN_LOCK_WAIT_S=60
    wait "$holder" 2>/dev/null
    ((FIXTURE_RC == 0)) ||
        fail "the bounded wait must proceed once the lock clears, got rc=$FIXTURE_RC: $(run_text "$ws")"
    text=$(run_text "$ws")
    grep -q 'waiting up to 60 s for the pacman database lock to clear' <<<"$text" ||
        fail "the deferral must report its bounded wait: $text"
    grep -Eq 'pacman database lock cleared after [0-9]+ s' <<<"$text" ||
        fail "the wait must report the clearance: $text"
    grep -qF 'U-time: covered p1' "$ws/pacman.log" ||
        fail "registration must land before pacman -U once the lock clears: $(cat "$ws/pacman.log" 2>/dev/null || true)"
    conf_covers "$ws/pacman.conf" p1 ||
        fail "p1 must be registered after the deferred write: $(cat "$ws/pacman.conf")"
    printf 'N3: held db.lck defers the registration, then it lands OK\n'
)

# ─── N4. db.lck never clears + 1 s bound → refuse, fail, no pacman -U ────────
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
    printf 'N4: lock timeout refuses the install and fails the run OK\n'
)

# ─── N5. idempotent second install run ───────────────────────────────────────
(
    fail() {
        printf 'ignorepkg-register N5: %s\n' "$1" >&2
        exit 1
    }
    ws=$tmp/ws-n5
    make_install_ws "$ws"
    run_install "$ws"
    ((FIXTURE_RC == 0)) ||
        fail "first install run must succeed, got rc=$FIXTURE_RC: $(run_text "$ws")"
    cp "$ws/pacman.conf" "$ws/pacman.conf.after1"
    run_install "$ws"
    ((FIXTURE_RC == 0)) ||
        fail "second install run must succeed, got rc=$FIXTURE_RC: $(run_text "$ws")"
    grep -q 'no changes needed' <(run_text "$ws") ||
        fail "the second run must report the closure as complete: $(run_text "$ws")"
    cmp "$ws/pacman.conf" "$ws/pacman.conf.after1" >/dev/null ||
        fail "the second run must not rewrite the conf: $(diff "$ws/pacman.conf.after1" "$ws/pacman.conf" || true)"
    shopt -s nullglob
    baks=("$ws/pacman.conf".bak-*)
    shopt -u nullglob
    ((${#baks[@]} == 1)) ||
        fail "two install runs must leave exactly one dated backup, got: ${baks[*]:-none}"
    printf 'N5: second install run is idempotent OK\n'
)

# ─── N6. the real leak: build-only acceptance must register first ────────────
(
    fail() {
        printf 'ignorepkg-register N6: %s\n' "$1" >&2
        exit 1
    }
    ws=$tmp/ws-n6
    make_split_ws "$ws" p6 1 p6-a p6-b p6-legacy
    # N6 builds only: the registration target is user-writable, so a tripwire
    # sudo (fails, logs) proves nothing escalates on the acceptance path.
    tripwire_sudo "$ws"
    run_gen "$ws" p6 "p6 p6-a p6-b p6-legacy p6-extra" \
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
    printf 'N6: build-only acceptance registers before any transaction OK\n'
)

# ─── N7. split outputs through the install pipeline, rung 1 payloads ─────────
(
    fail() {
        printf 'ignorepkg-register N7: %s\n' "$1" >&2
        exit 1
    }
    ws=$tmp/ws-n7
    make_split_ws "$ws" p7 0 p7-a p7-b
    run_gen "$ws" p7 "p7 p7-a p7-b" GSA_FAKE_PKGVER='2.0-1' --install
    ((FIXTURE_RC == 0)) ||
        fail "the install run must succeed, got rc=$FIXTURE_RC: $(run_text "$ws")"
    grep -q 'pacman -U' "$ws/pacman.log" ||
        fail "the transaction never ran: $(cat "$ws/pacman.log" 2>/dev/null || true)"
    grep -qF 'U-time: covered p7 p7-a p7-b' "$ws/pacman.log" ||
        fail "pkgbase + every output must be covered at -U time: $(cat "$ws/pacman.log" 2>/dev/null || true)"
    conf_covers "$ws/pacman.conf" p7 p7-a p7-b ||
        fail "the closure must carry pkgbase + every output: $(cat "$ws/pacman.conf")"
    printf 'N7: split outputs register before the single transaction OK\n'
)

# ─── N8a. an -s freshness CLAIM registers with nothing to install ────────────
(
    fail() {
        printf 'ignorepkg-register N8a: %s\n' "$1" >&2
        exit 1
    }
    ws=$tmp/ws-n8a
    make_split_ws "$ws" p8 0 p8-a p8-b
    prebuild_split "$ws" p8
    run_gen "$ws" p8 "p8 p8-a p8-b" \
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
    printf 'N8a: skip-claim acceptance registers without any install OK\n'
)

# ─── N8b. same-version skip rows: registered, but no transaction ─────────────
(
    fail() {
        printf 'ignorepkg-register N8b: %s\n' "$1" >&2
        exit 1
    }
    ws=$tmp/ws-n8b
    make_split_ws "$ws" p8 0 p8-a p8-b
    run_gen "$ws" p8 "p8 p8-a p8-b" \
        GSA_FAKE_PKGVER='2.0-1' GSA_FAKE_PROBE_MODE=answered --install
    ((FIXTURE_RC == 0)) ||
        fail "a same-version skip plan must not fail the run, got rc=$FIXTURE_RC: $(run_text "$ws")"
    text=$(run_text "$ws")
    grep -q 'already installed at' <<<"$text" ||
        fail "the skip note must render for the skip rows: $text"
    if grep -q 'pacman -U' "$ws/pacman.log" 2>/dev/null; then
        fail "skip rows must run no transaction: $(cat "$ws/pacman.log")"
    fi
    conf_covers "$ws/pacman.conf" p8 p8-a p8-b ||
        fail "skip rows are archives this run keeps — their names must be registered: $(cat "$ws/pacman.conf")"
    printf 'N8b: same-version skip rows register and transact nothing OK\n'
)

# ─── N8c. -s + -fi: the claim plus forced rows ───────────────────────────────
(
    fail() {
        printf 'ignorepkg-register N8c: %s\n' "$1" >&2
        exit 1
    }
    ws=$tmp/ws-n8c
    make_split_ws "$ws" p8 0 p8-a p8-b
    prebuild_split "$ws" p8
    run_gen "$ws" p8 "p8 p8-a p8-b" \
        GSA_FAKE_PKGVER='2.0-1' GSA_FAKE_PROBE_MODE=answered -s -fi
    ((FIXTURE_RC == 0)) ||
        fail "the forced install of a claimed set must succeed, got rc=$FIXTURE_RC: $(run_text "$ws")"
    grep -q 'pacman -U' "$ws/pacman.log" ||
        fail "-fi must bypass the same-version skip and transact: $(cat "$ws/pacman.log" 2>/dev/null || true)"
    grep -qF 'U-time: covered p8 p8-a p8-b' "$ws/pacman.log" ||
        fail "the forced transaction must find every name covered: $(cat "$ws/pacman.log" 2>/dev/null || true)"
    conf_covers "$ws/pacman.conf" p8 p8-a p8-b ||
        fail "the closure must carry the claimed set: $(cat "$ws/pacman.conf")"
    printf 'N8c: -s + -fi forces the transaction with every name covered OK\n'
)

printf 'ignorepkg-register fixture: PASS\n'
