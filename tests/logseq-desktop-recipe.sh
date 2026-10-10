#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
recipe="packages/git/logseq-desktop-git"
pkgbuild="$root/$recipe/PKGBUILD"

fail() {
    printf 'logseq-desktop-git recipe: %s\n' "$1" >&2
    exit 1
}

assets=(PKGBUILD .SRCINFO BUILDING .gitignore logseq-desktop-git.desktop)
for asset in "${assets[@]}"; do
    test -f "$root/$recipe/$asset" || fail "missing asset: $recipe/$asset"
    if git -C "$root" check-ignore -q -- "$recipe/$asset"; then
        fail "asset is hidden by .gitignore: $recipe/$asset"
    fi
done

# Read the recipe the same way the builder does; the PKGBUILD overrides the
# `source` builtin, so this runs in its own shell.
vars=$(bash -c '
    source "$1" || exit 1
    printf "src=%s\n" "${source[@]}"
    printf "makedepends=%s\n" "${makedepends[@]}"
    printf "options=%s\n" "${options[@]}"
    printf "provides=%s\n" "${provides[@]}"
' _ "$pkgbuild") || fail "cannot source the PKGBUILD"

has() {
    grep -Fxq "$1=$2" <<<"$vars"
}

# Self-tracking: the VCS source follows upstream master and pkgver() reads the
# version the tree carries, so the package version moves with upstream.
has src 'logseq::git+https://github.com/logseq/logseq.git#branch=master' ||
    fail "does not track upstream master"
grep -Fq 'src/main/frontend/version.cljs' "$pkgbuild" ||
    fail "pkgver() does not derive the version from version.cljs"

# The desktop bundle embeds the ClojureScript frontend and the OCaml/Melange
# CLI runtime; both toolchains must stay declared.
for dep in clojure ocaml opam nodejs pnpm; do
    has makedepends "$dep" || fail "missing makedepend: $dep"
done
# Java is requested through the java-runtime virtual, optionally with a
# version floor (shadow-cljs runs class-65 Closure jars, so the recipe
# requires java-runtime>=21 — run #108): a versioned virtual is still the
# virtual; only concrete names are banned below.
grep -Eq '^makedepends=java-runtime(>=.*)?$' <<<"$vars" ||
    fail "missing makedepend: java-runtime (virtual, optionally versioned)"

# Java must be requested through the `java-runtime` virtual. A concrete
# jre-*/jdk-* package is not just narrower, it is unusable: jre-openjdk
# conflicts with jdk-openjdk, which `clojure` requires through
# java-environment, so pacman aborted the transaction demanding the removal of
# an installed JDK (2026-09-18).
if grep -Eq "^[[:space:]]*'(jre|jdk)[a-z0-9_.+-]*'" "$pkgbuild"; then
    fail "depends on a concrete jdk/jre package instead of java-runtime: $(grep -E "^[[:space:]]*'(jre|jdk)[a-z0-9_.+-]*'" "$pkgbuild")"
fi

# The desktop bundle is only produced by this sequence, in this order
# (upstream .github/workflows/build-desktop-release.yml).
stages=(
    'pnpm gulp:build'
    'pnpm cljs:release-electron'
    'pnpm db-worker-node:bundle'
    'opam exec -- pnpm cli:release'
    'pnpm webpack-app-build'
    'pnpm desktop:prepare-runtime-js'
)
last=0
for stage in "${stages[@]}"; do
    line=$(grep -Fn -- "$stage" "$pkgbuild" | head -1 | cut -d: -f1) || line=""
    test -n "$line" || fail "missing build stage: $stage"
    if (( line <= last )); then
        fail "build stage out of order: $stage"
    fi
    last=$line
done

# The recipe tree carries pnpm-workspace.yaml at its root with no `packages:`
# field, so a bare `pnpm install` run from a subdirectory resolves the ROOT
# project: it exits 0 without creating that subdirectory's node_modules, and the
# subsequent `pnpm exec` cannot find its locally installed binary. The static
# packaging step aborted on exactly that (2026-09-18); the cli install carries
# the guard too.
static_block=$(sed -n '/^  ( cd static$/,/executableName=logseq/p' "$pkgbuild")
grep -Fq 'pnpm install --frozen-lockfile --ignore-workspace' <<<"$static_block" ||
    fail "static install is not isolated from the repo-root pnpm workspace"

# $srcdir/opam-root survives a failed run, so build() must tolerate an existing
# switch: `opam switch create` exits 2 when the switch is already installed and
# makepkg's errexit turns that into an abort before the first bundle is built
# (2026-09-18).
grep -Fq 'opam switch list --short' "$pkgbuild" ||
    fail "opam switch creation is not guarded for a resumed build"

# Optimisation standard: no hard-coded host ISA or optimisation level, and the
# Electron exceptions are declared explicitly.
if grep -Eq -- '-march=|-mtune=|-O[0-9]' "$pkgbuild"; then
    fail "hard-codes a host ISA or optimisation flag"
fi
for opt in '!strip' '!debug' '!lto'; do
    has options "$opt" || fail "missing option: $opt"
done
grep -Fq 'command -v mold' "$pkgbuild" ||
    fail "native Node addons are not linked through the house mold probe"
grep -Fq 'CCACHE_DIR' "$pkgbuild" ||
    fail "native Node addons do not reuse the compiler cache"
has provides 'logseq-desktop' || fail "does not provide logseq-desktop"

# The bundled Electron sandbox helper only works when it is setuid root.
grep -Fq 'chmod 4755' "$pkgbuild" || fail "chrome-sandbox is not made setuid"
grep -Fq 'dist/linux-unpacked' "$pkgbuild" || fail "unpacked Electron tree unused"

# Topology: the recipe must be reachable through a topology record (id+path)
# and an app-group membership (the 2026-09-27 app-group expansion moved this
# desktop application from git to app), read through the builder's --topology
# channel.
topo=$(fish "$root/build-all.fish" --topology) || fail "--topology failed"
rec=$(printf '%s\n' "$topo" | awk -F'|' -v id=logseq-desktop-git '$1 == id')
[[ -n $rec ]] || fail "not registered in config/topology.conf (no record)"
[[ $(printf '%s\n' "$rec" | cut -d'|' -f2) == "$recipe" ]] ||
    fail "topology record does not point at $recipe"
[[ ",$(printf '%s\n' "$rec" | cut -d'|' -f3)," == *,app,* ]] ||
    fail "not a member of the app group"

# .SRCINFO freshness is owned by tests/srcinfo-freshness.sh (it regenerates and
# diffs every recipe from the --topology channel), so it is not re-asserted here.

printf 'logseq-desktop-git recipe fixture: PASS\n'
