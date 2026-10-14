#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
recipe="packages/git/texlive-texmf"
pkgbuild="$root/$recipe/PKGBUILD"

fail() {
    printf 'texlive-texmf recipe: %s\n' "$1" >&2
    exit 1
}

tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-texlive-recipe.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

# ─── The engine under test: built into the fixture tree (scratch only).
# GSA_TEST_GSA_BIN, when already set to an executable, is that engine and the
# scratch build is skipped. GSA_STATE_DIR stays in scratch too — this is a
# read-only real-tree fixture (migration §4 row, 2026-10-14). ────────────────
if [ -z "${GSA_TEST_GSA_BIN:-}" ]; then
    cargo build --offline --quiet --target-dir "$tmp/cargo" -p gsa-cli \
        --manifest-path "$root/Cargo.toml" ||
        fail "cannot build the gsa binary for the fixture"
    GSA_TEST_GSA_BIN="$tmp/cargo/debug/gsa"
fi
[ -x "$GSA_TEST_GSA_BIN" ] || fail "the engine under test is not executable: $GSA_TEST_GSA_BIN"
export GSA_TEST_GSA_BIN
export GSA_STATE_DIR="$tmp/state"

# Trimmed to texlive-meta and its depends closure: 22 non-lang collections.
expected_collections=(
    basic bibtexextra binextra context fontsextra fontsrecommended fontutils
    formatsextra games humanities latex latexextra latexrecommended luatex
    mathscience metapost music pictures plaingeneric pstricks publishers xetex
)
# The packages requested when the recipe was added.
requested=(
    texlive-meta
    texlive-bibtexextra texlive-binextra texlive-context texlive-fontsextra
    texlive-fontutils texlive-formatsextra texlive-games texlive-humanities
    texlive-latex texlive-latexextra texlive-latexrecommended texlive-luatex
    texlive-mathscience texlive-metapost texlive-music texlive-pictures
    texlive-publishers texlive-xetex
)
# Upstream support files the recipe ships next to the PKGBUILD.
support_files=(
    09-texlive-fonts.conf
    70-mktexlsr.hook
    71-texlive-language.hook
    72-texlive-fmtutil.hook
    73-texlive-updmap.hook
    80-mtxrun.hook
    mtxrun.script
    texlive-fmtutil.script
    texlive-language.script
    texlive-updmap.script
    texmf.cnf.patch
    minted-3.8.patch
)

assets=(PKGBUILD .SRCINFO .gitignore BUILDING REUSE.toml LICENSE list-collections
    .nvchecker.toml LICENSES/0BSD.txt LICENSES/GPL-2.0-or-later.txt
    "${support_files[@]}")
for asset in "${assets[@]}"; do
    test -e "$root/$recipe/$asset" || fail "missing asset: $recipe/$asset"
    if git -C "$root" check-ignore -q -- "$recipe/$asset"; then
        fail "asset is hidden by .gitignore: $recipe/$asset"
    fi
done

# Read the recipe the way the builder does; the PKGBUILD overrides the
# `source` builtin, so this runs in its own shell.
vars=$(bash -c '
    source "$1" || exit 1
    printf "pkgbase=%s\n" "${pkgbase:-}"
    printf "pkgver=%s\n" "${pkgver:-}"
    printf "pkgrel=%s\n" "${pkgrel:-}"
    printf "rev=%s\n" "${_rev:-}"
    printf "arch=%s\n" "${arch[@]}"
    printf "depends=%s\n" "${depends[@]}"
    printf "makedepends=%s\n" "${makedepends[@]}"
    printf "options=%s\n" "${options[@]}"
    printf "pkgname=%s\n" "${pkgname[@]}"
    printf "collections=%s\n" "${_collections[@]}"
    printf "source=%s\n" "${source[@]}"
' _ "$pkgbuild") || fail "cannot source the PKGBUILD"

field() {
    grep "^$1=" <<<"$vars" | cut -d= -f2-
}

has() {
    grep -Fxq "$1=$2" <<<"$vars"
}

test "$(field pkgbase)" = texlive-texmf || fail "pkgbase is not texlive-texmf"
test "$(field pkgrel)" = 1 || fail "pkgrel must stay 1 for parity with the repos"

mapfile -t collections < <(field collections)
if [[ "${collections[*]}" != "${expected_collections[*]}" ]]; then
    fail "collection set changed: ${collections[*]}"
fi

# pkgname must be exactly texlive-meta plus the retained collections: no lang*
# split and no texlive-doc may reappear. Check the trimmed names first so the
# failure names the offending split.
mapfile -t pkgnames < <(field pkgname)
for pkg in "${pkgnames[@]}"; do
    case "$pkg" in
        texlive-lang*|texlive-doc) fail "trimmed split came back: $pkg" ;;
    esac
done
test "${pkgnames[*]}" = "texlive-meta ${expected_collections[*]/#/texlive-}" ||
    fail "pkgname set changed: ${pkgnames[*]}"
for pkg in "${requested[@]}"; do
    grep -Fxq "$pkg" <<<"$(field pkgname)" || fail "requested package is not produced: $pkg"
done

# The build is driven entirely by the pinned TeX Live release: every SVN source
# must point at the tag matching pkgver and carry the same #revision pin.
pkgver=$(field pkgver)
rev=$(field rev)
test -n "$pkgver" || fail "pkgver is empty"
test -n "$rev" || fail "_rev is empty"
mapfile -t svn_sources < <(field source | grep -E '^svn(\+|://)')
test "${#svn_sources[@]}" -eq 3 || fail "expected 3 svn sources, found ${#svn_sources[@]}"
for src in "${svn_sources[@]}"; do
    [[ "$src" == *"tags/texlive-$pkgver/"* ]] ||
        fail "source does not track the pkgver tag: $src"
    [[ "$src" == *"#revision=$rev"* ]] ||
        fail "source is not pinned to _rev=$rev: $src"
done
# The upstream release signal ships with the recipe, as in the other 49 recipes
# that carry a .nvchecker.toml.
grep -Fq "regex = 'tags/texlive-([\\d.]+)'" "$root/$recipe/.nvchecker.toml" ||
    fail ".nvchecker.toml no longer tracks the texlive tag"

# Dependency, tooling, and optimisation contract.
has arch any || fail "arch is not any"
has depends texlive-bin || fail "missing depends: texlive-bin"
has makedepends subversion || fail "missing makedepends: subversion"
has options '!strip' || fail "missing option: !strip"
grep -Fq "groups=(texlive)" "$pkgbuild" || fail "collections are not in group texlive"
if grep -Fq 'groups=(texlive-lang)' "$pkgbuild"; then
    fail "leftover texlive-lang group branch"
fi
if grep -Fq 'texlive-langextra)' "$pkgbuild"; then
    fail "leftover texlive-langextra provides/replaces"
fi
if grep -Eq 'package_texlive-doc\(\)' "$pkgbuild"; then
    fail "texlive-doc split came back"
fi

# Data package: no compiler phase may creep in, and no host ISA/optimisation
# flag may be hard-coded.
if grep -Eq '^(build|check)\(\)' "$pkgbuild"; then
    fail "data package grew a build/check phase"
fi
if grep -Eq -- '-march=|-mtune=|-O[0-9]' "$pkgbuild"; then
    fail "hard-codes ISA/optimisation flags"
fi

# Every local source entry must exist next to the recipe.
while IFS= read -r src; do
    case "$src" in
        *://*) continue ;;
    esac
    src=${src%%#*}
    test -f "$root/$recipe/$src" || fail "missing local source: $src"
done < <(field source)
grep -q '^source=https://.*/latexminted-0\.7\.1-py3-none-any\.whl$' <<<"$vars" ||
    fail "the latexminted wheel source disappeared"

# Hooks and helper scripts must stay wired into the splits that ship them.
grep -Fq 'install -Dm644 7*.hook -t "$pkgdir"/usr/share/libalpm/hooks/' "$pkgbuild" ||
    fail "basic split no longer installs the 7x hooks"
grep -Fq 'install -Dm644 80-mtxrun.hook -t "$pkgdir"/usr/share/libalpm/hooks/' "$pkgbuild" ||
    fail "context split no longer installs the mtxrun hook"
for script in texlive-fmtutil texlive-language texlive-updmap; do
    grep -Fq "\"\$pkgdir\"/usr/share/libalpm/scripts/$script" "$pkgbuild" ||
        fail "missing alpm script install: $script"
done

# Topology registration, read through the engine's topology channel gsa -Qt
# (id|path|groups|edges|tags; the engine finds the workspace from the cwd
# upward, contract §B.8 amendment G11 — migration §4 row, 2026-10-14).
topo=$(cd "$root" && "$GSA_TEST_GSA_BIN" -Qt) || fail "gsa -Qt failed"
rec=$(printf '%s\n' "$topo" | awk -F'|' -v id=texlive-texmf '$1 == id')
[[ -n $rec ]] || fail "not registered in config/topology.conf (no record)"
[[ $(printf '%s\n' "$rec" | cut -d'|' -f2) == "$recipe" ]] ||
    fail "topology record does not point at $recipe"
[[ ",$(printf '%s\n' "$rec" | cut -d'|' -f3)," == *,git,* ]] ||
    fail "not a member of the git group"

# 2026-10-14 — RETIRED WITHOUT REPLACEMENT (migration §6 R-1): the svn-regex
# and `_DOWNLOAD_ARCHIVE_EXTS` greps pinned the retired fish builder's cleanup
# implementation; gsa is a shipped binary with no engine source to grep. The
# cleanup-ext behaviour re-pins behaviourally at its flip (`gsa -Mccc` target
# rendering, contract §B.7; synthetic-workspace precedent in
# tests/cleanup-extensions.sh) — no mutating prune verb runs against the real
# tree here.

# .SRCINFO freshness is owned by tests/srcinfo-freshness.sh (it regenerates and
# diffs every recipe from the engine's topology channel gsa -Qt), so it is not
# re-asserted here.

printf 'texlive-texmf recipe fixture: PASS\n'
