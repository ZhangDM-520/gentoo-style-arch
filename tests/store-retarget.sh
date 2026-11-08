#!/usr/bin/env bash
set -euo pipefail

# tests/store-retarget.sh — a `recipe_url` change takes effect on the next
# `gsa -Sy`. The store clone honoured the URL only on FIRST use; a refresh
# kept fetching whatever `origin` the checkout already had, so repointing
# `DEFAULT_RECIPE_URL` (or `recipe_url` in gsa.conf) left an existing store
# tracking the old repository — silently. Pinned here:
#   a. the first `-Sy` clones from the configured URL (no retarget line);
#   b. repointing `recipe_url` retargets `origin`, follows the NEW upstream's
#      HEAD, and reports it on ONE `gsa: recipe store origin retargeted:` line;
#   c. the next `-Sy` with the same URL runs the plain fetch/reset — silent.
#
# Hermetic: two fixture-synthesised upstream repositories under $TMPDIR,
# GSA_RECIPES_DIR/GSA_STATE_DIR keep the store and state inside the fixture,
# `GSA_CONF` replaces the auto-read gsa.conf layers. The refresh is a
# root-side mutation, so the engine runs through real `sudo -n` (the
# gsa-store-v2 convention, including its root-safe cleanup trap).

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"

fixture=$(mktemp -d "${TMPDIR:-/tmp}/store-retarget.XXXXXX")
trap '/usr/bin/sudo -n rm -rf -- "$fixture" 2>/dev/null || rm -rf -- "$fixture" 2>/dev/null || true' EXIT

engine=${GSA_TEST_GSA_BIN:-gsa}

fail() {
    printf 'store-retarget fixture: %s\n' "$1" >&2
    exit 1
}

# make_upstream DIR ID — a synthetic one-package recipe repo committed to git
# (a local path is a valid `git clone` URL for the store).
make_upstream() {
    local dir=$1 id=$2
    make_workspace "$dir" 1 auto low
    add_package "$dir" "$id" "$gsa_meta_any"
    (
        cd "$dir" && git init -q -b main . &&
            git -c user.name=fixture -c user.email=fixture@invalid add -A &&
            git -c user.name=fixture -c user.email=fixture@invalid commit -qm "fixture $id"
    ) || fail "cannot commit the fixture upstream $id"
}

run_sync() { # STATE CONF DIR — `gsa -Sy` as root, output in FIXTURE_OUTPUT
    local state=$1 conf=$2 dir=$3
    local had_errexit=0
    [[ $- == *e* ]] && had_errexit=1
    set +e
    FIXTURE_OUTPUT=$(cd "$dir" && /usr/bin/sudo -n env \
        PATH="$PATH" GSA_STATE_DIR="$state" GSA_CONF="$conf" \
        GSA_BUILD_DIR="$state/../build-cache" \
        GSA_RECIPES_DIR="$state/../recipe-store" \
        "$engine" -Sy 2>&1)
    FIXTURE_RC=$?
    ((had_errexit)) && set -e
    return 0
}

(
    set -euo pipefail
    up_one="$fixture/one"
    up_two="$fixture/two"
    state="$fixture/state"
    store="$fixture/recipe-store"
    conf="$fixture/gsa.conf"
    empty="$fixture/empty"
    mkdir -p "$empty"
    make_upstream "$up_one" alpha
    make_upstream "$up_two" beta
    printf 'recipe_url = %s\n' "$up_one" >"$conf"

    # a. first use clones from the configured URL — nothing to retarget yet
    run_sync "$state" "$conf" "$empty"
    [ "$FIXTURE_RC" = 0 ] || fail "a: the first -Sy must succeed (rc $FIXTURE_RC): $FIXTURE_OUTPUT"
    [ "$(git -C "$store" config --get remote.origin.url)" = "$up_one" ] ||
        fail "a: the store must be cloned from recipe_url: $FIXTURE_OUTPUT"
    if grep -F 'origin retargeted' <<<"$FIXTURE_OUTPUT" >/dev/null; then
        fail "a: a matching origin must not be retargeted: $FIXTURE_OUTPUT"
    fi

    # b. repointing recipe_url must retarget the existing store
    printf 'recipe_url = %s\n' "$up_two" >"$conf"
    up_two_head=$(git -C "$up_two" rev-parse HEAD)
    run_sync "$state" "$conf" "$empty"
    [ "$FIXTURE_RC" = 0 ] || fail "b: the repointed -Sy must succeed (rc $FIXTURE_RC): $FIXTURE_OUTPUT"
    grep -F "gsa: recipe store origin retargeted: $up_one → $up_two" <<<"$FIXTURE_OUTPUT" >/dev/null ||
        fail "b: the retarget must be reported on one gsa: line: $FIXTURE_OUTPUT"
    [ "$(git -C "$store" config --get remote.origin.url)" = "$up_two" ] ||
        fail "b: origin must be re-pointed at the new recipe_url: $FIXTURE_OUTPUT"
    [ "$(git -C "$store" rev-parse HEAD)" = "$up_two_head" ] ||
        fail "b: the store must check out the NEW upstream's HEAD: $FIXTURE_OUTPUT"
    [ -d "$store/packages/beta" ] ||
        fail "b: the store must carry the new upstream's recipes: $FIXTURE_OUTPUT"
    grep -F "recipe store refreshed: $up_two_head" <<<"$FIXTURE_OUTPUT" >/dev/null ||
        fail "b: the refresh must still announce the new HEAD: $FIXTURE_OUTPUT"

    # c. same URL again: plain fetch/reset, silent about the origin
    run_sync "$state" "$conf" "$empty"
    [ "$FIXTURE_RC" = 0 ] || fail "c: the repeat -Sy must succeed (rc $FIXTURE_RC): $FIXTURE_OUTPUT"
    if grep -F 'origin retargeted' <<<"$FIXTURE_OUTPUT" >/dev/null; then
        fail "c: an agreeing origin must print nothing: $FIXTURE_OUTPUT"
    fi
    [ "$(git -C "$store" config --get remote.origin.url)" = "$up_two" ] ||
        fail "c: the origin must stay on the current recipe_url: $FIXTURE_OUTPUT"
)
