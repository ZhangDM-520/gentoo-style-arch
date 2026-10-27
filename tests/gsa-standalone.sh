#!/usr/bin/env bash
set -euo pipefail

# tests/gsa-standalone.sh — standalone-PKGBUILD target input
# (plan-gsa-isolation.md W4's distribution unit: "stage → build → index").
# Hermetic: every workspace and state root is a $TMPDIR scratch tree, the
# auto-read gsa.conf layers are replaced by an empty GSA_CONF, and section d
# builds through a stub makepkg — the real /var/lib/gsa and the host's
# pacman.conf are never read or written.
#
# Pinned here (six ( subshell ) sections, run one alone with
# GSA_STANDALONE_ONLY=a…f):
#   a. a directory holding a PKGBUILD is staged as its own one-node workspace
#      and the run record names the staged id; a --dry-run stages EPHEMERALLY
#      (no state left behind — §B.10 reads);
#   b. a bare PKGBUILD file is the same input (staged id = the file's parent
#      directory name);
#   c. a run cannot mix standalone targets and workspace references (rc 2),
#      and query/report verbs do not take standalone targets yet (rc 2);
#   d. a real `sudo gsa -B <dir>` run with no project clone: stage → build →
#      index — the run record names the staged id, the archive lands in the
#      build-user cache (GSA_BUILD_DIR/pkgs, never beside the recipe), the
#      binpkg index records the instance, and the staging area persists
#      under <state>/standalone/;
#   e. a URL target (file:// — the network-free curl seam) is fetched and
#      staged like a local PKGBUILD;
#   f. a discoverable workspace root's shared `lib/` (lib/pgo.sh,
#      lib/cups-config) is staged into the one-node workspace — the shared
#      PGO gate is sourced by a repo-relative path and a standalone
#      shared-gate recipe must not hard-fail at PKGBUILD parse (S5).
#
# House conventions: ( subshell ) sections with their own workspace and state
# root, inline stubs and oracles, fail() prefixes, rr-v2.bash's
# run_engine_user for unprivileged calls and run_engine for the `sudo gsa …`
# form (section d). Sections a–c/e are --dry-run reads and run as a plain
# user; section d builds and goes through real `sudo -n` (root-safe trap).

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"

fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-standalone.XXXXXX")
trap '/usr/bin/sudo -n rm -rf -- "$fixture" 2>/dev/null || rm -rf -- "$fixture" 2>/dev/null || true' EXIT

engine=${GSA_TEST_GSA_BIN:-gsa}
only=${GSA_STANDALONE_ONLY:-}

fail() {
    printf 'gsa-standalone fixture: %s\n' "$1" >&2
    exit 1
}

# An empty gsa.conf: the auto-read layers (/etc/gsa.conf, ~/.config/…) must
# never steer a fixture (§J.3 hermeticity — a host `project` key would answer
# the standalone/workspace disambiguation probe).
conf="$fixture/gsa.conf"
: >"$conf"

# make_recipe DIR NAME — the shared recipe: a PKGBUILD only (the distribution
# unit), plus makepkg's output noise beside it to prove staging drops it.
make_recipe() {
    local dir=$1 name=$2
    mkdir -p "$dir/src" "$dir/pkg"
    cat >"$dir/PKGBUILD" <<PKGB
pkgname=$name
pkgver=1.0.0
pkgrel=1
arch=(any)
license=('MIT')
PKGB
    : >"$dir/src/leftover"
    : >"$dir/pkg/leftover"
    : >"$dir/$name-1.0.0-1-any.pkg.tar.zst"
}

# make_stubs DIR — stub makepkg that records the uid it runs as and leaves
# the REAL archive makepkg would (a .pkg.tar.zst with a .PKGINFO — archive
# discovery is truth-filtered, a zero-byte stand-in never indexes).
make_stubs() {
    local dir=$1
    mkdir -p "$dir"
    cat >"$dir/makepkg" <<'STUB'
#!/usr/bin/env bash
set -eu
printf 'uid=%s argv=%s\n' "$(id -u)" "$*" >>"${GSA_FAKE_MAKEPKG_LOG:?}"
id=$(basename "$PWD")
case " $* " in
*" --verifysource "*) exit 0 ;;
*" --printsrcinfo "*)
    printf 'pkgbase = %s\npkgname = %s\npkgver = 1.0.0\npkgrel = 1\narch = any\n' "$id" "$id"
    exit 0
    ;;
esac
stage="$PWD/.stage-$id"
mkdir -p "$stage"
{
    printf 'pkgbase = %s\n' "$id"
    printf 'pkgname = %s\n' "$id"
    printf 'pkgver = 1.0.0-1\n'
    printf 'arch = any\n'
} >"$stage/.PKGINFO"
tar --zstd -cf "${PKGDEST:-$PWD}/$id-1.0.0-1-any.pkg.tar.zst" -C "$stage" .PKGINFO
rm -rf "$stage"
exit 0
STUB
    chmod +x "$dir/makepkg"
}

# ── a. directory target: staged id in the record, dry run is stateless ───
if [ -z "$only" ] || [ "$only" = a ]; then
    (
        ws="$fixture/a/empty-cwd"
        state="$fixture/a/state"
        mkdir -p "$ws"
        make_recipe "$fixture/a/shared/solo-recipe" solo-recipe
        GSA_CONF="$conf" GSA_STATE_DIR="$state" run_engine_user "$ws" \
            -B --dry-run "$fixture/a/shared/solo-recipe"
        [ "$FIXTURE_RC" -eq 0 ] || fail "a: rc=$FIXTURE_RC want 0: $FIXTURE_OUTPUT"
        case $FIXTURE_OUTPUT in
        *'staged standalone target'*"'solo-recipe'"*) ;;
        *) fail "a: the staging note must name the staged id: $FIXTURE_OUTPUT" ;;
        esac
        case $FIXTURE_OUTPUT in
        *'order: solo-recipe'*) ;;
        *) fail "a: the run record must name the staged id: $FIXTURE_OUTPUT" ;;
        esac
        case $FIXTURE_OUTPUT in
        *'solo-recipe build'*) ;;
        *) fail "a: the plan must carry a row for the staged id: $FIXTURE_OUTPUT" ;;
        esac
        # Ephemeral staging: a dry run writes no state at all (§B.10).
        [ ! -e "$state" ] || fail "a: a dry run must leave no state: $(ls -R "$state" 2>&1)"
    )
fi

# ── b. bare PKGBUILD file target ─────────────────────────────────────────
if [ -z "$only" ] || [ "$only" = b ]; then
    (
        ws="$fixture/b/empty-cwd"
        state="$fixture/b/state"
        mkdir -p "$ws"
        make_recipe "$fixture/b/shared/file-pkg" file-pkg
        GSA_CONF="$conf" GSA_STATE_DIR="$state" run_engine_user "$ws" \
            -B --dry-run "$fixture/b/shared/file-pkg/PKGBUILD"
        [ "$FIXTURE_RC" -eq 0 ] || fail "b: rc=$FIXTURE_RC want 0: $FIXTURE_OUTPUT"
        # The staged id is the PKGBUILD's parent directory name.
        case $FIXTURE_OUTPUT in
        *'order: file-pkg'*) ;;
        *) fail "b: the run record must name the parent-dir id: $FIXTURE_OUTPUT" ;;
        esac
    )
fi

# ── c. mixed targets refuse; query verbs do not take standalone ──────────
if [ -z "$only" ] || [ "$only" = c ]; then
    (
        ws="$fixture/c/ws"
        state="$fixture/c/state"
        make_workspace "$ws" 1 auto low
        add_package "$ws" ws-pkg "pkgver=1.0.0" misc
        make_recipe "$fixture/c/shared/solo-recipe" solo-recipe
        GSA_CONF="$conf" GSA_STATE_DIR="$state" run_engine_user "$ws" \
            -B --dry-run "$fixture/c/shared/solo-recipe" ws-pkg
        [ "$FIXTURE_RC" -eq 2 ] || fail "c: mixed rc=$FIXTURE_RC want 2: $FIXTURE_OUTPUT"
        case $FIXTURE_OUTPUT in
        *'cannot be combined with workspace references'*) ;;
        *) fail "c: the mixed-target refusal is missing: $FIXTURE_OUTPUT" ;;
        esac
        # A query verb refuses the standalone shape (v1: report verbs read a
        # workspace) — never a staging note, never a state write.
        GSA_CONF="$conf" GSA_STATE_DIR="$state" run_engine_user "$ws" \
            -Qi "$fixture/c/shared/solo-recipe"
        [ "$FIXTURE_RC" -eq 2 ] || fail "c: query rc=$FIXTURE_RC want 2: $FIXTURE_OUTPUT"
        case $FIXTURE_OUTPUT in
        *'standalone targets are not supported'*) ;;
        *) fail "c: the unsupported-verb refusal is missing: $FIXTURE_OUTPUT" ;;
        esac
        [ ! -e "$state" ] || fail "c: a refused run must leave no state"
    )
fi

# ── d. real run: stage → build → index, no project clone ─────────────────
if [ -z "$only" ] || [ "$only" = d ]; then
    (
        ws="$fixture/d/empty-cwd"
        state="$fixture/d/state"
        cache="$fixture/d/cache"
        log="$fixture/d/makepkg.log"
        mkdir -p "$ws"
        make_recipe "$fixture/d/shared/solo-recipe" solo-recipe
        make_stubs "$fixture/d/bin"
        PATH="$fixture/d/bin:$PATH" GSA_CONF="$conf" GSA_STATE_DIR="$state" \
            GSA_BUILD_DIR="$cache" GSA_FAKE_MAKEPKG_LOG="$log" \
            run_engine "$ws" -B "$fixture/d/shared/solo-recipe"
        [ "$FIXTURE_RC" -eq 0 ] || fail "d: rc=$FIXTURE_RC want 0: $FIXTURE_OUTPUT"
        [ -s "$log" ] || fail "d: stub makepkg never ran: $FIXTURE_OUTPUT"
        case $FIXTURE_OUTPUT in
        *'order: solo-recipe'*) ;;
        *) fail "d: the run record must name the staged id: $FIXTURE_OUTPUT" ;;
        esac
        # The archive lands in the build-user cache, never beside the recipe
        # (W4's PKGDEST relocation).
        [ -f "$cache/pkgs/solo-recipe-1.0.0-1-any.pkg.tar.zst" ] ||
            fail "d: the archive must land in the build cache: $(ls -R "$fixture/d" 2>&1)"
        [ ! -e "$state/standalone/packages/misc/solo-recipe/solo-recipe-1.0.0-1-any.pkg.tar.zst" ] ||
            fail "d: the archive must not land beside the staged recipe"
        # "index": the post-build hook registers the instance (§J.4).
        grep -rq 'solo-recipe' "$state/index" 2>/dev/null ||
            fail "d: the binpkg index must record the staged id: $(ls -R "$state" 2>&1)"
        # Persistent staging is the recipe work area: it stays after the run.
        [ -f "$state/standalone/config/topology.conf" ] ||
            fail "d: the staged workspace must persist under <state>/standalone"
        [ -f "$state/standalone/packages/misc/solo-recipe/PKGBUILD" ] ||
            fail "d: the staged recipe must persist"
        [ ! -e "$state/standalone/packages/misc/solo-recipe/src" ] ||
            fail "d: makepkg output trees must not be staged"
        [ ! -e "$state/standalone/packages/misc/solo-recipe/solo-recipe-1.0.0-1-any.pkg.tar.zst" ] ||
            fail "d: old archives must not be staged"
    )
fi

# ── e. URL target (file:// — the network-free curl seam) ─────────────────
if [ -z "$only" ] || [ "$only" = e ]; then
    (
        ws="$fixture/e/empty-cwd"
        state="$fixture/e/state"
        mkdir -p "$ws"
        make_recipe "$fixture/e/shared/url-pkg" url-pkg
        GSA_CONF="$conf" GSA_STATE_DIR="$state" run_engine_user "$ws" \
            -B --dry-run "file://$fixture/e/shared/url-pkg/PKGBUILD"
        [ "$FIXTURE_RC" -eq 0 ] || fail "e: rc=$FIXTURE_RC want 0: $FIXTURE_OUTPUT"
        # The staged id is the URL path segment before the PKGBUILD leaf.
        case $FIXTURE_OUTPUT in
        *'order: url-pkg'*) ;;
        *) fail "e: the run record must name the URL-derived id: $FIXTURE_OUTPUT" ;;
        esac
    )
fi

# ── f. shared lib/ staged from the discoverable workspace root ───────────
if [ -z "$only" ] || [ "$only" = f ]; then
    (
        ws="$fixture/f/empty-cwd"
        state="$fixture/f/state"
        cache="$fixture/f/cache"
        log="$fixture/f/makepkg.log"
        repo="$fixture/f/repo"
        mkdir -p "$ws" "$repo/lib" "$repo/config"
        printf '#!/usr/bin/env bash\n# fixture shared PGO gate\n' >"$repo/lib/pgo.sh"
        printf '#!/bin/sh\n# fixture cups-config shim\n' >"$repo/lib/cups-config"
        : >"$repo/config/topology.conf"
        conf_f="$fixture/f/gsa.conf"
        printf 'project=%s\n' "$repo" >"$conf_f"
        make_recipe "$fixture/f/shared/solo-recipe" solo-recipe
        make_stubs "$fixture/f/bin"
        PATH="$fixture/f/bin:$PATH" GSA_CONF="$conf_f" GSA_STATE_DIR="$state" \
            GSA_BUILD_DIR="$cache" GSA_FAKE_MAKEPKG_LOG="$log" \
            run_engine "$ws" -B "$fixture/f/shared/solo-recipe"
        [ "$FIXTURE_RC" -eq 0 ] || fail "f: rc=$FIXTURE_RC want 0: $FIXTURE_OUTPUT"
        [ -f "$state/standalone/lib/pgo.sh" ] ||
            fail "f: the staged workspace must carry the shared lib/pgo.sh: $(ls -R "$state/standalone" 2>&1)"
        [ -f "$state/standalone/lib/cups-config" ] ||
            fail "f: the staged workspace must carry the shared lib/cups-config: $(ls -R "$state/standalone" 2>&1)"
    )
fi

printf 'gsa-standalone: PASS\n'
