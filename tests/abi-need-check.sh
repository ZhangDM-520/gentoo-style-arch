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
#     resolve (tk `libtk.so` lesson) and a file needs no provide — and the
#     file system includes the loader cache: a soname visible only through
#     an ld.so.conf.d dir resolves (R's /usr/lib/R/lib class), with the
#     same file-truth rule;
#   * transaction-internal coverage: a soname another payload in the same
#     batch ships is fine, and a declared provide covers its stems ONLY
#     when a file stands behind them (the same file-system resolution the
#     direct path performs — a provide with no file behind it stays a
#     finding, the tk `libtk.so` lesson);
#   * the exact finding message and the 0/1/2 exit contract;
#   * --from-names resolves names through a cache dir (hook shape: alpm
#     passes package names on stdin) and skips unresolvable names — and
#     stands down for EVERY name of a local `-U` file install (the pacman
#     argv carries `-U`): a stale cached twin is never scanned instead.

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

# ── 7. regression 2026-10-22: .sig siblings and unextractable files ─────
# The real transaction that walled: a detached signature next to the
# archive won the newest-wins race and its extraction failure aborted the
# whole upgrade. Contract now: real archives only, fail open on extraction.
printf 'not-a-tar\n' >"$tmp/cache/pkg-clean-1.0.0-1-any.pkg.tar.zst.sig"
touch -d '2030-01-01' "$tmp/cache/pkg-clean-1.0.0-1-any.pkg.tar.zst.sig"
status=0
out=$(printf 'pkg-clean\n' |
    GSA_ABI_NEED_CHECK_CACHE="$tmp/cache" "$tool" --from-names 2>/dev/null) || status=$?
[[ $status == 0 ]] || fail ".sig sibling poisoned the scan (want clean), got $status: $out"
[[ $out == *'pkg-clean: clean'* ]] || fail "real archive skipped when .sig present: $out"

printf 'also not a tar\n' >"$tmp/cache/pkg-broken-1.0.0-1-any.pkg.tar.zst"
status=0
err=$(printf 'pkg-broken\n' |
    GSA_ABI_NEED_CHECK_CACHE="$tmp/cache" "$tool" --from-names 2>&1 >/dev/null) || status=$?
[[ $status == 0 ]] || fail "unextractable cache file aborted (want fail-open), got $status: $err"
[[ $err == *'pkg-broken-1.0.0-1-any.pkg.tar.zst: skipped (not extractable)'* ]] ||
    fail "missing fail-open warning: $err"

# newest-wins stays: a stale BROKEN archive must lose to a newer clean one
mv "$tmp/cache/pkg-broken-1.0.0-1-any.pkg.tar.zst" "$tmp/cache/pkg-clean-0.0.1-1-any.pkg.tar.zst"
touch -d '2000-01-01' "$tmp/cache/pkg-clean-0.0.1-1-any.pkg.tar.zst"
status=0
out=$(printf 'pkg-clean\n' |
    GSA_ABI_NEED_CHECK_CACHE="$tmp/cache" "$tool" --from-names 2>/dev/null) || status=$?
[[ $status == 0 ]] || fail "stale archive won newest-wins (want clean), got $status: $out"
[[ $out == *'pkg-clean: clean'* ]] || fail "stale archive swallowed the scan: $out"

# fail-open must NOT soften real findings: a cached FATAL archive aborts
tar --zstd -cf "$tmp/cache/pkg-fatal-1.0.0-1-any.pkg.tar.zst" -C "$tmp/b" .
status=0
out=$(printf 'pkg-fatal\n' |
    GSA_ABI_NEED_CHECK_CACHE="$tmp/cache" "$tool" --from-names 2>/dev/null) || status=$?
[[ $status == 1 ]] || fail "cached fatal went soft (want 1), got $status: $out"
[[ $out == *'libmissing-fixture.so.42'* ]] || fail "fatal finding lost: $out"

# explicit mode with nothing scannable is still a caller error
status=0
run out err -- "$tmp/cache/pkg-clean-0.0.1-1-any.pkg.tar.zst" || status=$?
[[ $status == 2 ]] || fail "all-garbage explicit input exited $status (want 2): $err"
[[ $err == *'no input could be scanned'* ]] || fail "missing unscannable verdict: $err"

# ── 8. regression 2026-10-22 replay: prefix twins do not cross-resolve ───
# The real wall: name `linux-cachyos` glob-matched `linux-cachyos-headers-*`
# and newest-wins scanned the twin, leaving the kernel unchecked.
tar --zstd -cf "$tmp/cache/pkg-clean-headers-2.0.0-1-any.pkg.tar.zst" -C "$tmp/b" .
touch -d '2030-01-01' "$tmp/cache/pkg-clean-headers-2.0.0-1-any.pkg.tar.zst"
status=0
out=$(printf 'pkg-clean\n' |
    GSA_ABI_NEED_CHECK_CACHE="$tmp/cache" "$tool" --from-names 2>/dev/null) || status=$?
[[ $status == 0 ]] || fail "prefix twin cross-resolved (want clean), got $status: $out"
[[ $out == *'pkg-clean: clean'* ]] || fail "own archive not scanned: $out"
[[ $out != *'libmissing-fixture'* ]] || fail "prefix twin was scanned: $out"

# …and the twin resolves under its own name, finding still fatal
status=0
out=$(printf 'pkg-clean-headers\n' |
    GSA_ABI_NEED_CHECK_CACHE="$tmp/cache" "$tool" --from-names 2>/dev/null) || status=$?
[[ $status == 1 ]] || fail "twin name missed its own archive (want 1), got $status: $out"
[[ $out == *'libmissing-fixture.so.42'* ]] || fail "twin finding lost: $out"

# ── 9. kernel-class whitelist: skipped by name, carve-outs scanned ──────
# The owner's optimisation: kernel/firmware payloads cannot carry userspace
# SONAME skew and are skipped outright — even a FATAL payload inside one.
tar --zstd -cf "$tmp/cache/linux-cachyos-1.0-1-any.pkg.tar.zst" -C "$tmp/b" .
touch -d '2030-01-02' "$tmp/cache/linux-cachyos-1.0-1-any.pkg.tar.zst"
status=0
out=$(printf 'linux-cachyos\n' |
    GSA_ABI_NEED_CHECK_CACHE="$tmp/cache" "$tool" --from-names 2>/dev/null) || status=$?
[[ $status == 0 ]] || fail "kernel-class not skipped (want 0), got $status: $out"
[[ $out == *'skipped (kernel-class'* ]] || fail "missing kernel-class skip note: $out"
[[ $out != *'libmissing-fixture'* ]] || fail "kernel payload was scanned: $out"

# …every OTHER listed kernel flavour is skipped the same way — the roster
# is kernel_class()'s explicit name list (S2: never a `linux-*` wildcard).
for flav in linux linux-cachyos-lts linux-cachyos-bore-lto linux-cachyos-bore-lto-dbg; do
    tar --zstd -cf "$tmp/cache/$flav-1.0-1-any.pkg.tar.zst" -C "$tmp/b" .
    status=0
    out=$(printf '%s\n' "$flav" |
        GSA_ABI_NEED_CHECK_CACHE="$tmp/cache" "$tool" --from-names 2>/dev/null) || status=$?
    [[ $status == 0 ]] || fail "kernel flavour $flav not skipped (want 0), got $status: $out"
    [[ $out == *'skipped (kernel-class'* ]] || fail "missing kernel-class skip note for $flav: $out"
done

# …and a `linux-tools`-SHAPED userspace name is NOT kernel-class (S2: the
# old `linux-*` wildcard swallowed real userspace payloads — perf and
# turbostat live in linux-tools, config/topology.conf:91): its fatal payload
# must abort exactly like any userspace package.
tar --zstd -cf "$tmp/cache/linux-tools-1.0-1-any.pkg.tar.zst" -C "$tmp/b" .
status=0
out=$(printf 'linux-tools\n' |
    GSA_ABI_NEED_CHECK_CACHE="$tmp/cache" "$tool" --from-names 2>/dev/null) || status=$?
[[ $status == 1 ]] || fail "linux-tools-shaped name skipped (want fatal 1), got $status: $out"
[[ $out == *'libmissing-fixture.so.42'* ]] || fail "linux-tools-shaped payload not scanned: $out"

# …but the -headers carve-out is NOT kernel-class (22 runtime links
# measured in linux-cachyos-headers, 2026-10-22): same fatal payload stays
# fatal under the carve-out name.
tar --zstd -cf "$tmp/cache/linux-cachyos-headers-1.0-1-any.pkg.tar.zst" -C "$tmp/b" .
status=0
out=$(printf 'linux-cachyos-headers\n' |
    GSA_ABI_NEED_CHECK_CACHE="$tmp/cache" "$tool" --from-names 2>/dev/null) || status=$?
[[ $status == 1 ]] || fail "headers carve-out skipped (want fatal 1), got $status: $out"

# ── 10. fact cache: written on scan, READ on rescan (poison proof) ──────
# Verdicts are never cached; the parse facts are. Poisoning the cached
# facts must flip the verdict (proves the cache is READ), and deleting the
# entry must restore the clean verdict (proves the flip came from cache).
mkdir -p "$tmp/factcache"
status=0
out=$(printf 'pkg-clean\n' |
    GSA_ABI_NEED_CHECK_CACHE="$tmp/cache" GSA_ABI_NEED_CHECK_FACTCACHE="$tmp/factcache" \
    "$tool" --from-names 2>/dev/null) || status=$?
[[ $status == 0 ]] || fail "cache-cold scan exited $status: $out"
compgen -G "$tmp/factcache/*.facts" >/dev/null || fail "fact cache not written"

sha=$(sha256sum "$tmp/cache/pkg-clean-1.0.0-1-any.pkg.tar.zst")
sha=${sha%% *}
{
    printf '# gsa-abi-need-check facts v1 %s\n' "$sha"
    printf 'pkg\x1fpkg-clean\n'
    printf 'file\x1fusr/bin/consumer\x1fELF64\x1f\x1f\x1flibmissing-fixture.so.42\n'
} >"$tmp/factcache/$sha.facts"
status=0
out=$(printf 'pkg-clean\n' |
    GSA_ABI_NEED_CHECK_CACHE="$tmp/cache" GSA_ABI_NEED_CHECK_FACTCACHE="$tmp/factcache" \
    "$tool" --from-names 2>/dev/null) || status=$?
[[ $status == 1 ]] || fail "poisoned fact cache not used (want 1), got $status: $out"
[[ $out == *'libmissing-fixture.so.42'* ]] || fail "poisoned facts ignored: $out"
rm -f "$tmp/factcache/$sha.facts"
status=0
out=$(printf 'pkg-clean\n' |
    GSA_ABI_NEED_CHECK_CACHE="$tmp/cache" GSA_ABI_NEED_CHECK_FACTCACHE="$tmp/factcache" \
    "$tool" --from-names 2>/dev/null) || status=$?
[[ $status == 0 ]] || fail "cache delete did not restore clean scan: $status: $out"

# ── 11. per-file attribution: findings name the owning payload file ─────
# Pins the batched-parse `File:` markers: in a multi-file chunk the facts
# of two files must NOT meld into one record. Order-independent by
# construction: each file has its own unresolvable need, so melding
# misattributes one of them whichever file `find` yields first.
# (Mutation-probed 2026-10-22: a dead marker regex passed every case above
# — verdicts survive melding — and passed the first draft of this one.)
make_bin "$tmp/m/usr/bin" first-broken libmissing-a.so.1
make_bin "$tmp/m/usr/bin" second-broken libmissing-b.so.2
make_pkgroot "$tmp/m" pkg-multi
status=0
run out err -- "$tmp/m" || status=$?
[[ $status == 1 ]] || fail "multi-file fatal exited $status (want 1): $err"
[[ $out == *"pkg-multi: 'first-broken' needs 'libmissing-a.so.1'"* ]] ||
    fail "first file's finding lost/misattributed: $out"
[[ $out == *"pkg-multi: 'second-broken' needs 'libmissing-b.so.2'"* ]] ||
    fail "second file's finding lost/misattributed: $out"

# ── 12. S1: a provide covers its stems ONLY with a file behind them ─────
# The runtime oracle is the file system: a provide-name match must go
# through the same file resolution the direct path performs. A provide
# whose backing file is absent (the tk `libtk.so` dangling symlink class)
# must NOT set covered — it stays a finding.
make_bin "$tmp/s1/usr/bin" consumer libp-fixture.so.7 '$ORIGIN/lib'
mkdir -p "$tmp/s1/usr/bin/lib"
ln -s nowhere-fixture.so "$tmp/s1/usr/bin/lib/libp-fixture.so.7"
make_pkgroot "$tmp/s1" pkg-provide-dangling libp-fixture.so
status=0
run out err -- "$tmp/s1" || status=$?
[[ $status == 1 ]] || fail "provide with no file behind it resolved (want fatal 1), got $status: $out"
[[ $out == *"needs 'libp-fixture.so.7'"* ]] || fail "provide-without-file finding lost: $out"

# green: the same provide with a REAL file behind the needed name is a
# clean cover (the file is a symlink, so no shipped SONAME backs it — the
# provide + file resolution is what covers the stem).
ln -f -s libp-fixture-real "$tmp/s1/usr/bin/lib/libp-fixture.so.7"
printf 'fixture payload\n' >"$tmp/s1/usr/bin/lib/libp-fixture-real"
status=0
run out err -- "$tmp/s1" || status=$?
[[ $status == 0 ]] || fail "provide with a real file behind it did not cover (want 0), got $status: $out"

# ── 13. S3: a cached twin is never scanned for a `pacman -U` install ─────
# The stand-down for local file installs must NOT be cache-conditioned: a
# same-name archive sitting in the cache (a stale stock twin of a house
# build — NOTE 2026-10-25 made weston/colord move theirs out by hand) must
# not be scanned when the transaction installs a DIFFERENT file. alpm feeds
# bare names (no versions), so the transaction shape is read from the
# pacman argv — the fixture drives the tool under a stub named `pacman`
# whose argv carries `-U`.
tar --zstd -cf "$tmp/cache/pkg-twin-1.0.0-1-any.pkg.tar.zst" -C "$tmp/b" .
mkdir -p "$tmp/elsewhere"
tar --zstd -cf "$tmp/elsewhere/pkg-twin-9.9.9-1-any.pkg.tar.zst" -C "$tmp/a" .

# control: outside a `-U` transaction the cached archive IS the payload,
# and its fatal finding stays fatal…
status=0
out=$(printf 'pkg-twin\n' |
    GSA_ABI_NEED_CHECK_CACHE="$tmp/cache" "$tool" --from-names 2>/dev/null) || status=$?
[[ $status == 1 ]] || fail "cached twin not scanned outside -U (want fatal 1), got $status: $out"
[[ $out == *'libmissing-fixture.so.42'* ]] || fail "cached payload finding lost: $out"

# …but under `pacman -U <different file>` the hook stands down entirely.
cc -x c - "-DTOOL_PATH=\"$tool\"" -o "$tmp/pacman" <<'STUB' || fail "cannot build the pacman argv stub"
#include <sys/wait.h>
#include <unistd.h>
int main(void)
{
    pid_t pid = fork();
    if (pid == 0) {
        char *args[] = { "gsa-abi-need-check", "--from-names", NULL };
        execv(TOOL_PATH, args);
        _exit(127);
    }
    int status = 0;
    waitpid(pid, &status, 0);
    return WIFEXITED(status) ? WEXITSTATUS(status) : 1;
}
STUB
status=0
out=$(printf 'pkg-twin\n' |
    GSA_ABI_NEED_CHECK_CACHE="$tmp/cache" \
    "$tmp/pacman" -U "$tmp/elsewhere/pkg-twin-9.9.9-1-any.pkg.tar.zst" 2>/dev/null) || status=$?
[[ $status == 0 ]] || fail "cached twin was scanned for a -U install (want stand-down 0), got $status: $out"
[[ $out == *'pkg-twin: skipped (local file install'* ]] || fail "missing -U stand-down note: $out"
[[ $out != *'libmissing-fixture'* ]] || fail "cached twin was scanned instead of standing down: $out"

# ── 14. ld.so.cache truth: resolution through an ld.so.conf.d dir ─────────
# A soname visible only through the loader cache resolves (R's
# /usr/lib/R/lib class — /etc/ld.so.conf.d/R.conf, 2026-10-30: libR.so has
# NO DT_SONAME and the modules carry no RUNPATH, so only the cache maps the
# name to the file), with the SAME file-truth rule as the dir scan — a cache
# row pointing at nothing stays fatal (the dangling-symlink lesson,
# cache-shaped). The provider stands in for an ALREADY-INSTALLED file (it
# is never part of the scanned payload) and the cache is stubbed through
# PATH (the checker consults `ldconfig -p`, the map ld.so loads).
make_lib "$tmp/hostroot/usr/lib/rprivate" libgsc.so.3 libgsc.so.3
make_bin "$tmp/e/usr/bin" cache-consumer libgsc.so.3
make_bin "$tmp/e/usr/bin" dangling-consumer libdang.so.5
mkdir -p "$tmp/stubbin"
cat >"$tmp/stubbin/ldconfig" <<EOF
#!/usr/bin/env bash
printf '2 libs found in cache\n'
printf '\tlibgsc.so.3 (libc6,x86-64) => $tmp/hostroot/usr/lib/rprivate/libgsc.so.3\n'
printf '\tlibdang.so.5 (libc6,x86-64) => $tmp/hostroot/usr/lib/rprivate/libdang.so.5\n'
EOF
chmod +x "$tmp/stubbin/ldconfig"
make_pkgroot "$tmp/e" pkg-cache
status=0
PATH="$tmp/stubbin:$PATH" run out err -- --quiet "$tmp/e" || status=$?
[[ $status == 1 ]] || fail "dangling cache row resolved (want fatal 1), got $status: $out"
[[ $out == *"'dangling-consumer' needs 'libdang.so.5'"* ]] || fail "dangling cache row not flagged: $out"
[[ $out != *'libgsc.so.3'* ]] || fail "cache-visible soname not resolved: $out"

printf 'abi-need-check fixture: ok\n'
