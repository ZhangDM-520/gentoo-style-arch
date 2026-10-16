#!/usr/bin/env bash
set -euo pipefail

# tests/gsa-store-v2.sh — the canonical recipe store (plan-gsa-isolation.md
# W3). Hermetic: a fixture-synthesised upstream git repo serves as
# `recipe_url`, `GSA_STATE_DIR` keeps the store inside $TMPDIR, and
# `GSA_CONF` replaces the auto-read gsa.conf layers. Pinned here (three
# ( subshell ) sections, GSA_STORE_ONLY=a…c):
#   a. `-Sy` fetches the store on demand and refreshes it in place
#      (fetch note on first use, refresh note + moved HEAD on the second);
#   b. the `project` config key is authoritative over cwd discovery
#      (a dry-run plan resolves from the configured workspace, not cwd);
#   c. the cwd-discovery deprecation note is TTY-only — a pipe capture is
#      byte-stable (the fixture battery asserts on captured text).
#
# Sections a runs the engine through real `sudo -n` (the store is root-owned
# state, W5 convention: root-safe trap, absolute /usr/bin/sudo for cleanup).

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"

fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-store-v2.XXXXXX")
trap '/usr/bin/sudo -n rm -rf -- "$fixture" 2>/dev/null || rm -rf -- "$fixture" 2>/dev/null || true' EXIT

engine=${GSA_TEST_GSA_BIN:-gsa}
only=${GSA_STORE_ONLY:-}

fail() {
    printf 'gsa-store-v2 fixture: %s\n' "$1" >&2
    exit 1
}

# make_upstream DIR — a synthetic recipe repo committed to git (the store's
# fetch source; a local path is a valid `git clone` URL).
make_upstream() {
    local dir=$1
    make_workspace "$dir" 1 auto low
    add_package "$dir" alpha "$gsa_meta_any"
    (cd "$dir" && git init -q -b main . &&
        git -c user.name=fixture -c user.email=fixture@invalid add -A &&
        git -c user.name=fixture -c user.email=fixture@invalid commit -qm "fixture upstream") ||
        fail "cannot commit the fixture upstream"
}

run_store() { # STATE CONF DIR ARG... — the engine as root through real sudo
    local state=$1 conf=$2 dir=$3
    shift 3
    local had_errexit=0
    [[ $- == *e* ]] && had_errexit=1
    set +e
    FIXTURE_OUTPUT=$(cd "$dir" && /usr/bin/sudo -n env \
        PATH="$PATH" GSA_STATE_DIR="$state" GSA_CONF="$conf" \
        GSA_BUILD_DIR="${GSA_BUILD_DIR:-$state/../build-cache}" \
        "$engine" "$@" 2>&1)
    FIXTURE_RC=$?
    ((had_errexit)) && set -e
    return 0
}

# ── a. fetch-on-demand + in-place refresh ───────────────────────────────
if [ -z "$only" ] || [ "$only" = a ]; then
    (
        set -euo pipefail
        up="$fixture/a/upstream"
        state="$fixture/a/state"
        conf="$fixture/a/gsa.conf"
        empty="$fixture/a/empty"
        mkdir -p "$empty"
        make_upstream "$up"
        printf 'recipe_url = %s\n' "$up" >"$conf"

        run_store "$state" "$conf" "$empty" -Sy
        [ "$FIXTURE_RC" = 0 ] || fail "a: first -Sy must succeed (rc $FIXTURE_RC): $FIXTURE_OUTPUT"
        case $FIXTURE_OUTPUT in
        *"recipe store fetched:"*|*"recipe store refreshed:"*) ;;
        *) fail "a: the fetch must be announced: $FIXTURE_OUTPUT" ;;
        esac
        [ -f "$state/recipes/config/topology.conf" ] ||
            fail "a: the store must land at <state>/recipes: $FIXTURE_OUTPUT"

        up_head=$(git -C "$up" rev-parse HEAD)
        # upstream moves between runs — the refresh must follow it
        printf 'second\n' >"$up/UPSTREAM-MOVE"
        (cd "$up" && git -c user.name=fixture -c user.email=fixture@invalid add -A &&
            git -c user.name=fixture -c user.email=fixture@invalid commit -qm "move") ||
            fail "a: cannot move the fixture upstream"
        up_head=$(git -C "$up" rev-parse HEAD)
        run_store "$state" "$conf" "$empty" -Sy
        [ "$FIXTURE_RC" = 0 ] || fail "a: second -Sy must succeed: $FIXTURE_OUTPUT"
        case $FIXTURE_OUTPUT in
        *"recipe store refreshed: $up_head"*) ;;
        *) fail "a: the refresh must announce the upstream HEAD: $FIXTURE_OUTPUT" ;;
        esac
        [ -f "$state/recipes/UPSTREAM-MOVE" ] ||
            fail "a: the store must track upstream's new commit: $FIXTURE_OUTPUT"
    )
fi

# ── b. the project config key beats cwd discovery ──────────────────────
if [ -z "$only" ] || [ "$only" = b ]; then
    (
        set -euo pipefail
        ws1="$fixture/b/ws1"
        ws2="$fixture/b/ws2"
        conf="$fixture/b/gsa.conf"
        make_workspace "$ws1" 1 auto low
        add_package "$ws1" alpha "$gsa_meta_any"
        make_workspace "$ws2" 1 auto low
        add_package "$ws2" beta "$gsa_meta_any"
        printf 'project = %s\n' "$ws1" >"$conf"

        # Unprivileged: --dry-run plans are read-only (§B.10).
        FIXTURE_OUTPUT=$(cd "$ws2" && GSA_CONF="$conf" "$engine" -B --dry-run alpha 2>&1) || FIXTURE_RC=$?
        case $FIXTURE_OUTPUT in
        *alpha*) ;;
        *) fail "b: the configured workspace must resolve alpha: $FIXTURE_OUTPUT" ;;
        esac
        case $FIXTURE_OUTPUT in
        *beta*) fail "b: cwd must not leak into the configured workspace: $FIXTURE_OUTPUT" ;;
        esac
        if FIXTURE_OUTPUT=$(cd "$ws2" && GSA_CONF="$conf" "$engine" -B --dry-run beta 2>&1); then
            fail "b: beta lives only in cwd (unconfigured): $FIXTURE_OUTPUT"
        fi
    )
fi

# ── c. the cwd deprecation note never reaches a pipe ────────────────────
if [ -z "$only" ] || [ "$only" = c ]; then
    (
        set -euo pipefail
        ws="$fixture/c/ws"
        conf="$fixture/c/gsa.conf"
        make_workspace "$ws" 1 auto low
        add_package "$ws" alpha "$gsa_meta_any"
        : >"$conf"
        FIXTURE_OUTPUT=$(cd "$ws" && GSA_CONF="$conf" "$engine" -B --dry-run alpha 2>&1) || true
        case $FIXTURE_OUTPUT in
        *deprecated*) fail "c: the deprecation note must stay TTY-only: $FIXTURE_OUTPUT" ;;
        esac
        case $FIXTURE_OUTPUT in
        *alpha*) ;;
        *) fail "c: cwd discovery must still work: $FIXTURE_OUTPUT" ;;
        esac
    )
fi

printf 'gsa-store-v2: ok\n'
