# Copilot instructions — gsa engine

`gsa` builds and installs a curated Arch Linux package set: it reads declarative topology, resolves build order, builds and installs each package before its consumers compile, and emits a machine-readable `format: 2` run record. **This repository is the engine only**: `packages/`, `config/` and recipe policy live in `ZhangDM-520/gsa-recipe`, consumed through the build-user store or a dev checkout (`project`, `GSA_RECIPE_CHECKOUT`).

Read before edits: `docs/gsa-contract.md` (**authoritative interface — wins over every other document**), `AGENTS.md` (rules, pitfalls, queue, architecture invariants), `CONTRIBUTING.md` (validation block, commit policy), `SECURITY.md` (trust and privilege), `CONTEXT.md` (vocabulary), `docs/architecture.md`, `docs/build-guide.md`, `docs/portability.md`.

## Build, test, lint

```sh
cargo build --release                                  # ./target/release/gsa
cargo test --workspace [-- --test-threads=1]           # 13 crates; serial run is deterministic (2 supervisor tests are load-flaky)
cargo test -p <crate> [--test <file>|<unit_path>]      # e.g. -p gsa-cli --test preflight_contract
cargo clippy --workspace --all-targets                 # hold the HEAD warning count; never sweep unrelated warnings
tools/fmt.sh                                           # rustfmt check (`--write` applies; `cargo fmt` aborts on nightly)
bash tests/run-all.sh [filter|--serial|-j N]           # fixture battery; defaults to installed /usr/bin/gsa
GSA_TEST_GSA_BIN=$PWD/target/release/gsa bash tests/run-all.sh   # explicit pre-install deviation (report it)
GSA_RECIPE_CHECKOUT=~/Projects/gsa-recipe bash tests/run-all.sh  # real-tree sections; SKIP loudly when unset
gsa --help                                             # authoritative spelling and ENV_INPUTS roster
```

- **No CI by decision**: the `CONTRIBUTING.md` block is the gate. Say which items you ran; report a deviation instead of presenting it as a full pass. Never use a real rebuild as a syntax check, and never run the battery beside live `-S`/`-Ua`.
- **Dev smoke (read-only)**: `--help`, `-Qt`, `-Sl @git`, `-S --dry-run @git`, `-Ma`. Bare `gsa` and `--version` exit `2`; mutating verbs require root and exit `3` otherwise (contract §B.10).
- **Perf (`tools/perf/`)**: measurement only, never a gate. Report median + IQR, pair before/after runs, and prefer load-invariant counts (instructions, syscalls, allocations) to wall time.

## Architecture and navigation

One-way crate DAG, `gsa-model` base → domain crates → `gsa-cli` root:

| Crate | Owns |
|---|---|
| `gsa-model` | core types, `format: 2` record/rendering, `config::{resolve,resolve_opt}`, `read::{required,optional}`, `build_layout_for_run`, `checkout_roots`, `privilege::build_command`, `makepkg_conf`, `mirror::mirror_state` |
| `gsa-topo` / `gsa-recipe` | strict `config/` loaders; `.SRCINFO` + read-only `PKGBUILD` scan (no shell eval); version sync, VCS freshness, checksums, toolchain identity |
| `gsa-graph` / `gsa-sched` | consumer expansion, topo sort, coupled batches; lane supervisor, intensity budgets, failure policy, signals, lock, `progress::Progress` |
| `gsa-build` / `gsa-install` / `gsa-fetch` | `makepkg` child contract + `PACMAN` shim; the single `decide()` seam, PGO/ABI gates, `pacman -U`; `--verifysource` prefetch |
| `gsa-state` / `gsa-qa` / `gsa-maint` / `gsa-abi` / `gsa-cli` | side-car state and store; `-Ma`/`--qa-check`; `-M*`; ABI tokens, waves, ELF view; `args.rs`, `select.rs`, `exit.rs`, `help.rs`, `style.rs` |

## Conventions (index; bodies in `AGENTS.md` §4)

- **One decision site per question.** Install decisions are typed rows computed once; the record is computed once and rendered three ways; a second decision site or a second counter is the change to reject in review.
- **Unreadable is not absent.** Use `gsa_model::read::{required,optional}`; never `if let Ok` / `unwrap_or_default`.
- **One ladder.** Build root, state root, store and `SRCDEST` resolve through `config::{resolve,resolve_opt}`, and the rung is named.
- **One renderer.** Steps return `Err(Exit::...)`; `RecordOwed::Yes` prints nothing extra.
- **One state fold.** Every view projects `gsa_sched::progress::Progress`.
- **One colour/width seam.** Resolve once in `gsa-cli::style`, paint after `truncate_{middle,end}`.
- **New flags and record fields** (contract §L.1–§L.4, §D.1): wire `gsa --help`, the continuation table (`mirrored`/`not-mirrored`), a fixture, and bump `format` plus parser fixtures on record changes.
- **Fixtures are the test suite.** Assert on `--install-decide`, `--qa-check`, `--build-identity`, `--local-db-check`, `--stale-lock-check` and `rr2_*` rows; prose pins live only in `tests/dashboard.sh` and `tests/rendering.sh`. Falsify a new check red-first, and ship a behaviour change with its fixture and its dead-code removal.
- **Fail closed.** Never weaken checksums, PGP checks, the PGO payload gate or the ABI gates; never delete a held `db.lck`.
- **Citations.** `crates/` cites `docs/gsa-contract.md` (§A–§L) and `AGENTS.md` §4 rule numbers. Gaps point at `gsa-recipe`; never renumber, reuse or invent a body. `docs/plans/` is frozen provenance cited by path and section.
- **Docs follow behaviour.** Update the guide that teaches a changed spelling; retired spellings live only in contract §B.9. `docs/architecture.md` owns the crate split; `docs/portability.md` owns intensity and `GSA_*` overrides.

## Records and memory

- In-repo history: none — the action history was retired to the maintainer's private warehouse (2026-11-17). `tests/memory-layout.sh` gates that the bookkeeping paths stay absent and `AGENTS.md` exists.
- Durable project memory (measurements, campaign history, host facts, review verdicts) lives **outside** this repository in the owner's private store. This repository is public: keep host paths, timings and private detail out of it, and put only what the contract, docs or rules need in tracked files.

## Git and PRs

Never commit or push unprompted: a green battery is evidence, not consent. PRs use `.github/pull_request_template.md` through `gh` (never the GitHub MCP service, whose checks table can be stale). Each commit carries a descriptive body — what changed, why, how validated — and ends with exactly:

```
Assisted-by: LLM (human-reviewed)
Signed-off-by: <the committer's configured git identity>
```

No `Co-authored-by: Copilot`: `Assisted-by` already discloses the assistant.
