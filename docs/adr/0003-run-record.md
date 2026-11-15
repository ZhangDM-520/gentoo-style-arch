# Run record: builder-internal data, default-on machine block

Plan and outcome knowledge was re-derived in three places (dispatch
accounting, `_RL_*` globals, the summary) and two hand-maintained
continuation-flag mirrors drifted repeatedly (including the 2026-09-26
failed-package drop). We decided: one **run record** — plan + per-package
outcome rows + continuation — computed once inside the builder and rendered
three ways (streaming dashboard, prose, and an additive machine-checkable
block on stdout, default-on, also emitted on the interrupt path). The record
is not persisted to `.state/` (that would blur the Builder/Runtime-state
split), and there is no opt-in flag (unassertable behaviour stays
unassertable). Continuation arguments come from one flag-rule table with an
explicit not-mirrored list; ambient env knobs (`GSA_TARGET_CPU`,
`GSA_STATE_DIR`) are warned about, not mirrored.

## Considered options

- Persisting the record under `.state/`.
- Opt-in machine output via a flag.
- Splitting outcome and presentation into two modules — unstable seam;
  presentation would own continuation-flag semantics again.

## Consequences

Prose fixtures migrate to the record except one rendering test; the rc-99
deferral becomes a named outcome, amending the "failure stops dispatches"
invariant in `docs/architecture.md`; interrupted runs finally emit a summary
and continuation.

## Amendment: persisted, and the stored row names its grammar

Contract §H.1 later reversed the "not persisted" clause: the record is
persisted into the side-car run history (§J.2, `gsa -Mh`) because the side-car
DB owns run history by owner decision. That is storage of the same structure
and not a fourth derivation — reads re-render through
`RunRecord::render_machine`, so the stored record and the emitted block cannot
drift.

The reversal exposed a second gap the original decision never had to answer:
the store carried no record-format marker while every live rendering announced
one (`format: 2`). Two consequences followed, both wrong. After a format bump a
stored row and a damaged row would be indistinguishable, and re-rendering an
old row through the new grammar would be a guess printed as a re-render.

The stored row therefore carries `"format":<n>`, written from the ONE literal
that renders the block (`gsa_model::RECORD_FORMAT`), so the two directions
share an authority. A row naming a grammar this build does not render fails
deserialization, so it rides the store's existing corruption tolerance: the
listing names it and keeps the readable rows, while `--show` and `--prune`
refuse rather than renumber over the hole (rule 71). A row with no marker reads
as the current grammar, because this store was born at `format: 2` and no other
grammar has written to it; nothing is rewritten in place. Normative text is
contract §H.1's 2026-11-15 amendment (R2-vera-11).
