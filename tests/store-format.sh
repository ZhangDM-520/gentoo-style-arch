#!/usr/bin/env bash
set -euo pipefail

# tests/store-format.sh — the recipe-store compatibility gate.
#
# A recipe store declares the format it was written for
# (`config/build-defaults.conf`'s `store_format`). An engine that does not
# understand that format must refuse LOUDLY at load time instead of misreading
# records it was never taught — this is the prerequisite for splitting the
# recipe half into its own repository, so the gate has to ship BEFORE any
# store declares a format. Four cases, one fresh synthetic workspace each:
#
#   a. absent  → the legacy path: format 1, accepted (the gate must never
#                close on the stores that exist today);
#   b. =1      → accepted;
#   c. =2      → rc 2 (usage class) and the exact upgrade remedy;
#   d. =abc    → rc 2 and a NAMED error (file:line), never a silent default.
#
# Read-only: every run is the query family (`-Sl`), which still loads and
# validates the whole config, so nothing here mutates the host. All scratch
# lives in one $TMPDIR tree removed by the trap, which keeps the fixture
# parallel-safe like every other battery member. The engine is
# $GSA_TEST_GSA_BIN when the runner prebuilt one, else `gsa` from PATH.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"

fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-store-format.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf 'store-format fixture: %s\n' "$1" >&2
    exit 1
}

# The newest format this engine build supports, kept as a literal on purpose:
# the fixture is the INDEPENDENT half of the pair, so a bump that forgets one
# side shows up as a red fixture instead of two agreeing mistakes.
supported_max=1

# Where a case's appended key lands: make_workspace writes six defaults lines.
store_format_line=7

# make_case DIR [VALUE] — one workspace; VALUE appends `store_format=VALUE`.
make_case() {
    local dir=$1 value=${2:-}
    make_workspace "$dir"
    add_package "$dir" p1
    if [[ -n $value ]]; then
        printf 'store_format=%s\n' "$value" >>"$dir/config/build-defaults.conf"
        [[ $(sed -n "${store_format_line}p" "$dir/config/build-defaults.conf") == "store_format=$value" ]] ||
            fail "fixture bug: the appended store_format is not on line $store_format_line"
    fi
}

# run_list DIR — `-Sl` (a read, so unprivileged, §B.10) still loads the whole
# config; captures into FIXTURE_OUTPUT and FIXTURE_RC.
run_list() {
    run_engine_user "$1" -Sl
    return "$FIXTURE_RC"
}

# ─── a. absent: the legacy path stays open ──────────────────────────────────
dir="$fixture/absent"
make_case "$dir"
if ! run_list "$dir"; then
    fail "a store with no store_format key was REFUSED (legacy stores must load): $FIXTURE_OUTPUT"
fi

# ─── b. =1: the current format is accepted ──────────────────────────────────
dir="$fixture/format-1"
make_case "$dir" 1
if ! run_list "$dir"; then
    fail "store_format=1 was REFUSED: $FIXTURE_OUTPUT"
fi

# ─── c. =2: rc 2 and the exact upgrade remedy ───────────────────────────────
# The second record names a group this engine does not know, i.e. the shape a
# newer store may plausibly use. The gate must speak FIRST: the operator needs
# the upgrade remedy, not a record-level complaint about a store it cannot
# read anyway.
dir="$fixture/format-2"
make_case "$dir" 2
set_topology_record "$dir" p2 future-group
expected="recipe store format 2 needs a newer gsa (this build supports $supported_max) — run 'sudo pacman -Syu gsa-pm', then 'sudo gsa -Sy'"
if run_list "$dir"; then
    fail "a store format newer than this engine was ACCEPTED: $FIXTURE_OUTPUT"
fi
[[ $FIXTURE_RC -eq 2 ]] ||
    fail "store_format=2 exited $FIXTURE_RC, want 2 (usage class): $FIXTURE_OUTPUT"
vgrep "$FIXTURE_OUTPUT" -Fq -- "$expected" ||
    fail "store_format=2 did not print the exact remedy: $FIXTURE_OUTPUT"
if vgrep "$FIXTURE_OUTPUT" -Fq 'unknown key'; then
    fail "store_format=2 was rejected as an unknown key, not by the compatibility gate: $FIXTURE_OUTPUT"
fi

# ─── d. =abc: a named error, never a silent default ─────────────────────────
dir="$fixture/not-a-number"
make_case "$dir" abc
if run_list "$dir"; then
    fail "store_format=abc was ACCEPTED (a non-numeric format must be an error): $FIXTURE_OUTPUT"
fi
[[ $FIXTURE_RC -eq 2 ]] ||
    fail "store_format=abc exited $FIXTURE_RC, want 2 (usage class): $FIXTURE_OUTPUT"
vgrep "$FIXTURE_OUTPUT" -Fq "config/build-defaults.conf:${store_format_line}:" ||
    fail "store_format=abc did not name the file and line: $FIXTURE_OUTPUT"
vgrep "$FIXTURE_OUTPUT" -Fq 'invalid value for store_format' ||
    fail "store_format=abc did not name store_format as the offender: $FIXTURE_OUTPUT"
if vgrep "$FIXTURE_OUTPUT" -Fq 'unknown key'; then
    fail "store_format=abc was rejected as an unknown key, not as a bad value: $FIXTURE_OUTPUT"
fi
