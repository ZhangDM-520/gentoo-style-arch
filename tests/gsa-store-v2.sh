#!/usr/bin/env bash
set -euo pipefail

# tests/gsa-store-v2.sh — the canonical recipe store (plan-gsa-isolation.md
# W3; 2026-10-17 relocation: the BUILD USER's working copy at
# `GSA_RECIPES_DIR` > gsa.conf `recipe_dir` > ~/.local/share/gsa/recipes —
# never below the state root). Hermetic: a fixture-synthesised upstream git
# repo serves as `recipe_url`, GSA_RECIPES_DIR/GSA_STATE_DIR keep the store
# inside $TMPDIR, and `GSA_CONF` replaces the auto-read gsa.conf layers.
# Pinned here (seven ( subshell ) sections, GSA_STORE_ONLY=a…g):
#   a. `-Sy` fetches the store on demand and refreshes it in place into
#      GSA_RECIPES_DIR (fetch note on first use, refresh note + moved HEAD
#      on the second), the tree is owned by the RUN USER (the class pin:
#      root-side git must hand the store to the build user), and the state
#      root grows NO recipes/ dir;
#   b. the `project` config key is authoritative over cwd discovery
#      (a dry-run plan resolves from the configured workspace, not cwd);
#   c. the cwd-discovery deprecation note is TTY-only — a pipe capture is
#      byte-stable (the fixture battery asserts on captured text);
#   d. the gsa.conf `recipe_dir` key is the second store seam (a fetch
#      lands there when GSA_RECIPES_DIR is unset);
#   e. one-shot migration: a legacy <state>/recipes — root-owned and with a
#      dirty worktree, like production — MOVES to the resolved store (the
#      dirty markers survive, the legacy location is gone, the tree is
#      handed to the run user, one loud note prints);
#   f. both trees present: the resolved store wins, the stale legacy tree
#      is noted and NEVER deleted;
#   g. no workspace anywhere and no store: the failing read teaches the
#      store-era remedy (never the retired cwd-only hint).
#
# Sections a/d/e/f run the engine through real `sudo -n` (fetch and
# migration are root-side mutations; W5 convention: root-safe trap,
# absolute /usr/bin/sudo for cleanup).

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
        GSA_RECIPES_DIR="${GSA_RECIPES_DIR-$state/../recipe-store}" \
        "$engine" "$@" 2>&1)
    FIXTURE_RC=$?
    ((had_errexit)) && set -e
    return 0
}

# ── a. fetch-on-demand + in-place refresh into GSA_RECIPES_DIR ──────────
if [ -z "$only" ] || [ "$only" = a ]; then
    (
        set -euo pipefail
        up="$fixture/a/upstream"
        state="$fixture/a/state"
        store="$fixture/a/recipe-store"
        conf="$fixture/a/gsa.conf"
        empty="$fixture/a/empty"
        mkdir -p "$empty"
        make_upstream "$up"
        printf 'recipe_url = %s\n' "$up" >"$conf"
        export GSA_RECIPES_DIR="$store"

        run_store "$state" "$conf" "$empty" -Sy
        [ "$FIXTURE_RC" = 0 ] || fail "a: first -Sy must succeed (rc $FIXTURE_RC): $FIXTURE_OUTPUT"
        case $FIXTURE_OUTPUT in
        *"recipe store fetched:"*|*"recipe store refreshed:"*) ;;
        *) fail "a: the fetch must be announced: $FIXTURE_OUTPUT" ;;
        esac
        [ -f "$store/config/topology.conf" ] ||
            fail "a: the store must land at GSA_RECIPES_DIR: $FIXTURE_OUTPUT"
        # --state-dir no longer implies the store location (design B)
        [ ! -e "$state/recipes" ] ||
            fail "a: the state root must not grow a recipes/ dir: $FIXTURE_OUTPUT"
        # the class pin: root-side git hands the whole tree to the build
        # user (= the user who invoked sudo), recursively
        run_user=$(id -u)
        [ "$(stat -c %u "$store")" = "$run_user" ] ||
            fail "a: the store root must be owned by the run user ($run_user), got $(stat -c %u "$store")"
        [ "$(stat -c %u "$store/config/topology.conf")" = "$run_user" ] ||
            fail "a: the store tree must be owned by the run user recursively"

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
        [ -f "$store/UPSTREAM-MOVE" ] ||
            fail "a: the store must track upstream's new commit: $FIXTURE_OUTPUT"
        [ "$(stat -c %u "$store/UPSTREAM-MOVE")" = "$run_user" ] ||
            fail "a: the refreshed tree must stay owned by the run user"
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
        rc=0
        FIXTURE_OUTPUT=$(cd "$ws" && GSA_CONF="$conf" "$engine" -B --dry-run alpha 2>&1) || rc=$?
        [ "$rc" -eq 0 ] || fail "c: the dry-run must succeed, rc=$rc: $FIXTURE_OUTPUT"
        case $FIXTURE_OUTPUT in
        *deprecated*) fail "c: the deprecation note must stay TTY-only: $FIXTURE_OUTPUT" ;;
        esac
        case $FIXTURE_OUTPUT in
        *alpha*) ;;
        *) fail "c: cwd discovery must still work: $FIXTURE_OUTPUT" ;;
        esac
    )
fi

# ── d. the gsa.conf `recipe_dir` key resolves the store ─────────────────
if [ -z "$only" ] || [ "$only" = d ]; then
    (
        set -euo pipefail
        up="$fixture/d/upstream"
        state="$fixture/d/state"
        store="$fixture/d/conf-store"
        conf="$fixture/d/gsa.conf"
        empty="$fixture/d/empty"
        mkdir -p "$empty"
        make_upstream "$up"
        printf 'recipe_url = %s\nrecipe_dir = %s\n' "$up" "$store" >"$conf"
        # Explicitly empty: the env seam is UNSET here so the conf key is
        # what resolves (env > conf > default).
        export GSA_RECIPES_DIR=""

        run_store "$state" "$conf" "$empty" -Sy
        [ "$FIXTURE_RC" = 0 ] || fail "d: -Sy must succeed (rc $FIXTURE_RC): $FIXTURE_OUTPUT"
        [ -f "$store/config/topology.conf" ] ||
            fail "d: the store must land at the recipe_dir value: $FIXTURE_OUTPUT"
        [ ! -e "$state/recipes" ] ||
            fail "d: the state root must not grow a recipes/ dir: $FIXTURE_OUTPUT"
        [ "$(stat -c %u "$store")" = "$(id -u)" ] ||
            fail "d: the store must be owned by the run user"
    )
fi

# ── e. one-shot migration of a legacy <state>/recipes ───────────────────
if [ -z "$only" ] || [ "$only" = e ]; then
    (
        set -euo pipefail
        up="$fixture/e/upstream"
        state="$fixture/e/state"
        store="$fixture/e/recipe-store"
        conf="$fixture/e/gsa.conf"
        empty="$fixture/e/empty"
        mkdir -p "$empty"
        make_upstream "$up"
        printf 'recipe_url = %s\n' "$up" >"$conf"
        export GSA_RECIPES_DIR="$store"

        # Production shape: the pre-relocation store sits under the state
        # root, root-owned, carrying uncommitted sync rewrites (a modified
        # tracked file) plus debris (an untracked marker).
        mkdir -p "$state"
        git clone -q "$up" "$state/recipes" || fail "e: cannot seed the legacy store"
        printf '\n# fixture dirty worktree marker\n' >>"$state/recipes/packages/alpha/PKGBUILD"
        printf 'uncommitted sync rewrite stand-in\n' >"$state/recipes/DIRTY-MARKER"
        /usr/bin/sudo -n chown -R root:root "$state/recipes" ||
            fail "e: cannot shape the legacy store root-owned"

        run_store "$state" "$conf" "$empty" -B --dry-run alpha
        [ "$FIXTURE_RC" = 0 ] ||
            fail "e: the run must resolve through the migrated store (rc $FIXTURE_RC): $FIXTURE_OUTPUT"
        case $FIXTURE_OUTPUT in
        *"recipe store moved to $store"*) ;;
        *) fail "e: the move must be announced loudly: $FIXTURE_OUTPUT" ;;
        esac
        [ -d "$store/.git" ] || fail "e: .git must survive the move"
        [ -f "$store/DIRTY-MARKER" ] ||
            fail "e: the uncommitted marker must survive the move: $FIXTURE_OUTPUT"
        grep -F 'fixture dirty worktree marker' "$store/packages/alpha/PKGBUILD" >/dev/null ||
            fail "e: the dirty tracked rewrite must survive the move"
        [ ! -e "$state/recipes" ] ||
            fail "e: the legacy location must be gone after the move"
        [ "$(stat -c %u "$store")" = "$(id -u)" ] ||
            fail "e: the migrated store must be owned by the run user, got $(stat -c %u "$store")"
    )
fi

# ── f. both trees present: the resolved store wins, the stale one stays ─
if [ -z "$only" ] || [ "$only" = f ]; then
    (
        set -euo pipefail
        up="$fixture/f/upstream"
        state="$fixture/f/state"
        store="$fixture/f/recipe-store"
        conf="$fixture/f/gsa.conf"
        empty="$fixture/f/empty"
        mkdir -p "$empty"
        make_upstream "$up"
        printf 'recipe_url = %s\n' "$up" >"$conf"
        export GSA_RECIPES_DIR="$store"

        git clone -q "$up" "$state/recipes" || fail "f: cannot seed the legacy store"
        git clone -q "$up" "$store" || fail "f: cannot seed the resolved store"
        printf 'stale legacy stand-in\n' >"$state/recipes/STALE-MARKER"
        # A malformed legacy topology is the usage discriminator: resolving
        # from the legacy tree would break every command.
        printf 'garbage record\n' >"$state/recipes/config/topology.conf"

        run_store "$state" "$conf" "$empty" -B --dry-run alpha
        [ "$FIXTURE_RC" = 0 ] ||
            fail "f: the resolved store must be the workspace (rc $FIXTURE_RC): $FIXTURE_OUTPUT"
        case $FIXTURE_OUTPUT in
        *alpha*) ;;
        *) fail "f: the plan must resolve from the resolved store: $FIXTURE_OUTPUT" ;;
        esac
        case $FIXTURE_OUTPUT in
        *"was left in place"*) ;;
        *) fail "f: the stale legacy tree must be noted: $FIXTURE_OUTPUT" ;;
        esac
        [ -f "$state/recipes/STALE-MARKER" ] ||
            fail "f: the stale legacy tree must never be deleted"
        [ ! -e "$store/STALE-MARKER" ] ||
            fail "f: the resolved store must not inherit the legacy tree's files"
    )
fi

# ── g. no workspace anywhere: the store-era remedy is what gets taught ──
if [ -z "$only" ] || [ "$only" = g ]; then
    (
        set -euo pipefail
        state="$fixture/g/state"
        store="$fixture/g/recipe-store"
        conf="$fixture/g/gsa.conf"
        empty="$fixture/g/empty"
        mkdir -p "$empty"
        : >"$conf"
        export GSA_RECIPES_DIR="$store"

        # A read path (fetch disabled) from a non-workspace cwd: nothing to
        # discover, nothing fetched.
        rc=0
        FIXTURE_OUTPUT=$(cd "$empty" && GSA_CONF="$conf" GSA_STATE_DIR="$state" \
            GSA_RECIPES_DIR="$store" "$engine" -Sl @core 2>&1) || rc=$?
        [ "$rc" = 2 ] || fail "g: a not-found workspace is a usage error (rc $rc): $FIXTURE_OUTPUT"
        case $FIXTURE_OUTPUT in
        *"cannot find a recipe workspace: set \`project\` in gsa.conf"*) ;;
        *) fail "g: the store-era remedy must be taught: $FIXTURE_OUTPUT" ;;
        esac
        case $FIXTURE_OUTPUT in
        *"fetch the store with \`sudo gsa -Sy\`"*) ;;
        *) fail "g: the remedy must name the store fetch: $FIXTURE_OUTPUT" ;;
        esac
        if printf '%s' "$FIXTURE_OUTPUT" | grep -F \
            'cannot find config/topology.conf from the current directory upward' >/dev/null; then
            fail "g: the retired cwd-only hint must be gone: $FIXTURE_OUTPUT"
        fi

        # The same remedy from the --qa-check discovery path (qa.rs).
        rc=0
        FIXTURE_OUTPUT=$(cd "$empty" && GSA_CONF="$conf" GSA_STATE_DIR="$state" \
            GSA_RECIPES_DIR="$store" "$engine" --qa-check provides-versioning 2>&1) || rc=$?
        [ "$rc" = 2 ] || fail "g: --qa-check with no workspace exits 2 (rc $rc): $FIXTURE_OUTPUT"
        case $FIXTURE_OUTPUT in
        *"cannot find a recipe workspace: set \`project\` in gsa.conf"*) ;;
        *) fail "g: --qa-check must teach the store-era remedy: $FIXTURE_OUTPUT" ;;
        esac

        # The topology loader's not-found path (a `project` pointing at a
        # non-workspace) renders the shared wording too.
        printf 'project = %s\n' "$fixture/g/not-a-workspace" >"$conf"
        rc=0
        FIXTURE_OUTPUT=$(cd "$empty" && GSA_CONF="$conf" GSA_STATE_DIR="$state" \
            GSA_RECIPES_DIR="$store" "$engine" -Sl @core 2>&1) || rc=$?
        [ "$rc" = 2 ] || fail "g: a broken `project` exits 2 (rc $rc): $FIXTURE_OUTPUT"
        case $FIXTURE_OUTPUT in
        *"topology file not found"*"set \`project\` in gsa.conf"*) ;;
        *) fail "g: the topology not-found error must teach the store-era remedy: $FIXTURE_OUTPUT" ;;
        esac
    )
fi

printf 'gsa-store-v2: ok\n'
