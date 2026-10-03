#!/usr/bin/env bash
set -euo pipefail

# Stable recipes track the Arch repository version, while explicitly tagged
# recipes may track an upstream source through `.nvchecker.toml`. The builder
# rewrites pkgver/pkgrel in place, and the committed sums may still describe the
# previous version.
#
# Two tempting ways out of the resulting staleness are both wrong. Re-hashing the
# fetch (updpkgsums on its own) records whatever arrived, verifying nothing.
# Passing --skipchecksums — which the builder used to do, silently, because
# build_package is only ever called quiet and every lane logs its own stream —
# builds and (with -i) installs sources nobody verified.
#
# The builder re-anchors the sums to the value *Arch* published for that version,
# from the .SRCINFO of the official packaging repo, and verifies the fetched
# sources against it. What makes that necessary is not the version bump itself
# but the *source* moving: 26 of the 28 stable recipes pin a literal version
# inside their source=() URLs, so a sync leaves their sums valid, and refusing
# those builds would be a false alarm.
#
#   1. the sync really happens (pkgver rewritten) — otherwise the rest is
#      vacuous, which is the trap this fixture exists to avoid;
#   2. --skipchecksums is never passed to makepkg;
#   3. the recipe's checksums really are re-anchored, and verification runs;
#   4. a source that DISAGREES with Arch's published checksum refuses the build,
#      restores the recipe, and never runs makepkg — the case that plain
#      auto-updpkgsums would have accepted, which is what makes this a test;
#   5. no official checksum at our version (404, or a repo carrying another
#      version): refuse, leaving the recipe untouched;
#   6. an entry Arch publishes NO checksum for (SKIP or absent): refreshed by
#      updpkgsums at sync-fire instead of refusing, recorded LOUDLY per entry
#      as fetch-only (no official value attests it) — the 2026-09-24 stance.
#      An entry Arch DOES publish is still verified against it (cases 1/2);
#   7. a version bump that does not move source=(): nothing is re-anchored and
#      the build runs against the sums already committed;
#   8. an official file publishing two algorithms for the same sources: still
#      anchored (the lists only line up within one algorithm);
#   9. a "name::url" override: the fetched file carries the override name, not
#      the URL basename, so it is found and verified;
#  10. the packaging repo has moved past our version: the version's own tag is
#      fetched instead of anchoring to a version that is not ours;
#  11. a VCS source: anchored, and verified the way makepkg verifies it
#      (`git archive --format tar <tag>` hashed, not a directory);
#  12. --no-sync disables the whole path;
#  13. the refresh itself fails (network down, upstream gone): the named
#      'updpkgsums' error plus the manual recovery line ('Refresh them by
#      hand', '--no-sync' builds the committed version as-is), the recipe
#      restored, makepkg never started — and the run DEFERS the recipe
#      (parked with a named marker) instead of killing the dispatch, which
#      tests/anchor-defer.sh pins end to end;
#  14. a local pkgrel ahead of the repo is a DELIBERATE bump (a PGO wave marks
#      its own revision, e.g. ripgrep's pkgrel 2 over the repo's 1) and is
#      never rewritten back to the repo value — only a repo pkgrel actually
#      ahead is synced (case 7's pkgrel-only variant pins that direction).
#  15. an opted-in core recipe resolves its AUR version and uses the matching
#      AUR .SRCINFO pkgrel/checksum, without leaking nvchecker state into recipes.
#  16. GitHub release digests anchor changed assets and reset pkgrel on version
#      movement; a git-source tracker resolves its GitHub repository too.
#  17. a GitHub release without an asset digest follows the loud fetch-only path.
#  18. a GitHub digest mismatch refuses the run and restores the original recipe.
#  19. unavailable GitHub metadata defers and restores the original recipe.
#  20. an nvchecker failure does not fall back to the Arch provider.
#  21-22. AUR version/source races never apply mismatched metadata.
#  23. --no-sync skips the resolver, provider metadata, and recipe rewrites.
#  24-25. AUR pkgrel adopts an upstream increase but never lowers a local
#        revision at the same pkgver.
#  26. GitHub keeps pkgrel when pkgver is unchanged.
#  27-28. gcc-snapshot maps supported dates into _pkgver and rejects bad formats.
#  29-30. AUR missing sums are loud fetch-only; a published checksum mismatch
#        refuses and restores the recipe.
#  31. Zen's recipe ID/pkgname difference and local source filename override
#        still select the correct config section and GitHub asset digest.
#  34. a computed pkgver=${var} recipe gets its VERSION VARIABLES bumped
#        (_rcver=rc3 → _rcver=rc5 — never a literal pkgver write over the
#        expression), its moved source re-anchored, and its committed .SRCINFO
#        refreshed in lockstep.
#  35. a computed pkgver expression the planner cannot rewrite (command
#        substitution) refuses and rolls back — the historical rewrite would
#        have clobbered the expression with a literal.
#  36. a tracker section named for the recipe id still resolves when the
#        pkgbase carries a flavor suffix.
#
# All external collaborators (pacman, curl, updpkgsums, makepkg, nvchecker) are
# stubs on PATH, so this runs with no network and never builds anything.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-stable-sync.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

command -v vercmp >/dev/null || {
    printf 'vercmp is required (it ships with pacman)\n' >&2
    exit 1
}
command -v sha256sum >/dev/null || {
    printf 'sha256sum is required\n' >&2
    exit 1
}
command -v git >/dev/null || {
    printf 'git is required (the VCS case recomputes git archive)\n' >&2
    exit 1
}

staged_version=1.0.0         # what the recipe pins
repo_version=2.0.0           # what the stub repo advertises
staged_sum=0000000000000000000000000000000000000000000000000000000000000000
staged_b2=11111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111

# The bytes Arch published a checksum for, and different bytes the "fetch" will
# sometimes deliver instead.
published_payload="$fixture/published.tar.gz"
tampered_payload="$fixture/tampered.tar.gz"
printf 'the source Arch published a checksum for\n' >"$published_payload"
printf 'a different source entirely, same filename\n' >"$tampered_payload"
published_sha=$(sha256sum "$published_payload" | awk '{print $1}')
published_b2=$(b2sum "$published_payload" | awk '{print $1}')
tampered_sha=$(sha256sum "$tampered_payload" | awk '{print $1}')

fail() {
    printf '\nFAIL: %s\n' "$*" >&2
    exit 1
}

# ─── The sandbox ────────────────────────────────────────────────────────────
# $1 = dir · $2 = the version the stub repo advertises · $3 = source entry
# (default: one whose URL spells $pkgver out) · $4 = the staged sum arrays.
# Skeleton synthesis comes from tests/lib/fixture-lib.bash; s1's recipe lives
# at the non-default path packages/stable/s1 with a fully parameterised
# PKGBUILD, so it is written here rather than via add_package.
make_case_workspace() {
    local dir=$1 repo_full=$2
    local source_entry=${3:-'https://example.invalid/s1-$pkgver.tar.gz'}
    local sum_lines=${4:-"sha256sums=('$staged_sum')"}
    make_workspace "$dir" 1 2 low
    mkdir -p "$dir/packages/stable/s1" "$dir/fake"
    printf 's1|packages/stable/s1|stable|\n' >>"$dir/config/topology.conf"

    # $pkgver must stay literal here: the builder expands the array by sourcing
    # the recipe, so the value has to come from the recipe's own pkgver=. printf
    # writes the entry verbatim — a heredoc would either expand it now or need
    # escaping that survives into the file.
    {
        printf 'pkgname=s1\n'
        printf 'pkgver=%s\n' "$staged_version"
        printf 'pkgrel=1\n'
        printf 'arch=(any)\n'
        printf 'source=("%s")\n' "$source_entry"
        printf '%s\n' "$sum_lines"
    } >"$dir/packages/stable/s1/PKGBUILD"
    cat >"$dir/packages/stable/s1/.nvchecker.toml" <<'EOF'
[s1]
source = "github"
github = "example/s1"
EOF

    printf '%s\n' "$repo_full" >"$dir/fake/repo_version"

    # The stub repository: sync_stable_version runs `pacman -Si <name>`.
    cat >"$dir/bin/pacman" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == -Si ]]; then
    printf 'Repository      : extra\nName            : s1\nVersion         : %s\n' \
        "$(cat "$GSA_FAKE_DIR/repo_version")"
    exit 0
fi
exit 0
EOF
    chmod +x "$dir/bin/pacman"

    # Stands in for the fetch of gitlab.archlinux.org/.../.SRCINFO. An empty
    # fake/srcinfo is the 404 case: a recipe Arch does not carry. fake/srcinfo is
    # also the answer for the `main` ref; a tag ref is answered by
    # fake/srcinfo_tag, which is absent (404) unless a case sets it.
    cat >"$dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""; url=""; write_out=""
while (($#)); do
    case $1 in
        -o|--output) out=$2; shift 2 ;;
        -w|--write-out) write_out=$2; shift 2 ;;
        --max-time|--connect-timeout) shift 2 ;;
        -*) shift ;;
        *) url=$1; shift ;;
    esac
done
printf '%s\n' "$url" >>"$GSA_FAKE_DIR/curl_calls"
if [[ $url == *api.github.com/repos/*/releases/tags/* ]]; then
    tag=${url##*/}
    answer=$GSA_FAKE_DIR/github_release.$tag.json
    http_status=${GSA_FAKE_GITHUB_STATUS:-200}
    if [[ ! -s $answer && $http_status == 200 ]]; then
        http_status=404
    fi
    if [[ $http_status == 200 ]]; then
        cp -- "$answer" "$out"
    fi
    [[ $write_out != '%{http_code}' ]] || printf '%s' "$http_status"
    exit 0
elif [[ $url == *aur.archlinux.org/cgit/aur.git/plain/.SRCINFO* ]]; then
    answer=$GSA_FAKE_DIR/aur_srcinfo
elif [[ $url == */raw/main/* ]]; then
    answer=$GSA_FAKE_DIR/srcinfo
else
    answer=$GSA_FAKE_DIR/srcinfo_tag
fi
[[ -s $answer ]] || exit 22
cp -- "$answer" "$out"
EOF
    chmod +x "$dir/bin/curl"

    # Stands in for makepkg's updater. It reproduces the three things the builder
    # depends on: the sources are fetched, a VCS source becomes a checkout at its
    # tag, and the sums are written in the recipe's own algorithms — from
    # whatever was fetched.
    cat >"$dir/bin/updpkgsums" <<'EOF'
#!/usr/bin/env bash
dir=$(pwd)
set -e
set -o pipefail   # a failed git archive must fail the shim, never hash empty input
printf '%s\n' "$dir" >>"$GSA_FAKE_DIR/updpkgsums_calls"
[[ -s $GSA_FAKE_DIR/deliver ]] || exit 1          # nothing to fetch

mapfile -t sources < <(bash -c 'source "$1" >/dev/null 2>&1; printf "%s\n" "${source[@]}"' _ "$dir/PKGBUILD")
mapfile -t algos < <(bash -c 'source "$1" >/dev/null 2>&1; for a in sha256 sha512 b2; do declare -p "${a}sums" >/dev/null 2>&1 && printf "%s\n" "$a"; done' _ "$dir/PKGBUILD")

file_of() {   # the name makepkg gives one source entry
    local e=$1 u
    if [[ $e == *::* ]]; then printf '%s' "${e%%::*}"; return; fi
    u=${e%%\?*}; u=${u%%#*}
    printf '%s' "${u##*/}"
}

for alg in "${algos[@]}"; do
    line=""
    for e in "${sources[@]}"; do
        f=$(file_of "$e")
        if [[ $e == *git+* ]]; then
            tag=${e##*#}; tag=${tag%%\?*}; tag=${tag##*=}
            if [[ ! -d $dir/$f ]]; then
                mkdir -p "$dir/$f"
                git -C "$dir/$f" init -q .
                printf 'checkout of %s\n' "$tag" >"$dir/$f/f.txt"
                git -C "$dir/$f" add -A
                git -C "$dir/$f" -c user.email=t@t -c user.name=t commit -qm "$tag"
                git -C "$dir/$f" -c user.email=t@t -c user.name=t tag "$tag"
            fi
            sum=$(git -c core.abbrev=no -C "$dir/$f" archive --format tar "$tag" | "${alg}sum" | awk '{print $1}')
        else
            cp -- "$GSA_FAKE_DIR/deliver" "$dir/$f"
            sum=$("${alg}sum" "$dir/$f" | awk '{print $1}')
        fi
        line+="'$sum' "
    done
    sed -i "s|^${alg}sums=.*|${alg}sums=(${line% })|" "$dir/PKGBUILD"
done
EOF
    chmod +x "$dir/bin/updpkgsums"

    # Records the argv it was invoked with; on every refusal path it must never
    # be created at all. --printsrcinfo is pure metadata — the version sync
    # refreshes the committed .SRCINFO through it — so it models makepkg's
    # .SRCINFO shape from the recipe instead of building anything. The
    # computed-pkgver case asserts .SRCINFO consistency by regenerating through
    # this same code path and diffing.
    cat >"$dir/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$GSA_FAKE_DIR/makepkg_argv"
for arg in "$@"; do
    if [[ $arg == --printsrcinfo ]]; then
        dir=$PWD
        args=("$@")
        for ((i = 0; i < ${#args[@]}; i++)); do
            [[ ${args[i]} == --dir ]] && dir=${args[i + 1]}
        done
        bash -c '
            cd "$1" || exit 1
            source ./PKGBUILD >/dev/null 2>&1 || exit 1
            printf "pkgbase = %s\n" "${pkgbase:-${pkgname[0]}}"
            printf "\tpkgver = %s\n" "$pkgver"
            printf "\tpkgrel = %s\n" "$pkgrel"
            for s in "${source[@]}"; do printf "\tsource = %s\n" "$s"; done
            for alg in sha256sums sha512sums b2sums md5sums; do
                declare -p "$alg" >/dev/null 2>&1 || continue
                eval "vals=(\"\${$alg[@]}\")"
                for v in "${vals[@]}"; do printf "\t%s = %s\n" "$alg" "$v"; done
            done
            printf "pkgname = %s\n" "${pkgname[0]}"
        ' _ "$dir"
        exit 0
    fi
done
printf 'fake makepkg: %s\n' "$*"
exit 0
EOF
    chmod +x "$dir/bin/makepkg"
}

# The official .SRCINFO the "network" serves.
# $1 = dir · $2 = official pkgver · $3.. = body lines after pkgbase/pkgver/pkgrel
set_official_srcinfo() {
    local dir=$1 ver=$2
    shift 2
    {
        printf 'pkgbase = s1\n'
        printf '\tpkgver = %s\n' "$ver"
        printf '\tpkgrel = 1\n'
        printf '\tarch = any\n'
        printf '%s\n' "$@"
    } >"$dir/fake/srcinfo"
}

# AUR .SRCINFO uses the same pkgbase-level source/checksum representation as
# Arch's, but the package version is its own authority.
set_aur_srcinfo() {
    local dir=$1 base=$2 ver=$3 rel=$4 source_entry=$5 checksum=$6
    {
        printf 'pkgbase = %s\n' "$base"
        printf '\tpkgver = %s\n' "$ver"
        printf '\tpkgrel = %s\n' "$rel"
        if [[ -n ${7:-} ]]; then printf '\tepoch = %s\n' "$7"; fi
        printf '\tarch = any\n'
        printf '\tsource = %s\n' "$source_entry"
        printf '\tsha256sums = %s\n\n' "$checksum"
        printf 'pkgname = %s\n' "$base"
    } >"$dir/fake/aur_srcinfo"
}

# $1 = dir · $2 = the file "updpkgsums" will fetch, or 'none'
set_delivery() {
    local dir=$1 payload=$2
    if [[ $payload == none ]]; then
        : >"$dir/fake/deliver"
    else
        cp -- "$payload" "$dir/fake/deliver"
    fi
}

# $1 = dir · $2 = label · $3 = expected rc (0 or 'fail') · extra args...
run_build() {
    local dir=$1 label=$2 expect=$3
    shift 3
    local package_id=${GSA_FAKE_PACKAGE_ID:-s1}
    set +e
    output=$(
        PATH="$dir/bin:$PATH" \
        GSA_STATE_DIR="$dir/state" \
        NVCHECK_STATE_DIR="$dir/nvcheck-state" \
        GSA_FAKE_DIR="$dir/fake" \
        GSA_FAKE_NVCHECK_VERSION="${GSA_FAKE_NVCHECK_VERSION:-}" \
        GSA_FAKE_NVCHECK_KEY="${GSA_FAKE_NVCHECK_KEY:-s1}" \
        GSA_FAKE_NVCHECK_FAIL="${GSA_FAKE_NVCHECK_FAIL:-0}" \
        GSA_FAKE_GITHUB_STATUS="${GSA_FAKE_GITHUB_STATUS:-200}" \
        GSA_CPU_THREADS=4 \
        GSA_MEMORY_GIB=8 \
        fish "$dir/build-all.fish" --allow-broken-rustc --no-deps \
            --intensity low "$package_id" "$@" 2>&1
    )
    rc=$?
    set -e
    printf '%s' "$output" >"$dir/out.txt"
    if [[ $expect == fail ]]; then
        ((rc != 0)) || fail "$label: the builder reported success; it was supposed to refuse"
    else
        ((rc == 0)) || fail "$label: the builder exited $rc"$'\n'"$output"
    fi
}

pkgfile() { printf '%s/packages/stable/s1/PKGBUILD' "$1"; }
recipe_log() { printf '%s/state/logs/s1.log' "$1"; }

# The external-sync path still uses the real resolver. Only nvchecker itself is
# stubbed; it writes the configured key into the resolver's temporary newver file.
make_nvchecker_stub() {
    local dir=$1
    mkdir -p "$dir/tools"
    cp -- "$gsa_repo_root/tools/nvcheck.sh" "$dir/tools/nvcheck.sh"
    cat >"$dir/bin/nvchecker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ ${GSA_FAKE_NVCHECK_FAIL:-0} == 1 ]]; then
    printf 'fake nvchecker: requested failure\n' >&2
    exit 1
fi
config=""
while (($#)); do
    case $1 in
        -c|--config) config=$2; shift 2 ;;
        *) shift ;;
    esac
done
[[ -n $config ]] || exit 2
newver=$(sed -n 's/^[[:space:]]*newver[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$config" | head -n1)
[[ -n $newver ]] || exit 2
printf '%s\n' "$config" >>"$GSA_FAKE_DIR/nvchecker_calls"
printf '{"%s":"%s"}\n' "$GSA_FAKE_NVCHECK_KEY" "$GSA_FAKE_NVCHECK_VERSION" >"$newver"
EOF
    chmod +x "$dir/bin/nvchecker"
}

opt_in_nvchecker() { # $1 = workspace · $2 = id · $3 = path · $4 = group
    local dir=$1 id=$2 path=$3 group=$4
    sed -i "\|^$id|d" "$dir/config/topology.conf"
    printf '%s|%s|%s||version-sync=nvchecker\n' "$id" "$path" "$group" \
        >>"$dir/config/topology.conf"
}

set_github_release() { # $1 = workspace · $2 = tag · $3 = asset · $4 = sha256|none
    local dir=$1 tag=$2 asset=$3 digest=$4
    local digest_json=null
    if [[ $digest != none ]]; then
        digest_json="\"sha256:$digest\""
    fi
    cat >"$dir/fake/github_release.$tag.json" <<EOF
{
  "tag_name": "$tag",
  "assets": [
    {"name": "$asset", "digest": $digest_json}
  ]
}
EOF
}

make_aur_version_workspace() { # $1 = workspace
    local dir=$1
    make_case_workspace "$dir" '99.0.0-1'
    mkdir -p "$dir/packages/core"
    mv -- "$dir/packages/stable/s1" "$dir/packages/core/s1"
    opt_in_nvchecker "$dir" s1 packages/core/s1 core
    cat >"$dir/packages/core/s1/.nvchecker.toml" <<'EOF'
[s1]
source = "aur"
aur = "s1"
strip_release = true
EOF
    make_nvchecker_stub "$dir"
}

make_gcc_version_workspace() { # $1 = workspace
    local dir=$1
    make_case_workspace "$dir" '99.0.0-1'
    mkdir -p "$dir/packages/core"
    mv -- "$dir/packages/stable/s1" "$dir/packages/core/gcc-snapshot"
    sed -i '/^s1|/d' "$dir/config/topology.conf"
    printf 'gcc-snapshot|packages/core/gcc-snapshot|core||version-sync=nvchecker\n' \
        >>"$dir/config/topology.conf"
    cat >"$dir/packages/core/gcc-snapshot/PKGBUILD" <<'EOF'
pkgbase=gcc-snapshot
pkgname=(gcc-snapshot)
pkgver=17.0.0.snapshot20260920
if [[ $pkgver =~ ^([0-9]+)\.0\.0\.snapshot([0-9]{8})$ ]]; then
    _pkgver="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
else
    printf 'gcc-snapshot: unsupported pkgver format: %s\n' "$pkgver" >&2
    exit 1
fi
pkgrel=1
arch=(any)
source=("https://example.invalid/gcc-${_pkgver}.tar.xz")
sha256sums=('0000000000000000000000000000000000000000000000000000000000000000')
EOF
    cat >"$dir/packages/core/gcc-snapshot/.nvchecker.toml" <<'EOF'
[gcc-snapshot]
source = "aur"
aur = "gcc-snapshot"
strip_release = true
EOF
    make_nvchecker_stub "$dir"
}

make_zen_version_workspace() { # $1 = workspace
    local dir=$1
    local source_entry='zen-source-$pkgver.tar.zst::https://github.com/zen-browser/desktop/releases/download/$pkgver/zen.source.tar.zst'
    make_case_workspace "$dir" '99.0.0-1' "$source_entry"
    mv -- "$dir/packages/stable/s1" "$dir/packages/stable/zen-browser-pgo"
    sed -i '/^s1|/d' "$dir/config/topology.conf"
    printf 'zen-browser-pgo|packages/stable/zen-browser-pgo|stable||version-sync=nvchecker\n' \
        >>"$dir/config/topology.conf"
    sed -i 's/^pkgname=s1$/pkgname=zen-browser/' \
        "$dir/packages/stable/zen-browser-pgo/PKGBUILD"
    cat >"$dir/packages/stable/zen-browser-pgo/.nvchecker.toml" <<'EOF'
[zen-browser]
source = "github"
github = "zen-browser/desktop"
EOF
    make_nvchecker_stub "$dir"
}

# ─── Case 1: anchored and verified — the happy path ─────────────────────────
dir="$fixture/anchor"
make_case_workspace "$dir" "$repo_version-1"
set_official_srcinfo "$dir" "$repo_version" \
    "	source = https://example.invalid/s1-$repo_version.tar.gz" \
    "	sha256sums = $published_sha"
set_delivery "$dir" "$published_payload"
make_nvchecker_stub "$dir"
run_build "$dir" 'anchor' 0

# Preconditions: the sync happened, and so did the anchoring — otherwise every
# assertion below could pass for the wrong reason.
grep -q "^pkgver=$repo_version$" "$(pkgfile "$dir")" \
    || fail "the recipe was not version-synced, so this run cannot exercise the checksum path"
[[ -s $dir/fake/curl_calls ]] || fail 'no official .SRCINFO was fetched, so nothing was anchored to'
[[ -s $dir/fake/updpkgsums_calls ]] || fail 'the sums were never rewritten'
[[ -s $dir/fake/makepkg_argv ]] || fail 'makepkg never ran on the success path'
[[ ! -s $dir/fake/nvchecker_calls ]] \
    || fail 'an untagged .nvchecker.toml redirected the Arch version provider'

# The weakening is gone: the build is checksum-verified, not skipped.
if grep -q -- '--skipchecksums' "$dir/fake/makepkg_argv"; then
    fail 'a synced build still passed --skipchecksums to makepkg'
fi

# The recipe now carries the hash of a file that matched Arch's published value,
# which is the whole point: not a hash of whatever arrived.
grep -q "^sha256sums=('$published_sha')$" "$(pkgfile "$dir")" \
    || fail 'the recipe does not carry the checksum of the verified source'
grep -q 're-anchored to the official' "$(recipe_log "$dir")" \
    || fail 'the log does not record that the checksums were re-anchored'

# ─── Case 2: a source that disagrees with Arch refuses the build ────────────
# This is the case that separates anchoring from rubber-stamping: hashing what
# arrived (updpkgsums alone) accepts this build.
dir="$fixture/tampered"
make_case_workspace "$dir" "$repo_version-1"
set_official_srcinfo "$dir" "$repo_version" \
    "	source = https://example.invalid/s1-$repo_version.tar.gz" \
    "	sha256sums = $published_sha"
set_delivery "$dir" "$tampered_payload"
run_build "$dir" 'tampered' fail

[[ -s $dir/fake/curl_calls ]] || fail 'no official .SRCINFO was fetched: this case is vacuous'
[[ -s $dir/fake/updpkgsums_calls ]] || fail 'the sums were never rewritten: this case is vacuous'
if [[ -s $dir/fake/makepkg_argv ]]; then
    fail 'makepkg ran for a source that disagrees with the checksum Arch published'
fi
grep -q 'does not match the official Arch checksum' "$(recipe_log "$dir")" \
    || fail 'the refusal does not say that the source disagrees with Arch'
grep -q "$tampered_sha" "$(recipe_log "$dir")" \
    || fail 'the refusal does not name the hash the fetched source actually had'
grep -q "$published_sha" "$(recipe_log "$dir")" \
    || fail 'the refusal does not name the hash Arch published'
grep -q "^sha256sums=('$staged_sum')$" "$(pkgfile "$dir")" \
    || fail 'the recipe was left carrying a hash of the tampered source'

# ─── Case 3: no official .SRCINFO at all (a recipe Arch does not carry) ─────
dir="$fixture/no-official"
make_case_workspace "$dir" "$repo_version-1"
: >"$dir/fake/srcinfo"                       # the fetch 404s
: >"$dir/fake/srcinfo_tag"
set_delivery "$dir" "$published_payload"
run_build "$dir" 'no-official' fail

grep -q 'carries no revision of' "$(recipe_log "$dir")" \
    || fail 'the refusal does not say that no official revision carries our version'
if [[ -s $dir/fake/makepkg_argv ]]; then
    fail 'makepkg ran without any anchor for the sums'
fi
if [[ -s $dir/fake/updpkgsums_calls ]]; then
    fail 'updpkgsums rewrote the sums without an anchor — that is the rubber stamp'
fi
grep -q "^sha256sums=('$staged_sum')$" "$(pkgfile "$dir")" \
    || fail 'the recipe was modified although nothing could be anchored'

# ─── Case 4: the official repo carries a different version ──────────────────
# Anchoring to another version's checksums would be worse than not anchoring.
dir="$fixture/other-version"
make_case_workspace "$dir" "$repo_version-1"
set_official_srcinfo "$dir" '1.5.0' \
    '	source = https://example.invalid/s1-1.5.0.tar.gz' \
    "	sha256sums = $published_sha"
: >"$dir/fake/srcinfo_tag"
set_delivery "$dir" "$published_payload"
run_build "$dir" 'other-version' fail

grep -q 'the official packaging repo carries 1.5.0' "$(recipe_log "$dir")" \
    || fail 'the refusal does not say which version the official repo carries'
if [[ -s $dir/fake/makepkg_argv ]]; then
    fail 'makepkg ran against another version of the sums'
fi
grep -q "^sha256sums=('$staged_sum')$" "$(pkgfile "$dir")" \
    || fail 'the recipe was modified although the official version did not match'

# ─── Case 5: an entry the official file does not cover is refreshed, LOUDLY ─
# The official document matched our pkgver but publishes no checksum for a
# moved source (SKIP, or no entry at all). The old stance refused the recipe
# for that; since 2026-09-24 the sync runs updpkgsums over it instead — that
# is exactly the documented manual remedy, now automated — and records which
# entries were refreshed fetch-only, because nothing official attests them.
# What must NOT appear: a silent refresh (the entries are named), a build with
# verification disabled, or any weakening for entries Arch DOES publish
# (cases 1/2 pin that half independently).
dir="$fixture/unanchored"
make_case_workspace "$dir" "$repo_version-1"
set_official_srcinfo "$dir" "$repo_version" \
    "	source = https://example.invalid/s1-$repo_version.tar.xz" \
    "	sha256sums = $published_sha"
set_delivery "$dir" "$published_payload"
run_build "$dir" 'unanchored' 0

[[ -s $dir/fake/updpkgsums_calls ]] \
    || fail 'unanchored: the sums were never refreshed — this case is vacuous'
[[ -s $dir/fake/makepkg_argv ]] \
    || fail 'unanchored: the build did not proceed after the refresh'
if grep -q -- '--skipchecksums' "$dir/fake/makepkg_argv"; then
    fail 'unanchored: the build disabled checksum verification'
fi
grep -q 'publishes no checksum for' "$(recipe_log "$dir")" \
    || fail 'the refresh does not record that official publishes no checksum for the entry'
grep -q 's1-2.0.0.tar.gz' "$(recipe_log "$dir")" \
    || fail 'the refresh does not name the fetch-only entry'
grep -q 'attested by nothing but the fetch' "$(recipe_log "$dir")" \
    || fail 'the refresh-only entry is recorded without saying what attests it'
grep -q "^sha256sums=('$published_sha')$" "$(pkgfile "$dir")" \
    || fail 'unanchored: the recipe does not carry the refreshed sum'
# The run-level surface: the owner must be told what to review and commit.
grep -q 'Version and checksum sync this run' "$dir/out.txt" \
    || fail 'the run summary does not list the synced recipe as uncommitted work'
grep -q 'refresh-only' "$dir/out.txt" \
    || fail 'the run summary does not flag the fetch-only refresh'

# ─── Case 5b: the refresh itself fails → named error + recovery, parked ─────
# Network down, upstream gone: updpkgsums exits non-zero. The recipe must be
# restored, the build refused with the 'updpkgsums' error and BOTH recovery
# lines (manual refresh, --no-sync), makepkg never started — and the run must
# DEFER the recipe (named marker in the summary) rather than drop the whole
# dispatch. The dispatch half is re-pinned end to end in tests/anchor-defer.sh;
# here the refusal itself and the parking marker are asserted.
dir="$fixture/refresh-fails"
make_case_workspace "$dir" "$repo_version-1"
set_official_srcinfo "$dir" "$repo_version" \
    "	source = https://example.invalid/s1-$repo_version.tar.xz" \
    "	sha256sums = $published_sha"
set_delivery "$dir" none                       # the updpkgsums stub exits 1
run_build "$dir" 'refresh-fails' fail

grep -q "'updpkgsums' could not refresh the checksums" "$(recipe_log "$dir")" \
    || fail 'refresh failure: the log does not carry the named updpkgsums error'
grep -q "Refresh them by hand" "$(recipe_log "$dir")" \
    || fail 'refresh failure: the manual recovery line is missing'
grep -q -- "'--no-sync' builds the committed version as-is" "$(recipe_log "$dir")" \
    || fail 'refresh failure: the --no-sync escape is no longer documented in the error'
if [[ -s $dir/fake/makepkg_argv ]]; then
    fail 'refresh failure: makepkg ran although nothing could be refreshed'
fi
grep -q "^sha256sums=('$staged_sum')$" "$(pkgfile "$dir")" \
    || fail 'refresh failure: the recipe was not restored to its pre-refresh sums'
grep -q 'DEFERRED' "$dir/out.txt" \
    || fail 'refresh failure: the recipe was not parked with a DEFERRED marker'
grep -q '^  build-all.fish ' "$dir/out.txt" \
    || fail 'refresh failure: no resume command for the parked recipe'

# ─── Case 6: a bump that does not move source=() is not treated as stale ────
# 26 of the 28 stable recipes pin a literal version in the URL, so nothing they
# fetch changes and their committed sums still verify. Anchoring here would be a
# false alarm; re-hashing would be a gratuitous rewrite.
for variant in pkgrel-only static-pkgver; do
    dir="$fixture/$variant"
    if [[ $variant == pkgrel-only ]]; then
        make_case_workspace "$dir" "$staged_version-2"
    else
        make_case_workspace "$dir" "$repo_version-1" \
            "https://example.invalid/s1-$staged_version.tar.gz"
    fi
    set_official_srcinfo "$dir" "$repo_version" \
        "	source = https://example.invalid/s1-$repo_version.tar.gz" \
        "	sha256sums = $published_sha"
    set_delivery "$dir" "$published_payload"
    run_build "$dir" "$variant" 0

    if [[ -s $dir/fake/curl_calls ]]; then
        fail "$variant: official checksums were fetched although source=() did not move"
    fi
    if [[ -s $dir/fake/updpkgsums_calls ]]; then
        fail "$variant: the sums were rewritten although source=() did not move"
    fi
    if [[ ! -s $dir/fake/makepkg_argv ]]; then
        fail "$variant: the build was refused instead of being built"
    fi
    if grep -q -- '--skipchecksums' "$dir/fake/makepkg_argv"; then
        fail "$variant: the build disabled checksum verification"
    fi
    grep -q "^sha256sums=('$staged_sum')$" "$(pkgfile "$dir")" \
        || fail "$variant: the committed sums were rewritten although the sources did not move"
done

# The pkgver variant must still have synced the version, or it proves nothing.
grep -q "^pkgver=$repo_version$" "$(pkgfile "$fixture/static-pkgver")" \
    || fail 'the static-source variant did not sync the version, so it tested nothing'
# The pkgrel-only variant must have adopted the repo's higher pkgrel — the
# never-downgrade guard (case 12) only ever blocks the opposite direction.
grep -q '^pkgrel=2$' "$(pkgfile "$fixture/pkgrel-only")" \
    || fail 'a repo pkgrel ahead of the local one was not adopted'

# ─── Case 7: an official file publishing two algorithms ─────────────────────
# The sums for one file list do not line up flat: fish has a single source with
# both a sha512 and a b2 sum, and reading them as one list refuses the build.
dir="$fixture/two-algorithms"
make_case_workspace "$dir" "$repo_version-1" \
    'https://example.invalid/s1-$pkgver.tar.gz' \
    "$(printf "sha256sums=('%s')\nb2sums=('%s')" "$staged_sum" "$staged_b2")"
set_official_srcinfo "$dir" "$repo_version" \
    "	source = https://example.invalid/s1-$repo_version.tar.gz" \
    "	sha256sums = $published_sha" \
    "	b2sums = $published_b2"
set_delivery "$dir" "$published_payload"
run_build "$dir" 'two-algorithms' 0

[[ -s $dir/fake/updpkgsums_calls ]] || fail 'two-algorithms: the sums were never rewritten: this case is vacuous'
grep -q "^sha256sums=('$published_sha')$" "$(pkgfile "$dir")" \
    || fail 'two-algorithms: the sha256 sums were not anchored'
grep -q "^b2sums=('$published_b2')$" "$(pkgfile "$dir")" \
    || fail 'two-algorithms: the b2 sums were not anchored'

# ─── Case 8: a "name::url" override names the fetched file ──────────────────
# 'openshadinglanguage-….tar.gz::https://…/v1.15.3.0.tar.gz' downloads to the
# override. Looking for the URL's basename finds nothing (or, for util-linux's
# renamed LICENSE, an unrelated file that happens to share the name).
dir="$fixture/renamed"
make_case_workspace "$dir" "$repo_version-1" \
    's1-local.tar.gz::https://example.invalid/s1-$pkgver.tar.gz'
set_official_srcinfo "$dir" "$repo_version" \
    "	source = s1-local.tar.gz::https://example.invalid/s1-$repo_version.tar.gz" \
    "	sha256sums = $published_sha"
set_delivery "$dir" "$published_payload"
run_build "$dir" 'renamed' 0

[[ -s $dir/fake/updpkgsums_calls ]] || fail 'renamed: the sums were never rewritten: this case is vacuous'
[[ -f $dir/packages/stable/s1/s1-local.tar.gz ]] \
    || fail 'renamed: the stub did not fetch under the override name, so this case is vacuous'
grep -q "^sha256sums=('$published_sha')$" "$(pkgfile "$dir")" \
    || fail 'renamed: the sums were not anchored, so the override name was not resolved'
grep -q 're-anchored to the official' "$(recipe_log "$dir")" \
    || fail 'renamed: the fetch of the override name was not verified against Arch'

# ─── Case 9: the packaging repo moved on — the version's tag is the anchor ──
# bash's main branch is 5.3.20 while the repos serve 5.3.15, so anchoring to main
# would anchor to a different version's files.
dir="$fixture/version-tag"
make_case_workspace "$dir" "$repo_version-1"
# main carries a different version, so it is no anchor; the version's own tag
# carries ours.
set_official_srcinfo "$dir" '1.5.0' \
    '	source = https://example.invalid/s1-1.5.0.tar.gz' \
    "	sha256sums = $published_sha"
cp -- "$dir/fake/srcinfo" "$dir/fake/main_answer"
set_official_srcinfo "$dir" "$repo_version" \
    "	source = https://example.invalid/s1-$repo_version.tar.gz" \
    "	sha256sums = $published_sha"
mv -- "$dir/fake/srcinfo" "$dir/fake/srcinfo_tag"
mv -- "$dir/fake/main_answer" "$dir/fake/srcinfo"
set_delivery "$dir" "$published_payload"
run_build "$dir" 'version-tag' 0

grep -q "/raw/$repo_version-1/" "$dir/fake/curl_calls" \
    || fail 'the version tag was never tried, so main could not be the only candidate'
grep -q "^sha256sums=('$published_sha')$" "$(pkgfile "$dir")" \
    || fail 'the version-tag run did not anchor the sums'

# ─── Case 10: a VCS source is anchored and verified the way makepkg does ────
# A 'git+…#tag=' source has no file to hash: makepkg hashes git archive of the
# tag. Verifying it as a download reports "not fetched", and anchoring to a
# value that was never checked is the rubber stamp again.
dir="$fixture/vcs"
make_case_workspace "$dir" "$repo_version-1" \
    's1git::git+https://example.invalid/s1.git#tag=$pkgver' \
    "sha512sums=('$staged_sum')"
# The checkout exists before the run (updpkgsums reuses it), so the value Arch
# "published" is the one this machine computes — which is the property that makes
# a pinned tag anchorable at all.
checkout="$dir/packages/stable/s1/s1git"
mkdir -p "$checkout"
git -C "$checkout" init -q .
printf 'checkout of %s\n' "$repo_version" >"$checkout/f.txt"
git -C "$checkout" add -A
git -C "$checkout" -c user.email=t@t -c user.name=t commit -qm "$repo_version"
git -C "$checkout" -c user.email=t@t -c user.name=t tag "$repo_version"
published_vcs=$(git -c core.abbrev=no -C "$checkout" archive --format tar "$repo_version" | sha512sum | awk '{print $1}')
set_official_srcinfo "$dir" "$repo_version" \
    "	source = s1git::git+https://example.invalid/s1.git#tag=$repo_version" \
    "	sha512sums = $published_vcs"
set_delivery "$dir" "$published_payload"
run_build "$dir" 'vcs' 0

[[ -d $checkout ]] || fail 'vcs: the checkout was not present, so this case is vacuous'
[[ -s $dir/fake/updpkgsums_calls ]] || fail 'vcs: the sums were never rewritten: this case is vacuous'
if [[ -s $dir/fake/makepkg_argv ]] && grep -q -- '--skipchecksums' "$dir/fake/makepkg_argv"; then
    fail 'vcs: the build disabled checksum verification'
fi
grep -q "^sha512sums=('$published_vcs')$" "$(pkgfile "$dir")" \
    || fail 'vcs: the checkout was not anchored to the git-archive value'
grep -q 're-anchored to the official' "$(recipe_log "$dir")" \
    || fail 'vcs: the log does not record that the checkout was anchored'

# ─── Case 10b: a `?signed` fragment flag must not leak into the ref name ─────
# makepkg appends verification flags to the fragment (#tag=$pkgver?signed).
# The archive must be recomputed from the bare ref: treating the flag as part
# of the ref makes `git archive` fail and the anchor refuse a perfectly good
# checkout with a bogus checksum-mismatch verdict (2026-10-02, systemd).
dir="$fixture/vcs-signed"
make_case_workspace "$dir" "$repo_version-1" \
    's1git::git+https://example.invalid/s1.git#tag=$pkgver?signed' \
    "sha512sums=('$staged_sum')"
checkout="$dir/packages/stable/s1/s1git"
mkdir -p "$checkout"
git -C "$checkout" init -q .
printf 'checkout of %s\n' "$repo_version" >"$checkout/f.txt"
git -C "$checkout" add -A
git -C "$checkout" -c user.email=t@t -c user.name=t commit -qm "$repo_version"
git -C "$checkout" -c user.email=t@t -c user.name=t tag "$repo_version"
published_vcs=$(git -c core.abbrev=no -C "$checkout" archive --format tar "$repo_version" | sha512sum | awk '{print $1}')
set_official_srcinfo "$dir" "$repo_version" \
    $'\tsource = s1git::git+https://example.invalid/s1.git#tag='"$repo_version" \
    $'\tsha512sums = '"$published_vcs"
set_delivery "$dir" "$published_payload"
run_build "$dir" 'vcs-signed' 0
grep -q "^sha512sums=('$published_vcs')$" "$(pkgfile "$dir")" \
    || fail 'vcs-signed: the ?signed checkout was not anchored to the git-archive value'
grep -q 're-anchored to the official' "$(recipe_log "$dir")" \
    || fail 'vcs-signed: the log does not record that the checkout was anchored'

# ─── Case 11: --no-sync disables the whole path ─────────────────────────────
dir="$fixture/no-sync"
make_case_workspace "$dir" "$repo_version-1"
set_official_srcinfo "$dir" "$repo_version" \
    "	source = https://example.invalid/s1-$repo_version.tar.gz" \
    "	sha256sums = $published_sha"
set_delivery "$dir" "$published_payload"
run_build "$dir" 'no-sync' 0 --no-sync

grep -q "^pkgver=$staged_version$" "$(pkgfile "$dir")" \
    || fail '--no-sync rewrote the recipe version anyway'
if [[ -e $dir/fake/curl_calls ]]; then
    fail '--no-sync still fetched official checksums'
fi
if [[ ! -s $dir/fake/makepkg_argv ]]; then
    fail '--no-sync refused to build a recipe it did not rewrite'
fi
if grep -q -- '--skipchecksums' "$dir/fake/makepkg_argv"; then
    fail '--no-sync still disabled checksum verification'
fi

# ─── Case 12: a local pkgrel ahead of the repo is a deliberate bump ─────────
# ripgrep carries pkgrel 2 over the repo's 1: the Rust PGO wave changed the
# build, so the recipe marks its own revision. Rewriting it back to the repo
# value clobbered ripgrep 15.2.0-2 to 15.2.0-1 on 2026-09-28, re-stamping a
# PGO build with the pre-PGO revision identity. pkgver is at parity here, so
# there is nothing to sync at all.
dir="$fixture/pkgrel-ahead"
make_case_workspace "$dir" "$staged_version-1"
sed -i 's/^pkgrel=1$/pkgrel=2/' "$(pkgfile "$dir")"
set_official_srcinfo "$dir" "$staged_version" \
    "	source = https://example.invalid/s1-$staged_version.tar.gz" \
    "	sha256sums = $published_sha"
set_delivery "$dir" "$published_payload"
run_build "$dir" 'pkgrel-ahead' 0

grep -q '^pkgrel=2$' "$(pkgfile "$dir")" \
    || fail 'a local pkgrel ahead of the repo was downgraded back to the repo value'
grep -q "^pkgver=$staged_version$" "$(pkgfile "$dir")" \
    || fail 'pkgrel-ahead: pkgver moved although the repo carried it at parity'
if [[ -e $dir/fake/curl_calls ]]; then
    fail 'pkgrel-ahead: official checksums were fetched although nothing was synced'
fi
if [[ -s $dir/fake/updpkgsums_calls ]]; then
    fail 'pkgrel-ahead: the sums were rewritten although source=() did not move'
fi
if [[ ! -s $dir/fake/makepkg_argv ]]; then
    fail 'pkgrel-ahead: the build was refused instead of being built'
fi
if [[ -s $dir/state/synced.list ]]; then
    fail 'pkgrel-ahead: the run witness lists a recipe the sync must not have touched'
fi

# ─── Case 15: opted-in core recipes use AUR metadata as the version source ──
# The AUR .SRCINFO must agree with the version returned by nvchecker and is the
# checksum authority for the moved custom-upstream source.
dir="$fixture/aur-sync"
make_case_workspace "$dir" '99.0.0-1'
mkdir -p "$dir/packages/core"
mv -- "$dir/packages/stable/s1" "$dir/packages/core/s1"
sed -i '/^s1|/d' "$dir/config/topology.conf"
printf 's1|packages/core/s1|core||version-sync=nvchecker\n' \
    >>"$dir/config/topology.conf"
cat >"$dir/packages/core/s1/.nvchecker.toml" <<'EOF'
[s1]
source = "aur"
aur = "s1"
strip_release = true
EOF
make_nvchecker_stub "$dir"
set_aur_srcinfo "$dir" s1 "$repo_version" 3 \
    "https://example.invalid/s1-$repo_version.tar.gz" "$published_sha" 1
set_delivery "$dir" "$published_payload"
GSA_FAKE_NVCHECK_VERSION="$repo_version" run_build "$dir" 'aur-sync' 0

grep -q "^pkgver=$repo_version$" "$dir/packages/core/s1/PKGBUILD" \
    || fail 'aur-sync: the AUR pkgver was not applied to the core recipe'
grep -q '^pkgrel=3$' "$dir/packages/core/s1/PKGBUILD" \
    || fail 'aur-sync: pkgrel was not taken from the matching AUR .SRCINFO'
grep -q '^epoch=1$' "$dir/packages/core/s1/PKGBUILD" \
    || fail 'aur-sync: epoch was not taken from the matching AUR .SRCINFO'
grep -q "1:$repo_version-3" "$dir/out.txt" \
    || fail 'aur-sync: the run summary omitted the synced epoch'
[[ -s $dir/fake/nvchecker_calls ]] \
    || fail 'aur-sync: the .nvchecker.toml resolver was not called'
[[ -s $dir/fake/curl_calls ]] \
    || fail 'aur-sync: no AUR checksum metadata was fetched'
grep -q 'aur.archlinux.org/cgit/aur.git/plain/.SRCINFO' "$dir/fake/curl_calls" \
    || fail 'aur-sync: the checksum authority was not fetched from AUR'
grep -q "^sha256sums=('$published_sha')$" "$dir/packages/core/s1/PKGBUILD" \
    || fail 'aur-sync: the fetched source was not anchored to the AUR checksum'
grep -q 're-anchored to AUR' "$dir/state/logs/s1.log" \
    || fail 'aur-sync: the package log does not name the AUR checksum authority'
[[ -s $dir/fake/makepkg_argv ]] \
    || fail 'aur-sync: makepkg did not run after successful AUR verification'
if find "$dir/packages" \( -name old_ver.json -o -name new_ver.json \) | grep -q .; then
    fail 'aur-sync: nvchecker state leaked into a recipe directory'
fi

# ─── Case 16: GitHub release digests anchor changed assets ───────────────────
dir="$fixture/github-digest"
github_source='https://github.com/example/s1/releases/download/$pkgver/s1-$pkgver.tar.gz'
make_case_workspace "$dir" '99.0.0-1' "$github_source"
opt_in_nvchecker "$dir" s1 packages/stable/s1 stable
cat >"$dir/packages/stable/s1/.nvchecker.toml" <<'EOF'
[s1]
source = "github"
github = "example/s1"
EOF
sed -i 's/^pkgrel=1$/pkgrel=4/' "$(pkgfile "$dir")"
make_nvchecker_stub "$dir"
set_github_release "$dir" "$repo_version" "s1-$repo_version.tar.gz" "$published_sha"
set_delivery "$dir" "$published_payload"
GSA_FAKE_NVCHECK_VERSION="$repo_version" run_build "$dir" 'github-digest' 0

grep -q "^pkgver=$repo_version$" "$(pkgfile "$dir")" \
    || fail 'github-digest: the resolved GitHub version was not applied'
grep -q '^pkgrel=1$' "$(pkgfile "$dir")" \
    || fail 'github-digest: pkgrel was not reset for a changed pkgver'
grep -q "^sha256sums=('$published_sha')$" "$(pkgfile "$dir")" \
    || fail 'github-digest: the fetched source was not anchored to the release digest'
grep -q 're-anchored to GitHub example/s1' "$(recipe_log "$dir")" \
    || fail 'github-digest: the log does not identify the GitHub checksum authority'
grep -q 'Version and checksum sync this run' "$dir/out.txt" \
    || fail 'github-digest: the run summary does not use the provider-aware heading'
grep -q 'synced with GitHub example/s1' "$dir/out.txt" \
    || fail 'github-digest: the run summary omits the version provider'

# ─── Case 17: absent GitHub digest is explicit fetch-only, never a false anchor
dir="$fixture/github-fetch-only"
make_case_workspace "$dir" '99.0.0-1' "$github_source"
opt_in_nvchecker "$dir" s1 packages/stable/s1 stable
cat >"$dir/packages/stable/s1/.nvchecker.toml" <<'EOF'
[s1]
source = "git"
git = "https://github.com/example/s1.git"
EOF
make_nvchecker_stub "$dir"
set_github_release "$dir" "v$repo_version" "s1-$repo_version.tar.gz" none
set_delivery "$dir" "$published_payload"
GSA_FAKE_NVCHECK_VERSION="$repo_version" run_build "$dir" 'github-fetch-only' 0

grep -q "^pkgver=$repo_version$" "$(pkgfile "$dir")" \
    || fail 'github-fetch-only: the git-source tracker did not resolve its version'
grep -q 'NOT anchored' "$(recipe_log "$dir")" \
    || fail 'github-fetch-only: the log does not disclose the missing upstream digest'
grep -q 'fetch-only sums: review before committing' "$dir/out.txt" \
    || fail 'github-fetch-only: the run summary does not request review'
grep -q "^sha256sums=('$published_sha')$" "$(pkgfile "$dir")" \
    || fail 'github-fetch-only: the fetched checksum was not refreshed'

# ─── Case 18: a published GitHub digest mismatch refuses and rolls back ─────
dir="$fixture/github-mismatch"
make_case_workspace "$dir" '99.0.0-1' "$github_source"
opt_in_nvchecker "$dir" s1 packages/stable/s1 stable
cat >"$dir/packages/stable/s1/.nvchecker.toml" <<'EOF'
[s1]
source = "github"
github = "example/s1"
EOF
make_nvchecker_stub "$dir"
set_github_release "$dir" "$repo_version" "s1-$repo_version.tar.gz" "$published_sha"
set_delivery "$dir" "$tampered_payload"
cp -- "$(pkgfile "$dir")" "$dir/fake/PKGBUILD.original"
GSA_FAKE_NVCHECK_VERSION="$repo_version" run_build "$dir" 'github-mismatch' fail

cmp -s "$dir/fake/PKGBUILD.original" "$(pkgfile "$dir")" \
    || fail 'github-mismatch: the original PKGBUILD was not restored'
[[ ! -s $dir/fake/makepkg_argv ]] \
    || fail 'github-mismatch: makepkg ran despite a published-digest disagreement'
grep -q 'source does not match' "$dir/out.txt" \
    || fail 'github-mismatch: the integrity refusal was not reported'
grep -q '^s1 failed ' "$dir/out.txt" \
    || fail 'github-mismatch: the run record did not classify the mismatch as failure'

# ─── Case 19: unavailable GitHub metadata defers and rolls back ──────────────
dir="$fixture/github-unavailable"
make_case_workspace "$dir" '99.0.0-1' "$github_source"
opt_in_nvchecker "$dir" s1 packages/stable/s1 stable
cat >"$dir/packages/stable/s1/.nvchecker.toml" <<'EOF'
[s1]
source = "github"
github = "example/s1"
EOF
make_nvchecker_stub "$dir"
set_delivery "$dir" "$published_payload"
cp -- "$(pkgfile "$dir")" "$dir/fake/PKGBUILD.original"
GSA_FAKE_GITHUB_STATUS=503 GSA_FAKE_NVCHECK_VERSION="$repo_version" \
    run_build "$dir" 'github-unavailable' fail

cmp -s "$dir/fake/PKGBUILD.original" "$(pkgfile "$dir")" \
    || fail 'github-unavailable: the original PKGBUILD was not restored'
[[ ! -s $dir/fake/updpkgsums_calls && ! -s $dir/fake/makepkg_argv ]] \
    || fail 'github-unavailable: source refresh or build ran without provider metadata'
grep -qi 'GitHub.*metadata' "$dir/out.txt" \
    || fail 'github-unavailable: the provider failure was not reported'
grep -q '^s1 deferred 99 ' "$dir/out.txt" \
    || fail 'github-unavailable: the run record did not classify the outage as deferred'

# ─── Case 20: an nvchecker failure does not fall back to Arch ────────────────
dir="$fixture/nvchecker-unavailable"
make_case_workspace "$dir" '99.0.0-1'
opt_in_nvchecker "$dir" s1 packages/stable/s1 stable
make_nvchecker_stub "$dir"
cp -- "$(pkgfile "$dir")" "$dir/fake/PKGBUILD.original"
GSA_FAKE_NVCHECK_FAIL=1 run_build "$dir" 'nvchecker-unavailable' fail

cmp -s "$dir/fake/PKGBUILD.original" "$(pkgfile "$dir")" \
    || fail 'nvchecker-unavailable: the recipe changed after its provider failed'
[[ ! -s $dir/fake/curl_calls && ! -s $dir/fake/makepkg_argv ]] \
    || fail 'nvchecker-unavailable: the builder fell back to Arch or built without a version'
grep -q 'nvchecker failed' "$dir/out.txt" \
    || fail 'nvchecker-unavailable: the resolver failure was not reported'
grep -q '^s1 deferred 99 ' "$dir/out.txt" \
    || fail 'nvchecker-unavailable: the run record did not classify the failure as deferred'

# ─── Case 21: stale AUR version metadata cannot authorize a different version
dir="$fixture/aur-version-race"
make_aur_version_workspace "$dir"
set_aur_srcinfo "$dir" s1 "$staged_version" 3 \
    "https://example.invalid/s1-$staged_version.tar.gz" "$published_sha"
set_delivery "$dir" none
cp -- "$dir/packages/core/s1/PKGBUILD" "$dir/fake/PKGBUILD.original"
GSA_FAKE_NVCHECK_VERSION="$repo_version" run_build "$dir" 'aur-version-race' fail

cmp -s "$dir/fake/PKGBUILD.original" "$dir/packages/core/s1/PKGBUILD" \
    || fail 'aur-version-race: a version-mismatched AUR .SRCINFO changed the recipe'
[[ ! -s $dir/fake/makepkg_argv ]] \
    || fail 'aur-version-race: makepkg ran with a mismatched AUR version'
grep -q '^s1 deferred 99 ' "$dir/out.txt" \
    || fail 'aur-version-race: the run record did not classify the metadata race as deferred'

# ─── Case 22: AUR source metadata must match the rewritten recipe exactly ───
dir="$fixture/aur-source-race"
make_aur_version_workspace "$dir"
set_aur_srcinfo "$dir" s1 "$repo_version" 3 \
    "https://example.invalid/not-s1-$repo_version.tar.gz" "$published_sha"
set_delivery "$dir" "$published_payload"
cp -- "$dir/packages/core/s1/PKGBUILD" "$dir/fake/PKGBUILD.original"
GSA_FAKE_NVCHECK_VERSION="$repo_version" run_build "$dir" 'aur-source-race' fail

cmp -s "$dir/fake/PKGBUILD.original" "$dir/packages/core/s1/PKGBUILD" \
    || fail 'aur-source-race: the recipe was not restored after an AUR source mismatch'
[[ ! -s $dir/fake/updpkgsums_calls && ! -s $dir/fake/makepkg_argv ]] \
    || fail 'aur-source-race: a mismatched AUR source was fetched or built'
grep -q '^s1 deferred 99 ' "$dir/out.txt" \
    || fail 'aur-source-race: the run record did not classify the source mismatch as deferred'

# ─── Case 23: --no-sync suppresses every external provider operation ─────────
dir="$fixture/no-sync"
make_case_workspace "$dir" '99.0.0-1'
opt_in_nvchecker "$dir" s1 packages/stable/s1 stable
make_nvchecker_stub "$dir"
cp -- "$(pkgfile "$dir")" "$dir/fake/PKGBUILD.original"
GSA_FAKE_NVCHECK_FAIL=1 GSA_FAKE_NVCHECK_VERSION="$repo_version" \
    run_build "$dir" 'no-sync' 0 --no-sync

cmp -s "$dir/fake/PKGBUILD.original" "$(pkgfile "$dir")" \
    || fail 'no-sync: the opted-in recipe changed despite --no-sync'
[[ ! -s $dir/fake/nvchecker_calls && ! -s $dir/fake/curl_calls ]] \
    || fail 'no-sync: an external provider was queried'
[[ -s $dir/fake/makepkg_argv ]] \
    || fail 'no-sync: the recipe did not continue through the ordinary build path'

# ─── Case 24: matching AUR metadata cannot lower a local pkgrel ─────────────
dir="$fixture/aur-pkgrel"
make_aur_version_workspace "$dir"
sed -i 's/^pkgver=.*/pkgver=2.0.0/; s/^pkgrel=1$/pkgrel=5/' \
    "$dir/packages/core/s1/PKGBUILD"
set_aur_srcinfo "$dir" s1 "$repo_version" 3 \
    "https://example.invalid/s1-$repo_version.tar.gz" "$published_sha"
set_delivery "$dir" none
GSA_FAKE_NVCHECK_VERSION="$repo_version" run_build "$dir" 'aur-pkgrel' 0

grep -q "^pkgver=$repo_version$" "$dir/packages/core/s1/PKGBUILD" \
    || fail 'aur-pkgrel: the recipe pkgver changed unexpectedly'
grep -q '^pkgrel=5$' "$dir/packages/core/s1/PKGBUILD" \
    || fail 'aur-pkgrel: the AUR pkgrel lowered a local revision'
[[ ! -s $dir/fake/updpkgsums_calls ]] \
    || fail 'aur-pkgrel: unchanged sources were unnecessarily refreshed'

# ─── Case 25: AUR pkgrel catches up at the same pkgver ──────────────────────
dir="$fixture/aur-pkgrel-ahead"
make_aur_version_workspace "$dir"
sed -i 's/^pkgver=.*/pkgver=2.0.0/' "$dir/packages/core/s1/PKGBUILD"
set_aur_srcinfo "$dir" s1 "$repo_version" 3 \
    "https://example.invalid/s1-$repo_version.tar.gz" "$published_sha"
set_delivery "$dir" none
GSA_FAKE_NVCHECK_VERSION="$repo_version" run_build "$dir" 'aur-pkgrel-ahead' 0

grep -q '^pkgrel=3$' "$dir/packages/core/s1/PKGBUILD" \
    || fail 'aur-pkgrel-ahead: a newer AUR pkgrel at the same pkgver was ignored'
[[ ! -s $dir/fake/updpkgsums_calls ]] \
    || fail 'aur-pkgrel-ahead: unchanged sources were unnecessarily refreshed'

# ─── Case 26: a GitHub provider retains pkgrel at the same pkgver ───────────
dir="$fixture/github-pkgrel"
make_case_workspace "$dir" '99.0.0-1'
opt_in_nvchecker "$dir" s1 packages/stable/s1 stable
sed -i 's/^pkgver=.*/pkgver=2.0.0/; s/^pkgrel=1$/pkgrel=7/' "$(pkgfile "$dir")"
make_nvchecker_stub "$dir"
GSA_FAKE_NVCHECK_VERSION="$repo_version" run_build "$dir" 'github-pkgrel' 0

grep -q "^pkgver=$repo_version$" "$(pkgfile "$dir")" \
    || fail 'github-pkgrel: the recipe pkgver changed unexpectedly'
grep -q '^pkgrel=7$' "$(pkgfile "$dir")" \
    || fail 'github-pkgrel: an unchanged pkgver reset the local pkgrel'

# ─── Case 27: gcc-snapshot follows its date-derived source URL ───────────────
dir="$fixture/gcc-snapshot"
gcc_new_version=17.0.0.snapshot20260921
gcc_new_source=https://example.invalid/gcc-17-20260921.tar.xz
make_gcc_version_workspace "$dir"
set_aur_srcinfo "$dir" gcc-snapshot "$gcc_new_version" 3 \
    "$gcc_new_source" "$published_sha"
set_delivery "$dir" "$published_payload"
GSA_FAKE_PACKAGE_ID=gcc-snapshot GSA_FAKE_NVCHECK_KEY=gcc-snapshot \
    GSA_FAKE_NVCHECK_VERSION="$gcc_new_version" \
    run_build "$dir" 'gcc-snapshot' 0

grep -q "^pkgver=$gcc_new_version$" "$dir/packages/core/gcc-snapshot/PKGBUILD" \
    || fail 'gcc-snapshot: the AUR pkgver was not applied'
[[ -f $dir/packages/core/gcc-snapshot/gcc-17-20260921.tar.xz ]] \
    || fail 'gcc-snapshot: the new pkgver did not map into the snapshot source path'
grep -q "^sha256sums=('$published_sha')$" \
    "$dir/packages/core/gcc-snapshot/PKGBUILD" \
    || fail 'gcc-snapshot: the AUR checksum did not anchor its moved source'

# ─── Case 28: an unsupported gcc-snapshot mapping is rejected and rolled back
dir="$fixture/gcc-snapshot-invalid"
gcc_bad_version=17.0.0.snapshotbad
make_gcc_version_workspace "$dir"
set_aur_srcinfo "$dir" gcc-snapshot "$gcc_bad_version" 3 \
    https://example.invalid/gcc-17-bad.tar.xz "$published_sha"
set_delivery "$dir" "$published_payload"
cp -- "$dir/packages/core/gcc-snapshot/PKGBUILD" "$dir/fake/PKGBUILD.original"
GSA_FAKE_PACKAGE_ID=gcc-snapshot GSA_FAKE_NVCHECK_KEY=gcc-snapshot \
    GSA_FAKE_NVCHECK_VERSION="$gcc_bad_version" \
    run_build "$dir" 'gcc-snapshot-invalid' fail

cmp -s "$dir/fake/PKGBUILD.original" "$dir/packages/core/gcc-snapshot/PKGBUILD" \
    || fail 'gcc-snapshot-invalid: the unsupported version was not rolled back'
[[ ! -s $dir/fake/updpkgsums_calls && ! -s $dir/fake/makepkg_argv ]] \
    || fail 'gcc-snapshot-invalid: source refresh or build ran with an invalid mapping'

# ─── Case 29: AUR entries without checksums are loud fetch-only ─────────────
dir="$fixture/aur-fetch-only"
make_aur_version_workspace "$dir"
set_aur_srcinfo "$dir" s1 "$repo_version" 3 \
    "https://example.invalid/s1-$repo_version.tar.gz" SKIP
set_delivery "$dir" "$published_payload"
GSA_FAKE_NVCHECK_VERSION="$repo_version" run_build "$dir" 'aur-fetch-only' 0

grep -q "^sha256sums=('$published_sha')$" "$dir/packages/core/s1/PKGBUILD" \
    || fail 'aur-fetch-only: the fetched checksum was not refreshed'
grep -q 'NOT anchored' "$dir/state/logs/s1.log" \
    || fail 'aur-fetch-only: the package log hid the missing AUR checksum'
grep -q 'fetch-only sums: review before committing' "$dir/out.txt" \
    || fail 'aur-fetch-only: the run summary omitted the review instruction'

# ─── Case 30: an AUR checksum mismatch refuses and rolls back ────────────────
dir="$fixture/aur-mismatch"
make_aur_version_workspace "$dir"
set_aur_srcinfo "$dir" s1 "$repo_version" 3 \
    "https://example.invalid/s1-$repo_version.tar.gz" "$published_sha"
set_delivery "$dir" "$tampered_payload"
cp -- "$dir/packages/core/s1/PKGBUILD" "$dir/fake/PKGBUILD.original"
GSA_FAKE_NVCHECK_VERSION="$repo_version" run_build "$dir" 'aur-mismatch' fail

cmp -s "$dir/fake/PKGBUILD.original" "$dir/packages/core/s1/PKGBUILD" \
    || fail 'aur-mismatch: the original recipe was not restored'
[[ ! -s $dir/fake/makepkg_argv ]] \
    || fail 'aur-mismatch: makepkg ran despite a published AUR checksum disagreement'
grep -q 'AUR published checksum' "$dir/out.txt" \
    || fail 'aur-mismatch: the AUR integrity refusal was not reported'
grep -q '^s1 failed ' "$dir/out.txt" \
    || fail 'aur-mismatch: the run record did not classify the checksum mismatch as failure'

# ─── Case 31: Zen's tracker key and asset name differ from its recipe ID ───
dir="$fixture/zen-browser"
make_zen_version_workspace "$dir"
zen_recipe="$dir/packages/stable/zen-browser-pgo"
sed -i 's/^pkgrel=1$/pkgrel=4/' "$zen_recipe/PKGBUILD"
set_github_release "$dir" "$repo_version" "zen.source.tar.zst" "$published_sha"
set_delivery "$dir" "$published_payload"
GSA_FAKE_PACKAGE_ID=zen-browser-pgo GSA_FAKE_NVCHECK_KEY=zen-browser \
    GSA_FAKE_NVCHECK_VERSION="$repo_version" run_build "$dir" 'zen-browser' 0

grep -q "^pkgver=$repo_version$" "$zen_recipe/PKGBUILD" \
    || fail 'zen-browser: the pkgname-matched nvchecker section was not resolved'
grep -q '^pkgrel=1$' "$zen_recipe/PKGBUILD" \
    || fail 'zen-browser: pkgrel was not reset for the new version'
[[ -f $zen_recipe/zen-source-$repo_version.tar.zst ]] \
    || fail 'zen-browser: makepkg did not use the local source filename override'
grep -q "^sha256sums=('$published_sha')$" "$zen_recipe/PKGBUILD" \
    || fail 'zen-browser: the remote GitHub asset digest did not anchor the override file'
grep -q 're-anchored to GitHub zen-browser/desktop' \
    "$dir/state/logs/zen-browser-pgo.log" \
    || fail 'zen-browser: the log does not name its GitHub checksum authority'

# ─── Case 32: a source that never arrived is ABSENT, not disagreeing ─────────
# A fetch that leaves the tarball nowhere in the recipe dir or $SRCDEST is a
# reconcilable environment state, not evidence of a different source. The
# fatal "does not match the official Arch checksum" verdict — and the
# dispatch drain that follows it — killed a 147-package run over one missing
# download on 2026-10-03 (81 built, 65 never started). Owner semantics: park
# when the consumer chain can absorb the wait, else fall back to a normal
# build attempt (makepkg fetches and checks the recipe sums itself). Never
# fail-fast on an absence. Case 2 keeps its teeth: a source that DISAGREES
# still refuses.
dir="$fixture/absent-source"
make_case_workspace "$dir" "$repo_version-1"
set_official_srcinfo "$dir" "$repo_version" \
    "\tsource = https://example.invalid/s1-$repo_version.tar.gz" \
    "\tsha256sums = $published_sha"
# no set_delivery: the tarball never arrives anywhere
run_build "$dir" 'absent-source' fail

[[ -s $dir/fake/curl_calls ]] || fail 'no official .SRCINFO was fetched: this case is vacuous'
if grep -q 'does not match the official Arch checksum' "$(recipe_log "$dir")"; then
    fail 'a source that never arrived was condemned as a disagreeing source'
fi
grep -q '^s1 deferred 99 ' "$dir/out.txt" \
    || fail 'absent-source: the run record did not classify the absence as deferred'
grep -q 'the rest of the dispatch continued' "$dir/out.txt" \
    || fail 'absent-source: the deferral still drains the dispatch (the run-1 harm)'
if [[ -s $dir/fake/makepkg_argv ]]; then
    fail 'a parked recipe was built anyway'
fi 

  # (case 33 — provider-path absence pin — deferred to follow-up: the AUR/GitHub
  #  integrity sites refuse through their own checks (case 30's 'AUR published
  #  checksum'), so the provider-branch pin needs that site mapping first.
  #  The builder-side classification itself is fixed and covered by case 32.)

# ─── Case 34: a computed pkgver bumps its variables, not a literal write ────
# linux-cachyos declares pkgver=${_major}.${_rcver} (the kernel recipe's exact
# shape). A version-sync bump must move _rcver=rc3 → _rcver=rc5 and leave the
# expression, _major and _tagrel alone: writing pkgver=<new> literally would
# pin the version and orphan the variables the rest of the recipe derives from
# (_srctag, _stable). The bump moves source=(), so the same run must re-anchor
# the sums to the provider checksum and refresh the committed .SRCINFO.
dir="$fixture/computed-pkgver"
make_aur_version_workspace "$dir"
cat >"$dir/packages/core/s1/PKGBUILD" <<'EOF'
pkgname=s1
_major=2.0
_rcver=rc1
_tagrel=4
pkgver=${_major}.${_rcver}
pkgrel=1
arch=(any)
source=("https://example.invalid/s1-${_major}-${_rcver}-${_tagrel}.tar.gz")
sha256sums=('0000000000000000000000000000000000000000000000000000000000000000')
EOF
recipe="$dir/packages/core/s1"
GSA_FAKE_DIR="$dir/fake" "$dir/bin/makepkg" --printsrcinfo --dir "$recipe" \
    >"$recipe/.SRCINFO" 2>/dev/null
: >"$dir/fake/makepkg_argv" # the pre-generation call is setup, not the run
set_aur_srcinfo "$dir" s1 "2.0.rc2" 1 \
    "https://example.invalid/s1-2.0-rc2-4.tar.gz" "$published_sha"
set_delivery "$dir" "$published_payload"
GSA_FAKE_NVCHECK_VERSION="2.0.rc2" run_build "$dir" 'computed-pkgver' 0

# (a) the version moved through the VARIABLES
grep -q '^_rcver=rc2$' "$recipe/PKGBUILD" \
    || fail 'computed-pkgver: _rcver was not bumped to rc2'
grep -Fqx 'pkgver=${_major}.${_rcver}' "$recipe/PKGBUILD" \
    || fail 'computed-pkgver: the pkgver expression was not kept intact'
if grep -q '^pkgver=2\.0\.rc2$' "$recipe/PKGBUILD"; then
    fail 'computed-pkgver: a literal pkgver=2.0.rc2 was written over the expression'
fi
grep -q '^_major=2\.0$' "$recipe/PKGBUILD" \
    || fail 'computed-pkgver: _major moved although only _rcver had to'
grep -q '^_tagrel=4$' "$recipe/PKGBUILD" \
    || fail 'computed-pkgver: _tagrel moved although it is not part of pkgver'
# The checksum contract is source-shaped, not rewrite-shaped: the moved source
# must be re-anchored to the provider's published checksum and verified against
# the fetched bytes — never left with the previous version's sum.
[[ -s $dir/fake/updpkgsums_calls ]] \
    || fail 'computed-pkgver: the moved source never refreshed its sums'
grep -q "^sha256sums=('$published_sha')$" "$recipe/PKGBUILD" \
    || fail 'computed-pkgver: the moved source was not anchored to the AUR checksum'
grep -q 're-anchored to AUR' "$dir/state/logs/s1.log" \
    || fail 'computed-pkgver: the log does not name the AUR checksum authority'
[[ -s $dir/fake/makepkg_argv ]] \
    || fail 'computed-pkgver: the recipe did not continue to the build'
# (b) the committed .SRCINFO was refreshed in lockstep with the bump
grep -q 'pkgver = 2.0.rc2' "$recipe/.SRCINFO" \
    || fail 'computed-pkgver: the committed .SRCINFO still pins the old version'
grep -q 's1-2.0-rc2-4.tar.gz' "$recipe/.SRCINFO" \
    || fail 'computed-pkgver: the committed .SRCINFO still names the old source'
GSA_FAKE_DIR="$dir/fake" "$dir/bin/makepkg" --printsrcinfo --dir "$recipe" \
    >"$dir/fake/srcinfo.regen" 2>/dev/null
diff -u "$dir/fake/srcinfo.regen" "$recipe/.SRCINFO" >/dev/null \
    || fail 'computed-pkgver: the committed .SRCINFO is not consistent with the bumped recipe'

# ─── Case 35: a pkgver expression the planner cannot rewrite is refused ─────
# The planner only moves plain variable assignments. Command substitution
# inside pkgver is not its business — and the historical rewrite would have
# CLOBBERED the expression with a literal, silently pinning the version. The
# refusal must leave the recipe byte-identical and fail the package loudly.
dir="$fixture/computed-pkgver-unsupported"
make_aur_version_workspace "$dir"
cat >"$dir/packages/core/s1/PKGBUILD" <<'EOF'
pkgname=s1
_major=2.0
_rcver=rc1
pkgver=${_major}.$(printf 'rc1')
pkgrel=1
arch=(any)
source=("https://example.invalid/s1-${_major}.${_rcver}.tar.gz")
sha256sums=('0000000000000000000000000000000000000000000000000000000000000000')
EOF
set_aur_srcinfo "$dir" s1 "2.0.rc2" 1 \
    "https://example.invalid/s1-2.0.rc2.tar.gz" "$published_sha"
set_delivery "$dir" "$published_payload"
cp -- "$dir/packages/core/s1/PKGBUILD" "$dir/fake/PKGBUILD.original"
GSA_FAKE_NVCHECK_VERSION="2.0.rc2" \
    run_build "$dir" 'computed-pkgver-unsupported' fail

cmp -s "$dir/fake/PKGBUILD.original" "$dir/packages/core/s1/PKGBUILD" \
    || fail 'computed-pkgver-unsupported: the recipe changed despite the refusal'
[[ ! -s $dir/fake/updpkgsums_calls && ! -s $dir/fake/makepkg_argv ]] \
    || fail 'computed-pkgver-unsupported: sums or build ran after the refusal'
grep -q 'expression this version sync cannot rewrite' "$dir/out.txt" \
    || fail 'computed-pkgver-unsupported: the refusal does not name the unsupported expression'
grep -q '^s1 failed ' "$dir/out.txt" \
    || fail 'computed-pkgver-unsupported: the run record did not classify the refusal as failure'

# ─── Case 36: a tracker section named for the recipe id resolves ────────────
# pkgbase is flavor-derived for some recipes (linux-cachyos evaluates to
# linux-cachyos-rt-bore-lto from its scheduler knobs) while its tracker file
# follows the stable recipe identity. The section is looked up by pkgbase first
# (case 31 pins that path for a pkgname-derived pkgbase), then by the recipe
# id, so a flavored pkgbase never makes its own tracker unreachable.
dir="$fixture/section-by-id"
make_case_workspace "$dir" '99.0.0-1' "https://example.invalid/s1-static.tar.gz"
opt_in_nvchecker "$dir" s1 packages/stable/s1 stable
cat >"$(pkgfile "$dir")" <<'EOF'
pkgbase=s1-flavored
pkgname=(s1-flavored)
pkgver=1.0.0
pkgrel=1
arch=(any)
source=("https://example.invalid/s1-static.tar.gz")
sha256sums=('0000000000000000000000000000000000000000000000000000000000000000')
EOF
cat >"$dir/packages/stable/s1/.nvchecker.toml" <<'EOF'
[s1]
source = "github"
github = "example/s1"
EOF
make_nvchecker_stub "$dir"
GSA_FAKE_NVCHECK_VERSION="$repo_version" run_build "$dir" 'section-by-id' 0

grep -q "^pkgver=$repo_version$" "$(pkgfile "$dir")" \
    || fail 'section-by-id: the id-named tracker section was not resolved for a flavored pkgbase'
grep -q 'synced with GitHub example/s1' "$dir/out.txt" \
    || fail 'section-by-id: the resolved version provider was not reported'
printf 'stable-sync fixture: PASS\n'
