#!/usr/bin/env bash
set -euo pipefail

# tests/workspace-hint.sh — an engine checkout is not a recipe workspace.
#
# The recipe half lives in its own repository (contract §B.8), so this
# repository has no `config/topology.conf` and must never look like a
# workspace. Every command that needs one has to fail with the SAME remedy:
# `WORKSPACE_HINT` (`gsa-model`), a single string with three rungs — set
# `project`, run inside the recipe repository, or fetch the store. The retired
# cwd-only advice taught a workflow the store replaced, and a second copy of the
# sentence drifts from the first, so both the CLI's discovery error and the
# hidden `--fetch-job` child error must render that one constant.
#
# Two cases, one $TMPDIR tree:
#   a. no store, no `project`  → rc 2, the hint names all three remedies, and
#      the message names the missing file (`config/topology.conf`);
#   b. `project` in gsa.conf   → `-Qt` resolves the synthetic workspace and
#      lists its records, proving the hint's first rung is real advice;
#   plus the `--fetch-job` child, which owns its own preamble but not its own
#   remedy.
#
# Read-only and $TMPDIR-scoped like every battery member: `-Qt` and the fetch
# child are query paths, and the synthetic workspace is built under $TMPDIR.
# The engine is $GSA_TEST_GSA_BIN when set, else the installed one.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"

fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-workspace-hint.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf 'workspace-hint fixture: %s\n' "$1" >&2
    exit 1
}

# The remedies, spelled once here as the fixture's INDEPENDENT half: the
# fixture must fail if the engine rewords the hint, because a rewording is a
# behaviour change nobody asked for.
hint_project='set `project` in gsa.conf'
hint_inside='run inside the recipe repository'
hint_store='fetch the store with `sudo gsa -Sy`'

mkdir -p "$fixture/empty"
: >"$fixture/empty.conf"

# ─── a. no store, no project: the shared hint, with all three rungs ─────────
(
    set -euo pipefail
    run_engine "$fixture/empty" -Qt
    ((FIXTURE_RC == 2)) ||
        fail "a: a directory with no workspace must be a usage error (rc 2, §G.1), got $FIXTURE_RC: $FIXTURE_OUTPUT"
    for clause in "$hint_project" "$hint_inside" "$hint_store"; do
        [[ $FIXTURE_OUTPUT == *"$clause"* ]] ||
            fail "a: the hint drops '$clause': $FIXTURE_OUTPUT"
    done
    [[ $FIXTURE_OUTPUT == *'config/topology.conf'* ]] ||
        fail "a: the error never names the file it looked for: $FIXTURE_OUTPUT"
    printf 'a: the shared workspace hint names all three remedies\n'
)

# ─── b. `project` resolves a real tree: the hint's first rung is advice ─────
(
    set -euo pipefail
    make_workspace "$fixture/ws"
    add_package "$fixture/ws" hint-pkg
    printf 'project = %s\n' "$fixture/ws" >"$fixture/with-project.conf"

    GSA_CONF="$fixture/with-project.conf" GSA_STATE_DIR="$fixture/state" \
        run_engine "$fixture/empty" -Qt
    ((FIXTURE_RC == 0)) ||
        fail "b: a configured project must resolve (rc 0), got $FIXTURE_RC: $FIXTURE_OUTPUT"
    grep -Fq 'hint-pkg|' <<<"$FIXTURE_OUTPUT" ||
        fail "b: the topology channel does not list the configured workspace: $FIXTURE_OUTPUT"
    printf 'b: a configured project resolves the workspace\n'
)

# ─── c. a BROKEN gsa.conf names its own error, never a missing topolog ─────
# A typo'd key used to be answered with "cannot find a recipe workspace
# (missing config/topology.conf)": the parse error was discarded by the
# discovery seam and the reader chased a file that was never the problem
# (blind review, 2026-11-11).
(
    set -euo pipefail
    printf 'projekt = %s\n' "$fixture/ws" >"$fixture/typo.conf"
    GSA_CONF="$fixture/typo.conf" GSA_STATE_DIR="$fixture/state" \
        run_engine "$fixture/empty" -Qt
    ((FIXTURE_RC == 2)) ||
        fail "c: a malformed gsa.conf must be a usage error (rc 2), got $FIXTURE_RC: $FIXTURE_OUTPUT"
    [[ $FIXTURE_OUTPUT == *'unknown gsa.conf key'* && $FIXTURE_OUTPUT == *projekt* ]] ||
        fail "c: the real config error is discarded: $FIXTURE_OUTPUT"
    [[ $FIXTURE_OUTPUT != *'missing config/topology.conf'* ]] ||
        fail "c: the workspace prose still masks the config error: $FIXTURE_OUTPUT"
    printf 'c: a malformed gsa.conf reports its own error\n'
)

# ─── d. an explicitly named GSA_CONF must exist ────────────────────────────
# `GSA_CONF` "replaces the auto-read layers with exactly one file", so a
# misspelt path is an operator error — not an empty layer that silently ran
# against the built-in directories (blind review, 2026-11-11).
(
    set -euo pipefail
    GSA_CONF="$fixture/nope.conf" GSA_STATE_DIR="$fixture/state" \
        run_engine "$fixture/empty" -Qt
    ((FIXTURE_RC == 2)) ||
        fail "d: a missing GSA_CONF must be a usage error (rc 2), got $FIXTURE_RC: $FIXTURE_OUTPUT"
    [[ $FIXTURE_OUTPUT == *"cannot read $fixture/nope.conf"* ]] ||
        fail "d: the missing file is not named: $FIXTURE_OUTPUT"
    printf 'd: an explicitly named GSA_CONF must exist\n'
)

# ─── the fetch child: its own preamble, the shared remedy ──────────────────
(
    set -euo pipefail
    GSA_CONF="$fixture/empty.conf" GSA_STATE_DIR="$fixture/state" \
        run_engine "$fixture/empty" --fetch-job hint-pkg "$fixture/verdict"
    ((FIXTURE_RC == 2)) ||
        fail "fetch-job: no workspace must be a usage error (rc 2), got $FIXTURE_RC: $FIXTURE_OUTPUT"
    [[ $FIXTURE_OUTPUT == *'cannot find config/topology.conf'* ]] ||
        fail "fetch-job: the child lost its own preamble: $FIXTURE_OUTPUT"
    [[ $FIXTURE_OUTPUT == *"$hint_project"* && $FIXTURE_OUTPUT == *"$hint_store"* ]] ||
        fail "fetch-job: the child carries its own copy of the remedy instead of WORKSPACE_HINT: $FIXTURE_OUTPUT"
    printf 'fetch-job: one remedy string, two call sites\n'
)

printf 'workspace-hint fixture: PASS (shared hint, project resolution, fetch child)\n'
