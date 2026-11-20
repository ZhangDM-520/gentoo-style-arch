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

# This fixture belongs to the recipe tree's side of the split (its payloads are
# recipe-shaped), so it takes the checkout from the operator input
# `GSA_RECIPE_CHECKOUT` (contract §B.8) and SKIPS loudly (rc 0, one line) when
# there is none. The TOOL it pins stays in the engine repository: `$tool` is
# resolved from `$gsa_repo_root` (this fixture's own checkout), never from the
# recipe root — which is why `root` answers the skip gate only and the tool path
# keeps the engine-root name.
source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
root=$(gsa_recipe_root)
require_recipe_tree abi-need-check.sh
tool="$gsa_repo_root/tools/abi-need-check.sh"
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

# make_lib_bare DIR FILENAME — a shared object with NO DT_SONAME, so the
# loader indexes it by its bare file name only (perl's libperl.so).
make_lib_bare() {
    mkdir -p "$1"
    printf 'int gsa_fixture_anchor;\n' |
        cc -shared -x c - -o "$1/$2"
    readelf -dW "$1/$2" | grep -q '(SONAME)' &&
        fail "synthesis gave $2 a DT_SONAME the fixture claims it lacks"
    return 0
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

# make_bin_path DIR FILENAME LINK-AGAINST [RECORDED] — a consumer ELF whose
# DT_NEEDED is an ABSOLUTE PATH, the shape a DT_SONAME-less DSO produces when
# it is linked by path (`mpv` records `/usr/lib/libmujs.so` because mujs ships
# no DT_SONAME — issue #3). Linking against a real file with no SONAME records
# its path; linking against a stub whose SONAME is a path records that path
# (RECORDED) without needing the file to exist yet.
make_bin_path() {
    local dir=$1 file=$2 link=$3 recorded=${4:-$3}
    mkdir -p "$dir"
    printf 'int main(void){return 0;}\n' |
        cc -x c - -x none -Wl,--no-as-needed "$link" -o "$dir/$file"
    readelf -dW "$dir/$file" | grep -q "NEEDED.*\[$recorded\]" ||
        fail "synthesis failed to record DT_NEEDED $recorded"
}

# make_bin_path32 DIR FILENAME LINK — the `-m32` twin of `make_bin_path`: a
# real ELF32 DSO recording LINK as a path-style DT_NEEDED. The class assertions
# are the point: a header-shaped stub would let the class case pass for the
# wrong reason.
make_bin_path32() {
    local dir=$1 file=$2 link=$3
    mkdir -p "$dir"
    printf 'int gsa_fixture_anchor32;\n' |
        cc -m32 -shared -x c - -x none -Wl,--no-as-needed "$link" -o "$dir/$file"
    readelf -hW "$dir/$file" | grep -q 'Class: *ELF32' ||
        fail "synthesis did not produce an ELF32 consumer: $dir/$file"
    readelf -dW "$dir/$file" | grep -q "NEEDED.*\[$link\]" ||
        fail "synthesis failed to record path-style DT_NEEDED $link"
}

# make_stub_with_soname OUT SONAME — a throwaway DSO carrying SONAME, for a
# consumer that must record a path WITHOUT that path existing on the host.
make_stub_with_soname() {
    mkdir -p "$(dirname "$1")"
    printf 'int gsa_fixture_anchor;\n' |
        cc -shared -x c - -Wl,-soname,"$2" -o "$1"
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
    printf '# gsa-abi-need-check facts v3 %s\n' "$sha"
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
# build — JOURNAL 2026-10-25 made weston/colord move theirs out by hand) must
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

# ── 15. attribution: name the gsa-managed provider behind a finding ──────
# The fatal line leaves open whether the provider is a package the gsa tree
# manages and is behind on (2026-11-10: openssl 3.6.5 here vs core 4.1.0, so
# every rebuilt consumer needed libcrypto.so.4 and nothing resolved it). The
# checker answers it from the side-car binpkg index — one pass over
# line-delimited JSON, NAMES ONLY (never a version, never a command) — and
# only on the abort path: a clean run collects no stems and reads no index.
make_bin "$tmp/i/usr/bin" owned-consumer libmissing-fixture.so.42
make_pkgroot "$tmp/i" pkg-owned
printf '%s\n' \
    '{"op":"row","recipe_id":"fixture-lib","pkgbase":"fixture-lib","version":"0:1.0.0-1","provides":["libmissing-fixture.so=1-64"],"instance":1}' \
    '{"op":"row","recipe_id":"other-lib","pkgbase":"other-lib","version":"0:2.0.0-1","provides":["libother.so=2-64"],"instance":1}' \
    >"$tmp/index.jsonl"
status=0
GSA_ABI_NEED_CHECK_BINPKG="$tmp/index.jsonl" run out err -- "$tmp/i" || status=$?
[[ $status == 1 ]] || fail "attributed case exited $status (want 1): $err"
[[ $out == *"'owned-consumer' needs 'libmissing-fixture.so.42'"* ]] ||
    fail "fatal line lost under attribution: $out"
[[ $out == *'gsa-owned provider behind: fixture-lib'* ]] ||
    fail "attribution missing: $out"
[[ ${out##*$'\n'} == 'abi-need-check: gsa-owned provider behind: fixture-lib' ]] ||
    fail "attribution is not the closing summary line: $out"
[[ $out != *'other-lib'* ]] || fail "unrelated index row reported: $out"

# --quiet keeps findings, so it keeps the attribution with them.
status=0
GSA_ABI_NEED_CHECK_BINPKG="$tmp/index.jsonl" run out err -- --quiet "$tmp/i" || status=$?
[[ $status == 1 ]] || fail "quiet attributed case exited $status (want 1): $err"
[[ $out == *'gsa-owned provider behind: fixture-lib'* ]] ||
    fail "quiet mode dropped the attribution: $out"

# Unattributed: the index owns a DIFFERENT stem. The finding stands and the
# summary invents no name — matching is per stem, never "some row exists".
make_bin "$tmp/j/usr/bin" unowned-consumer libunowned-fixture.so.7
make_pkgroot "$tmp/j" pkg-unowned
status=0
GSA_ABI_NEED_CHECK_BINPKG="$tmp/index.jsonl" run out err -- "$tmp/j" || status=$?
[[ $status == 1 ]] || fail "unowned case exited $status (want 1): $err"
[[ $out == *"'unowned-consumer' needs 'libunowned-fixture.so.7'"* ]] ||
    fail "unowned finding lost: $out"
[[ $out != *'gsa-owned provider behind'* ]] || fail "attribution invented: $out"

# No index at all (fresh host, engine never ran): still fatal, still quiet
# about ownership, never a crash.
status=0
GSA_ABI_NEED_CHECK_BINPKG="$tmp/no-such-index.jsonl" run out err -- "$tmp/j" || status=$?
[[ $status == 1 ]] || fail "missing-index case exited $status (want 1): $err"
[[ $out != *'gsa-owned provider behind'* ]] || fail "attribution without an index: $out"
[[ $out == *"'unowned-consumer' needs 'libunowned-fixture.so.7'"* ]] ||
    fail "missing index swallowed the finding: $out"

# Clean payload: the attribution is gated on the call site, so the index is
# never OPENED. A missing path proves nothing (awk would swallow it under
# 2>/dev/null and print nothing anyway), so the index is a FIFO: any read
# blocks until a writer appears, which makes an unconditional read observable
# as a hang. The property has ONE owner — the `if ((findings))` call site — so
# this catches its removal on its own.
mkfifo "$tmp/index.fifo"
status=0
GSA_ABI_NEED_CHECK_BINPKG="$tmp/index.fifo" \
    timeout 10 "$tool" "$tmp/a" >"$tmp/clean.out" 2>&1 || status=$?
out=$(cat "$tmp/clean.out")
[[ $status == 0 ]] || fail "clean run opened the side-car index (rc $status — the abort-path gate is gone): $out"
[[ $out != *'gsa-owned provider behind'* ]] || fail "clean run printed an attribution: $out"
[[ $out == *'pkg-clean: clean'* ]] || fail "clean run lost its clean line: $out"

# ── 16. resolver equivalence: the class tag still discriminates ──────────
# The loader cache is read ONCE into an associative map now (measured
# 2026-11-11: 103 ms per miss rescanned all ~5.8k rows, 0.2 ms for a map
# hit). The rule the old inline loop enforced must survive the reshape, in
# ALL FOUR directions, and the multi-entry shape (one name carrying both a
# libc6 and a libc6,x86-64 row — 301 names on this host, measured 2026-11-11)
# must be traversed rather than truncated to its first entry:
#   ELF32 accepts the libc6 row, ELF32 REFUSES the x86-64 row,
#   ELF64 accepts the x86-64 row, ELF64 REFUSES the libc6 row.
# The x86-64 entry is listed FIRST, the order a real `ldconfig -p` emits, so
# an ELF32 lookup only resolves if the `;` list is walked past it.
mkdir -p "$tmp/host/usr/lib" "$tmp/host/usr/lib32" "$tmp/stub32" \
    "$tmp/f32/usr/lib" "$tmp/f32only/usr/lib" "$tmp/f64/usr/bin" "$tmp/f64only/usr/bin"
printf 'int gsa64_anchor;\n' |
    cc -shared -x c - -Wl,-soname,libg32.so.1 -o "$tmp/host/usr/lib/libg32.so.1"
printf 'int gsa32_anchor;\n' |
    cc -m32 -shared -x c - -Wl,-soname,libg32.so.1 -o "$tmp/host/usr/lib32/libg32.so.1"
printf 'int gsa32_only;\n' |
    cc -m32 -shared -x c - -Wl,-soname,libgonly32.so.1 -o "$tmp/host/usr/lib32/libgonly32.so.1"
printf 'int gsa64_only;\n' |
    cc -shared -x c - -Wl,-soname,libgonly64.so.1 -o "$tmp/host/usr/lib/libgonly64.so.1"

# ELF32 consumers: link for real against the 32-bit provider, and through a
# 32-bit stub for the name only a 64-bit row exists for (a 32-bit link
# cannot consume the 64-bit file — which is exactly the shape the class
# test must refuse).
printf 'int gsa32_consumer;\n' |
    cc -m32 -shared -x c - -Wl,--no-as-needed -o "$tmp/f32/usr/lib/libc32-consumer.so" \
        -L"$tmp/host/usr/lib32" -l:libg32.so.1
printf 'int gsa32only_stub;\n' |
    cc -m32 -shared -x c - -Wl,-soname,libgonly64.so.1 -o "$tmp/stub32/stub-libgonly64.so.1"
printf 'int gsa32only_consumer;\n' |
    cc -m32 -shared -x c - -Wl,--no-as-needed -o "$tmp/f32only/usr/lib/libc32only-consumer.so" \
        -L"$tmp/stub32" -l:stub-libgonly64.so.1
readelf -dW "$tmp/f32/usr/lib/libc32-consumer.so" | grep -q 'NEEDED.*\[libg32.so.1\]' ||
    fail 'synthesis failed to record the ELF32 DT_NEEDED (libg32)'
readelf -hW "$tmp/f32/usr/lib/libc32-consumer.so" | grep -q 'Class: *ELF32' ||
    fail 'synthesis did not produce an ELF32 consumer (the class case would pass for the wrong reason)'
readelf -dW "$tmp/f32only/usr/lib/libc32only-consumer.so" | grep -q 'NEEDED.*\[libgonly64.so.1\]' ||
    fail 'synthesis failed to record the ELF32 DT_NEEDED (libgonly64)'
readelf -hW "$tmp/f32only/usr/lib/libc32only-consumer.so" | grep -q 'Class: *ELF32' ||
    fail 'synthesis did not produce an ELF32 consumer (the refusal case would pass for the wrong reason)'
# ELF64 consumers go through the stub for both names (a 64-bit link cannot
# consume the 32-bit providers).
make_bin "$tmp/f64/usr/bin" consumer64 libg32.so.1
make_bin "$tmp/f64only/usr/bin" consumer64only libgonly32.so.1

mkdir -p "$tmp/stubbin32"
cat >"$tmp/stubbin32/ldconfig" <<EOF
#!/usr/bin/env bash
printf '4 libs found in cache\n'
printf '\tlibg32.so.1 (libc6,x86-64) => $tmp/host/usr/lib/libg32.so.1\n'
printf '\tlibg32.so.1 (libc6) => $tmp/host/usr/lib32/libg32.so.1\n'
printf '\tlibgonly64.so.1 (libc6,x86-64) => $tmp/host/usr/lib/libgonly64.so.1\n'
printf '\tlibgonly32.so.1 (libc6) => $tmp/host/usr/lib32/libgonly32.so.1\n'
EOF
chmod +x "$tmp/stubbin32/ldconfig"
make_pkgroot "$tmp/f32" pkg-elf32
status=0
PATH="$tmp/stubbin32:$PATH" run out err -- --quiet "$tmp/f32" || status=$?
[[ $status == 0 ]] || fail "ELF32 consumer did not walk past the x86-64 row to the libc6 one: $err $out"
[[ $out != *'libg32.so.1'* ]] || fail "ELF32 cache row reported a finding: $out"
make_pkgroot "$tmp/f32only" pkg-elf32-only64
status=0
PATH="$tmp/stubbin32:$PATH" run out err -- --quiet "$tmp/f32only" || status=$?
[[ $status == 1 ]] || fail "ELF32 consumer accepted an x86-64 cache row (want fatal 1), got $status: $out"
[[ $out == *"'libc32only-consumer.so' needs 'libgonly64.so.1'"* ]] ||
    fail "ELF32 class-mismatch finding lost: $out"
make_pkgroot "$tmp/f64" pkg-elf64
status=0
PATH="$tmp/stubbin32:$PATH" run out err -- --quiet "$tmp/f64" || status=$?
[[ $status == 0 ]] || fail "ELF64 consumer did not resolve through the x86-64 row: $err $out"
[[ $out != *'libg32.so.1'* ]] || fail "ELF64 cache row reported a finding: $out"
make_pkgroot "$tmp/f64only" pkg-elf64-only32
status=0
PATH="$tmp/stubbin32:$PATH" run out err -- --quiet "$tmp/f64only" || status=$?
[[ $status == 1 ]] || fail "64-bit consumer accepted a 32-bit cache row (want fatal 1), got $status: $out"
[[ $out == *"'consumer64only' needs 'libgonly32.so.1'"* ]] ||
    fail "ELF64 class-mismatch finding lost: $out"

# ── N. the Tier-2 exclusions registry is honoured ────────────────────────
# The install seam has always honoured `config/abi-exclusions.conf`
# (`AbiExclusions::covers`); this gate did not, so a documented exception still
# aborted every transaction — openimagedenoise's CUDA backend needs
# `libcuda.so.1`, unresolvable BY DESIGN on an AMD-only host, and `pacman -Syu`
# died in this hook from 2026-11-10 to 2026-11-14 while the INSTALLED version
# shipped the identical dangling plugin.
make_bin "$tmp/x/usr/bin" xconsumer libexcluded-fixture.so.9
make_bin "$tmp/x/usr/bin" xyconsumer libunlisted-fixture.so.9
make_pkgroot "$tmp/x" pkg-exclusion

# No registry: still fatal (the strict baseline this host had before).
status=0
GSA_ABI_NEED_CHECK_EXCLUSIONS=/dev/null run out err -- --quiet "$tmp/x" || status=$?
[[ $status == 1 ]] || fail "no registry must stay fatal (want 1), got $status: $out"

# A soname STEM row covers the versioned soname; the unlisted one still aborts,
# so the section cannot pass by exempting everything.
printf 'libexcluded-fixture.so|documented gap|2027-04-01\n' >"$tmp/exclusions.conf"
status=0
GSA_ABI_NEED_CHECK_EXCLUSIONS="$tmp/exclusions.conf" run out err -- --quiet "$tmp/x" || status=$?
[[ $status == 1 ]] || fail "an unlisted soname must still abort (want 1), got $status: $out"
[[ $out == *"'xyconsumer' needs 'libunlisted-fixture.so.9'"* ]] ||
    fail "unlisted soname lost its finding: $out"
[[ $out != *'libexcluded-fixture.so.9'* ]] ||
    fail "a registered soname stem still reported: $out"

# A package-id row exempts that package wholesale, and says so.
make_bin "$tmp/y/usr/bin" yconsumer libother-fixture.so.9
make_pkgroot "$tmp/y" pkg-excluded-id
printf 'pkg-excluded-id|documented gap|2027-04-01\n' >"$tmp/exclusions-id.conf"
status=0
GSA_ABI_NEED_CHECK_EXCLUSIONS="$tmp/exclusions-id.conf" run out err -- "$tmp/y" || status=$?
[[ $status == 0 ]] || fail "a registered package id was not exempt (want 0), got $status: $out"
[[ $out == *'pkg-excluded-id: skipped (documented ABI exclusion)'* ]] ||
    fail "exempt package line drifted: $out"

# An ABSENT registry path is the empty registry, never an error.
status=0
GSA_ABI_NEED_CHECK_EXCLUSIONS="$tmp/does-not-exist.conf" run out err -- --quiet "$tmp/y" || status=$?
[[ $status == 1 ]] || fail "a missing registry must degrade to empty (want fatal 1), got $status: $out"

# ── 17. a SONAME-less in-payload lib covers its own consumer ─────────────
# `tx_sonames` is the transaction-internal cover set, and it was built from
# the SONAME field alone. A payload lib that declares none is indexed by ld.so
# under its BARE FILE NAME, so `libperl.so` (usr/lib/perl5/5.44/core_perl/
# CORE/libperl.so, no DT_SONAME) never entered the set, its own consumer
# `usr/bin/perl` recorded `NEEDED libperl.so`, and `host_resolves` cannot
# succeed on a clean box: `perl` was uninstallable and every transaction
# carrying it aborted. A payload file's bare name is as loadable as a soname —
# same class, same existence — so it is the same cover.
make_lib_bare "$tmp/o/usr/lib/perl5/5.44/core_perl/CORE" libbare-fixture.so
# The runpath is the INSTALL path (absolute, as `perl` records it) and the
# payload file is not under it yet, so no direct file resolution can cover
# the name: only the transaction-internal set can.
make_bin "$tmp/o/usr/bin" bare-consumer libbare-fixture.so /usr/lib/perl5/5.44/core_perl/CORE
make_pkgroot "$tmp/o" pkg-bare-soname
status=0
run out err -- --quiet "$tmp/o" || status=$?
[[ $status == 0 ]] || fail "a SONAME-less in-payload lib did not cover its consumer (want 0), got $status: $out"
[[ $out == *'libbare-fixture.so'* ]] && fail "the SONAME-less cover still reported: $out"

# Negative control: the same consumer shape, but the bare-named file belongs to
# NO package of this transaction (it is not under the scanned root), so it must
# stay fatal — the section cannot pass by covering any bare name it has seen.
make_lib_bare "$tmp/elsewhere" libotherbare-fixture.so
make_bin "$tmp/o2/usr/bin" other-consumer libotherbare-fixture.so /usr/lib/perl5/5.44/core_perl/CORE
make_pkgroot "$tmp/o2" pkg-bare-unshipped
status=0
run out err -- --quiet "$tmp/o2" || status=$?
[[ $status == 1 ]] || fail "a bare name outside the transaction resolved (want 1), got $status: $out"
[[ $out == *"needs 'libotherbare-fixture.so'"* ]] || fail "absent bare-name finding lost: $out"

# ── 18. a payload symlink alias covers its own loader name ───────────────
# The transaction-internal cover set was built from DT_SONAME plus the bare
# name of a REGULAR payload file. A DSO the payload also ships as an
# unversioned symlink (`libaaf.so -> libaaf.so.0.0.0`, ardour issue #2) is
# absent from that set twice over: `find -type f` skips the link, and the
# regular file's own name (`libaaf.so.0.0.0`) is not the name a consumer
# records. When such a consumer needs the SYMLINK's name — which only the
# launcher's LD_LIBRARY_PATH (a private dir, no ld.so entry, no RUNPATH) can
# resolve — the gate called it fatal although the payload ships it.
make_lib_bare "$tmp/p/usr/lib/ardour9" libalias-fixture.so.1.2.3
ln -s libalias-fixture.so.1.2.3 "$tmp/p/usr/lib/ardour9/libalias-fixture.so"
make_bin "$tmp/p/usr/bin" alias-consumer libalias-fixture.so
make_pkgroot "$tmp/p" pkg-private-libdir
status=0
run out err -- --quiet "$tmp/p" || status=$?
[[ $status == 0 ]] || fail "a payload symlink alias did not cover its consumer (want 0), got $status: $out"
[[ $out == *'libalias-fixture.so'* ]] && fail "the payload alias still reported: $out"

# A SONAME-carrying payload file is loadable under its own FILE name too (the
# private dir is on the loader path by launcher, nothing else names it).
make_lib "$tmp/p/usr/lib/ardour9" libsonamefile-fixture.so.3.0.0 libsonamefile-fixture.so.3
make_bin "$tmp/p/usr/bin" sonamefile-consumer libsonamefile-fixture.so.3.0.0
status=0
run out err -- --quiet "$tmp/p" || status=$?
[[ $status == 0 ]] || fail "a payload file did not cover its own name (want 0), got $status: $out"

# Negative control A: the link's target is NOT this package's file (it lives
# outside the scanned root), so its name must stay fatal.
make_lib_bare "$tmp/elsewhere18" liboutlink-fixture.so.7.0.0
mkdir -p "$tmp/p2/usr/lib/priv"
ln -s "$tmp/elsewhere18/liboutlink-fixture.so.7.0.0" "$tmp/p2/usr/lib/priv/liboutlink-fixture.so"
make_bin "$tmp/p2/usr/bin" outlink-consumer liboutlink-fixture.so
make_pkgroot "$tmp/p2" pkg-private-outlink
status=0
run out err -- --quiet "$tmp/p2" || status=$?
[[ $status == 1 ]] || fail "a link out of the payload resolved (want 1), got $status: $out"
[[ $out == *"needs 'liboutlink-fixture.so'"* ]] || fail "absent out-of-payload finding lost: $out"

# Negative control B: no name of this batch covers anything — a provider that
# belongs to NO package of the transaction stays fatal.
make_lib "$tmp/elsewhere2" libunshipped-fixture.so.4 libunshipped-fixture.so.4
make_bin "$tmp/p3/usr/bin" unshipped-consumer libunshipped-fixture.so.4
make_pkgroot "$tmp/p3" pkg-private-unshipped
status=0
run out err -- --quiet "$tmp/p3" || status=$?
[[ $status == 1 ]] || fail "a private name outside the transaction resolved (want 1), got $status: $out"
[[ $out == *"needs 'libunshipped-fixture.so.4'"* ]] || fail "absent private-lib finding lost: $out"


# ── 19. the registry resolves through the ACTIVE workspace first ──────────
# Issue #2 secondary: a host with a store copy but no `project` key in
# /etc/gsa/gsa.conf silently read the STALE store registry, so an edit to the
# checkout's config/abi-exclusions.conf was untestable — the hook kept
# exempting whatever the store said. The engine's own conf ladder decides what
# the active workspace IS (GSA_CONF > GSA_CONF_DIR > /etc/gsa then
# ~/.config/gsa), and the checkout that ladder names is the operator's
# workspace: its registry must win over the store copy.
mkdir -p "$tmp/store/.local/share/gsa/recipes/config" "$tmp/ws/config" "$tmp/state"
printf '# store copy: no rows\n' >"$tmp/store/.local/share/gsa/recipes/config/abi-exclusions.conf"
printf 'libwsgap-fixture.so|checkout gap under review|2027-04-01\n' >"$tmp/ws/config/abi-exclusions.conf"
printf 'project = %s\n' "$tmp/ws" >"$tmp/gsa.conf"
make_bin "$tmp/z/usr/bin" zconsumer libwsgap-fixture.so.9
make_pkgroot "$tmp/z" pkg-workspace-registry

# Baseline: the store copy is what gets read when no workspace is active.
status=0
SUDO_HOME="$tmp/store" GSA_STATE_DIR="$tmp/state" GSA_CONF=/nonexistent/gsa.conf \
    run out err -- --quiet "$tmp/z" || status=$?
[[ $status == 1 ]] || fail "the store copy was not read as the baseline (want 1), got $status: $out"

status=0
SUDO_HOME="$tmp/store" GSA_STATE_DIR="$tmp/state" GSA_CONF="$tmp/gsa.conf" \
    run out err -- --quiet "$tmp/z" || status=$?
[[ $status == 0 ]] || fail "the ACTIVE workspace registry was not honoured (want 0), got $status: $out"

# The explicit override still beats the workspace registry.
printf '# override: no rows\n' >"$tmp/override.conf"
status=0
SUDO_HOME="$tmp/store" GSA_STATE_DIR="$tmp/state" GSA_CONF="$tmp/gsa.conf" \
    GSA_ABI_NEED_CHECK_EXCLUSIONS="$tmp/override.conf" run out err -- --quiet "$tmp/z" || status=$?
[[ $status == 1 ]] || fail "the explicit override did not win (want 1), got $status: $out"

# `GSA_CONF_DIR` collapses the ladder onto one directory (fixture control) —
# and `GSA_CONF` above wins outright over it, exactly as `config::load` merges.
mkdir -p "$tmp/confdir"
printf 'project = %s\n' "$tmp/ws" >"$tmp/confdir/gsa.conf"
status=0
SUDO_HOME="$tmp/store" GSA_STATE_DIR="$tmp/state" GSA_CONF_DIR="$tmp/confdir" \
    run out err -- --quiet "$tmp/z" || status=$?
[[ $status == 0 ]] || fail "GSA_CONF_DIR was not consulted (want 0), got $status: $out"


# A non-ELF payload FILE must never cover a loader name: readelf_facts emits a
# record for every tracked payload file (the resolve loop skips the non-ELF
# ones), so an unguarded basename would let a data file named like a soname
# cover a real miss — measured: 18 834 "sonames" from 117 ELFs plus 18 751
# data files, and the whole scan went 2 s -> 29 s.
mkdir -p "$tmp/p/usr/share/ardour9"
# Content that makes readelf emit its `File:` marker with NO class (a `#!`
# script does not even get that far), so the record exists and only the
# class gate can keep it out of the cover set.
printf 'plain payload text, not an ELF \n%.0s' $(seq 1 8) >"$tmp/p/usr/share/ardour9/libfakeelf-fixture.so.1"
make_bin "$tmp/p/usr/bin" fakeelf-consumer libfakeelf-fixture.so.1
status=0
run out err -- --quiet "$tmp/p" || status=$?
[[ $status == 1 ]] || fail "a data file covered a loader name (want 1), got $status: $out"
[[ $out == *"needs 'libfakeelf-fixture.so.1'"* ]] || fail "data-file cover finding lost: $out"
rm -rf "$tmp/p/usr/share/ardour9" "$tmp/p/usr/bin/fakeelf-consumer"

# ── 20. a PATH-STYLE DT_NEEDED resolves at its exact path (issue #3) ──────
# A shared object with NO DT_SONAME linked by absolute path records that
# path as its DT_NEEDED (`readelf -d mpv | grep NEEDED.*/` →
# `/usr/lib/libmujs.so`). The loader opens exactly that file: it consults
# neither the default libdirs nor ld.so.cache for a name containing '/'. The
# hook used to prefix a libdir onto the absolute name (`/usr/lib//usr/lib/…`)
# and fall back to a cache keyed on the literal path, so both halves missed
# and a file that exists at the recorded path aborted the transaction.
mkdir -p "$tmp/hostpath/usr/lib"
make_lib_bare "$tmp/hostpath/usr/lib" libnopath-fixture.so
make_bin_path "$tmp/h/usr/bin" path-consumer "$tmp/hostpath/usr/lib/libnopath-fixture.so"
make_pkgroot "$tmp/h" pkg-path-style
status=0
run out err -- --quiet "$tmp/h" || status=$?
[[ $status == 0 ]] || fail "an existing path-style DT_NEEDED did not resolve (want 0), got $status: $out"
[[ $out == *'libnopath-fixture.so'* ]] && fail "the resolved path-style name still reported: $out"

# Negative control: the SAME consumer with the file gone stays fatal — that
# is the vanished-provider case the hook exists for, not a false alarm.
rm -f "$tmp/hostpath/usr/lib/libnopath-fixture.so"
status=0
run out err -- --quiet "$tmp/h" || status=$?
[[ $status == 1 ]] || fail "a vanished path-style provider resolved (want 1), got $status: $out"
[[ $out == *"needs '$tmp/hostpath/usr/lib/libnopath-fixture.so'"* ]] ||
    fail "the absent path-style finding lost its exact path: $out"

# The exact path is the WHOLE answer: `ld.so` opens it and never consults the
# cache for a name containing '/'. A cache row carrying the same BASENAME but
# pointing at a different file must not resolve it — that fallback was
# proposed in review and rejected here, because it turns a real miss green
# (measured: rc 0 on this shape with the fallback in place).
mkdir -p "$tmp/bn/usr/lib" "$tmp/bn/usr/bin" "$tmp/bnstub"
make_lib "$tmp/bn/usr/lib" libdecoy-fixture.so libdecoy-fixture.so
make_stub_with_soname "$tmp/bn-stub.so" "$tmp/hostpath/usr/lib/libnopath-fixture.so"
make_bin_path "$tmp/bn/usr/bin" basename-consumer "$tmp/bn-stub.so" "$tmp/hostpath/usr/lib/libnopath-fixture.so"
cat >"$tmp/bnstub/ldconfig" <<EOF
#!/usr/bin/env bash
printf '1 libs found in cache\n'
printf '\tlibnopath-fixture.so (libc6,x86-64) => $tmp/bn/usr/lib/libdecoy-fixture.so\n'
EOF
chmod +x "$tmp/bnstub/ldconfig"
make_pkgroot "$tmp/bn" pkg-path-basename-decoy
status=0
PATH="$tmp/bnstub:$PATH" run out err -- --quiet "$tmp/bn" || status=$?
[[ $status == 1 ]] || fail "a basename cache row resolved a path-style need (want 1), got $status: $out"
[[ $out == *"needs '$tmp/hostpath/usr/lib/libnopath-fixture.so'"* ]] ||
    fail "basename-decoy finding lost its exact path: $out"

# Class guard: the file EXISTS at the recorded path but is not the consumer's
# ELF class. Both directions are linked for real (`-m32` yields a genuine
# ELF32 object, not a header-shaped stub): a 64-bit consumer must not be
# satisfied by a 32-bit file, and a 32-bit consumer must be satisfied by it —
# so the refusal is a class decision, not a blanket refusal of path-style
# names. "Exists" alone is not resolution.
mkdir -p "$tmp/cl"
printf 'int gsa_fixture_anchor;\n' |
    cc -m32 -shared -x c - -o "$tmp/cl/libclass-fixture.so"
readelf -hW "$tmp/cl/libclass-fixture.so" | grep -q 'Class: *ELF32' ||
    fail 'synthesis did not produce an ELF32 provider (the class case would pass for the wrong reason)'
make_stub_with_soname "$tmp/cl-stub.so" "$tmp/cl/libclass-fixture.so"
make_bin_path "$tmp/clpkg/usr/bin" class-consumer "$tmp/cl-stub.so" "$tmp/cl/libclass-fixture.so"
make_pkgroot "$tmp/clpkg" pkg-path-class
status=0
run out err -- --quiet "$tmp/clpkg" || status=$?
[[ $status == 1 ]] || fail "an ELF32 file resolved a 64-bit path-style need (want 1), got $status: $out"
[[ $out == *"needs '$tmp/cl/libclass-fixture.so'"* ]] ||
    fail "64-bit class-mismatch finding lost: $out"

make_bin_path32 "$tmp/cl32pkg/usr/lib" class32-consumer "$tmp/cl/libclass-fixture.so"
make_pkgroot "$tmp/cl32pkg" pkg-path-class32
status=0
run out err -- --quiet "$tmp/cl32pkg" || status=$?
[[ $status == 0 ]] || fail "an ELF32 consumer did not resolve its own class at the path (want 0), got $status: $err $out"
[[ $out != *'libclass-fixture.so'* ]] || fail "the resolved ELF32 path-style name still reported: $out"

# Transaction-internal: a payload that SHIPS the SONAME-less provider at the
# exact absolute path the consumer records covers it before the files land.
# The consumer is linked against a stub whose SONAME is the INSTALL path
# (`/usr/lib/…`), which no host file carries here.
make_lib_bare "$tmp/tx/usr/lib" libinpay-fixture.so
make_stub_with_soname "$tmp/tx-stub.so" /usr/lib/libinpay-fixture.so
make_bin_path "$tmp/tx/usr/bin" tx-consumer "$tmp/tx-stub.so" /usr/lib/libinpay-fixture.so
make_pkgroot "$tmp/tx" pkg-path-in-payload
status=0
run out err -- --quiet "$tmp/tx" || status=$?
[[ $status == 0 ]] || fail "a payload-shipped path-style provider did not cover its consumer (want 0), got $status: $out"

# Negative control: the same consumer with the provider in NO package of the
# transaction stays fatal — the cover set is not "any path-style name seen".
mkdir -p "$tmp/txo/usr/bin"
cp "$tmp/tx/usr/bin/tx-consumer" "$tmp/txo/usr/bin/tx-consumer"
make_pkgroot "$tmp/txo" pkg-path-unshipped
status=0
run out err -- --quiet "$tmp/txo" || status=$?
[[ $status == 1 ]] || fail "an unshipped path-style name resolved (want 1), got $status: $out"
[[ $out == *"needs '/usr/lib/libinpay-fixture.so'"* ]] || fail "unshipped path-style finding lost: $out"

# ── 21. issue #7: a transaction that DROPS a soname strands its consumers ─
# Phase 2 resolves the incoming packages' DT_NEEDED only, so a provider
# moving `libsndio.so.7 -> .so.9` passed while every installed consumer of
# the OLD soname lost its file at the same instant (measured 2026-11-20:
# mpv, celluloid and kodi.bin died on a stock `pacman -Syu`). The hook now
# diffs the incoming sonames against the INSTALLED package's shipped set
# (the pacman local DB), resolves installed consumers of what it takes
# away, and refuses with `need-rebuild` rows.
#
# The synthetic world is a root prefix plus a three-entry local DB: the
# installed `sndio 1.11.0-1` owns one DSO, three consumers link it, and the
# incoming `sndio 1.11.0-2` ships only `.so.9`.
drop_root="$tmp/drop-root"
drop_db="$tmp/drop-db"
drop_cache="$tmp/drop-cache"
drop_bin="$tmp/drop-bin"
mkdir -p "$drop_root/usr/lib" "$drop_root/usr/bin" "$drop_cache" \
    "$drop_db/local/sndio-1.11.0-1" "$drop_bin"
make_lib "$drop_root/usr/lib" libsndio.so.7 libsndio.so.7
make_bin "$drop_root/usr/bin" mpv libsndio.so.7
make_bin "$drop_root/usr/bin" celluloid libsndio.so.7
# Not a `*.so*` name and nested one level down — the kodi.bin shape: the
# executable bit is what makes it a candidate, not its name.
make_bin "$drop_root/usr/lib/kodi" kodi.bin libsndio.so.7
mkdir -p "$drop_root/opt/stockapp/bin"
make_bin "$drop_root/opt/stockapp/bin" stockapp libsndio.so.7
chmod +x "$drop_root/usr/bin/mpv" "$drop_root/usr/bin/celluloid" \
    "$drop_root/usr/lib/kodi/kodi.bin" "$drop_root/opt/stockapp/bin/stockapp"
cat >"$drop_db/local/sndio-1.11.0-1/desc" <<'EOF'
%NAME%
sndio

%VERSION%
1.11.0-1
EOF
cat >"$drop_db/local/sndio-1.11.0-1/files" <<'EOF'
%FILES%
usr/
usr/lib/
usr/lib/libsndio.so.7
EOF
cat >"$drop_bin/pacman" <<EOF
#!/usr/bin/env bash
case \${1:-} in
-Qoq)
    case \${2:-} in
    "$drop_root"/usr/bin/mpv) echo mpv ;;
    "$drop_root"/usr/bin/celluloid) echo celluloid ;;
    "$drop_root"/usr/lib/kodi/kodi.bin) echo kodi ;;
    "$drop_root"/opt/stockapp/bin/stockapp) echo stockapp ;;
    *) exit 1 ;;
    esac
    ;;
*) exit 0 ;;
esac
EOF
chmod +x "$drop_bin/pacman"
# The incoming archive: same pkgname, one new generation of the soname.
make_lib "$tmp/drop-new/usr/lib" libsndio.so.9 libsndio.so.9
printf 'pkgname = sndio\npkgver = 1.11.0-2\narch = any\n' >"$tmp/drop-new/.PKGINFO"
tar --zstd -cf "$drop_cache/sndio-1.11.0-2-any.pkg.tar.zst" -C "$tmp/drop-new" .
# A second transaction member that still ships the old generation: the drop
# is not a drop when another member carries it.
make_lib "$tmp/drop-compat/usr/lib" libsndio.so.7 libsndio.so.7
printf 'pkgname = libsndio-compat\npkgver = 1.11.0-2\narch = any\n' >"$tmp/drop-compat/.PKGINFO"
tar --zstd -cf "$drop_cache/libsndio-compat-1.11.0-2-any.pkg.tar.zst" -C "$tmp/drop-compat" .
# The consumer that IS a transaction member (its own upgrade clears it).
mkdir -p "$tmp/drop-mpv/usr/bin"
# A non-ELF payload is enough: this member exists to be IN the transaction,
# and phase 2 finds nothing to resolve inside it.
: >"$tmp/drop-mpv/usr/bin/mpv"
printf 'pkgname = mpv\npkgver = 0.42.0-3\narch = any\n' >"$tmp/drop-mpv/.PKGINFO"
tar --zstd -cf "$drop_cache/mpv-0.42.0-3-any.pkg.tar.zst" -C "$tmp/drop-mpv" .

drop_env=(PATH="$drop_bin:$PATH" GSA_ABI_NEED_CHECK_ROOT="$drop_root"
    GSA_ABI_NEED_CHECK_LOCALDB="$drop_db" GSA_ABI_NEED_CHECK_CACHE="$drop_cache"
    GSA_ABI_NEED_CHECK_FACTCACHE="$tmp/drop-facts")

# The exact row set the issue's acceptance pins.
status=0
out=$(printf 'sndio\n' | env "${drop_env[@]}" "$tool" --from-names 2>&1) || status=$?
[[ $status == 1 ]] || fail "a dropped soname did not refuse (want 1), got $status: $out"
[[ $out == *'sndio: drops libsndio.so.7 (installed consumers: celluloid, kodi, mpv, stockapp)'* ]] ||
    fail "drop row lost or unordered: $out"
for consumer in mpv celluloid kodi stockapp; do
    [[ $out == *"need-rebuild $consumer libsndio.so.7"* ]] ||
        fail "missing need-rebuild row for $consumer: $out"
done
[[ $out != *': clean ('* ]] || fail "a clean line rode a finding: $out"

# The provider's own `provides = libsndio.so=9-64` parses to the bare stem
# `libsndio.so`, and a stem match would class `.so.7` as covered — the exact
# false negative this phase exists to stop (blind review 2026-11-20).
make_lib "$tmp/drop-prov/usr/lib" libsndio.so.9 libsndio.so.9
{
    printf 'pkgname = sndio\n'
    printf 'pkgver = 1.11.0-3\n'
    printf 'arch = any\n'
    printf 'provides = libsndio.so=9-64\n'
} >"$tmp/drop-prov/.PKGINFO"
# Its own cache: newest-wins would otherwise hand the other cases this
# archive, and each case must pin ONE input.
mkdir -p "$tmp/drop-cache-prov"
tar --zstd -cf "$tmp/drop-cache-prov/sndio-1.11.0-3-any.pkg.tar.zst" -C "$tmp/drop-prov" .
status=0
# `env` applies assignments left to right, so the per-case override comes
# AFTER the shared set — the other order silently ran the wrong cache.
out=$(printf 'sndio\n' |
    env "${drop_env[@]}" GSA_ABI_NEED_CHECK_CACHE="$tmp/drop-cache-prov" \
    "$tool" --from-names 2>&1) || status=$?
[[ $status == 1 ]] ||
    fail "a versioned provide swallowed the dropped generation (want 1), got $status: $out"
[[ $out == *'need-rebuild mpv libsndio.so.7'* ]] ||
    fail "the dropped generation was not reported beside the provide: $out"

# A consumer carried by the transaction is covered — exactly the engine's
# `in_tx`, and its own upgrade is what clears it.
status=0
out=$(printf 'sndio\nmpv\n' | env "${drop_env[@]}" "$tool" --from-names 2>&1) || status=$?
[[ $status == 1 ]] || fail "uncovered consumers must still refuse (want 1), got $status: $out"
[[ $out != *'need-rebuild mpv '* ]] || fail "a transaction member was named for rebuild: $out"
[[ $out == *'need-rebuild celluloid libsndio.so.7'* ]] ||
    fail "covered member swallowed the other consumers: $out"

# Another member shipping the old generation is coverage too.
status=0
out=$(printf 'sndio\nlibsndio-compat\n' | env "${drop_env[@]}" "$tool" --from-names 2>&1) || status=$?
[[ $status == 0 ]] || fail "a co-shipped soname still refused (want 0), got $status: $out"
[[ $out != *'need-rebuild'* ]] || fail "co-shipped soname produced rebuild rows: $out"

# The reviewed exclusion registry still wins.
printf 'libsndio.so.7|documented gap|2027-04-01\n' >"$tmp/drop-exclusions.conf"
status=0
out=$(printf 'sndio\n' |
    GSA_ABI_NEED_CHECK_EXCLUSIONS="$tmp/drop-exclusions.conf" \
    env "${drop_env[@]}" "$tool" --from-names 2>&1) || status=$?
[[ $status == 0 ]] || fail "an excluded soname still refused (want 0), got $status: $out"

# A fresh install (no installed entry) can only ADD sonames. The archive
# must really exist, or the hook exits before phase 3 and the case proves
# nothing (round-3 review 2026-11-20).
mkdir -p "$tmp/drop-brand/usr/lib" "$tmp/drop-cache-brand"
make_lib "$tmp/drop-brand/usr/lib" libbrand.so.1 libbrand.so.1
printf 'pkgname = brand-new\npkgver = 1.0-1\narch = any\n' >"$tmp/drop-brand/.PKGINFO"
tar --zstd -cf "$tmp/drop-cache-brand/brand-new-1.0-1-any.pkg.tar.zst" -C "$tmp/drop-brand" .
status=0
out=$(printf 'brand-new\n' |
    env "${drop_env[@]}" GSA_ABI_NEED_CHECK_CACHE="$tmp/drop-cache-brand" \
    "$tool" --from-names 2>&1) || status=$?
[[ $status == 0 ]] || fail "a fresh install refused (want 0), got $status: $out"
[[ $out == *'brand-new: clean ('* ]] ||
    fail "the fresh-install archive was never scanned: $out"
[[ $out != *'drops ' && $out != *'unreadable'* ]] ||
    fail "a package with no installed entry reported a drop: $out"

# An unreadable installed entry is NOT "drops nothing" (rule 71).
ln -sfn "$tmp/does-not-exist-files" "$drop_db/local/sndio-1.11.0-1/files"
status=0
out=$(printf 'sndio\n' | env "${drop_env[@]}" "$tool" --from-names 2>&1) || status=$?
rm -f "$drop_db/local/sndio-1.11.0-1/files"
cat >"$drop_db/local/sndio-1.11.0-1/files" <<'EOF'
%FILES%
usr/
usr/lib/
usr/lib/libsndio.so.7
EOF
[[ $status == 1 ]] || fail "an unreadable installed entry passed (want 1), got $status: $out"
[[ $out == *'sndio: installed file list is unreadable'* ]] ||
    fail "unreadable entry finding lost: $out"

# Coverage is CLASS-SCOPED: upgrading `sndio` beside `lib32-sndio` ships the
# same soname for the 32-bit class only, and the 64-bit consumers are exactly
# who die (round-2 spec review 2026-11-20).
mkdir -p "$tmp/drop-cache-class"
cp "$drop_cache/sndio-1.11.0-2-any.pkg.tar.zst" "$tmp/drop-cache-class/"
mkdir -p "$tmp/drop-new32/usr/lib32"
printf 'int gsa_fixture_anchor32;\n' |
    cc -m32 -shared -x c - -Wl,-soname,libsndio.so.7 \
        -o "$tmp/drop-new32/usr/lib32/libsndio.so.7" ||
    fail "cannot synthesise a 32-bit payload (multilib toolchain missing)"
printf 'pkgname = lib32-sndio\npkgver = 1.11.0-2\narch = any\n' >"$tmp/drop-new32/.PKGINFO"
tar --zstd -cf "$tmp/drop-cache-class/lib32-sndio-1.11.0-2-any.pkg.tar.zst" \
    -C "$tmp/drop-new32" .
status=0
out=$(printf 'sndio\nlib32-sndio\n' |
    env "${drop_env[@]}" GSA_ABI_NEED_CHECK_CACHE="$tmp/drop-cache-class" \
    "$tool" --from-names 2>&1) || status=$?
[[ $status == 1 ]] ||
    fail "a 32-bit co-ship covered the 64-bit drop (want 1), got $status: $out"
[[ $out == *'need-rebuild mpv libsndio.so.7'* ]] ||
    fail "the 64-bit consumers were covered by a 32-bit ship: $out"

# A consumer carrying its OWN copy along RUNPATH is not a consumer of what
# disappears: the loader never leaves the bundle (round-2 spec review
# 2026-11-20). The provider's file is still dropped for everyone else.
make_lib "$drop_root/opt/bundle/lib" libsndio.so.7 libsndio.so.7
mkdir -p "$drop_root/opt/bundle/bin"
make_bin "$drop_root/opt/bundle/bin" bundled libsndio.so.7 '$ORIGIN/../lib'
chmod +x "$drop_root/opt/bundle/bin/bundled"
drop_bin2="$tmp/drop-bin2"
mkdir -p "$drop_bin2"
cp "$drop_bin/pacman" "$drop_bin2/pacman"
cat >"$drop_bin2/pacman" <<EOF
#!/usr/bin/env bash
case \${1:-} in
-Qoq)
    case \${2:-} in
    "$drop_root"/usr/bin/mpv) echo mpv ;;
    "$drop_root"/usr/bin/celluloid) echo celluloid ;;
    "$drop_root"/usr/lib/kodi/kodi.bin) echo kodi ;;
    "$drop_root"/opt/stockapp/bin/stockapp) echo stockapp ;;
    "$drop_root"/opt/bundle/bin/bundled) echo bundled ;;
    *) exit 1 ;;
    esac
    ;;
*) exit 0 ;;
esac
EOF
chmod +x "$drop_bin2/pacman"
status=0
out=$(printf 'sndio\n' |
    env "${drop_env[@]}" PATH="$drop_bin2:$PATH" "$tool" --from-names 2>&1) || status=$?
[[ $status == 1 ]] || fail "a bundled private copy still refused (want 1), got $status: $out"
[[ $out == *'need-rebuild mpv libsndio.so.7'* ]] ||
    fail "the bundled app swallowed the real consumers: $out"
[[ $out != *'need-rebuild bundled'* && $out != *'need-rebuild /'"$drop_root"'/opt/bundle/bin/bundled'* ]] ||
    fail "a consumer with its own RUNPATH copy was reported: $out"
rm -rf "$drop_root/opt/bundle" "$drop_bin2"

# A scan whose candidate set is exactly ONE file still resolves it: readelf
# prints no `File:` marker for a single input, so the chunker writes one
# (round-3 review 2026-11-20). The provider's own DSO lives outside the
# scanned roots here, which leaves the consumer as the only candidate.
single_root="$tmp/single-root"
single_db="$tmp/single-db"
mkdir -p "$single_root/var/lib/sndio" "$single_root/usr/bin" "$single_db/local/sndio-1.11.0-1"
make_lib "$single_root/var/lib/sndio" libsndio.so.7 libsndio.so.7
make_bin "$single_root/usr/bin" only-consumer libsndio.so.7
chmod +x "$single_root/usr/bin/only-consumer"
cat >"$single_db/local/sndio-1.11.0-1/desc" <<'EOF'
%NAME%
sndio

%VERSION%
1.11.0-1
EOF
cat >"$single_db/local/sndio-1.11.0-1/files" <<'EOF'
%FILES%
var/
var/lib/
var/lib/sndio/
var/lib/sndio/libsndio.so.7
usr/
usr/bin/
usr/bin/only-consumer
EOF
mkdir -p "$tmp/single-new/usr/lib" "$tmp/single-cache" "$tmp/single-bin"
make_lib "$tmp/single-new/usr/lib" libsndio.so.9 libsndio.so.9
printf 'pkgname = sndio\npkgver = 1.11.0-4\narch = any\n' >"$tmp/single-new/.PKGINFO"
tar --zstd -cf "$tmp/single-cache/sndio-1.11.0-4-any.pkg.tar.zst" -C "$tmp/single-new" .
cat >"$tmp/single-bin/pacman" <<EOF
#!/usr/bin/env bash
case \${1:-} in
-Qoq)
    case \${2:-} in
    "$single_root"/usr/bin/only-consumer) echo only-consumer ;;
    *) exit 1 ;;
    esac
    ;;
*) exit 0 ;;
esac
EOF
chmod +x "$tmp/single-bin/pacman"
status=0
out=$(printf 'sndio\n' |
    PATH="$tmp/single-bin:$PATH" GSA_ABI_NEED_CHECK_ROOT="$single_root" \
    GSA_ABI_NEED_CHECK_LOCALDB="$single_db" \
    GSA_ABI_NEED_CHECK_CACHE="$tmp/single-cache" \
    GSA_ABI_NEED_CHECK_FACTCACHE="$tmp/single-facts" \
    "$tool" --from-names 2>&1) || status=$?
[[ $status == 1 ]] || fail "a one-candidate scan resolved nothing (want 1), got $status: $out"
[[ $out == *'need-rebuild only-consumer libsndio.so.7'* ]] ||
    fail "the single-file chunk lost its consumer: $out"

# The `-U` stand-down covers phase 3 as well: the engine gates its own
# installs, and a local file install is not a sync transaction.
status=0
out=$(printf 'sndio\n' | env "${drop_env[@]}" "$tmp/pacman" -U \
    "$drop_cache/sndio-1.11.0-2-any.pkg.tar.zst" 2>&1) || status=$?
[[ $status == 0 ]] || fail "phase 3 ran under a -U install (want 0), got $status: $out"
[[ $out == *'sndio: skipped (local file install'* ]] || fail "missing -U stand-down note: $out"
[[ $out != *'need-rebuild'* ]] || fail "a -U install produced rebuild rows: $out"

printf 'abi-need-check fixture: ok\n' 
