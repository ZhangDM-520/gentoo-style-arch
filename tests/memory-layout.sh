#!/usr/bin/env bash
set -euo pipefail

# tests/memory-layout.sh — the memory-architecture layout gate.
#
# The repo's memory is a LAYOUT, not a habit: `AGENTS.md` at the root is the
# global memory (overview, read-first map, commands, architecture, RULES,
# pitfalls, queue); `docs/JOURNAL.md` is the historical log, one dense dated
# line per action; `.logs/scratchpad.md` is the active buffer and
# `.logs/action-<ISO-date>-<task>.md` are per-action exports that are NEVER
# tracked by git. `docs/MEMORY.md` (rules, pitfalls, queue) and `docs/NOTE.md`
# (dated incident sections) were retired on 2026-11-09 into those files.
#
# A silent regression here is a reader following a dead pointer: a re-created
# `docs/MEMORY.md`, a code comment citing a deleted doc, a committed action
# export. Each of those has to go red in the battery instead of being found
# later by somebody who trusted the map.
#
# The assertions are on the CONTRACT — existence, absence, section titles,
# citation cleanliness — never on prose wording, so the documents stay free to
# be rewritten while the layout holds.
#
# `tests/assets/**` is excluded from the citation scan because it is the frozen
# differential oracle (the retired fish engine), not live documentation: those
# files keep their pre-retirement text verbatim. Root `plan*.md` are excluded
# too — archive-class design records whose MEMORY/NOTE citations are dated
# provenance, annotated in their own headers.
#
# Read-only and therefore parallel-safe: every check is `git grep`,
# `git ls-files`, `wc -l`, `head` or `[[ -f ]]`. Nothing is written, no $TMPDIR
# workspace is synthesized and no trap is needed, so the fixture can run beside
# every other battery member.

source "$(dirname "${BASH_SOURCE[0]}")/lib/fixture-lib.bash"

root=$gsa_repo_root

fail() {
    printf 'memory-layout fixture: %s\n' "$1" >&2
    exit 1
}

# ─── 1. The required layout exists ─────────────────────────────────────────
for f in AGENTS.md docs/JOURNAL.md .logs/scratchpad.md; do
    [[ -f $root/$f ]] || fail "missing required memory file: $f"
done

# Existence alone would pass on a truncated file, so each document also clears
# a floor: a stub that lost its body must fail loudly, not silently.
lines=$(wc -l <"$root/AGENTS.md")
((lines >= 100)) ||
    fail "AGENTS.md is a stub: $lines line(s), want at least 100 (global memory truncated?)"
lines=$(wc -l <"$root/docs/JOURNAL.md")
((lines >= 50)) ||
    fail "docs/JOURNAL.md is a stub: $lines line(s), want at least 50 (history truncated?)"

# ─── 2. The retired files are absent ───────────────────────────────────────
# A re-created file is a second source of truth and would silently diverge from
# the copy that is actually read.
for f in docs/MEMORY.md docs/NOTE.md; do
    if [[ -e $root/$f ]]; then
        fail "$f was retired on 2026-11-09 — its content now lives in AGENTS.md (rules, pitfalls, queue) and docs/JOURNAL.md (incident history); delete it rather than restoring a second source of truth"
    fi
done

# ─── 3. AGENTS.md carries the required sections ────────────────────────────
# Titles only: the numeric prefix and the `·` separator are presentation, so a
# renumbering stays green while a dropped section goes red. Exactly one H2 per
# title — a duplicated section is two homes for one rule set.
count_section() {
    grep -c -- "^## .*$1" "$root/AGENTS.md" || true
}

for title in 'What this repository is' \
    'Read before changing anything' \
    'Commands' \
    'Rules' \
    'Pitfalls' \
    'Queued'; do
    n=$(count_section "$title")
    [[ $n == 1 ]] ||
        fail "AGENTS.md has $n H2 section(s) titled '$title', want exactly 1"
done

# The journal is a log, so it opens with its H1 banner and never a bare list.
first=$(head -1 "$root/docs/JOURNAL.md")
[[ $first == '# '* ]] ||
    fail "docs/JOURNAL.md does not open with an H1 heading: $first"

# ─── 4. No live citation of a retired path ─────────────────────────────────
# Five exclusions, each with a reason. tests/assets/ is the frozen oracle.
# docs/JOURNAL.md and AGENTS.md narrate the retirement itself (the journal
# header explains it; AGENTS.md names the retired numbering). Root `plan*.md`
# are archive-class design records: `crates/` and the contract cite them by
# section, so they are kept, and their internal MEMORY/NOTE citations —
# including line ranges — are annotated in their own headers rather than
# rewritten, because rewriting them would destroy the provenance a dated
# design record exists to preserve. And this fixture names the two paths it
# forbids (in its prose, its loop and its message), so it excludes itself —
# section 2 is what catches a re-created file. Anything else citing the paths
# points a reader at a dead file.
if out=$(git -C "$root" grep -n -E '(MEMORY|NOTE)\.md|\bMEMORY rule|\bMEMORY §' -- . \
    ':!tests/assets' ':!docs/JOURNAL.md' ':!AGENTS.md' ':!plan*.md' \
    ':!tests/memory-layout.sh' 2>/dev/null); then
    hits=$(printf '%s\n' "$out" | head -5)
    fail "live citation of a retired path — docs/MEMORY.md moved to AGENTS.md (rule numbers preserved) and docs/NOTE.md moved to docs/JOURNAL.md; offending hits:
$hits"
fi

# ─── 5. Action exports are never tracked ───────────────────────────────────
# The exports are per-action scratch: they belong under the ignored .logs/, so
# a `git add -A` must not drag one into history. scratchpad.md is deliberately
# NOT asserted on — it may be tracked or ignored, the contract only requires
# that it exists (section 1).
if tracked=$(git -C "$root" ls-files -- '.logs/action-*.md') && [[ -n $tracked ]]; then
    fail "action export(s) tracked by git (per-action scratch, never committed): $(printf '%s\n' "$tracked" | head -5)"
fi

printf 'memory-layout fixture: PASS (layout present, retired files absent, sections unique, no live retired citations, no tracked action exports)\n'
