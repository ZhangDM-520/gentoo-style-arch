#!/usr/bin/env bash
set -euo pipefail

# tests/gsa-privilege.sh — the transparent privilege handle (contract §B.10,
# plan-gsa-isolation.md W1). Everything is synthetic: $TMPDIR workspaces, a
# stub `makepkg`, `GSA_STATE_DIR` overrides; the real /var/lib/gsa is never
# read or written.
#
# Pinned here (seven ( subshell ) sections, run one alone with
# GSA_PRIV_ONLY=a…g):
#   a. an unprivileged mutating verb refuses early (§G.1 rc 3) with the
#      pacman-worded message and creates NO state;
#   b. unprivileged read-only verbs pass the gate untouched;
#   c. a sudo run drops its build-side commands to the build user: the stub
#      makepkg records the dropped uid (the fixture runner's own uid);
#   d. a bare root shell (SUDO_UID/SUDO_GID stripped) refuses a build run
#      with guidance instead of improvising a build user;
#   e. `-Mm` refuses under a root supervisor (build-user-only verb);
#   f. the fetch half drops too: `gsa -Sw`'s `makepkg --verifysource` child
#      runs as the build user (the §D.1 fetch engine is a build-side command);
#   g. a real `-B` run under sudo prints the ONE banner line and its makepkg
#      child runs as the build user (plan-gsa-isolation.md test (c); the
#      cache-placement half of that scenario lands with W4's build_dir).
#
# Sections c–e use real `sudo -n` (passwordless by the host contract) with
# `env PATH="$PATH" …` so the stubs and knobs survive sudo's secure_path and
# env_reset — PATH stubs are the contract (§D.2). Every engine call carries
# an explicit state root (env or flag), so nothing can reach the real one.
#
# House conventions: `( subshell )` sections with their own workspace and
# state root, inline stubs and oracles, `fail()` prefixes, and rr-v2.bash's
# run_engine_user for the unprivileged calls (run_engine itself is the
# `sudo gsa …` form since the W5 fixture migration — the gate tests here are
# exactly the calls that must NOT be elevated).

source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"
# GSA_FAKE_MAKEPKG_LOG is already in rr-v2's stub vocabulary (one home: the
# table's description); this fixture only reads the knob its stub writes.

fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-priv.XXXXXX")
trap '/usr/bin/sudo -n rm -rf -- "$fixture" 2>/dev/null || rm -rf -- "$fixture" 2>/dev/null || true' EXIT

fail() {
    printf '%s\n' "$1" >&2
    exit 1
}

# The engine under test (rr-v2's resolution): a fixture-built binary or
# `gsa` from PATH.
engine=${GSA_TEST_GSA_BIN:-gsa}

# run_engine_root STATE LOG WORKSPACE [ARG...] — the engine as root through
# real sudo with PATH, GSA_STATE_DIR and the stub log carried explicitly.
# Captures FIXTURE_OUTPUT / FIXTURE_RC like run_engine. SUDO_* stays intact.
run_engine_root() {
    local state=$1 log=$2 ws=$3
    shift 3
    local had_errexit=0
    [[ $- == *e* ]] && had_errexit=1
    set +e
    FIXTURE_OUTPUT=$(cd "$ws" && sudo -n env \
        PATH="$PATH" \
        GSA_STATE_DIR="$state" \
        GSA_BUILD_DIR="${GSA_BUILD_DIR:-$state/../build-cache}" \
        GSA_FAKE_MAKEPKG_LOG="$log" \
        "$engine" "$@" 2>&1)
    FIXTURE_RC=$?
    ((had_errexit)) && set -e
    return 0
}

# run_engine_root_stripped … — the same, minus the sudo identity: a bare
# root shell (the case that must refuse build runs).
run_engine_root_stripped() {
    local state=$1 log=$2 ws=$3
    shift 3
    local had_errexit=0
    [[ $- == *e* ]] && had_errexit=1
    set +e
    FIXTURE_OUTPUT=$(cd "$ws" && sudo -n env -u SUDO_UID -u SUDO_GID -u SUDO_USER \
        PATH="$PATH" \
        GSA_STATE_DIR="$state" \
        GSA_BUILD_DIR="${GSA_BUILD_DIR:-$state/../build-cache}" \
        GSA_FAKE_MAKEPKG_LOG="$log" \
        "$engine" "$@" 2>&1)
    FIXTURE_RC=$?
    ((had_errexit)) && set -e
    return 0
}

# make_ws DIR — the minimal workspace the engine loads (one leaf recipe).
make_ws() {
    local ws=$1
    mkdir -p "$ws/config" "$ws/packages/misc/pkg1"
    printf 'pkg1|packages/misc/pkg1|misc|\n' >"$ws/config/topology.conf"
    {
        echo 'lanes=auto'
        echo 'jobs=2'
        echo 'intensity=low'
        echo 'memory_per_job_gib=1'
        echo 'state_dir=auto'
    } >"$ws/config/build-defaults.conf"
    cat >"$ws/packages/misc/pkg1/PKGBUILD" <<'PKGB'
pkgname=pkg1
pkgver=1.0.0
pkgrel=1
arch=(x86_64)
license=('MIT')
PKGB
    (cd "$ws/packages/misc/pkg1" && GIT_CONFIG_COUNT=0 makepkg --printsrcinfo >.SRCINFO 2>/dev/null) ||
        printf 'pkgbase = pkg1\npkgname = pkg1\npkgver = 1.0.0\npkgrel = 1\narch = x86_64\nlicense = MIT\n' \
            >"$ws/packages/misc/pkg1/.SRCINFO"
}

# make_stubs DIR — stub `makepkg` that records the uid it runs as (the drop
# is the subject of section c) and always succeeds.
make_stubs() {
    local dir=$1
    mkdir -p "$dir"
    cat >"$dir/makepkg" <<'STUB'
#!/usr/bin/env bash
printf 'uid=%s argv=%s\n' "$(id -u)" "$*" >>"${GSA_FAKE_MAKEPKG_LOG:?}"
# W4: the engine passes PKGDEST (the build-user cache); honour it like real
# makepkg does so fixtures can assert the archive location.
id=$(basename "$PWD")
: >"${PKGDEST:-$PWD}/$id-1.0.0-1-any.pkg.tar.zst"
exit 0
STUB
    chmod +x "$dir/makepkg"
}

only=${GSA_PRIV_ONLY:-}

# ── a. unprivileged mutation refuses early, no state created ─────────────
if [ -z "$only" ] || [ "$only" = a ]; then
    (
        ws="$fixture/a/ws"
        state="$fixture/a/state"
        log="$fixture/a/makepkg.log"
        make_ws "$ws"
        make_stubs "$fixture/a/bin"
        PATH="$fixture/a/bin:$PATH" GSA_FAKE_MAKEPKG_LOG="$log" run_engine_user "$ws" -B pkg1 --state-dir "$state"
        [ "$FIXTURE_RC" -eq 3 ] || fail "a: rc=$FIXTURE_RC want 3"
        case $FIXTURE_OUTPUT in
        *'you cannot perform this operation unless you are root'*) ;;
        *) fail "a: refusal message missing: $FIXTURE_OUTPUT" ;;
        esac
        case $FIXTURE_OUTPUT in
        *'sudo gsa'*) ;;
        *) fail "a: the remedy must name sudo: $FIXTURE_OUTPUT" ;;
        esac
        [ ! -e "$state" ] || fail "a: a refused run must not create state"
        [ ! -e "$log" ] || fail "a: a refused run must not build"
    )
fi

# ── b. read-only verbs pass the gate untouched ───────────────────────────
if [ -z "$only" ] || [ "$only" = b ]; then
    (
        ws="$fixture/b/ws"
        make_ws "$ws"
        run_engine_user "$ws" -Sl pkg1
        [ "$FIXTURE_RC" -eq 0 ] || fail "b: rc=$FIXTURE_RC want 0: $FIXTURE_OUTPUT"
        case $FIXTURE_OUTPUT in
        *'unless you are root'*) fail "b: a read must never gate: $FIXTURE_OUTPUT" ;;
        esac
        case $FIXTURE_OUTPUT in
        *pkg1*) ;;
        *) fail "b: listing must name pkg1: $FIXTURE_OUTPUT" ;;
        esac
    )
fi

# ── c. a sudo run drops build-side commands to the build user ────────────
if [ -z "$only" ] || [ "$only" = c ]; then
    (
        ws="$fixture/c/ws"
        state="$fixture/c/state"
        log="$fixture/c/makepkg.log"
        make_ws "$ws"
        make_stubs "$fixture/c/bin"
        PATH="$fixture/c/bin:$PATH" \
            run_engine_root "$state" "$log" "$ws" --lane-job pkg1 "$fixture/c/result.row" 1
        [ -s "$log" ] || fail "c: stub makepkg never ran: $FIXTURE_OUTPUT"
        want=$(id -u)
        got=$(sed -n 's/^uid=\([0-9]*\).*/\1/p' "$log" | head -1)
        [ "$got" = "$want" ] || fail "c: makepkg ran as uid=$got want $want (the drop is broken)"
    )
fi

# ── d. a bare root shell refuses build runs with guidance ────────────────
if [ -z "$only" ] || [ "$only" = d ]; then
    (
        ws="$fixture/d/ws"
        state="$fixture/d/state"
        log="$fixture/d/makepkg.log"
        make_ws "$ws"
        make_stubs "$fixture/d/bin"
        PATH="$fixture/d/bin:$PATH" \
            run_engine_root_stripped "$state" "$log" "$ws" -B pkg1 --state-dir "$state"
        [ "$FIXTURE_RC" -eq 3 ] || fail "d: rc=$FIXTURE_RC want 3"
        case $FIXTURE_OUTPUT in
        *'needs a build user'*) ;;
        *) fail "d: guidance missing: $FIXTURE_OUTPUT" ;;
        esac
        [ ! -e "$state" ] || fail "d: a refused run must not create state"
        [ ! -e "$log" ] || fail "d: a refused run must not build"
    )
fi

# ── e. -Mm refuses under a root supervisor ───────────────────────────────
if [ -z "$only" ] || [ "$only" = e ]; then
    (
        ws="$fixture/e/ws"
        state="$fixture/e/state"
        log="$fixture/e/makepkg.log"
        make_ws "$ws"
        run_engine_root "$state" "$log" "$ws" -Mm
        [ "$FIXTURE_RC" -eq 3 ] || fail "e: rc=$FIXTURE_RC want 3"
        case $FIXTURE_OUTPUT in
        *'must run as the build user'*) ;;
        *) fail "e: the build-user-only refusal is missing: $FIXTURE_OUTPUT" ;;
        esac
    )
fi

# ── f. the fetch half's makepkg drops to the build user too ──────────────
if [ -z "$only" ] || [ "$only" = f ]; then
    (
        ws="$fixture/f/ws"
        state="$fixture/f/state"
        log="$fixture/f/makepkg.log"
        make_ws "$ws"
        make_stubs "$fixture/f/bin"
        # A plain-URL source makes the recipe fetchable (§D.1 candidacy): the
        # -Sw run must reach `makepkg --verifysource`.
        printf "source=('https://example.invalid/pkg1-1.0.0.tar.gz')\n" >>"$ws/packages/misc/pkg1/PKGBUILD"
        printf 'source = https://example.invalid/pkg1-1.0.0.tar.gz\n' >>"$ws/packages/misc/pkg1/.SRCINFO"
        PATH="$fixture/f/bin:$PATH" \
            run_engine_root "$state" "$log" "$ws" -Sw pkg1
        [ "$FIXTURE_RC" = 0 ] || fail "f: the fetch run must succeed (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
        grep -q -- '--verifysource' "$log" || fail "f: stub makepkg never saw --verifysource: $FIXTURE_OUTPUT"
        want=$(id -u)
        got=$(sed -n 's/^uid=\([0-9]*\).*/\1/p' "$log" | head -1)
        [ "$got" = "$want" ] || fail "f: makepkg --verifysource ran as uid=$got want $want (the fetch-half drop is broken)"
    )
fi

# ── g. real build run: banner once, makepkg as the build user ────────────
if [ -z "$only" ] || [ "$only" = g ]; then
    (
        ws="$fixture/g/ws"
        state="$fixture/g/state"
        log="$fixture/g/makepkg.log"
        make_ws "$ws"
        make_stubs "$fixture/g/bin"
        PATH="$fixture/g/bin:$PATH" GSA_BUILD_DIR="$fixture/g/cache" \
            run_engine_root "$state" "$log" "$ws" -B pkg1
        [ -s "$log" ] || fail "g: stub makepkg never ran: $FIXTURE_OUTPUT"
        want=$(id -u)
        got=$(sed -n 's/^uid=\([0-9]*\).*/\1/p' "$log" | head -1)
        [ "$got" = "$want" ] || fail "g: makepkg ran as uid=$got want $want (the drop is broken)"
        n=$(vgrep "$FIXTURE_OUTPUT" -c 'gsa: privileged run:')
        [ "$n" = 1 ] || fail "g: exactly one banner line expected, got $n: $FIXTURE_OUTPUT"
        # W4 (plan test (c)): the archive lands in the build-user cache, not
        # beside the recipe (the stub honours the engine's PKGDEST).
        [ -f "$fixture/g/cache/pkgs/pkg1-1.0.0-1-any.pkg.tar.zst" ] ||
            fail "g: the archive must land in the build cache: $(ls -R "$fixture/g" 2>&1)"
        [ ! -e "$ws/packages/misc/pkg1/pkg1-1.0.0-1-any.pkg.tar.zst" ] ||
            fail "g: the archive must not land beside the recipe"
    )
fi

printf 'gsa-privilege: PASS\n'
