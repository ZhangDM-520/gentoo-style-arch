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
#      named and blocks the same way.
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

printf 'ignorepkg-register fixture: PASS\n'
