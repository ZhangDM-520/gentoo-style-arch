#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
recipe="packages/git/onlyoffice-git"
pkgbuild="$root/$recipe/PKGBUILD"

fail() {
    printf 'onlyoffice-git recipe: %s\n' "$1" >&2
    exit 1
}

# The PKGBUILD's own commentary discusses `git describe` and makepkg's `error`,
# so structural checks below must look at code only, never at comments.
pkgcode=$(grep -v '^[[:space:]]*#' "$pkgbuild")

# Local assets must be committed and must survive .gitignore. The root
# .gitignore denies packages/*/*/*/ (every directory below a recipe), so a
# future patch subdirectory would silently vanish from a clean checkout.
assets=(PKGBUILD .SRCINFO BUILDING .nvchecker.toml sync-submodules.sh)
for asset in "${assets[@]}"; do
    test -f "$root/$recipe/$asset" || fail "missing asset: $recipe/$asset"
    if git -C "$root" check-ignore -q -- "$recipe/$asset"; then
        fail "asset is hidden by .gitignore: $recipe/$asset"
    fi
done

# Read the recipe the way the builder does; the PKGBUILD says `source=(...)` and
# this runs in its own shell so it cannot disturb the fixture's own builtins.
vars=$(bash -c '
    set -e
    source "$1"
    printf "src=%s\n" "${source[@]}"
    printf "sums=%s\n" "${sha256sums[@]}"
    printf "options=%s\n" "${options[@]}"
    printf "provides=%s\n" "${provides[@]}"
    printf "conflicts=%s\n" "${conflicts[@]}"
    printf "depends=%s\n" "${depends[@]}"
    printf "makedepends=%s\n" "${makedepends[@]}"
    printf "noextract=%s\n" "${noextract[@]}"
    printf "release=%s\n" "${_oo_release}"
    printf "build=%s\n" "${_oo_build}"
    printf "pkgver=%s\n" "${pkgver}"
    printf "pkgname=%s\n" "${pkgname}"
' _ "$pkgbuild") || fail "cannot source the PKGBUILD"

has() { grep -Fxq "$1=$2" <<<"$vars"; }
field() { sed -n "s/^$1=//p" <<<"$vars"; }

# ---------------------------------------------------------------- namespaces
# Two independent upstream namespaces, and mixing them is the classic mistake:
# v9.4.0 exists only in DesktopEditors, v9.4.0.130 only in the ten modules.
# A module pinned with the release name would try to check out a ref that does
# not exist anywhere.
release=$(field release)
build=$(field build)
[[ -n $release && -n $build ]] || fail "cannot read _oo_release/_oo_build"
[[ $release != "$build" ]] ||
    fail "_oo_release and _oo_build collapsed into one value ($release)"

has pkgver "$build" || fail "pkgver ($(field pkgver)) is not the build tag ($build)"

# The release tag must never be used as a source ref. It would name a tag the
# module repositories do not have.
if grep -Eq "tag=v${release}([^.]|$)" "$pkgbuild"; then
    fail "a source pins the release tag v${release}, which the modules do not have"
fi

# pkgver() must read the version from a module tree, because DesktopEditors'
# own tags are vX.Y.Z only and carry no build number.
grep -Fq 'cd "$srcdir/core"' "$pkgbuild" ||
    fail "pkgver() does not read the version from the core module"
# ...and it must ask which tags point at HEAD, never `git describe`: upstream
# tags one commit with several build numbers (core's .130 commit also carries
# .126/.127/.129), so describe answers arbitrarily and reported 9.4.0.126 here.
[[ $pkgcode == *'git tag --points-at HEAD'* ]] ||
    fail "pkgver() does not select the build tag by tag membership of HEAD"
if [[ $pkgcode == *'git describe'* ]]; then
    fail "git describe is unreliable here (multi-tagged commits); use tag --points-at"
fi

# --------------------------------------------------------------------- pins
# A moving ref is not a pin. Every git source must name a commit or a tag, and
# every tag used for a module must be the build tag.
while read -r src; do
    [[ $src == *git+* ]] || continue
    case "$src" in
        *#commit=* | *#tag=*) ;;
        *) fail "git source is not pinned: $src" ;;
    esac
    [[ $src == *'#branch='* ]] && fail "git source follows a branch: $src"
done < <(field src)

# Every module must be pinned, and every pin must be a real 40-hex commit.
for module in core desktop-apps desktop-sdk sdkjs sdkjs-forms web-apps \
              dictionaries build_tools core-fonts document-templates; do
    grep -Eq "(^| )${module}::git\+.*#commit=[0-9a-f]{40}( |$)" <<<"$(field src)" ||
        fail "module $module is not pinned to a 40-hex commit"
done

# web-apps is the one rename: the directory must be web-apps (that is the path
# build_tools uses) while the repository is web-apps-pro.
grep -Fq 'web-apps::git+${_url}/web-apps-pro#commit=' "$pkgbuild" ||
    fail "web-apps is not mapped to the web-apps-pro repository"

# ------------------------------------------------------------------ checksums
# makepkg hashes `git archive` of a #commit=/#tag= fragment, so a pinned git
# source gets a REAL checksum and never needs SKIP. A SKIP here would mean a
# source that can drift unnoticed.
sums=()
while read -r sum; do sums+=("$sum"); done < <(field sums)
srcs=()
while read -r src; do srcs+=("$src"); done < <(field src)

((${#sums[@]} == ${#srcs[@]})) ||
    fail "checksum count (${#sums[@]}) does not match source count (${#srcs[@]})"
for sum in "${sums[@]}"; do
    [[ $sum == SKIP ]] && fail "a source carries SKIP instead of a real checksum"
    [[ $sum =~ ^[0-9a-f]{64}$ ]] || fail "malformed checksum: $sum"
done

# --------------------------------------------------------------- local assets
# Anything in source=() that is not a URL is a file this recipe must ship.
locals=0
for src in "${srcs[@]}"; do
    path=$src
    url=$src
    if [[ $src == *'::'* ]]; then
        path=${src%%::*}
        url=${src#*::}
    fi
    # A remote source is a URL; only bare filenames are ours to ship.
    [[ $url == *'://'* ]] && continue

    locals=$((locals + 1))
    test -f "$root/$recipe/$path" || fail "local source is missing: $path"
    git -C "$root" ls-files --error-unmatch "$recipe/$path" >/dev/null 2>&1 ||
        fail "local source is not committed: $path"
    if git -C "$root" check-ignore -q -- "$recipe/$path"; then
        fail "local source is hidden by .gitignore: $path"
    fi
done
((locals >= 18)) || fail "expected at least 18 local assets, found $locals"

# The CEF tarball is unpacked by hand, selecting only Release/ and Resources/.
# Without noextract makepkg would unpack all of it first and throw it away.
has noextract "cef_$(sed -n 's/^_cef_build=//p' "$pkgbuild").tar.bz2" ||
    fail "the CEF tarball is not excluded from automatic extraction"

# ------------------------------------------------------------------ self-track
grep -Fq 'source = "git"' "$root/$recipe/.nvchecker.toml" ||
    fail ".nvchecker.toml does not track a git source"
grep -Fq 'ONLYOFFICE/DesktopEditors.git' "$root/$recipe/.nvchecker.toml" ||
    fail ".nvchecker.toml does not track the release repository"
grep -Fq 'prefix = "v"' "$root/$recipe/.nvchecker.toml" ||
    fail ".nvchecker.toml does not strip the tag prefix"

# -------------------------------------------------------------------- flags
# CONTRIBUTING.md forbids APPENDING host-specific optimisation or ISA flags.
# This recipe only removes flags (_FORTIFY_SOURCE 3->2, and a -O2 removal that
# is inert on a -O3 host). A blunt grep for -O[0-9] would flag a removal as if
# it were an addition, so require that every mention is part of a ${VAR/-O.../}
# substitution. Both checks ignore comments: naming a flag to explain why it is
# *not* appended is documentation, not an addition, and a comment cannot reach
# the compiler.
while IFS= read -r line; do
    stripped=${line%%#*}                  # a trailing comment is not an addition
    [[ $stripped == *'-O'* ]] || continue
    [[ $stripped == *'${'*'-O'*'}'* ]] || fail "optimisation flag is added, not removed: $line"
done < <(grep -E -- '-O[0-9]' "$pkgbuild")

while IFS= read -r line; do
    stripped=${line%%#*}
    [[ $stripped == *'-march='* || $stripped == *'-mtune='* ]] || continue
    fail "hard-codes a host ISA flag: $line"
done < "$pkgbuild"

# ---------------------------------------------------------------- capabilities
# Java is needed for the Closure Compiler grunt drives. It must be requested
# through the versioned virtual: only a JDK 11 satisfies =11, and jdk11-openjdk
# conflicts with neither jdk-openjdk nor jdk17-openjdk, so nothing has to be
# removed to build this.
has makedepends 'java-environment=11' ||
    fail "does not request java-environment=11"
if grep -Eq "^[[:space:]]*'(jre|jdk)[a-z0-9_.+-]*'" "$pkgbuild"; then
    fail "depends on a concrete jdk/jre package instead of the virtual"
fi

# The Qt5 capability is requested through the virtuals, so the installed
# provider (qt5-base-git) satisfies it without naming a concrete recipe.
for dep in qt5-base qt5-multimedia qt5-svg qt5-x11extras; do
    has depends "$dep" || fail "missing dependency: $dep"
done

has provides 'onlyoffice' || fail "does not provide onlyoffice"
has provides 'onlyoffice-desktopeditors' || fail "does not provide onlyoffice-desktopeditors"
has conflicts 'onlyoffice' || fail "would not conflict with the archlinuxcn build"

# -O2 plus LTO segfaults the linker in this build; the option is load-bearing.
has options '!lto' || fail "missing option: !lto"

# ------------------------------------------------------- pin assertions exist
# The recipe asserts its own pins so a half-applied update fails at prepare()
# rather than producing a package whose version lies about its contents.
[[ $pkgcode == *'_assert_tag'* ]] ||
    fail "prepare() does not assert that each module's HEAD carries the build tag"
# makepkg's `error` only prints; it does not abort. An assertion without a
# failure path is a no-op, which is exactly how eight wrong pins once reached a
# build unnoticed. Each error call must either exit on the spot or set the
# deferred-failure flag that the surrounding block returns (the idiom the PGO
# recipes use: `_rc=1` ... `return $_rc`), so both are accepted here.
while IFS= read -r line; do
    [[ $line == *'error '* && $line != *'exit 1'* && $line != *'_rc=1'* ]] &&
        fail "assertion calls error without a failure path (makepkg's error does not abort): $line"
done <<<"$pkgcode"
grep -Fq 'is not at the pinned commit' "$pkgbuild" ||
    fail "prepare() does not assert the V8 commit"
grep -Fq 'v8.data' "$pkgbuild" ||
    fail "the v8.data sentinel is missing; upstream would re-clone V8"

# ----------------------------------------------------------------- topology
# Read through the builder's --topology channel (id|path|groups|edges|tags):
# the record must exist, point at the recipe, and carry the app membership
# (onlyoffice-git moved from git to app with the 2026-09-27 app-group
# expansion).
topo=$(fish "$root/build-all.fish" --topology) || fail "--topology failed"
rec=$(printf '%s\n' "$topo" | awk -F'|' -v id=onlyoffice-git '$1 == id')
[[ -n $rec ]] || fail "not registered in config/topology.conf (no record)"
[[ $(printf '%s\n' "$rec" | cut -d'|' -f2) == "$recipe" ]] ||
    fail "topology record does not point at $recipe"
[[ ",$(printf '%s\n' "$rec" | cut -d'|' -f3)," == *,app,* ]] ||
    fail "not a member of the app group"

# The dependency edge must name the same capabilities the recipe declares, or
# the recorded build order would not describe a real rebuild trigger. Ids are
# the ones config/topology.conf publishes: the VCS recipe keeps its -git
# suffix, but the Qt5 module recipes are stable-named (qt5-multimedia, not
# qt5-multimedia-git), so the ids cannot simply be derived by appending one.
qtdeps=$(printf '%s\n' "$rec" | cut -d'|' -f4)
for dep in qt5-base-git qt5-multimedia qt5-svg qt5-x11extras; do
    [[ ",$qtdeps," == *",$dep,"* ]] ||
        fail "topology edges field does not record the $dep rebuild trigger"
    printf '%s\n' "$topo" | awk -F'|' -v id="$dep" '$1 == id { found = 1 } END { exit !found }' ||
        fail "$dep is recorded as a trigger but has no topology record"
done

# .SRCINFO must match the recipe.
if ! makepkg_printsrcinfo "$root/$recipe" |
    diff -q - "$root/$recipe/.SRCINFO" >/dev/null; then
    fail ".SRCINFO is out of sync with the PKGBUILD"
fi

printf 'onlyoffice-git recipe fixture: PASS\n'
