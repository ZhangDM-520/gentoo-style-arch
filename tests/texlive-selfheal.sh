#!/usr/bin/env bash
set -euo pipefail

# texlive-texmf tlpkg self-heal fixture.
#
# prepare() in packages/git/texlive-texmf heals the tlpkg SVN husk (2026-10-20):
# an interrupted checkout leaves a config-only directory which makepkg only
# WARNS about and then extracts, so the build used to die 23 minutes later
# with `awk: fatal: cannot open file 'tlpkg/texlive.tlpdb'` — or, on a later
# strike, with a remediation message that put a manual `rm -rf` on the
# operator. This fixture runs the REAL prepare() over synthetic trees and
# pins the contract:
#
#   - a missing tlpkg/texlive.tlpdb wipes and re-fetches the pinned revision
#     from the tlpkg entry of the recipe's own `source` array (never a
#     duplicated URL/rev), into $SRCDEST/tlpkg, copied back to $srcdir;
#   - a partial texmf-dist working copy (the 2026-10-21 SEGV-era husk: 27
#     of 459k files) heals the same way, anchored to the texmf-dist entry,
#     with the minted.sty / web2c/texmf.cnf sentinels restored;
#   - a stale husk beside the PKGBUILD is cleared when it is not $SRCDEST;
#   - a transient checkout failure retries (3 attempts) before giving up;
#   - a complete working copy is left alone (no spurious re-fetch).
#
# Everything happens in a scratch tree; the real tree and the real network
# are never touched (svn is a PATH stub).

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
recipe="$root/packages/git/texlive-texmf"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-texlive-selfheal.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'texlive selfheal fixture: %s\n' "$1" >&2
    exit 1
}

# ─── The svn stub: records its argv, writes the working copy on success ────
shim="$tmp/shim"
mkdir -p "$shim"
cat >"$shim/svn" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GSA_FAKE_SVN_LOG"
case ${GSA_FAKE_SVN_MODE:-ok} in
    ok) ;;
    fail-once) [[ $(wc -l <"$GSA_FAKE_SVN_LOG") == 1 ]] && exit 139 ;;
    fail-all) exit 139 ;;
    *) echo "svn stub: unknown GSA_FAKE_SVN_MODE" >&2; exit 2 ;;
esac
dest="${@: -1}"
mkdir -p "$dest"
printf 'stub texlive.tlpdb\n' >"$dest/texlive.tlpdb"
mkdir -p "$dest/tex/latex/minted" "$dest/web2c"
printf 'stub\n' >"$dest/tex/latex/minted/minted.sty"
printf 'stub\n' >"$dest/web2c/texmf.cnf"
EOF
chmod +x "$shim/svn"

# ─── The svn source entries the recipe itself declares (the anchoring) ────
tlpkg_entry=$(bash -c "source '$recipe/PKGBUILD'; printf '%s\n' \"\${source[@]}\"" | grep '/tlpkg#revision=') ||
    fail "the recipe declares no tlpkg svn source"
expected_url=${tlpkg_entry%%#*}
expected_rev=${tlpkg_entry##*#revision=}
texmf_entry=$(bash -c "source '$recipe/PKGBUILD'; printf '%s\n' \"\${source[@]}\"" | grep '/texmf-dist#revision=') ||
    fail "the recipe declares no texmf-dist svn source"
texmf_url=${texmf_entry%%#*}
texmf_rev=${texmf_entry##*#revision=}

# ─── Run prepare() over one synthetic tree ────────────────────────────────
# makepkg runs prepare() with cwd = $srcdir; SRCDEST is canonicalised to
# $startdir when unset, so both are always defined there. prepare() cannot
# run to completion on a synthetic tree (the real split needs texmf-dist),
# so a run is judged on the heal's side effects and on WHERE it stopped.
run_case() { # run_case <label> <svn-mode> <husk|healed|texmf-husk|both-husk>
    local label=$1 mode=$2 shape=$3
    local work="$tmp/$label"
    local srcdir="$work/src" startdir="$work/start" srcdest="$work/srcdest"
    mkdir -p "$srcdir/tlpkg" "$startdir" "$srcdest"
    : >"$tmp/log-$label"
    # every shape carries a complete texmf-dist unless it is the tested husk
    mkdir -p "$srcdir/texmf-dist/tex/latex/minted" "$srcdir/texmf-dist/web2c"
    printf 'ok\n' >"$srcdir/texmf-dist/tex/latex/minted/minted.sty"
    printf 'ok\n' >"$srcdir/texmf-dist/web2c/texmf.cnf"
    case $shape in
        husk)
            # the config-only husk makepkg extracts: no texlive.tlpdb
            mkdir -p "$srcdir/tlpkg/.makepkg" "$srcdest/tlpkg/.makepkg"
            printf 'stale\n' >"$startdir/tlpkg-legacy-marker"
            mkdir -p "$startdir/tlpkg/.makepkg"
            ;;
        healed)
            printf 'complete\n' >"$srcdir/tlpkg/texlive.tlpdb"
            ;;
        texmf-husk)
            # a partial texmf-dist working copy (SEGV-era: 27 of 459k files)
            printf 'complete\n' >"$srcdir/tlpkg/texlive.tlpdb"
            rm -rf "$srcdir/texmf-dist"
            mkdir -p "$srcdir/texmf-dist/.makepkg" "$srcdest/texmf-dist/.makepkg"
            ;;
        both-husk)
            mkdir -p "$srcdir/tlpkg/.makepkg" "$srcdest/tlpkg/.makepkg"
            rm -rf "$srcdir/texmf-dist"
            mkdir -p "$srcdir/texmf-dist/.makepkg" "$srcdest/texmf-dist/.makepkg"
            ;;
        *) fail "unknown shape: $shape" ;;
    esac
    {
        printf '%s\n' 'set +e'
        printf '%s\n' "srcdir='$srcdir'" "startdir='$startdir'" "SRCDEST='$srcdest'" \
            'export srcdir startdir SRCDEST' "source '$recipe/PKGBUILD'"
        printf '%s\n' 'prepare'
    } >"$tmp/wrapper-$label.sh"
    (
        cd "$srcdir"
        GSA_FAKE_SVN_LOG="$tmp/log-$label" GSA_FAKE_SVN_MODE="$mode" \
            PATH="$shim:$PATH" bash "$tmp/wrapper-$label.sh" \
            >"$tmp/out-$label" 2>&1
        echo $? >"$tmp/rc-$label"
    ) || true
}

checkout_calls() { grep -c '^checkout ' "$tmp/log-$1" || true; }

# ─── 1. husk → wiped, re-anchored fetch, copy back, legacy husk cleared ───
run_case heal ok husk
[[ -r "$tmp/heal/src/tlpkg/texlive.tlpdb" ]] || fail "husk was not healed in \$srcdir"
[[ -r "$tmp/heal/srcdest/tlpkg/texlive.tlpdb" ]] || fail "\$SRCDEST/tlpkg was not re-fetched"
[[ ! -e "$tmp/heal/start/tlpkg" ]] || fail "the husk beside the PKGBUILD was not cleared"
[[ $(checkout_calls heal) == 1 ]] || fail "expected exactly one svn checkout, got $(checkout_calls heal)"
read -r -a _svn_argv <"$tmp/log-heal"
[[ ${_svn_argv[*]} == "checkout -r $expected_rev --config-dir $tmp/heal/srcdest/tlpkg/.makepkg $expected_url $tmp/heal/srcdest/tlpkg" ]] ||
    fail "the re-fetch is not anchored to the declared source entry: ${_svn_argv[*]} (want $expected_url @ r$expected_rev)"
grep -q 'wiping and re-fetching' "$tmp/out-heal" || fail "the heal did not announce itself"

# ─── 2. transient checkout failure → retried, then healed ─────────────────
run_case retry fail-once husk
[[ -r "$tmp/retry/src/tlpkg/texlive.tlpdb" ]] || fail "husk was not healed after a transient failure"
[[ $(checkout_calls retry) == 2 ]] || fail "expected 2 svn checkouts (fail then retry), got $(checkout_calls retry)"

# ─── 3. checkout keeps failing → three attempts, then a loud failure ──────
run_case giveup fail-all husk
[[ $(checkout_calls giveup) == 3 ]] || fail "expected 3 svn checkouts before giving up, got $(checkout_calls giveup)"
[[ $(cat "$tmp/rc-giveup") != 0 ]] || fail "prepare() must fail when the self-heal cannot fetch"
grep -q 'self-heal failed after 3 attempts' "$tmp/out-giveup" || fail "the give-up path did not name itself"

# ─── 4. complete working copy → left alone ────────────────────────────────
run_case untouched ok healed
[[ $(checkout_calls untouched) == 0 ]] || fail "a complete working copy must not be re-fetch"
[[ -r "$tmp/untouched/src/tlpkg/texlive.tlpdb" ]] || fail "the complete working copy was disturbed"
[[ -r "$tmp/untouched/src/texmf-dist/tex/latex/minted/minted.sty" ]] || fail "the complete texmf-dist was disturbed"

# ─── 5. texmf-dist husk → healed, anchored to the texmf-dist source ───────
run_case texhusk ok texmf-husk
[[ -r "$tmp/texhusk/src/texmf-dist/tex/latex/minted/minted.sty" ]] || fail "texmf-dist husk was not healed in \$srcdir"
[[ -r "$tmp/texhusk/src/texmf-dist/web2c/texmf.cnf" ]] || fail "texmf-dist self-heal left the web2c sentinel missing"
[[ -r "$tmp/texhusk/srcdest/texmf-dist/tex/latex/minted/minted.sty" ]] || fail "\$SRCDEST/texmf-dist was not re-fetched"
[[ $(checkout_calls texhusk) == 1 ]] || fail "expected exactly one svn checkout, got $(checkout_calls texhusk)"
read -r -a _svn_argv <"$tmp/log-texhusk"
[[ ${_svn_argv[*]} == "checkout -r $texmf_rev --config-dir $tmp/texhusk/srcdest/texmf-dist/.makepkg $texmf_url $tmp/texhusk/srcdest/texmf-dist" ]] ||
    fail "the texmf-dist re-fetch is not anchored to the declared source entry: ${_svn_argv[*]} (want $texmf_url @ r$texmf_rev)"
grep -q 'wiping and re-fetching' "$tmp/out-texhusk" || fail "the texmf-dist heal did not announce itself"

# ─── 6. both husks → both healed, two anchored fetches ────────────────────
run_case both ok both-husk
[[ -r "$tmp/both/src/tlpkg/texlive.tlpdb" ]] || fail "tlpkg was not healed in the both-husk case"
[[ -r "$tmp/both/src/texmf-dist/tex/latex/minted/minted.sty" ]] || fail "texmf-dist was not healed in the both-husk case"
[[ $(checkout_calls both) == 2 ]] || fail "expected 2 svn checkouts (tlpkg + texmf-dist), got $(checkout_calls both)"

printf 'texlive selfheal fixture: PASS\n'
