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

advance_main() { # $1 = local worktree; $2 = commit message and file content
    local work=$1 message=$2
    printf '%s\n' "$message" >>"$work/source.txt"
    git_fixture -C "$work" add source.txt
    git_fixture -C "$work" commit -m "$message" >/dev/null
    git_fixture -C "$work" push origin main >/dev/null
}

make_vcs_workspace() { # $1 = workspace; $2 = remote path; $3 = branch|tag; $4 = ref
    local dir=$1 remote=$2 kind=$3 ref=$4
    local source="upstream::git+file://$remote"
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
upstream::git+file://*) ;;
*)
    printf 'fake makepkg: expected a named local Git source, got %s\n' "$entry" >&2
    exit 1
    ;;
esac

url=${entry#upstream::git+}
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

if [[ ! -d "$PWD/upstream/.git" ]]; then
    git_config0 clone --quiet --no-checkout "$remote" "$PWD/upstream"
fi

case $selector in
default)
    git_config0 -C "$PWD/upstream" remote set-head origin --auto >/dev/null
    default_ref=$(git_config0 -C "$PWD/upstream" symbolic-ref --short refs/remotes/origin/HEAD)
    default_ref=${default_ref#origin/}
    git_config0 -C "$PWD/upstream" fetch --quiet --no-tags origin \
        "$default_ref:refs/remotes/origin/$default_ref"
    git_config0 -C "$PWD/upstream" checkout --quiet -B "$default_ref" "refs/remotes/origin/$default_ref"
    ;;
branch=*)
    ref=${selector#branch=}
    git_config0 -C "$PWD/upstream" fetch --quiet --no-tags origin \
        "refs/heads/$ref:refs/remotes/origin/$ref"
    git_config0 -C "$PWD/upstream" checkout --quiet -B "$ref" "refs/remotes/origin/$ref"
    ;;
tag=*)
    ref=${selector#tag=}
    git_config0 -C "$PWD/upstream" fetch --quiet --no-tags origin \
        "+refs/tags/$ref:refs/tags/$ref"
    git_config0 -C "$PWD/upstream" checkout --quiet --detach "refs/tags/$ref"
    ;;
*)
    printf 'fake makepkg: unsupported selected Git ref %s\n' "$selector" >&2
    exit 1
    ;;
esac

: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
EOF
    chmod +x "$dir/bin/makepkg"
    stub_sudo "$dir"
    cat >"$dir/bin/pacman" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'pacman %s\n' "$*" >>"${GSA_FAKE_PACMAN_LOG:?}"
case ${1:-} in
-Qp | -Qi) exit 1 ;;
esac
exit 0
EOF
    chmod +x "$dir/bin/pacman"
}

run_case() { # $1 = workspace; remaining args = builder selection/flags
    local dir=$1
    shift
    run_builder env \
        PATH="$dir/bin:$PATH" \
        GIT_CONFIG_COUNT=0 \
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
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
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
-Qp | -Qi) exit 1 ;;
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

expect_freshness_refusal() { # $1 = workspace; $2 = prior count; $3 = label; $4 = diagnostic regex
    local dir=$1 want_count=$2 label=$3 words=$4 diagnostics=$FIXTURE_OUTPUT
    if ((FIXTURE_RC == 0)); then
        fail "$label unexpectedly succeeded:"$'\n'"$FIXTURE_OUTPUT"
    fi
    assert_makepkg_count "$dir" "$want_count" "$label (must fail before makepkg)"
    if [[ -d $dir/state/logs ]]; then
        diagnostics+=$'\n'"$(find "$dir/state/logs" -maxdepth 1 -type f -exec cat {} + 2>/dev/null || true)"
    fi
    if ! grep -Fq 'p1' <<<"$diagnostics" || ! grep -Eiq "$words" <<<"$diagnostics"; then
        fail "$label did not report a package-specific VCS freshness error:"$'\n'"$diagnostics"
    fi
}

# A single branch-following recipe pins unchanged-ref skips, -s -i install
# behavior, selected-ref advancement, and the original PKGBUILD-mtime check.
branch_dir=$fixture/branch
init_git_remote "$branch_dir/repository"
branch_remote=$branch_dir/repository/remote.git
branch_work=$branch_dir/repository/work
make_vcs_workspace "$branch_dir/workspace" "$branch_remote" branch main

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
grep -Fq 'p1-1.0.0-1-any.pkg.tar.zst' "$branch_dir/workspace/pacman.log" ||
    fail 'unchanged branch -s -i installed without the existing archive'

advance_main "$branch_work" 'advanced selected branch'
run_case "$branch_dir/workspace" -s p1
expect_success 'advanced selected branch'
assert_makepkg_count "$branch_dir/workspace" 2 'advanced selected branch'

touch -d '+1 day' "$branch_dir/workspace/packages/p1/PKGBUILD"
run_case "$branch_dir/workspace" -s p1
expect_success 'newer PKGBUILD mtime'
assert_makepkg_count "$branch_dir/workspace" 3 'newer PKGBUILD mtime'

# A pre-existing archive with no successful-build revision record is not a
# usable skip baseline, even while its selected remote ref is reachable.
missing_dir=$fixture/missing-baseline
init_git_remote "$missing_dir/repository"
make_vcs_workspace "$missing_dir/workspace" "$missing_dir/repository/remote.git" branch main
: >"$missing_dir/workspace/packages/p1/p1-1.0.0-1-any.pkg.tar.zst"
run_case "$missing_dir/workspace" -s p1
expect_freshness_refusal "$missing_dir/workspace" 0 'missing baseline' 'baseline|revision|upstream'

# A previously recorded baseline cannot be used when the selected remote ref
# is no longer queryable; the failure must happen before another makepkg run.
unreachable_dir=$fixture/unreachable
init_git_remote "$unreachable_dir/repository"
make_vcs_workspace "$unreachable_dir/workspace" "$unreachable_dir/repository/remote.git" branch main
run_case "$unreachable_dir/workspace" p1
expect_success 'initial reachable build'
assert_makepkg_count "$unreachable_dir/workspace" 1 'initial reachable build'
mv "$unreachable_dir/repository/remote.git" "$unreachable_dir/repository/remote.offline"
run_case "$unreachable_dir/workspace" -s p1
expect_freshness_refusal "$unreachable_dir/workspace" 1 'unreachable upstream' 'remote|revision|upstream|baseline'

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
advance_main "$default_dir/repository/work" 'advanced default HEAD'
run_case "$default_dir/workspace" -s p1
expect_success 'advanced default HEAD'
assert_makepkg_count "$default_dir/workspace" 2 'advanced default HEAD'

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

printf 'upstream-aware skip fixture: PASS\n'
