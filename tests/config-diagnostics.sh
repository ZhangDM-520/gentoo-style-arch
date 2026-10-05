#!/usr/bin/env bash
set -euo pipefail

# load_project_config returns 1 from about a dozen places. Before the
# 2026-09-20 audit most of them returned silently, and the only thing the user
# ever saw was the caller's generic "project configuration is invalid under
# <dir>" — which says nothing about *which* record is wrong. This fixture
# breaks one thing at a time in a sandbox and requires the builder to name the
# offender.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-config-diag.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

# A minimal but fully valid workspace: two packages, both grouped. The skeleton
# and the packages come from the fixture-lib helper; the per-case tweaks below
# stay inline because each breakage IS the case.
make_case_workspace() {
    local dir=$1
    make_workspace "$dir" 1 2 low
    add_package "$dir" p1 $'pkgver=1\npkgrel=1\narch=(any)'
    add_package "$dir" p2 $'pkgver=1\npkgrel=1\narch=(any)'
}

# Runs --list (which still loads the whole config) through the helper's capture;
# returns the builder's status, output in FIXTURE_OUTPUT.
run_list() {
    local dir=$1
    run_builder fish "$dir/build-all.fish" --list
    return "$FIXTURE_RC"
}

# assert_rejected <case> <dir> <expected substring>
assert_rejected() {
    local case_name=$1 dir=$2 expected=$3
    if run_list "$dir"; then
        printf '%s: invalid configuration was ACCEPTED:\n%s\n' "$case_name" "$FIXTURE_OUTPUT" >&2
        exit 1
    fi
    if ! grep -F "$expected" <<<"$FIXTURE_OUTPUT" >/dev/null; then
        printf '%s: error did not name the offender (wanted %q):\n%s\n' \
            "$case_name" "$expected" "$FIXTURE_OUTPUT" >&2
        exit 1
    fi
}

# Sanity: the baseline must be accepted, or every case below passes for the
# wrong reason.
baseline="$fixture/baseline"
make_case_workspace "$baseline"
if ! run_list "$baseline"; then
    printf 'baseline workspace is not valid — the fixture itself is broken:\n%s\n' \
        "$FIXTURE_OUTPUT" >&2
    exit 1
fi

# ─── A topology record naming no group ─────────────────────────────────────
dir="$fixture/ungrouped"
make_case_workspace "$dir"
set_topology_record "$dir" p2 '' # p2 names no group at all
assert_rejected 'ungrouped package' "$dir" 'topology record for p2 names no group'

# ─── An edge naming a package that does not exist ──────────────────────────
dir="$fixture/unknown-dep"
make_case_workspace "$dir"
set_topology_record "$dir" p1 git ghost
assert_rejected 'unknown dependency' "$dir" 'unknown dependency: ghost'

# ─── A record whose recipe does not exist ──────────────────────────────────
dir="$fixture/unknown-pkg"
make_case_workspace "$dir"
set_topology_record "$dir" ghost git # no packages/ghost/PKGBUILD ever written
assert_rejected 'unknown package' "$dir" 'invalid topology record path for ghost'

# ─── A record with the wrong field count ───────────────────────────────────
dir="$fixture/malformed-record"
make_case_workspace "$dir"
printf 'p1\n' >"$dir/config/topology.conf" # one bare field, not a record
assert_rejected 'malformed topology record' "$dir" "invalid topology record (expected"

# ─── Missing config files are named, not just "invalid" ─────────────────────
dir="$fixture/no-topology"
make_case_workspace "$dir"
rm -f "$dir/config/topology.conf"
assert_rejected 'missing topology' "$dir" 'topology not found:'

dir="$fixture/no-build-defaults"
make_case_workspace "$dir"
rm -f "$dir/config/build-defaults.conf"
assert_rejected 'missing build defaults' "$dir" 'build defaults not found:'

# ─── An invalid build default still names its key (pre-existing behaviour) ──
dir="$fixture/bad-default"
make_case_workspace "$dir"
sed -i 's/^memory_per_job_gib=.*/memory_per_job_gib=0/' "$dir/config/build-defaults.conf"
assert_rejected 'invalid numeric default' "$dir" 'memory_per_job_gib=0'

# ─── Per-record problems name the record, not just the file ─────────────────
dir="$fixture/group-duplicate"
make_case_workspace "$dir"
set_topology_record "$dir" p1 'git,git' # one group listed twice
assert_rejected 'duplicate group in field' "$dir" 'appears twice in the groups field'

dir="$fixture/group-unknown"
make_case_workspace "$dir"
set_topology_record "$dir" p2 'git,ghost'
assert_rejected 'unknown group in field' "$dir" 'unknown group in topology record p2: ghost'

dir="$fixture/edge-duplicate"
make_case_workspace "$dir"
set_topology_record "$dir" p1 git 'p2,p2'
assert_rejected 'duplicate edge in field' "$dir" 'appears twice in the edges field'

dir="$fixture/tag-unknown"
make_case_workspace "$dir"
set_topology_record "$dir" p1 git '' 'abi=maybe'
assert_rejected 'unknown tag' "$dir" 'unknown tag in topology record p1'

dir="$fixture/tag-conflict"
make_case_workspace "$dir"
set_topology_record "$dir" p1 git '' 'abi=must,abi=should'
assert_rejected 'conflicting tags' "$dir" 'names both abi=must and abi=should'

dir="$fixture/bad-id"
make_case_workspace "$dir"
printf '%s\n' 'bad id|packages/p1|git|' >>"$dir/config/topology.conf"
assert_rejected 'invalid id' "$dir" 'invalid topology record id'

# ─── NEW: a duplicate package id names the offender AND the line ────────────
# The old map's duplicate-id path was a bare `return 1` with no offender name;
# one record per package makes the duplicate possible again (two rows, one id),
# so the fix the loader got is pinned here.
dir="$fixture/duplicate-id"
make_case_workspace "$dir"
printf '%s\n' 'p1|packages/p1|git|' >>"$dir/config/topology.conf"
assert_rejected 'duplicate id' "$dir" 'duplicate package id in topology record: p1'

# ─── two DIFFERENT app-cluster tags on one record ──────────────────────────
# An identical repeated tag is caught by the repeat check; two different
# cluster names are the split-row hazard (one record must join exactly one
# prompt row), so the count check is pinned separately.
dir="$fixture/cluster-duplicate"
make_case_workspace "$dir"
set_topology_record "$dir" p1 git '' 'app-cluster=one,app-cluster=two'
assert_rejected 'multiple app-cluster tags' "$dir" 'names more than one app-cluster tag'

# ─── a forward edge reference (consumer listed before its dep) is valid ────
# Edge targets are validated only after EVERY record is known, so record order
# in the file is irrelevant: p1's record names p2 as its edge target while
# p2's record sits below it. The keyed target check must accept that exactly
# like the old scans did — a name-pattern bug in the key plumbing would reject
# it with the unknown-dependency error.
dir="$fixture/forward-edge"
make_case_workspace "$dir"
set_topology_record "$dir" p1 git 'p2'
if ! run_list "$dir"; then
    printf 'forward edge reference was rejected:\n%s\n' "$FIXTURE_OUTPUT" >&2
    exit 1
fi

# ─── build-defaults: every failure names its offender (line/text/file) ──────
# read_config_defaults was the one loader that returned 1 silently — the user
# saw only "invalid build defaults: <file>" and bisected by hand. The rule is
# now uniform with read_topology_config: the offending line (number + text) or
# the unreadable file is named in the error (2026-10-05).
dir="$fixture/defaults-malformed"
make_case_workspace "$dir"
printf 'this line has no equals sign\n' >"$dir/config/build-defaults.conf"
assert_rejected 'malformed build-defaults line' "$dir" \
    "invalid build defaults line 1 (expected 'key=value'): this line has no equals sign"

dir="$fixture/defaults-unknown-key"
make_case_workspace "$dir"
printf 'bogus_key=1\n' >"$dir/config/build-defaults.conf"
assert_rejected 'unknown build-defaults key' "$dir" \
    'unknown key in build defaults line 1: bogus_key=1'

dir="$fixture/defaults-unreadable"
make_case_workspace "$dir"
chmod 000 "$dir/config/build-defaults.conf"
assert_rejected 'unreadable build-defaults file' "$dir" 'build defaults unreadable:'
chmod 644 "$dir/config/build-defaults.conf"

# ─── fixture-lib smoke: a helper-built workspace satisfies the loader ────────
# The synthesis helper's contract is that its skeletons are valid OUT OF THE
# BOX — every migrated fixture rests on that. Wrapped in a subshell so the
# helper's redefinitions, trap and variables stay out of the cases above.
(
    set -euo pipefail
    source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
    smoke=$(mktemp -d "${TMPDIR:-/tmp}/gsa-fixture-lib.XXXXXX")
    trap 'rm -rf -- "$smoke"' EXIT

    ws="$smoke/ws"
    make_workspace "$ws" 1 2 low
    add_package "$ws" p1 "$gsa_meta_any"
    add_package "$ws" p2 "$gsa_meta_any" core

    run_builder fish "$ws/build-all.fish" --list
    if ((FIXTURE_RC != 0)) || [[ $FIXTURE_OUTPUT != *p1* ]]; then
        printf 'fixture-lib smoke: --list rejects a helper-built workspace (rc=%d):\n%s\n' \
            "$FIXTURE_RC" "$FIXTURE_OUTPUT" >&2
        exit 1
    fi

    run_builder fish "$ws/build-all.fish" --audit
    if ((FIXTURE_RC != 0)); then
        printf 'fixture-lib smoke: --audit rejects a helper-built workspace (rc=%d):\n%s\n' \
            "$FIXTURE_RC" "$FIXTURE_OUTPUT" >&2
        exit 1
    fi

    printf 'fixture-lib smoke: OK\n'
)

printf 'config diagnostics fixture: PASS\n'
