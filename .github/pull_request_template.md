<!-- A guide, not a form to satisfy: keep the headings that carry evidence and
     delete the rest. The maintainer reads the validation block first. -->

## What this changes

One or two sentences, plus the seam it lives at. If the contract moves, name
the section (§B–§L) that moves with it.

## Why

The measurement, defect or decision behind it — `path:line`, a command and its
key output, a run record row. "Cleaner" is not a reason; a claim a reviewer can
falsify is.

## Validation

Tick what you actually ran, and report deviations as deviations:

- [ ] `tools/fmt.sh`
- [ ] `cargo clippy --workspace --all-targets`
- [ ] `cargo test --workspace` (or `-- --test-threads=1`)
- [ ] `bash tests/run-all.sh`
- [ ] `GSA_RECIPE_CHECKOUT=… bash tests/run-all.sh`
- [ ] `gsa -Ma` (report-only — paste the findings, not just the exit code)

Notes: the engine under test (`gsa-pm <version>` or a `GSA_TEST_GSA_BIN`
override), any fixture that SKIPped, anything you could not run and why.

## Behaviour, fixture, retirement

- A behavioural change to scheduling, install, state, fetch or signals: which
  fixture pins it?
- A retired spelling or a dead path: where is it removed in the same change?
- If a check was bypassed, say which one and why — a green run that skipped a
  gate is not a green run.

## Scope

- [ ] Engine-side only — nothing about `packages/` or `config/` is stated here
- [ ] The recipe half has its own PR in `ZhangDM-520/gsa-recipe`
