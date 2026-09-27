#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
recipe="packages/git/vencord-git"
pkgbuild="$root/$recipe/PKGBUILD"

fail() {
    printf 'vencord-git recipe: %s\n' "$1" >&2
    exit 1
}

# Assets must exist and survive both .gitignore layers (the root rule that
# denies every subdirectory under a recipe, and any recipe-local file). The
# initiation files ship as local sources/scriptlets, so they are part of the
# contract, not just the PKGBUILD.
assets=(PKGBUILD .SRCINFO vencord-git.install discord-vencord vencord-inject
    vencord-discord-desktop vencord-discord-desktop.hook)
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
    printf "pkgname=%s\n" "$pkgname"
    printf "arch=%s\n" "${arch[@]}"
    printf "src=%s\n" "${source[@]}"
    printf "makedepends=%s\n" "${makedepends[@]}"
    printf "options=%s\n" "${options[@]}"
    printf "provides=%s\n" "${provides[@]}"
    printf "conflicts=%s\n" "${conflicts[@]}"
    printf "depends=%s\n" "${depends[@]}"
' _ "$pkgbuild") || fail "cannot source the PKGBUILD"

has() {
    grep -Fxq "$1=$2" <<<"$vars"
}

has pkgname 'vencord-git' || fail "pkgname is not vencord-git"

# Desktop standalone scope: tracks upstream main, arch-neutral JavaScript
# payload, provides/conflicts the plain `vencord` capability.
has src 'Vencord::git+https://github.com/Vendicated/Vencord.git#branch=main' ||
    fail "does not track upstream main"
has arch 'any' || fail "payload is plain JavaScript; arch must be any"
has provides 'vencord' || fail "does not provide vencord"
has conflicts 'vencord' || fail "does not conflict with vencord"

# The only runtime depend is python (vencord-inject, stdlib only). The host
# client stays a loader choice: the AUR recipe hard-depends on vesktop; this
# one must not hard-depend on any client — that belongs in optdepends.
has depends 'python' || fail "missing runtime depend: python (vencord-inject)"
if grep -Eq '^depends=(discord|vesktop)' <<<"$vars"; then
    fail "hard client depend: $(grep -E '^depends=(discord|vesktop)' <<<"$vars")"
fi

# Toolchain: pnpm drives the bundle; git is the VCS source. Java must be
# requested through virtuals if it ever appears — concrete JDK/JRE names
# made pacman demand removal of a package the graph needs (2026-09-18).
for dep in git nodejs pnpm; do
    has makedepends "$dep" || fail "missing makedepend: $dep"
done
if grep -Eq "^[[:space:]]*'(jre|jdk)[a-z0-9_.+-]*'" "$pkgbuild"; then
    fail "depends on a concrete jdk/jre package instead of java-runtime"
fi

# Build stages in order: root workspace install, standalone bundle, type-check.
stages=(
    'pnpm install --frozen-lockfile'
    'pnpm buildStandalone'
    'pnpm testTsc'
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

# The install runs at the tree root, where pnpm-workspace.yaml applies. A
# subdirectory install would need the workspace-isolating flag (2026-09-18
# logseq incident); its absence here pins that the install is a root one.
grep -Fq -- '--ignore-workspace' "$pkgbuild" &&
    fail "install carries the subdirectory workspace guard but is a root install"

# Scope: no web bundle, no extension build.
grep -Fq 'pnpm buildWeb' "$pkgbuild" &&
    fail "builds web/extension outputs - desktop standalone only"

# Optimisation standard (docs/MEMORY.md §4, Electron/JavaScript bullet):
# no hard-coded host ISA or optimisation level, the exceptions declared
# explicitly, and the ccache + mold probe for incidental native addons.
if grep -Eq -- '-march=|-mtune=|-O[0-9]' "$pkgbuild"; then
    fail "hard-codes a host ISA or optimisation flag"
fi
for opt in '!strip' '!debug' '!lto'; do
    has options "$opt" || fail "missing option: $opt"
done
grep -Fq 'CCACHE_DIR' "$pkgbuild" ||
    fail "native addon builds do not reuse the compiler cache"
grep -Fq 'command -v mold' "$pkgbuild" ||
    fail "native addon builds are not linked through the house mold probe"

# Source verification discipline: never bypass PGP checking, never drop sums
# silently (VCS sources legitimately carry SKIP).
grep -Fq -- '--skippgpcheck' "$pkgbuild" &&
    fail "bypasses PGP checking"

# pkgver() derives from upstream tags in the house -git describe form.
grep -Fq 'git describe --long --tags' "$pkgbuild" ||
    fail "pkgver() does not derive from git describe"

# Package scope: the six desktop standalone bundles land in /usr/lib/vencord
# with the package.json loader shim, and nothing else is shipped from dist/.
grep -Fq 'dist/vencord*' "$pkgbuild" ||
    fail "does not copy the standalone bundle set from dist/"
grep -Fq '/usr/lib/vencord' "$pkgbuild" ||
    fail "payload is not installed to /usr/lib/vencord"
grep -Fq '/usr/lib/vencord/package.json' "$pkgbuild" ||
    fail "loader contract: no package.json shim beside the payloads"

# Initiation contract: the payload is inert until injected, so package()
# must ship the launcher, the injector and the desktop-redirect hook, and the
# scriptlets must wire first wrap + adopt at install and unpatch + unwrap at
# removal (pre_remove — post_remove runs after the package's own files are
# already gone).
grep -Fq 'install=vencord-git.install' "$pkgbuild" ||
    fail "PKGBUILD does not reference its scriptlet file"
for shipped in '/usr/bin/discord-vencord' '/usr/bin/vencord-inject' \
    '/usr/share/libalpm/scripts/vencord-discord-desktop' \
    '/usr/share/libalpm/hooks/vencord-discord-desktop.hook'; do
    grep -Fq "$shipped" "$pkgbuild" || fail "package() does not install $shipped"
done
install_file="$root/$recipe/vencord-git.install"
grep -Fq 'post_install()' "$install_file" || fail "no post_install scriptlet"
grep -Fq 'pre_remove()' "$install_file" ||
    fail "cleanup must run in pre_remove, not post_remove"
grep -Fq 'post_upgrade()' "$install_file" ||
    fail "no post_upgrade — pacman has no fallback to post_install on upgrades, so bumps would silently skip initiation"
grep -Fq 'vencord-inject inject' "$install_file" ||
    fail "post_install does not adopt an existing injection"
grep -Fq 'vencord-discord-desktop wrap' "$install_file" ||
    fail "post_install does not wrap the stock desktop entry"
grep -Fq 'vencord-inject uninject' "$install_file" ||
    fail "pre_remove does not uninject"
grep -Fq 'vencord-discord-desktop restore' "$install_file" ||
    fail "pre_remove does not restore the desktop Exec line"
grep -Fxq 'Target = usr/share/applications/discord.desktop' \
    "$root/$recipe/vencord-discord-desktop.hook" ||
    fail "hook does not trigger on the stock discord.desktop path"

# Topology: the recipe must be reachable through a topology record (id+path)
# and an app-group membership (the 2026-09-27 app-group expansion moved this
# desktop application from git to app), read through the builder's --topology
# channel.
topo=$(fish "$root/build-all.fish" --topology) || fail "--topology failed"
rec=$(printf '%s\n' "$topo" | awk -F'|' -v id=vencord-git '$1 == id')
[[ -n $rec ]] || fail "not registered in config/topology.conf (no record)"
[[ $(printf '%s\n' "$rec" | cut -d'|' -f2) == "$recipe" ]] ||
    fail "topology record does not point at $recipe"
[[ ",$(printf '%s\n' "$rec" | cut -d'|' -f3)," == *,app,* ]] ||
    fail "not a member of the app group"

# .SRCINFO must match the recipe.
if ! makepkg_printsrcinfo "$root/$recipe" |
    diff -q - "$root/$recipe/.SRCINFO" >/dev/null; then
    fail ".SRCINFO is out of sync with the PKGBUILD"
fi

printf 'vencord-git recipe fixture: PASS\n'

# ==== vencord-inject.sh ====
(

# The payload alone is inert: this fixture pins the initiation contract of
# vencord-git (docs/NOTE.md 2026-09-23) against scratch trees. Discovery goes
# through the standard XDG_CONFIG_HOME seam, so the real home is never
# touched and no extra test knob exists.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
inject="$root/packages/git/vencord-git/vencord-inject"
desktop="$root/packages/git/vencord-git/vencord-discord-desktop"

fail() {
    printf 'vencord-inject fixture: %s\n' "$1" >&2
    exit 1
}

work=$(mktemp -d "${TMPDIR:-/tmp}/vencord-inject.XXXXXX")
trap 'rm -rf "$work"' EXIT

cfg="$work/config"
res_new="$cfg/discord/app-1.0.159/resources"
res_old="$cfg/discord/app-1.0.9/resources"
res_canary="$cfg/discordcanary/app-0.0.312/resources"
mkdir -p "$res_new" "$res_old" "$res_canary"
printf 'PRISTINE-ASAR-ORIGINAL-BYTES' >"$res_new/app.asar"
printf 'PRISTINE-OLD-VERSION' >"$res_old/app.asar"
printf 'PRISTINE-CANARY' >"$res_canary/app.asar"

vi() {
    XDG_CONFIG_HOME="$cfg" "$inject" "$@"
}

embedded_patcher() {
    python3 - "$1" <<'PYEOF'
import json, struct, sys
data = open(sys.argv[1], "rb").read()
_, hsz, _, hss = struct.unpack_from("<4I", data)
hdr = json.loads(data[16:16 + hss])
e = hdr["files"]["index.js"]
off = 8 + hsz + int(e["offset"])
sys.stdout.write(data[off:off + int(e["size"])].decode()[len('require("'):-2])
PYEOF
}

# --- inject: newest app-* per channel, every channel, oldest left alone ------
vi inject >/dev/null || fail "inject returned non-zero on pristine trees"
test -f "$res_new/_app.asar" || fail "pristine app.asar was not renamed"
cmp -s <(printf 'PRISTINE-ASAR-ORIGINAL-BYTES') "$res_new/_app.asar" ||
    fail "_app.asar is not the byte-identical original"
cmp -s <(printf 'PRISTINE-OLD-VERSION') "$res_old/app.asar" ||
    fail "an older app-* version was patched; only the newest per channel may be"
test -f "$res_canary/_app.asar" ||
    fail "second channel (discordcanary) was not discovered"
vi status >/dev/null || fail "status is not green after injecting every channel"

got=$(embedded_patcher "$res_new/app.asar")
[ "$got" = /usr/lib/vencord/patcher.js ] ||
    fail "shim embeds '$got', expected the pacman-owned patcher"

# --- idempotence: a second run changes nothing -------------------------------
before=$(sha256sum "$res_new/app.asar" "$res_new/_app.asar")
vi inject >/dev/null || fail "second inject returned non-zero"
[ "$before" = "$(sha256sum "$res_new/app.asar" "$res_new/_app.asar")" ] ||
    fail "inject is not idempotent"

# --- adoption: a foreign (official-installer) shim is repointed in place -----
printf 'OFFICIAL-SHIM-POINTING-ELSEWHERE' >"$res_new/app.asar"
keep=$(sha256sum "$res_new/_app.asar")
vi inject >/dev/null || fail "adopting an already-patched tree failed"
[ "$keep" = "$(sha256sum "$res_new/_app.asar")" ] ||
    fail "adoption rewrote _app.asar"
if cmp -s <(printf 'OFFICIAL-SHIM-POINTING-ELSEWHERE') "$res_new/app.asar"; then
    fail "foreign shim was not rewritten"
fi
vi status >/dev/null || fail "adoption did not repoint at /usr/lib/vencord"

# --- interrupted state: backup present, shim missing -------------------------
rm "$res_new/app.asar"
vi inject >/dev/null || fail "repair of a missing shim failed"
vi status >/dev/null || fail "status is red after repairing a missing shim"

# --- uninject restores the pristine original byte-for-byte -------------------
vi uninject >/dev/null || fail "uninject returned non-zero"
cmp -s <(printf 'PRISTINE-ASAR-ORIGINAL-BYTES') "$res_new/app.asar" ||
    fail "uninject did not restore the pristine app.asar"
test ! -e "$res_new/_app.asar" || fail "_app.asar left behind after uninject"
if vi status >/dev/null 2>&1; then
    fail "status reports injected after uninject"
fi

# --- fresh bootstrap: no channel at all --------------------------------------
mkdir -p "$work/empty"
XDG_CONFIG_HOME="$work/empty" "$inject" inject >/dev/null ||
    fail "inject must no-op (rc=0) when no channel exists yet"
if XDG_CONFIG_HOME="$work/empty" "$inject" status >/dev/null 2>&1; then
    fail "status is green without any channel"
fi

# --- desktop Exec wrap/restore, idempotent both ways -------------------------
desk="$work/discord.desktop"
cat >"$desk" <<'EOF'
[Desktop Entry]
Name=Discord
Exec=/usr/bin/discord --url -- %u
MimeType=x-scheme-handler/discord;
EOF
cp "$desk" "$work/orig.desktop"
"$desktop" wrap "$desk"
grep -q '^Exec=/usr/bin/discord-vencord --url -- %u$' "$desk" ||
    fail "wrap did not redirect the stock Exec line"
"$desktop" wrap "$desk"
[ "$(grep -c 'discord-vencord' "$desk" || true)" = 1 ] ||
    fail "wrap is not idempotent — the Exec line double-wrapped"
"$desktop" restore "$desk"
cmp -s "$desk" "$work/orig.desktop" ||
    fail "restore did not return the original Exec line"
"$desktop" restore "$desk"
cmp -s "$desk" "$work/orig.desktop" || fail "restore is not idempotent"
"$desktop" wrap "$work/absent.desktop" ||
    fail "wrap of an absent file must exit 0 (discord not installed yet)"

# --- wrapper: injects first, then execs Discord with args intact -------------
wrapdir="$work/wrap"
mkdir -p "$wrapdir"
printf '#!/bin/sh\n: >"%s/inject-called"\n' "$work" >"$wrapdir/inject-stub"
printf '#!/bin/sh\nprintf "DISCORD:%%s\\n" "$*" >"%s/discord-args"\nexit 7\n' \
    "$work" >"$wrapdir/discord-stub"
chmod +x "$wrapdir/inject-stub" "$wrapdir/discord-stub"
# Fixture-local copy only: retarget the wrapper's absolute paths at stubs.
sed -e "s|/usr/bin/vencord-inject|$wrapdir/inject-stub|" \
    -e "s|/usr/bin/discord|$wrapdir/discord-stub|" \
    "$root/packages/git/vencord-git/discord-vencord" >"$wrapdir/wrapper"
rc=0
sh "$wrapdir/wrapper" --url -- '%u' || rc=$?
[ "$rc" = 7 ] || fail "wrapper does not exec Discord (exit $rc, expected 7)"
test -f "$work/inject-called" || fail "wrapper did not run vencord-inject first"
[ "$(cat "$work/discord-args")" = 'DISCORD:--url -- %u' ] ||
    fail "wrapper mangled the launcher arguments: $(cat "$work/discord-args")"

printf 'vencord-inject fixture: PASS\n'
)
