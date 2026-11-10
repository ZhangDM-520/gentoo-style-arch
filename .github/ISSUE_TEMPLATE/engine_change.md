---
name: Engine change
about: Propose a change to the engine — a behaviour, a seam, an exit code, a record field
title: ''
labels: ''
assignees: ''
---

<!-- A guide, not a form to satisfy. Delete any heading that does not apply. -->

## What changes, and for whom?

One or two sentences: what a caller/operator can do afterwards that they could
not before, or what they have to stop doing.

## Which existing thing does it touch?

- Contract section(s): the grammar (§B), selection (§C), hidden seams (§D),
  decision rows and rc contract (§E), outcome vocabularies (§F), exit codes
  (§G), the run record (§H), failure policy (§I), state layout (§J),
  concurrency (§K), change control (§L).
- The seam it edits — and why no existing seam can carry it. A change that
  adds a second decision site, a second counter or a fourth derivation is the
  shape this repository rejects.
- Whether it is engine-side or recipe-side (they are different repositories).

## Is it a behaviour or a spelling?

A spelling change updates the contract's migration table (§B.9) and every
fixture that pins it. A behaviour change to scheduling, install, state, fetch
or signals ships with a fixture in the same change — name the fixture here if
you know it, or say that the issue needs one.

## What would falsify your claim?

The check that would convince a reviewer, and what result would prove the
change wrong. "The battery stays green" is not a measurement; name the
assertion.
