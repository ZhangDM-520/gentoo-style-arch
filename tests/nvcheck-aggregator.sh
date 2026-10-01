#!/usr/bin/env bash
# Reduced-scale contract for tools/nvcheck.sh.
#
# The aggregator itself needs the network and 51 nvchecker runs, so it is not in
# the battery. This pins the parts that decide whether it can work at all, using
# only its offline modes. The invariant worth protecting is the merge: the
# generated config must be the recipe's file with a [__config__] table prepended
# and nothing else touched, because a re-serialised TOML would quietly drop or
# reorder what a recipe author wrote.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tool="$root/tools/nvcheck.sh"

fail() {
    printf 'nvcheck aggregator: %s\n' "$1" >&2
    exit 1
}

test -x "$tool" || fail "tools/nvcheck.sh is not present and executable"
bash -n "$tool" || fail "tools/nvcheck.sh does not parse"

# --list must see every config the repository has, not a remembered inventory.
listed=$("$tool" --list)
configured=$(find "$root/packages" -mindepth 3 -maxdepth 3 -name .nvchecker.toml | wc -l)
((configured > 0)) || fail "no .nvchecker.toml files found at all"
[[ $(wc -l <<<"$listed") -eq $configured ]] ||
    fail "--list reported $(wc -l <<<"$listed") configs but $configured exist"
grep -Fq 'packages/git/onlyoffice-git/.nvchecker.toml' <<<"$listed" ||
    fail "--list does not include the onlyoffice-git config"

# The merge must preserve the original bytes exactly. bash is the hard case: it
# has three sections, one of them quoted, and a combiner referencing the others.
multi="$root/packages/stable/bash/.nvchecker.toml"
if [[ -f $multi ]]; then
    merged=$("$tool" --print-config "$multi")
    head -n1 <<<"$merged" | grep -Fxq '[__config__]' ||
        fail "--print-config does not start with a [__config__] table"
    grep -Fq 'oldver = "' <<<"$merged" || fail "the merged config has no oldver"
    grep -Fq 'newver = "' <<<"$merged" || fail "the merged config has no newver"
    if ! diff -q <(tail -n +5 <<<"$merged") "$multi" >/dev/null; then
        fail "--print-config altered the recipe's config instead of copying it verbatim"
    fi
fi

# nvchecker persists nothing unless both files are named, and the paths must be
# absolute: a relative oldver/newver is resolved against the *config file's*
# directory, which for these recipes is inside the repository.
oldver=$("$tool" --print-config "$multi" | sed -n 's/^oldver = "\(.*\)"$/\1/p')
newver=$("$tool" --print-config "$multi" | sed -n 's/^newver = "\(.*\)"$/\1/p')
[[ $oldver == /* ]] || fail "oldver is not absolute: $oldver"
[[ $newver == /* ]] || fail "newver is not absolute: $newver"
[[ $oldver != "$root"/* ]] || fail "state would be written inside the repository: $oldver"
[[ $oldver == */old_ver.json && $newver == */new_ver.json ]] ||
    fail "the state files are not named old_ver.json/new_ver.json"

# Printing a config must not create state, here or anywhere. Asserted against a
# redirected state directory rather than by mtime, so a concurrent build writing
# into packages/ cannot make this flaky.
tmpstate=$(mktemp -d)
NVCHECK_STATE_DIR=$tmpstate "$tool" --print-config "$multi" >/dev/null
[[ -z $(ls -A "$tmpstate") ]] || fail "--print-config created state in its state dir"
rm -rf "$tmpstate"
strays=$(find "$root/packages" \( -name old_ver.json -o -name new_ver.json \) | wc -l)
[[ $strays -eq 0 ]] || fail "version state leaked into the repository"

# A config that already defines the table must be refused rather than silently
# producing a duplicate [__config__] that nvchecker would reject.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --resolve runs one config with disposable old/new state and prints only the
# requested version. nvchecker reads and writes the paths in the merged config;
# nvcmp is present as a tripwire because its human output is not an API.
query_config="$root/packages/stable/bettbox/.nvchecker.toml"
query_bin="$tmp/query-bin"
normal_state="$tmp/normal-state"
mkdir -p "$query_bin" "$normal_state"
printf 'preserve this report state\n' >"$normal_state/outdated.txt"
cat >"$query_bin/nvchecker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ ${1:-} == -c && $# -eq 2 ]] || exit 91
merged=$2
newver=$(sed -n 's/^newver = "\(.*\)"$/\1/p' "$merged")
[[ -n $newver ]] || exit 92
printf '%s\t%s\n' "$merged" "$newver" >>"$FAKE_NVCHECKER_LOG"
if grep -Fq '[bettbox' "$merged" && ! grep -Fxq '[bettbox]' "$merged"; then
    printf 'fake nvchecker: malformed TOML table header\n' >&2
    exit 16
fi
case ${FAKE_NVCHECKER_MODE:-success} in
    provider-failure)
        printf 'fake nvchecker: provider request failed\n' >&2
        exit 17
        ;;
    missing-key)
        printf '{"another-package": "9.8.7"}\n' >"$newver"
        ;;
    success)
        printf '{"another-package": "9.8.7", "bettbox": "1.2.3-pre4"}\n' >"$newver"
        ;;
    *) exit 94 ;;
esac
EOF
cat >"$query_bin/nvcmp" <<'EOF'
#!/usr/bin/env bash
if [[ ${FAKE_NVCMP_MODE:-tripwire} == outdated ]]; then
    printf 'fake outdated: 1.2.3-pre4\n'
    exit 0
fi
printf 'called\n' >"$FAKE_NVCMP_MARKER"
exit 99
EOF
cat >"$query_bin/nvtake" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ ${1:-} == -c ]] || exit 93
printf '%s\n' "$*" >>"$FAKE_NVTAKE_LOG"
EOF
chmod +x "$query_bin/nvchecker" "$query_bin/nvcmp" "$query_bin/nvtake"
repo_state_before=$(find "$root/packages" -type f \( -name old_ver.json -o -name new_ver.json \) -print | sort)
report_state_before=$(find "$normal_state" -mindepth 1 -printf '%P %s %T@\n' | sort)
if ! PATH="$query_bin:$PATH" TMPDIR="$tmp" \
    NVCHECK_STATE_DIR="$normal_state" \
    FAKE_NVCHECKER_LOG="$tmp/nvchecker.log" \
    FAKE_NVCMP_MARKER="$tmp/nvcmp-called" \
    "$tool" --resolve "$query_config" bettbox >"$tmp/resolved-version"; then
    fail "--resolve did not resolve the Bettbox version"
fi
[[ $(cat "$tmp/resolved-version") == '1.2.3-pre4' ]] ||
    fail "--resolve did not print the exact version by itself"
[[ $(wc -l <"$tmp/resolved-version") -eq 1 ]] ||
    fail "--resolve printed more than one line"
[[ $(wc -l <"$tmp/nvchecker.log") -eq 1 ]] ||
    fail "--resolve did not invoke nvchecker exactly once"
IFS=$'\t' read -r merged_config resolver_newver <"$tmp/nvchecker.log"
[[ $merged_config == "$tmp"/* && $resolver_newver == "$tmp"/* ]] ||
    fail "--resolve did not keep its merged config and version state in TMPDIR"
[[ $merged_config != "$root"/* && $resolver_newver != "$root"/* ]] ||
    fail "--resolve created merged config or version state in the repository"
[[ ! -e $tmp/nvcmp-called ]] || fail "--resolve used nvcmp human-readable output"
[[ $(find "$normal_state" -mindepth 1 -printf '%P %s %T@\n' | sort) == "$report_state_before" ]] ||
    fail "--resolve changed the normal report-state directory"
[[ $(cat "$normal_state/outdated.txt") == 'preserve this report state' ]] ||
    fail "--resolve changed the existing normal report"
repo_state_after=$(find "$root/packages" -type f \( -name old_ver.json -o -name new_ver.json \) -print | sort)
[[ $repo_state_after == "$repo_state_before" ]] ||
    fail "--resolve wrote version state into the repository"

# Provider errors, malformed TOML, and missing output keys must fail without
# emitting a version string or changing the report state.
if PATH="$query_bin:$PATH" TMPDIR="$tmp" NVCHECK_STATE_DIR="$normal_state" \
    FAKE_NVCHECKER_LOG="$tmp/nvchecker.log" FAKE_NVCHECKER_MODE=provider-failure \
    "$tool" --resolve "$query_config" bettbox >"$tmp/provider-failure.out" 2>"$tmp/provider-failure.err"; then
    fail "--resolve accepted a provider failure"
fi
grep -Fq 'nvchecker failed' "$tmp/provider-failure.err" ||
    fail "--resolve did not explain the nvchecker failure"
grep -Fq 'fake nvchecker: provider request failed' "$tmp/provider-failure.err" ||
    fail "--resolve dropped the provider diagnostic"
[[ ! -s $tmp/provider-failure.out ]] || fail "--resolve emitted a version after provider failure"

if PATH="$query_bin:$PATH" TMPDIR="$tmp" NVCHECK_STATE_DIR="$normal_state" \
    FAKE_NVCHECKER_LOG="$tmp/nvchecker.log" FAKE_NVCHECKER_MODE=missing-key \
    "$tool" --resolve "$query_config" missing-section >"$tmp/missing-key.out" 2>"$tmp/missing-key.err"; then
    fail "--resolve accepted a key missing from new_ver.json"
fi
grep -Fq "no version for key 'missing-section'" "$tmp/missing-key.err" ||
    fail "--resolve did not explain the missing output key"
[[ ! -s $tmp/missing-key.out ]] || fail "--resolve emitted a version for a missing key"

malformed_config="$tmp/malformed/.nvchecker.toml"
mkdir -p "$(dirname "$malformed_config")"
printf '[bettbox\nsource = "git"\n' >"$malformed_config"
if PATH="$query_bin:$PATH" TMPDIR="$tmp" NVCHECK_STATE_DIR="$normal_state" \
    FAKE_NVCHECKER_LOG="$tmp/nvchecker.log" \
    "$tool" --resolve "$malformed_config" bettbox >"$tmp/malformed-config.out" 2>"$tmp/malformed-config.err"; then
    fail "--resolve accepted malformed TOML"
fi
grep -Fq 'nvchecker failed' "$tmp/malformed-config.err" ||
    fail "--resolve did not explain the malformed config failure"
grep -Fq 'fake nvchecker: malformed TOML table header' "$tmp/malformed-config.err" ||
    fail "--resolve dropped the malformed-config diagnostic"
[[ ! -s $tmp/malformed-config.out ]] || fail "--resolve emitted a version for malformed TOML"

# The missing-tool check must work even when a host nvchecker happens to be
# installed, so give the script only the commands needed to reach that check.
missing_nvchecker_path="$tmp/no-nvchecker-path"
mkdir -p "$missing_nvchecker_path"
for command_name in bash dirname find sort grep; do
    ln -s "$(command -v "$command_name")" "$missing_nvchecker_path/$command_name"
done
if PATH="$missing_nvchecker_path" TMPDIR="$tmp" NVCHECK_STATE_DIR="$normal_state" \
    "$tool" --resolve "$query_config" bettbox >"$tmp/missing-nvchecker.out" 2>"$tmp/missing-nvchecker.err"; then
    fail "--resolve succeeded without nvchecker"
fi
grep -Fq 'nvchecker not found in PATH' "$tmp/missing-nvchecker.err" ||
    fail "--resolve did not clearly report missing nvchecker"
[[ ! -s $tmp/missing-nvchecker.out ]] || fail "--resolve emitted a version without nvchecker"

if PATH="$query_bin:$PATH" TMPDIR="$tmp" NVCHECK_STATE_DIR="$normal_state" \
    FAKE_NVCHECKER_LOG="$tmp/nvchecker.log" \
    "$tool" --resolve "$query_config" '' >"$tmp/empty-key.out" 2>"$tmp/empty-key.err"; then
    fail "--resolve accepted an empty section/key"
fi
grep -Fq 'non-empty section/key' "$tmp/empty-key.err" ||
    fail "--resolve did not clearly report an empty section/key"
[[ ! -s $tmp/empty-key.out ]] || fail "--resolve emitted a version for an empty section/key"

# Even a misconfigured TMPDIR must not place transient resolver files in the
# checkout.
repo_tmp_before=$(find "$root" -maxdepth 1 -type d -name 'gsa-nvcheck.*' -print | sort)
if PATH="$query_bin:$PATH" TMPDIR="$root" NVCHECK_STATE_DIR="$normal_state" \
    FAKE_NVCHECKER_LOG="$tmp/nvchecker.log" \
    "$tool" --resolve "$query_config" bettbox >"$tmp/repo-tmpdir.out" 2>"$tmp/repo-tmpdir.err"; then
    fail "--resolve accepted a TMPDIR inside the repository"
fi
grep -Fq 'TMPDIR must be outside the repository' "$tmp/repo-tmpdir.err" ||
    fail "--resolve did not reject a repository-local TMPDIR"
[[ ! -s $tmp/repo-tmpdir.out ]] || fail "--resolve emitted a version for a repository-local TMPDIR"
repo_tmp_after=$(find "$root" -maxdepth 1 -type d -name 'gsa-nvcheck.*' -print | sort)
[[ $repo_tmp_after == "$repo_tmp_before" ]] ||
    fail "--resolve created temporary state in the repository"

[[ $(find "$normal_state" -mindepth 1 -printf '%P %s %T@\n' | sort) == "$report_state_before" ]] ||
    fail "resolver failures changed the normal report-state directory"
[[ $(cat "$normal_state/outdated.txt") == 'preserve this report state' ]] ||
    fail "resolver failures changed the existing normal report"
repo_state_after=$(find "$root/packages" -type f \( -name old_ver.json -o -name new_ver.json \) -print | sort)
[[ $repo_state_after == "$repo_state_before" ]] ||
    fail "resolver failures wrote version state into the repository"

# Build-time sync selects the upstream from the exact section already used by
# --resolve. The only supported providers are AUR and GitHub (including a Git
# tracker whose HTTPS remote is on github.com); this inspection is read-only.
provider_calls_before=$(wc -l <"$tmp/nvchecker.log")
github_provider=$(
    PATH="$query_bin:$PATH" TMPDIR="$tmp" NVCHECK_STATE_DIR="$normal_state" \
        FAKE_NVCHECKER_LOG="$tmp/nvchecker.log" \
        "$tool" --provider "$query_config" bettbox
)
[[ $github_provider == $'github\nappshubcc/Bettbox' ]] ||
    fail "--provider did not normalize Bettbox's GitHub Git remote"
zen_provider=$(
    PATH="$query_bin:$PATH" TMPDIR="$tmp" NVCHECK_STATE_DIR="$normal_state" \
        FAKE_NVCHECKER_LOG="$tmp/nvchecker.log" \
        "$tool" --provider "$root/packages/stable/zen-browser-pgo/.nvchecker.toml" zen-browser
)
[[ $zen_provider == $'github\nzen-browser/desktop' ]] ||
    fail "--provider did not read Zen's GitHub source"
aur_provider=$(
    PATH="$query_bin:$PATH" TMPDIR="$tmp" NVCHECK_STATE_DIR="$normal_state" \
        FAKE_NVCHECKER_LOG="$tmp/nvchecker.log" \
        "$tool" --provider "$root/packages/core/gcc-snapshot/.nvchecker.toml" gcc-snapshot
)
[[ $aur_provider == $'aur\ngcc-snapshot' ]] ||
    fail "--provider did not read gcc-snapshot's AUR source"
if PATH="$query_bin:$PATH" TMPDIR="$tmp" NVCHECK_STATE_DIR="$normal_state" \
    "$tool" --provider "$query_config" missing-section >"$tmp/provider-missing.out" \
    2>"$tmp/provider-missing.err"; then
    fail "--provider accepted a missing config section"
fi
grep -Fq 'no such section' "$tmp/provider-missing.err" ||
    fail "--provider did not explain the missing config section"
gitlab_config="$tmp/gitlab/.nvchecker.toml"
mkdir -p "$(dirname "$gitlab_config")"
cat >"$gitlab_config" <<'EOF'
[gitlab]
source = "git"
git = "https://gitlab.com/example/project.git"
EOF
if PATH="$query_bin:$PATH" TMPDIR="$tmp" NVCHECK_STATE_DIR="$normal_state" \
    "$tool" --provider "$gitlab_config" gitlab >"$tmp/provider-unsupported.out" \
    2>"$tmp/provider-unsupported.err"; then
    fail "--provider accepted an unsupported Git host"
fi
grep -Fq 'only GitHub Git sources are supported' "$tmp/provider-unsupported.err" ||
    fail "--provider did not explain the unsupported Git host"
[[ $(wc -l <"$tmp/nvchecker.log") -eq $provider_calls_before ]] ||
    fail "--provider ran nvchecker while only inspecting metadata"
[[ $(find "$normal_state" -mindepth 1 -printf '%P %s %T@\n' | sort) == "$report_state_before" ]] ||
    fail "--provider changed the normal report-state directory"

# GitHub release metadata is reduced to a strict filename/algorithm/digest map.
# Missing digests stay absent so the builder can apply its explicit fetch-only
# policy, while mismatched tags and unsupported digest formats fail closed.
release_digest=$(printf '%064d' 0)
release_json="$tmp/release.json"
cat >"$release_json" <<EOF
{
  "tag_name": "v2.0.0",
  "assets": [
    {"name": "asset.tar.gz", "digest": "sha256:$release_digest"},
    {"name": "unsigned.tar.gz", "digest": null}
  ]
}
EOF
release_map=$("$tool" --release-digests "$release_json" v2.0.0)
[[ $release_map == "$(printf 'asset.tar.gz\tsha256\t%s' "$release_digest")" ]] ||
    fail "--release-digests did not return the published asset digest map"
if "$tool" --release-digests "$release_json" v1.0.0 >"$tmp/release-tag.out" \
    2>"$tmp/release-tag.err"; then
    fail "--release-digests accepted metadata for a different tag"
fi
grep -Fq 'does not match the requested tag' "$tmp/release-tag.err" ||
    fail "--release-digests did not explain the tag mismatch"
printf '{"tag_name":"v2.0.0","assets":[{"name":"asset.tar.gz","digest":"sha1:abc"}]}\n' \
    >"$tmp/unsupported-digest.json"
if "$tool" --release-digests "$tmp/unsupported-digest.json" v2.0.0 \
    >"$tmp/unsupported-digest.out" 2>"$tmp/unsupported-digest.err"; then
    fail "--release-digests accepted an unsupported checksum algorithm"
fi
grep -Fq 'unsupported digest' "$tmp/unsupported-digest.err" ||
    fail "--release-digests did not explain the unsupported digest"
[[ $(find "$normal_state" -mindepth 1 -printf '%P %s %T@\n' | sort) == "$report_state_before" ]] ||
    fail "--release-digests changed the normal report-state directory"

# The established aggregate report path still uses persistent state, --only
# still filters to one recipe, and nvcmp output remains report-only here.
aggregate_state="$tmp/aggregate-state"
if PATH="$query_bin:$PATH" NVCHECK_STATE_DIR="$aggregate_state" \
    FAKE_NVCHECKER_LOG="$tmp/nvchecker.log" FAKE_NVCMP_MODE=outdated \
    "$tool" --only stable/bettbox >"$tmp/aggregate.out"; then
    fail "the aggregate mode did not return its existing outdated status"
else
    aggregate_status=$?
fi
[[ $aggregate_status -eq 1 ]] || fail "the aggregate mode returned $aggregate_status instead of 1"
grep -Fq 'UPDATE stable/bettbox' "$tmp/aggregate.out" ||
    fail "--only did not report the selected outdated recipe"
grep -Fq '1 checked, 1 outdated, 0 failed' "$tmp/aggregate.out" ||
    fail "--only did not preserve aggregate counts"
[[ $(cat "$aggregate_state/outdated.txt") == 'fake outdated: 1.2.3-pre4' ]] ||
    fail "the aggregate outdated report changed format"
aggregate_config="$aggregate_state/configs/stable/bettbox.toml"
[[ -f $aggregate_config ]] || fail "the aggregate config was not persisted in NVCHECK_STATE_DIR"
grep -Fq "$aggregate_state/state/stable/bettbox/new_ver.json" "$aggregate_config" ||
    fail "the aggregate config did not retain its persistent newver path"

# --take continues to visit every configured file and writes its merged
# configs under the normal state directory.
take_state="$tmp/take-state"
if ! PATH="$query_bin:$PATH" NVCHECK_STATE_DIR="$take_state" \
    FAKE_NVTAKE_LOG="$tmp/nvtake.log" "$tool" --take bettbox >"$tmp/take.out"; then
    fail "--take failed with the nvchecker stub"
fi
[[ $(cat "$tmp/take.out") == 'nvcheck: accepted upstream versions as known' ]] ||
    fail "--take output changed"
[[ $(wc -l <"$tmp/nvtake.log") -eq $configured ]] ||
    fail "--take did not visit every configured file"
[[ -f $take_state/configs/stable/bettbox.toml ]] ||
    fail "--take stopped persisting merged configs in NVCHECK_STATE_DIR"

printf '[__config__]\noldver = "x"\nnewver = "y"\n\n[foo]\nsource = "git"\n' >"$tmp/already.toml"
if "$tool" --print-config "$tmp/already.toml" >/dev/null 2>&1; then
    fail "a config that already defines [__config__] was accepted"
fi

# Unknown arguments must fail rather than fall through to a full network run.
if "$tool" --not-a-flag >/dev/null 2>&1; then
    fail "an unknown argument was accepted"
fi

# The tool is host-side and must stay out of the fixture battery's discovery,
# which scans tests/ only.
if grep -rqF 'tools/nvcheck.sh' "$root/tests/run-all.sh"; then
    fail "run-all.sh references the tool; it must stay undiscovered"
fi

printf 'nvcheck aggregator fixture: PASS\n'
