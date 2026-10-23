#!/usr/bin/env bash
set -euo pipefail

# tests/stable-sync-checksums.sh — version-sync + checksum anchoring across
# stubbed providers, driven through the NATIVE engine (docs/gsa-contract.md
# §B.4/§B.8, §G.1, §H.2–§H.3). Stable recipes track the Arch repository
# version, tagged recipes track an upstream source; the engine rewrites
# pkgver/pkgrel in place and RE-ANCHORS the sums to the value the provider
# published for that version (rule 18), never to whatever the fetch delivered.
#
#   1. the sync really happens (pkgver rewritten) — otherwise the rest is
#      vacuous, which is the trap this fixture exists to avoid;
#   2. --skipchecksums is never passed to makepkg (the lane seam rejects
#      every verification-bypass token outright);
#   3. the recipe's checksums really are re-anchored, and verification runs;
#   4. a source that DISAGREES with the provider's published checksum is an
#      integrity stop: run-wide abort BEFORE any makepkg, the offending row
#      `failed 1 - integrity-stop`, every other row `never-started - -
#      startup-refused`, rc 3, recipe restored byte-identical;
#   5. no official checksum at our version (404, or a repo carrying another
#      version): the anchor is refused and the recipe DEFERS
#      (`anchoring-refused`), restored, never built;
#   6. an entry the provider publishes NO checksum for (SKIP or absent):
#      refreshed by updpkgsums instead of refused, recorded LOUDLY per entry
#      as fetch-only (no published value attests it) — the 2026-09-24 stance;
#   7. a version bump that does not move source=(): nothing is re-anchored
#      and the build runs against the sums already committed;
#   8. an official file publishing two algorithms for the same sources;
#   9. a "name::url" override resolves the fetched file by the override name;
#  10. the packaging repo moved past our version: the version's own tag is
#      the anchor instead;
#  11. a VCS source: anchored and verified the way makepkg verifies it
#      (`git archive --format tar <tag>` hashed), `?signed` never leaking
#      into the ref name;
#  12. --no-sync disables the whole path (no provider query, no rewrite);
#  13. the refresh itself fails (updpkgsums non-zero): named error, recipe
#      restored, makepkg never started, and the recipe DEFERS
#      (`anchoring-refused`) instead of killing the dispatch;
#  14. a local pkgrel ahead of the repo is a DELIBERATE bump and is never
#      rewritten back; only a repo pkgrel actually ahead is synced;
#  15-17. the opted-in nvchecker path (version-sync=nvchecker tag) resolves
#      AUR and GitHub versions, anchors to AUR .SRCINFO sums / GitHub release
#      digests, and treats an absent digest as loud fetch-only;
#  18/30. a published digest mismatch is an integrity stop (rows/restore of
#      case 4's shape) for both provider families;
#  19-22. provider outages and metadata races DEFER (anchoring-refused /
#      upstream-unverified / source-unfetchable) and restore — never an
#      invented version, never an anchor from mismatched metadata;
#  23. --no-sync skips the resolver, provider metadata, and recipe rewrites;
#  24-26. pkgrel policy: an upstream pkgrel adopts forward, never lowers a
#      local revision at the same pkgver, GitHub retains pkgrel at parity;
#  27-28. gcc-snapshot's date-derived source follows the bump; a mapping the
#      rewritten recipe cannot evaluate refuses and rolls back;
#  31. Zen's recipe id/pkgname difference and local source filename override
#      still bind the GitHub asset digest;
#  32. a source that never arrived is ABSENT, not disagreeing: defer
#      (source-unfetchable) and let the rest of the dispatch continue;
#  34-35. a computed pkgver=${var} recipe bumps its VARIABLES (never a
#      literal write over the expression) and refreshes .SRCINFO in lockstep;
#      a pkgver expression the planner cannot rewrite refuses and rolls back;
#  36. a tracker section named for the recipe id resolves for a flavored
#      pkgbase;
#  37. --skip never claims over upstream movement (the sync runs first);
#  38. a failed repo QUERY is not "the name is unknown": the failure names
#      itself and defers, the name-unknown answer syncs nothing;
#  39. repository version text the rewrite cannot write safely (`&`, `\`,
#      `/`) is refused BEFORE the first write;
#  40. a failure after the publish (artifact clear) rolls the rewrite back;
#  43. an unevaluable recipe is NAMED, never synced blind.
#
# Flip notes (docs/gsa-fixture-migration.md row `tests/stable-sync-checksums.sh`,
# REWRITE class): the engine under test is `gsa` (`-B --leaf` build runs,
# `gsa -Sy` sync-only runs, `run_engine`); fish-era prose greps re-pin against
# the fixture's MERGED FIXTURE_OUTPUT (policy/prose output goes to stderr) and
# outcome assertions against the `format: 2` run record via tests/lib/rr-v2.bash
# (§H.2–§H.3): integrity stop `failed 1 - integrity-stop` + `never-started - -
# startup-refused` rc 3 (§G.1), deferral `deferred 99 - <key>` + consumer cone
# `parked - - waits-on-deferred`, deferral-only rc 5. `gsa -Sy` prints the
# `Version and checksum sync this run` disposition block on stdout, emits NO
# run record, and exits 0/3/5. Retired fish-era sections, with reasons:
#   * case 41's sed-argv/.SRCINFO-tmp watch: the rewrite is Rust-side
#     (RecipeTransaction staging), no `sed` is ever invoked and the .SRCINFO
#     scratch is created after `makepkg --printsrcinfo` exits — the tool-
#     boundary pins cannot fire; their meaning (no scratch survives a run)
#     re-pins below;
#   * case 44 (-ccc/-ln naming unevaluable recipes): the engine's -M verbs
#     parse recipes (`gsa-recipe`) and never evaluate PKGBUILDs (gsa-maint
#     lib.rs), so no evaluation failure exists to name;
#   * case 45 (builder-cwd relocation noise): fish 4.9.3 in-process command
#     substitution machinery, nonexistent in a Rust process;
#   * the `DEFERRED` marker, resume-command prose, `synced.list` witness and
#     `Version and checksum sync this run` build-run summary are rendering
#     (§L.3): their meanings re-pin from run-record rows and the -Sy
#     disposition block.
# All external collaborators (pacman, curl, updpkgsums, makepkg, nvchecker,
# sleep) are stubs on PATH: no network, nothing is really built.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"

fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-stable-sync.XXXXXX")
# Root-safe cleanup: privileged runs leave root-owned state litter a user-side
# rm cannot unlink, and case 40's immutable artifact guard must be lifted
# first or the tree cannot go at all.
trap '/usr/bin/sudo -n chattr -i "$fixture/rollback/packages/stable/s1/src" 2>/dev/null || true; /usr/bin/sudo -n rm -rf -- "$fixture" 2>/dev/null || rm -rf -- "$fixture" 2>/dev/null || true' EXIT

command -v vercmp >/dev/null || {
    printf 'vercmp is required (it ships with pacman)\n' >&2
    exit 1
}
command -v sha256sum >/dev/null || {
    printf 'sha256sum is required\n' >&2
    exit 1
}
command -v b2sum >/dev/null || {
    printf 'b2sum is required (the two-algorithms case publishes b2)\n' >&2
    exit 1
}
command -v git >/dev/null || {
    printf 'git is required (the VCS case recomputes git archive)\n' >&2
    exit 1
}

# ─── Stub-knob vocabulary (§D.2: declared in the change that adds them) ─────
rr2_stub_knob GSA_FAKE_FETCH_ABSENT "stable-sync updpkgsums stub: rewrite sums from the fetch but leave no fetched file behind"
rr2_stub_knob GSA_FAKE_GITHUB_STATUS "stable-sync curl stub: HTTP status for GitHub release queries"
rr2_stub_knob GSA_FAKE_NVCHECK_FAIL "stable-sync nvchecker stub: requested resolver failure"
rr2_stub_knob GSA_FAKE_NVCHECK_KEY "stable-sync nvchecker stub: key written into the resolver state"
rr2_stub_knob GSA_FAKE_NVCHECK_VERSION "stable-sync nvchecker stub: resolved upstream version"

fail() {
    printf '\nFAIL: %s\n' "$1" >&2
    if [ -n "${2:-}" ] && [ -f "$2" ]; then
        sed 's/^/    /' "$2" >&2
    fi
    exit 1
}

# ─── The engine under test: the INSTALLED binary (contract §L.10);
# GSA_TEST_GSA_BIN is the explicit pre-install override (rr-v2.bash) ──────────────────────
if [ -z "${GSA_TEST_GSA_BIN:-}" ]; then
    GSA_TEST_GSA_BIN=$(command -v gsa) || {
        printf 'contract §L.10: no installed gsa on PATH — install gsa-pm, or set GSA_TEST_GSA_BIN explicitly\n' >&2
        exit 1
    }
fi
gsa_bin="$GSA_TEST_GSA_BIN"
[ -x "$gsa_bin" ] || fail "the engine under test is not executable: $gsa_bin"
export GSA_TEST_ENGINE=gsa
export GSA_TEST_GSA_BIN="$gsa_bin"

staged_version=1.0.0         # what the recipe pins
repo_version=2.0.0           # what the stub repo advertises
staged_sum=0000000000000000000000000000000000000000000000000000000000000000
staged_b2=11111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111111

# The bytes a provider published a checksum for, and different bytes the
# "fetch" will sometimes deliver instead.
published_payload="$fixture/published.tar.gz"
tampered_payload="$fixture/tampered.tar.gz"
printf 'the source a provider published a checksum for\n' >"$published_payload"
printf 'a different source entirely, same filename\n' >"$tampered_payload"
published_sha=$(sha256sum "$published_payload" | awk '{print $1}')
published_b2=$(b2sum "$published_payload" | awk '{print $1}')
tampered_sha=$(sha256sum "$tampered_payload" | awk '{print $1}')

# ─── The sandbox ────────────────────────────────────────────────────────────
# $1 = dir · $2 = the version the stub repo advertises · $3 = source entry
# (default: one whose URL spells $pkgver out) · $4 = the staged sum arrays.
# Skeleton synthesis comes from tests/lib/fixture-lib.bash; the recipe lives
# at the non-default path packages/stable/s1 with a fully parameterised
# PKGBUILD, so it is written here rather than via add_package. Providers
# shell out through PATH (crates/gsa-recipe/src/sync.rs): `pacman -Si` for
# the Arch version, `curl` (body + '%{http_code}' on stdout) for the official
# packaging repo's .SRCINFO, the AUR .SRCINFO and GitHub release JSON,
# `nvchecker` for the opted-in resolver, `updpkgsums` for the rewrite.
make_case_workspace() {
    local dir=$1 repo_full=$2
    local source_entry=${3:-'https://example.invalid/s1-$pkgver.tar.gz'}
    local sum_lines=${4:-"sha256sums=('$staged_sum')"}
    make_workspace "$dir" 1 2 low
    # The engine's retry backoffs and dispatcher polls are pure latency here —
    # nothing in this fixture asserts on wall-clock time (see stub_sleep).
    stub_sleep "$dir"
    mkdir -p "$dir/packages/stable/s1" "$dir/fake"
    printf 's1|packages/stable/s1|stable|\n' >>"$dir/config/topology.conf"

    # $pkgver must stay literal here: the anchoring reads the array by
    # sourcing the recipe, so the value has to come from the recipe's own
    # pkgver=. printf writes the entry verbatim — a heredoc would either
    # expand it now or need escaping that survives into the file.
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

    # The stub repository: the Arch provider runs `pacman -Si <name>`
    # (LC_ALL=C). The failure modes distinguish the two answers the engine
    # must never fold together: a name the repos do not know versus a query
    # that failed.
    cat >"$dir/bin/pacman" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == -Si ]]; then
    printf '%s\n' "$*" >>"$GSA_FAKE_DIR/pacman_calls"
    case ${GSA_FAKE_SI_MODE:-} in
        db-error)
            printf 'error: failed to synchronize all databases (unexpected error)\n' >&2
            exit 1
            ;;
        not-found)
            printf "error: package '%s' was not found\n" "$2" >&2
            exit 1
            ;;
    esac
    printf 'Repository      : extra\nName            : s1\nVersion         : %s\n' \
        "$(cat "$GSA_FAKE_DIR/repo_version")"
    exit 0
fi
exit 0
EOF
    chmod +x "$dir/bin/pacman"

    # Stands in for every provider metadata fetch (gitlab .SRCINFO, AUR
    # .SRCINFO, GitHub release JSON). The engine calls curl with
    # '--write-out %{http_code}' and reads BODY+CODE from stdout: the code is
    # the trailing 3-digit run after the body. An empty/absent answer is a
    # clean 404 (the main-vs-tag fallback depends on "absent" ≠ "broken").
    cat >"$dir/bin/curl" <<'EOF'
#!/usr/bin/env bash
url=""; write_out=""
while (($#)); do
    case $1 in
        -w|--write-out) write_out=$2; shift 2 ;;
        --max-time|--connect-timeout) shift 2 ;;
        -*) shift ;;
        *) url=$1; shift ;;
    esac
done
printf '%s\n' "$url" >>"$GSA_FAKE_DIR/curl_calls"
code=200
if [[ $url == *api.github.com/repos/*/releases/tags/* ]]; then
    tag=${url##*/}
    answer=$GSA_FAKE_DIR/github_release.$tag.json
    if [[ ! -s $answer ]]; then code=404; fi
elif [[ $url == *aur.archlinux.org/cgit/aur.git/plain/.SRCINFO* ]]; then
    answer=$GSA_FAKE_DIR/aur_srcinfo
elif [[ $url == */-/raw/main/.SRCINFO ]]; then
    answer=$GSA_FAKE_DIR/srcinfo
else
    answer=$GSA_FAKE_DIR/srcinfo_tag
fi
if [[ $code == 200 && ! -s $answer ]]; then code=404; fi
if [[ ${GSA_FAKE_GITHUB_STATUS:-200} != 200 && $url == *api.github.com* ]]; then
    code=${GSA_FAKE_GITHUB_STATUS}
fi
if [[ $code == 200 ]]; then
    cat -- "$answer"
fi
case $write_out in
    *http_code*) printf '%s' "$code" ;;
esac
exit 0
EOF
    chmod +x "$dir/bin/curl"

    # Stands in for makepkg's updater. It reproduces the three things the
    # engine depends on: the sources are fetched, a VCS source becomes a
    # checkout at its tag, and the sums are written in the recipe's own
    # algorithms — from whatever was fetched. GSA_FAKE_FETCH_ABSENT models
    # "the fetch left nothing anywhere": the sums are still rewritten, but no
    # file survives to verify (a reconcilable ABSENCE, never a disagreement).
    cat >"$dir/bin/updpkgsums" <<'EOF'
#!/usr/bin/env bash
dir=$(pwd)
buildfile=${1:-$dir/PKGBUILD}   # pacman-contrib's tool takes [build file]
set -e
set -o pipefail   # a failed git archive must fail the shim, never hash empty input
printf '%s\n' "$dir" >>"$GSA_FAKE_DIR/updpkgsums_calls"
[[ -s $GSA_FAKE_DIR/deliver ]] || exit 1          # nothing to fetch

mapfile -t sources < <(bash -c 'source "$1" >/dev/null 2>&1; printf "%s\n" "${source[@]}"' _ "$buildfile")
mapfile -t algos < <(bash -c 'source "$1" >/dev/null 2>&1; for a in sha256 sha512 b2; do declare -p "${a}sums" >/dev/null 2>&1 && printf "%s\n" "$a"; done' _ "$buildfile")

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
            if [[ -n ${GSA_FAKE_FETCH_ABSENT:-} ]]; then
                rm -f -- "$dir/$f"   # fetched "successfully", arrived nowhere
            fi
        fi
        line+="'$sum' "
    done
    sed -i "s|^${alg}sums=.*|${alg}sums=(${line% })|" "$buildfile"
done
EOF
    chmod +x "$dir/bin/updpkgsums"

    # Records the argv it was invoked with; on every refusal path it must
    # never be created at all. --printsrcinfo is pure metadata (the version
    # sync refreshes the committed .SRCINFO through it) — it models makepkg's
    # .SRCINFO shape from the recipe instead of building anything. The
    # computed-pkgver case asserts .SRCINFO consistency by regenerating
    # through this same code path and diffing.
    cat >"$dir/bin/makepkg" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$GSA_FAKE_DIR/makepkg_argv"
for arg in "$@"; do
    if [[ $arg == --printsrcinfo ]]; then
        dir=$PWD
        args=("$@")
        for ((i = 0; i < ${#args[@]}; i++)); do
            [[ ${args[i]} == --dir ]] && dir=${args[i + 1]}
        done
        [[ ${GSA_FAKE_PRINTSRCINFO_FAIL:-0} != 1 ]] || exit 1
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
[[ ${GSA_FAKE_MAKEPKG_FAIL:-0} != 1 ]] || exit 1
bash -c 'source ./PKGBUILD >/dev/null 2>&1; : >"$PWD/${pkgname[0]}-${pkgver}-${pkgrel}-any.pkg.tar.zst"' 2>/dev/null || exit 1
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

# The external-sync path still uses the real resolver seam. Only nvchecker
# itself is stubbed: it writes the configured key into the resolver's
# disposable new_ver.json state (the engine accepts the flat map shape).
make_nvchecker_stub() {
    local dir=$1
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
printf '{"%s":"%s"}\n' "${GSA_FAKE_NVCHECK_KEY:-s1}" "${GSA_FAKE_NVCHECK_VERSION:-}" >"$newver"
EOF
    chmod +x "$dir/bin/nvchecker"
}

opt_in_nvchecker() { # $1 = workspace · $2 = id · $3 = path · $4 = group
    local dir=$1 id=$2 path=$3 group=$4
    sed -i "\|^$id|d" "$dir/config/topology.conf"
    printf '%s|%s|%s||version-sync=nvchecker\n' "$id" "$path" "$group" \
        >>"$dir/config/topology.conf"
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

# ─── Engine drivers ─────────────────────────────────────────────────────────
base_path=$PATH
run_case() { # $1 = workspace · $2 = label · $3 = expected rc · extra args…
    local dir=$1 label=$2 expect=$3
    shift 3
    export PATH="$dir/bin:$base_path"
    export GSA_FAKE_DIR="$dir/fake"
    export GSA_FAKE_NVCHECK_VERSION="${GSA_FAKE_NVCHECK_VERSION:-}" \
        GSA_FAKE_NVCHECK_KEY="${GSA_FAKE_NVCHECK_KEY:-s1}" \
        GSA_FAKE_NVCHECK_FAIL="${GSA_FAKE_NVCHECK_FAIL:-0}" \
        GSA_FAKE_GITHUB_STATUS="${GSA_FAKE_GITHUB_STATUS:-200}" \
        GSA_FAKE_SI_MODE="${GSA_FAKE_SI_MODE:-}" \
        GSA_FAKE_PRINTSRCINFO_FAIL="${GSA_FAKE_PRINTSRCINFO_FAIL:-}" \
        GSA_FAKE_MAKEPKG_FAIL="${GSA_FAKE_MAKEPKG_FAIL:-}" \
        GSA_FAKE_FETCH_ABSENT="${GSA_FAKE_FETCH_ABSENT:-}"
    # targets may be several ids (GSA_FAKE_PACKAGE_ID, space-separated) and
    # must word-split; modifiers stay before the targets per `gsa --help`.
    local targets=${GSA_FAKE_PACKAGE_ID:-s1}
    run_engine "$dir" -B --leaf --intensity low --state-dir "$dir/state" \
        "$@" $targets
    printf '%s' "$FIXTURE_OUTPUT" >"$dir/out.txt"
    unset GSA_FAKE_NVCHECK_VERSION GSA_FAKE_NVCHECK_KEY GSA_FAKE_NVCHECK_FAIL \
        GSA_FAKE_GITHUB_STATUS GSA_FAKE_SI_MODE GSA_FAKE_PRINTSRCINFO_FAIL \
        GSA_FAKE_MAKEPKG_FAIL GSA_FAKE_FETCH_ABSENT GSA_FAKE_PACKAGE_ID
    if ((FIXTURE_RC != expect)); then
        fail "$label: engine exited $FIXTURE_RC, want $expect:" "$dir/out.txt"
    fi
}

run_sync() { # $1 = workspace · $2 = label · $3 = expected rc — the -Sy pass
    local dir=$1 label=$2 expect=$3
    export PATH="$dir/bin:$base_path"
    export GSA_FAKE_DIR="$dir/fake"
    export GSA_FAKE_NVCHECK_VERSION="${GSA_FAKE_NVCHECK_VERSION:-}" \
        GSA_FAKE_NVCHECK_KEY="${GSA_FAKE_NVCHECK_KEY:-s1}" \
        GSA_FAKE_NVCHECK_FAIL="${GSA_FAKE_NVCHECK_FAIL:-0}" \
        GSA_FAKE_GITHUB_STATUS="${GSA_FAKE_GITHUB_STATUS:-200}" \
        GSA_FAKE_SI_MODE="${GSA_FAKE_SI_MODE:-}"
    run_engine "$dir" -Sy
    printf '%s' "$FIXTURE_OUTPUT" >"$dir/out.txt"
    unset GSA_FAKE_NVCHECK_VERSION GSA_FAKE_NVCHECK_KEY GSA_FAKE_NVCHECK_FAIL \
        GSA_FAKE_GITHUB_STATUS GSA_FAKE_SI_MODE
    if ((FIXTURE_RC != expect)); then
        fail "$label: gsa -Sy exited $FIXTURE_RC, want $expect:" "$dir/out.txt"
    fi
    if grep -q -- '--- run record begin ---' <<<"$FIXTURE_OUTPUT"; then
        fail "$label: -Sy emitted a run record — the sync pass has none (§H):" "$dir/out.txt"
    fi
}

expect_row() { # $1 = label · $2 = pkg · $3 = status · $4 = rc · $5 = reason
    local label=$1 pkg=$2 st=$3 rc=$4 why=$5
    local got_st got_rc got_why
    got_st=$(rr2_outcome "$pkg" status <<<"$FIXTURE_OUTPUT")
    got_rc=$(rr2_outcome "$pkg" rc <<<"$FIXTURE_OUTPUT")
    got_why=$(rr2_outcome "$pkg" reason <<<"$FIXTURE_OUTPUT")
    [[ $got_st == "$st" ]] \
        || fail "$label: $pkg outcome status '$got_st', want '$st':" "$FIXTURE_OUTPUT"
    [[ $got_rc == "$rc" ]] \
        || fail "$label: $pkg outcome rc '$got_rc', want '$rc':" "$FIXTURE_OUTPUT"
    [[ $got_why == "$why" ]] \
        || fail "$label: $pkg outcome reason '$got_why', want '$why':" "$FIXTURE_OUTPUT"
}

expect_plan() { # $1 = label · $2 = pkg · $3 = plan · $4 = reason
    local label=$1 pkg=$2 plan=$3 why=$4
    [[ $(rr2_plan "$pkg" plan <<<"$FIXTURE_OUTPUT") == "$plan" ]] \
        || fail "$label: $pkg plan is not '$plan':" "$FIXTURE_OUTPUT"
    [[ $(rr2_plan "$pkg" reason <<<"$FIXTURE_OUTPUT") == "$why" ]] \
        || fail "$label: $pkg plan reason mismatch (want '$why'):" "$FIXTURE_OUTPUT"
}

pkgfile() { printf '%s/packages/stable/s1/PKGBUILD' "$1"; }

# ─── Case 1: anchored and verified — the happy path ─────────────────────────
dir="$fixture/anchor"
make_case_workspace "$dir" "$repo_version-1"
set_official_srcinfo "$dir" "$repo_version" \
    "	source = https://example.invalid/s1-$repo_version.tar.gz" \
    "	sha256sums = $published_sha"
set_delivery "$dir" "$published_payload"
make_nvchecker_stub "$dir"
run_case "$dir" 'anchor' 0

# Preconditions: the sync happened, and so did the anchoring — otherwise
# every assertion below could pass for the wrong reason.
grep -q "^pkgver=$repo_version$" "$(pkgfile "$dir")" \
    || fail 'the recipe was not version-synced, so this run cannot exercise the checksum path'
[[ -s $dir/fake/curl_calls ]] || fail 'no official .SRCINFO was fetched, so nothing was anchored to'
[[ -s $dir/fake/updpkgsums_calls ]] || fail 'the sums were never rewritten'
[[ -s $dir/fake/makepkg_argv ]] || fail 'makepkg never ran on the success path'
[[ ! -s $dir/fake/nvchecker_calls ]] \
    || fail 'an untagged .nvchecker.toml redirected the Arch version provider'

# The weakening is gone: the build is checksum-verified, not skipped.
if grep -q -- '--skipchecksums' "$dir/fake/makepkg_argv"; then
    fail 'a synced build still passed --skipchecksums to makepkg'
fi

# The recipe now carries the hash of a file that matched the published value,
# which is the whole point: not a hash of whatever arrived.
grep -q "^sha256sums=('$published_sha')$" "$(pkgfile "$dir")" \
    || fail 'the recipe does not carry the checksum of the verified source'
grep -q 'checksums re-anchored to' "$dir/out.txt" \
    || fail 'the run does not record that the checksums were re-anchored'
grep -q 'verified against the fetched sources' "$dir/out.txt" \
    || fail 'the anchoring is recorded without claiming verification against the fetch'
expect_row 'anchor' s1 succeeded 0 ok
expect_plan 'anchor' s1 build ok
[[ $(rr2_scalar order <<<"$FIXTURE_OUTPUT") == 's1' ]] \
    || fail "anchor: the record's order is not exactly the selection:" "$dir/out.txt"

# The transactional rewrite leaves no scratch behind (the case-41 semantic
# that survives the flip: no sed/tmp tool boundary exists in the engine).
if grep < <(find "$dir/packages/stable/s1" -name '*.tmp*' -print -quit) -q .; then
    fail 'a staged file survived the run'
fi

# ─── Case 2: a source that disagrees refuses the run (integrity stop) ───────
# This is the case that separates anchoring from rubber-stamping: hashing
# what arrived (updpkgsums alone) accepts this build.
dir="$fixture/tampered"
make_case_workspace "$dir" "$repo_version-1"
set_official_srcinfo "$dir" "$repo_version" \
    "	source = https://example.invalid/s1-$repo_version.tar.gz" \
    "	sha256sums = $published_sha"
set_delivery "$dir" "$tampered_payload"
run_case "$dir" 'tampered' 3

[[ -s $dir/fake/curl_calls ]] || fail 'no official .SRCINFO was fetched: this case is vacuous'
[[ -s $dir/fake/updpkgsums_calls ]] || fail 'the sums were never rewritten: this case is vacuous'
if [[ -s $dir/fake/makepkg_argv ]]; then
    fail 'makepkg ran for a source that disagrees with the checksum the provider published'
fi
grep -q 'source does not match' "$dir/out.txt" \
    || fail 'the refusal does not say that the source disagrees with the published checksum'
grep -q "$tampered_sha" "$dir/out.txt" \
    || fail 'the refusal does not name the hash the fetched source actually had'
grep -q "$published_sha" "$dir/out.txt" \
    || fail 'the refusal does not name the hash the provider published'
grep -q 'the recipe was restored' "$dir/out.txt" \
    || fail 'the integrity stop does not claim the recipe restore'
grep -q "^sha256sums=('$staged_sum')$" "$(pkgfile "$dir")" \
    || fail 'the recipe was left carrying a hash of the tampered source'
expect_row 'tampered' s1 failed 1 integrity-stop
expect_plan 'tampered' s1 build ok

# ─── Case 3: no official .SRCINFO at all (a recipe Arch does not carry) ─────
dir="$fixture/no-official"
make_case_workspace "$dir" "$repo_version-1"
: >"$dir/fake/srcinfo"                       # the fetch 404s
: >"$dir/fake/srcinfo_tag"
set_delivery "$dir" "$published_payload"
run_case "$dir" 'no-official' 5

grep -q 'carries no revision of' "$dir/out.txt" \
    || fail 'the refusal does not say that no official revision carries our version'
if [[ -s $dir/fake/makepkg_argv ]]; then
    fail 'makepkg ran without any anchor for the sums'
fi
if [[ -s $dir/fake/updpkgsums_calls ]]; then
    fail 'updpkgsums rewrote the sums without an anchor — that is the rubber stamp'
fi
grep -q "^sha256sums=('$staged_sum')$" "$(pkgfile "$dir")" \
    || fail 'the recipe was modified although nothing could be anchored'
expect_row 'no-official' s1 deferred 99 anchoring-refused

# ─── Case 4: the official repo carries a different version ──────────────────
# Anchoring to another version's checksums would be worse than not anchoring.
dir="$fixture/other-version"
make_case_workspace "$dir" "$repo_version-1"
set_official_srcinfo "$dir" '1.5.0' \
    '	source = https://example.invalid/s1-1.5.0.tar.gz' \
    "	sha256sums = $published_sha"
: >"$dir/fake/srcinfo_tag"
set_delivery "$dir" "$published_payload"
run_case "$dir" 'other-version' 5

grep -q 'the official packaging repo carries 1.5.0' "$dir/out.txt" \
    || fail 'the refusal does not say which version the official repo carries'
if [[ -s $dir/fake/makepkg_argv ]]; then
    fail 'makepkg ran against another version of the sums'
fi
grep -q "^sha256sums=('$staged_sum')$" "$(pkgfile "$dir")" \
    || fail 'the recipe was modified although the official version did not match'
expect_row 'other-version' s1 deferred 99 anchoring-refused

# ─── Case 5: an entry the provider does not cover is refreshed, LOUDLY ──────
# The official document matched our pkgver but publishes no checksum for a
# moved source (SKIP, or no entry at all). Since 2026-09-24 the sync runs
# updpkgsums over it instead of refusing the recipe — and records which
# entries were refreshed fetch-only, because nothing official attests them.
dir="$fixture/unanchored"
make_case_workspace "$dir" "$repo_version-1"
set_official_srcinfo "$dir" "$repo_version" \
    "	source = https://example.invalid/s1-$repo_version.tar.xz" \
    "	sha256sums = $published_sha"
set_delivery "$dir" "$published_payload"
run_case "$dir" 'unanchored' 0

[[ -s $dir/fake/updpkgsums_calls ]] \
    || fail 'unanchored: the sums were never refreshed — this case is vacuous'
[[ -s $dir/fake/makepkg_argv ]] \
    || fail 'unanchored: the build did not proceed after the refresh'
if grep -q -- '--skipchecksums' "$dir/fake/makepkg_argv"; then
    fail 'unanchored: the build disabled checksum verification'
fi
grep -q 'publishes no checksum for' "$dir/out.txt" \
    || fail 'the refresh does not record that the provider publishes no checksum for the entry'
grep -q 's1-2.0.0.tar.gz' "$dir/out.txt" \
    || fail 'the refresh does not name the fetch-only entry'
grep -q 'attested by nothing but the fetch' "$dir/out.txt" \
    || fail 'the refresh-only entry is recorded without saying what attests it'
grep -q "^sha256sums=('$published_sha')$" "$(pkgfile "$dir")" \
    || fail 'unanchored: the recipe does not carry the refreshed sum'
expect_row 'unanchored' s1 succeeded 0 ok

# The run-level surface: the owner must be told what to review and commit —
# the -Sy disposition block carries the fetch-only accounting (§B.4).
dir="$fixture/unanchored-sy"
make_case_workspace "$dir" "$repo_version-1"
set_official_srcinfo "$dir" "$repo_version" \
    "	source = https://example.invalid/s1-$repo_version.tar.xz" \
    "	sha256sums = $published_sha"
set_delivery "$dir" "$published_payload"
run_sync "$dir" 'unanchored-sy' 0
grep -q 'Version and checksum sync this run' "$dir/out.txt" \
    || fail 'the -Sy disposition block does not list the synced recipe as uncommitted work'
grep -q 'refresh-only (fetch-only sums: review before committing)' "$dir/out.txt" \
    || fail 'the -Sy disposition block does not flag the fetch-only refresh'
if [[ -s $dir/fake/makepkg_argv ]]; then
    fail 'unanchored-sy: the sync pass started a build'
fi

# ─── Case 5b: the refresh itself fails → named error, parked ────────────────
# Network down, upstream gone: updpkgsums exits non-zero. The recipe must be
# restored, the build refused with the named 'updpkgsums' error and the
# '--no-sync' escape hatch, makepkg never started — and the recipe must DEFER
# (`anchoring-refused`) rather than drop the whole dispatch.
dir="$fixture/refresh-fails"
make_case_workspace "$dir" "$repo_version-1"
set_official_srcinfo "$dir" "$repo_version" \
    "	source = https://example.invalid/s1-$repo_version.tar.xz" \
    "	sha256sums = $published_sha"
set_delivery "$dir" none                       # the updpkgsums stub exits 1
run_case "$dir" 'refresh-fails' 5

grep -q "'updpkgsums' could not refresh the checksums" "$dir/out.txt" \
    || fail 'refresh failure: the run does not carry the named updpkgsums error'
grep -q -- "use '--no-sync' to build the committed version" "$dir/out.txt" \
    || fail 'refresh failure: the --no-sync escape is no longer documented in the error'
if [[ -s $dir/fake/makepkg_argv ]]; then
    fail 'refresh failure: makepkg ran although nothing could be refreshed'
fi
grep -q "^sha256sums=('$staged_sum')$" "$(pkgfile "$dir")" \
    || fail 'refresh failure: the recipe was not restored to its pre-refresh sums'
expect_row 'refresh-fails' s1 deferred 99 anchoring-refused

# ─── Case 6: a bump that does not move source=() is not treated as stale ────
# 26 of the 28 stable recipes pin a literal version in the URL, so nothing
# they fetch changes and their committed sums still verify. Anchoring here
# would be a false alarm; re-hashing would be a gratuitous rewrite.
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
    run_case "$dir" "$variant" 0

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
    expect_row "$variant" s1 succeeded 0 ok
done

# The pkgver variant must still have synced the version, or it proves nothing.
grep -q "^pkgver=$repo_version$" "$(pkgfile "$fixture/static-pkgver")" \
    || fail 'the static-source variant did not sync the version, so it tested nothing'
# The pkgrel-only variant must have adopted the repo's higher pkgrel — the
# never-downgrade guard (case 12) only ever blocks the opposite direction.
grep -q '^pkgrel=2$' "$(pkgfile "$fixture/pkgrel-only")" \
    || fail 'a repo pkgrel ahead of the local one was not adopted'

# ─── Case 7: a provider file publishing two algorithms ──────────────────────
# The sums for one file list do not line up flat: one source with both a
# sha256 and a b2 sum, read as one list, would refuse the build.
dir="$fixture/two-algorithms"
make_case_workspace "$dir" "$repo_version-1" \
    'https://example.invalid/s1-$pkgver.tar.gz' \
    "$(printf "sha256sums=('%s')\nb2sums=('%s')" "$staged_sum" "$staged_b2")"
set_official_srcinfo "$dir" "$repo_version" \
    "	source = https://example.invalid/s1-$repo_version.tar.gz" \
    "	sha256sums = $published_sha" \
    "	b2sums = $published_b2"
set_delivery "$dir" "$published_payload"
run_case "$dir" 'two-algorithms' 0

[[ -s $dir/fake/updpkgsums_calls ]] || fail 'two-algorithms: the sums were never rewritten: this case is vacuous'
grep -q "^sha256sums=('$published_sha')$" "$(pkgfile "$dir")" \
    || fail 'two-algorithms: the sha256 sums were not anchored'
grep -q "^b2sums=('$published_b2')$" "$(pkgfile "$dir")" \
    || fail 'two-algorithms: the b2 sums were not anchored'

# ─── Case 8: a "name::url" override names the fetched file ──────────────────
# 'openshadinglanguage-….tar.gz::https://…/v1.15.3.0.tar.gz' downloads to the
# override. Looking for the URL's basename finds nothing (or an unrelated
# file that happens to share the name).
dir="$fixture/renamed"
make_case_workspace "$dir" "$repo_version-1" \
    's1-local.tar.gz::https://example.invalid/s1-$pkgver.tar.gz'
set_official_srcinfo "$dir" "$repo_version" \
    "	source = s1-local.tar.gz::https://example.invalid/s1-$repo_version.tar.gz" \
    "	sha256sums = $published_sha"
set_delivery "$dir" "$published_payload"
run_case "$dir" 'renamed' 0

[[ -s $dir/fake/updpkgsums_calls ]] || fail 'renamed: the sums were never rewritten: this case is vacuous'
[[ -f $dir/packages/stable/s1/s1-local.tar.gz ]] \
    || fail 'renamed: the stub did not fetch under the override name, so this case is vacuous'
grep -q "^sha256sums=('$published_sha')$" "$(pkgfile "$dir")" \
    || fail 'renamed: the sums were not anchored, so the override name was not resolved'
grep -q 'checksums re-anchored to' "$dir/out.txt" \
    || fail 'renamed: the fetch of the override name was not verified against the provider'

# ─── Case 9: the packaging repo moved on — the version's tag is the anchor ──
# bash's main branch is 5.3.20 while the repos serve 5.3.15, so anchoring to
# main would anchor to a different version's files.
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
run_case "$dir" 'version-tag' 0

grep -q "/raw/$repo_version-1/" "$dir/fake/curl_calls" \
    || fail 'the version tag was never tried, so main could not be the only candidate'
grep -q "^sha256sums=('$published_sha')$" "$(pkgfile "$dir")" \
    || fail 'the version-tag run did not anchor the sums'

# ─── Case 10: a VCS source is anchored and verified the way makepkg does ────
# A 'git+…#tag=' source has no file to hash: makepkg hashes git archive of
# the tag. Verifying it as a download reports "not fetched", and anchoring to
# a value that was never checked is the rubber stamp again.
dir="$fixture/vcs"
make_case_workspace "$dir" "$repo_version-1" \
    's1git::git+https://example.invalid/s1.git#tag=$pkgver' \
    "sha512sums=('$staged_sum')"
# The checkout exists before the run (updpkgsums reuses it), so the value the
# provider "published" is the one this machine computes — which is the
# property that makes a pinned tag anchorable at all.
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
run_case "$dir" 'vcs' 0

[[ -d $checkout ]] || fail 'vcs: the checkout was not present, so this case is vacuous'
[[ -s $dir/fake/updpkgsums_calls ]] || fail 'vcs: the sums were never rewritten: this case is vacuous'
if [[ -s $dir/fake/makepkg_argv ]] && grep -q -- '--skipchecksums' "$dir/fake/makepkg_argv"; then
    fail 'vcs: the build disabled checksum verification'
fi
grep -q "^sha512sums=('$published_vcs')$" "$(pkgfile "$dir")" \
    || fail 'vcs: the checkout was not anchored to the git-archive value'
grep -q 'checksums re-anchored to' "$dir/out.txt" \
    || fail 'vcs: the run does not record that the checkout was anchored'

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
run_case "$dir" 'vcs-signed' 0
grep -q "^sha512sums=('$published_vcs')$" "$(pkgfile "$dir")" \
    || fail 'vcs-signed: the ?signed checkout was not anchored to the git-archive value'

# ─── Case 11: --no-sync disables the whole path ─────────────────────────────
dir="$fixture/no-sync"
make_case_workspace "$dir" "$repo_version-1"
set_official_srcinfo "$dir" "$repo_version" \
    "	source = https://example.invalid/s1-$repo_version.tar.gz" \
    "	sha256sums = $published_sha"
set_delivery "$dir" "$published_payload"
run_case "$dir" 'no-sync' 0 --no-sync

grep -q "^pkgver=$staged_version$" "$(pkgfile "$dir")" \
    || fail '--no-sync rewrote the recipe version anyway'
if [[ -e $dir/fake/curl_calls || -e $dir/fake/pacman_calls ]]; then
    fail '--no-sync still queried a version or checksum provider'
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
run_case "$dir" 'pkgrel-ahead' 0

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

# ─── Case 15: opted-in core recipes use AUR metadata as the version source ──
# The AUR .SRCINFO must agree with the version resolved by nvchecker and is
# the checksum authority for the moved custom-upstream source.
dir="$fixture/aur-sync"
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
set_aur_srcinfo "$dir" s1 "$repo_version" 3 \
    "https://example.invalid/s1-$repo_version.tar.gz" "$published_sha" 1
set_delivery "$dir" "$published_payload"
GSA_FAKE_NVCHECK_VERSION="$repo_version" run_case "$dir" 'aur-sync' 0

grep -q "^pkgver=$repo_version$" "$dir/packages/core/s1/PKGBUILD" \
    || fail 'aur-sync: the AUR pkgver was not applied to the core recipe'
grep -q '^pkgrel=3$' "$dir/packages/core/s1/PKGBUILD" \
    || fail 'aur-sync: pkgrel was not taken from the matching AUR .SRCINFO'
grep -q '^epoch=1$' "$dir/packages/core/s1/PKGBUILD" \
    || fail 'aur-sync: epoch was not taken from the matching AUR .SRCINFO'
[[ -s $dir/fake/nvchecker_calls ]] \
    || fail 'aur-sync: the .nvchecker.toml resolver was not called'
[[ -s $dir/fake/curl_calls ]] \
    || fail 'aur-sync: no AUR checksum metadata was fetched'
grep -q 'aur.archlinux.org/cgit/aur.git/plain/.SRCINFO' "$dir/fake/curl_calls" \
    || fail 'aur-sync: the checksum authority was not fetched from AUR'
grep -q "^sha256sums=('$published_sha')$" "$dir/packages/core/s1/PKGBUILD" \
    || fail 'aur-sync: the fetched source was not anchored to the AUR checksum'
grep -q 're-anchored to' "$dir/out.txt" \
    || fail 'aur-sync: the run does not name the checksum authority'
[[ -s $dir/fake/makepkg_argv ]] \
    || fail 'aur-sync: makepkg did not run after successful AUR verification'
if grep < <(find "$dir/packages" \( -name old_ver.json -o -name new_ver.json \)) -q .; then
    fail 'aur-sync: nvchecker state leaked into a recipe directory'
fi
expect_row 'aur-sync' s1 succeeded 0 ok

# ─── Case 16: GitHub release digests anchor changed assets ──────────────────
github_source='https://github.com/example/s1/releases/download/$pkgver/s1-$pkgver.tar.gz'
dir="$fixture/github-digest"
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
GSA_FAKE_NVCHECK_VERSION="$repo_version" run_case "$dir" 'github-digest' 0

grep -q "^pkgver=$repo_version$" "$(pkgfile "$dir")" \
    || fail 'github-digest: the resolved GitHub version was not applied'
grep -q '^pkgrel=1$' "$(pkgfile "$dir")" \
    || fail 'github-digest: pkgrel was not reset for a changed pkgver'
grep -q "^sha256sums=('$published_sha')$" "$(pkgfile "$dir")" \
    || fail 'github-digest: the fetched source was not anchored to the release digest'
grep -q 'checksums re-anchored to' "$dir/out.txt" \
    || fail 'github-digest: the run does not identify the checksum authority'

# The provider-aware disposition wording lives on the -Sy surface (§B.4).
dir="$fixture/github-digest-sy"
make_case_workspace "$dir" '99.0.0-1' "$github_source"
opt_in_nvchecker "$dir" s1 packages/stable/s1 stable
cat >"$dir/packages/stable/s1/.nvchecker.toml" <<'EOF'
[s1]
source = "github"
github = "example/s1"
EOF
make_nvchecker_stub "$dir"
set_github_release "$dir" "$repo_version" "s1-$repo_version.tar.gz" "$published_sha"
set_delivery "$dir" "$published_payload"
GSA_FAKE_NVCHECK_VERSION="$repo_version" run_sync "$dir" 'github-digest-sy' 0
grep -q 'Version and checksum sync this run' "$dir/out.txt" \
    || fail 'github-digest-sy: the -Sy disposition block is missing'
grep -q 'synced with GitHub example/s1' "$dir/out.txt" \
    || fail 'github-digest-sy: the disposition block omits the version provider'

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
GSA_FAKE_NVCHECK_VERSION="$repo_version" run_case "$dir" 'github-fetch-only' 0

grep -q "^pkgver=$repo_version$" "$(pkgfile "$dir")" \
    || fail 'github-fetch-only: the git-source tracker did not resolve its version'
grep -q 'NOT anchored' "$dir/out.txt" \
    || fail 'github-fetch-only: the run does not disclose the missing upstream digest'
grep -q 'Review these sums before committing' "$dir/out.txt" \
    || fail 'github-fetch-only: the run does not request review'
grep -q "^sha256sums=('$published_sha')$" "$(pkgfile "$dir")" \
    || fail 'github-fetch-only: the fetched checksum was not refreshed'
expect_row 'github-fetch-only' s1 succeeded 0 ok

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
GSA_FAKE_NVCHECK_VERSION="$repo_version" run_case "$dir" 'github-mismatch' 3

cmp -s "$dir/fake/PKGBUILD.original" "$(pkgfile "$dir")" \
    || fail 'github-mismatch: the original PKGBUILD was not restored'
[[ ! -s $dir/fake/makepkg_argv ]] \
    || fail 'github-mismatch: makepkg ran despite a published-digest disagreement'
grep -q 'source does not match' "$dir/out.txt" \
    || fail 'github-mismatch: the integrity refusal was not reported'
expect_row 'github-mismatch' s1 failed 1 integrity-stop

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
    run_case "$dir" 'github-unavailable' 5

cmp -s "$dir/fake/PKGBUILD.original" "$(pkgfile "$dir")" \
    || fail 'github-unavailable: the original PKGBUILD was not restored'
[[ ! -s $dir/fake/updpkgsums_calls && ! -s $dir/fake/makepkg_argv ]] \
    || fail 'github-unavailable: source refresh or build ran without provider metadata'
grep -q 'metadata is unavailable' "$dir/out.txt" \
    || fail 'github-unavailable: the provider failure was not reported'
expect_row 'github-unavailable' s1 deferred 99 anchoring-refused

# ─── Case 20: an nvchecker failure does not fall back to Arch ────────────────
dir="$fixture/nvchecker-unavailable"
make_case_workspace "$dir" '99.0.0-1'
opt_in_nvchecker "$dir" s1 packages/stable/s1 stable
make_nvchecker_stub "$dir"
cp -- "$(pkgfile "$dir")" "$dir/fake/PKGBUILD.original"
GSA_FAKE_NVCHECK_FAIL=1 run_case "$dir" 'nvchecker-unavailable' 5

cmp -s "$dir/fake/PKGBUILD.original" "$(pkgfile "$dir")" \
    || fail 'nvchecker-unavailable: the recipe changed after its provider failed'
[[ ! -s $dir/fake/pacman_calls && ! -s $dir/fake/curl_calls && ! -s $dir/fake/makepkg_argv ]] \
    || fail 'nvchecker-unavailable: the engine fell back to Arch or built without a version'
grep -q 'nvchecker failed' "$dir/out.txt" \
    || fail 'nvchecker-unavailable: the resolver failure was not reported'
expect_row 'nvchecker-unavailable' s1 deferred 99 anchoring-refused

# ─── Case 21: stale AUR version metadata cannot authorize a different version
dir="$fixture/aur-version-race"
make_aur_version_workspace "$dir"
set_aur_srcinfo "$dir" s1 "$staged_version" 3 \
    "https://example.invalid/s1-$staged_version.tar.gz" "$published_sha"
set_delivery "$dir" none
cp -- "$dir/packages/core/s1/PKGBUILD" "$dir/fake/PKGBUILD.original"
GSA_FAKE_NVCHECK_VERSION="$repo_version" run_case "$dir" 'aur-version-race' 5

cmp -s "$dir/fake/PKGBUILD.original" "$dir/packages/core/s1/PKGBUILD" \
    || fail 'aur-version-race: a version-mismatched AUR .SRCINFO changed the recipe'
[[ ! -s $dir/fake/makepkg_argv ]] \
    || fail 'aur-version-race: makepkg ran with a mismatched AUR version'
expect_row 'aur-version-race' s1 deferred 99 anchoring-refused

# ─── Case 22: AUR source metadata must cover the rewritten recipe exactly ───
# A provider source list that does not carry the recipe's own sources defers
# (URL drift is indistinguishable from a different file). The converse — a
# published SUPERSET with provider-only files — anchors fine; case 46 pins it.
dir="$fixture/aur-source-race"
make_aur_version_workspace "$dir"
set_aur_srcinfo "$dir" s1 "$repo_version" 3 \
    "https://example.invalid/not-s1-$repo_version.tar.gz" "$published_sha"
set_delivery "$dir" "$published_payload"
cp -- "$dir/packages/core/s1/PKGBUILD" "$dir/fake/PKGBUILD.original"
GSA_FAKE_NVCHECK_VERSION="$repo_version" run_case "$dir" 'aur-source-race' 5

cmp -s "$dir/fake/PKGBUILD.original" "$dir/packages/core/s1/PKGBUILD" \
    || fail 'aur-source-race: the recipe was not restored after an AUR source mismatch'
[[ ! -s $dir/fake/updpkgsums_calls && ! -s $dir/fake/makepkg_argv ]] \
    || fail 'aur-source-race: a mismatched AUR source was fetched or built'
grep -q 'do not cover every source' "$dir/out.txt" \
    || fail 'aur-source-race: the coverage refusal is not named'
expect_row 'aur-source-race' s1 deferred 99 anchoring-refused

# ─── Case 23: --no-sync suppresses every external provider operation ─────────
dir="$fixture/no-sync-tagged"
make_case_workspace "$dir" '99.0.0-1'
opt_in_nvchecker "$dir" s1 packages/stable/s1 stable
make_nvchecker_stub "$dir"
cp -- "$(pkgfile "$dir")" "$dir/fake/PKGBUILD.original"
GSA_FAKE_NVCHECK_FAIL=1 GSA_FAKE_NVCHECK_VERSION="$repo_version" \
    run_case "$dir" 'no-sync-tagged' 0 --no-sync

cmp -s "$dir/fake/PKGBUILD.original" "$(pkgfile "$dir")" \
    || fail 'no-sync: the opted-in recipe changed despite --no-sync'
[[ ! -s $dir/fake/nvchecker_calls && ! -s $dir/fake/curl_calls && ! -s $dir/fake/pacman_calls ]] \
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
GSA_FAKE_NVCHECK_VERSION="$repo_version" run_case "$dir" 'aur-pkgrel' 0

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
GSA_FAKE_NVCHECK_VERSION="$repo_version" run_case "$dir" 'aur-pkgrel-ahead' 0

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
set_delivery "$dir" none
GSA_FAKE_NVCHECK_VERSION="$repo_version" run_case "$dir" 'github-pkgrel' 0

grep -q "^pkgver=$repo_version$" "$(pkgfile "$dir")" \
    || fail 'github-pkgrel: the recipe pkgver changed unexpectedly'
grep -q '^pkgrel=7$' "$(pkgfile "$dir")" \
    || fail 'github-pkgrel: an unchanged pkgver reset the local pkgrel'

# ─── Case 27: gcc-snapshot follows its date-derived source URL ───────────────
# The mapping lives in the PKGBUILD itself (pkgver=…snapshotYYYYMMDD derives
# _pkgver), so a literal pkgver bump moves the source it names.
gcc_new_version=17.0.0.snapshot20260921
gcc_new_source=https://example.invalid/gcc-17-20260921.tar.xz
dir="$fixture/gcc-snapshot"
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
set_aur_srcinfo "$dir" gcc-snapshot "$gcc_new_version" 3 \
    "$gcc_new_source" "$published_sha"
set_delivery "$dir" "$published_payload"
GSA_FAKE_PACKAGE_ID=gcc-snapshot GSA_FAKE_NVCHECK_KEY=gcc-snapshot \
    GSA_FAKE_NVCHECK_VERSION="$gcc_new_version" \
    run_case "$dir" 'gcc-snapshot' 0

grep -q "^pkgver=$gcc_new_version$" "$dir/packages/core/gcc-snapshot/PKGBUILD" \
    || fail 'gcc-snapshot: the AUR pkgver was not applied'
[[ -f $dir/packages/core/gcc-snapshot/gcc-17-20260921.tar.xz ]] \
    || fail 'gcc-snapshot: the new pkgver did not map into the snapshot source path'
grep -q "^sha256sums=('$published_sha')$" \
    "$dir/packages/core/gcc-snapshot/PKGBUILD" \
    || fail 'gcc-snapshot: the AUR checksum did not anchor its moved source'

# ─── Case 28: an invalid snapshot mapping is rejected and rolled back ───────
# The rewritten pkgver no longer evaluates through the recipe's own mapping
# rule: the source array cannot be read, so the rewrite refuses and restores
# — never a blind anchor over a version the recipe cannot express.
gcc_bad_version=17.0.0.snapshotbad
dir="$fixture/gcc-snapshot-invalid"
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
set_aur_srcinfo "$dir" gcc-snapshot "$gcc_bad_version" 3 \
    https://example.invalid/gcc-17-bad.tar.xz "$published_sha"
set_delivery "$dir" "$published_payload"
cp -- "$dir/packages/core/gcc-snapshot/PKGBUILD" "$dir/fake/PKGBUILD.original"
GSA_FAKE_PACKAGE_ID=gcc-snapshot GSA_FAKE_NVCHECK_KEY=gcc-snapshot \
    GSA_FAKE_NVCHECK_VERSION="$gcc_bad_version" \
    run_case "$dir" 'gcc-snapshot-invalid' 3

cmp -s "$dir/fake/PKGBUILD.original" "$dir/packages/core/gcc-snapshot/PKGBUILD" \
    || fail 'gcc-snapshot-invalid: the unsupported version was not rolled back'
[[ ! -s $dir/fake/updpkgsums_calls && ! -s $dir/fake/makepkg_argv ]] \
    || fail 'gcc-snapshot-invalid: source refresh or build ran with an invalid mapping'
expect_row 'gcc-snapshot-invalid' gcc-snapshot failed 1 sync-refused

# ─── Case 29: AUR entries without checksums are loud fetch-only ─────────────
dir="$fixture/aur-fetch-only"
make_aur_version_workspace "$dir"
set_aur_srcinfo "$dir" s1 "$repo_version" 3 \
    "https://example.invalid/s1-$repo_version.tar.gz" SKIP
set_delivery "$dir" "$published_payload"
GSA_FAKE_NVCHECK_VERSION="$repo_version" run_case "$dir" 'aur-fetch-only' 0

grep -q "^sha256sums=('$published_sha')$" "$dir/packages/core/s1/PKGBUILD" \
    || fail 'aur-fetch-only: the fetched checksum was not refreshed'
grep -q 'NOT anchored' "$dir/out.txt" \
    || fail 'aur-fetch-only: the run hid the missing AUR checksum'
grep -q 'Review these sums before committing' "$dir/out.txt" \
    || fail 'aur-fetch-only: the run omitted the review instruction'

# ─── Case 30: an AUR checksum mismatch refuses and rolls back ────────────────
dir="$fixture/aur-mismatch"
make_aur_version_workspace "$dir"
set_aur_srcinfo "$dir" s1 "$repo_version" 3 \
    "https://example.invalid/s1-$repo_version.tar.gz" "$published_sha"
set_delivery "$dir" "$tampered_payload"
cp -- "$dir/packages/core/s1/PKGBUILD" "$dir/fake/PKGBUILD.original"
GSA_FAKE_NVCHECK_VERSION="$repo_version" run_case "$dir" 'aur-mismatch' 3

cmp -s "$dir/fake/PKGBUILD.original" "$dir/packages/core/s1/PKGBUILD" \
    || fail 'aur-mismatch: the original recipe was not restored'
[[ ! -s $dir/fake/makepkg_argv ]] \
    || fail 'aur-mismatch: makepkg ran despite a published AUR checksum disagreement'
grep -q 'source does not match' "$dir/out.txt" \
    || fail 'aur-mismatch: the AUR integrity refusal was not reported'
grep -q "$published_sha" "$dir/out.txt" \
    || fail 'aur-mismatch: the refusal does not name the AUR published value'
expect_row 'aur-mismatch' s1 failed 1 integrity-stop

# ─── Case 31: Zen's recipe id/pkgname difference and source filename override ─
# zen-browser-pgo builds pkgname zen-browser and downloads its GitHub asset
# under a LOCAL NAME override (zen-source-$pkgver.tar.zst::…/zen.source.tar.zst):
# the remote ASSET digest binds the remote basename while verification hashes
# the override file the fetch actually produced. (The fish-era "pkgname-matched
# tracker section" half does not survive the flip: prepare.rs's
# nvchecker_provider keys are pkgbase-or-directory only and never the single
# pkgname that RecipeInfo::read falls back to, so the real recipe's
# `[zen-browser]` section is refused as "cannot classify the nvchecker
# provider" — an ENGINE BUG recorded in the flip report with evidence, not
# pinned here. Section-resolution semantics that DO work are case 36's.)
dir="$fixture/zen-browser"
local_source_entry='zen-source-$pkgver.tar.zst::https://github.com/zen-browser/desktop/releases/download/$pkgver/zen.source.tar.zst'
make_case_workspace "$dir" '99.0.0-1' "$local_source_entry"
mv -- "$dir/packages/stable/s1" "$dir/packages/stable/zen-browser-pgo"
sed -i '/^s1|/d' "$dir/config/topology.conf"
printf 'zen-browser-pgo|packages/stable/zen-browser-pgo|stable||version-sync=nvchecker\n' \
    >>"$dir/config/topology.conf"
sed -i 's/^pkgname=s1$/pkgname=zen-browser/' \
    "$dir/packages/stable/zen-browser-pgo/PKGBUILD"
cat >"$dir/packages/stable/zen-browser-pgo/.nvchecker.toml" <<'EOF'
[zen-browser-pgo]
source = "github"
github = "zen-browser/desktop"
EOF
make_nvchecker_stub "$dir"
zen_recipe="$dir/packages/stable/zen-browser-pgo"
sed -i 's/^pkgrel=1$/pkgrel=4/' "$zen_recipe/PKGBUILD"
set_github_release "$dir" "$repo_version" "zen.source.tar.zst" "$published_sha"
set_delivery "$dir" "$published_payload"
GSA_FAKE_PACKAGE_ID=zen-browser-pgo GSA_FAKE_NVCHECK_KEY=zen-browser \
    GSA_FAKE_NVCHECK_VERSION="$repo_version" run_case "$dir" 'zen-browser' 0

grep -q "^pkgver=$repo_version$" "$zen_recipe/PKGBUILD" \
    || fail 'zen-browser: the resolved GitHub version was not applied to the id/pkgname-split recipe'
grep -q '^pkgrel=1$' "$zen_recipe/PKGBUILD" \
    || fail 'zen-browser: pkgrel was not reset for the new version'
[[ -f $zen_recipe/zen-source-$repo_version.tar.zst ]] \
    || fail 'zen-browser: the local source filename override was not fetched'
grep -q "^sha256sums=('$published_sha')$" "$zen_recipe/PKGBUILD" \
    || fail 'zen-browser: the remote GitHub asset digest did not anchor the override file'

# ─── Case 32: a source that never arrived is ABSENT, not disagreeing ─────────
# A fetch that leaves the tarball nowhere is a reconcilable environment
# state, not evidence of a different source. The fatal "does not match"
# verdict — and the dispatch drain that follows it — killed a 147-package run
# over one missing download on 2026-10-03. Owner semantics: park (defer) and
# let the rest of the dispatch continue. Case 2 keeps its teeth: a source
# that DISAGREES still refuses.
dir="$fixture/absent-source"
make_case_workspace "$dir" "$repo_version-1"
add_package "$dir" other "$gsa_meta_any" git
set_official_srcinfo "$dir" "$repo_version" \
    $'\tsource = https://example.invalid/s1-'"$repo_version"$'.tar.gz' \
    $'\tsha256sums = '"$published_sha"
set_delivery "$dir" "$published_payload"
cp -- "$(pkgfile "$dir")" "$dir/fake/PKGBUILD.original"
export GSA_FAKE_PACKAGE_ID='s1 other'
GSA_FAKE_FETCH_ABSENT=1 run_case "$dir" 'absent-source' 5

[[ -s $dir/fake/curl_calls ]] || fail 'no official .SRCINFO was fetched: this case is vacuous'
if grep -q 'source does not match' "$dir/out.txt"; then
    fail 'a source that never arrived was condemned as a disagreeing source'
fi
cmp -s "$dir/fake/PKGBUILD.original" "$(pkgfile "$dir")" \
    || fail 'absent-source: the recipe was not restored after the deferral'
expect_row 'absent-source' s1 deferred 99 source-unfetchable
# THE POINT: the rest of the dispatch continued.
expect_row 'absent-source' other succeeded 0 ok
if grep < <(find "$dir/packages/stable/s1" -name '*.pkg.tar.zst' -print -quit) -q .; then
    fail 'a parked recipe was built anyway'
fi

#  (case 33 — provider-path absence pin — stays deferred for follow-up, as in
#   the fish fixture: the provider-branch sites refuse through their own
#   checks (cases 18/30), the builder-side classification is case 32.)

# ─── Case 34: a computed pkgver bumps its variables, not a literal write ────
# linux-cachyos declares pkgver=${_major}.${_rcver}. A version-sync bump must
# move _rcver=rc1 → _rcver=rc2 and leave the expression, _major and _tagrel
# alone: writing pkgver=<new> literally would pin the version and orphan the
# variables the rest of the recipe derives from. The bump moves source=(), so
# the same run must re-anchor the sums and refresh the committed .SRCINFO.
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
GSA_FAKE_NVCHECK_VERSION="2.0.rc2" run_case "$dir" 'computed-pkgver' 0

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
# must be re-anchored to the provider's published checksum and verified
# against the fetched bytes — never left with the previous version's sum.
[[ -s $dir/fake/updpkgsums_calls ]] \
    || fail 'computed-pkgver: the moved source never refreshed its sums'
grep -q "^sha256sums=('$published_sha')$" "$recipe/PKGBUILD" \
    || fail 'computed-pkgver: the moved source was not anchored to the AUR checksum'
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
# inside pkgver is not its business — and a literal rewrite would CLOBBER the
# expression, silently pinning the version. The refusal must leave the recipe
# byte-identical and fail the package loudly.
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
    run_case "$dir" 'computed-pkgver-unsupported' 3

cmp -s "$dir/fake/PKGBUILD.original" "$dir/packages/core/s1/PKGBUILD" \
    || fail 'computed-pkgver-unsupported: the recipe changed despite the refusal'
[[ ! -s $dir/fake/updpkgsums_calls && ! -s $dir/fake/makepkg_argv ]] \
    || fail 'computed-pkgver-unsupported: sums or build ran after the refusal'
grep -q 'expression this version sync cannot rewrite' "$dir/out.txt" \
    || fail 'computed-pkgver-unsupported: the refusal does not name the unsupported expression'
expect_row 'computed-pkgver-unsupported' s1 failed 1 sync-refused

# ─── Case 36: a tracker section named for the recipe id resolves ────────────
# pkgbase is flavor-derived for some recipes while its tracker file follows
# the stable recipe identity. The section is looked up by pkgbase first, then
# by the recipe id, so a flavored pkgbase never makes its own tracker
# unreachable.
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
GSA_FAKE_NVCHECK_VERSION="$repo_version" run_case "$dir" 'section-by-id' 0

grep -q "^pkgver=$repo_version$" "$(pkgfile "$dir")" \
    || fail 'section-by-id: the id-named tracker section was not resolved for a flavored pkgbase'

# ─── Case 37: a --skip run must see upstream movement (R-F10) ───────────────
# The skip claim used to run BEFORE the version query, so a resumed run
# claimed "already built" forever at a stale version. The version sync runs
# first now: upstream moved → the recipe is rewritten and rebuilt, never
# skipped. The source URL is static so this case exercises the claim alone,
# not the checksum anchor.
(
    dir="$fixture/s-resume"
    make_case_workspace "$dir" "$staged_version-1" \
        "https://example.invalid/s1-$staged_version.tar.gz"
    run_case "$dir" 's-resume seed' 0

    # The seed run's output: the current version, newer than the recipe.
    printf 'built payload\n' >"$dir/packages/stable/s1/s1-$staged_version-1-any.pkg.tar.zst"
    : >"$dir/fake/makepkg_argv"
    run_case "$dir" 's-resume still-current' 0 --skip
    if [[ -s $dir/fake/makepkg_argv ]]; then
        fail 's-resume: --skip rebuilt a recipe whose version is current and whose archive is fresh'
    fi
    expect_plan 's-resume still-current' s1 skip ok

    printf '%s\n' "$repo_version-1" >"$dir/fake/repo_version"
    : >"$dir/fake/makepkg_argv"
    run_case "$dir" 's-resume upstream moved' 0 --skip
    grep -q "^pkgver=$repo_version$" "$(pkgfile "$dir")" \
        || fail 's-resume: a resumed --skip run did not sync the moved upstream version'
    [[ -s $dir/fake/makepkg_argv ]] \
        || fail 's-resume: a resumed --skip run SKIPPED a recipe whose upstream version moved'
    if [[ -s $dir/fake/curl_calls || -s $dir/fake/updpkgsums_calls ]]; then
        fail 's-resume: the static source did not move; anchoring ran anyway'
    fi
)

# ─── Case 38: a failed repo query is not "the name is unknown" (R-F20) ─────
# pacman -Si used to fail (unsynced db, mirror error) exactly like "not in
# the repos" — both silently returned 0 — so a stale committed version built
# with no log and no note. The query failure now names itself and defers; the
# name-unknown answer syncs nothing and builds as-is.
for mode in db-error not-found; do
    (
        dir="$fixture/si-$mode"
        make_case_workspace "$dir" "$staged_version-1" \
            "https://example.invalid/s1-$staged_version.tar.gz"
        if [[ $mode == db-error ]]; then
            GSA_FAKE_SI_MODE=db-error run_case "$dir" "si-$mode" 5
            grep -q 'cannot query the Arch repository version' "$dir/out.txt" \
                || fail "si-$mode: the failed query is not named"
            grep -q 'waits-on-deferred' "$dir/out.txt" \
                || fail "si-$mode: the deferral does not name the parked-cone reason key"
            [[ ! -s $dir/fake/makepkg_argv ]] \
                || fail "si-$mode: a build ran over an unverified version"
            expect_row "si-$mode" s1 deferred 99 upstream-unverified
        else
            GSA_FAKE_SI_MODE=not-found run_case "$dir" "si-$mode" 0
            [[ -s $dir/fake/makepkg_argv ]] \
                || fail "si-$mode: the name-unknown answer refused the ordinary build path"
        fi
        grep -q "^pkgver=$staged_version$" "$(pkgfile "$dir")" \
            || fail "si-$mode: the recipe was rewritten although the query never succeeded"
    )
done

# ─── Case 39: repository version text that cannot be written safely is
# refused before the first write (R-F11) ─────────────────────────────────────
# `&`, `\` and `/` corrupt a rewrite replacement rather than fail it. The
# rewrite refuses such a version outright — nothing is written, nothing built.
i=0
for bad_ver in '2.0&0-1' '2.0\0-1' '2.0/0-1'; do
    i=$((i + 1))
    (
        dir="$fixture/badver-$i"
        make_case_workspace "$dir" "$bad_ver" \
            "https://example.invalid/s1-$staged_version.tar.gz"
        cp -- "$(pkgfile "$dir")" "$dir/pre-PKGBUILD"
        run_case "$dir" "badver-$i" 3
        grep -q 'refusing to sync from a repository version' "$dir/out.txt" \
            || fail "badver-$i: the unwritable repository version is not named"
        cmp -s "$dir/pre-PKGBUILD" "$(pkgfile "$dir")" \
            || fail "badver-$i: the recipe was written although the repository version cannot be written safely"
        [[ ! -s $dir/fake/makepkg_argv ]] \
            || fail "badver-$i: makepkg ran over a refused version"
        expect_row "badver-$i" s1 failed 1 sync-refused
    )
done

# ─── Case 40: a failure after the publish rolls the whole rewrite back ──────
# The snapshot/rollback boundary wraps both sync paths: a failure AFTER the
# publish (here an artifact directory rm cannot clear) leaves the recipe
# byte-for-byte at its committed state, not half-rewritten for the owner to
# commit.
dir="$fixture/rollback"
make_case_workspace "$dir" "$staged_version-1" \
    "https://example.invalid/s1-$staged_version.tar.gz"
# An artifact directory rm -rf cannot clear (no write bit, one file inside).
# Since W1 the engine's clear step runs as ROOT (it is in-process, not a
# build-side command), so the 555 mode alone no longer stops it
# (CAP_DAC_OVERRIDE writes through): the directory is also staged IMMUTABLE,
# root cannot unlink inside it either, and the post-publish failure the
# rollback wraps still fires.
mkdir -p "$dir/packages/stable/s1/src"
printf 'cached object\n' >"$dir/packages/stable/s1/src/keep"
chmod 555 "$dir/packages/stable/s1/src"
/usr/bin/sudo -n chattr +i "$dir/packages/stable/s1/src" ||
    fail 'rollback: chattr +i failed — the root-unclearable artifact dir cannot be staged'
printf '%s\n' "$repo_version-1" >"$dir/fake/repo_version"
cp -- "$(pkgfile "$dir")" "$dir/pre-PKGBUILD"
run_case "$dir" 'rollback' 3
/usr/bin/sudo -n chattr -i "$dir/packages/stable/s1/src" 2>/dev/null || true
chmod -R u+w "$dir/packages/stable/s1"     # asserts below must not need the mode
grep -q 'could not clear stale build artifacts' "$dir/out.txt" \
    || fail 'rollback: the failing step is not named'
cmp -s "$dir/pre-PKGBUILD" "$(pkgfile "$dir")" \
    || fail 'rollback: the recipe is not back at its committed state after the failed step'
[[ ! -s $dir/fake/makepkg_argv ]] \
    || fail 'rollback: makepkg ran after the rollback'
expect_row 'rollback' s1 failed 1 sync-refused

# ─── Case 43: an unevaluable recipe is named, never synced blind (R-F32) ────
# The pkgname candidates come from sourcing the PKGBUILD; a recipe that does
# not source must be NAMED here instead of looking like one whose pkgname is
# its pkgbase (the failure once went out as a blind query).
dir="$fixture/eval-broken"
make_case_workspace "$dir" "$repo_version-1" \
    "https://example.invalid/s1-$staged_version.tar.gz"
printf 'return 1\n' >>"$(pkgfile "$dir")"
cp -- "$(pkgfile "$dir")" "$dir/pre-PKGBUILD"
run_case "$dir" 'eval-broken' 3
grep -q 'cannot evaluate the pkgname array' "$dir/out.txt" \
    || fail 'eval-broken: the unevaluable recipe is not named'
cmp -s "$dir/pre-PKGBUILD" "$(pkgfile "$dir")" \
    || fail 'eval-broken: the recipe was rewritten although it never evaluated'
[[ ! -s $dir/fake/makepkg_argv ]] \
    || fail 'eval-broken: makepkg ran'
expect_row 'eval-broken' s1 failed 1 sync-refused

# ─── Case 46: a published SUPERSET still anchors (provider-only extras) ─────
# run #56 gcc-snapshot: AUR carries `gcc-ada-repro.patch` for the ada
# frontend this recipe trims, and the old byte-equality guard refused a
# checksum anchor that was correct for every source the recipe DOES build.
# Coverage semantics: every recipe source must appear verbatim in the
# provider list; provider-only extras never anchor. (The extras NOTE the
# module produces is dropped by the CLI seam — recorded as an engine bug in
# the flip report; the anchoring half is what this case pins.) Case 22 keeps
# pinning the real mismatch class.
dir="$fixture/aur-superset"
make_aur_version_workspace "$dir"
{
    printf 'pkgbase = s1\n'
    printf '\tpkgver = %s\n' "$repo_version"
    printf '\tpkgrel = 3\n'
    printf '\tarch = any\n'
    printf '\tsource = https://example.invalid/s1-%s.tar.gz\n' "$repo_version"
    printf '\tsource = only-in-aur.patch\n'
    printf '\tsha256sums = %s\n' "$published_sha"
    printf '\tsha256sums = %s\n' "$staged_sum"
    printf '\n\tpkgname = s1\n'
} >"$dir/fake/aur_srcinfo"
set_delivery "$dir" "$published_payload"
GSA_FAKE_NVCHECK_VERSION="$repo_version" run_case "$dir" 'aur-superset' 0

grep -q "^pkgver=$repo_version$" "$dir/packages/core/s1/PKGBUILD" \
    || fail 'aur-superset: the AUR pkgver was not applied to the recipe'
grep -q "^sha256sums=('$published_sha')$" "$dir/packages/core/s1/PKGBUILD" \
    || fail 'aur-superset: the recipe source was not anchored to the AUR checksum'
[[ -s $dir/fake/makepkg_argv ]] \
    || fail 'aur-superset: the build did not run although every recipe source was published'
expect_row 'aur-superset' s1 succeeded 0 ok

printf 'stable-sync fixture: PASS\n'
