#!/usr/bin/env bash
set -euo pipefail

# vscodium-insiders-git npm retry-shim fixture.
#
# build() in packages/git/vscodium-insiders-git generates an npm retry shim
# (2026-10-20, the electron packaging wall): `@electron/get` re-fetches
# SHASUMS256.txt through undici fetch() on every packaging run, so a dying
# link throws `TypeError: fetch failed`/`terminated` in the `vscode-*-packing`
# gulp tasks. The shim retries an npm step up to 3 times on exactly the
# transient-network class and fails immediately (rc preserved) otherwise.
#
# This fixture extracts the shim's GENERATION block from the real PKGBUILD and
# runs the generated shim against a PATH-independent stub npm, pinning:
#
#   - transient failure → retried, succeeds on the 3rd attempt;
#   - persistent transient failure → exactly 3 attempts, then the failure;
#   - non-transient failure → exactly 1 attempt, original rc, no retry;
#   - clean run → exactly 1 attempt.
#
# Everything happens in a scratch tree; the real tree, npm and the network
# are never touched.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
recipe="$root/packages/git/vscodium-insiders-git"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-vscodium-npm-retry.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'vscodium npm-retry fixture: %s\n' "$1" >&2
    exit 1
}

# ─── Extract the shim-generation block from the real PKGBUILD ─────────────
start=$(grep -n 'cat >"\$_shim_dir/npm" <<EOF' "$recipe/PKGBUILD" | cut -d: -f1)
[[ -n $start ]] || fail "could not find the npm shim generation block in the PKGBUILD"
heredoc_end=$(awk -v s="$start" 'NR > s && /^EOF$/ { print NR; exit }' "$recipe/PKGBUILD")
[[ -n $heredoc_end ]] || fail "the npm shim heredoc is not terminated"
end=$(awk -v s="$heredoc_end" 'NR > s && /chmod \+x "\$_shim_dir\/npm"/ { print NR; exit }' "$recipe/PKGBUILD")
[[ -n $end ]] || fail "the npm shim generation does not chmod the shim"
sed -n "${start},${end}p" "$recipe/PKGBUILD" >"$tmp/gen.sh"

# ─── The stub npm: scripted failures, one log line per invocation ─────────
stub="$tmp/stub"
mkdir -p "$stub"
cat >"$stub/npm" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GSA_FAKE_NPM_LOG"
case ${GSA_FAKE_NPM_MODE:-ok} in
    ok) exit 0 ;;
    fail-transient-twice)
        if [[ $(wc -l <"$GSA_FAKE_NPM_LOG") == 3 ]]; then exit 0; fi
        echo "TypeError: terminated" >&2
        exit 1
        ;;
    fail-transient-always)
        echo "TypeError: fetch failed" >&2
        exit 1
        ;;
    fail-hard)
        echo "SyntaxError: Unexpected token" >&2
        exit 42
        ;;
    *) echo "npm stub: unknown GSA_FAKE_NPM_MODE" >&2; exit 2 ;;
esac
EOF
chmod +x "$stub/npm"
# keep the shim's backoff out of the fixture's runtime
printf '#!/usr/bin/env bash\nexit 0\n' >"$stub/sleep"
chmod +x "$stub/sleep"

# ─── Generate the shim exactly as build() does ────────────────────────────
_shim_dir="$tmp/shim"
_real_npm="$stub/npm"
mkdir -p "$_shim_dir"
( export _shim_dir _real_npm; bash "$tmp/gen.sh" )
[[ -x $_shim_dir/npm ]] || fail "generation did not produce an executable shim"

run_shim() { # run_shim <label> <mode>
    local label=$1 mode=$2 rc=0
    : >"$tmp/log-$label"
    GSA_FAKE_NPM_LOG="$tmp/log-$label" GSA_FAKE_NPM_MODE="$mode" \
        PATH="$stub:$PATH" "$_shim_dir/npm" run gulp vscode-linux-x64-min-packing \
        >"$tmp/out-$label" 2>&1 || rc=$?
    echo "$rc" >"$tmp/rc-$label"
}

calls() { wc -l <"$tmp/log-$1"; }

# ─── 1. transient failure → retried until it succeeds ────────────────────
run_shim retry-ok fail-transient-twice
[[ $(cat "$tmp/rc-retry-ok") == 0 ]] || fail "a transient failure that later succeeds must not fail the step"
[[ $(calls retry-ok) == 3 ]] || fail "expected 3 npm attempts, got $(calls retry-ok)"
[[ $(grep -c 'retrying' "$tmp/out-retry-ok") == 2 ]] || fail "expected 2 retry notes"

# ─── 2. persistent transient failure → 3 attempts, then the failure ──────
run_shim retry-all fail-transient-always
[[ $(cat "$tmp/rc-retry-all") != 0 ]] || fail "a persistent transient failure must surface"
[[ $(calls retry-all) == 3 ]] || fail "expected 3 npm attempts, got $(calls retry-all)"

# ─── 3. non-transient failure → one attempt, original rc, no retry ───────
run_shim hard fail-hard
[[ $(cat "$tmp/rc-hard") == 42 ]] || fail "the real npm exit status must pass through (want 42, got $(cat "$tmp/rc-hard"))"
[[ $(calls hard) == 1 ]] || fail "a non-transient failure must not be retried (got $(calls hard) attempts)"
if grep -q 'retrying' "$tmp/out-hard"; then
    fail "a non-transient failure must not announce a retry"
fi

# ─── 4. clean run → one attempt ──────────────────────────────────────────
run_shim clean ok
[[ $(cat "$tmp/rc-clean") == 0 ]] || fail "a clean run must succeed"
[[ $(calls clean) == 1 ]] || fail "a clean run must not retry"

printf 'vscodium npm-retry fixture: PASS\n'
