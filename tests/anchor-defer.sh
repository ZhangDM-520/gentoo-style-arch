#!/usr/bin/env bash
set -euo pipefail

# One unanchorable recipe must park itself, not strangle the dispatch.
#
# Before 2026-09-24 the first anchoring refusal exited the lane non-zero, the
# dispatcher treated that as a failed build, set stop_starting and drained:
# measured on a full-roster whole-tree run, ONE recipe whose official
# .SRCINFO published no checksum for a moved source cost the other ~120
# packages their dispatch (two consecutive runs, "stopped dispatching, drained
# in-flight lanes"). Anchoring impossibility is not a failed build — it is a
# recipe that cannot be refreshed right now (no official document, network
# down, updpkgsums failed). The stance pinned here:
#
#   * a-stable (stable, official 404 → cannot anchor) is DEFERRED: named
#     marker in the summary, its log tail carries the named error AND both
#     recovery lines ('Refresh them by hand', '--no-sync'), makepkg never
#     ran for it, and the recipe is not counted as succeeded or failed;
#   * c-plain, independent of a-stable, still BUILDS — dispatch continues;
#   * b-dep (a topology edge b-dep → a-stable) is never dispatched: building
#     it against a package that was never built/installed this run is the
#     rule-11 hazard -i exists to prevent. It is labelled as waiting on the
#     deferred recipe, not as a dependency cycle;
#   * the run exits non-zero (parked work needs the owner), and the resume
#     command names BOTH unbuilt packages (tests/resume-command.sh pins the
#     command's flag shape; this fixture pins its honesty about parked work).
#
# All collaborators (pacman, curl, updpkgsums, makepkg) are PATH stubs; the
# run builds nothing real and touches no network.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-anchor-defer.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf 'anchor defer fixture: %s\n' "$1" >&2
    exit 1
}

command -v vercmp >/dev/null || {
    printf 'vercmp is required (it ships with pacman)\n' >&2
    exit 1
}

dir="$fixture/ws"
make_workspace "$dir" 1 2 low
mkdir -p "$dir/packages/stable/a-stable"

# a-stable: a stable recipe whose moved source gets NO official document (404)
# → anchor_sums_from_official refuses with rc 3, which the lane reports as the
# defer code. $pkgver must be literal: the builder expands source=() by
# sourcing the recipe. Its recipe path (packages/stable/) is not what
# add_package records, so its recipe and topology record stay inline.
{
    printf 'pkgname=a-stable\n'
    printf 'pkgver=1.0.0\n'
    printf 'pkgrel=1\n'
    printf 'arch=(any)\n'
    printf 'source=("https://example.invalid/a-$pkgver.tar.gz")\n'
    printf "sha256sums=('0000000000000000000000000000000000000000000000000000000000000000')\n"
} >"$dir/packages/stable/a-stable/PKGBUILD"
printf 'a-stable|packages/stable/a-stable|stable|\n' >>"$dir/config/topology.conf"

# b-dep / c-plain: ordinary recipes with working builds. b-dep's edge on
# a-stable is why a deferred a-stable parks it.
add_package "$dir" b-dep "$gsa_meta_any"
add_package "$dir" c-plain "$gsa_meta_any"
set_topology_record "$dir" b-dep git 'a-stable'

mkdir -p "$dir/fake"
printf '2.0.0-1\n' >"$dir/fake/repo_version"

cat >"$dir/bin/pacman" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == -Si ]]; then
    printf 'Repository      : extra\nName            : %s\nVersion         : %s\n' \
        "$2" "$(cat "$GSA_FAKE_DIR/repo_version")"
    exit 0
fi
exit 0
EOF
chmod +x "$dir/bin/pacman"

# Official packaging repo: 404 for everything → no anchor at our version.
cat >"$dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GSA_FAKE_DIR/curl_calls"
exit 22
EOF
chmod +x "$dir/bin/curl"

cat >"$dir/bin/updpkgsums" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >>"$GSA_FAKE_DIR/updpkgsums_calls"
exit 0
EOF
chmod +x "$dir/bin/updpkgsums"

cat >"$dir/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(basename "$PWD")
printf '%s\n' "$id" >>"$GSA_FAKE_DIR/makepkg_calls"
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
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
        --intensity low a-stable b-dep c-plain 2>&1
)
rc=$?
set -e
printf '%s' "$output" >"$dir/out.txt"

# 1. Parked work must keep the run non-zero — a silent green would hide it.
((rc != 0)) || fail "the run exited 0 although a recipe was parked:
$output"

# 2. a-stable is parked with a NAMED marker, not reported as a build failure.
#    The record row is the outcome DATA (deferred = the lane rc-99 anchoring
#    amendment, rc visible in the row); the DEFERRED marker itself is the
#    human label, pinned here because only this scenario renders it.
[[ $(rr_row a-stable status <<<"$output") == deferred ]] \
    || fail "a-stable row is not deferred:
$(rr_row a-stable <<<"$output")
$output"
[[ $(rr_row a-stable rc <<<"$output") == 99 ]] \
    || fail "a-stable row does not carry the rc-99 defer code:
$(rr_row a-stable <<<"$output")"
[[ $(rr_row a-stable reason <<<"$output") == anchoring-refused ]] \
    || fail "a-stable row reason is not anchoring-refused:
$(rr_row a-stable <<<"$output")"
grep -q 'DEFERRED' "$dir/out.txt" || fail "no DEFERRED marker for a-stable:
$output"
grep -q 'a-stable' "$dir/out.txt" || fail 'the DEFERRED marker does not name a-stable'
if grep -q 'a-stable: BUILD FAILED' "$dir/out.txt"; then
    fail "a deferral was reported as a build failure:
$output"
fi
[[ -f $dir/packages/stable/a-stable/PKGBUILD ]] || fail 'the parked recipe disappeared'

# 3. The parked recipe's summary carries the named error AND both recovery
#    lines (the deferred section tails the package log — that tail is the only
#    place a non-interactive owner can read why it parked).
grep -q 'refusing to build' "$dir/out.txt" \
    || fail "the deferred summary does not carry the named refusal:
$output"
grep -q 'Refresh them by hand' "$dir/out.txt" \
    || fail "the deferred summary lost the manual recovery line:
$output"
grep -q -- "'--no-sync' builds the committed version as-is" "$dir/out.txt" \
    || fail "the deferred summary lost the --no-sync escape:
$output"

# 4. makepkg never ran for the parked recipe…
if grep -qx 'a-stable' "$dir/fake/makepkg_calls" 2>/dev/null; then
    fail 'makepkg ran for the recipe that could not be anchored'
fi
# …but updpkgsums was never reached either: without an official document
# there is nothing to classify against, so the refusal precedes any write.
if [[ -s $dir/fake/updpkgsums_calls ]]; then
    fail 'updpkgsums ran although no official document could be fetched'
fi

# 5. THE POINT: the rest of the dispatch continued — c-plain built.
grep -qx 'c-plain' "$dir/fake/makepkg_calls" 2>/dev/null \
    || fail "c-plain was never built — one parked recipe still stopped the dispatch:
$output"
[[ -f $dir/packages/c-plain/c-plain-1.0.0-1-any.pkg.tar.zst ]] \
    || fail 'c-plain reports built but produced no archive'
[[ $(rr_row c-plain status <<<"$output") == succeeded ]] \
    || fail "c-plain row is not succeeded:
$(rr_row c-plain <<<"$output")"

# 6. b-dep depends on the parked recipe: never dispatched, honestly labelled —
#    waiting on a deferral is not a dependency cycle.
if grep -qx 'b-dep' "$dir/fake/makepkg_calls" 2>/dev/null; then
    fail 'b-dep built although its dependency a-stable was never built'
fi
[[ $(rr_row b-dep status <<<"$output") == blocked ]] \
    || fail "b-dep row is not blocked:
$(rr_row b-dep <<<"$output")"
[[ $(rr_row b-dep reason <<<"$output") == waits-on-deferred ]] \
    || fail "b-dep row reason is not waits-on-deferred:
$(rr_row b-dep <<<"$output")"
# The human label is scenario-bound rendering (the record says
# 'waits-on-deferred'; only this fixture renders the sentence).
grep -q 'waits on a deferred package' "$dir/out.txt" \
    || fail "b-dep's non-dispatch is not labelled as waiting on a deferred package:
$output"

# 7. The resume set is DATA: the record's non-succeeded rows, in row order —
#    the parked recipe and its blocked dependent, and ONLY those: a resume
#    must retry a-stable and b-dep, not re-run c-plain. The suggestion line
#    must carry that same set (one owner for what remains).
[[ $(rr_remaining <<<"$output" | tr '\n' ' ') == 'a-stable b-dep ' ]] \
    || fail "resume set must be exactly a-stable b-dep in row order, got:
$(rr_remaining <<<"$output" | tr '\n' ' ')
$output"
resume=$(grep '^  build-all.fish ' "$dir/out.txt" | head -1) || true
[[ -n $resume ]] || fail "no resume command in the failure summary:
$output"
[[ $resume == *' a-stable b-dep' ]] \
    || fail "resume command does not carry the run-record resume set [a-stable b-dep]: $resume"
[[ $resume == *--intensity* ]] || fail "resume command lost its flags: $resume"

(
# ─── A failed anchor scratch creation is a named refusal, never root-relative
# paths (R-F12) ─────────────────────────────────────────────────────────────
# `set -l tmp (mktemp -d)` was unchecked: on failure every derived path
# collapsed to the filesystem root ("/map", "/PKGBUILD.orig") and the root-mode
# failure path would have "restored" from /PKGBUILD.orig. The anchor now gates
# its scratch creation and derives every path from a verified directory.
dir="$fixture/mktemp-fail"
make_workspace "$dir" 1 2 low
mkdir -p "$dir/packages/stable/m1"
{
    printf 'pkgname=m1\n'
    printf 'pkgver=1.0.0\n'
    printf 'pkgrel=1\n'
    printf 'arch=(any)\n'
    printf 'source=("https://example.invalid/m-$pkgver.tar.gz")\n'
    printf "sha256sums=('0000000000000000000000000000000000000000000000000000000000000000')\n"
} >"$dir/packages/stable/m1/PKGBUILD"
printf 'm1|packages/stable/m1|stable|\n' >>"$dir/config/topology.conf"
mkdir -p "$dir/fake"
printf '2.0.0-1\n' >"$dir/fake/repo_version"
cat >"$dir/bin/pacman" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == -Si ]]; then
    printf 'Repository      : extra\nName            : %s\nVersion         : %s\n' \
        "$2" "$(cat "$GSA_FAKE_DIR/repo_version")"
    exit 0
fi
exit 0
EOF
chmod +x "$dir/bin/pacman"
cat >"$dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit 22
EOF
chmod +x "$dir/bin/curl"
cat >"$dir/bin/updpkgsums" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >>"$GSA_FAKE_DIR/updpkgsums_calls"
exit 0
EOF
chmod +x "$dir/bin/updpkgsums"
cat >"$dir/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(basename "$PWD")
printf '%s\n' "$id" >>"$GSA_FAKE_DIR/makepkg_calls"
exit 0
EOF
chmod +x "$dir/bin/makepkg"
# Only the ANCHOR's template fails — the version sync's own snapshot must
# still work, or the refusal would come from the wrong seam entirely.
cat >"$dir/bin/mktemp" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
    if [[ $a == *gsa-anchor-sums* && ${GSA_FAKE_MKTEMP_FAIL:-} == anchor ]]; then
        printf 'fake mktemp: requested failure\n' >&2
        exit 1
    fi
done
exec /usr/bin/mktemp "$@"
EOF
chmod +x "$dir/bin/mktemp"

set +e
output=$(
    PATH="$dir/bin:$PATH" \
    GSA_STATE_DIR="$dir/state" \
    GSA_FAKE_DIR="$dir/fake" \
    GSA_FAKE_MKTEMP_FAIL=anchor \
    GSA_CPU_THREADS=4 \
    GSA_MEMORY_GIB=8 \
    fish "$dir/build-all.fish" --allow-broken-rustc --no-deps \
        --intensity low m1 2>&1
)
rc=$?
set -e
printf '%s' "$output" >"$dir/out.txt"

((rc != 0)) || fail "mktemp-fail: the run succeeded although no checksum state could be held:
$output"
grep -q 'cannot create an isolated temporary directory' "$dir/state/logs/m1.log" \
    || fail "mktemp-fail: the scratch failure is not named in the log:
$(cat "$dir/state/logs/m1.log" 2>/dev/null)"
grep -q 'DEFERRED' "$dir/out.txt" \
    || fail "mktemp-fail: the unanchorable recipe was not parked:
$output"
[[ ! -s $dir/fake/makepkg_calls ]] \
    || fail 'mktemp-fail: makepkg ran although the sums were never anchored'
grep -q "^pkgver=2.0.0$" "$dir/packages/stable/m1/PKGBUILD" \
    || fail 'mktemp-fail: the version sync did not land — the case would test the wrong seam'
grep -q "^sha256sums=('0000000000000000000000000000000000000000000000000000000000000000')$" \
    "$dir/packages/stable/m1/PKGBUILD" \
    || fail 'mktemp-fail: the sums were rewritten although no anchor could be consulted'
)

(
# ─── A failed restore is its own named error, never a false claim (R-F21) ──
# The anchor's failure paths restored with an unchecked `cp` while the message
# asserted "the recipe was restored": a failed restore left the recipe
# rewritten behind a claim that never held. The restore is now checked and its
# failure is folded into the return status — a dirty recipe fails the run
# instead of parking quietly.
dir="$fixture/restore-fails"
make_workspace "$dir" 1 2 low
mkdir -p "$dir/packages/stable/r1"
{
    printf 'pkgname=r1\n'
    printf 'pkgver=1.0.0\n'
    printf 'pkgrel=1\n'
    printf 'arch=(any)\n'
    printf 'source=("https://example.invalid/r-$pkgver.tar.gz")\n'
    printf "sha256sums=('0000000000000000000000000000000000000000000000000000000000000000')\n"
} >"$dir/packages/stable/r1/PKGBUILD"
printf 'r1|packages/stable/r1|stable|\n' >>"$dir/config/topology.conf"
mkdir -p "$dir/fake"
printf '2.0.0-1\n' >"$dir/fake/repo_version"
cat >"$dir/bin/pacman" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == -Si ]]; then
    printf 'Repository      : extra\nName            : %s\nVersion         : %s\n' \
        "$2" "$(cat "$GSA_FAKE_DIR/repo_version")"
    exit 0
fi
exit 0
EOF
chmod +x "$dir/bin/pacman"
# The anchor must reach the updater step for this case: serve the official
# packaging .SRCINFO at the rewritten version, and 404 everything else.
cat >"$dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=
url=
while (($#)); do
    case $1 in
    -o) out=$2; shift 2 ;;
    --max-time) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
    esac
done
if [[ -n ${url:-} && $url == *'/packaging/packages/r1/-/raw/'* && -n $out ]]; then
    {
        printf 'pkgbase = r1\n'
        printf '\tpkgver = 2.0.0\n'
        printf '\tpkgrel = 1\n'
        printf 'source = https://example.invalid/r-2.0.0.tar.gz\n'
        printf 'sha256sums = 0000000000000000000000000000000000000000000000000000000000000000\n'
        printf 'pkgname = r1\n'
    } >"$out"
    exit 0
fi
exit 22
EOF
chmod +x "$dir/bin/curl"
# The updater makes the recipe directory unwritable before failing: the
# restore can then not write, which is exactly the unchecked path.
cat >"$dir/bin/updpkgsums" <<'EOF'
#!/usr/bin/env bash
printf 'called\n' >>"$GSA_FAKE_DIR/updpkgsums_calls"
chmod 555 "$PWD"
exit 1
EOF
chmod +x "$dir/bin/updpkgsums"
cat >"$dir/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -u
id=$(basename "$PWD")
printf '%s\n' "$id" >>"$GSA_FAKE_DIR/makepkg_calls"
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
        --intensity low r1 2>&1
)
rc=$?
set -e
printf '%s' "$output" >"$dir/out.txt"
chmod -R u+w "$dir/packages/stable/r1"     # asserts below must not need the mode

((rc != 0)) || fail "restore-fails: the run succeeded over a recipe left dirty:
$output"
grep -q 'could NOT be restored' "$dir/state/logs/r1.log" \
    || fail "restore-fails: the failed restore is not named in the log:
$(cat "$dir/state/logs/r1.log" 2>/dev/null)"
if grep -q 'the recipe was restored' "$dir/state/logs/r1.log"; then
    fail "restore-fails: the log claims a restore that never happened:
$(cat "$dir/state/logs/r1.log" 2>/dev/null)"
fi
if grep -q 'DEFERRED' "$dir/out.txt"; then
    fail "restore-fails: a dirty recipe was parked instead of failing the run:
$output"
fi
[[ ! -s $dir/fake/makepkg_calls ]] \
    || fail 'restore-fails: makepkg ran over a recipe left dirty'
)

printf 'anchor defer fixture: PASS (parked a-stable, waited b-dep, built c-plain)\n'
