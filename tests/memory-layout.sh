#!/usr/bin/env bash
set -euo pipefail

# tests/memory-layout.sh — the retired-notes layout gate.
#
# Agent bookkeeping does not live in this repository any more: the journal, the
# scratchpad, the per-action exports and the extracted rule/pitfall/queue
# bodies were retired to the maintainer's private warehouse on 2026-11-17. What
# the public tree keeps is the project's own documentation and ONE agent entry
# point, `AGENTS.md`. A stranger reading the tree should find the project, never
# the notebook.
#
# The gate is the INVERSION of the layout it replaced: the retired paths must be
# ABSENT and `AGENTS.md` must be PRESENT. A silent regression here is a
# re-created second source of truth — a fresh `docs/JOURNAL.md`, a committed
# `.logs/` export, a restored `docs/rules.md` — which is exactly the copy that
# diverges from the warehouse and that nobody reading the public tree can
# reconcile.
#
# The agent-era doc class is retired with it (2026-11-18): `docs/plans/`, the
# ADRs, the fixture inventory and the review/audit records were agent-produced
# design and campaign records, and git history is their archive. `crates/` and
# `docs/gsa-contract.md` still cite them by path and section — those citations
# are provenance, so they stay and resolve through `git show <commit>:<path>`
# rather than a re-created file.
#
# The assertions are on the CONTRACT — path presence and absence — never on
# prose wording, and they carry no host path, no `~` reference and no
# private-store detail, so the test is true of any checkout and safe to run in
# public CI.
#
# Read-only and therefore parallel-safe: every check is `[[ -e ]]`,
# `git ls-files` or `wc -l`. Nothing is written, no $TMPDIR workspace is
# synthesized and no trap is needed, so the fixture can run beside every other
# battery member.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"

root=$gsa_repo_root

fail() {
    printf 'memory-layout fixture: %s\n' "$1" >&2
    exit 1
}

# ─── 1. The one convention file is present ─────────────────────────────────
[[ -f $root/AGENTS.md ]] || fail "missing the agent entry point: AGENTS.md"

# Existence alone would pass on a truncated file, so the entry point also
# clears a floor: a stub that lost its body must fail loudly, not silently.
# The floor is deliberately far below the file's real length — AGENTS.md is an
# agent-facing README, not a rules dump, and it shrinks as bodies move to the
# warehouse.
lines=$(wc -l <"$root/AGENTS.md")
((lines >= 40)) ||
    fail "AGENTS.md is a stub: $lines line(s), want at least 40 (entry point truncated?)"

# ─── 2. The retired bookkeeping paths are absent ───────────────────────────
# A re-created path is a second source of truth: it would silently diverge from
# the warehouse copy and point a reader at a file the project no longer keeps.
for f in \
    .logs \
    docs/JOURNAL.md \
    docs/journals \
    docs/reviews \
    docs/researchs \
    docs/scratchpad.md \
    docs/MEMORY.md \
    docs/NOTE.md \
    docs/CURRENT.md \
    docs/pitfalls.md \
    docs/rules.md \
    docs/queue.md \
    docs/plans \
    docs/adr \
    docs/audit \
    docs/audits \
    docs/gsa-fixture-migration.md \
    scratchpad.md \
    MEMORY.md \
    NOTE.md \
    CURRENT.md; do
    if [[ -e $root/$f ]]; then
        fail "$f is retired agent bookkeeping (archived outside this tree) — delete it rather than restoring a second source of truth in the public tree"
    fi
done

# ─── 3. Action exports are never tracked ───────────────────────────────────
# Defence in depth for the case the working tree looks clean: a path staged in
# the index but deleted from the tree is still a second source of truth.
if tracked=$(git -C "$root" ls-files -- '.logs/action-*.md') && [[ -n $tracked ]]; then
    fail "action export(s) tracked by git (per-action scratch, never committed): $(printf '%s\n' "$tracked" | head -5)"
fi

printf 'memory-layout fixture: PASS (AGENTS.md present, retired bookkeeping paths absent, no tracked action exports)\n'
