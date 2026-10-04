#!/usr/bin/env bash
set -euo pipefail

# Recipe-contract lints: provides versioning, the purged-tools denylist and
# the IgnorePkg closure. One implementation per rule lives in build-all.fish
# (audit_lint_provides / audit_lint_purged / audit_lint_ignorepkg);
# `fish build-all.fish --audit` renders them in its report and the hidden
# `--audit-lint <name> [pacman-conf]` seam runs one of them — the seam is the
# interface, and this fixture is its gating walker (red/green per rule, then
# the real-repo gates).
#
# Enforcement mapping (the settled three-tier rule):
#   deterministic + must-gate  provides-versioning, purged-tools → --audit
#                              lints, GATED here (fixture rc, never --audit's);
#   host-state                 IgnorePkg closure → --audit lint (report-only,
#                              Q20) + gate here that reads /etc/pacman.conf
#                              DIRECTLY and skips only when it is unreadable
#                              (Q17); the cumulative [options] semantics are
#                              proven against scratch confs through the seam's
#                              path argument;
#   heavy/ELF                  soname-presence → tools/provides-audit.sh pair.
# PGP procedure and trimming stay docs-only by the same mapping.
#
# Every scratch workspace and conf lives under $TMPDIR; the real-repo sections
# are read-only.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/tests/lib/fixture-lib.bash"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-recipe-contract.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'recipe contract fixture: %s\n' "$1" >&2
    exit 1
}

# lint WORKSPACE NAME [CONF] — run one audit lint through the seam.
lint() {
    local ws=$1 name=$2 conf=${3:-}
    if [[ -n $conf ]]; then
        run_builder fish "$ws/build-all.fish" --audit-lint "$name" "$conf"
    else
        run_builder fish "$ws/build-all.fish" --audit-lint "$name"
    fi
}

# write_srcinfo DIR BASE [EXTRA_PKGNAME...] — committed-.SRCINFO shape:
# pkgbase/pkgname at column 0, metadata fields one tab in. Callers append
# their fields with `printf '\tfield = value\n' >>"$DIR/.SRCINFO"`.
write_srcinfo() {
    local dir=$1 base=$2
    shift 2
    {
        printf 'pkgbase = %s\n' "$base"
        printf 'pkgname = %s\n' "$base"
        local name
        for name in "$@"; do
            [[ $name == "$base" ]] && continue
            printf 'pkgname = %s\n' "$name"
        done
    } >"$dir/.SRCINFO"
}

# ─── A. provides versioning: red/green through the seam ──────────────────────
(
    set -euo pipefail
    ws=$tmp/provides-ws
    make_workspace "$ws" 1 2 low
    add_package "$ws" prov-git
    add_package "$ws" consumer-git
    add_package "$ws" libs-git

    # P1 mechanism: an unversioned provide cannot satisfy a versioned
    # constraint, so pacman falls back to the repo package (the meson class).
    write_srcinfo "$ws/packages/prov-git" prov-git
    printf '\tprovides = meson\n' >>"$ws/packages/prov-git/.SRCINFO"
    write_srcinfo "$ws/packages/consumer-git" consumer-git
    printf '\tmakedepends = meson>=1.8\n' >>"$ws/packages/consumer-git/.SRCINFO"
    write_srcinfo "$ws/packages/libs-git" libs-git

    lint "$ws" provides
    if ((FIXTURE_RC != 0)); then
        fail "A: --audit-lint must stay report-only while findings exist (rc=$FIXTURE_RC)"
    fi
    grep -Fq "provides: prov-git: unversioned provide 'meson' cannot satisfy 'meson>=1.8' (required by consumer-git) — version it as provides=('meson=\${pkgver}')" \
        <<<"$FIXTURE_OUTPUT" ||
        fail "A: missing or wrong P1 finding, got: $FIXTURE_OUTPUT"

    # P2/P3 soname forms, plus the BARE stem that must NOT be flagged.
    printf '\tprovides = libfoo.so=2-64\n' >>"$ws/packages/libs-git/.SRCINFO"
    printf '\tprovides = libbar.so.1\n' >>"$ws/packages/libs-git/.SRCINFO"
    printf '\tprovides = libbaz.so\n' >>"$ws/packages/libs-git/.SRCINFO"
    lint "$ws" provides
    grep -Fq "provides: libs-git: soname provide 'libfoo.so=2-64' is hand-versioned — declare the bare stem 'libfoo.so' and let makepkg auto-version it from the built ELF" \
        <<<"$FIXTURE_OUTPUT" ||
        fail "A: missing P2 finding, got: $FIXTURE_OUTPUT"
    grep -Fq "provides: libs-git: soname provide 'libbar.so.1' names a versioned soname — declare the bare stem 'libbar.so'" \
        <<<"$FIXTURE_OUTPUT" ||
        fail "A: missing P3 finding, got: $FIXTURE_OUTPUT"
    grep -Fq 'libbaz.so' <<<"$FIXTURE_OUTPUT" &&
        fail "A: a bare soname stem is the correct form and must not be flagged: $FIXTURE_OUTPUT"
    grep -Fq 'audit-lint provides: 3 finding(s)' <<<"$FIXTURE_OUTPUT" ||
        fail "A: wrong finding count, got: $FIXTURE_OUTPUT"

    # Green: versioned provide for the constrained name, bare soname stems.
    write_srcinfo "$ws/packages/prov-git" prov-git
    printf '\tprovides = meson=1.8.0\n' >>"$ws/packages/prov-git/.SRCINFO"
    write_srcinfo "$ws/packages/libs-git" libs-git
    printf '\tprovides = libbaz.so\n' >>"$ws/packages/libs-git/.SRCINFO"
    lint "$ws" provides
    ((FIXTURE_RC == 0)) || fail "A: green case failed (rc=$FIXTURE_RC)"
    grep -Fq 'audit-lint provides: clean' <<<"$FIXTURE_OUTPUT" ||
        fail "A: expected a clean verdict, got: $FIXTURE_OUTPUT"
    # Q8 NAME mapping scope (red): every shape that MAPS a name needs a
    # VERSIONED name-provide — the Class A swap, the VCS-derived stock
    # counterpart, and compat-maps of output names (sibling AND cross-recipe).
    # The swap case also pins the dedup: a mapped name a consumer constrains
    # gets ONE finding, since one edit fixes both sides. A self-provide and a
    # capability virtual map nothing and stay unversioned.
    add_package "$ws" swap-git
    add_package "$ws" map-git
    add_package "$ws" compat
    add_package "$ws" cross
    add_package "$ws" selfname
    add_package "$ws" virt
    write_srcinfo "$ws/packages/swap-git" swap-git
    printf '\tprovides = stocklib\n' >>"$ws/packages/swap-git/.SRCINFO"
    printf '\tconflicts = stocklib\n' >>"$ws/packages/swap-git/.SRCINFO"
    printf '\tmakedepends = stocklib>=2\n' >>"$ws/packages/consumer-git/.SRCINFO"
    write_srcinfo "$ws/packages/map-git" map-git
    printf '\tprovides = map\n' >>"$ws/packages/map-git/.SRCINFO"
    write_srcinfo "$ws/packages/compat" compat compat-b
    printf '\tprovides = compat\n' >>"$ws/packages/compat/.SRCINFO"
    write_srcinfo "$ws/packages/cross" cross
    printf '\tprovides = compat-b\n' >>"$ws/packages/cross/.SRCINFO"
    write_srcinfo "$ws/packages/selfname" selfname
    printf '\tprovides = selfname\n' >>"$ws/packages/selfname/.SRCINFO"
    write_srcinfo "$ws/packages/virt" virt
    printf '\tprovides = libgl\n' >>"$ws/packages/virt/.SRCINFO"

    lint "$ws" provides
    ((FIXTURE_RC == 0)) || fail "A: Q8 red case must stay report-only (rc=$FIXTURE_RC)"
    for pair in "swap-git: stocklib" "map-git: map" "compat: compat" "cross: compat-b"; do
        id=${pair%%: *}
        name=${pair#*: }
        grep -Fq "provides: $id: mapped swap/compat provide '$name' is unversioned" \
            <<<"$FIXTURE_OUTPUT" ||
            fail "A: missing Q8 mapping finding for '$pair', got: $FIXTURE_OUTPUT"
    done
    grep -Fq 'audit-lint provides: 4 finding(s)' <<<"$FIXTURE_OUTPUT" ||
        fail "A: wrong Q8 finding count (dedup/self-provide/virtual must add none): $FIXTURE_OUTPUT"

    # Green: the mapped names carry versions; the self-provide and the
    # capability virtual stay unversioned and stay clean.
    write_srcinfo "$ws/packages/swap-git" swap-git
    printf '\tprovides = stocklib=2.0\n' >>"$ws/packages/swap-git/.SRCINFO"
    printf '\tconflicts = stocklib\n' >>"$ws/packages/swap-git/.SRCINFO"
    write_srcinfo "$ws/packages/map-git" map-git
    printf '\tprovides = map=1.0\n' >>"$ws/packages/map-git/.SRCINFO"
    write_srcinfo "$ws/packages/compat" compat compat-b
    printf '\tprovides = compat=1.0\n' >>"$ws/packages/compat/.SRCINFO"
    write_srcinfo "$ws/packages/cross" cross
    printf '\tprovides = compat-b=1.0\n' >>"$ws/packages/cross/.SRCINFO"
    lint "$ws" provides
    ((FIXTURE_RC == 0)) || fail "A: Q8 green case failed (rc=$FIXTURE_RC)"
    grep -Fq 'audit-lint provides: clean' <<<"$FIXTURE_OUTPUT" ||
        fail "A: versioning the mapped names must clear the verdict, got: $FIXTURE_OUTPUT"
    printf 'A: provides versioning red/green OK\n'
)

# ─── B. purged-tools denylist: red/green through the seam ────────────────────
(
    set -euo pipefail
    ws=$tmp/purged-ws
    make_workspace "$ws" 1 2 low
    add_package "$ws" tools-git

    # Exact-name denylist: 'python-sphinx-theme' must NOT match
    # 'python-sphinx', and checkdepends is a build-time install vector just
    # like makedepends (makepkg installs both silently).
    write_srcinfo "$ws/packages/tools-git" tools-git
    printf '\tmakedepends = python-sphinx\n' >>"$ws/packages/tools-git/.SRCINFO"
    printf '\tmakedepends = python-sphinx-theme\n' >>"$ws/packages/tools-git/.SRCINFO"
    printf '\tcheckdepends = po4a>=0.6\n' >>"$ws/packages/tools-git/.SRCINFO"
    lint "$ws" purged
    ((FIXTURE_RC == 0)) || fail "B: --audit-lint must stay report-only (rc=$FIXTURE_RC)"
    grep -Fq "purged: tools-git: makedepends reintroduces purged tool 'python-sphinx' — remove it (docs/MEMORY.md rule 8)" \
        <<<"$FIXTURE_OUTPUT" ||
        fail "B: missing makedepends finding, got: $FIXTURE_OUTPUT"
    grep -Fq "purged: tools-git: checkdepends reintroduces purged tool 'po4a' — remove it (docs/MEMORY.md rule 8)" \
        <<<"$FIXTURE_OUTPUT" ||
        fail "B: missing checkdepends finding, got: $FIXTURE_OUTPUT"
    grep -Fq 'audit-lint purged: 2 finding(s)' <<<"$FIXTURE_OUTPUT" ||
        fail "B: the denylist must match exact names only (count != 2): $FIXTURE_OUTPUT"

    write_srcinfo "$ws/packages/tools-git" tools-git
    printf '\tmakedepends = python-sphinx-theme\n' >>"$ws/packages/tools-git/.SRCINFO"
    lint "$ws" purged
    grep -Fq 'audit-lint purged: clean' <<<"$FIXTURE_OUTPUT" ||
        fail "B: expected a clean verdict, got: $FIXTURE_OUTPUT"
    printf 'B: purged-tools denylist red/green OK\n'
)

# ─── C. IgnorePkg closure: pacman.conf semantics + Q17 skip ──────────────────
(
    set -euo pipefail
    ws=$tmp/ignorepkg-ws
    make_workspace "$ws" 1 2 low
    add_package "$ws" p1
    add_package "$ws" q
    write_srcinfo "$ws/packages/p1" p1
    write_srcinfo "$ws/packages/q" q q-libs # split output: two names under test

    conf_ok=$tmp/conf-ok
    cat >"$conf_ok" <<EOF
# Repeated IgnorePkg lines inside [options] ACCUMULATE (Q16 semantics), and a
# repo section's IgnorePkg line is silently dropped.
[options]
IgnorePkg = p1
IgnorePkg = q   q-libs

[cachyos]
Include = /etc/pacman.d/cachyos-mirrorlist
IgnorePkg = decoy-repo-section
EOF
    lint "$ws" ignorepkg "$conf_ok"
    ((FIXTURE_RC == 0)) || fail "C: clean case failed (rc=$FIXTURE_RC)"
    grep -Fq 'audit-lint ignorepkg: clean' <<<"$FIXTURE_OUTPUT" ||
        fail "C: cumulative [options] lines must cover every name, got: $FIXTURE_OUTPUT"

    # Drop conf: the pre-header line belongs to no section, the [core] line is
    # repo-scoped, and a commented line is not a directive — all three names
    # must come back as findings.
    conf_drop=$tmp/conf-drop
    cat >"$conf_drop" <<EOF
IgnorePkg = p1
[core]
IgnorePkg = q q-libs
[options]
# IgnorePkg = q
EOF
    lint "$ws" ignorepkg "$conf_drop"
    ((FIXTURE_RC == 0)) || fail "C: --audit-lint must stay report-only (rc=$FIXTURE_RC)"
    for name in p1 q q-libs; do
        grep -Fq "ignorepkg: $name is not in the IgnorePkg closure of $conf_drop" \
            <<<"$FIXTURE_OUTPUT" ||
            fail "C: '$name' must be reported when its only IgnorePkg line is dropped, got: $FIXTURE_OUTPUT"
    done
    grep -Fq 'audit-lint ignorepkg: 3 finding(s)' <<<"$FIXTURE_OUTPUT" ||
        fail "C: wrong finding count (comment/pre-header/repo lines must not count): $FIXTURE_OUTPUT"

    # Inline comments strip after the names; the names before '#' still count.
    conf_comment=$tmp/conf-comment
    cat >"$conf_comment" <<EOF
[options]
IgnorePkg = p1 # trailing comment
IgnorePkg = q q-libs
EOF
    lint "$ws" ignorepkg "$conf_comment"
    grep -Fq 'audit-lint ignorepkg: clean' <<<"$FIXTURE_OUTPUT" ||
        fail "C: inline comments must strip after the names, got: $FIXTURE_OUTPUT"

    # An [options] Include cannot be followed here: report it instead of
    # silently under-counting the closure.
    conf_include=$tmp/conf-include
    cat >"$conf_include" <<EOF
[options]
Include = $tmp/extra.conf
IgnorePkg = p1 q q-libs
EOF
    lint "$ws" ignorepkg "$conf_include"
    grep -Fq "ignorepkg: $conf_include: [options] Include is not followed — inline its IgnorePkg entries into the file" \
        <<<"$FIXTURE_OUTPUT" ||
        fail "C: an [options] Include must be reported, got: $FIXTURE_OUTPUT"
    grep -Fq 'audit-lint ignorepkg: 1 finding(s)' <<<"$FIXTURE_OUTPUT" ||
        fail "C: the Include finding must be the only one when all names are covered, got: $FIXTURE_OUTPUT"

    # Q17: the ONLY skip condition is an unreadable conf — and it says so.
    lint "$ws" ignorepkg "$tmp/no-such.conf"
    ((FIXTURE_RC == 0)) || fail "C: skip must stay report-only (rc=$FIXTURE_RC)"
    grep -Fq "ignorepkg: skipped — $tmp/no-such.conf is not readable" <<<"$FIXTURE_OUTPUT" ||
        fail "C: skip must name the unreadable conf, got: $FIXTURE_OUTPUT"
    grep -Fq 'audit-lint ignorepkg: skipped' <<<"$FIXTURE_OUTPUT" ||
        fail "C: skip must be visible in the verdict line, got: $FIXTURE_OUTPUT"
    printf 'C: IgnorePkg semantics + skip OK\n'
)

# ─── D. --audit renders the lints and stays report-only (Q20) ────────────────
(
    set -euo pipefail
    ws=$tmp/audit-ws
    make_workspace "$ws" 1 2 low
    add_package "$ws" prov-git
    write_srcinfo "$ws/packages/prov-git" prov-git
    printf '\tprovides = libfoo.so=2-64\n' >>"$ws/packages/prov-git/.SRCINFO"

    run_builder fish "$ws/build-all.fish" --audit
    ((FIXTURE_RC == 0)) ||
        fail "D: --audit must exit 0 even with findings (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    for heading in 'Provides versioning:' 'Purged tools:' 'IgnorePkg closure:'; do
        grep -Fq "$heading" <<<"$FIXTURE_OUTPUT" ||
            fail "D: --audit is missing the '$heading' section: $FIXTURE_OUTPUT"
    done
    grep -Fq 'provides: prov-git: soname provide' <<<"$FIXTURE_OUTPUT" ||
        fail "D: --audit must render the lint findings, got: $FIXTURE_OUTPUT"
    printf 'D: --audit integration + report-only OK\n'
)

# ─── E. real-repo gates ──────────────────────────────────────────────────────
(
    set -euo pipefail
    run_builder fish "$root/build-all.fish" --audit-lint provides
    ((FIXTURE_RC == 0)) || fail "E: real-repo provides lint failed (rc=$FIXTURE_RC)"

    # The SONAME side and the constraint side stay strictly forbidden on the
    # real repo (P2 debt cleared 2026-10-04: bare stems only; an unversioned
    # provide of a constrained name is the meson-incident class). The NAME
    # mapping side carries the Q8 debt register instead: the 2026-10-04 scope
    # decision (SONAME + NAME) was audited the same day, and these recipes
    # still declare mapped names unversioned. More than five, so recipe work
    # stays gated — version one (declare provides=('<name>=$pkgver')) or
    # update this ratchet consciously.
    if grep '^provides: ' <<<"$FIXTURE_OUTPUT" | grep -v ' mapped swap/compat provide ' | grep -q .; then
        fail "E: soname/constraint provides finding on the real repo: $FIXTURE_OUTPUT"
    fi
    sed -n "s/^provides: \([^:]*\): mapped swap\/compat provide '\([^']*\)' is unversioned.*/\1: \2/p" \
        <<<"$FIXTURE_OUTPUT" | LC_ALL=C sort >"$tmp/mapping.actual"
    cat >"$tmp/mapping.expected" <<'EOF'
blender-git: blender
bpftune-git: bpftune
dbus-broker-git: dbus-broker
dbus-broker-git: dbus-broker-units
dbus-broker-git: dbus-units
dbus-broker: dbus-units
dbus: libdbus
easyeffects-git: easyeffects
emacs: emacs
fcitx5-chinese-addons-git: fcitx5-chinese-addons
fcitx5-git: fcitx5
fcitx5-gtk-git: fcitx5-gtk
fcitx5-lua-git: fcitx5-lua
fcitx5-qt-git: fcitx5-qt
fcitx5-qt-git: fcitx5-qt5
fcitx5-qt-git: fcitx5-qt6
flatpak-git: flatpak
freeglut: glut
gcc-snapshot: gcc
gcc-snapshot: gcc-fortran
gcc-snapshot: gcc-fortran-multilib
gcc-snapshot: gcc-libs-multilib
gcc-snapshot: gcc-multilib
gcc-snapshot: lib32-gcc-libs
gcc-snapshot: libasan
gcc-snapshot: libatomic
gcc-snapshot: libgcc
gcc-snapshot: libgccjit
gcc-snapshot: libgfortran
gcc-snapshot: libgomp
gcc-snapshot: libitm
gcc-snapshot: liblsan
gcc-snapshot: libquadmath
gcc-snapshot: libstdc++
gcc-snapshot: libtsan
gcc-snapshot: libubsan
gcc-snapshot: lto-dump
gimp-git: gimp
git-git: git
gtk3-git: gtk3-print-backends
jack2-git: jack
jack2-git: jack2-dbus
kmod-git: kmod
libadwaita-git: libadwaita
libcamera-git: libcamera-ipa
libclc-git: libclc
libdex-git: libdex
libdrm-git: libdrm
libime-git: libime
libinput-git: libinput
libisl-git: isl
libisl-git: libisl
liburing-git: liburing
libva-git: libva
llvm-git: clang
llvm-git: clang-opencl-headers
llvm-git: compiler-rt
llvm-git: lld
llvm-git: llvm
llvm-git: llvm-libs
logseq-desktop-git: logseq
logseq-desktop-git: logseq-desktop
mesa-git: libva-mesa-driver
mesa-git: mesa
mesa-git: mesa-libgl
mesa-git: vulkan-intel
mesa-git: vulkan-mesa-device-select
mesa-git: vulkan-mesa-implicit-layers
mesa-git: vulkan-mesa-layers
mesa-git: vulkan-nouveau
mesa-git: vulkan-radeon
mesa-git: vulkan-swrast
mesa-git: vulkan-virtio
mimalloc-git: mimalloc
nghttp3-git: nghttp3
noctalia-git: noctalia
onlyoffice-git: onlyoffice
onlyoffice-git: onlyoffice-desktopeditors
pango-git: pango
pipewire: pulse-native-provider
pyside6-git: pyside6
pyside6-git: shiboken6
qt6-base-git: qt6-base
qt6-base-git: qt6-xcb-private-headers
rust-bindgen-git: rust-bindgen
rust-git: cargo
rust-git: rust
rust-git: rust-src
rust-git: rustfmt
seatd-git: libseat
seatd-git: seatd
spirv-llvm-translator-git: spirv-llvm-translator
systemd: libsystemd
systemd: nss-myhostname
systemd: resolvconf
util-linux: hardlink
util-linux: libutil-linux
util-linux: rfkill
vencord-git: vencord
vscodium-insiders-git: codium
vscodium-insiders-git: vscodium
vulkan-icd-loader-git: vulkan-icd-loader
wireplumber: pipewire-session-manager
xcb-imdkit-git: xcb-imdkit
xdg-desktop-portal-gnome-git: xdg-desktop-portal-gnome
xdg-desktop-portal-gtk-git: xdg-desktop-portal-gtk
xorg-xwayland-git: xorg-server-xwayland
xorg-xwayland-git: xorg-server-xwayland-git
xorg-xwayland-git: xorg-xwayland
xwayland-satellite-git: xwayland-satellite
zlib-ng-compat-git: zlib
zlib-ng-git: zlib-ng
zstd-git: zstd
EOF
    LC_ALL=C sort -o "$tmp/mapping.expected" "$tmp/mapping.expected"
    diff -u "$tmp/mapping.expected" "$tmp/mapping.actual" >&2 ||
        fail "E: the mapped-name versioned-provides debt drifted — fix the recipe (declare provides=(<name>=\${pkgver})) or update this ratchet consciously"

    run_builder fish "$root/build-all.fish" --audit-lint purged
    ((FIXTURE_RC == 0)) || fail "E: real-repo purged lint failed (rc=$FIXTURE_RC)"
    grep -Fq 'audit-lint purged: clean' <<<"$FIXTURE_OUTPUT" ||
        fail "E: a purged tool re-entered the workspace: $FIXTURE_OUTPUT"

    run_builder fish "$root/build-all.fish" --audit-lint ignorepkg
    ((FIXTURE_RC == 0)) || fail "E: real-repo ignorepkg lint failed (rc=$FIXTURE_RC)"
    if [[ -r /etc/pacman.conf ]]; then
        grep -Fq 'audit-lint ignorepkg: clean' <<<"$FIXTURE_OUTPUT" ||
            fail "E: a workspace pkgname is missing from the IgnorePkg closure: $FIXTURE_OUTPUT"
    else
        # Q17: the gate skips exactly here, and says so.
        grep -Fq "ignorepkg: skipped — /etc/pacman.conf is not readable" <<<"$FIXTURE_OUTPUT" ||
            fail "E: unreadable /etc/pacman.conf must produce the skip line, got: $FIXTURE_OUTPUT"
    fi
    printf 'E: real-repo gates OK\n'
)

printf 'recipe contract fixture: PASS (3 lint seams gated, real-repo gates green)\n'
