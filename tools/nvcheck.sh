#!/usr/bin/env bash
# Aggregate the per-recipe .nvchecker.toml files and report outdated packages.
#
# Usage:
#   tools/nvcheck.sh                 check every recipe, write the report
#   tools/nvcheck.sh --list          list the configs that would be checked
#   tools/nvcheck.sh --only PATTERN  check only configs whose path matches
#   tools/nvcheck.sh --print-config CONFIG
#                                    print the generated config for one file
#   tools/nvcheck.sh --provider CONFIG SECTION
#                                    print the upstream provider and identity
#   tools/nvcheck.sh --release-digests JSON TAG
#                                    print a GitHub release checksum map
#   tools/nvcheck.sh --resolve CONFIG KEY
#                                    resolve one config key as a version string
#   tools/nvcheck.sh --take NAME...  accept the current upstream versions as
#                                    known, so they stop being reported
#
# Why this exists at all: nvchecker has no multi-file mode. It reads one config
# with -c, so 51 scattered recipe configs need 51 invocations. And it persists
# nothing unless the config names an oldver AND a newver file - with both absent
# its state is silently discarded, `nvcmp` has nothing to compare, and every
# entry reads as never-seen. See nvchecker's core.py:
#
#     if 'oldver' in c and 'newver' in c:
#
# The recipe configs are shared with the rest of the repository and must not
# grow build-host paths, so the oldver/newver pair is injected here instead. The
# generated config is the original file with a [__config__] table prepended,
# byte for byte, which keeps multi-section configs (bash has three, with a
# combiner) working without any TOML re-serialisation.
#
# State lives outside the repository: it is machine state, not recipe content.

set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
state_dir=${NVCHECK_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/gsa-nvcheck}
report=$state_dir/outdated.txt

die() { printf 'nvcheck: %s\n' "$*" >&2; exit 2; }

# Every config, sorted, so the report is stable between runs.
mapfile -t configs < <(
    find "$root/packages" -mindepth 3 -maxdepth 3 -name .nvchecker.toml -print | sort
)
((${#configs[@]})) || die "no .nvchecker.toml files found under $root/packages"

# The id is the recipe path with the filename dropped: packages/<group>/<id>.
config_id() {
    local cfg=$1
    cfg=${cfg#"$root"/packages/}
    printf '%s' "${cfg%/.nvchecker.toml}"
}

merged_config() { printf '%s/configs/%s.toml' "$state_dir" "$(config_id "$1")"; }
state_subdir() { printf '%s/state/%s' "$state_dir" "$(config_id "$1")"; }

# The original file must not already carry the table we inject: prepending a
# second [__config__] would be a duplicate key and nvchecker would refuse it.
write_merged() {
    local cfg=$1 out
    out=$(merged_config "$cfg")
    grep -q '^\[__config__\]' "$cfg" &&
        die "$(config_id "$cfg") already defines [__config__]; the injector would clash"

    local sub
    sub=$(state_subdir "$cfg")
    mkdir -p "$sub" "$(dirname "$out")"
    {
        printf '[__config__]\n'
        printf 'oldver = "%s/old_ver.json"\n' "$sub"
        printf 'newver = "%s/new_ver.json"\n' "$sub"
        printf '\n'
        cat "$cfg"
    } >"$out"
    printf '%s' "$out"
}

case ${1:-} in
    -h | --help)
        sed -n '2,25p' "${BASH_SOURCE[0]}"
        exit 0
        ;;
    --list)
        for cfg in "${configs[@]}"; do
            printf '%s\t%s\n' "$(config_id "$cfg")" "${cfg#"$root"/}"
        done
        exit 0
        ;;
    --print-config)
        [[ -n ${2:-} ]] || die '--print-config needs a config path'
        cfg=$2
        [[ $cfg == /* ]] || cfg="$root/$cfg"
        [[ -f $cfg ]] || die "no such config: $cfg"
        # Printed to stdout so a fixture can assert on it without touching the
        # state directory.
        grep -q '^\[__config__\]' "$cfg" &&
            die "$(config_id "$cfg") already defines [__config__]"
        sub=$(state_subdir "$cfg")
        printf '[__config__]\n'
        printf 'oldver = "%s/old_ver.json"\n' "$sub"
        printf 'newver = "%s/new_ver.json"\n' "$sub"
        printf '\n'
        cat "$cfg"
        exit 0
        ;;
    --release-digests)
        (($# == 3)) || die '--release-digests needs a JSON path and tag'
        release_json=$2
        release_tag=$3
        [[ -n $release_tag ]] || die '--release-digests needs a non-empty tag'
        [[ -f $release_json ]] || die "no such release JSON: $release_json"
        command -v python3 >/dev/null 2>&1 ||
            die 'python3 is required to read GitHub release metadata'

        if ! python3 - "$release_json" "$release_tag" <<'PY'
import json
import re
import sys

path, expected_tag = sys.argv[1:3]
try:
    with open(path, encoding="utf-8") as response_file:
        release = json.load(response_file)
except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
    print(f"nvcheck: cannot read GitHub release JSON: {exc}", file=sys.stderr)
    raise SystemExit(2)

if not isinstance(release, dict) or release.get("tag_name") != expected_tag:
    print("nvcheck: GitHub release metadata does not match the requested tag", file=sys.stderr)
    raise SystemExit(2)
assets = release.get("assets")
if not isinstance(assets, list):
    print("nvcheck: GitHub release metadata has no valid assets list", file=sys.stderr)
    raise SystemExit(2)

lengths = {"sha256": 64, "sha512": 128, "md5": 32, "b2": 128}
seen = set()
for asset in assets:
    if not isinstance(asset, dict):
        print("nvcheck: GitHub release metadata contains an invalid asset", file=sys.stderr)
        raise SystemExit(2)
    name = asset.get("name")
    if not isinstance(name, str) or not name or any(char in name for char in "\t\r\n"):
        print("nvcheck: GitHub release metadata contains an invalid asset name", file=sys.stderr)
        raise SystemExit(2)
    if name in seen:
        print(f"nvcheck: GitHub release has duplicate asset name {name!r}", file=sys.stderr)
        raise SystemExit(2)
    seen.add(name)
    digest = asset.get("digest")
    if digest is None:
        continue
    if not isinstance(digest, str):
        print(f"nvcheck: GitHub asset {name!r} has an invalid digest", file=sys.stderr)
        raise SystemExit(2)
    match = re.fullmatch(r"(sha256|sha512|md5|b2):([0-9a-fA-F]+)", digest)
    if match is None or len(match.group(2)) != lengths[match.group(1)]:
        print(f"nvcheck: GitHub asset {name!r} has an unsupported digest", file=sys.stderr)
        raise SystemExit(2)
    print(f"{name}\t{match.group(1)}\t{match.group(2).lower()}")
PY
        then
            exit 2
        fi
        exit 0
        ;;
    --provider)
        (($# == 3)) || die '--provider needs a config path and section'
        cfg=$2
        provider_section=$3
        [[ -n $provider_section ]] || die '--provider needs a non-empty section'
        [[ $cfg == /* ]] || cfg="$root/$cfg"
        [[ -f $cfg ]] || die "no such config: $cfg"
        [[ ${cfg##*/} == .nvchecker.toml ]] ||
            die '--provider expects a .nvchecker.toml file'
        grep -q '^\[__config__\]' "$cfg" &&
            die "$cfg already defines [__config__]; cannot inspect provider"
        command -v python3 >/dev/null 2>&1 ||
            die 'python3 is required to inspect nvchecker config'

        if ! python3 - "$cfg" "$provider_section" <<'PY'
import re
import sys
from urllib.parse import urlsplit

try:
    import tomllib
except ImportError:
    print("nvcheck: Python 3.11+ is required to inspect nvchecker config", file=sys.stderr)
    raise SystemExit(2)

path, key = sys.argv[1:3]
try:
    with open(path, "rb") as config_file:
        config = tomllib.load(config_file)
except (OSError, tomllib.TOMLDecodeError) as exc:
    print(f"nvcheck: cannot read nvchecker config: {exc}", file=sys.stderr)
    raise SystemExit(2)

section = config.get(key)
if not isinstance(section, dict):
    print(f"nvcheck: no such section {key!r} in {path}", file=sys.stderr)
    raise SystemExit(2)

source = section.get("source")
if source == "aur":
    identity = section.get("aur")
    if (
        not isinstance(identity, str)
        or re.fullmatch(r"[A-Za-z0-9@._+-]+", identity) is None
        or identity in {".", ".."}
    ):
        print(f"nvcheck: section {key!r} has an invalid AUR identity", file=sys.stderr)
        raise SystemExit(2)
    provider = "aur"
elif source == "github":
    identity = section.get("github")
    provider = "github"
elif source == "git":
    remote = section.get("git")
    if not isinstance(remote, str):
        print(f"nvcheck: section {key!r} has an invalid Git remote", file=sys.stderr)
        raise SystemExit(2)
    parsed = urlsplit(remote)
    if (
        parsed.scheme != "https"
        or parsed.netloc.lower() != "github.com"
        or parsed.query
        or parsed.fragment
    ):
        print("nvcheck: only GitHub Git sources are supported", file=sys.stderr)
        raise SystemExit(2)
    identity = parsed.path.strip("/")
    if identity.endswith(".git"):
        identity = identity[:-4]
    provider = "github"
else:
    print(f"nvcheck: unsupported version provider source {source!r}", file=sys.stderr)
    raise SystemExit(2)

if provider == "github":
    if (
        not isinstance(identity, str)
        or re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", identity) is None
        or any(part in {".", ".."} for part in identity.split("/"))
    ):
        print(f"nvcheck: section {key!r} has an invalid GitHub identity", file=sys.stderr)
        raise SystemExit(2)

sys.stdout.write(f"{provider}\n{identity}\n")
PY
        then
            exit 2
        fi
        exit 0
        ;;
    --resolve)
        (($# == 3)) || die '--resolve needs a config path and section/key'
        cfg=$2
        query_key=$3
        [[ -n $query_key ]] || die '--resolve needs a non-empty section/key'
        [[ $cfg == /* ]] || cfg="$root/$cfg"
        [[ -f $cfg ]] || die "no such config: $cfg"
        [[ ${cfg##*/} == .nvchecker.toml ]] ||
            die '--resolve expects a .nvchecker.toml file'
        grep -q '^\[__config__\]' "$cfg" &&
            die "$cfg already defines [__config__]; cannot inject resolver state"
        command -v nvchecker >/dev/null 2>&1 || die 'nvchecker not found in PATH'
        command -v python3 >/dev/null 2>&1 ||
            die 'python3 is required to read nvchecker output'

        resolver_root=$(cd "$root" && pwd -P) || die 'could not resolve repository path'
        resolver_tmp_base=${TMPDIR:-/tmp}
        resolver_tmp_base=$(cd -- "$resolver_tmp_base" 2>/dev/null && pwd -P) ||
            die "TMPDIR is not an accessible directory: ${TMPDIR:-/tmp}"
        if [[ $resolver_tmp_base == "$resolver_root" ||
            $resolver_tmp_base == "$resolver_root/"* ]]; then
            die 'TMPDIR must be outside the repository'
        fi
        resolver_tmp=$(mktemp -d "$resolver_tmp_base/gsa-nvcheck.XXXXXXXX") ||
            die 'could not create resolver temp state'
        resolver_tmp_original=$resolver_tmp
        trap 'rm -rf -- "$resolver_tmp_original"' EXIT
        resolver_tmp=$(cd "$resolver_tmp_original" && pwd -P) ||
            die 'could not resolve resolver temp state path'
        resolver_state="$resolver_tmp/state"
        mkdir -p "$resolver_state" || die 'could not create resolver state directory'
        merged="$resolver_tmp/config.toml"
        oldver="$resolver_state/old_ver.json"
        newver="$resolver_state/new_ver.json"
        {
            printf '[__config__]\n'
            printf 'oldver = "%s"\n' "$oldver"
            printf 'newver = "%s"\n' "$newver"
            printf '\n'
            cat "$cfg"
        } >"$merged"

        if nvchecker -c "$merged" >/dev/null 2>"$resolver_tmp/nvchecker.stderr"; then
            :
        else
            nvchecker_status=$?
            printf 'nvcheck: nvchecker failed for %s key %s (exit %d)\n' \
                "$cfg" "$query_key" "$nvchecker_status" >&2
            [[ ! -s $resolver_tmp/nvchecker.stderr ]] ||
                cat "$resolver_tmp/nvchecker.stderr" >&2
            exit 3
        fi

        if ! python3 - "$newver" "$query_key" <<'PY'
import json
import sys

path, key = sys.argv[1:3]
try:
    with open(path, encoding="utf-8") as state:
        versions = json.load(state)
except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
    print(f"nvcheck: cannot read new_ver.json: {exc}", file=sys.stderr)
    raise SystemExit(2)

if not isinstance(versions, dict) or key not in versions:
    print(f"nvcheck: new_ver.json has no version for key {key!r}", file=sys.stderr)
    raise SystemExit(2)

version = versions[key]
if not isinstance(version, str) or not version or any(char.isspace() for char in version):
    print(f"nvcheck: new_ver.json has an invalid version for key {key!r}", file=sys.stderr)
    raise SystemExit(2)

sys.stdout.write(version + "\n")
PY
        then
            exit 2
        fi
        exit 0
        ;;
    --take)
        shift
        (($#)) || die '--take needs at least one NAME, or --all'
        mkdir -p "$state_dir"
        for cfg in "${configs[@]}"; do
            merged=$(write_merged "$cfg")
            # A name that this config does not define is expected: --take is
            # normally called with one name across every config.
            nvtake -c "$merged" --ignore-nonexistent "$@" >/dev/null 2>&1 || true
        done
        printf 'nvcheck: accepted upstream versions as known\n'
        exit 0
        ;;
    --only)
        [[ -n ${2:-} ]] || die '--only needs a pattern'
        pattern=$2
        mapfile -t configs < <(printf '%s\n' "${configs[@]}" | grep -F "$pattern" || true)
        ((${#configs[@]})) || die "no config matches: $pattern"
        ;;
    '') ;;
    *) die "unknown argument: $1 (try --help)" ;;
esac

mkdir -p "$state_dir"
: >"$report"

failed=0
outdated=0
checked=0

for cfg in "${configs[@]}"; do
    id=$(config_id "$cfg")
    merged=$(write_merged "$cfg")
    checked=$((checked + 1))

    if ! nvchecker -c "$merged" >/dev/null 2>"$state_dir/last-error.log"; then
        printf 'ERROR  %s (see %s)\n' "$id" "$state_dir/last-error.log"
        failed=$((failed + 1))
        continue
    fi

    # nvcmp prints only genuine differences, so empty output means up to date.
    if out=$(nvcmp -c "$merged" 2>/dev/null) && [[ -n $out ]]; then
        printf '%s\n' "$out" >>"$report"
        outdated=$((outdated + 1))
        printf 'UPDATE %s\n' "$id"
    fi
done

printf '\nnvcheck: %d checked, %d outdated, %d failed\n' "$checked" "$outdated" "$failed"
if ((failed)); then
    printf 'report: %s\n' "$report"
    exit 3
fi
if ((outdated)); then
    printf 'outdated packages are listed in %s\n' "$report"
    exit 1
fi
printf 'all recipes are current\n'
