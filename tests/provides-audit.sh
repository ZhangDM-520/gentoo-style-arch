#!/usr/bin/env bash
set -euo pipefail

# tools/provides-audit.sh owns the soname-provides PRESENCE rule at artifact
# level: every DT_SONAME a built package ships must be covered by a declared
# provides entry. The tool is a host-side diagnostic (it reads real built
# archives), so it lives outside the battery; this fixture pins its contract
# at reduced scale against synthetic packages under $TMPDIR — the same
# two-adapter pairing as tools/go-modcache-check.sh ↔ tests/modcache-check.sh.
#
# What is pinned here:
#   * presence-only semantics: the declared name must be the bare stem
#     (`libfoo.so` — covering `libfoo.so` itself and `libfoo.so.<generation>`)
#     or the full soname (`libfoo.so.1` == `libfoo.so.1`); a plain `libfoo`
#     is neither shape and covers NOTHING — the FORM rule (declare bare)
#     belongs to the audit lint, not here;
#   * the exact finding message, including the derived bare stem;
#   * archive input extracts under $TMPDIR only;
#   * inputs are never modified (a decoy that is never named must survive
#     byte-identical, and a named input must too);
#   * --quiet and the exit-status contract (0 clean, 1 findings, 2 usage).

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tool="$root/tools/provides-audit.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-provides-audit-fixture.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'provides-audit fixture: %s\n' "$1" >&2
    exit 1
}

command -v cc >/dev/null 2>&1 || fail 'cc is required to synthesize DT_SONAME payloads'
command -v readelf >/dev/null 2>&1 || fail 'readelf is required'
[[ -x $tool ]] || fail "tool is not executable: $tool"

# make_payload DIR SONAME — one tiny shared object carrying DT_SONAME.
make_payload() {
    mkdir -p "$1"
    printf 'int gsa_fixture_anchor;\n' |
        cc -shared -x c - -Wl,-soname,"$2" -o "$1/$2"
}

# make_pkgroot DIR PKGNAME [provides...] — .PKGINFO plus payload files that
# follow in the caller.
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

# snapshot DIR — deterministic byte inventory for the not-touched assertions.
snapshot() {
    (cd "$1" && find . -type f -exec md5sum {} + | sort)
}

# --- green: soname covered by a declared bare stem --------------------------
green=$tmp/green
make_pkgroot "$green" libfoo 'libfoo.so=1-64'
make_payload "$green/usr/lib" libfoo.so.1
out=$("$tool" "$green") || fail "a package whose soname is declared must exit 0 (got $?): $out"
grep -Fq 'libfoo: clean (1 soname(s))' <<<"$out" ||
    fail "a clean package must report its pkgname and soname count, got: $out"

# --quiet is the battery/script contract: no output at all on clean.
out=$("$tool" --quiet "$green") || fail "--quiet on a clean package must exit 0"
[[ -z $out ]] || fail "--quiet on a clean package must print nothing, got: $out"

# --- green: no shipped sonames at all ---------------------------------------
flat=$tmp/flat
make_pkgroot "$flat" data-only
printf 'just text\n' >"$flat/README"
out=$("$tool" "$flat") || fail "a payload with no sonames must exit 0 (got $?): $out"
grep -Fq 'data-only: clean (no shipped sonames)' <<<"$out" ||
    fail "a soname-less payload must say so, got: $out"

# --- red: shipped soname with no provides entry -----------------------------
red=$tmp/red
make_pkgroot "$red" libbar
make_payload "$red/usr/lib" libbar.so.2
before_red=$(snapshot "$red")
set +e
out=$("$tool" "$red" 2>&1)
rc=$?
set -e
((rc == 1)) || fail "an undeclared soname must exit 1 (got $rc): $out"
grep -Fq "libbar: soname 'libbar.so.2' is not declared in provides — declare the bare stem 'libbar.so'" <<<"$out" ||
    fail "wrong or missing finding message, got: $out"

# --- green: presence is not form — the FULL soname also covers it -----------
full=$tmp/full
make_pkgroot "$full" libbaz 'libbaz.so.2'
make_payload "$full/usr/lib" libbaz.so.2
out=$("$tool" "$full") || fail "a full-soname provide must cover presence (got $?): $out"
grep -Fq 'libbaz: clean (1 soname(s))' <<<"$out" ||
    fail "form is the audit lint's rule, not this tool's; got: $out"

# --- red: a plain `libfoo` declaration covers NOTHING (the S9 shape) --------
# The declared name must be the bare stem (`libfoo.so`, pinned green above
# covering `libfoo.so.1`) or the full soname (pinned green just above); a
# bare `libfoo` is neither and must NOT cover `libfoo.so.1`.
bare=$tmp/bare
make_pkgroot "$bare" libbare 'libbare'
make_payload "$bare/usr/lib" libbare.so.1
set +e
out=$("$tool" "$bare" 2>&1)
rc=$?
set -e
((rc == 1)) || fail "a bare non-stem provide must not cover the soname (got $rc): $out"
grep -Fq "libbare: soname 'libbare.so.1' is not declared in provides — declare the bare stem 'libbare.so'" <<<"$out" ||
    fail "a bare non-stem provide changed the verdict, got: $out"

# --- archive input: same verdict, extraction stays under $TMPDIR ------------
mkdir -p "$tmp/dist"
tar -cf "$tmp/dist/libbar-1.0.0-1-x86_64.pkg.tar.zst" -C "$red" .
set +e
out=$("$tool" "$tmp/dist/libbar-1.0.0-1-x86_64.pkg.tar.zst" 2>&1)
rc=$?
set -e
((rc == 1)) || fail "archive input must reach the same verdict (got $rc): $out"
grep -Fq "libbar: soname 'libbar.so.2' is not declared in provides" <<<"$out" ||
    fail "archive input produced no finding, got: $out"

# --- decoy and inputs: never touched ---------------------------------------
decoy=$tmp/decoy
make_pkgroot "$decoy" decoy-pkg
make_payload "$decoy/usr/lib" decoy.so.9
before_decoy=$(snapshot "$decoy")
out=$("$tool" "$green" "$red" "$full" 2>&1) && fail "the red input among greens must still fail: $out"
[[ $(snapshot "$decoy") == "$before_decoy" ]] ||
    fail 'a package the tool was not pointed at was modified'
[[ $(snapshot "$red") == "$before_red" ]] ||
    fail 'an input package was modified — the tool is read-only on its inputs'

# --- usage -----------------------------------------------------------------
set +e
out=$("$tool" 2>&1)
rc=$?
set -e
((rc == 2)) || fail "no inputs is a usage error (got $rc): $out"
set +e
out=$("$tool" --nonsense "$green" 2>&1)
rc=$?
set -e
((rc == 2)) || fail "an unknown flag is a usage error (got $rc): $out"

printf 'provides-audit fixture: PASS (presence rule pinned at reduced scale)\n'
