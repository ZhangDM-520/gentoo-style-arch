#!/usr/bin/env bash
set -euo pipefail

# ghostty-git zig cache unpack fixture.
#
# prepare() in packages/git/ghostty-git materialises the zig dependency
# cache for `zig build --system`: the pinned mirror tarballs pack the source
# archive VERBATIM under the package id (<id>/<src-top-dir>/…), but --system
# resolves <pkgdir>/<id>/ as the package ROOT — a nested extraction makes
# zig read a rootless dir and the build graph dies with
# `no module named '<dep>'` (2026-10-21, zig 0.17.0: 32 of 37 packages
# nested). prepare() therefore hoists a single top-level dir. This fixture
# runs the REAL prepare() over synthetic tarballs and pins the contract:
#
#   - <id>/<single-dir>/… is hoisted to <id>/… (dotfiles included);
#   - a flat package (<id>/file + <id>/dir) is left exactly as extracted;
#   - a single top-level FILE is not mistaken for a hoistable dir.
#
# Everything happens in a scratch tree; fetch-zig-cache.sh is a no-op stub.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
recipe="$root/packages/git/ghostty-git"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-ghostty-zigcache.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'ghostty zigcache fixture: %s\n' "$1" >&2
    exit 1
}

# ─── Synthetic srcdir: stub fetch script + three differently shaped tarballs
srcdir="$tmp/src"
mkdir -p "$srcdir/ghostty/nix/build-support" "$srcdir/zig-global-cache/p"
cat >"$srcdir/ghostty/nix/build-support/fetch-zig-cache.sh" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$srcdir/ghostty/nix/build-support/fetch-zig-cache.sh"

pack() { # pack <id> <build the tarball body>
    local id=$1
    shift
    local stage="$tmp/stage-$id"
    mkdir -p "$stage/$id"
    ( cd "$stage/$id" && "$@" )
    tar -czf "$srcdir/zig-global-cache/p/$id.tar.gz" -C "$stage" "$id"
    rm -rf "$stage"
}

# nested: one top-level dir holding the package root
pack idNested sh -c 'mkdir -p inner && printf x >inner/build.zig && printf y >inner/build.zig.zon && printf h >inner/.hidden'
# flat: two top-level entries — must NOT be hoisted
pack idFlat sh -c 'printf x >file.txt && mkdir -p sub && printf y >sub/x'
# lone file: no dir to hoist
pack idLone sh -c 'printf x >lone.txt'

# ─── Run the real prepare() ───────────────────────────────────────────────
{
    printf '%s\n' 'set +e'
    printf '%s\n' "srcdir='$srcdir'" "startdir='$tmp/start'" "SRCDEST='$tmp/srcdest'" \
        'export srcdir startdir SRCDEST' "source '$recipe/PKGBUILD'"
    printf '%s\n' 'prepare'
} >"$tmp/wrapper.sh"
mkdir -p "$tmp/start"
( cd "$srcdir/ghostty" && bash "$tmp/wrapper.sh" >"$tmp/out" 2>&1 ) || true

# ─── 1. nested package hoisted, dotfiles included ─────────────────────────
p="$srcdir/zig-global-cache/p"
[[ -f "$p/idNested/build.zig" ]] || fail "nested package root was not hoisted (build.zig)"
[[ -f "$p/idNested/build.zig.zon" ]] || fail "nested package root was not hoisted (build.zig.zon)"
[[ -f "$p/idNested/.hidden" ]] || fail "hoist dropped a dotfile"
[[ ! -e "$p/idNested/inner" ]] || fail "the hoisted inner dir was left behind"

# ─── 2. flat package untouched ────────────────────────────────────────────
[[ -f "$p/idFlat/file.txt" ]] || fail "flat package lost file.txt"
[[ -f "$p/idFlat/sub/x" ]] || fail "flat package lost sub/x"

# ─── 3. single top-level file untouched ───────────────────────────────────
[[ -f "$p/idLone/lone.txt" ]] || fail "single-file package was disturbed"

printf 'ghostty zigcache fixture: PASS\n'
