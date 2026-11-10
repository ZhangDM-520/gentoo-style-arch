#!/usr/bin/env bash
set -euo pipefail

# tests/completion.sh — shell completion is answered by the engine, not by a
# script that restates the grammar (contract §D.1).
#
# Two seams, one protocol:
#   `gsa --complete <words…>`      — candidates for the last word, which is the
#                                    partial token and may be empty;
#   `gsa --print-completion <sh>`  — the wrapper text for fish|bash|zsh, which
#                                    contains no grammar and calls the seam.
#
# What this fixture pins:
#   1. names come from the workspace on disk (a package the fixture created is
#      offered), never from a compiled list;
#   2. the `@` namespace offers the closed group roster plus a committed set;
#   3. a value position offers exactly what the engine will accept
#      (`--toolchain` → gcc, clang), with menu text on the wire;
#   4. a path position — after `--`, `-U <path>`, a path-valued flag — answers
#      `#mode files` so the shell completes a path;
#   5. the seam FAILS SOFT: an absent workspace and a corrupt topology both
#      answer nothing with rc 0. This is the one deliberate exception to the
#      unreadable-is-not-absent rule (rule 71): completion decides nothing, so
#      a broken store must not colour a prompt red;
#   6. the seam stays hidden (`--help` never names it) and the contract owns
#      it;
#   7. every emitted wrapper parses in its own shell, mentions the seam, and
#      carries no grammar of its own.
#
# Read-only and $TMPDIR-scoped like every battery member: the workspace is
# synthesized under $TMPDIR and nothing outside it is touched.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"
source "$(dirname "${BASH_SOURCE[0]}")/lib/rr-v2.bash"

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

fixture=$(mktemp -d "${TMPDIR:-/tmp}/gsa-completion.XXXXXX")
trap 'rm -rf -- "$fixture"' EXIT

fail() {
    printf 'completion fixture: %s\n' "$1" >&2
    exit 1
}

# Completion runs as an unprivileged user in a real shell (the wrapper is the
# invoking user's), so the fixture never runs it through sudo.
complete_at() { # WORKSPACE WORD...
    local ws=$1
    shift
    run_engine_user "$ws" --complete "$@"
}

ws=$fixture/ws
make_workspace "$ws"
add_package "$ws" zlib-fixture
add_package "$ws" alpha-fixture
# A committed set: the `@` namespace's second half (config/sets/<name>).
mkdir -p "$ws/config/sets"
printf 'zlib-fixture\n' >"$ws/config/sets/deskworld"

# ─── 1. names come from the workspace ───────────────────────────────────────
(
    set -euo pipefail
    complete_at "$ws" -S ""
    ((FIXTURE_RC == 0)) || fail "1: --complete must exit 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
    [[ $FIXTURE_OUTPUT == *zlib-fixture* && $FIXTURE_OUTPUT == *alpha-fixture* ]] ||
        fail "1: the roster of the workspace is not offered: $FIXTURE_OUTPUT"
    # A prefix narrows, and the description field never leaks into the value.
    complete_at "$ws" -S "zlib"
    [[ $FIXTURE_OUTPUT == *zlib-fixture* && $FIXTURE_OUTPUT != *alpha-fixture* ]] ||
        fail "1: the prefix does not narrow the answer: $FIXTURE_OUTPUT"
    printf '1: completion reads the topology on disk\n'
)

# ─── 2. the @ namespace: the closed roster plus the committed set ───────────
(
    set -euo pipefail
    complete_at "$ws" -S "@"
    ((FIXTURE_RC == 0)) || fail "2: rc $FIXTURE_RC: $FIXTURE_OUTPUT"
    for group in git stable core misc app build-tools; do
        [[ $FIXTURE_OUTPUT == *"@$group"* ]] ||
            fail "2: the group roster drops @$group: $FIXTURE_OUTPUT"
    done
    [[ $FIXTURE_OUTPUT == *'@deskworld'* ]] ||
        fail "2: a committed config/sets/ name is invisible to completion: $FIXTURE_OUTPUT"
    [[ $FIXTURE_OUTPUT != *'zlib-fixture'* ]] ||
        fail "2: the @ position offers the roster, not the ids: $FIXTURE_OUTPUT"
    printf '2: @ offers the roster and the committed sets\n'
)

# ─── 3. a value position offers what the engine accepts ─────────────────────
(
    set -euo pipefail
    complete_at "$ws" -B --toolchain ""
    ((FIXTURE_RC == 0)) || fail "3: rc $FIXTURE_RC: $FIXTURE_OUTPUT"
    [[ $(grep -c . <<<"$FIXTURE_OUTPUT") == 2 ]] ||
        fail "3: --toolchain must offer exactly gcc and clang: $FIXTURE_OUTPUT"
    [[ $FIXTURE_OUTPUT == *gcc* && $FIXTURE_OUTPUT == *clang* ]] ||
        fail "3: --toolchain does not offer both families: $FIXTURE_OUTPUT"
    # Menu text is a second, TAB-separated field on the same line.
    grep -q $'\t' <<<"$FIXTURE_OUTPUT" ||
        fail "3: the candidates carry no menu text: $FIXTURE_OUTPUT"
    complete_at "$ws" -B --toolchain gc
    [[ $(grep -c . <<<"$FIXTURE_OUTPUT") == 1 && $FIXTURE_OUTPUT == *gcc* ]] ||
        fail "3: the value position ignores the prefix: $FIXTURE_OUTPUT"
    printf '3: --toolchain offers gcc and clang with menu text\n'
)

# ─── 4. a path position hands the work back to the shell ────────────────────
(
    set -euo pipefail
    for case in '-U -- x' '--state-dir /v' '--build-dir /v' '-U /var/cache/pkg/'; do
        # shellcheck disable=SC2086 # each case is a deliberate word list
        complete_at "$ws" $case
        ((FIXTURE_RC == 0)) || fail "4: '$case' exited $FIXTURE_RC: $FIXTURE_OUTPUT"
        [[ $FIXTURE_OUTPUT == '#mode files' ]] ||
            fail "4: '$case' must answer only '#mode files', got: $FIXTURE_OUTPUT"
    done
    printf '4: path positions answer #mode files\n'
)

# ─── 5. fail-soft: a broken store answers nothing, never an error ───────────
(
    set -euo pipefail
    mkdir -p "$fixture/empty"
    complete_at "$fixture/empty" -S ""
    ((FIXTURE_RC == 0)) ||
        fail "5: no workspace must still exit 0 (fail-soft), got $FIXTURE_RC: $FIXTURE_OUTPUT"
    [[ -z $FIXTURE_OUTPUT ]] ||
        fail "5: no workspace must answer nothing, got: $FIXTURE_OUTPUT"

    # A workspace whose topology is unreadable is the same answer: silent.
    broken=$fixture/broken
    make_workspace "$broken"
    printf 'not-a-record\n' >>"$broken/config/topology.conf"
    complete_at "$broken" -S ""
    ((FIXTURE_RC == 0)) ||
        fail "5: a corrupt topology must still exit 0, got $FIXTURE_RC: $FIXTURE_OUTPUT"
    [[ -z $FIXTURE_OUTPUT ]] ||
        fail "5: a corrupt topology must answer nothing, got: $FIXTURE_OUTPUT"
    printf '5: the seam is fail-soft (rc 0, silent)\n'
)

# ─── 5b. the documented surface: family mask, inline values, real vocabularies ──
(
    set -euo pipefail
    # A build knob is not suggested where the dispatcher would refuse it.
    complete_at "$ws" -Q --
    [[ $FIXTURE_OUTPUT != *'--toolchain'* ]] ||
        fail "5b: -Q is offered a build-run flag: $FIXTURE_OUTPUT"
    [[ $FIXTURE_OUTPUT == *'--machine'* ]] ||
        fail "5b: -Q lost a flag it does document: $FIXTURE_OUTPUT"
    # `--toolchain=gc` is one token and must complete the whole token back.
    complete_at "$ws" -B --toolchain=gc
    [[ $FIXTURE_OUTPUT == *'--toolchain=gcc'* && $FIXTURE_OUTPUT != *clang* ]] ||
        fail "5b: the inline value form does not complete: $FIXTURE_OUTPUT"
    # `auto` is a lanes/jobs answer; the budget resolver rejects it for
    # --intensity, so the roster must not hand it over.
    complete_at "$ws" -B --intensity ""
    [[ $FIXTURE_OUTPUT != *auto* ]] ||
        fail "5b: --intensity offers 'auto', which the engine refuses: $FIXTURE_OUTPUT"
    for level in low medium high xhigh max; do
        [[ $FIXTURE_OUTPUT == *"$level"* ]] ||
            fail "5b: --intensity drops '$level': $FIXTURE_OUTPUT"
    done
    printf '5b: the mask, the inline form and the real vocabularies hold\n'
)

# ─── 5c. the seam reads; it never creates state ─────────────────────────────
(
    set -euo pipefail
    absent=$fixture/never-created
    GSA_STATE_DIR="$absent" complete_at "$ws" -S ""
    ((FIXTURE_RC == 0)) || fail "5c: rc $FIXTURE_RC: $FIXTURE_OUTPUT"
    [[ ! -e $absent ]] ||
        fail "5c: completion created its state root ($absent) — §D.1 promises a read-only seam"
    printf '5c: completion creates no state\n'
)

# ─── 6. hidden from --help, owned by the contract ───────────────────────────
(
    set -euo pipefail
    run_engine_user "$ws" --help
    ((FIXTURE_RC == 0)) || fail "6: --help exited $FIXTURE_RC"
    [[ $FIXTURE_OUTPUT != *'--complete'* ]] ||
        fail "6: --help names a hidden seam: $FIXTURE_OUTPUT"
    for seam in '--complete' '--print-completion'; do
        grep -Fq "\`$seam" "$repo/docs/gsa-contract.md" ||
            fail "6: the contract does not own $seam (§D.1)"
    done
    grep -Fq 'fail-soft' "$repo/docs/gsa-contract.md" ||
        fail "6: the contract does not state the fail-soft exception"
    printf '6: the seam is hidden but contractual\n'
)

# ─── 7. the wrappers are grammar-free and parse in their own shell ──────────
(
    set -euo pipefail
    declare -A body=()
    for shell in fish bash zsh; do
        run_engine_user "$ws" --print-completion "$shell"
        ((FIXTURE_RC == 0)) ||
            fail "7: --print-completion $shell exited $FIXTURE_RC: $FIXTURE_OUTPUT"
        [[ -n $FIXTURE_OUTPUT ]] || fail "7: $shell wrapper is empty"
        grep -Fq 'gsa --complete' <<<"$FIXTURE_OUTPUT" ||
            fail "7: the $shell wrapper does not call the seam: $FIXTURE_OUTPUT"
        for grammar in '--dry-run' '@core' '--toolchain'; do
            [[ $FIXTURE_OUTPUT != *"$grammar"* ]] ||
                fail "7: the $shell wrapper restates the grammar ('$grammar')"
        done
        body[$shell]=$FIXTURE_OUTPUT
        printf '%s\n' "$FIXTURE_OUTPUT" >"$fixture/wrapper.$shell"
    done

    # The shells' own parsers are the authority; a missing shell is a loud
    # SKIP, never a pass.
    if command -v fish >/dev/null 2>&1; then
        fish -n "$fixture/wrapper.fish" || fail "7: the fish wrapper does not parse"
    else
        printf '7: SKIP fish -n (fish not installed)\n'
    fi
    bash -n "$fixture/wrapper.bash" || fail "7: the bash wrapper does not parse"
    if command -v zsh >/dev/null 2>&1; then
        zsh -n "$fixture/wrapper.zsh" || fail "7: the zsh wrapper does not parse"
    else
        printf '7: SKIP zsh -n (zsh not installed)\n'
    fi

    # An unknown shell is a usage error naming the three it accepts.
    run_engine_user "$ws" --print-completion tcsh
    ((FIXTURE_RC == 2)) ||
        fail "7: an unknown shell must be rc 2, got $FIXTURE_RC: $FIXTURE_OUTPUT"
    [[ $FIXTURE_OUTPUT == *'fish|bash|zsh'* ]] ||
        fail "7: the refusal does not name the shells: $FIXTURE_OUTPUT"
    printf '7: three wrappers, no grammar, all parse\n'
)

printf 'completion fixture: PASS\n'
