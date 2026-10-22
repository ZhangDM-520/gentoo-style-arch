#!/usr/bin/env bash
set -euo pipefail

# tools/abi-need-check.sh owns the FATAL runtime-dependency rule at
# transaction time: a DT_NEEDED soname that no file resolves after the
# transaction aborts the install. The tool is a host-side gate (it also runs
# as a pacman PreTransaction hook), so it lives outside the battery in
# tools/; this fixture pins its contract at reduced scale against synthetic
# packages under $TMPDIR — the same two-adapter pairing as
# tools/provides-audit.sh ↔ tests/provides-audit.sh.
#
# What is pinned here:
#   * fatal-only semantics: missing FILE is fatal, missing version pins are
#     invisible (the owner's loose-scope call, 2026-10-22);
#   * the runtime oracle is the file system: a dangling symlink does NOT
#     resolve (tk `libtk.so` lesson) and a file needs no provide;
#   * transaction-internal coverage: a soname another payload in the same
#     batch ships is fine, and a declared provide covers its stems;
#   * the exact finding message and the 0/1/2 exit contract;
#   * --from-names resolves names through a cache dir (hook shape: alpm
#     passes package names on stdin) and skips unresolvable names.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tool="$root/tools/abi-need-check.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-abi-need-check-fixture.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'abi-need-check fixture: %s\n' "$1" >&2
    exit 1
}

command -v cc >/dev/null 2>&1 || fail 'cc is required to synthesize payloads'
command -v readelf >/dev/null 2>&1 || fail 'readelf is required'
[[ -x $tool ]] || fail "tool is not executable: $tool"

# make_lib DIR FILENAME SONAME — a shared object carrying DT_SONAME.
make_lib() {
    mkdir -p "$1"
    printf 'int gsa_fixture_anchor;\n' |
        cc -shared -x c - -Wl,-soname,"$3" -o "$1/$2"
}

# make_bin DIR FILENAME NEEDED [rpath] — a consumer ELF with DT_NEEDED.
# Synthesis links against a throwaway stub whose DT_SONAME is exactly the
# wanted name: the produced consumer records that DT_NEEDED no matter what
# (or whether) a real file provides it on the host.
make_bin() {
    local dir=$1 file=$2 needed=$3 rpath=${4:-}
    mkdir -p "$dir" "$tmp/stub"
    local extra=()
    [[ -n $rpath ]] && extra+=(-Wl,-rpath,"$rpath")
    if [[ -e /usr/lib/$needed || -e /usr/lib32/$needed ]]; then
        # A host-resolved name (libc.so.6 …) must not be shadowed by a stub:
        # link plainly and let the real library record the DT_NEEDED.
        printf 'int main(void){return 0;}\n' |
            cc -x c - "${extra[@]+"${extra[@]}"}" -o "$dir/$file"
    else
        make_lib "$tmp/stub" "stub-$needed" "$needed"
        printf 'int main(void){return 0;}\n' |
            cc -x c - -Wl,--no-as-needed -L"$tmp/stub" -l:"stub-$needed" \
                "${extra[@]+"${extra[@]}"}" -o "$dir/$file"
    fi
    readelf -dW "$dir/$file" | grep -q "NEEDED.*\[$needed\]" ||
        fail "synthesis failed to record DT_NEEDED $needed"
}

# make_pkgroot DIR PKGNAME [provides...] — .PKGINFO; payload follows.
make_pkgroot() {
    local dir=$1 name=$2
    shift 2
    mkdir -p "$dir"
    {
        printf 'pkgname = %s\n' "$name"
        printf 'pkgver = 1.0.0-1\n'
        local provide
        for provide in "$@"; do
            printf 'provides = %s\n' "$provide"
        done
    } >"$dir/.PKGINFO"
}

run() {
    # run OUTVAR ERRVAR -- args… ; captures status without tripping set -e
    local outvar=$1 errvar=$2
    shift 2
    [[ ${1:-} == -- ]] && shift
    local _out _err _status=0
    _out=$("$tool" "$@" 2>/tmp/gsa-abi-need-check-fixture.err) || _status=$?
    _err=$(cat /tmp/gsa-abi-need-check-fixture.err)
    printf -v "$outvar" '%s' "$_out"
    printf -v "$errvar" '%s' "$_err"
    return $_status
}

# ── 1. clean: host-resolved + transaction-internal + provide-covered ─────
make_lib "$tmp/a/usr/lib" libgso.so.1 libgso.so.1
make_bin "$tmp/a/usr/bin" consumer libgso.so.1
make_bin "$tmp/a/usr/bin" libc-consumer libc.so.6
make_pkgroot "$tmp/a" pkg-clean libgso.so
status=0
run out err -- "$tmp/a" || status=$?
[[ $status == 0 ]] || fail "clean batch exited $status: $err"
[[ $out == *'pkg-clean: clean'* ]] || fail "missing clean line: $out"

# ── 2. fatal: a needed soname nothing resolves ───────────────────────────
make_bin "$tmp/b/usr/bin" broken libmissing-fixture.so.42
make_pkgroot "$tmp/b" pkg-fatal
status=0
run out err -- "$tmp/b" || status=$?
[[ $status == 1 ]] || fail "fatal case exited $status (want 1): $err"
expected="abi-need-check: pkg-fatal: 'broken' needs 'libmissing-fixture.so.42' — no file resolves it (fatal)"
[[ $out == *"$expected"* ]] || fail "finding message drifted: $out"

# ── 3. dangling symlink is NOT resolution (tk lesson) ───────────────────
make_bin "$tmp/c/usr/bin" consumer liblink-fixture.so.7 '$ORIGIN/lib'
mkdir -p "$tmp/c/usr/bin/lib"
ln -s nowhere-fixture.so "$tmp/c/usr/bin/lib/liblink-fixture.so.7"
make_pkgroot "$tmp/c" pkg-dangling
status=0
run out err -- "$tmp/c" || status=$?
[[ $status == 1 ]] || fail "dangling symlink resolved (want fatal), got $status"
# green: the same path replaced by a real file resolves
rm -f "$tmp/c/usr/bin/lib/liblink-fixture.so.7"
make_lib "$tmp/c/usr/bin/lib" liblink-fixture.so.7 liblink-fixture.so.7
status=0
run out err -- "$tmp/c" || status=$?
[[ $status == 0 ]] || fail "real file did not resolve (want clean), got $status: $out"

# ── 4. --quiet keeps findings, drops clean lines ────────────────────────
status=0
run out err -- --quiet "$tmp/a" || status=$?
[[ $status == 0 ]] || fail "quiet clean batch exited $status"
[[ -z $out ]] || fail "quiet printed clean output: $out"
status=0
run out err -- --quiet "$tmp/b" || status=$?
[[ $status == 1 ]] || fail "quiet fatal batch exited $status (want 1)"
[[ $out == *'no file resolves it'* ]] || fail "quiet dropped the finding"

# ── 5. --from-names: names on stdin resolve through the cache ───────────
mkdir -p "$tmp/cache"
tar --zstd -cf "$tmp/cache/pkg-clean-1.0.0-1-any.pkg.tar.zst" -C "$tmp/a" .
status=0
out=$(printf 'pkg-clean\npkg-not-downloaded\n' |
    GSA_ABI_NEED_CHECK_CACHE="$tmp/cache" "$tool" --from-names 2>/dev/null) || status=$?
[[ $status == 0 ]] || fail "--from-names exited $status: $out"
[[ $out == *'pkg-not-downloaded: skipped'* ]] || fail "unresolvable name not skipped: $out"
[[ $out == *'pkg-clean: clean'* ]] || fail "cached name not scanned: $out"

# ── 6. usage contract ──────────────────────────────────────────────────
status=0
run out err -- || status=$?
[[ $status == 2 ]] || fail "no-input usage exited $status (want 2)"
status=0
run out err -- --bogus || status=$?
[[ $status == 2 ]] || fail "unknown flag exited $status (want 2)"

printf 'abi-need-check fixture: ok\n'
