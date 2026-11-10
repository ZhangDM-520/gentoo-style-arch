# Contributing to the engine

This repository holds `gsa`, the build engine. The recipe set it builds —
`PKGBUILD` files, topology, recipe policy and the recipe battery — lives in
[`ZhangDM-520/gsa-recipe`](https://github.com/ZhangDM-520/gsa-recipe); its
`CONTRIBUTING.md` is the checklist for recipe changes, and nothing about
`packages/` or `config/` is authoritative here.

## What an engine change looks like

- **Start from the contract.** `docs/gsa-contract.md` is authoritative: the
  action-pass grammar (§B), selection (§C), the hidden seams (§D), the decision
  rows and rc contract (§E), outcome vocabularies (§F), exit codes (§G), the
  `format: 2` run record (§H), failure policy (§I), state layout (§J),
  concurrency (§K) and change control (§L). When a document and the contract
  disagree, the contract wins — fix the document, never the contract in
  passing.
- **Keep the seams where they are.** Install decisions are computed once as
  typed rows; the record is computed once and rendered three ways; resolution
  ladders name their rung; an early exit is a typed `Exit` behind one renderer.
  A change that adds a second decision site or a second counter is the change
  to reject in review.
- **Change hygiene.** Make precise, complete, surgical changes. A behavioural
  change to scheduling, install, state, fetch or signals ships with a fixture
  in the same change, and a change that retires a behaviour removes its dead
  code and its config in the same pass. Do not fix unrelated pre-existing
  issues in the same commit.
- **Fixtures are the test suite.** `tests/*.sh` are self-contained bash
  scripts, non-mutating and `$TMPDIR`-scoped, discovered recursively by
  `tests/run-all.sh`; a new fixture needs no runner edit. The run-record
  machine block (`format: 2`) is the assertion surface — assert on the record,
  not on prose. Stubs fail closed; oracle-shaped stubs stay inline in the
  fixture that gives them meaning.
- **Never weaken a verification.** Checksums, signatures, the PGO payload gate
  and the ABI gates are fail-closed by design. A green run that skipped the
  check is not a green run.

## Validation

Before submitting an engine change:

```sh
cargo test --workspace                       # the crate suite
bash tests/run-all.sh                        # the whole fixture battery
GSA_RECIPE_CHECKOUT=~/Projects/gsa-recipe \
  bash tests/run-all.sh                      # the real-recipe-tree sections
gsa -Ma                                      # audit lints are report-only; read the report
```

- `tests/run-all.sh` defaults to the installed `/usr/bin/gsa` — the contract's
  smoke-the-shipped-binary rule — and prints the binary and its owning package.
  `GSA_TEST_GSA_BIN=$PWD/target/release/gsa` is the explicit pre-install
  override and is reported as a deviation, never passed off as validated.
- Fixtures that read the real recipe tree take `GSA_RECIPE_CHECKOUT` and SKIP
  loudly when it is unset: the battery must be green both with and without a
  recipe checkout on disk.
- `cargo test --workspace` runs two supervisor timing tests that are load-flaky
  under full parallelism (pre-existing, measured at HEAD).
  `cargo test --workspace -- --test-threads=1` is the deterministic run.
- Never use a real rebuild as a syntax check.

## Committing

Never commit or push unprompted: a green battery is evidence, not consent.
PR comments go through `gh` only (never the GitHub MCP service, whose checks
table can be stale) and never before CI is green.
Each commit carries a descriptive body — what changed, why, and how it was
validated — and the trailer:

```
Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>
```

## Trust and privilege

The engine runs privileged, `makepkg` runs as the build user, and the engine
never prompts for privilege (`sudo -n` throughout). `SECURITY.md` is the trust
model; read it before changing anything that touches privilege, the state root
or a filesystem write.

## Documentation

`docs/JOURNAL.md` gets one dense dated line per action; the detail belongs in
the action export, not in the line. `AGENTS.md` holds the rules and pitfalls —
update it when an operational contract changes, and record the incident that
justified a new rule in the journal line. `docs/gsa-contract.md` changes are
amendments: they are dated, and the rule they encode is named.
