#!/usr/bin/env bash
set -euo pipefail

# Every recipe ships a committed `.SRCINFO` next to its PKGBUILD. Three
# fixtures (logseq-desktop-recipe.sh, texlive-recipe.sh, bpftune-tuners-hook.sh)
# already assert that *their own* recipe's `.SRCINFO` matches, which leaves the
# other ~123 unchecked — and a stale `.SRCINFO` is a silent break: it pins the
# previous pkgver, provides, source URL and sha256sums, so anything consuming
# the recipe through it builds the wrong sources against the wrong sums.
#
# bettbox proved the gap: its PKGBUILD moved to 1.19.2 while `.SRCINFO` stayed
# at 1.19.1 with the previous tarball's hash. `makepkg --printsrcinfo` was
# simply never re-run when the version was bumped.
#
# The recipe list comes from the builder's --topology data channel (one
# record per package, id|path|groups|edges|tags), which resolves
# config/topology.conf — the only place that binds a package id to a recipe
# path — so a new recipe is covered without touching this file. Read-only:
# each recipe is generated into $TMPDIR and diffed, never written to.

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
# Concurrency: makepkg --printsrcinfo is cheap and pure, so the whole map is
# checked at once (one job per hardware thread; override with GSA_FAKE_SRCINFO_JOBS).
jobs=${GSA_FAKE_SRCINFO_JOBS:-$(nproc 2>/dev/null || echo 8)}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/gsa-srcinfo-fixture.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

# One recipe: print "<path>\t<reason>" when it is stale, nothing when it is not.
check_recipe() {
    local rel=$1 dir=$root/$1 out=$tmp/out.$$
    if [[ ! -f $dir/.SRCINFO ]]; then
        printf '%s\tno .SRCINFO committed\n' "$rel"
        return 0
    fi
    if ! makepkg_printsrcinfo "$dir" >"$out" 2>"$tmp/err.$$"; then
        printf '%s\tmakepkg --printsrcinfo failed: %s\n' "$rel" \
            "$(head -1 "$tmp/err.$$" 2>/dev/null)"
        rm -f -- "$out" "$tmp/err.$$"
        return 0
    fi
    if ! diff -q "$out" "$dir/.SRCINFO" >/dev/null; then
        printf '%s\tstale (pkgver/version-pinned fields differ)\n' "$rel"
    fi
    rm -f -- "$out" "$tmp/err.$$"
    return 0
}
export -f check_recipe
# check_recipe runs in `bash -c` workers, which only see exported functions.
export -f makepkg_printsrcinfo
export root tmp

mapfile -t recipes < <(fish "$root/build-all.fish" --topology 2>/dev/null |
    awk -F'|' '!/^#/ && NF == 5 {print $2}')
((${#recipes[@]} > 0)) || {
    printf 'srcinfo freshness fixture: the --topology channel listed no recipes\n' >&2
    exit 1
}

stale=$(printf '%s\n' "${recipes[@]}" |
    xargs -P "$jobs" -I{} bash -c 'check_recipe "$1"' _ {} |
    sort)

if [[ -n $stale ]]; then
    printf 'srcinfo freshness fixture: %d recipe(s) have a stale .SRCINFO\n' \
        "$(wc -l <<<"$stale")" >&2
    printf '%s\n' "$stale" >&2
    printf 'regenerate with: cd <recipe> && GIT_CONFIG_COUNT=0 makepkg --printsrcinfo > .SRCINFO\n' >&2
    exit 1
fi

(
# ─── A failed .SRCINFO refresh is surfaced twice, never silently dropped
# (R-F39) ──────────────────────────────────────────────────────────────────
# refresh_package_srcinfo used to end in a warning whose status every caller
# discarded, so a stale committed .SRCINFO stayed the truth later gates read
# while the run summary claimed a clean sync. The refresh now returns its own
# status and the failure surfaces twice: a named log line carrying the
# regeneration command, and the run-summary witness annotated with the gap.
# Static source on purpose: no checksum anchor runs, so the version rewrite
# alone is what invalidates the committed .SRCINFO.
fail() {
    printf '\nFAIL: %s\n' "$*" >&2
    exit 1
}
dir="$tmp/refresh-fail"
make_workspace "$dir" 1 2 low
mkdir -p "$dir/packages/stable/s1" "$dir/fake"
cat >"$dir/packages/stable/s1/PKGBUILD" <<'EOF'
pkgname=s1
pkgver=1.0.0
pkgrel=1
arch=(any)
source=("https://example.invalid/s1-static.tar.gz")
sha256sums=('0000000000000000000000000000000000000000000000000000000000000000')
EOF
printf 's1|packages/stable/s1|stable|\n' >>"$dir/config/topology.conf"
printf 'pkgbase = s1\n\tpkgver = 1.0.0\n\tpkgrel = 1\npkgname = s1\n' \
    >"$dir/packages/stable/s1/.SRCINFO"
cp -- "$dir/packages/stable/s1/.SRCINFO" "$dir/pre-SRCINFO"
cat >"$dir/bin/pacman" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == -Si ]]; then
    printf 'Repository      : extra\nName            : %s\nVersion         : 2.0.0-1\n' "$2"
    exit 0
fi
exit 0
EOF
chmod +x "$dir/bin/pacman"
# --printsrcinfo fails here and only here: the refresh is this case's seam,
# while the build itself succeeds on the rewritten version.
cat >"$dir/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$GSA_FAKE_DIR/makepkg_argv"
for a in "$@"; do
    if [[ $a == --printsrcinfo ]]; then
        exit 1
    fi
done
id=$(basename "$PWD")
: >"$PWD/$id-2.0.0-1-any.pkg.tar.zst"
printf 'fake makepkg %s\n' "$PWD"
exit 0
EOF
chmod +x "$dir/bin/makepkg"

set +e
output=$(
    PATH="$dir/bin:$PATH" \
    GSA_STATE_DIR="$dir/state" \
    GSA_FAKE_DIR="$dir/fake" \
    GSA_CPU_THREADS=4 \
    GSA_MEMORY_GIB=8 \
    fish "$dir/build-all.fish" --allow-broken-rustc --no-deps \
        --intensity low s1 2>&1
)
rc=$?
set -e
printf '%s' "$output" >"$dir/out.txt"

((rc == 0)) || fail "refresh-fail: the build did not proceed over a stale .SRCINFO:
$output"
grep -q "^pkgver=2.0.0$" "$dir/packages/stable/s1/PKGBUILD" \
    || fail 'refresh-fail: the version sync did not land — the case would test the wrong seam'
grep -q -- '--printsrcinfo' "$dir/fake/makepkg_argv" \
    || fail 'refresh-fail: the .SRCINFO refresh was never attempted — the case tested nothing'
grep -q 'could not be refreshed' "$dir/state/logs/s1.log" \
    || fail "refresh-fail: the failed refresh is not named in the log:
$(cat "$dir/state/logs/s1.log" 2>/dev/null)"
grep -Fq "regenerate it with 'makepkg --printsrcinfo" "$dir/state/logs/s1.log" \
    || fail 'refresh-fail: the log does not carry the regeneration command'
grep -q '(synced with repo) — the committed .SRCINFO could NOT be refreshed' \
    "$dir/out.txt" \
    || fail "refresh-fail: the run summary does not annotate the sync with the failed refresh:
$output"
cmp -s "$dir/pre-SRCINFO" "$dir/packages/stable/s1/.SRCINFO" \
    || fail 'refresh-fail: the committed .SRCINFO was replaced although the refresh failed'
if find "$dir/packages/stable/s1" -name '.SRCINFO.tmp*' -print -quit | grep -q .; then
    fail 'refresh-fail: a staged .SRCINFO scratch survived the failed refresh'
fi
)

printf 'srcinfo freshness fixture: PASS (%d recipes)\n' "${#recipes[@]}"
