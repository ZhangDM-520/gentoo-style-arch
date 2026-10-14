#!/usr/bin/env bash
set -euo pipefail

# Recipe-contract lints: provides versioning and the purged-tools denylist (the
# static IgnorePkg closure lint was retired 2026-10-05 in favour of dynamic
# install-time registration). One implementation per rule lives in the
# engine's QA registry (crates/gsa-qa/src/checks.rs `provides-versioning` /
# `purged-tools` — the ports of build-all.fish audit_lint_provides /
# audit_lint_purged); `gsa -Ma` renders them in its report and the hidden
# `gsa --qa-check <name>` seam (contract §D.1) runs one of them — the seam is
# the interface, and this fixture is its gating walker (red/green per rule,
# then the real-repo gates).
#
# Enforcement mapping (the settled two-tier rule):
#   deterministic + must-gate  provides-versioning, purged-tools → QA lints,
#                              GATED here (fixture rc, never -Ma's);
#   heavy/ELF                  soname-presence → tools/provides-audit.sh pair.
# PGP procedure and trimming stay docs-only by the same mapping.
#
# Section F pins the CLI name surface instead of a lint: pkgbase + pkgname from
# a recipe's committed .SRCINFO both resolve as package references, and an
# unknown name is refused (red-first probe, see the section's header).
#
# Every scratch workspace and conf lives under $TMPDIR; the real-repo sections
# are read-only.

# Flip notes (docs/gsa-fixture-migration.md row `tests/recipe-contract.sh`):
# argv `--audit-lint <provides|purged>` flips to the hidden
# `gsa --qa-check <provides-versioning|purged-tools>` seam (§D.1). DEVIATION
# (inventory's "gsa --qa-check <name>" is satisfied, but the NAMES differ from
# the fish families): the registry renames the ports — `provides` →
# `provides-versioning`, `purged` → `purged-tools` (plus `swap-drift` for the
# fish `swap` family) — and never auto-corrects a name (§C.1 discipline).
# Finding lines re-pin as §E.4 rows (`<check>: <subject>: <detail>`); the
# detail sentences are byte-identical ports of the fish wording, so the
# meaning pins assert the staged DATA they carry; the `audit-lint …` tallies
# become `qa-check …` and the `--audit` section headings (`Provides
# versioning:`/`Purged tools:`) retire (§L.3) for `-Ma`'s `recipe-contract`
# family rows (§B.7/§E.4, report-only). Section F's `--dry-run` flips to
# `gsa -B --dry-run <ref>` (the §B.1 family form; §C.1 is the name surface):
# the fish numbered build-order rows retire for the run record's `order`
# scalar (§H.2 — record-derived, rule 25(j)); an unknown ref is §G.1's usage
# class (2), naming the token (§C.1: a typo is never auto-corrected). Like
# tests/project.sh, dry-run scalars are read through a local extractor: a
# `--dry-run` record carries `lanes: -`, which rr2_body's integer rule
# rejects (gap G12).
# DEVIATION (inventory KEEP :390-441 pins the FULL fish name surface: "the
# union of a recipe's committed-.SRCINFO pkgbase and pkgname rows"): the
# engine's §C.1 surface resolves ids, case-variants, paths and PKGNAMES, but
# NOT a pkgbase-only name — RecipeDb::load indexes `meta.pkgnames()`
# (crates/gsa-recipe/src/lib.rs:602/:748: pkgname rows, pkgbase only as the
# no-pkgname fallback), so select.rs `resolve_ref`'s by_pkgname lookup never
# sees 'base-only' and §C.1's enumeration ("a pacman pkgname including a
# split output") does not carry it. Assertion (2) — the pkgbase-only probe —
# therefore STAYS FISH-DRIVEN (the escape for missing machinery applies at
# the finest granularity that preserves the KEEP); (1)/(3)/(4) flip to
# `gsa -B --dry-run`. If the owner decides §C.1 grows pkgbase rows, (2)
# flips with the rest and this note retires.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$root/tests/lib/fixture-lib.bash"
source "$root/tests/lib/rr-v2.bash"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-recipe-contract.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'recipe contract fixture: %s\n' "$1" >&2
    exit 1
}

# ─── The engine under test: built into the fixture tree (scratch only).
# GSA_TEST_GSA_BIN, when already set to an executable, is that engine (the
# rr-v2.bash run_engine convention) and the scratch build is skipped. ──────
if [ -z "${GSA_TEST_GSA_BIN:-}" ]; then
    cargo build --offline --quiet --target-dir "$tmp/cargo" -p gsa-cli \
        --manifest-path "$gsa_repo_root/Cargo.toml" ||
        fail "cannot build the gsa binary for the fixture"
    GSA_TEST_GSA_BIN="$tmp/cargo/debug/gsa"
fi
[ -x "$GSA_TEST_GSA_BIN" ] || fail "the engine under test is not executable: $GSA_TEST_GSA_BIN"
export GSA_TEST_ENGINE=gsa
export GSA_TEST_GSA_BIN
export GSA_STATE_DIR="$tmp/state"

# lint WORKSPACE NAME — run one QA check through the seam.
lint() {
    local ws=$1 name=$2
    run_engine "$ws" --qa-check "$name"
}

# rr_dry_scalar KEY — one scalar of a `--dry-run` run record. rr2_body rejects
# that record shape (the flip notes: `lanes: -` vs its integer rule), so the
# dry-run record is read through this extractor; real-run records would go
# through rr2_* unchanged.
rr_dry_scalar() {
    printf '%s\n' "$FIXTURE_OUTPUT" | awk -v key="$1" '
        /^--- run record begin ---$/ { inb = 1; next }
        /^--- plan ---$/ { exit }
        inb {
            p = index($0, ":")
            if (p && substr($0, 1, p - 1) == key) {
                v = substr($0, p + 1); sub(/^ /, "", v); print v; found = 1; exit
            }
        }
        END {
            if (!found) {
                printf("rr_dry_scalar: no %s scalar in the dry-run record\n", key) > "/dev/stderr"
                exit 1
            }
        }'
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

    lint "$ws" provides-versioning
    if ((FIXTURE_RC != 0)); then
        fail "A: --qa-check must stay report-only while findings exist (rc=$FIXTURE_RC)"
    fi
    grep -Fq "provides-versioning: prov-git: unversioned provide 'meson' cannot satisfy 'meson>=1.8' (required by consumer-git) — version it as provides=('meson=\${pkgver}')" \
        <<<"$FIXTURE_OUTPUT" ||
        fail "A: missing or wrong P1 finding, got: $FIXTURE_OUTPUT"

    # P2/P3 soname forms, plus the BARE stem that must NOT be flagged.
    printf '\tprovides = libfoo.so=2-64\n' >>"$ws/packages/libs-git/.SRCINFO"
    printf '\tprovides = libbar.so.1\n' >>"$ws/packages/libs-git/.SRCINFO"
    printf '\tprovides = libbaz.so\n' >>"$ws/packages/libs-git/.SRCINFO"
    lint "$ws" provides-versioning
    grep -Fq "provides-versioning: libs-git: soname provide 'libfoo.so=2-64' is hand-versioned — declare the bare stem 'libfoo.so' and let makepkg auto-version it from the built ELF" \
        <<<"$FIXTURE_OUTPUT" ||
        fail "A: missing P2 finding, got: $FIXTURE_OUTPUT"
    grep -Fq "provides-versioning: libs-git: soname provide 'libbar.so.1' names a versioned soname — declare the bare stem 'libbar.so'" \
        <<<"$FIXTURE_OUTPUT" ||
        fail "A: missing P3 finding, got: $FIXTURE_OUTPUT"
    grep -Fq 'libbaz.so' <<<"$FIXTURE_OUTPUT" &&
        fail "A: a bare soname stem is the correct form and must not be flagged: $FIXTURE_OUTPUT"
    grep -Fq 'qa-check provides-versioning: 3 finding(s)' <<<"$FIXTURE_OUTPUT" ||
        fail "A: wrong finding count, got: $FIXTURE_OUTPUT"

    # Green: versioned provide for the constrained name, bare soname stems.
    write_srcinfo "$ws/packages/prov-git" prov-git
    printf '\tprovides = meson=1.8.0\n' >>"$ws/packages/prov-git/.SRCINFO"
    write_srcinfo "$ws/packages/libs-git" libs-git
    printf '\tprovides = libbaz.so\n' >>"$ws/packages/libs-git/.SRCINFO"
    lint "$ws" provides-versioning
    ((FIXTURE_RC == 0)) || fail "A: green case failed (rc=$FIXTURE_RC)"
    grep -Fq 'qa-check provides-versioning: clean' <<<"$FIXTURE_OUTPUT" ||
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

    lint "$ws" provides-versioning
    ((FIXTURE_RC == 0)) || fail "A: Q8 red case must stay report-only (rc=$FIXTURE_RC)"
    for pair in "swap-git: stocklib" "map-git: map" "compat: compat" "cross: compat-b"; do
        id=${pair%%: *}
        name=${pair#*: }
        grep -Fq "provides-versioning: $id: mapped swap/compat provide '$name' is unversioned" \
            <<<"$FIXTURE_OUTPUT" ||
            fail "A: missing Q8 mapping finding for '$pair', got: $FIXTURE_OUTPUT"
    done
    grep -Fq 'qa-check provides-versioning: 4 finding(s)' <<<"$FIXTURE_OUTPUT" ||
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
    lint "$ws" provides-versioning
    ((FIXTURE_RC == 0)) || fail "A: Q8 green case failed (rc=$FIXTURE_RC)"
    grep -Fq 'qa-check provides-versioning: clean' <<<"$FIXTURE_OUTPUT" ||
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
    lint "$ws" purged-tools
    ((FIXTURE_RC == 0)) || fail "B: --qa-check must stay report-only (rc=$FIXTURE_RC)"
    grep -Fq "purged-tools: tools-git: makedepends reintroduces purged tool 'python-sphinx' — remove it (docs/MEMORY.md rule 8)" \
        <<<"$FIXTURE_OUTPUT" ||
        fail "B: missing makedepends finding, got: $FIXTURE_OUTPUT"
    grep -Fq "purged-tools: tools-git: checkdepends reintroduces purged tool 'po4a' — remove it (docs/MEMORY.md rule 8)" \
        <<<"$FIXTURE_OUTPUT" ||
        fail "B: missing checkdepends finding, got: $FIXTURE_OUTPUT"
    grep -Fq 'qa-check purged-tools: 2 finding(s)' <<<"$FIXTURE_OUTPUT" ||
        fail "B: the denylist must match exact names only (count != 2): $FIXTURE_OUTPUT"

    write_srcinfo "$ws/packages/tools-git" tools-git
    printf '\tmakedepends = python-sphinx-theme\n' >>"$ws/packages/tools-git/.SRCINFO"
    lint "$ws" purged-tools
    grep -Fq 'qa-check purged-tools: clean' <<<"$FIXTURE_OUTPUT" ||
        fail "B: expected a clean verdict, got: $FIXTURE_OUTPUT"
    printf 'B: purged-tools denylist red/green OK\n'
)

# ─── D. `gsa -Ma` renders the lints and stays report-only (Q20) ──────────────
(
    set -euo pipefail
    ws=$tmp/audit-ws
    make_workspace "$ws" 1 2 low
    add_package "$ws" prov-git
    write_srcinfo "$ws/packages/prov-git" prov-git
    printf '\tprovides = libfoo.so=2-64\n' >>"$ws/packages/prov-git/.SRCINFO"

    run_engine "$ws" -Ma
    ((FIXTURE_RC == 0)) ||
        fail "D: -Ma must exit 0 even with findings (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    grep -Eq '^audit recipe-contract (clean|[0-9]+ finding\(s\))$' <<<"$FIXTURE_OUTPUT" ||
        fail "D: -Ma is missing the recipe-contract QA family: $FIXTURE_OUTPUT"
    grep -Fq 'recipe-contract provides-versioning: prov-git soname provide' <<<"$FIXTURE_OUTPUT" ||
        fail "D: -Ma must render the lint findings, got: $FIXTURE_OUTPUT"
    printf 'D: -Ma integration + report-only OK\n'
)

# ─── E. real-repo gates ──────────────────────────────────────────────────────
(
    set -euo pipefail
    run_engine "$root" --qa-check provides-versioning
    ((FIXTURE_RC == 0)) || fail "E: real-repo provides lint failed (rc=$FIXTURE_RC)"

    # The SONAME side and the constraint side stay strictly forbidden on the
    # real repo (P2 debt cleared 2026-10-04: bare stems only; an unversioned
    # provide of a constrained name is the meson-incident class). The NAME
    # mapping side carries the Q8 debt register instead: the 2026-10-04 scope
    # decision (SONAME + NAME) was audited the same day, and these recipes
    # still declare mapped names unversioned. More than five, so recipe work
    # stays gated — version one (declare provides=('<name>=$pkgver')) or
    # update this ratchet consciously.
    if grep '^provides-versioning: ' <<<"$FIXTURE_OUTPUT" | grep -v ' mapped swap/compat provide ' | grep -q .; then
        fail "E: soname/constraint provides finding on the real repo: $FIXTURE_OUTPUT"
    fi
    sed -n "s/^provides-versioning: \([^:]*\): mapped swap\/compat provide '\([^']*\)' is unversioned.*/\1: \2/p" \
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

    run_engine "$root" --qa-check purged-tools
    ((FIXTURE_RC == 0)) || fail "E: real-repo purged lint failed (rc=$FIXTURE_RC)"
    grep -Fq 'qa-check purged-tools: clean' <<<"$FIXTURE_OUTPUT" ||
        fail "E: a purged tool re-entered the workspace: $FIXTURE_OUTPUT"

    printf 'E: real-repo gates OK\n'
)

# ─── F. one name surface: pkgbase + pkgname resolve as CLI references ────────
# The CLI name surface is the union of a recipe's committed-.SRCINFO pkgbase
# and pkgname rows (crates/gsa-recipe/src/lib.rs `SrcinfoRows::names` is the
# one index both feed, reached through crates/gsa-cli/src/select.rs
# `resolve_ref`). The discriminating shape is a recipe whose pkgbase differs
# from its id AND its outputs ("pkgbase-only name"): only an index that
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
#   (4) unknown reference — rc 2 (§G.1), the token reported (§C.1), no
#       selection.
# (2) is RED against an index that lacks pkgbase rows and GREEN once the index
# is the pkgbase+pkgname union — red-first is the fixture's purpose.
#
# Selection surface: the `--dry-run` record's `order` scalar (§H.2) is the
# stable machine-checkable selection output (rule 25(j): derived from the
# record, never prose). "Exactly rec-a" also fails on a duplicated row.
(
    set -euo pipefail
    ws=$tmp/namesurface-ws
    make_workspace "$ws" 1 2 low
    install_fish_oracle "$ws"

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

    # assert_rec_a_only LABEL — the run selected exactly recipe rec-a.
    assert_rec_a_only() {
        local label=$1 order
        order=$(rr_dry_scalar order) || order='<no order scalar>'
        [[ $order == rec-a ]] ||
            fail "F: $label must select exactly recipe 'rec-a' (once), got: ${order:-<no build order>} | output: $FIXTURE_OUTPUT"
    }

    # dry_order OUTPUT — the fish dry-run's numbered build-order rows, used
    # by the fish-driven (2) half below.
    dry_order() {
        awk '/^[[:space:]]*[0-9]+\. / { sub(/^[[:space:]]*[0-9]+\. /, ""); print }' <<<"$1"
    }

    # (1) id reference: baseline selection (engine).
    run_engine "$ws" -B --dry-run rec-a
    ((FIXTURE_RC == 0)) || fail "F: id reference 'rec-a' failed (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    assert_rec_a_only "id reference 'rec-a'"
    id_order=$(rr_dry_scalar order)

    # (3) pkgname reference: the output name keeps resolving to its recipe.
    run_engine "$ws" -B --dry-run rec-a-out
    ((FIXTURE_RC == 0)) || fail "F: pkgname reference 'rec-a-out' failed (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    assert_rec_a_only "pkgname reference 'rec-a-out'"

    # (4) unknown reference: refused (§G.1 rc 2), named (§C.1), no selection.
    run_engine "$ws" -B --dry-run definitely-not-a-package
    ((FIXTURE_RC == 2)) || fail "F: unknown reference must exit 2 (§G.1 usage), got rc=$FIXTURE_RC: $FIXTURE_OUTPUT"
    grep -Fq -- 'definitely-not-a-package' <<<"$FIXTURE_OUTPUT" ||
        fail "F: the unknown reference must be reported by name, got: $FIXTURE_OUTPUT"
    if grep -Fq -- '--- run record begin ---' <<<"$FIXTURE_OUTPUT"; then
        fail "F: an unknown reference must not select anything (a record appeared), got: $FIXTURE_OUTPUT"
    fi

    # (2) pkgbase-only reference (red-first probe, last on purpose): must
    # resolve to rec-a exactly like the id does — same selection, one row.
    # FISH-DRIVEN (DEVIATION in the flip notes: the engine's §C.1 surface
    # indexes pkgname rows only; the pkgbase half of the fish name surface
    # has no engine machinery yet).
    run_builder fish "$ws/build-all.fish" --dry-run base-only
    ((FIXTURE_RC == 0)) ||
        fail "F: pkgbase-only reference 'base-only' must resolve like the id (rc=$FIXTURE_RC): $FIXTURE_OUTPUT"
    base_order=$(dry_order "$FIXTURE_OUTPUT")
    [[ $base_order == rec-a ]] ||
        fail "F: pkgbase reference 'base-only' must select exactly recipe 'rec-a' (once), got: ${base_order:-<no build order>} | output: $FIXTURE_OUTPUT"
    [[ $base_order == "$id_order" ]] ||
        fail "F: pkgbase reference must select what the id selects ('"$id_order"'), got: $base_order"

    printf 'F: one name surface (pkgbase + pkgname) + unknown-name refusal OK (pkgbase half fish-driven, see flip notes)\n'
)

# ─── F mutation probes (documented, NOT run here). Each probe is a one-spot
# perturbation of the ENGINE source followed by `bash tests/recipe-contract.sh`
# → the named assertion goes red; REVERSE the edit (paste the original line
# back — never `git checkout`/`git stash`) → green again. The function names
# are the stable handles.
#   M1 pkgbase half of the surface: in `SrcinfoRows::names`
#      (crates/gsa-recipe/src/lib.rs:259) drop the pkgbase row and keep only
#      the pkgname rows → assertion (2) red; reverse → green.
#   M2 pkgname half: keep only the pkgbase row → assertion (3) red; reverse.
#   M3 wrong owner: make `resolve_ref` (crates/gsa-cli/src/select.rs:172)
#      resolve 'base-only' to rec-b as well → assertion (2)'s "exactly rec-a,
#      once" check red; reverse → green.
#   M4 unknown-name refusal: make `resolve_ref` map an unknown token to a
#      known id instead of `SelectError` (select.rs:158-161) → assertion (4)
#      red; reverse → green.
# ─────────────────────────────────────────────────────────────────────────────

printf 'recipe contract fixture: PASS (2 lint seams gated, name surface pinned, real-repo gates green)\n'
