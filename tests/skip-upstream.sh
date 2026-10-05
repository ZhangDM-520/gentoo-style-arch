#!/usr/bin/env bash
set -euo pipefail

# Regression fixture for upstream-aware -s. Every workspace and local remote is
# isolated under $TMPDIR; only the Git adapter is exercised end to end here.
source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-skip-upstream.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf 'skip-upstream: %s\n' "$*" >&2
    exit 1
}

git_fixture() {
    GIT_CONFIG_COUNT=0 git "$@"
}

init_git_remote() { # $1 = isolated root; creates remote.git and work/
    local root=$1 remote=$1/remote.git work=$1/work
    mkdir -p "$root"
    git_fixture init --bare --initial-branch=main "$remote" >/dev/null
    git_fixture init --initial-branch=main "$work" >/dev/null
    git_fixture -C "$work" config user.name 'Fixture User'
    git_fixture -C "$work" config user.email 'fixture@example.invalid'
    git_fixture -C "$work" config commit.gpgsign false
    git_fixture -C "$work" config core.hooksPath /dev/null
    printf 'first revision\n' >"$work/source.txt"
    git_fixture -C "$work" add source.txt
    git_fixture -C "$work" commit -m 'first revision' >/dev/null
    git_fixture -C "$work" remote add origin "$remote"
    git_fixture -C "$work" push --set-upstream origin main >/dev/null
}

advance_main() { # $1 = local worktree; $2 = commit message and file content;
    # $3 = commit count (default 1). A caller that expects a REBUILD must move
    # at least the freshness tolerance (5) commits: -s deliberately waives
    # moves below it (see the freshness-tolerance section).
    local work=$1 message=$2 count=${3:-1}
    local i
    for ((i = 1; i <= count; i++)); do
        printf '%s\n' "$message $i" >>"$work/source.txt"
        git_fixture -C "$work" add source.txt
        git_fixture -C "$work" commit -m "$message $i" >/dev/null
    done
    git_fixture -C "$work" push origin main >/dev/null
}

mk_fake_archive() { # $1 = archive path; $2 = optional payload text
    # A REAL (if tiny) zstd tarball: the -s payload probe reads archives the
    # way pacman does, so "an archive exists" must model a readable one — a
    # zero-byte file models exactly the interrupted write this seam rejects.
    if [[ -n ${2:-} ]]; then
        local stage=$fixture/.mk-archive.$$
        mkdir -p "$stage"
        printf '%s\n' "$2" >"$stage/payload"
        tar --zstd -cf "$1" -C "$stage" payload
        rm -rf "$stage"
    else
        tar --zstd -cf "$1" --files-from /dev/null
    fi
}

make_vcs_workspace() { # $1 workspace; $2 remote path; $3 branch|tag; $4 ref;
    # $5 entry style: override (default — 'upstream::url') or basename (no
    #    override, URL basename carries .git — the xdg-utils shape). The
    #    checkout layout is not baked here: the fake makepkg decides it at
    #    run time from the stub variable GSA_FAKE_VCS_LAYOUT (root = clone
    #    beside the PKGBUILD, the layout this fixture used before 2026-10-02;
    #    srcdir = clone under $PWD/src/<name>, where real makepkg's
    #    extract_git puts the working copy), passed per run_case call like
    #    the other GSA_FAKE_* stub variables.
    local dir=$1 remote=$2 kind=$3 ref=$4
    local style=${5:-override}
    case $style in
    override | basename) ;;
    *) fail "make_vcs_workspace: unknown entry style '$style'" ;;
    esac
    local source
    if [[ $style == basename ]]; then
        source="git+file://$remote"
    else
        source="upstream::git+file://$remote"
    fi
    [[ $kind == default ]] || source+="#$kind=$ref"
    local extra="$gsa_meta_any"$'\n'"source=(\"$source\")"$'\n'"sha256sums=('SKIP')"
    make_workspace "$dir" 1 2 low
    add_package "$dir" p1 "$extra"
    # Keep the archive-mtime condition deterministic on the first build.
    touch -d '2000-01-01 00:00:00 UTC' "$dir/packages/p1/PKGBUILD"

    cat >"$dir/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -eu

git_config0() {
    GIT_CONFIG_COUNT=0 git "$@"
}

id=$(basename "$PWD")
printf '%s\n' "$id" >>"${GSA_FAKE_MAKEPKG_COUNT:?}"
source "$PWD/PKGBUILD"
entry=${source[0]:-}
case $entry in
*git+file://*) ;;
*)
    printf 'fake makepkg: expected a local Git source, got %s\n' "$entry" >&2
    exit 1
    ;;
esac

name_override=
raw=$entry
if [[ $entry == *::* ]]; then
    name_override=${entry%%::*}
    raw=${entry#*::}
fi
url=${raw#git+}
remote=${url%%#*}
if [[ $url == *#* ]]; then
    selector=${url#*#}
else
    selector=default
fi
case $remote in
file://*) ;;
*)
    printf 'fake makepkg: refusing non-local remote %s\n' "$remote" >&2
    exit 1
    ;;
esac

if [[ ${GSA_FAKE_EXPECT_CLEAN:-0} == 1 &&
    -e "$PWD/$id-1.0.0-1-any.pkg.tar.zst.gsa-vcs-revisions" ]]; then
    printf 'fake makepkg: clean left a stale VCS revision record\n' >&2
    exit 1
fi

# Where the working copy lands: the name makepkg would derive (the name::
# override verbatim, else the URL basename with .git stripped) under the
# selected layout. GSA_FAKE_VCS_LAYOUT is fixture-side only, like the rest of
# the GSA_FAKE_* stub variables.
if [[ -n $name_override ]]; then
    checkout_name=$name_override
else
    checkout_name=${remote##*/}
    checkout_name=${checkout_name%.git}
fi
checkout=$PWD/$checkout_name
if [[ ${GSA_FAKE_VCS_LAYOUT:-root} == srcdir ]]; then
    checkout=$PWD/src/$checkout_name
fi
mkdir -p "${checkout%/*}"
if [[ ! -d "$checkout/.git" ]]; then
    git_config0 clone --quiet --no-checkout "$remote" "$checkout"
fi

case $selector in
default)
    git_config0 -C "$checkout" remote set-head origin --auto >/dev/null
    default_ref=$(git_config0 -C "$checkout" symbolic-ref --short refs/remotes/origin/HEAD)
    default_ref=${default_ref#origin/}
    git_config0 -C "$checkout" fetch --quiet --no-tags origin \
        "$default_ref:refs/remotes/origin/$default_ref"
    git_config0 -C "$checkout" checkout --quiet -B "$default_ref" "refs/remotes/origin/$default_ref"
    ;;
branch=*)
    ref=${selector#branch=}
    git_config0 -C "$checkout" fetch --quiet --no-tags origin \
        "refs/heads/$ref:refs/remotes/origin/$ref"
    git_config0 -C "$checkout" checkout --quiet -B "$ref" "refs/remotes/origin/$ref"
    ;;
tag=*)
    ref=${selector#tag=}
    git_config0 -C "$checkout" fetch --quiet --no-tags origin \
        "+refs/tags/$ref:refs/tags/$ref"
    git_config0 -C "$checkout" checkout --quiet --detach "refs/tags/$ref"
    ;;
*)
    printf 'fake makepkg: unsupported selected Git ref %s\n' "$selector" >&2
    exit 1
    ;;
esac

tar --zstd -cf "$PWD/$id-1.0.0-1-any.pkg.tar.zst" --files-from /dev/null
EOF
    chmod +x "$dir/bin/makepkg"
    stub_sudo "$dir"
    cat >"$dir/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'pacman %s\n' "$*" >>"${GSA_FAKE_PACMAN_LOG:?}"
case ${1:-} in
-Qp)
    # Model pacman's own archive validation: it decompresses the whole zstd
    # stream before answering, so a write killed at ANY offset fails this
    # probe exactly as it fails real pacman.
    file=
    for arg in "$@"; do file=$arg; done
    [[ -n $file ]] || exit 1
    tar --zstd -t -f "$file" >/dev/null 2>&1
    exit $?
    ;;
-Qi) exit 1 ;;
esac
exit 0
EOF
    chmod +x "$dir/bin/pacman"
}

run_case() { # $1 = workspace; remaining args = builder selection/flags
    local dir=$1
    shift
    # Hermetic SRCDEST: the recorder probes the builder's exported SRCDEST, so
    # the host's real source cache must never leak into a fixture decision.
    mkdir -p "$dir/makepkg-srcdest"
    run_builder env \
        PATH="$dir/bin:$PATH" \
        GIT_CONFIG_COUNT=0 \
        SRCDEST="$dir/makepkg-srcdest" \
        GSA_FAKE_VCS_LAYOUT="${GSA_FAKE_VCS_LAYOUT:-root}" \
        GSA_STATE_DIR="$dir/state" \
        GSA_FAKE_MAKEPKG_COUNT="$dir/makepkg.count" \
        GSA_FAKE_PACMAN_LOG="$dir/pacman.log" \
        GSA_FAKE_EXPECT_CLEAN="${GSA_FAKE_EXPECT_CLEAN:-0}" \
        GSA_FAKE_VCS_REMOTE_REV="${GSA_FAKE_VCS_REMOTE_REV:-}" \
        GSA_FAKE_VCS_BUILT_REV="${GSA_FAKE_VCS_BUILT_REV:-}" \
        GSA_CPU_THREADS=8 \
        GSA_MEMORY_GIB=16 \
        fish_function_path=/nonexistent-fp \
        fish "$dir/build-all.fish" \
        --allow-broken-rustc --no-deps --no-sync "$@"
}

make_non_git_workspace() { # $1 = workspace; $2 = svn|hg|bzr; $3 = optional fragment
    local dir=$1 protocol=$2 fragment=${3:-}
    local source="upstream::${protocol}+https://example.invalid/repo"
    [[ -n $fragment ]] && source+="#$fragment"
    local extra="$gsa_meta_any"$'\n'"source=(\"$source\")"$'\n'"sha256sums=('SKIP')"
    make_workspace "$dir" 1 2 low
    add_package "$dir" p1 "$extra"
    touch -d '2000-01-01 00:00:00 UTC' "$dir/packages/p1/PKGBUILD"

    cat >"$dir/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -eu
id=$(basename "$PWD")
printf '%s\n' "$id" >>"${GSA_FAKE_MAKEPKG_COUNT:?}"
mkdir -p "$PWD/upstream"
tar --zstd -cf "$PWD/$id-1.0.0-1-any.pkg.tar.zst" --files-from /dev/null
EOF
    chmod +x "$dir/bin/makepkg"

    cat >"$dir/bin/svn" <<'EOF'
#!/usr/bin/env bash
set -u
target=
for arg in "$@"; do target=$arg; done
if [[ $target == *://* ]]; then
    [[ " $* " == *' --revision HEAD '* ]] || exit 31
    printf '%s\n' "${GSA_FAKE_VCS_REMOTE_REV:?}"
else
    [[ " $* " == *' info --show-item revision '* ]] || exit 32
    printf '%s\n' "${GSA_FAKE_VCS_BUILT_REV:?}"
fi
EOF
    cat >"$dir/bin/hg" <<'EOF'
#!/usr/bin/env bash
set -u
target=
for arg in "$@"; do target=$arg; done
if [[ $target == *://* ]]; then
    [[ " $* " == *' --rev default '* ]] || exit 33
    printf '%s\n' "${GSA_FAKE_VCS_REMOTE_REV:?}"
else
    [[ " $* " == *' log -r . --template {node} '* ]] || exit 34
    printf '%s\n' "${GSA_FAKE_VCS_BUILT_REV:?}"
fi
EOF
    cat >"$dir/bin/bzr" <<'EOF'
#!/usr/bin/env bash
set -u
target=
for arg in "$@"; do target=$arg; done
if [[ $target == *://* ]]; then
    [[ " $* " == *' version-info --custom --template={revision_id} '* ]] || exit 35
    printf '%s\n' "${GSA_FAKE_VCS_REMOTE_REV:?}"
else
    [[ " $* " == *' version-info --custom --template={revision_id} '* ]] || exit 36
    printf '%s\n' "${GSA_FAKE_VCS_BUILT_REV:?}"
fi
EOF
    chmod +x "$dir/bin/svn" "$dir/bin/hg" "$dir/bin/bzr"
    stub_sudo "$dir"
    cat >"$dir/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'pacman %s\n' "$*" >>"${GSA_FAKE_PACMAN_LOG:?}"
case ${1:-} in
-Qp)
    # Model pacman's own archive validation: it decompresses the whole zstd
    # stream before answering, so a write killed at ANY offset fails this
    # probe exactly as it fails real pacman.
    file=
    for arg in "$@"; do file=$arg; done
    [[ -n $file ]] || exit 1
    tar --zstd -t -f "$file" >/dev/null 2>&1
    exit $?
    ;;
-Qi) exit 1 ;;
esac
exit 0
EOF
    chmod +x "$dir/bin/pacman"
}

expect_success() { # $1 = case label
    if ((FIXTURE_RC != 0)); then
        fail "$1 failed (rc=$FIXTURE_RC):"$'\n'"$FIXTURE_OUTPUT"
    fi
}

makepkg_count() { # $1 = workspace
    local count_file=$1/makepkg.count
    if [[ -f $count_file ]]; then
        awk 'END { print NR }' "$count_file"
    else
        printf '0\n'
    fi
}

assert_makepkg_count() { # $1 = workspace; $2 = expected; $3 = label
    local got
    got=$(makepkg_count "$1")
    [[ $got == "$2" ]] || fail "$3: makepkg ran $got times, expected $2"
}

diagnostics_with_logs() { # $1 = workspace — the captured run output plus every
    # package log: the lane's stdout IS its log, so decision lines a quiet
    # lane printed live there (the idiom expect_unverifiable_defer uses).
    printf '%s\n' "$FIXTURE_OUTPUT"
    if [[ -d $1/state/logs ]]; then
        find "$1/state/logs" -maxdepth 1 -type f -exec cat {} + 2>/dev/null || true
    fi
}

expect_unverifiable_defer() { # $1 = workspace; $2 = prior makepkg count; $3 = label; $4 = diagnostic regex
    local dir=$1 want_count=$2 label=$3 words=$4 diagnostics=$FIXTURE_OUTPUT
    if ((FIXTURE_RC == 0)); then
        fail "$label unexpectedly succeeded (a parked run is not green):"$'\n'"$FIXTURE_OUTPUT"
    fi
    assert_makepkg_count "$dir" "$want_count" "$label (a parked recipe must not run makepkg)"
    grep -Eq '^p1 deferred 99 [0-9]+ upstream-unverified$' <<<"$FIXTURE_OUTPUT" ||
        fail "$label row is not 'deferred 99 … upstream-unverified':"$'\n'"$FIXTURE_OUTPUT"
    if [[ -d $dir/state/logs ]]; then
        diagnostics+=$'\n'"$(find "$dir/state/logs" -maxdepth 1 -type f -exec cat {} + 2>/dev/null || true)"
    fi
    if ! grep -Fq 'p1' <<<"$diagnostics" || ! grep -Eiq "$words" <<<"$diagnostics"; then
        fail "$label did not report a package-specific VCS freshness warning:"$'\n'"$diagnostics"
    fi
}

# A single branch-following recipe pins unchanged-ref skips, -s -i install
# behavior, selected-ref advancement, and the original PKGBUILD-mtime check.
branch_dir=$fixture/branch
init_git_remote "$branch_dir/repository"
branch_remote=$branch_dir/repository/remote.git
branch_work=$branch_dir/repository/work
make_vcs_workspace "$branch_dir/workspace" "$branch_remote" branch main
skip_help=$(fish "$branch_dir/workspace/build-all.fish" --help 2>/dev/null) ||
    fail 'builder help command failed'
grep -Fq -- 'an unusable baseline rebuilds' <<<"$skip_help" ||
    fail 'builder help does not describe legacy VCS baseline recovery'

run_case "$branch_dir/workspace" p1
expect_success 'initial branch build'
assert_makepkg_count "$branch_dir/workspace" 1 'initial branch build'

run_case "$branch_dir/workspace" -s p1
expect_success 'unchanged selected branch'
assert_makepkg_count "$branch_dir/workspace" 1 'unchanged selected branch'

# This is a real skip, not a build followed by an install: pacman must still
# install the existing archive while makepkg's invocation count stays fixed.
run_case "$branch_dir/workspace" -s -i p1
expect_success 'unchanged branch with install'
assert_makepkg_count "$branch_dir/workspace" 1 'unchanged branch with install'
grep -q -- 'pacman -U' "$branch_dir/workspace/pacman.log" ||
    fail 'unchanged branch -s -i did not install the skipped archive'
grep -- 'pacman -U' "$branch_dir/workspace/pacman.log" | grep -Fq 'p1-1.0.0-1-any.pkg.tar.zst' ||
    fail 'unchanged branch -s -i installed without the existing archive'

# The rebuild trigger below must clear the freshness tolerance (-s waives
# moves of fewer than 5 commits by design); the case still pins "a moved
# selected ref rebuilds".
advance_main "$branch_work" 'advanced selected branch' 5
run_case "$branch_dir/workspace" -s p1
expect_success 'advanced selected branch'
assert_makepkg_count "$branch_dir/workspace" 2 'advanced selected branch'

touch -d '+1 day' "$branch_dir/workspace/packages/p1/PKGBUILD"
run_case "$branch_dir/workspace" -s p1
expect_success 'newer PKGBUILD mtime'
assert_makepkg_count "$branch_dir/workspace" 3 'newer PKGBUILD mtime'

# A fresh legacy archive cannot be trusted without a recorded build revision.
# Rebuild once after confirming the selected refs are reachable, then skip it
# normally on later runs.
missing_dir=$fixture/missing-baseline
init_git_remote "$missing_dir/repository"
missing_remote=$missing_dir/repository/remote.git
make_vcs_workspace "$missing_dir/workspace" "$missing_remote" branch main
archive=$missing_dir/workspace/packages/p1/p1-1.0.0-1-any.pkg.tar.zst
mk_fake_archive "$archive"
run_case "$missing_dir/workspace" -s p1
expect_success 'legacy archive rebuilds once to record its baseline'
assert_makepkg_count "$missing_dir/workspace" 1 'legacy archive rebuild'
[[ -f $archive.gsa-vcs-revisions ]] ||
    fail 'legacy archive rebuild did not record its VCS baseline'
run_case "$missing_dir/workspace" -s p1
expect_success 'legacy archive skips after recording its baseline'
assert_makepkg_count "$missing_dir/workspace" 1 'legacy archive subsequent skip'
printf 'malformed VCS baseline\n' >"$archive.gsa-vcs-revisions"
run_case "$missing_dir/workspace" -s p1
expect_success 'malformed legacy baseline triggers a rebuild'
assert_makepkg_count "$missing_dir/workspace" 2 'malformed legacy baseline rebuild'
grep -Fq $'gsa-vcs-revisions\t2' "$archive.gsa-vcs-revisions" ||
    fail 'malformed legacy baseline was not replaced after rebuilding'

# A missing baseline does not license a skip or a build when upstream cannot
# be queried; the refusal must happen before makepkg.
legacy_offline_dir=$fixture/missing-baseline-offline
init_git_remote "$legacy_offline_dir/repository"
legacy_offline_remote=$legacy_offline_dir/repository/remote.git
make_vcs_workspace "$legacy_offline_dir/workspace" "$legacy_offline_remote" branch main
mk_fake_archive "$legacy_offline_dir/workspace/packages/p1/p1-1.0.0-1-any.pkg.tar.zst"
mv "$legacy_offline_remote" "$legacy_offline_dir/repository/remote.offline"
run_case "$legacy_offline_dir/workspace" -s p1
expect_unverifiable_defer "$legacy_offline_dir/workspace" 0 \
    'unreachable legacy upstream' 'cannot query|upstream|remote'

# A previously recorded baseline cannot license a skip when the selected
# remote ref is no longer queryable; with no consumers to break, the recipe
# parks (deferred) — never fails the run, never skips.
unreachable_dir=$fixture/unreachable
init_git_remote "$unreachable_dir/repository"
make_vcs_workspace "$unreachable_dir/workspace" "$unreachable_dir/repository/remote.git" branch main
run_case "$unreachable_dir/workspace" p1
expect_success 'initial reachable build'
assert_makepkg_count "$unreachable_dir/workspace" 1 'initial reachable build'
mv "$unreachable_dir/repository/remote.git" "$unreachable_dir/repository/remote.offline"
run_case "$unreachable_dir/workspace" -s p1
expect_unverifiable_defer "$unreachable_dir/workspace" 1 'unreachable upstream' 'remote|revision|upstream|baseline'

# ─── Transport failures: classify, retry, DEFER — never fail the run ────────
# 2026-10-02 defect: a momentary git ls-remote transport error (TLS flake,
# NOT a moved ref) made rc 2 fail the package, and fail-fast stopped dispatch
# — one unreachable upstream aborted a 147-package run (131 never-started).
# These cases pin the replacement contract:
#   * a transient failure is retried and, once answered, the normal skip /
#     moved-ref decisions apply unchanged;
#   * a persistent failure PARKS the recipe when its consumer chain can
#     absorb the wait (no or few waiters — owner 2026-10-02): deferred with
#     reason upstream-unverified, dependents honestly held, run continues;
#   * a heavy or unresolvable consumer chain falls back to a NORMAL BUILD
#     attempt: the recipe builds (or fails on its own merits) and installs
#     under -i — never silently skips, never parks what others need.
install_lsremote_stub() { # $1 workspace — $1/lsremote.mode = off|once|always
    local dir=$1 real_git
    real_git=$(command -v git)
    cat >"$dir/bin/git" <<EOF
#!/usr/bin/env bash
set -u
if [[ " \$* " == *" ls-remote "* ]]; then
    count=\$(cat "$dir/lsremote.count" 2>/dev/null || echo 0)
    count=\$((count + 1))
    printf '%s\n' "\$count" >"$dir/lsremote.count"
    mode=\$(cat "$dir/lsremote.mode" 2>/dev/null || echo off)
    if [[ \$mode == always ]] || { [[ \$mode == once ]] && [[ \$count -eq 1 ]]; }; then
        printf 'fatal: unable to access: TLS handshake failure (fixture)\n' >&2
        exit 128
    fi
fi
exec "$real_git" "\$@"
EOF
    chmod +x "$dir/bin/git"
}

lsremote_attempts() { # $1 workspace
    cat "$1/lsremote.count" 2>/dev/null || printf '0\n'
}

# T1: one transport failure, then the upstream answers an UNCHANGED ref —
# the retry must restore a normal -s -i skip (install included), not a
# deferral or a rebuild.
flaky_dir=$fixture/flaky-skip
init_git_remote "$flaky_dir/repository"
make_vcs_workspace "$flaky_dir/workspace" "$flaky_dir/repository/remote.git" branch main
install_lsremote_stub "$flaky_dir/workspace"
run_case "$flaky_dir/workspace" p1
expect_success 'flaky initial build'
assert_makepkg_count "$flaky_dir/workspace" 1 'flaky initial build'
printf 'once' >"$flaky_dir/workspace/lsremote.mode"
run_case "$flaky_dir/workspace" -s -i p1
expect_success 'flaky transport recovers into a normal skip'
assert_makepkg_count "$flaky_dir/workspace" 1 'flaky transport skip must not rebuild'
attempts=$(lsremote_attempts "$flaky_dir/workspace")
((attempts >= 2)) ||
    fail "flaky transport: expected a retry, saw $attempts ls-remote attempt(s)"
grep -q -- 'pacman -U' "$flaky_dir/workspace/pacman.log" ||
    fail 'flaky transport skip did not install the skipped archive'
grep -- 'pacman -U' "$flaky_dir/workspace/pacman.log" | grep -Fq 'p1-1.0.0-1-any.pkg.tar.zst' ||
    fail 'flaky transport skip installed without the existing archive'

# T2: one transport failure, then the upstream answers a MOVED ref — the
# retry must surface the move (rebuild), never mask it as skip.
moved_dir=$fixture/flaky-moved
init_git_remote "$moved_dir/repository"
moved_work=$moved_dir/repository/work
make_vcs_workspace "$moved_dir/workspace" "$moved_dir/repository/remote.git" branch main
install_lsremote_stub "$moved_dir/workspace"
run_case "$moved_dir/workspace" p1
expect_success 'flaky-moved initial build'
assert_makepkg_count "$moved_dir/workspace" 1 'flaky-moved initial build'
# The move clears the freshness tolerance (5 commits): a waivable move would
# skip BY DESIGN, so it cannot pin "the retry surfaces the move as a rebuild".
advance_main "$moved_work" 'advanced while transport was flaky' 5
printf 'once' >"$moved_dir/workspace/lsremote.mode"
run_case "$moved_dir/workspace" -s p1
expect_success 'flaky transport still detects a moved ref'
assert_makepkg_count "$moved_dir/workspace" 2 'moved ref after a flaky attempt must rebuild, not skip'
attempts=$(lsremote_attempts "$moved_dir/workspace")
((attempts >= 2)) ||
    fail "flaky-moved: expected a retry, saw $attempts ls-remote attempt(s)"

# T3: the upstream NEVER answers and p1's only consumer (p2) can wait —
# p1 must park (defer, not fail, not skip), its dependent p2 must hold
# with it, and p3 must keep building: the defect's whole point was that
# one unqueryable upstream stopped the other 146 packages. `-i` is
# deliberate: the parked package must never reach pacman either.
defer_dir=$fixture/defer-dispatch
init_git_remote "$defer_dir/repository"
make_vcs_workspace "$defer_dir/workspace" "$defer_dir/repository/remote.git" branch main
add_package "$defer_dir/workspace" p2 "$gsa_meta_any"
set_topology_record "$defer_dir/workspace" p2 git 'p1'
add_package "$defer_dir/workspace" p3 "$gsa_meta_any"
# The workspace stub only understands the VCS shape; route plain packages
# (p2/p3) to a trivial archive writer and keep the original for p1.
mv "$defer_dir/workspace/bin/makepkg" "$defer_dir/workspace/bin/makepkg.vcs"
cat >"$defer_dir/workspace/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -eu
if grep -q 'git+file://' "$PWD/PKGBUILD" 2>/dev/null; then
    exec "$(dirname "$0")/makepkg.vcs" "$@"
fi
id=$(basename "$PWD")
printf '%s\n' "$id" >>"${GSA_FAKE_MAKEPKG_COUNT:?}"
tar --zstd -cf "$PWD/$id-1.0.0-1-any.pkg.tar.zst" --files-from /dev/null
EOF
chmod +x "$defer_dir/workspace/bin/makepkg"
install_lsremote_stub "$defer_dir/workspace"
run_case "$defer_dir/workspace" p1
expect_success 'defer-dispatch initial build'
assert_makepkg_count "$defer_dir/workspace" 1 'defer-dispatch initial build'
printf 'always' >"$defer_dir/workspace/lsremote.mode"
run_case "$defer_dir/workspace" -s -i p1 p2 p3
if ((FIXTURE_RC == 0)); then
    fail "persistent transport failure reported a green run:"$'\n'"$FIXTURE_OUTPUT"
fi
attempts=$(lsremote_attempts "$defer_dir/workspace")
((attempts >= 3)) ||
    fail "persistent transport: expected the full retry window, saw $attempts attempt(s)"
# p1: parked with the machine-checkable reason — not failed, not skipped.
grep -Eq '^p1 deferred 99 [0-9]+ upstream-unverified$' <<<"$FIXTURE_OUTPUT" ||
    fail "p1 row is not 'deferred 99 … upstream-unverified':"$'\n'"$FIXTURE_OUTPUT"
if grep -Eq '^p1 (succeeded|failed) ' <<<"$FIXTURE_OUTPUT"; then
    fail "p1 was recorded as a build outcome instead of deferred:"$'\n'"$FIXTURE_OUTPUT"
fi
grep -Fq 'cannot verify upstream VCS freshness' "$defer_dir/workspace/state/logs/p1.log" ||
    fail "p1's log lost the freshness warning:"$'\n'"$(cat "$defer_dir/workspace/state/logs/p1.log" 2>/dev/null)"
grep -Fq 'parking this recipe' "$defer_dir/workspace/state/logs/p1.log" ||
    fail "p1's log does not name the parking decision:"$'\n'"$(cat "$defer_dir/workspace/state/logs/p1.log" 2>/dev/null)"
# p3 kept building — dispatch continued around the parked recipe.
grep -Eq '^p3 succeeded 0 [0-9]+ ok$' <<<"$FIXTURE_OUTPUT" ||
    fail "p3 did not build while p1 was deferred:"$'\n'"$FIXTURE_OUTPUT"
# p2 depends on p1: held, honestly labelled — never dispatched.
grep -Eq '^p2 blocked - - waits-on-deferred$' <<<"$FIXTURE_OUTPUT" ||
    fail "p2 is not 'blocked … waits-on-deferred':"$'\n'"$FIXTURE_OUTPUT"
assert_makepkg_count "$defer_dir/workspace" 2 'only p3 may build while p1 is deferred'
[[ $(grep -c '^p1$' "$defer_dir/workspace/makepkg.count") == 1 ]] ||
    fail 'p1 built again despite its unverifiable upstream'
if grep -q '^p2$' "$defer_dir/workspace/makepkg.count" 2>/dev/null; then
    fail 'p2 was dispatched although its dependency p1 is parked'
fi
if grep -- 'pacman -U' "$defer_dir/workspace/pacman.log" 2>/dev/null |
    grep -F 'p1-1.0.0-1-any.pkg.tar.zst'; then
    fail 'p1 archive was installed although upstream never answered'
fi
grep -- 'pacman -U' "$defer_dir/workspace/pacman.log" | grep -Fq 'p3-1.0.0-1-any.pkg.tar.zst' ||
    fail 'p3 did not install under -i while p1 was parked'

# T4: a heavily-consumed recipe cannot park — the fallback is a normal build
# attempt (owner semantics 2026-10-02): with a big consumer chain, an
# unverifiable upstream must NOT strand the packages that need it.
heavy_dir=$fixture/heavy-consumers
init_git_remote "$heavy_dir/repository"
make_vcs_workspace "$heavy_dir/workspace" "$heavy_dir/repository/remote.git" branch main
for id in p2 p3 p4 p5 p6; do
    add_package "$heavy_dir/workspace" "$id" "$gsa_meta_any"
    set_topology_record "$heavy_dir/workspace" "$id" git 'p1'
done
# Same split as T3: VCS-shaped p1 keeps the VCS stub, the plain consumers
# go to the trivial archive writer.
mv "$heavy_dir/workspace/bin/makepkg" "$heavy_dir/workspace/bin/makepkg.vcs"
cat >"$heavy_dir/workspace/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -eu
if grep -q 'git+file://' "$PWD/PKGBUILD" 2>/dev/null; then
    exec "$(dirname "$0")/makepkg.vcs" "$@"
fi
id=$(basename "$PWD")
printf '%s\n' "$id" >>"${GSA_FAKE_MAKEPKG_COUNT:?}"
tar --zstd -cf "$PWD/$id-1.0.0-1-any.pkg.tar.zst" --files-from /dev/null
EOF
chmod +x "$heavy_dir/workspace/bin/makepkg"
install_lsremote_stub "$heavy_dir/workspace"
run_case "$heavy_dir/workspace" p1
expect_success 'heavy-consumers initial build'
assert_makepkg_count "$heavy_dir/workspace" 1 'heavy-consumers initial build'
printf 'always' >"$heavy_dir/workspace/lsremote.mode"
run_case "$heavy_dir/workspace" -s -i p1 p2 p3 p4 p5 p6
expect_success 'persistent failure on a heavily-consumed recipe falls back to building'
grep -Eq '^p1 succeeded 0 [0-9]+ ok$' <<<"$FIXTURE_OUTPUT" ||
    fail "p1 did not fall back to a build:"$'\n'"$FIXTURE_OUTPUT"
grep -Fq 'cannot verify upstream VCS freshness' "$heavy_dir/workspace/state/logs/p1.log" ||
    fail "heavy p1's log lost the freshness warning:"$'\n'"$(cat "$heavy_dir/workspace/state/logs/p1.log" 2>/dev/null)"
grep -Fq 'consumers cannot wait' "$heavy_dir/workspace/state/logs/p1.log" ||
    fail "heavy p1's log does not name the fallback decision:"$'\n'"$(cat "$heavy_dir/workspace/state/logs/p1.log" 2>/dev/null)"
for id in p2 p3 p4 p5 p6; do
    grep -Eq "^$id succeeded 0 [0-9]+ ok$" <<<"$FIXTURE_OUTPUT" ||
        fail "$id did not build behind the fallback:"$'\n'"$FIXTURE_OUTPUT"
done
assert_makepkg_count "$heavy_dir/workspace" 7 'fallback build plus all five consumers'
grep -- 'pacman -U' "$heavy_dir/workspace/pacman.log" | grep -Fq 'p1-1.0.0-1-any.pkg.tar.zst' ||
    fail 'the fallback-built p1 archive did not install under -i'

# A tag-pinned source follows the declared tag, not HEAD or unrelated branches.
pinned_dir=$fixture/pinned
init_git_remote "$pinned_dir/repository"
pinned_remote=$pinned_dir/repository/remote.git
pinned_work=$pinned_dir/repository/work
git_fixture -C "$pinned_work" tag -a v1.0.0 -m 'fixture release tag'
git_fixture -C "$pinned_work" push origin refs/tags/v1.0.0 >/dev/null
make_vcs_workspace "$pinned_dir/workspace" "$pinned_remote" tag v1.0.0
run_case "$pinned_dir/workspace" p1
expect_success 'initial tag-pinned build'
assert_makepkg_count "$pinned_dir/workspace" 1 'initial tag-pinned build'
advance_main "$pinned_work" 'unrelated main branch movement'
run_case "$pinned_dir/workspace" -s p1
expect_success 'unrelated branch movement for pinned source'
assert_makepkg_count "$pinned_dir/workspace" 1 'unrelated branch movement for pinned source'
# A moved pin is a Git advance like any other: the re-tag below lands 6
# commits past the recorded baseline — past the freshness tolerance — so the
# rebuild must happen (a waivable move would skip by design).
advance_main "$pinned_work" 'tag retag groundwork' 5
git_fixture -C "$pinned_work" tag --force -a v1.0.0 -m 'moved fixture release tag'
git_fixture -C "$pinned_work" push --force origin refs/tags/v1.0.0 >/dev/null
run_case "$pinned_dir/workspace" -s p1
expect_success 'selected tag moved'
assert_makepkg_count "$pinned_dir/workspace" 2 'selected tag moved'

# An unqualified Git source tracks the remote's default HEAD.
default_dir=$fixture/default-head
init_git_remote "$default_dir/repository"
make_vcs_workspace "$default_dir/workspace" "$default_dir/repository/remote.git" default ''
run_case "$default_dir/workspace" p1
expect_success 'initial default-HEAD build'
run_case "$default_dir/workspace" -s p1
expect_success 'unchanged default HEAD'
assert_makepkg_count "$default_dir/workspace" 1 'unchanged default HEAD'
# 5 commits: past the freshness tolerance, so the move still rebuilds.
advance_main "$default_dir/repository/work" 'advanced default HEAD' 5
run_case "$default_dir/workspace" -s p1
expect_success 'advanced default HEAD'
assert_makepkg_count "$default_dir/workspace" 2 'advanced default HEAD'

# ─── Freshness tolerance: -s must not rebuild over a handful of commits ─────
# Owner design (2026-10-03): "a fewer than 5 commits is senseless especially
# for these heavy packages since we aren't actively participating in
# development in these important projects" — we are CONSUMERS of llvm/rust/qt6,
# not their developers. A measured advance strictly BELOW the tolerance (default
# 5, overridable via GSA_VCS_SKIP_TOLERANCE) keeps the skip and says so LOUDLY;
# at the tolerance (the boundary is AT 5) and beyond — including past the
# shallow measurement window — the rebuild happens exactly as before. Each case
# owns its own workspace so "moves N commits" is measured from the recorded
# baseline without cross-case arithmetic.

# 3 commits (< 5): the skip HOLDS — the -s run runs makepkg 0 times — and the
# waiver is a named line plus a freshness-waived run-record row, never a silent
# lowering of verification.
tolerance_dir=$fixture/freshness-tolerance
init_git_remote "$tolerance_dir/repository"
tolerance_work=$tolerance_dir/repository/work
make_vcs_workspace "$tolerance_dir/workspace" "$tolerance_dir/repository/remote.git" branch main
run_case "$tolerance_dir/workspace" p1
expect_success 'tolerance initial build'
assert_makepkg_count "$tolerance_dir/workspace" 1 'tolerance initial build'
advance_main "$tolerance_work" 'tolerance noise' 3
run_case "$tolerance_dir/workspace" -s p1
expect_success 'three-commit advance keeps the skip'
assert_makepkg_count "$tolerance_dir/workspace" 1 'three-commit advance: the -s run must run makepkg 0 times'
grep -Eq '^p1 succeeded 0 [0-9]+ freshness-waived$' <<<"$FIXTURE_OUTPUT" ||
    fail "three-commit advance row is not 'succeeded … freshness-waived':"$'\n'"$FIXTURE_OUTPUT"
if grep -Eq '^p1 succeeded 0 [0-9]+ ok$' <<<"$FIXTURE_OUTPUT"; then
    fail 'a waived-freshness skip claimed the plain ok row:'$'\n'"$FIXTURE_OUTPUT"
fi
grep -Fq 'SKIPPED (freshness-waived)' <<<"$FIXTURE_OUTPUT" ||
    fail 'the run output does not name the freshness waiver:'$'\n'"$FIXTURE_OUTPUT"
tolerance_diagnostics=$(diagnostics_with_logs "$tolerance_dir/workspace")
grep -Fq 'upstream moved 3 commit(s) < tolerance 5 — treating upstream as current' \
    <<<"$tolerance_diagnostics" ||
    fail 'three-commit advance did not print the named freshness waiver line:'$'\n'"$tolerance_diagnostics"

# Exactly 5: the boundary is AT the tolerance — rebuild (makepkg runs once).
boundary_dir=$fixture/freshness-boundary
init_git_remote "$boundary_dir/repository"
boundary_work=$boundary_dir/repository/work
make_vcs_workspace "$boundary_dir/workspace" "$boundary_dir/repository/remote.git" branch main
run_case "$boundary_dir/workspace" p1
expect_success 'boundary initial build'
assert_makepkg_count "$boundary_dir/workspace" 1 'boundary initial build'
advance_main "$boundary_work" 'tolerance boundary' 5
run_case "$boundary_dir/workspace" -s p1
expect_success 'exactly five commits rebuilds'
assert_makepkg_count "$boundary_dir/workspace" 2 'the boundary is AT 5: exactly five commits must rebuild'
grep -Eq '^p1 succeeded 0 [0-9]+ ok$' <<<"$FIXTURE_OUTPUT" ||
    fail "five-commit rebuild row is not 'succeeded … ok':"$'\n'"$FIXTURE_OUTPUT"

# 10 commits: past the fetch window (depth = tolerance + 1 = 6), where the
# baseline is unreachable in the probe repo — that failure must read as
# ">= tolerance", i.e. rebuild, never as a skip.
far_dir=$fixture/freshness-far
init_git_remote "$far_dir/repository"
far_work=$far_dir/repository/work
make_vcs_workspace "$far_dir/workspace" "$far_dir/repository/remote.git" branch main
run_case "$far_dir/workspace" p1
expect_success 'far initial build'
assert_makepkg_count "$far_dir/workspace" 1 'far initial build'
advance_main "$far_work" 'past the measurement window' 10
run_case "$far_dir/workspace" -s p1
expect_success 'ten-commit advance rebuilds'
assert_makepkg_count "$far_dir/workspace" 2 'ten-commit advance must rebuild (baseline outside the fetch window)'
grep -Eq '^p1 succeeded 0 [0-9]+ ok$' <<<"$FIXTURE_OUTPUT" ||
    fail "ten-commit rebuild row is not 'succeeded … ok':"$'\n'"$FIXTURE_OUTPUT"

# GSA_VCS_SKIP_TOLERANCE overrides the default (positive integers only); a
# garbage value falls back to the default 5, LOUDLY.
override_dir=$fixture/freshness-override
init_git_remote "$override_dir/repository"
override_work=$override_dir/repository/work
make_vcs_workspace "$override_dir/workspace" "$override_dir/repository/remote.git" branch main
run_case "$override_dir/workspace" p1
expect_success 'override initial build'
assert_makepkg_count "$override_dir/workspace" 1 'override initial build'
advance_main "$override_work" 'override noise' 1
GSA_VCS_SKIP_TOLERANCE=2 run_case "$override_dir/workspace" -s p1
expect_success 'tolerance 2 waives a one-commit move'
assert_makepkg_count "$override_dir/workspace" 1 'tolerance 2 must waive a one-commit move'
override_diagnostics=$(diagnostics_with_logs "$override_dir/workspace")
grep -Fq 'upstream moved 1 commit(s) < tolerance 2 — treating upstream as current' \
    <<<"$override_diagnostics" ||
    fail 'tolerance 2 waiver line is missing or names the wrong tolerance:'$'\n'"$override_diagnostics"
advance_main "$override_work" 'override boundary' 1
GSA_VCS_SKIP_TOLERANCE=2 run_case "$override_dir/workspace" -s p1
expect_success 'tolerance 2 boundary rebuilds'
assert_makepkg_count "$override_dir/workspace" 2 'the override boundary is AT 2: two commits must rebuild'
advance_main "$override_work" 'garbage knob' 3
GSA_VCS_SKIP_TOLERANCE=banana run_case "$override_dir/workspace" -s p1
expect_success 'garbage tolerance falls back to the default'
assert_makepkg_count "$override_dir/workspace" 2 'a garbage tolerance must not shrink the default below 5'
override_diagnostics=$(diagnostics_with_logs "$override_dir/workspace")
grep -Fq "GSA_VCS_SKIP_TOLERANCE='banana' is not a positive integer — using the default 5" \
    <<<"$override_diagnostics" ||
    fail 'a garbage tolerance was not rejected loudly:'$'\n'"$override_diagnostics"
grep -Fq 'upstream moved 3 commit(s) < tolerance 5 — treating upstream as current' \
    <<<"$override_diagnostics" ||
    fail 'the garbage-tolerance run did not fall back to the default 5:'$'\n'"$override_diagnostics"

# ─── ABI providers: never rebuild a matched ABI provider on mere movement ───
# Owner rule (2026-10-03): "not building the already built abi provider which
# is extremely heavy" — llvm-git is the matched ABI provider: rebuilding it
# invalidates every dependent's ABI (rust must rebuild after it: the owner's
# cascade rule) and costs hours, while llvm-project lands dozens of commits an
# hour, so NO tolerance can ever rescue it. A recipe carrying a .gsa-abi-provider
# marker is therefore WAIVED on any upstream movement — the verdict is
# "freshness waived", not "tolerated" — loudly, with the claim on the
# run-record row. The exemption is only the -s skip check: a missing baseline
# still rebuilds once, and an explicit build rebuilds normally.

# 30 commits of movement (far past the tolerance): the skip HOLDS — the -s run
# runs makepkg 0 times — and the waiver line names the recipe and the count.
abi_dir=$fixture/abi-provider
init_git_remote "$abi_dir/repository"
abi_work=$abi_dir/repository/work
make_vcs_workspace "$abi_dir/workspace" "$abi_dir/repository/remote.git" branch main
printf 'fixture rationale: matched ABI provider\n' >"$abi_dir/workspace/packages/p1/.gsa-abi-provider"
run_case "$abi_dir/workspace" p1
expect_success 'abi-provider initial build'
assert_makepkg_count "$abi_dir/workspace" 1 'abi-provider initial build'
advance_main "$abi_work" 'abi upstream churn' 30
run_case "$abi_dir/workspace" -s p1
expect_success 'marked recipe waives thirty commits of movement'
assert_makepkg_count "$abi_dir/workspace" 1 'marked recipe: the -s run must run makepkg 0 times'
grep -Eq '^p1 succeeded 0 [0-9]+ abi-provider-waived$' <<<"$FIXTURE_OUTPUT" ||
    fail "marked row is not 'succeeded … abi-provider-waived':"$'\n'"$FIXTURE_OUTPUT"
if grep -Eq '^p1 succeeded 0 [0-9]+ (ok|freshness-waived)$' <<<"$FIXTURE_OUTPUT"; then
    fail 'an ABI-provider skip claimed ok or a mere tolerance waiver:'$'\n'"$FIXTURE_OUTPUT"
fi
abi_diagnostics=$(diagnostics_with_logs "$abi_dir/workspace")
grep -Fq 'upstream moved 30 commit(s) — p1 is an ABI provider; freshness waived (rebuild only on measured skew or an explicit build)' \
    <<<"$abi_diagnostics" ||
    fail 'the ABI waiver line does not name the recipe and the commit count:'$'\n'"$abi_diagnostics"
# The exemption is only the skip check: an explicit build rebuilds normally.
run_case "$abi_dir/workspace" p1
expect_success 'explicit build still rebuilds a marked recipe'
assert_makepkg_count "$abi_dir/workspace" 2 'explicit build must rebuild despite the marker'

# Control: the SAME recipe shape without the marker and the same 30 commits of
# movement must rebuild — the marker is what waives, not the distance.
abi_ctrl_dir=$fixture/abi-control
init_git_remote "$abi_ctrl_dir/repository"
abi_ctrl_work=$abi_ctrl_dir/repository/work
make_vcs_workspace "$abi_ctrl_dir/workspace" "$abi_ctrl_dir/repository/remote.git" branch main
run_case "$abi_ctrl_dir/workspace" p1
expect_success 'abi-control initial build'
assert_makepkg_count "$abi_ctrl_dir/workspace" 1 'abi-control initial build'
advance_main "$abi_ctrl_work" 'abi control churn' 30
run_case "$abi_ctrl_dir/workspace" -s p1
expect_success 'unmarked recipe rebuilds after thirty commits'
assert_makepkg_count "$abi_ctrl_dir/workspace" 2 'the MARKER is what waives: an unmarked 30-commit move must rebuild'

# A marked recipe with no recorded baseline still rebuilds once (rc 3 is not
# waived — the waiver is purely the movement verdict).
abi_base_dir=$fixture/abi-missing-baseline
init_git_remote "$abi_base_dir/repository"
make_vcs_workspace "$abi_base_dir/workspace" "$abi_base_dir/repository/remote.git" branch main
printf 'fixture rationale: matched ABI provider\n' >"$abi_base_dir/workspace/packages/p1/.gsa-abi-provider"
mk_fake_archive "$abi_base_dir/workspace/packages/p1/p1-1.0.0-1-any.pkg.tar.zst"
run_case "$abi_base_dir/workspace" -s p1
expect_success 'marked recipe rebuilds once on a missing baseline'
assert_makepkg_count "$abi_base_dir/workspace" 1 'marked missing-baseline rebuild (rc 3 path intact)'
grep -Eq '^p1 succeeded 0 [0-9]+ ok$' <<<"$FIXTURE_OUTPUT" ||
    fail "marked missing-baseline rebuild row is not 'succeeded … ok':"$'\n'"$FIXTURE_OUTPUT"
[[ -f $abi_base_dir/workspace/packages/p1/p1-1.0.0-1-any.pkg.tar.zst.gsa-vcs-revisions ]] ||
    fail 'the marked rebuild did not record its VCS baseline'

# The other VCS adapters use fixture-side command stubs, so this coverage needs
# neither public network access nor optional host clients.
for protocol in svn hg bzr; do
    case $protocol in
    svn)
        fragment=revision=HEAD
        revision_a=10
        revision_b=11
        ;;
    hg)
        fragment=branch=default
        revision_a=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
        revision_b=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
        ;;
    bzr)
        fragment=
        revision_a=revision-a
        revision_b=revision-b
        ;;
    esac
    adapter_dir=$fixture/$protocol
    make_non_git_workspace "$adapter_dir/workspace" "$protocol" "$fragment"

    GSA_FAKE_VCS_REMOTE_REV=$revision_a GSA_FAKE_VCS_BUILT_REV=$revision_a \
        run_case "$adapter_dir/workspace" p1
    expect_success "$protocol initial build"
    assert_makepkg_count "$adapter_dir/workspace" 1 "$protocol initial build"

    GSA_FAKE_VCS_REMOTE_REV=$revision_a GSA_FAKE_VCS_BUILT_REV=$revision_a \
        run_case "$adapter_dir/workspace" -s p1
    expect_success "$protocol unchanged selected ref"
    assert_makepkg_count "$adapter_dir/workspace" 1 "$protocol unchanged selected ref"

    GSA_FAKE_VCS_REMOTE_REV=$revision_b GSA_FAKE_VCS_BUILT_REV=$revision_b \
        run_case "$adapter_dir/workspace" -s p1
    expect_success "$protocol advanced selected ref"
    assert_makepkg_count "$adapter_dir/workspace" 2 "$protocol advanced selected ref"
done

# Both package-local clean and workspace cleanup must remove VCS metadata with
# the archive it describes.
GSA_FAKE_EXPECT_CLEAN=1 run_case "$branch_dir/workspace" -c p1
expect_success 'clean removes the prior VCS baseline'
assert_makepkg_count "$branch_dir/workspace" 4 'clean removes the prior VCS baseline'
archive=$branch_dir/workspace/packages/p1/p1-1.0.0-1-any.pkg.tar.zst
manifest=$archive.gsa-vcs-revisions
[[ -f $manifest ]] || fail 'successful clean rebuild did not record a fresh baseline'
run_case "$branch_dir/workspace" -cc
expect_success 'workspace cleanup'
[[ ! -e $archive && ! -e $manifest ]] ||
    fail 'workspace cleanup left an archive or its VCS revision record'
assert_makepkg_count "$branch_dir/workspace" 4 'workspace cleanup'

# Real makepkg never leaves a VCS checkout at the package root: download_git
# keeps the mirror in SRCDEST and extract_git clones the working copy into
# $srcdir ($PWD/src/<name>), which build()/package() then cd into. The
# recorder must locate the checkout there — the 2026-10-02 xdg-utils failure
# ("build succeeded but VCS revisions could not be recorded: missing local
# checkout", green build, checkout present one directory deeper) was exactly
# this probe gap. The same-named decoys below pin the authority order: when
# directories also exist at the package root and in SRCDEST at a DIFFERENT
# revision, the manifest must still carry the revision compiled from src/.
src_layout=$fixture/srcdir-layout
init_git_remote "$src_layout/repository"
src_layout_remote=$src_layout/repository/remote.git
src_layout_work=$src_layout/repository/work
make_vcs_workspace "$src_layout/workspace" "$src_layout_remote" branch main
rev1=$(GIT_CONFIG_COUNT=0 git -C "$src_layout_work" rev-parse HEAD)

GSA_FAKE_VCS_LAYOUT=srcdir run_case "$src_layout/workspace" p1
expect_success 'srcdir-layout initial build'
assert_makepkg_count "$src_layout/workspace" 1 'srcdir-layout initial build'
src_layout_pkg=$src_layout/workspace/packages/p1
src_layout_archive=$src_layout_pkg/p1-1.0.0-1-any.pkg.tar.zst
src_layout_manifest=$src_layout_archive.gsa-vcs-revisions
[[ -f $src_layout_manifest ]] ||
    fail 'srcdir-layout build did not record its VCS baseline'
recorded=$(awk -F '\t' 'NR > 2 { print $3 }' "$src_layout_manifest")
src_rev=$(GIT_CONFIG_COUNT=0 git -C "$src_layout_pkg/src/upstream" rev-parse HEAD)
[[ $recorded == "$src_rev" && $recorded == "$rev1" ]] ||
    fail "srcdir-layout recorded $recorded; src/ checkout is $src_rev (first revision $rev1)"

# Consumer parity: the baseline recorded from the srcdir checkout must satisfy
# the -s skip decision exactly like one recorded from a package-root checkout.
GSA_FAKE_VCS_LAYOUT=srcdir run_case "$src_layout/workspace" -s p1
expect_success 'srcdir-layout unchanged selected branch'
assert_makepkg_count "$src_layout/workspace" 1 'srcdir-layout unchanged selected branch'

# Decoys at the two locations the recorder historically probed first, both
# pinned at the first revision while src/ still holds it. Sanity-checked so a
# decoy that silently landed on the built revision could not make the priority
# assertion below pass vacuously.
mkdir -p "$src_layout/workspace/makepkg-srcdest"
GIT_CONFIG_COUNT=0 git clone --quiet "$src_layout_remote" "$src_layout_pkg/upstream"
GIT_CONFIG_COUNT=0 git clone --quiet "$src_layout_remote" \
    "$src_layout/workspace/makepkg-srcdest/upstream"
for decoy in "$src_layout_pkg/upstream" "$src_layout/workspace/makepkg-srcdest/upstream"; do
    decoy_rev=$(GIT_CONFIG_COUNT=0 git -C "$decoy" rev-parse HEAD)
    [[ $decoy_rev == "$rev1" ]] ||
        fail "decoy at $decoy is at $decoy_rev, expected $rev1"
done

advance_main "$src_layout_work" 'advanced selected branch' 5
GSA_FAKE_VCS_LAYOUT=srcdir run_case "$src_layout/workspace" -s p1
expect_success 'srcdir-layout advanced selected branch'
assert_makepkg_count "$src_layout/workspace" 2 'srcdir-layout advanced selected branch'
rev2=$(GIT_CONFIG_COUNT=0 git -C "$src_layout_work" rev-parse HEAD)
recorded=$(awk -F '\t' 'NR > 2 { print $3 }' "$src_layout_manifest")
src_rev=$(GIT_CONFIG_COUNT=0 git -C "$src_layout_pkg/src/upstream" rev-parse HEAD)
[[ $recorded == "$src_rev" && $recorded == "$rev2" && $recorded != "$rev1" ]] ||
    fail "srcdir-layout recorded $recorded after the advance; src/ checkout is $src_rev (decoys still at $rev1)"

# The xdg-utils entry shape: no name:: override, and the URL basename carries
# .git. source_filename keeps that spelling ("remote.git", keyed by the
# provider maps) while makepkg strips it to name the checkout ("remote"), so
# the srcdir probe has to honour both spellings of the same source.
src_suffix=$fixture/srcdir-git-suffix
init_git_remote "$src_suffix/repository"
src_suffix_remote=$src_suffix/repository/remote.git
make_vcs_workspace "$src_suffix/workspace" "$src_suffix_remote" branch main basename

GSA_FAKE_VCS_LAYOUT=srcdir run_case "$src_suffix/workspace" p1
expect_success 'srcdir basename-style build'
assert_makepkg_count "$src_suffix/workspace" 1 'srcdir basename-style build'
src_suffix_manifest=$src_suffix/workspace/packages/p1/p1-1.0.0-1-any.pkg.tar.zst.gsa-vcs-revisions
[[ -f $src_suffix_manifest ]] ||
    fail 'basename-style build did not record its VCS baseline'
recorded=$(awk -F '\t' 'NR > 2 { print $3 }' "$src_suffix_manifest")
src_rev=$(GIT_CONFIG_COUNT=0 git -C "$src_suffix/workspace/packages/p1/src/remote" rev-parse HEAD)
[[ $recorded == "$src_rev" ]] ||
    fail "basename-style recorded $recorded; src/ checkout is $src_rev"

GSA_FAKE_VCS_LAYOUT=srcdir run_case "$src_suffix/workspace" -s p1
expect_success 'srcdir basename-style unchanged selected branch'
assert_makepkg_count "$src_suffix/workspace" 1 'srcdir basename-style unchanged selected branch'

# ─── Built-output set completeness (R-F2) ────────────────────────────────────
# A split recipe's currency is a property of the whole OUTPUT SET: an archive
# for one output does not make the recipe current while a sibling output is
# missing, so -s must rebuild instead of skipping on the surviving half. The
# expected set is discovered from the evaluated pkgname array (this workspace
# carries no .SRCINFO; install-archive-guard.sh pins the .SRCINFO primary
# source). The anomaly is created the way it happens in production: the set
# builds complete once (which also records the workspace's toolchain identity,
# so no drift clean can mask the decision), then a packaging SIGKILL is
# simulated by deleting one output.
(
    split_dir=$fixture/split-set
    split_ws=$split_dir/workspace
    make_workspace "$split_ws" 1 2 low
    mkdir -p "$split_ws/packages/p1"
    printf '%s\n' 'pkgname=(p1 p1-extra)' 'pkgver=1.0.0' 'pkgrel=1' 'arch=(any)' \
        >"$split_ws/packages/p1/PKGBUILD"
    printf 'p1|packages/p1|git|\n' >>"$split_ws/config/topology.conf"
    touch -d '2000-01-01 00:00:00 UTC' "$split_ws/packages/p1/PKGBUILD"
    cat >"$split_ws/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -eu
id=$(basename "$PWD")
printf '%s\n' "$id" >>"${GSA_FAKE_MAKEPKG_COUNT:?}"
tar --zstd -cf "$PWD/p1-1.0.0-1-any.pkg.tar.zst" --files-from /dev/null
tar --zstd -cf "$PWD/p1-extra-1.0.0-1-any.pkg.tar.zst" --files-from /dev/null
EOF
    chmod +x "$split_ws/bin/makepkg"
    stub_sudo "$split_ws"
    stub_pacman "$split_ws"

    run_case "$split_ws" -s p1
    expect_success 'split set: initial build'
    assert_makepkg_count "$split_ws" 1 'split set: initial build'
    rm -f "$split_ws/packages/p1/p1-extra-1.0.0-1-any.pkg.tar.zst"
    run_case "$split_ws" -s p1
    expect_success 'partial output set rebuilds'
    assert_makepkg_count "$split_ws" 2 'partial output set rebuilds'
    diagnostics=$(diagnostics_with_logs "$split_ws")
    grep -Fq 'is incomplete' <<<"$diagnostics" ||
        fail 'partial output set did not report the incomplete set:'$'\n'"$diagnostics"
    grep -Fq 'missing: p1-extra' <<<"$diagnostics" ||
        fail 'incomplete-set diagnostic did not name the missing output:'$'\n'"$diagnostics"

    run_case "$split_ws" -s p1
    expect_success 'complete output set skips'
    assert_makepkg_count "$split_ws" 2 'complete output set skips'
)

# ─── Payload integrity (R-F3) ────────────────────────────────────────────────
# A truncated archive must not be sticky under -s. The probe reads archives
# the way pacman does — the whole zstd stream, not the filename — so an
# interrupted write is detected before the skip and rebuilt once.
(
    trunc_dir=$fixture/truncated-archive
    trunc_ws=$trunc_dir/workspace
    make_workspace "$trunc_ws" 1 2 low
    add_package "$trunc_ws" p1 "$gsa_meta_any"
    touch -d '2000-01-01 00:00:00 UTC' "$trunc_ws/packages/p1/PKGBUILD"
    cat >"$trunc_ws/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -eu
id=$(basename "$PWD")
printf '%s\n' "$id" >>"${GSA_FAKE_MAKEPKG_COUNT:?}"
tar --zstd -cf "$PWD/$id-1.0.0-1-any.pkg.tar.zst" --files-from /dev/null
EOF
    chmod +x "$trunc_ws/bin/makepkg"
    stub_sudo "$trunc_ws"
    # The tar-delegating probe stub: pacman -Qp must model stream validation,
    # so a truncated archive fails it exactly as it fails real pacman.
    cat >"$trunc_ws/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'pacman %s\n' "$*" >>"${GSA_FAKE_PACMAN_LOG:?}"
case ${1:-} in
-Qp)
    file=
    for arg in "$@"; do file=$arg; done
    [[ -n $file ]] || exit 1
    tar --zstd -t -f "$file" >/dev/null 2>&1
    exit $?
    ;;
-Qi) exit 1 ;;
esac
exit 0
EOF
    chmod +x "$trunc_ws/bin/pacman"

    trunc_archive=$trunc_ws/packages/p1/p1-1.0.0-1-any.pkg.tar.zst
    run_case "$trunc_ws" -s p1
    expect_success 'truncated archive: initial build'
    assert_makepkg_count "$trunc_ws" 1 'truncated archive: initial build'
    half=$(($(stat -c %s "$trunc_archive") / 2))
    head -c "$half" "$trunc_archive" >"$trunc_archive.trunc"
    mv "$trunc_archive.trunc" "$trunc_archive"
    run_case "$trunc_ws" -s p1
    expect_success 'truncated archive rebuilds'
    assert_makepkg_count "$trunc_ws" 2 'truncated archive rebuilds'
    diagnostics=$(diagnostics_with_logs "$trunc_ws")
    grep -Fq 'cannot be read as a package archive' <<<"$diagnostics" ||
        fail 'truncated archive did not report the payload failure:'$'\n'"$diagnostics"

    run_case "$trunc_ws" -s p1
    expect_success 'rebuilt archive skips'
    assert_makepkg_count "$trunc_ws" 2 'rebuilt archive skips'
)

# ─── Version-aware currency (R-F23 / D-F2) ───────────────────────────────────
# "Current" is keyed to the evaluated pkgver/pkgrel: an archive named for an
# older version is not a build of THIS PKGBUILD and must never satisfy -s,
# however fresh its mtime.
(
    stale_dir=$fixture/stale-version
    stale_ws=$stale_dir/workspace
    make_workspace "$stale_ws" 1 2 low
    add_package "$stale_ws" p1 "$gsa_meta_any"
    touch -d '2000-01-01 00:00:00 UTC' "$stale_ws/packages/p1/PKGBUILD"
    cat >"$stale_ws/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -eu
id=$(basename "$PWD")
printf '%s\n' "$id" >>"${GSA_FAKE_MAKEPKG_COUNT:?}"
tar --zstd -cf "$PWD/$id-1.0.0-1-any.pkg.tar.zst" --files-from /dev/null
EOF
    chmod +x "$stale_ws/bin/makepkg"
    stub_sudo "$stale_ws"
    stub_pacman "$stale_ws"

    run_case "$stale_ws" -s p1
    expect_success 'stale-version archive: initial build'
    assert_makepkg_count "$stale_ws" 1 'stale-version archive: initial build'
    # The recipe moves to 1.0.0 while only the 0.9 build is on disk: the old
    # archive is not a build of this PKGBUILD and must not satisfy -s.
    mv "$stale_ws/packages/p1/p1-1.0.0-1-any.pkg.tar.zst" \
        "$stale_ws/packages/p1/p1-0.9-1-any.pkg.tar.zst"
    run_case "$stale_ws" -s p1
    expect_success 'stale-version archive rebuilds'
    assert_makepkg_count "$stale_ws" 2 'stale-version archive rebuilds'

    run_case "$stale_ws" -s p1
    expect_success 'current-version archive skips'
    assert_makepkg_count "$stale_ws" 2 'current-version archive skips'
)

# ─── Manifest identity binding (R-F4) ────────────────────────────────────────
# The v2 VCS manifest binds the recorded baseline to the exact archive bytes
# (sha256 + size). An archive replaced under a live manifest is a DIFFERENT
# build: the recorded revisions cannot vouch for it, so -s must rebuild rather
# than skip. The replacement here is a readable archive — the payload probe
# passes — so this case isolates the identity binding from the payload check.
(
    ident_dir=$fixture/manifest-identity
    init_git_remote "$ident_dir/repository"
    ident_remote=$ident_dir/repository/remote.git
    make_vcs_workspace "$ident_dir/workspace" "$ident_remote" branch main
    ident_ws=$ident_dir/workspace
    ident_archive=$ident_ws/packages/p1/p1-1.0.0-1-any.pkg.tar.zst
    run_case "$ident_ws" p1
    expect_success 'manifest identity: initial build'
    assert_makepkg_count "$ident_ws" 1 'manifest identity: initial build'
    [[ -f $ident_archive.gsa-vcs-revisions ]] ||
        fail 'manifest identity: initial build did not record its VCS baseline'

    mk_fake_archive "$ident_archive" 'replacement payload'
    run_case "$ident_ws" -s p1
    expect_success 'manifest identity: replaced archive rebuilds'
    assert_makepkg_count "$ident_ws" 2 'manifest identity: replaced archive rebuilds'
    diagnostics=$(diagnostics_with_logs "$ident_ws")
    grep -Fq 'a different build of' <<<"$diagnostics" ||
        fail 'manifest identity: replaced archive did not report the baseline mismatch'

    run_case "$ident_ws" -s p1
    expect_success 'manifest identity: rebuilt archive skips'
    assert_makepkg_count "$ident_ws" 2 'manifest identity: rebuilt archive skips'
)

printf 'upstream-aware skip fixture: PASS\n'
