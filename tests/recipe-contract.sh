#!/usr/bin/env bash
set -euo pipefail

# Recipe-contract lints: provides versioning and the purged-tools denylist (the
# static IgnorePkg closure lint was retired 2026-10-05 in favour of dynamic
# install-time registration). One implementation per rule lives in
# build-all.fish (audit_lint_provides / audit_lint_purged);
# `fish build-all.fish --audit` renders them in its report and the hidden
# `--audit-lint <name>` seam runs one of them — the seam is the interface, and
# this fixture is its gating walker (red/green per rule, then the real-repo
# gates).
#
# Enforcement mapping (the settled two-tier rule):
#   deterministic + must-gate  provides-versioning, purged-tools → --audit
#                              lints, GATED here (fixture rc, never --audit's);
#   heavy/ELF                  soname-presence → tools/provides-audit.sh pair.
# PGP procedure and trimming stay docs-only by the same mapping.
#
# Section F pins the CLI name surface instead of a lint: pkgbase + pkgname from
# a recipe's committed .SRCINFO both resolve as package references, and an
# unknown name is refused (red-first probe, see the section's header).
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

# lint WORKSPACE NAME — run one audit lint through the seam.
lint() {
    local ws=$1 name=$2
    run_builder fish "$ws/build-all.fish" --audit-lint "$name"
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
    for heading in 'Provides versioning:' 'Purged tools:'; do
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
seatd-git: libseat
seatd-git: seatd
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

    printf 'E: real-repo gates OK\n'
)

# ─── F. one name surface: pkgbase + pkgname resolve as CLI references ────────
# The CLI name surface is the union of a recipe's committed-.SRCINFO pkgbase
# and pkgname rows — `_pkgname_index`/`_pkgname_owner` in build-all.fish is the
# one index both feed. The discriminating shape is a recipe whose pkgbase
# differs from its id AND its outputs ("pkgbase-only name"): only an index that
# carries the pkgbase rows resolves it. A genuinely unknown name is still
# refused with the unresolved token reported — a typo is never auto-corrected,
# because a wrong guess would build the wrong recipe and its consumer closure.
#
# The four assertions, in contract order:
#   (1) id reference 'rec-a' — the baseline selection;
#   (2) pkgbase-only reference 'base-only' — same selection as (1), exactly
#       recipe rec-a ONCE; this is the red-first probe and deliberately runs
#       LAST, so a red run still executes and proves (1)/(3)/(4) before it
#       fails exactly where the contract is unimplemented;
#   (3) pkgname reference 'rec-a-out' — must keep resolving to rec-a;
#   (4) unknown reference — non-zero exit, the token reported, no selection.
# (2) is RED against an index that lacks pkgbase rows and GREEN once the index
# is the pkgbase+pkgname union — red-first is the fixture's purpose.
#
# Selection surface: --dry-run returns before the run record is registered
# (the build path registers its plan afterwards), so the numbered build-order
# rows are the stable machine-checkable selection output. The assertions parse
# only those rows and never prose wording, so an unrelated output-format change
# cannot flip them; "exactly rec-a" also fails on a duplicated row.
(
    set -euo pipefail
    ws=$tmp/namesurface-ws
    make_workspace "$ws" 1 2 low

    # rec-b is a decoy: not a consumer of rec-a, so it must never appear in
    # any of these selections — "exactly rec-a" means the closure is one row.
    add_package "$ws" rec-b
    write_srcinfo "$ws/packages/rec-b" rec-b

    # rec-a: pkgbase 'base-only' differs from the recipe id AND the sole
    # pkgname output 'rec-a-out'. PKGBUILD and .SRCINFO carry the same names;
    # the index reads the committed .SRCINFO, never the PKGBUILD.
    add_package "$ws" rec-a
    cat >"$ws/packages/rec-a/PKGBUILD" <<'EOF'
pkgbase=base-only
pkgname=(rec-a-out)
EOF
    printf 'pkgbase = base-only\npkgname = rec-a-out\n' >"$ws/packages/rec-a/.SRCINFO"

    # dry_order OUTPUT — the build-order rows only ("  %2d. %s"), one per line.
    dry_order() {
        awk '/^[[:space:]]*[0-9]+\. / { sub(/^[[:space:]]*[0-9]+\. /, ""); print }' <<<"$1"
    }
    # assert_rec_a_only LABEL OUTPUT — the run selected exactly recipe rec-a.
    assert_rec_a_only() {
        local label=$1 out=$2 order
        order=$(dry_order "$out")
        [[ $order == rec-a ]] ||
            fail "F: $label must select exactly recipe 'rec-a' (once), got: ${order:-<no build order>} | output: $out"
    }

    # (1) id reference: baseline selection.
    run_builder fish "$ws/build-all.fish" --dry-run rec-a
    ((FIXTURE_RC == 0)) || fail "F: id reference 'rec-a' failed (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    assert_rec_a_only "id reference 'rec-a'" "$FIXTURE_OUTPUT"
    id_order=$(dry_order "$FIXTURE_OUTPUT")

    # (3) pkgname reference: the output name keeps resolving to its recipe.
    run_builder fish "$ws/build-all.fish" --dry-run rec-a-out
    ((FIXTURE_RC == 0)) || fail "F: pkgname reference 'rec-a-out' failed (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    assert_rec_a_only "pkgname reference 'rec-a-out'" "$FIXTURE_OUTPUT"

    # (4) unknown reference: refused, named, and it selects nothing.
    run_builder fish "$ws/build-all.fish" --dry-run definitely-not-a-package
    ((FIXTURE_RC != 0)) || fail "F: unknown reference 'definitely-not-a-package' must exit non-zero, got rc=0: $FIXTURE_OUTPUT"
    grep -Fq 'definitely-not-a-package' <<<"$FIXTURE_OUTPUT" ||
        fail "F: the unknown reference must be reported by name, got: $FIXTURE_OUTPUT"
    unknown_order=$(dry_order "$FIXTURE_OUTPUT")
    [[ -z $unknown_order ]] ||
        fail "F: an unknown reference must not select anything, got order: $unknown_order | output: $FIXTURE_OUTPUT"

    # (2) pkgbase-only reference (red-first probe, last on purpose): must
    # resolve to rec-a exactly like the id does — same selection, one row.
    run_builder fish "$ws/build-all.fish" --dry-run base-only
    ((FIXTURE_RC == 0)) ||
        fail "F: pkgbase-only reference 'base-only' must resolve like the id (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    assert_rec_a_only "pkgbase reference 'base-only'" "$FIXTURE_OUTPUT"
    base_order=$(dry_order "$FIXTURE_OUTPUT")
    [[ $base_order == "$id_order" ]] ||
        fail "F: pkgbase reference must select what the id selects ('"$id_order"'), got: $base_order"

    printf 'F: one name surface (pkgbase + pkgname) + unknown-name refusal OK\n'
)

# ─── F mutation probes (documented, NOT run here: they need the name-surface
# implementation first). Each probe is a one-spot perturbation of build-all.fish
# followed by `bash tests/recipe-contract.sh` → the named assertion goes red;
# REVERSE the edit (paste the original line back — never `git checkout`/`git
# stash`) → green again. Line numbers are the 2026-10-05 anchors and drift;
# the function names are the stable handles.
#   M1 pkgbase half of the surface: in `_pkgname_index` (build-all.fish:7233,
#      the row sweep around `sed -n 's/^pkgname = //p'`), keep only the pkgname
#      rows and drop the pkgbase rows → assertion (2) red; reverse → green.
#      This probe reproduces the pre-change state the fixture is red against.
#   M2 pkgname half: in the same sweep keep only the pkgbase rows → assertion
#      (3) red; reverse → green.
#   M3 wrong owner: make the sweep emit one extra row `base-only|rec-b` (or
#      make `_pkgname_owner`, build-all.fish:7249, return a second owner) →
#      assertion (2)'s "exactly rec-a, once" check red; reverse → green.
#   M4 unknown-name refusal: make `canonicalize_pkg_ref` (build-all.fish:7384)
#      echo a known id instead of the unresolved token, or make the
#      `_report_unknown_ref` call site (build-all.fish:11333) not `return 1`
#      → assertion (4) red; reverse → green.
# ─────────────────────────────────────────────────────────────────────────────

printf 'recipe contract fixture: PASS (2 lint seams gated, name surface pinned, real-repo gates green)\n'
