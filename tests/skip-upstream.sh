#!/usr/bin/env bash
set -euo pipefail

# tests/skip-upstream.sh — upstream-aware `--skip` / `--skip-built` /
# `--vcs-skip-tolerance N` on the NATIVE engine (`gsa`): freshness tolerance
# and its waiver, ABI-provider waivers, VCS baseline/manifest integrity,
# transport retry/deferral/park/fallback, the built-set claim, the toolchain
# drift gate that outranks every claim, and claim durability. Driven through
# synthetic $TMPDIR workspaces and stub `makepkg`/`git`/`svn`/`hg`/`bzr`/
# `pacman`/`sudo`/`gcc` executables at the process boundary — no package is
# built, no real pacman transaction runs, nothing outside the fixture tree is
# written, no network is used (remotes are local `file://` bare repos and the
# non-git adapters answer from stubs).
#
# Flip notes (docs/gsa-fixture-migration.md row `tests/skip-upstream.sh`):
# the fish builder (`fish build-all.fish -s …`) becomes `gsa -B|-S --skip …`
# via tests/lib/rr-v2.bash's run_engine; `--no-deps` flips to `--leaf`
# (§B.8), `-i` retires into the `-S` family, `-c`/`-cc` flip to the cluster
# letter `c` / the `-Mc`/`-Mcc` maintain verbs (§B.7), and the fish
# `format: 1` rows become `format: 2` rows asserted through rr2_*:
#   * a `--skip` claim runs NO lane: plan `skip <reason>`, outcome
#     `succeeded - - <reason>`, reason ∈ ok|skip-built|freshness-waived|
#     abi-provider-waived (§H.3), yet on `gsa -S` the claim still installs;
#   * a build is plan `build[-install] ok`, outcome `succeeded 0 <dur> ok`;
#   * an unverifiable upstream parks the recipe as `deferred 99 -
#     upstream-unverified` and its consumer cone as `parked - -
#     waits-on-deferred`, rc 5 (§G.1 deferral-only); the fallback (consumers
#     cannot wait, waiter cap 3) is a normal build;
#   * policy/prose output is the run's merged STDERR (`gsa: note: …`) — it
#     never lands in per-package logs, so every prose pin greps
#     FIXTURE_OUTPUT. Fish-era decision DIAGNOSTIC greps ('is incomplete',
#     'cannot be read as a package archive', 'a different build of', …) have
#     no gsa rendering today (the freshness verdict's build detail is
#     computed in crates/gsa-recipe/src/freshness.rs `decide()` and dropped
#     by the CLI — recorded deviation, see the report) and their meanings
#     re-pin as DECISIONS paired with a control run over the same staged
#     state (§L.3/§L.5: prose byte-pins retire, meanings re-pin).
# The engine has STATE the fish builder never had (the hash-bound binpkg
# index and its retention sweep), so scenario setup STAGES the built set it
# needs (archive + `.gsa-vcs-revisions` manifest + toolchain marker + mtimes)
# instead of building it — one engine run per freshness scenario, with
# build→claim pairs where the round trip itself is the semantics. The final
# section pins CLAIM DURABILITY (a claim must leave its evidence in place so
# the next run keeps skipping); that is where the engine's retention sweep
# today deletes the claimed archive (engine bug, evidence in the report).

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-skip-upstream.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf 'skip-upstream: %s\n' "$*" >&2
    exit 1
}

# ─── Stub-knob vocabulary (§D.2: declared in the change that adds them) ─────
rr2_stub_knob GSA_FAKE_VCS_LAYOUT "skip-upstream makepkg stub: checkout layout (root|srcdir)"
rr2_stub_knob GSA_FAKE_EXPECT_CLEAN "skip-upstream makepkg stub: fail if a stale VCS baseline survives the clean"
rr2_stub_knob GSA_FAKE_VCS_REMOTE_REV "skip-upstream svn/hg/bzr stubs: remote revision answer"
rr2_stub_knob GSA_FAKE_VCS_BUILT_REV "skip-upstream svn/hg/bzr stubs: local checkout revision answer"

# The identity the gcc stub reports (and every staged toolchain marker
# carries) when no run overrides GSA_FAKE_GCC_VERSION.
GSA_FAKE_GCC_ID='gcc (fixture) fixture' 

# ─── The engine under test: built into the fixture tree (scratch only) ──────
cargo build --offline --quiet --target-dir "$fixture/cargo" -p gsa-cli \
    --manifest-path "$gsa_repo_root/Cargo.toml" \
    || fail "cannot build the gsa binary for the fixture"
gsa_bin="$fixture/cargo/debug/gsa"
[ -x "$gsa_bin" ] || fail "cargo did not produce $gsa_bin"
export GSA_TEST_ENGINE=gsa
export GSA_TEST_GSA_BIN="$gsa_bin"

# ─── Repository fixtures (a build-order claim is compared against a real
# remote revision, so the upstreams are real bare repos under $TMPDIR) ──────
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
    # at least the freshness tolerance (5) commits: --skip deliberately waives
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

ws_git_init() { # $1 = workspace; $2 = committer date (default 2020-01-01).
    # The --skip-built recipe-change gate reads the PKGBUILD's last COMMIT
    # time, so a fixture workspace must BE a git tree — and the commit date
    # is fixture state: fixed values keep the gate's second-granularity
    # arithmetic deterministic (a commit's whole second vs the archive's
    # nanosecond mtime).
    local ws=$1 date=${2:-'@1577836800 +0000'}
    git_fixture -C "$ws" init --initial-branch=main >/dev/null
    git_fixture -C "$ws" config user.name 'Fixture User'
    git_fixture -C "$ws" config user.email 'fixture@example.invalid'
    git_fixture -C "$ws" config commit.gpgsign false
    git_fixture -C "$ws" config core.hooksPath /dev/null
    GIT_COMMITTER_DATE=$date GIT_AUTHOR_DATE=$date git_fixture -C "$ws" add -A
    GIT_COMMITTER_DATE=$date GIT_AUTHOR_DATE=$date \
        git_fixture -C "$ws" commit -m 'recipe tree' >/dev/null
}

ws_git_commit() { # $1 = workspace; $2 = committer date; $3 = message.
    local ws=$1 date=$2 message=$3
    GIT_COMMITTER_DATE=$date GIT_AUTHOR_DATE=$date git_fixture -C "$ws" add -A
    GIT_COMMITTER_DATE=$date GIT_AUTHOR_DATE=$date \
        git_fixture -C "$ws" commit -m "$message" >/dev/null
}

# ─── Staged state (the built sets the freshness engine reads) ───────────────
# pkginfo_archive OUT NAME [MARKER] — one REAL (if tiny) zstd tarball carrying
# its own `.PKGINFO` truth: the payload probe reads archives the way pacman
# does (a zero-byte file models exactly the interrupted write that probe
# rejects), the binpkg-index registration and the install name authority read
# the `.PKGINFO`, so "an archive exists" must model a readable, nameable one.
# MARKER adds a second tar member: a plain repeat call within the same second
# is byte-identical (GNU tar records whole-second mtimes), so a replacement
# that must differ needs a different payload to model "replaced bytes".
pkginfo_archive() {
    local out=$1 name=$2 marker=${3:-}
    local stage=$fixture/.mk-archive.$$
    mkdir -p "$stage"
    printf 'pkgbase = %s\npkgname = %s\npkgver = 1.0.0\npkgrel = 1\narch = any\n' \
        "$name" "$name" >"$stage/.PKGINFO"
    if [ -n "$marker" ]; then
        printf '%s\n' "$marker" >"$stage/BUILD-MARKER"
    fi
    tar --zstd -cf "$out" -C "$stage" .PKGINFO ${marker:+BUILD-MARKER}
    rm -rf "$stage"
}

# vcs_manifest ARCHIVE ENTRY PROTOCOL REVISION — manifest format 2 bound to
# the archive's exact bytes (sha256 + size identity), one row for the source
# ENTRY at REVISION: the shape the engine's recorder writes after a build and
# its detector accepts at a --skip probe.
vcs_manifest() {
    local archive=$1 entry=$2 protocol=$3 revision=$4
    local key size sha
    key=$(printf '%s' "$entry" | sha256sum | awk '{print $1}')
    size=$(stat -c %s "$archive")
    sha=$(sha256sum "$archive" | awk '{print $1}')
    {
        printf 'gsa-vcs-revisions\t2\n'
        printf 'archive\t%s\t%s\n' "$sha" "$size"
        printf '%s\t%s\t%s\n' "$key" "$protocol" "$revision"
    } >"$archive.gsa-vcs-revisions"
}

# stage_marker WS [IDENTITY] — the GCC build-identity marker the drift gate
# reads (`<state>/toolchains/<id>`). Staging the CURRENT identity keeps the
# drift gate quiet so a scenario tests the freshness engine and not the
# one-time clean; the drift section stages missing/changed markers on purpose.
stage_marker() {
    local ws=$1 identity=${2:-$GSA_FAKE_GCC_ID}
    mkdir -p "$ws/state/toolchains"
    printf '%s\n' "$identity" >"$ws/state/toolchains/p1"
}

# stage_vcs_set WS ENTRY PROTOCOL REVISION — one claimed-ready built set for
# p1 beside its recipe: archive + bound VCS manifest + toolchain marker +
# the PKGBUILD-mtime pin (2000 ≪ the archive, so the mtime gate stays quiet).
stage_vcs_set() {
    local ws=$1 entry=$2 protocol=$3 revision=$4
    local pkg=$ws/packages/p1 archive=$ws/packages/p1/p1-1.0.0-1-any.pkg.tar.zst
    pkginfo_archive "$archive" p1
    vcs_manifest "$archive" "$entry" "$protocol" "$revision"
    stage_marker "$ws"
    touch -d '2000-01-01 00:00:00 UTC' "$pkg/PKGBUILD"
}

# stage_plain_set WS [NAME…] — a claimed-ready non-VCS built set (default
# p1): one archive per output name, marker, mtime pin.
stage_plain_set() { # $1 = workspace; remaining args = output names (default p1)
    local dir=$1
    shift
    local names=${*:-p1} name
    for name in $names; do
        pkginfo_archive "$dir/packages/p1/$name-1.0.0-1-any.pkg.tar.zst" "$name"
    done
}

# ─── Workspace synthesis ────────────────────────────────────────────────────
# The gcc stub pins the drift gate's identity input (GSA_FAKE_GCC_VERSION is
# fixture-side; tests/toolchain-drift.sh owns the LTO-object half of the
# gate), and every workspace's makepkg/pacman/sudo stubs live at the process
# boundary like the other flipped fixtures'.
write_gcc_stub() {
    cat >"$1/bin/gcc" <<'EOF'
#!/usr/bin/env bash
set -u
[[ ${1:-} == --version ]] || exit 2
printf 'gcc (fixture) %s\n' "${GSA_FAKE_GCC_VERSION:-fixture}"
EOF
    chmod +x "$1/bin/gcc"
}

# The pacman the engine's probes reach: `pacman -Qp` models pacman's own
# archive validation (it decompresses the whole zstd stream before answering,
# so a write killed at ANY offset fails this probe exactly as it fails real
# pacman), everything else is logged and answered "not installed"/ok.
write_pacman_stub() {
    cat >"$1/bin/pacman" <<'EOF'
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
    chmod +x "$1/bin/pacman"
}

# The sudo passthrough (fixture-lib) plus a fabricated pacman DB root, so an
# install decision never reads the HOST's /var/lib/pacman.
write_db_stub() {
    mkdir -p "$fixture/db"
    cat >"$1/bin/pacman-conf" <<EOF
#!/usr/bin/env bash
[ "\${1:-}" = DBPath ] && printf '%s\n' "$fixture/db"
exit 0
EOF
    chmod +x "$1/bin/pacman-conf"
}

make_workspace_common() { # $1 = workspace
    make_workspace "$1" 1 2 low
    make_install_conf "$1/pacman.conf"
    write_gcc_stub "$1"
    write_pacman_stub "$1"
    write_db_stub "$1"
    stub_sudo "$1"
    # Every workspace carries the fake makepkg — including the staged-set
    # workspaces that normally only CLAIM: a rebuild trigger must never fall
    # through to the HOST's real makepkg (it would clone into the engine's
    # shared SRCDEST cache and print real build output into the lane log).
    # The non-git adapter workspaces overwrite it with their own stub.
    write_git_makepkg_stub "$1"
    # The SUT's retry backoffs and dispatcher polls are pure latency here —
    # nothing in this fixture asserts on wall-clock time (see stub_sleep).
    stub_sleep "$1"
}

make_vcs_workspace() { # $1 workspace; $2 remote path; $3 branch|tag|default; $4 ref;
    # $5 entry style: override (default — 'upstream::url') or basename (no
    #    override, URL basename carries .git — the xdg-utils shape). The
    #    checkout layout is not baked here: the fake makepkg decides it at
    #    run time from GSA_FAKE_VCS_LAYOUT (root = clone beside the PKGBUILD;
    #    srcdir = clone under $PWD/src/<name>, where real makepkg's
    #    extract_git puts the working copy).
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
    make_workspace_common "$dir"
    add_package "$dir" p1 "$extra"
    # Keep the archive-mtime condition deterministic on the first build.
    touch -d '2000-01-01 00:00:00 UTC' "$dir/packages/p1/PKGBUILD"
    write_git_makepkg_stub "$dir"
}

# write_git_makepkg_stub DIR — the Git-capable fake makepkg: clones the local
# file:// remote the way real makepkg's extract_git would (layout chosen by
# GSA_FAKE_VCS_LAYOUT) and leaves one nameable archive per packaged output.
# Source-less synthetic packages (multi-package workspaces' extra rows) just
# get their archive.
write_git_makepkg_stub() {
    cat >"$1/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -eu

git_config0() {
    GIT_CONFIG_COUNT=0 git "$@"
}

# One archive per packaged output: a split recipe must leave a COMPLETE set.
emit_archives() {
    local names=() n
    case $(declare -p pkgname 2>/dev/null || true) in
    'declare -a'*) names=("${pkgname[@]}") ;;
    *) names=("$id") ;;
    esac
    local stage="$PWD/.pkginfo-stage"
    mkdir -p "$stage"
    for n in "${names[@]}"; do
        printf 'pkgbase = %s\npkgname = %s\npkgver = 1.0.0\npkgrel = 1\narch = any\n' \
            "$id" "$n" >"$stage/.PKGINFO"
        tar --zstd -cf "$PWD/$n-1.0.0-1-any.pkg.tar.zst" -C "$stage" .PKGINFO
    done
    rm -rf "$stage"
}

id=$(basename "$PWD")
printf '%s\n' "$id" >>"${GSA_FAKE_MAKEPKG_COUNT:?}"
source "$PWD/PKGBUILD"
entry=${source[0]:-}
case $entry in
*git+file://*) ;;
"")
    emit_archives
    exit 0
    ;;
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
# selected layout.
if [[ -n $name_override ]]; then
    checkout_name=$name_override
else
    checkout_name=$remote
    # Real makepkg strips trailing slashes before taking the basename and
    # dropping .git (a `url=` ending in `/` is legal — the libyuv shape).
    while [[ $checkout_name == */ ]]; do checkout_name=${checkout_name%/}; done
    checkout_name=${checkout_name##*/}
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

# A nameable archive (the engine reads each archive's own .PKGINFO):
emit_archives
EOF
    chmod +x "$1/bin/makepkg"
}

make_non_git_workspace() { # $1 = workspace; $2 = svn|hg|bzr; $3 = optional fragment
    local dir=$1 protocol=$2 fragment=${3:-}
    local source="upstream::${protocol}+https://example.invalid/repo"
    [[ -n $fragment ]] && source+="#$fragment"
    local extra="$gsa_meta_any"$'\n'"source=(\"$source\")"$'\n'"sha256sums=('SKIP')"
    make_workspace_common "$dir"
    add_package "$dir" p1 "$extra"
    touch -d '2000-01-01 00:00:00 UTC' "$dir/packages/p1/PKGBUILD"

    cat >"$dir/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -eu
id=$(basename "$PWD")
printf '%s\n' "$id" >>"${GSA_FAKE_MAKEPKG_COUNT:?}"
mkdir -p "$PWD/upstream"
# A nameable archive (the engine reads each archive's own .PKGINFO):
stage="$PWD/.pkginfo-stage"
mkdir -p "$stage"
printf 'pkgbase = %s\npkgname = %s\npkgver = 1.0.0\npkgrel = 1\narch = any\n' \
    "$id" "$id" >"$stage/.PKGINFO"
tar --zstd -cf "$PWD/$id-1.0.0-1-any.pkg.tar.zst" -C "$stage" .PKGINFO
rm -rf "$stage"
EOF
    chmod +x "$dir/bin/makepkg"

    # The adapter stubs answer the ENGINE's probes (crates/gsa-recipe/
    # src/freshness.rs vcs_remote_revision / vcs_local_revision argv shapes):
    # remote revisions come from the URL-bearing call, the built revision from
    # the checkout-bearing call.
    cat >"$dir/bin/svn" <<'EOF'
#!/usr/bin/env bash
set -u
target=
for arg in "$@"; do target=$arg; done
if [[ $target == *://* ]]; then
    [[ " $* " == *' --revision '* ]] || exit 31
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
    [[ " $* " == *' --rev '* ]] || exit 33
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
}

# install_lsremote_stub $1 workspace — $1/lsremote.mode = off|once|always:
# `git ls-remote` fails per mode (exit 128 = transport failure, the retryable
# class) and counts every attempt; everything else execs the real git.
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

# ─── Engine driver (rr-v2.bash run_engine; family first, modifiers before
# targets) ──────────────────────────────────────────────────────────────────
run_case() { # $1 = workspace; then ENGINE argv: FAMILY+MODS… -- TARGETS…
    local dir=$1
    shift
    local mods=() targets=()
    while (( $# )) && [[ ${1:-} != -- ]]; do mods+=("$1"); shift; done
    (( $# )) && shift
    targets=("$@")
    if [[ -n ${GSA_VCS_SKIP_TOLERANCE+x} ]]; then
        export GSA_VCS_SKIP_TOLERANCE
    else
        unset GSA_VCS_SKIP_TOLERANCE 2>/dev/null || true
    fi
    local fixed=(--leaf --no-sync --allow-broken-rustc --no-prefetch)
    [[ ${mods[0]:-} == -M* ]] && fixed=()
    PATH="$dir/bin:$PATH" \
        GIT_CONFIG_COUNT=0 \
        GSA_FAKE_VCS_LAYOUT="${GSA_FAKE_VCS_LAYOUT:-root}" \
        GSA_FAKE_GCC_VERSION="${GSA_FAKE_GCC_VERSION:-fixture}" \
        GSA_FAKE_MAKEPKG_COUNT="$dir/makepkg.count" \
        GSA_FAKE_PACMAN_LOG="$dir/pacman.log" \
        GSA_FAKE_EXPECT_CLEAN="${GSA_FAKE_EXPECT_CLEAN:-0}" \
        GSA_FAKE_VCS_REMOTE_REV="${GSA_FAKE_VCS_REMOTE_REV:-}" \
        GSA_FAKE_VCS_BUILT_REV="${GSA_FAKE_VCS_BUILT_REV:-}" \
        GSA_STATE_DIR="$dir/state" \
        GSA_CPU_THREADS=8 \
        GSA_MEMORY_GIB=16 \
        run_engine "$dir" "${mods[@]}" "${fixed[@]}" "${targets[@]}"
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

# expect_claim PKG LABEL REASON — the `--skip` claim row shapes: plan
# `skip <reason>`, outcome `succeeded - - <reason>`, and no lane (rc and dur
# are `-`). The reason is the §H.3 claim key the caller names.
expect_claim() {
    local pkg=$1 label=$2 reason=$3
    expect_success "$label"
    [[ $(rr2_plan "$pkg" plan <<<"$FIXTURE_OUTPUT") == skip ]] ||
        fail "$label: plan row is not 'skip $reason':"$'\n'"$FIXTURE_OUTPUT"
    [[ $(rr2_plan "$pkg" reason <<<"$FIXTURE_OUTPUT") == "$reason" ]] ||
        fail "$label: plan reason is not '$reason':"$'\n'"$FIXTURE_OUTPUT"
    [[ $(rr2_outcome "$pkg" status <<<"$FIXTURE_OUTPUT") == succeeded ]] ||
        fail "$label: claim is not a succeeded row:"$'\n'"$FIXTURE_OUTPUT"
    [[ $(rr2_outcome "$pkg" rc <<<"$FIXTURE_OUTPUT") == - ]] ||
        fail "$label: a claim runs no lane (rc must be -):"$'\n'"$FIXTURE_OUTPUT"
    [[ $(rr2_outcome "$pkg" reason <<<"$FIXTURE_OUTPUT") == "$reason" ]] ||
        fail "$label: outcome reason is not '$reason':"$'\n'"$FIXTURE_OUTPUT"
}

# expect_built PKG LABEL — a completed build row: `succeeded 0 <dur> ok`.
expect_built() {
    local pkg=$1 label=$2
    expect_success "$label"
    [[ $(rr2_outcome "$pkg" status <<<"$FIXTURE_OUTPUT") == succeeded ]] ||
        fail "$label: build row is not succeeded:"$'\n'"$FIXTURE_OUTPUT"
    [[ $(rr2_outcome "$pkg" rc <<<"$FIXTURE_OUTPUT") == 0 ]] ||
        fail "$label: build row rc is not 0:"$'\n'"$FIXTURE_OUTPUT"
    [[ $(rr2_outcome "$pkg" reason <<<"$FIXTURE_OUTPUT") == ok ]] ||
        fail "$label: build row reason is not ok:"$'\n'"$FIXTURE_OUTPUT"
}

# ─── The help roster names the skip modes (§B.8) ────────────────────────────
skip_help=$("$GSA_TEST_GSA_BIN" --help 2>&1) || fail 'gsa help command failed'
for needle in '--skip' '--skip-built' '--vcs-skip-tolerance N' \
    'freshness-waived / abi-provider-waived'; do
    grep -Fq -- "$needle" <<<"$skip_help" ||
        fail "gsa --help does not describe the skip mode around '$needle'"
done

# ─── Branch-following recipe: unchanged-ref claim, claim-installs, moved-ref
# and newer-mtime rebuilds (each over its own staged set; the CLAIM DURABILITY
# section pins what a claim must leave behind) ───────────────────────────────
branch_dir=$fixture/branch
init_git_remote "$branch_dir/repository"
branch_remote=$branch_dir/repository/remote.git
branch_work=$branch_dir/repository/work
branch_entry="upstream::git+file://$branch_remote#branch=main"
branch_rev=$(git_fixture -C "$branch_work" rev-parse HEAD)

# 1. build → claim round trip: the recorder's baseline IS what the detector
#    accepts (the two runs share one workspace; the claim is the last run).
make_vcs_workspace "$branch_dir/ws-roundtrip" "$branch_remote" branch main
run_case "$branch_dir/ws-roundtrip" -B -- p1
expect_built p1 'initial branch build'
assert_makepkg_count "$branch_dir/ws-roundtrip" 1 'initial branch build'
[[ -f $branch_dir/ws-roundtrip/packages/p1/p1-1.0.0-1-any.pkg.tar.zst.gsa-vcs-revisions ]] ||
    fail 'the build did not record its VCS baseline'
run_case "$branch_dir/ws-roundtrip" -B --skip -- p1
expect_claim p1 'unchanged selected branch' ok
assert_makepkg_count "$branch_dir/ws-roundtrip" 1 'unchanged selected branch'
grep -Fq 'p1: already built' <<<"$FIXTURE_OUTPUT" ||
    fail 'the claim does not name the claimed set:'$'\n'"$FIXTURE_OUTPUT"

# 2. a claimed set INSTALLS (§B.8: no lane, but the install hook still runs)
#    while makepkg stays untouched: a real skip, never a build-then-install.
make_workspace_common "$branch_dir/ws-install"
add_package "$branch_dir/ws-install" p1 "$gsa_meta_any"$'\n'"source=(\"$branch_entry\")"$'\n'"sha256sums=('SKIP')"
stage_vcs_set "$branch_dir/ws-install" "$branch_entry" git "$branch_rev"
run_case "$branch_dir/ws-install" -S --skip --config "$branch_dir/ws-install/pacman.conf" -- p1
expect_claim p1 'unchanged branch with install' ok
assert_makepkg_count "$branch_dir/ws-install" 0 'unchanged branch with install'
grep -- 'pacman -U' "$branch_dir/ws-install/pacman.log" | grep -Fq 'p1-1.0.0-1-any.pkg.tar.zst' ||
    fail 'unchanged branch --skip -S did not install the claimed archive'
grep -q -- 'pacman -U' "$branch_dir/ws-install/pacman.log" ||
    fail 'unchanged branch --skip -S did not install at all'

# 3. a moved selected ref rebuilds. The move must clear the freshness
#    tolerance (5 commits): a waivable move would skip BY DESIGN, so the
#    trigger is paired with its control (case 2 above claims the same staged
#    state without the move).
make_workspace_common "$branch_dir/ws-moved"
add_package "$branch_dir/ws-moved" p1 "$gsa_meta_any"$'\n'"source=(\"$branch_entry\")"$'\n'"sha256sums=('SKIP')"
stage_vcs_set "$branch_dir/ws-moved" "$branch_entry" git "$branch_rev"
advance_main "$branch_work" 'advanced selected branch' 5
run_case "$branch_dir/ws-moved" -B --skip -- p1
expect_built p1 'advanced selected branch'
assert_makepkg_count "$branch_dir/ws-moved" 1 'advanced selected branch'
# the fresh baseline is what the NEXT claim reads (round trip again)
run_case "$branch_dir/ws-moved" -B --skip -- p1
expect_claim p1 'moved-ref rebuild then claim' ok
assert_makepkg_count "$branch_dir/ws-moved" 1 'moved-ref rebuild then claim'

# 4. a newer PKGBUILD mtime invalidates the set under --skip (the control is
#    case 2 again: the same staged set claims while its mtime is older).
make_workspace_common "$branch_dir/ws-mtime"
add_package "$branch_dir/ws-mtime" p1 "$gsa_meta_any"$'\n'"source=(\"$branch_entry\")"$'\n'"sha256sums=('SKIP')"
stage_vcs_set "$branch_dir/ws-mtime" "$branch_entry" git "$branch_rev"
touch -d '+1 day' "$branch_dir/ws-mtime/packages/p1/PKGBUILD"
run_case "$branch_dir/ws-mtime" -B --skip -- p1
expect_built p1 'newer PKGBUILD mtime'
assert_makepkg_count "$branch_dir/ws-mtime" 1 'newer PKGBUILD mtime'

# ─── GCC toolchain drift gate: a missing/changed identity marker forces the
# clean + rebuild even under --skip (tests/toolchain-drift.sh owns the
# stale-LTO half; this section pins the two messages at a skip claim) ───────
(
    set -euo pipefail
    drift_dir=$fixture/toolchain-drift
    init_git_remote "$drift_dir/repository"
    drift_remote=$drift_dir/repository/remote.git
    drift_entry="upstream::git+file://$drift_remote#branch=main"
    drift_rev=$(git_fixture -C "$drift_dir/repository/work" rev-parse HEAD)

    # missing marker: a claimable set still rebuilds (the one-time clean).
    make_workspace_common "$drift_dir/ws-missing"
    add_package "$drift_dir/ws-missing" p1 "$gsa_meta_any"$'\n'"source=(\"$drift_entry\")"$'\n'"sha256sums=('SKIP')"
    stage_vcs_set "$drift_dir/ws-missing" "$drift_entry" git "$drift_rev"
    rm -f "$drift_dir/ws-missing/state/toolchains/p1"
    GSA_FAKE_GCC_VERSION=1.0 run_case "$drift_dir/ws-missing" -B --skip -- p1
    expect_built p1 'drift: missing identity marker forces a rebuild'
    assert_makepkg_count "$drift_dir/ws-missing" 1 'drift: missing identity marker forces a rebuild'
    grep -Fq 'GCC build identity missing; cleaning cached build artifacts (one-time clean)' \
        <<<"$FIXTURE_OUTPUT" ||
        fail 'drift: the one-time clean message is missing or reworded:'$'\n'"$FIXTURE_OUTPUT"

    # changed marker: the message names the previous AND current identities.
    make_workspace_common "$drift_dir/ws-changed"
    add_package "$drift_dir/ws-changed" p1 "$gsa_meta_any"$'\n'"source=(\"$drift_entry\")"$'\n'"sha256sums=('SKIP')"
    stage_vcs_set "$drift_dir/ws-changed" "$drift_entry" git "$drift_rev"
    mkdir -p "$drift_dir/ws-changed/state/toolchains"
    printf '%s\n' 'gcc (fixture) 0.9' >"$drift_dir/ws-changed/state/toolchains/p1"
    GSA_FAKE_GCC_VERSION=1.0 run_case "$drift_dir/ws-changed" -B --skip -- p1
    expect_built p1 'drift: changed identity marker forces a rebuild'
    assert_makepkg_count "$drift_dir/ws-changed" 1 'drift: changed identity marker forces a rebuild'
    grep -Fq 'GCC build identity missing or changed; cleaning cached build artifacts (previous: gcc (fixture) 0.9; current: gcc (fixture) 1.0)' \
        <<<"$FIXTURE_OUTPUT" ||
        fail 'drift: the change message does not name both identities:'$'\n'"$FIXTURE_OUTPUT"

    # unchanged marker: the gate is quiet and the claim stands (control).
    # The staged marker must be the identity this run's gcc stub REPORTS
    # (GSA_FAKE_GCC_VERSION=1.0), not the fixture default.
    make_workspace_common "$drift_dir/ws-unchanged"
    add_package "$drift_dir/ws-unchanged" p1 "$gsa_meta_any"$'\n'"source=(\"$drift_entry\")"$'\n'"sha256sums=('SKIP')"
    stage_vcs_set "$drift_dir/ws-unchanged" "$drift_entry" git "$drift_rev"
    stage_marker "$drift_dir/ws-unchanged" 'gcc (fixture) 1.0'
    GSA_FAKE_GCC_VERSION=1.0 run_case "$drift_dir/ws-unchanged" -B --skip -- p1
    expect_claim p1 'drift: unchanged identity keeps the claim' ok
    assert_makepkg_count "$drift_dir/ws-unchanged" 0 'drift: unchanged identity keeps the claim'
)

# ─── Legacy archives and the recorded baseline ──────────────────────────────
# A fresh legacy archive cannot be trusted without a recorded build revision:
# the engine rebuilds ONCE to record one — but only after confirming the
# declared refs are queryable (the deferral section below owns the offline
# shape). The recorded baseline is then exactly what the next claim accepts.
legacy_dir=$fixture/missing-baseline
init_git_remote "$legacy_dir/repository"
legacy_remote=$legacy_dir/repository/remote.git
legacy_entry="upstream::git+file://$legacy_remote#branch=main"
legacy_rev=$(git_fixture -C "$legacy_dir/repository/work" rev-parse HEAD)
make_vcs_workspace "$legacy_dir/workspace" "$legacy_remote" branch main
archive=$legacy_dir/workspace/packages/p1/p1-1.0.0-1-any.pkg.tar.zst
pkginfo_archive "$archive" p1
touch -d '2000-01-01 00:00:00 UTC' "$legacy_dir/workspace/packages/p1/PKGBUILD"
run_case "$legacy_dir/workspace" -B --skip -- p1
expect_built p1 'legacy archive rebuilds once to record its baseline'
assert_makepkg_count "$legacy_dir/workspace" 1 'legacy archive rebuild'
[[ -f $archive.gsa-vcs-revisions ]] ||
    fail 'legacy archive rebuild did not record its VCS baseline'
grep -Fq $'gsa-vcs-revisions\t2' "$archive.gsa-vcs-revisions" ||
    fail 'the recorded baseline is not manifest format 2'
run_case "$legacy_dir/workspace" -B --skip -- p1
expect_claim p1 'legacy archive skips after recording its baseline' ok
assert_makepkg_count "$legacy_dir/workspace" 1 'legacy archive subsequent skip'

# A malformed baseline is not half-trusted: the run rebuilds and the rebuilt
# manifest replaces the malformed one (staged in its own workspace so the
# malformed record is unambiguously the trigger — the control is the claim
# above over a well-formed record).
malformed_dir=$fixture/malformed-baseline
init_git_remote "$malformed_dir/repository"
make_vcs_workspace "$malformed_dir/workspace" "$malformed_dir/repository/remote.git" branch main
archive=$malformed_dir/workspace/packages/p1/p1-1.0.0-1-any.pkg.tar.zst
pkginfo_archive "$archive" p1
printf 'malformed VCS baseline\n' >"$archive.gsa-vcs-revisions"
touch -d '2000-01-01 00:00:00 UTC' "$malformed_dir/workspace/packages/p1/PKGBUILD"
run_case "$malformed_dir/workspace" -B --skip -- p1
expect_built p1 'malformed legacy baseline triggers a rebuild'
assert_makepkg_count "$malformed_dir/workspace" 1 'malformed legacy baseline rebuild'
grep -Fq $'gsa-vcs-revisions\t2' "$archive.gsa-vcs-revisions" ||
    fail 'malformed legacy baseline was not replaced after rebuilding'

# ─── Unverifiable upstream: park the recipe, hold its consumers, keep going ─
# A missing baseline does not license a skip or a build when upstream cannot
# be queried: the refusal happens BEFORE makepkg (and before the drift clean
# destroys the evidence — the ordering hard rule).
legacy_offline_dir=$fixture/missing-baseline-offline
init_git_remote "$legacy_offline_dir/repository"
legacy_offline_remote=$legacy_offline_dir/repository/remote.git
make_vcs_workspace "$legacy_offline_dir/workspace" "$legacy_offline_remote" branch main
pkginfo_archive "$legacy_offline_dir/workspace/packages/p1/p1-1.0.0-1-any.pkg.tar.zst" p1
touch -d '2000-01-01 00:00:00 UTC' "$legacy_offline_dir/workspace/packages/p1/PKGBUILD"
mv "$legacy_offline_remote" "$legacy_offline_dir/repository/remote.offline"
run_case "$legacy_offline_dir/workspace" -B --skip -- p1
if ((FIXTURE_RC == 0)); then
    fail "unreachable legacy upstream reported a green run:"$'\n'"$FIXTURE_OUTPUT"
fi
assert_makepkg_count "$legacy_offline_dir/workspace" 0 \
    'unreachable legacy upstream (a parked recipe must not run makepkg)'
[[ $(rr2_outcome p1 status <<<"$FIXTURE_OUTPUT") == deferred ]] ||
    fail "unreachable legacy upstream: p1 is not deferred:"$'\n'"$FIXTURE_OUTPUT"
[[ $(rr2_outcome p1 rc <<<"$FIXTURE_OUTPUT") == 99 ]] ||
    fail "unreachable legacy upstream: a deferral is lane code 99:"$'\n'"$FIXTURE_OUTPUT"
[[ $(rr2_outcome p1 reason <<<"$FIXTURE_OUTPUT") == upstream-unverified ]] ||
    fail "unreachable legacy upstream: deferral reason is not upstream-unverified:"$'\n'"$FIXTURE_OUTPUT"
[[ $FIXTURE_RC == 5 && $(rr2_scalar rc <<<"$FIXTURE_OUTPUT") == 5 ]] ||
    fail "a deferral-only run exits 5 (§G.1), got rc=$FIXTURE_RC:"$'\n'"$FIXTURE_OUTPUT"
if ! grep -Fq 'p1' <<<"$FIXTURE_OUTPUT" ||
    ! grep -Eiq 'cannot query|upstream|remote' <<<"$FIXTURE_OUTPUT"; then
    fail 'unreachable legacy upstream did not report a package-specific VCS freshness warning:'$'\n'"$FIXTURE_OUTPUT"
fi

# A previously recorded baseline cannot license a skip when the selected
# remote ref is no longer queryable either: same deferral, evidence intact.
unreachable_dir=$fixture/unreachable
init_git_remote "$unreachable_dir/repository"
unreachable_rev=$(git_fixture -C "$unreachable_dir/repository/work" rev-parse HEAD)
make_vcs_workspace "$unreachable_dir/workspace" "$unreachable_dir/repository/remote.git" branch main
stage_vcs_set "$unreachable_dir/workspace" "upstream::git+file://$unreachable_dir/repository/remote.git#branch=main" \
    git "$unreachable_rev"
mv "$unreachable_dir/repository/remote.git" "$unreachable_dir/repository/remote.offline"
run_case "$unreachable_dir/workspace" -B --skip -- p1
if ((FIXTURE_RC == 0)); then
    fail "unreachable upstream reported a green run:"$'\n'"$FIXTURE_OUTPUT"
fi
assert_makepkg_count "$unreachable_dir/workspace" 0 'unreachable upstream'
[[ $(rr2_outcome p1 status <<<"$FIXTURE_OUTPUT") == deferred &&
    $(rr2_outcome p1 rc <<<"$FIXTURE_OUTPUT") == 99 &&
    $(rr2_outcome p1 reason <<<"$FIXTURE_OUTPUT") == upstream-unverified ]] ||
    fail "unreachable upstream row is not 'deferred 99 - upstream-unverified':"$'\n'"$FIXTURE_OUTPUT"

# ─── Transport failures: classify, retry, DEFER — never fail the run ────────
# A momentary `git ls-remote` transport error (TLS flake, NOT a moved ref)
# must not fail the package or the run:
#   * a transient failure is retried and, once answered, the normal skip /
#     moved-ref decisions apply unchanged;
#   * a persistent failure PARKS the recipe when its consumer chain can
#     absorb the wait (waiter cap 3), reason upstream-unverified, dependents
#     honestly held, run continues;
#   * a heavy or unresolvable consumer chain falls back to a NORMAL BUILD
#     attempt: the recipe builds (or fails on its own merits) and installs
#     under -S — never silently skips, never parks what others need.
T1_dir=$fixture/flaky-skip
init_git_remote "$T1_dir/repository"
make_vcs_workspace "$T1_dir/workspace" "$T1_dir/repository/remote.git" branch main
install_lsremote_stub "$T1_dir/workspace"
stage_vcs_set "$T1_dir/workspace" "upstream::git+file://$T1_dir/repository/remote.git#branch=main" \
    git "$(git_fixture -C "$T1_dir/repository/work" rev-parse HEAD)"
printf 'once' >"$T1_dir/workspace/lsremote.mode"
run_case "$T1_dir/workspace" -S --skip --config "$T1_dir/workspace/pacman.conf" -- p1
expect_claim p1 'flaky transport recovers into a normal skip' ok
assert_makepkg_count "$T1_dir/workspace" 0 'flaky transport skip must not rebuild'
attempts=$(lsremote_attempts "$T1_dir/workspace")
((attempts >= 2)) ||
    fail "flaky transport: expected a retry, saw $attempts ls-remote attempt(s)"
grep -- 'pacman -U' "$T1_dir/workspace/pacman.log" | grep -Fq 'p1-1.0.0-1-any.pkg.tar.zst' ||
    fail 'flaky transport skip did not install the claimed archive'

T2_dir=$fixture/flaky-moved
init_git_remote "$T2_dir/repository"
make_vcs_workspace "$T2_dir/workspace" "$T2_dir/repository/remote.git" branch main
install_lsremote_stub "$T2_dir/workspace"
stage_vcs_set "$T2_dir/workspace" "upstream::git+file://$T2_dir/repository/remote.git#branch=main" \
    git "$(git_fixture -C "$T2_dir/repository/work" rev-parse HEAD)"
advance_main "$T2_dir/repository/work" 'advanced while transport was flaky' 5
printf 'once' >"$T2_dir/workspace/lsremote.mode"
run_case "$T2_dir/workspace" -B --skip -- p1
expect_built p1 'flaky transport still detects a moved ref'
assert_makepkg_count "$T2_dir/workspace" 1 'moved ref after a flaky attempt must rebuild, not skip'
attempts=$(lsremote_attempts "$T2_dir/workspace")
((attempts >= 2)) ||
    fail "flaky-moved: expected a retry, saw $attempts ls-remote attempt(s)"

# T3: the upstream NEVER answers and p1's only consumer (p2) can wait — p1
# parks (defer, not fail, not skip), p2 holds with it, p3 keeps building and
# installs. `-S` is deliberate: the parked package must never reach pacman.
T3_dir=$fixture/defer-dispatch
init_git_remote "$T3_dir/repository"
make_vcs_workspace "$T3_dir/workspace" "$T3_dir/repository/remote.git" branch main
add_package "$T3_dir/workspace" p2 "$gsa_meta_any"
set_topology_record "$T3_dir/workspace" p2 git 'p1'
add_package "$T3_dir/workspace" p3 "$gsa_meta_any"
# The workspace stub only understands the VCS shape; route plain packages
# (p2/p3) to a trivial archive writer and keep the VCS stub for p1.
mv "$T3_dir/workspace/bin/makepkg" "$T3_dir/workspace/bin/makepkg.vcs"
cat >"$T3_dir/workspace/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -eu
if grep -q 'git+file://' "$PWD/PKGBUILD" 2>/dev/null; then
    exec "$(dirname "$0")/makepkg.vcs" "$@"
fi
id=$(basename "$PWD")
printf '%s\n' "$id" >>"${GSA_FAKE_MAKEPKG_COUNT:?}"
# A nameable archive (the engine reads each archive's own .PKGINFO):
stage="$PWD/.pkginfo-stage"
mkdir -p "$stage"
printf 'pkgbase = %s\npkgname = %s\npkgver = 1.0.0\npkgrel = 1\narch = any\n' \
    "$id" "$id" >"$stage/.PKGINFO"
tar --zstd -cf "$PWD/$id-1.0.0-1-any.pkg.tar.zst" -C "$stage" .PKGINFO
rm -rf "$stage"
EOF
chmod +x "$T3_dir/workspace/bin/makepkg"
install_lsremote_stub "$T3_dir/workspace"
stage_vcs_set "$T3_dir/workspace" "upstream::git+file://$T3_dir/repository/remote.git#branch=main" \
    git "$(git_fixture -C "$T3_dir/repository/work" rev-parse HEAD)"
printf 'always' >"$T3_dir/workspace/lsremote.mode"
run_case "$T3_dir/workspace" -S --skip --config "$T3_dir/workspace/pacman.conf" -- p1 p2 p3
if ((FIXTURE_RC == 0)); then
    fail "persistent transport failure reported a green run:"$'\n'"$FIXTURE_OUTPUT"
fi
attempts=$(lsremote_attempts "$T3_dir/workspace")
((attempts >= 3)) ||
    fail "persistent transport: expected the full retry window, saw $attempts attempt(s)"
[[ $(rr2_outcome p1 status <<<"$FIXTURE_OUTPUT") == deferred ]] ||
    fail "T3: p1 is not deferred:"$'\n'"$FIXTURE_OUTPUT"
[[ $(rr2_outcome p1 rc <<<"$FIXTURE_OUTPUT") == 99 ]] ||
    fail "T3: a deferral is lane code 99:"$'\n'"$FIXTURE_OUTPUT"
[[ $(rr2_outcome p1 reason <<<"$FIXTURE_OUTPUT") == upstream-unverified ]] ||
    fail "T3: p1 deferral reason is not upstream-unverified:"$'\n'"$FIXTURE_OUTPUT"
grep -Fq 'cannot verify upstream VCS freshness' <<<"$FIXTURE_OUTPUT" ||
    fail "T3: the run output lost the freshness warning:"$'\n'"$FIXTURE_OUTPUT"
grep -Fq 'parking this recipe' <<<"$FIXTURE_OUTPUT" ||
    fail "T3: the run output does not name the parking decision:"$'\n'"$FIXTURE_OUTPUT"
[[ $(rr2_outcome p3 status <<<"$FIXTURE_OUTPUT") == succeeded ]] ||
    fail "T3: p3 did not build while p1 was deferred:"$'\n'"$FIXTURE_OUTPUT"
grep -Eq '^p3 succeeded 0 [0-9]+ ok$' <(rr2_outcome_rows <<<"$FIXTURE_OUTPUT") ||
    fail "T3: p3's row is not a completed build:"$'\n'"$FIXTURE_OUTPUT"
[[ $(rr2_outcome p2 status <<<"$FIXTURE_OUTPUT") == parked ]] ||
    fail "T3: p2 is not parked with the deferral:"$'\n'"$FIXTURE_OUTPUT"
[[ $(rr2_outcome p2 reason <<<"$FIXTURE_OUTPUT") == waits-on-deferred ]] ||
    fail "T3: p2 must carry waits-on-deferred (§H.3):"$'\n'"$FIXTURE_OUTPUT"
[[ $(rr2_outcome p2 rc <<<"$FIXTURE_OUTPUT") == - ]] ||
    fail "T3: a parked consumer never ran a lane (rc must be -):"$'\n'"$FIXTURE_OUTPUT"
assert_makepkg_count "$T3_dir/workspace" 1 'only p3 may build while p1 is deferred'
if grep -q '^p1$' "$T3_dir/workspace/makepkg.count" 2>/dev/null; then
    fail 'p1 built again despite its unverifiable upstream'
fi
if grep -q '^p2$' "$T3_dir/workspace/makepkg.count" 2>/dev/null; then
    fail 'p2 was dispatched although its prerequisite p1 is parked'
fi
if grep -- 'pacman -U' "$T3_dir/workspace/pacman.log" 2>/dev/null |
    grep -F 'p1-1.0.0-1-any.pkg.tar.zst'; then
    fail 'p1 archive was installed although upstream never answered'
fi
grep -- 'pacman -U' "$T3_dir/workspace/pacman.log" | grep -Fq 'p3-1.0.0-1-any.pkg.tar.zst' ||
    fail 'p3 did not install under -S while p1 was parked'

# T4: a heavily-consumed recipe cannot park — the fallback is a normal build
# attempt (owner semantics): with a big consumer chain (waiter cap 3), an
# unverifiable upstream must NOT strand the packages that need it.
T4_dir=$fixture/heavy-consumers
init_git_remote "$T4_dir/repository"
make_vcs_workspace "$T4_dir/workspace" "$T4_dir/repository/remote.git" branch main
for id in p2 p3 p4 p5 p6; do
    add_package "$T4_dir/workspace" "$id" "$gsa_meta_any"
    set_topology_record "$T4_dir/workspace" "$id" git 'p1'
done
mv "$T4_dir/workspace/bin/makepkg" "$T4_dir/workspace/bin/makepkg.vcs"
cat >"$T4_dir/workspace/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -eu
if grep -q 'git+file://' "$PWD/PKGBUILD" 2>/dev/null; then
    exec "$(dirname "$0")/makepkg.vcs" "$@"
fi
id=$(basename "$PWD")
printf '%s\n' "$id" >>"${GSA_FAKE_MAKEPKG_COUNT:?}"
# A nameable archive (the engine reads each archive's own .PKGINFO):
stage="$PWD/.pkginfo-stage"
mkdir -p "$stage"
printf 'pkgbase = %s\npkgname = %s\npkgver = 1.0.0\npkgrel = 1\narch = any\n' \
    "$id" "$id" >"$stage/.PKGINFO"
tar --zstd -cf "$PWD/$id-1.0.0-1-any.pkg.tar.zst" -C "$stage" .PKGINFO
rm -rf "$stage"
EOF
chmod +x "$T4_dir/workspace/bin/makepkg"
install_lsremote_stub "$T4_dir/workspace"
stage_vcs_set "$T4_dir/workspace" "upstream::git+file://$T4_dir/repository/remote.git#branch=main" \
    git "$(git_fixture -C "$T4_dir/repository/work" rev-parse HEAD)"
printf 'always' >"$T4_dir/workspace/lsremote.mode"
run_case "$T4_dir/workspace" -S --skip --config "$T4_dir/workspace/pacman.conf" -- p1 p2 p3 p4 p5 p6
expect_success 'persistent failure on a heavily-consumed recipe falls back to building'
expect_built p1 'heavy fallback build'
grep -Fq 'cannot verify upstream VCS freshness' <<<"$FIXTURE_OUTPUT" ||
    fail "heavy p1's run output lost the freshness warning:"$'\n'"$FIXTURE_OUTPUT"
grep -Fq 'consumers cannot wait' <<<"$FIXTURE_OUTPUT" ||
    fail "heavy p1's run output does not name the fallback decision:"$'\n'"$FIXTURE_OUTPUT"
for id in p2 p3 p4 p5 p6; do
    expect_built "$id" "$id behind the fallback"
done
assert_makepkg_count "$T4_dir/workspace" 6 'fallback build plus all five consumers'
grep -- 'pacman -U' "$T4_dir/workspace/pacman.log" | grep -Fq 'p1-1.0.0-1-any.pkg.tar.zst' ||
    fail 'the fallback-built p1 archive did not install under -S'

# ─── Selected-ref semantics: a tag pin follows the declared tag; an
# unqualified source tracks the remote's default HEAD ───────────────────────
pinned_dir=$fixture/pinned
init_git_remote "$pinned_dir/repository"
pinned_work=$pinned_dir/repository/work
git_fixture -C "$pinned_work" tag -a v1.0.0 -m 'fixture release tag'
git_fixture -C "$pinned_work" push origin refs/tags/v1.0.0 >/dev/null
pinned_entry="upstream::git+file://$pinned_dir/repository/remote.git#tag=v1.0.0"
pinned_rev=$(git_fixture -C "$pinned_work" rev-parse 'v1.0.0^{}')

# unrelated branch movement never moves the pin (claim).
make_workspace_common "$pinned_dir/ws-still"
add_package "$pinned_dir/ws-still" p1 "$gsa_meta_any"$'\n'"source=(\"$pinned_entry\")"$'\n'"sha256sums=('SKIP')"
stage_vcs_set "$pinned_dir/ws-still" "$pinned_entry" git "$pinned_rev"
advance_main "$pinned_work" 'unrelated main branch movement'
run_case "$pinned_dir/ws-still" -B --skip -- p1
expect_claim p1 'unrelated branch movement for pinned source' ok
assert_makepkg_count "$pinned_dir/ws-still" 0 'unrelated branch movement for pinned source'

# A moved pin is a Git advance like any other: the re-tag below lands past the
# freshness tolerance, so the rebuild must happen.
make_workspace_common "$pinned_dir/ws-moved"
add_package "$pinned_dir/ws-moved" p1 "$gsa_meta_any"$'\n'"source=(\"$pinned_entry\")"$'\n'"sha256sums=('SKIP')"
stage_vcs_set "$pinned_dir/ws-moved" "$pinned_entry" git "$pinned_rev"
advance_main "$pinned_work" 'tag retag groundwork' 5
git_fixture -C "$pinned_work" tag --force -a v1.0.0 -m 'moved fixture release tag'
git_fixture -C "$pinned_work" push --force origin refs/tags/v1.0.0 >/dev/null
run_case "$pinned_dir/ws-moved" -B --skip -- p1
expect_built p1 'selected tag moved'
assert_makepkg_count "$pinned_dir/ws-moved" 1 'selected tag moved'

# An unqualified Git source tracks the remote's default HEAD.
default_dir=$fixture/default-head
init_git_remote "$default_dir/repository"
default_entry="upstream::git+file://$default_dir/repository/remote.git"
default_rev=$(git_fixture -C "$default_dir/repository/work" rev-parse HEAD)
make_workspace_common "$default_dir/ws-still"
add_package "$default_dir/ws-still" p1 "$gsa_meta_any"$'\n'"source=(\"$default_entry\")"$'\n'"sha256sums=('SKIP')"
stage_vcs_set "$default_dir/ws-still" "$default_entry" git "$default_rev"
run_case "$default_dir/ws-still" -B --skip -- p1
expect_claim p1 'unchanged default HEAD' ok
assert_makepkg_count "$default_dir/ws-still" 0 'unchanged default HEAD'

make_workspace_common "$default_dir/ws-moved"
add_package "$default_dir/ws-moved" p1 "$gsa_meta_any"$'\n'"source=(\"$default_entry\")"$'\n'"sha256sums=('SKIP')"
stage_vcs_set "$default_dir/ws-moved" "$default_entry" git "$default_rev"
# 5 commits: past the freshness tolerance, so the move still rebuilds.
advance_main "$default_dir/repository/work" 'advanced default HEAD' 5
run_case "$default_dir/ws-moved" -B --skip -- p1
expect_built p1 'advanced default HEAD'
assert_makepkg_count "$default_dir/ws-moved" 1 'advanced default HEAD'

# ─── Freshness tolerance: --skip must not rebuild over a handful of commits ─
# Owner design (2026-10-03): "a fewer than 5 commits is senseless especially
# for these heavy packages since we aren't actively participating in
# development in these important projects" — we are CONSUMERS of llvm/rust/qt6,
# not their developers. A measured advance STRICTLY BELOW the tolerance
# (default 5, overridable via GSA_VCS_SKIP_TOLERANCE / --vcs-skip-tolerance)
# keeps the skip and says so LOUDLY; at the boundary (the boundary is AT 5)
# and beyond — including past the shallow measurement window — the rebuild
# happens exactly as before.
tolerance_dir=$fixture/freshness-tolerance
init_git_remote "$tolerance_dir/repository"
tolerance_work=$tolerance_dir/repository/work
tolerance_entry="upstream::git+file://$tolerance_dir/repository/remote.git#branch=main"
# Each case stages the baseline its measured advance is relative to: the
# cases share one remote that advances cumulatively, so a section-start
# capture would make every later case's move larger than its label says.

# 3 commits (< 5): the skip HOLDS — the run runs makepkg 0 times — and the
# waiver is a named line plus a freshness-waived claim row, never a silent
# lowering of verification.
make_workspace_common "$tolerance_dir/ws-under"
add_package "$tolerance_dir/ws-under" p1 "$gsa_meta_any"$'\n'"source=(\"$tolerance_entry\")"$'\n'"sha256sums=('SKIP')"
stage_vcs_set "$tolerance_dir/ws-under" "$tolerance_entry" git \
    "$(git_fixture -C "$tolerance_work" rev-parse HEAD)"
advance_main "$tolerance_work" 'tolerance noise' 3
run_case "$tolerance_dir/ws-under" -B --skip -- p1
expect_claim p1 'three-commit advance keeps the skip' freshness-waived
assert_makepkg_count "$tolerance_dir/ws-under" 0 'three-commit advance: the run must run makepkg 0 times'
grep -Fq 'upstream moved 3 commit(s) < tolerance 5 — treating upstream as current' \
    <<<"$FIXTURE_OUTPUT" ||
    fail 'three-commit advance did not print the named freshness waiver line:'$'\n'"$FIXTURE_OUTPUT"

# Exactly 5: the boundary is AT the tolerance — rebuild.
make_workspace_common "$tolerance_dir/ws-boundary"
add_package "$tolerance_dir/ws-boundary" p1 "$gsa_meta_any"$'\n'"source=(\"$tolerance_entry\")"$'\n'"sha256sums=('SKIP')"
stage_vcs_set "$tolerance_dir/ws-boundary" "$tolerance_entry" git \
    "$(git_fixture -C "$tolerance_work" rev-parse HEAD)"
advance_main "$tolerance_work" 'tolerance boundary' 5
run_case "$tolerance_dir/ws-boundary" -B --skip -- p1
expect_built p1 'exactly five commits rebuilds'
assert_makepkg_count "$tolerance_dir/ws-boundary" 1 'the boundary is AT 5: exactly five commits must rebuild'

# 10 commits: past the fetch window (depth = tolerance + 1 = 6), where the
# baseline is unreachable in the probe repo — that failure must read as
# ">= tolerance", i.e. rebuild, never as a skip.
make_workspace_common "$tolerance_dir/ws-far"
add_package "$tolerance_dir/ws-far" p1 "$gsa_meta_any"$'\n'"source=(\"$tolerance_entry\")"$'\n'"sha256sums=('SKIP')"
stage_vcs_set "$tolerance_dir/ws-far" "$tolerance_entry" git \
    "$(git_fixture -C "$tolerance_work" rev-parse HEAD)"
advance_main "$tolerance_work" 'past the measurement window' 10
run_case "$tolerance_dir/ws-far" -B --skip -- p1
expect_built p1 'ten-commit advance rebuilds'
assert_makepkg_count "$tolerance_dir/ws-far" 1 'ten-commit advance must rebuild (baseline outside the fetch window)'

# GSA_VCS_SKIP_TOLERANCE overrides the default (positive integers only).
override_dir=$fixture/freshness-override
init_git_remote "$override_dir/repository"
override_work=$override_dir/repository/work
override_entry="upstream::git+file://$override_dir/repository/remote.git#branch=main"
# Per-case baselines again: the shared remote advances cumulatively.

make_workspace_common "$override_dir/ws-two"
add_package "$override_dir/ws-two" p1 "$gsa_meta_any"$'\n'"source=(\"$override_entry\")"$'\n'"sha256sums=('SKIP')"
stage_vcs_set "$override_dir/ws-two" "$override_entry" git \
    "$(git_fixture -C "$override_work" rev-parse HEAD)"
advance_main "$override_work" 'override noise' 1
GSA_VCS_SKIP_TOLERANCE=2 run_case "$override_dir/ws-two" -B --skip -- p1
expect_claim p1 'tolerance 2 waives a one-commit move' freshness-waived
assert_makepkg_count "$override_dir/ws-two" 0 'tolerance 2 must waive a one-commit move'
grep -Fq 'upstream moved 1 commit(s) < tolerance 2 — treating upstream as current' \
    <<<"$FIXTURE_OUTPUT" ||
    fail 'tolerance 2 waiver line is missing or names the wrong tolerance:'$'\n'"$FIXTURE_OUTPUT"

make_workspace_common "$override_dir/ws-boundary"
add_package "$override_dir/ws-boundary" p1 "$gsa_meta_any"$'\n'"source=(\"$override_entry\")"$'\n'"sha256sums=('SKIP')"
stage_vcs_set "$override_dir/ws-boundary" "$override_entry" git \
    "$(git_fixture -C "$override_work" rev-parse HEAD)"
advance_main "$override_work" 'override boundary' 2
GSA_VCS_SKIP_TOLERANCE=2 run_case "$override_dir/ws-boundary" -B --skip -- p1
expect_built p1 'tolerance 2 boundary rebuilds'
assert_makepkg_count "$override_dir/ws-boundary" 1 'the override boundary is AT 2: two commits must rebuild'

# A garbage value falls back to the default 5, LOUDLY: the fallback is
# observable in the effective waiver (3 < 5 keeps the skip) and the resolver's
# rejection line is pinned in the same run output.
make_workspace_common "$override_dir/ws-garbage"
add_package "$override_dir/ws-garbage" p1 "$gsa_meta_any"$'\n'"source=(\"$override_entry\")"$'\n'"sha256sums=('SKIP')"
stage_vcs_set "$override_dir/ws-garbage" "$override_entry" git \
    "$(git_fixture -C "$override_work" rev-parse HEAD)"
advance_main "$override_work" 'garbage knob' 3
GSA_VCS_SKIP_TOLERANCE=banana run_case "$override_dir/ws-garbage" -B --skip -- p1
expect_claim p1 'garbage tolerance falls back to the default' freshness-waived
assert_makepkg_count "$override_dir/ws-garbage" 0 'a garbage tolerance must not shrink the default below 5'
grep -Fq "GSA_VCS_SKIP_TOLERANCE='banana' is not a positive integer — using the default 5" \
    <<<"$FIXTURE_OUTPUT" ||
    fail 'a garbage tolerance was not rejected loudly:'$'\n'"$FIXTURE_OUTPUT"
grep -Fq 'upstream moved 3 commit(s) < tolerance 5 — treating upstream as current' \
    <<<"$FIXTURE_OUTPUT" ||
    fail 'the garbage-tolerance run did not fall back to the default 5:'$'\n'"$FIXTURE_OUTPUT"

# ─── ABI providers: never rebuild a matched ABI provider on mere movement ───
# Owner rule (2026-10-03): "not building the already built abi provider which
# is extremely heavy" — llvm-git is the matched ABI provider: rebuilding it
# invalidates every dependent's ABI and costs hours, while llvm-project lands
# dozens of commits an hour, so NO tolerance can ever rescue it. A recipe
# carrying a .gsa-abi-provider marker is therefore WAIVED on any upstream
# movement — the verdict is "freshness waived", not "tolerated" — loudly,
# with the claim on the run-record row. The exemption is only the skip check:
# a missing baseline still rebuilds once, and an explicit build rebuilds.
abi_dir=$fixture/abi-provider
init_git_remote "$abi_dir/repository"
abi_work=$abi_dir/repository/work
abi_entry="upstream::git+file://$abi_dir/repository/remote.git#branch=main"
abi_rev=$(git_fixture -C "$abi_work" rev-parse HEAD)

make_workspace_common "$abi_dir/ws-waive"
add_package "$abi_dir/ws-waive" p1 "$gsa_meta_any"$'\n'"source=(\"$abi_entry\")"$'\n'"sha256sums=('SKIP')"
printf 'fixture rationale: matched ABI provider\n' >"$abi_dir/ws-waive/packages/p1/.gsa-abi-provider"
stage_vcs_set "$abi_dir/ws-waive" "$abi_entry" git "$abi_rev"
advance_main "$abi_work" 'abi upstream churn' 30
run_case "$abi_dir/ws-waive" -B --skip -- p1
expect_claim p1 'marked recipe waives thirty commits of movement' abi-provider-waived
assert_makepkg_count "$abi_dir/ws-waive" 0 'marked recipe: the run must run makepkg 0 times'
grep -Fq 'upstream moved 30 commit(s) — p1 is an ABI provider; freshness waived (rebuild only on measured skew or an explicit build)' \
    <<<"$FIXTURE_OUTPUT" ||
    fail 'the ABI waiver line does not name the recipe and the commit count:'$'\n'"$FIXTURE_OUTPUT"

# The exemption is only the skip check: an explicit build rebuilds normally.
run_case "$abi_dir/ws-waive" -B -- p1
expect_built p1 'explicit build still rebuilds a marked recipe'
assert_makepkg_count "$abi_dir/ws-waive" 1 'explicit build must rebuild despite the marker'

# Control: the SAME recipe shape without the marker and the same 30 commits of
# movement must rebuild — the marker is what waives, not the distance.
abi_ctrl_dir=$fixture/abi-control
init_git_remote "$abi_ctrl_dir/repository"
abi_ctrl_rev=$(git_fixture -C "$abi_ctrl_dir/repository/work" rev-parse HEAD)
make_vcs_workspace "$abi_ctrl_dir/workspace" "$abi_ctrl_dir/repository/remote.git" branch main
stage_vcs_set "$abi_ctrl_dir/workspace" "upstream::git+file://$abi_ctrl_dir/repository/remote.git#branch=main" \
    git "$abi_ctrl_rev"
advance_main "$abi_ctrl_dir/repository/work" 'abi control churn' 30
run_case "$abi_ctrl_dir/workspace" -B --skip -- p1
expect_built p1 'unmarked recipe rebuilds after thirty commits'
assert_makepkg_count "$abi_ctrl_dir/workspace" 1 'the MARKER is what waives: an unmarked 30-commit move must rebuild'

# A marked recipe with no recorded baseline still rebuilds once (the waiver is
# purely the movement verdict — the rebuild-to-record class is not waived).
abi_base_dir=$fixture/abi-missing-baseline
init_git_remote "$abi_base_dir/repository"
make_vcs_workspace "$abi_base_dir/workspace" "$abi_base_dir/repository/remote.git" branch main
printf 'fixture rationale: matched ABI provider\n' >"$abi_base_dir/workspace/packages/p1/.gsa-abi-provider"
pkginfo_archive "$abi_base_dir/workspace/packages/p1/p1-1.0.0-1-any.pkg.tar.zst" p1
touch -d '2000-01-01 00:00:00 UTC' "$abi_base_dir/workspace/packages/p1/PKGBUILD"
run_case "$abi_base_dir/workspace" -B --skip -- p1
expect_built p1 'marked recipe rebuilds once on a missing baseline'
assert_makepkg_count "$abi_base_dir/workspace" 1 'marked missing-baseline rebuild (baseline class intact)'
[[ -f $abi_base_dir/workspace/packages/p1/p1-1.0.0-1-any.pkg.tar.zst.gsa-vcs-revisions ]] ||
    fail 'the marked rebuild did not record its VCS baseline'

# ─── The other VCS adapters use fixture-side command stubs ──────────────────
# Coverage needs neither public network access nor optional host clients: the
# engine probes `svn info --show-item revision …` / `hg identify …` /
# `bzr version-info …` through PATH and the stubs answer the recorded and the
# remote revision from their knobs. Unchanged → claim; moved → rebuild.
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

    # build → claim round trip through the recorder (the claim is the last
    # run), both revisions agreeing.
    make_non_git_workspace "$adapter_dir/ws-roundtrip" "$protocol" "$fragment"
    GSA_FAKE_VCS_REMOTE_REV=$revision_a GSA_FAKE_VCS_BUILT_REV=$revision_a \
        run_case "$adapter_dir/ws-roundtrip" -B -- p1
    expect_built p1 "$protocol initial build"
    assert_makepkg_count "$adapter_dir/ws-roundtrip" 1 "$protocol initial build"
    GSA_FAKE_VCS_REMOTE_REV=$revision_a GSA_FAKE_VCS_BUILT_REV=$revision_a \
        run_case "$adapter_dir/ws-roundtrip" -B --skip -- p1
    expect_claim p1 "$protocol unchanged selected ref" ok
    assert_makepkg_count "$adapter_dir/ws-roundtrip" 1 "$protocol unchanged selected ref"

    # advanced selected ref: rebuild (staged baseline at revision_a, the
    # remote now answers revision_b — the claim above is the control).
    make_non_git_workspace "$adapter_dir/ws-moved" "$protocol" "$fragment"
    stage_vcs_set "$adapter_dir/ws-moved" "upstream::$protocol+https://example.invalid/repo$( [[ -n $fragment ]] && printf '#%s' "$fragment" )" \
        "$protocol" "$revision_a"
    GSA_FAKE_VCS_REMOTE_REV=$revision_b GSA_FAKE_VCS_BUILT_REV=$revision_b \
        run_case "$adapter_dir/ws-moved" -B --skip -- p1
    expect_built p1 "$protocol advanced selected ref"
    assert_makepkg_count "$adapter_dir/ws-moved" 1 "$protocol advanced selected ref"
done

# ─── Clean and cleanup remove VCS metadata with the archive it describes ───
# Package-local prune strength 1 (`gsa -Mc`) and workspace prune strength 2
# (`gsa -Mcc`) are maintain verbs (§B.7); the cluster letter `c` on a build
# run is the same strength-1 prune BEFORE the build (§B.5).
clean_dir=$fixture/clean
init_git_remote "$clean_dir/repository"
clean_entry="upstream::git+file://$clean_dir/repository/remote.git#branch=main"
clean_rev=$(git_fixture -C "$clean_dir/repository/work" rev-parse HEAD)

# strength 1 removes the archive AND its VCS revision record.
make_workspace_common "$clean_dir/ws-prune"
add_package "$clean_dir/ws-prune" p1 "$gsa_meta_any"$'\n'"source=(\"$clean_entry\")"$'\n'"sha256sums=('SKIP')"
stage_vcs_set "$clean_dir/ws-prune" "$clean_entry" git "$clean_rev"
mkdir -p "$clean_dir/ws-prune/packages/p1/src/upstream"
run_case "$clean_dir/ws-prune" -Mc -- p1
expect_success 'clean removes the prior VCS baseline'
[[ ! -e $clean_dir/ws-prune/packages/p1/p1-1.0.0-1-any.pkg.tar.zst &&
    ! -e $clean_dir/ws-prune/packages/p1/p1-1.0.0-1-any.pkg.tar.zst.gsa-vcs-revisions ]] ||
    fail 'clean left an archive or its VCS revision record'

# strength 1 first, then build (`-Bc`): the rebuild must see NO stale VCS
# record (the stub refuses one) and record a fresh baseline.
make_vcs_workspace "$clean_dir/ws-rebuild" "$clean_dir/repository/remote.git" branch main
archive=$clean_dir/ws-rebuild/packages/p1/p1-1.0.0-1-any.pkg.tar.zst
pkginfo_archive "$archive" p1
printf 'stale record the clean must remove\n' >"$archive.gsa-vcs-revisions"
GSA_FAKE_EXPECT_CLEAN=1 run_case "$clean_dir/ws-rebuild" -Bc -- p1
expect_built p1 'clean rebuild records a fresh baseline'
assert_makepkg_count "$clean_dir/ws-rebuild" 1 'clean rebuild'
[[ -f $archive.gsa-vcs-revisions ]] ||
    fail 'successful clean rebuild did not record a fresh baseline'
grep -Fq $'gsa-vcs-revisions\t2' "$archive.gsa-vcs-revisions" ||
    fail 'the clean rebuild baseline is not manifest format 2'

# workspace cleanup (strength 2) removes every built archive plus its
# VCS-revision sidecar.
run_case "$clean_dir/ws-rebuild" -Mcc
expect_success 'workspace cleanup'
[[ ! -e $archive && ! -e $archive.gsa-vcs-revisions ]] ||
    fail 'workspace cleanup left an archive or its VCS revision record'
assert_makepkg_count "$clean_dir/ws-rebuild" 1 'workspace cleanup'

# ─── Recorder authority: the checkout makepkg compiled from ────────────────
# Real makepkg never leaves a VCS checkout at the package root: download_git
# keeps the mirror in SRCDEST and extract_git clones the working copy into
# $srcdir ($PWD/src/<name>), which build()/package() then cd into. The
# recorder must locate the checkout there — the 2026-10-02 xdg-utils failure
# ("build succeeded but VCS revisions could not be recorded: missing local
# checkout", green build, checkout present one directory deeper) was exactly
# this probe gap. Decoys at the package root and in SRCDEST at a DIFFERENT
# revision pin the authority order: the manifest must carry the revision
# compiled from src/, never a decoy. (The engine's recorder does not consult
# SRCDEST at all — its env roster is GSA_VCS_SKIP_TOLERANCE + TMPDIR — so the
# SRCDEST decoy is inert by design and stays as the negative control.)
src_layout=$fixture/srcdir-layout
init_git_remote "$src_layout/repository"
src_layout_work=$src_layout/repository/work
src_layout_remote=$src_layout/repository/remote.git
src_layout_entry="upstream::git+file://$src_layout_remote#branch=main"
rev1=$(git_fixture -C "$src_layout_work" rev-parse HEAD)
make_vcs_workspace "$src_layout/workspace" "$src_layout_remote" branch main

# Decoys at the two locations the recorder historically probed first, pinned
# at the first revision while the build below compiles a LATER one.
mkdir -p "$src_layout/workspace/makepkg-srcdest"
GIT_CONFIG_COUNT=0 git clone --quiet "$src_layout_remote" "$src_layout/workspace/packages/p1/upstream"
GIT_CONFIG_COUNT=0 git clone --quiet "$src_layout_remote" \
    "$src_layout/workspace/makepkg-srcdest/upstream"
for decoy in "$src_layout/workspace/packages/p1/upstream" \
    "$src_layout/workspace/makepkg-srcdest/upstream"; do
    decoy_rev=$(GIT_CONFIG_COUNT=0 git -C "$decoy" rev-parse HEAD)
    [[ $decoy_rev == "$rev1" ]] ||
        fail "decoy at $decoy is at $decoy_rev, expected $rev1"
done
advance_main "$src_layout_work" 'advanced selected branch' 5
rev2=$(git_fixture -C "$src_layout_work" rev-parse HEAD)

GSA_FAKE_VCS_LAYOUT=srcdir run_case "$src_layout/workspace" -B -- p1
expect_built p1 'srcdir-layout build'
assert_makepkg_count "$src_layout/workspace" 1 'srcdir-layout build'
src_layout_pkg=$src_layout/workspace/packages/p1
src_layout_archive=$src_layout_pkg/p1-1.0.0-1-any.pkg.tar.zst
src_layout_manifest=$src_layout_archive.gsa-vcs-revisions
[[ -f $src_layout_manifest ]] ||
    fail 'srcdir-layout build did not record its VCS baseline'
recorded=$(awk -F '\t' 'NR > 2 { print $3 }' "$src_layout_manifest")
src_rev=$(GIT_CONFIG_COUNT=0 git -C "$src_layout_pkg/src/upstream" rev-parse HEAD)
[[ $recorded == "$src_rev" && $recorded == "$rev2" && $recorded != "$rev1" ]] ||
    fail "srcdir-layout recorded $recorded; src/ checkout is $src_rev (build revision $rev2, decoys still at $rev1)"

# Consumer parity: the baseline recorded from the srcdir checkout satisfies
# the --skip claim exactly like one recorded from a package-root checkout.
GSA_FAKE_VCS_LAYOUT=srcdir run_case "$src_layout/workspace" -B --skip -- p1
expect_claim p1 'srcdir-layout unchanged selected branch' ok
assert_makepkg_count "$src_layout/workspace" 1 'srcdir-layout unchanged selected branch'

# The xdg-utils entry shape: no name:: override, and the URL basename carries
# .git. The manifest key is the full entry ("remote.git") while makepkg strips
# it to name the checkout ("remote"), so the srcdir probe has to honour both
# spellings of the same source.
src_suffix=$fixture/srcdir-git-suffix
init_git_remote "$src_suffix/repository"
make_vcs_workspace "$src_suffix/workspace" "$src_suffix/repository/remote.git" branch main basename

GSA_FAKE_VCS_LAYOUT=srcdir run_case "$src_suffix/workspace" -B -- p1
expect_built p1 'srcdir basename-style build'
assert_makepkg_count "$src_suffix/workspace" 1 'srcdir basename-style build'
src_suffix_manifest=$src_suffix/workspace/packages/p1/p1-1.0.0-1-any.pkg.tar.zst.gsa-vcs-revisions
[[ -f $src_suffix_manifest ]] ||
    fail 'basename-style build did not record its VCS baseline'
recorded=$(awk -F '\t' 'NR > 2 { print $3 }' "$src_suffix_manifest")
src_rev=$(GIT_CONFIG_COUNT=0 git -C "$src_suffix/workspace/packages/p1/src/remote" rev-parse HEAD)
[[ $recorded == "$src_rev" ]] ||
    fail "basename-style recorded $recorded; src/ checkout is $src_rev"

GSA_FAKE_VCS_LAYOUT=srcdir run_case "$src_suffix/workspace" -B --skip -- p1
expect_claim p1 'srcdir basename-style unchanged selected branch' ok
assert_makepkg_count "$src_suffix/workspace" 1 'srcdir basename-style unchanged selected branch'

# The libyuv entry shape: `url=` carries a trailing slash, so the expanded
# source ends in '/' and makepkg still derives the checkout name normally
# (trailing slashes stripped, then basename, then .git dropped).
src_slash=$fixture/srcdir-trailing-slash
init_git_remote "$src_slash/repository"
make_vcs_workspace "$src_slash/workspace" "$src_slash/repository/remote.git/" branch main basename

GSA_FAKE_VCS_LAYOUT=srcdir run_case "$src_slash/workspace" -B -- p1
expect_built p1 'srcdir trailing-slash build'
assert_makepkg_count "$src_slash/workspace" 1 'srcdir trailing-slash build'
src_slash_manifest=$src_slash/workspace/packages/p1/p1-1.0.0-1-any.pkg.tar.zst.gsa-vcs-revisions
[[ -f $src_slash_manifest ]] ||
    fail 'trailing-slash build did not record its VCS baseline'
recorded=$(awk -F '\t' 'NR > 2 { print $3 }' "$src_slash_manifest")
src_rev=$(GIT_CONFIG_COUNT=0 git -C "$src_slash/workspace/packages/p1/src/remote" rev-parse HEAD)
[[ $recorded == "$src_rev" ]] ||
    fail "trailing-slash recorded $recorded; src/ checkout is $src_rev"

# ─── Built-output set completeness ─────────────────────────────────────────
# A split recipe's currency is a property of the whole OUTPUT SET: an archive
# for one output does not make the recipe current while a sibling output is
# missing, so --skip must rebuild instead of skipping on the surviving half.
# The expected set is discovered from the evaluated pkgname array. The control
# claims the complete set; the anomaly case rebuilds (the named "missing:" /
# "is incomplete" fish diagnostics have no gsa rendering — the decision is the
# pin).
(
    set -euo pipefail
    split_dir=$fixture/split-set
    split_ws=$split_dir/workspace
    make_workspace_common "$split_ws"
    mkdir -p "$split_ws/packages/p1"
    printf '%s\n' 'pkgname=(p1 p1-extra)' 'pkgver=1.0.0' 'pkgrel=1' 'arch=(any)' \
        >"$split_ws/packages/p1/PKGBUILD"
    printf 'p1|packages/p1|git|\n' >>"$split_ws/config/topology.conf"
    touch -d '2000-01-01 00:00:00 UTC' "$split_ws/packages/p1/PKGBUILD"
    stage_plain_set "$split_ws" p1 p1-extra
    rm -f "$split_ws/packages/p1/p1-extra-1.0.0-1-any.pkg.tar.zst"
    run_case "$split_ws" -B --skip -- p1
    expect_built p1 'partial output set rebuilds'
    assert_makepkg_count "$split_ws" 1 'partial output set rebuilds'

    # the rebuilt complete set is claimable (the completeness claim's control)
    run_case "$split_ws" -B --skip -- p1
    expect_claim p1 'complete output set skips' ok
    assert_makepkg_count "$split_ws" 1 'complete output set skips'
)

# ─── Payload integrity ─────────────────────────────────────────────────────
# A truncated archive must not be sticky under --skip. The probe reads
# archives the way pacman does — the whole zstd stream, not the filename — so
# an interrupted write is detected before the skip and rebuilt once.
(
    set -euo pipefail
    trunc_dir=$fixture/truncated-archive
    trunc_ws=$trunc_dir/workspace
    make_workspace_common "$trunc_ws"
    add_package "$trunc_ws" p1 "$gsa_meta_any"
    trunc_archive=$trunc_ws/packages/p1/p1-1.0.0-1-any.pkg.tar.zst
    pkginfo_archive "$trunc_archive" p1
    touch -d '2000-01-01 00:00:00 UTC' "$trunc_ws/packages/p1/PKGBUILD"
    half=$(($(stat -c %s "$trunc_archive") / 2))
    head -c "$half" "$trunc_archive" >"$trunc_archive.trunc"
    mv "$trunc_archive.trunc" "$trunc_archive"
    run_case "$trunc_ws" -B --skip -- p1
    expect_built p1 'truncated archive rebuilds'
    assert_makepkg_count "$trunc_ws" 1 'truncated archive rebuilds'

    # the rebuilt readable archive is claimable (the payload claim's control)
    run_case "$trunc_ws" -B --skip -- p1
    expect_claim p1 'rebuilt archive skips' ok
    assert_makepkg_count "$trunc_ws" 1 'rebuilt archive skips'
)

# ─── Version-aware currency ────────────────────────────────────────────────
# "Current" is keyed to the evaluated pkgver/pkgrel: an archive named for an
# older version is not a build of THIS PKGBUILD and must never satisfy
# --skip, however fresh its mtime.
(
    set -euo pipefail
    stale_dir=$fixture/stale-version
    stale_ws=$stale_dir/workspace
    make_workspace_common "$stale_ws"
    add_package "$stale_ws" p1 "$gsa_meta_any"
    # The recipe moves to 1.0.0 while only the 0.9 build is on disk: the old
    # archive is not a build of this PKGBUILD and must not satisfy --skip.
    pkginfo_archive "$stale_ws/packages/p1/p1-0.9-1-any.pkg.tar.zst" p1
    touch -d '2000-01-01 00:00:00 UTC' "$stale_ws/packages/p1/PKGBUILD"
    run_case "$stale_ws" -B --skip -- p1
    expect_built p1 'stale-version archive rebuilds'
    assert_makepkg_count "$stale_ws" 1 'stale-version archive rebuilds'

    run_case "$stale_ws" -B --skip -- p1
    expect_claim p1 'current-version archive skips' ok
    assert_makepkg_count "$stale_ws" 1 'current-version archive skips'
)

# ─── Manifest identity binding ─────────────────────────────────────────────
# The v2 VCS manifest binds the recorded baseline to the exact archive bytes
# (sha256 + size). An archive replaced under a live manifest is a DIFFERENT
# build: the recorded revisions cannot vouch for it, so --skip must rebuild
# rather than skip. The replacement is a readable archive — the payload probe
# passes — so this case isolates the identity binding from the payload check.
(
    set -euo pipefail
    ident_dir=$fixture/manifest-identity
    init_git_remote "$ident_dir/repository"
    ident_entry="upstream::git+file://$ident_dir/repository/remote.git#branch=main"
    ident_rev=$(git_fixture -C "$ident_dir/repository/work" rev-parse HEAD)
    make_workspace_common "$ident_dir/ws-mismatch"
    add_package "$ident_dir/ws-mismatch" p1 "$gsa_meta_any"$'\n'"source=(\"$ident_entry\")"$'\n'"sha256sums=('SKIP')"
    ident_archive=$ident_dir/ws-mismatch/packages/p1/p1-1.0.0-1-any.pkg.tar.zst
    pkginfo_archive "$ident_archive" p1
    vcs_manifest "$ident_archive" "$ident_entry" git "$ident_rev"
    stage_marker "$ident_dir/ws-mismatch"
    touch -d '2000-01-01 00:00:00 UTC' "$ident_dir/ws-mismatch/packages/p1/PKGBUILD"
    # replaced bytes under the live manifest — the marker member guarantees
    # the archive differs from the one the manifest binds to, even when both
    # writes land in the same second
    pkginfo_archive "$ident_archive" p1 'replacement build'
    run_case "$ident_dir/ws-mismatch" -B --skip -- p1
    expect_built p1 'manifest identity: replaced archive rebuilds'
    assert_makepkg_count "$ident_dir/ws-mismatch" 1 'manifest identity: replaced archive rebuilds'

    # the rebuilt archive's manifest matches it again (the identity control)
    run_case "$ident_dir/ws-mismatch" -B --skip -- p1
    expect_claim p1 'manifest identity: rebuilt archive skips' ok
    assert_makepkg_count "$ident_dir/ws-mismatch" 1 'manifest identity: rebuilt archive skips'
)

# ─── --skip-built: the built set is the claim, freshness analysis off ──────
# Owner ask (2026-10-06): "built remains built, no ignore skip" — a git pull
# that only bumps the PKGBUILD's mtime, over a flaky network, made --skip a
# rebuild machine (the mtime gate fires locally; the VCS probes need the
# network). --skip-built keeps the SKIP claim — a complete, payload-valid
# archive set for the recipe stays built — and drops the freshness analysis
# entirely: no PKGBUILD-vs-archive mtime compare, no VCS probes (zero
# network), no waivers. Version drift alone never rebuilds (2026-10-07
# doctrine flip): the claim is about the BUILD, not the recipe's recorded
# pkgver. Only evidence of a RECIPE CHANGE rebuilds (the commit gate).
(
    set -euo pipefail
    sb_dir=$fixture/skip-built-mtime
    sb_ws=$sb_dir/workspace
    init_git_remote "$sb_dir/repository"
    make_vcs_workspace "$sb_ws" "$sb_dir/repository/remote.git" branch main
    stage_vcs_set "$sb_ws" "upstream::git+file://$sb_dir/repository/remote.git#branch=main" \
        git "$(git_fixture -C "$sb_dir/repository/work" rev-parse HEAD)"
    # The change gate's evidence is the recipe's last COMMIT, so the recipe
    # tree must be committed (commit 2020 ≪ archive "now").
    ws_git_init "$sb_ws"

    # The git-pull shape: the recipe file is NEWER than the archive. Under
    # --skip that mtime alone forces a rebuild; under --skip-built the built
    # set still counts.
    touch -d '+1 day' "$sb_ws/packages/p1/PKGBUILD"
    run_case "$sb_ws" -B --skip-built -- p1
    expect_claim p1 'skip-built skips a built package despite a newer PKGBUILD' skip-built
    assert_makepkg_count "$sb_ws" 0 'skip-built mtime: the git-pull mtime churn must not rebuild'
)

(
    set -euo pipefail
    # Version drift alone never rebuilds: here the edit's mtime is pinned
    # away and no git metadata exists, so nothing says "changed".
    sbv_dir=$fixture/skip-built-version
    sbv_ws=$sbv_dir/workspace
    make_workspace_common "$sbv_ws"
    add_package "$sbv_ws" p1 "$gsa_meta_any"
    pkginfo_archive "$sbv_ws/packages/p1/p1-1.0.0-1-any.pkg.tar.zst" p1
    stage_marker "$sbv_ws"
    touch -d '2000-01-01 00:00:00 UTC' "$sbv_ws/packages/p1/PKGBUILD"
    sed -i 's/^pkgver=1\.0\.0$/pkgver=1.1.0/' "$sbv_ws/packages/p1/PKGBUILD"
    touch -d '2000-01-01 00:00:00 UTC' "$sbv_ws/packages/p1/PKGBUILD"
    run_case "$sbv_ws" -B --skip-built -- p1
    expect_claim p1 'skip-built skips a version-drifted recipe with no change evidence' skip-built
    assert_makepkg_count "$sbv_ws" 0 'skip-built version: version drift alone must not rebuild'
)

(
    set -euo pipefail
    # The run-#40 llvm shape: the recipe's COMMITTED pkgver trails the built
    # set (makepkg's pkgver() named the archives at a newer revision; a later
    # pull reset the in-tree record and churned its mtime). The claim must
    # survive the drift — and with -S the CLAIMED set installs, not whatever
    # the committed pkgver names. Then a committed recipe change after the
    # build must rebuild (the gate's whole reason to exist).
    sbg_dir=$fixture/skip-built-version-drift
    sbg_ws=$sbg_dir/workspace
    make_workspace_common "$sbg_ws"
    add_package "$sbg_ws" p1 "$gsa_meta_any"
    ws_git_init "$sbg_ws" # commit 2020 ≪ the archive written below
    pkginfo_archive "$sbg_ws/packages/p1/p1-1.1.0-1-any.pkg.tar.zst" p1
    stage_marker "$sbg_ws"
    touch -d '+1 day' "$sbg_ws/packages/p1/PKGBUILD"
    run_case "$sbg_ws" -S --skip-built --config "$sbg_ws/pacman.conf" -- p1
    expect_claim p1 'skip-built drift: version-drifted set still skips' skip-built
    assert_makepkg_count "$sbg_ws" 0 'skip-built drift: a complete drifted set must not rebuild'
    grep -- 'pacman -U' "$sbg_ws/pacman.log" | grep -Fq 'p1-1.1.0-1-any.pkg.tar.zst' ||
        fail 'skip-built drift: -S did not install the CLAIMED drifted archive'

    # A real recipe change is a COMMIT, and it postdates the build: rebuild.
    printf '# recipe change after the build\n' >>"$sbg_ws/packages/p1/PKGBUILD"
    ws_git_commit "$sbg_ws" '@4102444800 +0000' 'recipe change after the build'
    run_case "$sbg_ws" -B --skip-built -- p1
    expect_built p1 'skip-built drift: committed recipe change rebuilds'
    assert_makepkg_count "$sbg_ws" 1 'skip-built drift: a commit newer than the set must rebuild'
)

(
    set -euo pipefail
    # The no-git fallback: without commit metadata the file's mtime is the
    # only change evidence left, and a real edit moves it — conservative
    # direction.
    sbf_dir=$fixture/skip-built-mtime-fallback
    sbf_ws=$sbf_dir/workspace
    make_workspace_common "$sbf_ws"
    add_package "$sbf_ws" p1 "$gsa_meta_any"
    pkginfo_archive "$sbf_ws/packages/p1/p1-1.0.0-1-any.pkg.tar.zst" p1
    stage_marker "$sbf_ws"
    touch -d '2000-01-01 00:00:00 UTC' "$sbf_ws/packages/p1/PKGBUILD"
    printf '# real edit\n' >>"$sbf_ws/packages/p1/PKGBUILD"
    run_case "$sbf_ws" -B --skip-built -- p1
    expect_built p1 'skip-built fallback: mtime evidence rebuilds'
    assert_makepkg_count "$sbf_ws" 1 'skip-built fallback: without git, a newer PKGBUILD must rebuild'
)

(
    set -euo pipefail
    # The claim is the COMPLETE built set: a split recipe missing a sibling
    # output must rebuild under --skip-built too (same anomaly shape as the
    # completeness section).
    sbi_dir=$fixture/skip-built-incomplete
    sbi_ws=$sbi_dir/workspace
    make_workspace_common "$sbi_ws"
    mkdir -p "$sbi_ws/packages/p1"
    printf '%s\n' 'pkgname=(p1 p1-extra)' 'pkgver=1.0.0' 'pkgrel=1' 'arch=(any)' \
        >"$sbi_ws/packages/p1/PKGBUILD"
    printf 'p1|packages/p1|git|\n' >>"$sbi_ws/config/topology.conf"
    touch -d '2000-01-01 00:00:00 UTC' "$sbi_ws/packages/p1/PKGBUILD"
    pkginfo_archive "$sbi_ws/packages/p1/p1-1.0.0-1-any.pkg.tar.zst" p1
    stage_marker "$sbi_ws"
    run_case "$sbi_ws" -B --skip-built -- p1
    expect_built p1 'skip-built rebuilds a partial split set'
    assert_makepkg_count "$sbi_ws" 1 'skip-built incomplete: a missing sibling output must rebuild'
)

(
    set -euo pipefail
    # "no ignore skip": --skip-built skips the BUILD, never the install —
    # with -S the claim path installs the existing archive.
    sbin_dir=$fixture/skip-built-install
    sbin_ws=$sbin_dir/workspace
    init_git_remote "$sbin_dir/repository"
    make_vcs_workspace "$sbin_ws" "$sbin_dir/repository/remote.git" branch main
    stage_vcs_set "$sbin_ws" "upstream::git+file://$sbin_dir/repository/remote.git#branch=main" \
        git "$(git_fixture -C "$sbin_dir/repository/work" rev-parse HEAD)"
    run_case "$sbin_ws" -S --skip-built --config "$sbin_ws/pacman.conf" -- p1
    expect_claim p1 'skip-built install: claim installs' skip-built
    assert_makepkg_count "$sbin_ws" 0 'skip-built install: the claim path must not rebuild'
    grep -- 'pacman -U' "$sbin_ws/pacman.log" | grep -Fq 'p1-1.0.0-1-any.pkg.tar.zst' ||
        fail 'skip-built -S did not install the claimed archive'
)

# ─── --vcs-skip-tolerance N: the waive threshold as a CLI number ────────────
# The flag beats GSA_VCS_SKIP_TOLERANCE (which stays the transport to lane
# children), and bad values are usage errors, not silent fallbacks.
(
    set -euo pipefail
    tol2_dir=$fixture/vcs-tolerance-flag
    init_git_remote "$tol2_dir/repository"
    tol2_work=$tol2_dir/repository/work
    tol2_entry="upstream::git+file://$tol2_dir/repository/remote.git#branch=main"
    tol2_rev=$(git_fixture -C "$tol2_work" rev-parse HEAD)

    # GSA_VCS_SKIP_TOLERANCE=2 would REBUILD a two-commit move (the boundary
    # is AT 2 — pinned above), so a skip here can only come from the flag's 3,
    # and the waiver line must name the flag's value.
    make_workspace_common "$tol2_dir/ws-waive"
    add_package "$tol2_dir/ws-waive" p1 "$gsa_meta_any"$'\n'"source=(\"$tol2_entry\")"$'\n'"sha256sums=('SKIP')"
    stage_vcs_set "$tol2_dir/ws-waive" "$tol2_entry" git "$tol2_rev"
    advance_main "$tol2_work" 'flag tolerance noise' 2
    GSA_VCS_SKIP_TOLERANCE=2 run_case "$tol2_dir/ws-waive" -B --skip --vcs-skip-tolerance 3 -- p1
    expect_claim p1 'flag tolerance 3 waives a two-commit move' freshness-waived
    assert_makepkg_count "$tol2_dir/ws-waive" 0 'flag tolerance: a two-commit move must stay skipped under tolerance 3'
    grep -Fq 'upstream moved 2 commit(s) < tolerance 3 — treating upstream as current' \
        <<<"$FIXTURE_OUTPUT" ||
        fail 'the waiver does not name the FLAG tolerance 3 (the env value must lose):'$'\n'"$FIXTURE_OUTPUT"

    # Five commits from THIS case's recorded baseline (the shared remote
    # already moved for the case above): at-or-past 3 rebuilds.
    make_workspace_common "$tol2_dir/ws-boundary"
    add_package "$tol2_dir/ws-boundary" p1 "$gsa_meta_any"$'\n'"source=(\"$tol2_entry\")"$'\n'"sha256sums=('SKIP')"
    stage_vcs_set "$tol2_dir/ws-boundary" "$tol2_entry" git \
        "$(git_fixture -C "$tol2_work" rev-parse HEAD)"
    advance_main "$tol2_work" 'flag tolerance boundary' 5
    GSA_VCS_SKIP_TOLERANCE=2 run_case "$tol2_dir/ws-boundary" -B --skip --vcs-skip-tolerance 3 -- p1
    expect_built p1 'flag tolerance 3 rebuilds at five commits'
    assert_makepkg_count "$tol2_dir/ws-boundary" 1 'flag tolerance: a five-commit move must rebuild under tolerance 3'

    # Invalid values are a loud usage error naming the flag — rc AND text —
    # never a silent fallback like the env var's warning.
    make_workspace_common "$tol2_dir/ws-usage"
    add_package "$tol2_dir/ws-usage" p1 "$gsa_meta_any"
    for bad in 0 -1 x; do
        run_case "$tol2_dir/ws-usage" -B --vcs-skip-tolerance "$bad" -- p1
        ((FIXTURE_RC != 0)) ||
            fail "flag tolerance: --vcs-skip-tolerance $bad exited 0 (a usage error must be non-zero)"
        grep -Fq -- '--vcs-skip-tolerance' <<<"$FIXTURE_OUTPUT" ||
            fail "flag tolerance: the --vcs-skip-tolerance $bad error does not name the flag:"$'\n'"$FIXTURE_OUTPUT"
    done
    assert_makepkg_count "$tol2_dir/ws-usage" 0 'flag tolerance: usage errors must not build'
)

# ─── --skip and --skip-built are DIFFERENT claims and cannot combine ───────
# (the fish-era "--skip-built wins over -s" spelling retires: the engine
# refuses the combination loudly, which is the honest reading of "one skip
# MODE per run"; the zero-network promise is kept by --skip-built alone and
# MEASURED — the ls-remote counting stub must record zero attempts.)
(
    set -euo pipefail
    both_dir=$fixture/skip-and-skip-built
    both_ws=$both_dir/workspace
    init_git_remote "$both_dir/repository"
    make_vcs_workspace "$both_ws" "$both_dir/repository/remote.git" branch main
    install_lsremote_stub "$both_ws"
    both_entry="upstream::git+file://$both_dir/repository/remote.git#branch=main"
    both_rev=$(git_fixture -C "$both_dir/repository/work" rev-parse HEAD)
    stage_vcs_set "$both_ws" "$both_entry" git "$both_rev"
    # State that would make plain --skip both probe and rebuild: the ref moved
    # far past the tolerance.
    advance_main "$both_dir/repository/work" 'combined-mode churn' 30

    run_case "$both_ws" -B --skip --skip-built -- p1
    ((FIXTURE_RC != 0)) ||
        fail 'combining --skip with --skip-built must be a usage error, not a silent winner'
    grep -Fq -- '--skip' <<<"$FIXTURE_OUTPUT" &&
        grep -Fq -- '--skip-built' <<<"$FIXTURE_OUTPUT" ||
        fail "the combination error does not name both claims:"$'\n'"$FIXTURE_OUTPUT"
    assert_makepkg_count "$both_ws" 0 'the refused combination must not build'

    rm -f "$both_ws/lsremote.count"
    run_case "$both_ws" -B --skip-built -- p1
    expect_claim p1 '--skip-built claims the built set with zero probes' skip-built
    assert_makepkg_count "$both_ws" 0 '--skip-built must win over a moved ref'
    attempts=$(lsremote_attempts "$both_ws")
    ((attempts == 0)) ||
        fail "--skip-built probed upstream $attempts time(s) — it must make zero VCS probes"

    # Control: plain --skip over the same moved ref probes and rebuilds — the
    # skip and zero-probe claims belong to --skip-built, not to the state.
    # Its own staged workspace: a claim never feeds the control's evidence.
    ctrl_ws=$both_dir/ws-control
    make_workspace_common "$ctrl_ws"
    add_package "$ctrl_ws" p1 "$gsa_meta_any"$'\n'"source=(\"$both_entry\")"$'\n'"sha256sums=('SKIP')"
    install_lsremote_stub "$ctrl_ws"
    stage_vcs_set "$ctrl_ws" "$both_entry" git "$both_rev"
    rm -f "$ctrl_ws/lsremote.count"
    run_case "$ctrl_ws" -B --skip -- p1
    expect_built p1 'plain --skip over the moved ref rebuilds'
    assert_makepkg_count "$ctrl_ws" 1 'plain --skip must rebuild over a 30-commit move'
    attempts=$(lsremote_attempts "$ctrl_ws")
    ((attempts >= 1)) ||
        fail 'plain --skip probed upstream zero times — the zero-probe oracle is vacuous'
)

# ─── Pending ABI-repair marker: a skip must never strand a repair ──────────
# 2026-10-07 run #48: the layer-3 ABI gate accepts a provider's soname move
# on the strength of the run rebuilding the consumer later (in-run repair),
# and the executor records a forced-rebuild marker under
# $GSA_STATE_DIR/abi-repair/. If a skip then claims the consumer's fresh
# archive as current, the repair never happens and the installed consumer
# stays broken forever — so a pending marker outranks EVERY freshness claim
# below it (both skip modes) and forces the build; only the consumer's own
# INSTALL consumes the marker, so runs without -S keep it pending.
(
    set -euo pipefail
    marker_dir=$fixture/abi-repair-marker
    init_git_remote "$marker_dir/repository"
    marker_entry="upstream::git+file://$marker_dir/repository/remote.git#branch=main"
    marker_rev=$(git_fixture -C "$marker_dir/repository/work" rev-parse HEAD)

    mk_marker_ws() { # $1 = workspace suffix
        local ws=$marker_dir/ws-$1
        make_workspace_common "$ws"
        add_package "$ws" p1 "$gsa_meta_any"$'\n'"source=(\"$marker_entry\")"$'\n'"sha256sums=('SKIP')"
        stage_vcs_set "$ws" "$marker_entry" git "$marker_rev"
        printf '%s\n' "$ws"
    }

    # a pending repair forces a rebuild under --skip (and says why).
    ws=$(mk_marker_ws forces)
    mkdir -p "$ws/state/abi-repair"
    printf 'provider=libs\ndate=fixture\n' >"$ws/state/abi-repair/p1"
    run_case "$ws" -B --skip -- p1
    expect_built p1 'marker: a pending repair forces a rebuild under --skip'
    assert_makepkg_count "$ws" 1 'marker: a pending repair forces a rebuild under --skip'
    grep -Fq 'pending ABI repair' <<<"$FIXTURE_OUTPUT" ||
        fail 'marker: the forced rebuild must say why (pending ABI repair):'$'\n'"$FIXTURE_OUTPUT"
    [[ -f $ws/state/abi-repair/p1 ]] ||
        fail 'marker: a build without -S must keep the marker pending (no install = no repair)'

    # …and under --skip-built.
    ws=$(mk_marker_ws skip-built)
    mkdir -p "$ws/state/abi-repair"
    printf 'provider=libs\ndate=fixture\n' >"$ws/state/abi-repair/p1"
    run_case "$ws" -B --skip-built -- p1
    expect_built p1 'marker: a pending repair forces a rebuild under --skip-built too'
    assert_makepkg_count "$ws" 1 'marker: a pending repair forces a rebuild under --skip-built too'
    [[ -f $ws/state/abi-repair/p1 ]] ||
        fail 'marker: --skip-built without -S must keep the marker pending too'

    # -S rebuilds and installs the repair; the install consumes the marker;
    # a normal claim resumes afterwards.
    ws=$(mk_marker_ws installs)
    mkdir -p "$ws/state/abi-repair"
    printf 'provider=libs\ndate=fixture\n' >"$ws/state/abi-repair/p1"
    run_case "$ws" -S --skip --config "$ws/pacman.conf" -- p1
    expect_built p1 'marker: -S rebuilds and installs the repair'
    assert_makepkg_count "$ws" 1 'marker: -S must rebuild a pending repair, never skip it'
    grep -q -- 'pacman -U' "$ws/pacman.log" ||
        fail 'marker: -S did not install the repaired archive'
    [[ ! -e $ws/state/abi-repair/p1 ]] ||
        fail 'marker: the consumer install must consume the marker'
    run_case "$ws" -B --skip -- p1
    expect_claim p1 'marker: normal skip resumes after consumption' ok
    assert_makepkg_count "$ws" 1 'marker: normal skip resumes after consumption'
)

# ─── Claim durability: a claim must leave its evidence in place ────────────
# The whole point of a skip RESUME is that the NEXT run keeps skipping: the
# claimed archive and its VCS baseline are the evidence the claim rests on,
# and a claim runs NO lane that could replace them. (The fish fixture pinned
# this as consecutive `-s` runs on one workspace; the native engine gained
# state the fish builder never had — the hash-bound binpkg index and its
# retention sweep — so this is the one place the fixture keeps a multi-run
# timeline on purpose.)
(
    set -euo pipefail
    durable_dir=$fixture/claim-durability
    init_git_remote "$durable_dir/repository"
    durable_remote=$durable_dir/repository/remote.git
    make_vcs_workspace "$durable_dir/workspace" "$durable_remote" branch main

    run_case "$durable_dir/workspace" -B -- p1
    expect_built p1 'durability: initial build'
    assert_makepkg_count "$durable_dir/workspace" 1 'durability: initial build'

    run_case "$durable_dir/workspace" -B --skip -- p1
    expect_claim p1 'durability: first claim' ok
    assert_makepkg_count "$durable_dir/workspace" 1 'durability: first claim'
    archive=$durable_dir/workspace/packages/p1/p1-1.0.0-1-any.pkg.tar.zst
    [[ -f $archive && -f $archive.gsa-vcs-revisions ]] ||
        fail 'durability: the claim consumed its own evidence (archive or VCS baseline gone)'

    run_case "$durable_dir/workspace" -S --skip --config "$durable_dir/workspace/pacman.conf" -- p1
    expect_claim p1 'durability: consecutive claim still claims and installs' ok
    assert_makepkg_count "$durable_dir/workspace" 1 'durability: a consecutive claim must not rebuild'
    grep -- 'pacman -U' "$durable_dir/workspace/pacman.log" | grep -Fq 'p1-1.0.0-1-any.pkg.tar.zst' ||
        fail 'durability: the consecutive claim did not install the surviving archive'
)

printf 'upstream-aware skip fixture: PASS\n'
