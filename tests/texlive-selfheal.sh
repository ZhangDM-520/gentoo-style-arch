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
EOF
chmod +x "$shim/svn"

# ─── The tlpkg source entry the recipe itself declares (the anchoring) ─────
tlpkg_entry=$(bash -c "source '$recipe/PKGBUILD'; printf '%s\n' \"\${source[@]}\"" | grep '/tlpkg#revision=') ||
    fail "the recipe declares no tlpkg svn source"
expected_url=${tlpkg_entry%%#*}
expected_rev=${tlpkg_entry##*#revision=}

# ─── Run prepare() over one synthetic tree ────────────────────────────────
# makepkg runs prepare() with cwd = $srcdir; SRCDEST is canonicalised to
# $startdir when unset, so both are always defined there. prepare() cannot
# run to completion on a synthetic tree (the real split needs texmf-dist),
# so a run is judged on the heal's side effects and on WHERE it stopped.
run_case() { # run_case <label> <svn-mode> <husk|healed>
    local label=$1 mode=$2 shape=$3
    local work="$tmp/$label"
    local srcdir="$work/src" startdir="$work/start" srcdest="$work/srcdest"
    mkdir -p "$srcdir/tlpkg" "$startdir" "$srcdest"
    : >"$tmp/log-$label"
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
[[ $(checkout_calls untouched) == 0 ]] || fail "a complete working copy must not be re-fetched"
[[ -r "$tmp/untouched/src/tlpkg/texlive.tlpdb" ]] || fail "the complete working copy was disturbed"

printf 'texlive selfheal fixture: PASS\n'
