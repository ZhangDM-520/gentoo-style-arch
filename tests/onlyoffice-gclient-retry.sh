#!/usr/bin/env bash
set -euo pipefail

# onlyoffice-git gclient retry fixture.
#
# prepare() fetches V8's dep graph through gclient across flaky mirrors
# (2026-10-21: a TLS EOF from android.googlesource.com/perfetto aborted the
# build). `_gclient_sync` retries the (idempotent) sync up to 3 times on
# exactly the transient network class and fails immediately on anything
# else. This fixture runs the REAL helper over a stubbed gclient and pins:
#
#   - success first try → exactly one sync, rc 0;
#   - transient failure then success → retried, rc 0;
#   - persistent transient failure → 3 attempts, then a loud failure;
#   - a non-transient failure → NO retry, immediate failure.
#
# Everything happens in a scratch tree; gclient is a PATH stub.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
recipe="$root/packages/git/onlyoffice-git"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-onlyoffice-gclient.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'onlyoffice gclient fixture: %s\n' "$1" >&2
    exit 1
}

# ─── The gclient stub: records calls, fails per GSA_FAKE_GCLIENT_MODE ─────
shim="$tmp/shim"
mkdir -p "$shim"
cat >"$shim/gclient" <<'EOF'
#!/usr/bin/env bash
n=$(wc -l <"$GSA_FAKE_GCLIENT_LOG")
echo "$*" >>"$GSA_FAKE_GCLIENT_LOG"
case ${GSA_FAKE_GCLIENT_MODE:-ok} in
    ok) exit 0 ;;
    transient-once) [[ $n == 0 ]] || exit 0; echo "fatal: unable to access 'https://example/': TLS connect error: error:0A000126:SSL routines::unexpected eof while reading" >&2; exit 1 ;;
    transient-always) echo "fatal: unable to access 'https://example/': TLS connect error: error:0A000126:SSL routines::unexpected eof while reading" >&2; exit 1 ;;
    hard) echo "error: invalid DEPS file" >&2; exit 1 ;;
    *) echo "gclient stub: unknown mode" >&2; exit 2 ;;
esac
EOF
chmod +x "$shim/gclient"

# ─── Run the real helper ──────────────────────────────────────────────────
run_case() { # run_case <label> <mode>
    local label=$1 mode=$2 rc=0
    : >"$tmp/log-$label"
    {
        printf '%s\n' 'set +e'
        printf '%s\n' "source '$recipe/PKGBUILD'"
        printf '%s\n' 'error() { echo "error: $*" >&2; }'
        printf '%s\n' '_gclient_sync'
        printf '%s\n' 'exit $?'
    } >"$tmp/wrapper-$label.sh"
    GSA_FAKE_GCLIENT_LOG="$tmp/log-$label" GSA_FAKE_GCLIENT_MODE="$mode" \
        PATH="$shim:$PATH" bash "$tmp/wrapper-$label.sh" >"$tmp/out-$label" 2>&1 || rc=$?
    echo "$rc" >"$tmp/rc-$label"
}

sync_calls() { wc -l <"$tmp/log-$1"; }

# ─── 1. clean run → one sync ──────────────────────────────────────────────
run_case clean ok
[[ $(sync_calls clean) == 1 ]] || fail "expected exactly 1 sync, got $(sync_calls clean)"
[[ $(cat "$tmp/rc-clean") == 0 ]] || fail "a clean sync must succeed"

# ─── 2. transient then success → retried, succeeds ────────────────────────
run_case retry transient-once
[[ $(sync_calls retry) == 2 ]] || fail "expected 2 syncs (fail then retry), got $(sync_calls retry)"
[[ $(cat "$tmp/rc-retry") == 0 ]] || fail "a recovered transient failure must succeed"
grep -q 'retrying (1/3)' "$tmp/out-retry" || fail "the retry did not announce itself"

# ─── 3. persistent transient → 3 attempts then failure ────────────────────
run_case giveup transient-always
[[ $(sync_calls giveup) == 3 ]] || fail "expected 3 sync attempts, got $(sync_calls giveup)"
[[ $(cat "$tmp/rc-giveup") != 0 ]] || fail "a persistent failure must fail the helper"

# ─── 4. non-transient → no retry, immediate failure ───────────────────────
run_case hard hard
[[ $(sync_calls hard) == 1 ]] || fail "a non-transient failure must not be retried (got $(sync_calls hard))"
[[ $(cat "$tmp/rc-hard") != 0 ]] || fail "a non-transient failure must fail the helper"

printf 'onlyoffice gclient fixture: PASS\n'
