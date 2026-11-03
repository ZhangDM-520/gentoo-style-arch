# AGENTS.md — memory management architecture & entry point

Last reviewed: 2026-10-31

Every session reads this file first. It defines *where memory lives* and *how
it is written*; it holds no rules of its own — rules and pitfalls have single
sources of truth elsewhere and are linked, never copied.

## 0. Memory architecture

| Layer | File | Role | Write policy |
| --- | --- | --- | --- |
| Router | `AGENTS.md` (this file) | Architecture map, workflow protocol, pointers | Rewrite on architecture change only |
| Rules & state | `docs/MEMORY.md` | Golden rules (§1), workspace/stack state (§2–3), optimization playbook (§4), pending-task queue (§5 `Queued`), pitfall digest (§6) | A changed operational contract edits §1; queue items are claimed by editing §5; finished items are deleted, never ticked |
| Incident history | `docs/NOTE.md` | Dated incident sections, newest first: symptom → root cause → fix → validation → durable rule | One `##` section per non-trivial change |
| Action journal | `docs/JOURNAL.md` | One line per action, chronological (oldest first) | Append exactly one line after each action |
| Active buffer | `.logs/scratchpad.md` | Current task state, dense tool output, milestones | Reset to stub after each action export |
| Action exports | `.logs/action-<ISO-date>-<brief-task>.md` | Atomic per-action summaries | Written once, never edited after |
| Live snapshot | `docs/CURRENT.md` | Umbriel stack live snapshot | Overwrite, do not append — owned by a parallel session lane; do not edit from a rebuild-campaign lane |

History split: everything before the 2026-10-31 cutover is journaled only in
`docs/NOTE.md` (dated `##` sections) and `docs/MEMORY.md` §5/§6; `docs/JOURNAL.md`
starts at the cutover and links forward into `docs/NOTE.md` sections for detail.

## 1. Workflow protocol

1. **PRE-ACTION** — read this file and `docs/JOURNAL.md` (precedence), then the
   `docs/MEMORY.md` sections the task touches (`grep -n '^## ' docs/MEMORY.md`
   for the section map; grep a dated `docs/NOTE.md` section, never read it end
   to end). Initialize the current task in `.logs/scratchpad.md`.
2. **IN-ACTION** — keep dense intermediate tool output and milestones in
   `.logs/scratchpad.md`, not in the model context and not in `docs/`.
3. **POST-ACTION** — write `.logs/action-<ISO-date>-<brief-task>.md`, append one
   summary-pointer line to `docs/JOURNAL.md`, reset `.logs/scratchpad.md`.
4. A non-trivial packaging or scheduler change *also* earns a dated
   `docs/NOTE.md` section (format: `docs/maintainer-guide.md`); a changed
   operational contract updates `docs/MEMORY.md`. The journal line points at
   both; it never restates them.

## 2. Project overview

Two halves: a curated Arch recipe set (`packages/{git,stable,core,misc}/`) and
`gsa`, the Rust build engine under `crates/` that rebuilds the set as one
coherent system. Start at `README.md`; structure in `docs/architecture.md`;
the authoritative engine interface is `docs/gsa-contract.md`; vocabulary in
`CONTEXT.md`.

## 3. Long-term rules (single source of truth)

- Golden rules — `docs/MEMORY.md` §1 (violations caused real breakage)
- Optimization policy and documented exceptions — `docs/MEMORY.md` §4
- Operational contract seams referenced by number — `docs/MEMORY.md` §1
  (rules 11/12/15/19/20/23/25/68–70 are cited across `docs/gsa-contract.md`)
- Change hygiene, validation standard, commit policy — `CONTRIBUTING.md`
- Trust model and safe-operation rules — `SECURITY.md`

## 4. Pitfalls (single source of truth)

- Pitfall digest with per-entry `docs/NOTE.md` links — `docs/MEMORY.md` §6
- Host/environment hazards (fish login shell vs bash tool shells, agent-shell
  git hardening `GIT_CONFIG_COUNT=0`, stale packaged `gsa`, the
  `core_perl` PATH trap) — `docs/MEMORY.md` §1 rules 1–2 and the session
  runbook in `.logs/scratchpad.md`

## 5. Memory-writing discipline

- **Single source of truth**: never duplicate a rule or list; link with an
  explicit Markdown pointer (`docs/MEMORY.md` §6, not "see the pitfalls").
- **Methodology over state**: record *how to verify* (commands, probes,
  formulas), not volatile values; re-stamp entries `Last reviewed: YYYY-MM-DD`
  when re-verified.
- **Payload economy**: dense command output goes to `.logs/scratchpad.md`;
  `docs/` gets conclusions and pointers only.
- Keep private paths, credentials, host logs and generated artifacts out of
  `docs/` and out of `AGENTS.md`.
