# Copilot instructions — Gentoo_Style_Arch (engine repository)

`gsa` is the build engine for a curated Arch Linux package set: it reads
declarative topology, resolves the build order, builds each package and
installs it before its consumers compile, and accounts for the whole run as one
machine-readable record.

**This repository is the engine only.** The recipes, `PKGBUILD` policy, `config/`
topology and build order live in
[`ZhangDM-520/gsa-recipe`](https://github.com/ZhangDM-520/gsa-recipe). Nothing
about `packages/` or `config/` is authoritative here, and the engine never
carries a recipe workspace. The engine consumes that repository through the
canonical store (`gsa -Sy` refreshes it); a dev checkout is read-only input
selected by `gsa.conf`'s `project` key or `GSA_RECIPE_CHECKOUT`.

`AGENTS.md` at the repo root is this repository's memory — boundary, commands,
crate split, rules, pitfalls, shell hazards. `docs/gsa-contract.md` is the
**authoritative interface**: when any document disagrees with it, the contract
wins and the document is what gets fixed. Read `AGENTS.md` first, then the tail
of `docs/JOURNAL.md` for what just changed. Rules and pitfalls are not restated
here; a rule copied into a second file drifts in one of them.

## Build, test and lint

```sh
cargo build --release                    # ./target/release/gsa
cargo test --workspace                   # all 13 crates
cargo test -p gsa-sched                  # one crate
cargo test -p gsa-sched budget::tests::budget_formulas_follow_portability_doc
cargo test --workspace -- --test-threads=1   # deterministic; see flake note
cargo clippy
```

`cargo test --workspace` runs two supervisor timing tests that are load-flaky
under full parallelism. That flake is pre-existing and measured at HEAD — never
a regression to chase, and `--test-threads=1` is the deterministic run.

### The fixture battery

`tests/` is the real test suite. Each `tests/*.sh` is a self-contained,
non-mutating, `$TMPDIR`-scoped bash script that synthesizes a workspace and PATH
stubs; they are discovered recursively and run concurrently, so a new fixture
needs no runner edit.

```sh
bash tests/run-all.sh                    # everything, in parallel
bash tests/run-all.sh abi                # substring filter (a no-match exits 2)
bash tests/run-all.sh --serial           # one at a time, for a flaky fixture
bash tests/run-all.sh -j 4               # cap concurrency
bash tests/<name>.sh                     # a single fixture, standalone
GSA_TEST_GSA_BIN=$PWD/target/release/gsa bash tests/run-all.sh   # pre-install
GSA_RECIPE_CHECKOUT=~/Projects/gsa-recipe bash tests/run-all.sh # real-tree sections
gsa -Ma                                  # audit lints: report-only, read the report
```

The battery defaults to the **installed** `/usr/bin/gsa` (contract §L.10) and
prints the binary and its owning package. `GSA_TEST_GSA_BIN` is an explicit
pre-install deviation — report it as such, never pass it off as validated. A
stale `/usr/bin/gsa` makes the battery silently test old code, which surfaces
as phantom "fixture failures"; that is the first thing to check. Fixtures that
need the real recipe tree read `GSA_RECIPE_CHECKOUT` and SKIP loudly (rc 0)
when it is unset, so the battery must be green both with and without one.

Never use a real rebuild as a syntax check, and never run the battery beside a
live `-S`/`-Ua` run (install preflights read the real `db.lck`).

## Architecture

Thirteen crates under `crates/`, one binary, with a strict dependency direction:
model → loaders → graph/abi → scheduling → effects → CLI.

| Crate | Owns |
| --- | --- |
| `gsa-model` | Core types, the `format: 2` run record and its machine rendering; `config::resolve`/`resolve_opt` ladders; `read::{required,optional}`; `build_layout_for_run`, `checkout_roots`, `privilege::build_command` |
| `gsa-topo` | Strict loaders for the recipe repo's `config/` files and user sets; the group roster and `store_format` gate |
| `gsa-recipe` | `.SRCINFO` parsing, strict read-only `PKGBUILD` scan (never shell evaluation), source classification, version sync, VCS freshness, checksum anchoring, toolchain identity |
| `gsa-graph` | Consumer expansion (reverse closure), the one topological sort with cycle refusal, coupled batches, `app-cluster` |
| `gsa-sched` | Lane supervisor: intensity budgets, the typed lane-result codec, dispatch state machine (core-solo, `build-tools` band, failure policy), signals, run lock, `progress::Progress` |
| `gsa-build` | makepkg orchestration: lane child entry, the argv/env contract, the `PACMAN` shim, prune strength 1 |
| `gsa-install` | The one install decision seam (`decide`), the fail-closed gates, the `pacman -U --noconfirm --ask 4` executor, IgnorePkg registration |
| `gsa-fetch` | Fetch-ahead through `makepkg --verifysource`; the bounded prefetch window |
| `gsa-state` | Side-car state under the state root, the write-time ownership gate, the canonical recipe store |
| `gsa-qa` | Report-only audit lints (`-Ma`), install-refusing checks, the hidden `--qa-check` seam |
| `gsa-maint` | The `-M` surface: audit/doctor, IgnorePkg repair, prune, sets/world, run history |
| `gsa-abi` | Derived ABI tokens, `:=` subscription records, rebuild waves, the installed-ELF view, refusal rows |
| `gsa-cli` | The binary: argv grammar (§B), selection (§C), renderings, `exit` (the one rc renderer), `help` (the one environment roster) |

Three owners of runtime state, never mixed: the root-owned state root
(`index/`, `abi/`, `runs/`, `locks/`, …), the build user's cache
(`build/`, `pkg/`, `pkgs/`), and the build-user-owned recipe store. `SRCDEST`
is the engine's too (a `srcdest` gsa.conf key, built-in `~/.gsa-src`) — there
is no environment rung, so never export it.

The engine also owns **makepkg's configuration**: `/etc/gsa/{gsa.conf,
gcc-makepkg.conf, clang-makepkg.conf}` plus a `~/.config/gsa/` clone plus
built-in bodies, rendered into one `--config` composite per compiler family
(`gsa_model::makepkg_conf`). The host's `makepkg.conf` is never read; add a
flag by editing the site body, and add package-specific switches by appending
`CFLAGS+=" …"` in the recipe.

### Invariants a change must not break

1. Selection is mandatory (a bare `gsa` is a usage error, rc 2); plan, listing,
   record and range order are the same single topological order.
2. `-S` installs each package before its consumers compile; a refused install
   aborts the run.
3. Cone-stop is the default failure policy (rc 4); `--fail-fast` is 1,
   deferral-only 5, interrupt 130.
4. One record, three renderings: the dashboard is a `Progress` projection of the
   run record, and prose plus machine block are views. No rendering re-derives
   state.
5. A typed refusal owes a record (`Exit::Refuse` + `RecordOwed`); no step
   invents an rc.

## Key conventions

- **One seam per decision, everything else a view.** Install decisions are
  typed rows computed once (`install`/`skip`/`refuse`/`noop`/`parked`);
  rendering and execution never re-decide. A change adding a second decision
  site or a second counter is the change to reject in review.
- **An unreadable file is not an absent one.** Never collapse the two with
  `if let Ok` or `unwrap_or_default` — that stands every gate down. Use
  `gsa_model::read::{required, optional}` and refuse on `Broken`.
- **One resolution ladder per setting, and it names its rung.** Build root,
  state root, recipe store and `SRCDEST` all resolve through
  `config::{resolve, resolve_opt}`. Never write a second
  `if let Some(env) … if let Some(cfg)` chain or copy a default.
- **An early exit is a typed `Exit`.** `gsa_cli::exit` owns the exit-code
  mapping; steps return `Err(Exit::Usage(..))` / `Err(Exit::Refuse(..))`, never
  `return 2`.
- **The run record is the assertion surface.** Assert on the `format: 2`
  machine block via `tests/lib/rr-v2.bash`, not on prose. Prose pins live in
  exactly one place (`tests/dashboard.sh`'s rendering section).
- **Fixtures.** Assertions use `vgrep VALUE ARG…` or `grep … < <(PRODUCER)`,
  never `printf … | grep -q` (pipefail SIGPIPE). Sibling subjects merge into
  one file as `( subshell )` sections. Stub knobs are `GSA_FAKE_*`, read by the
  stub only — never an engine input. `tests/lib/` helpers take `.bash` so
  discovery cannot match them; `run_builder` always returns 0, so assert
  `$FIXTURE_RC`. Privilege assertions belong only in `tests/gsa-privilege.sh`.
- **A behavioural change to scheduling, install, state, fetch or signals ships
  with a fixture in the same change**, and retires its dead code and config in
  the same pass.
- **Checksums, signatures, the PGO payload gate and the ABI gates are
  fail-closed.** A green run that skipped the check is not a green run.
- **Shell boundary.** The login shell is fish, but agent tool calls run in
  bash: wrap ad-hoc one-liners in `bash -c '…'`. Agent shells inject git config
  that breaks bare repos and makepkg VCS operations — prefix those with
  `GIT_CONFIG_COUNT=0`. `rm` is a trash wrapper in fish; use `command rm`.
- **Never commit or push unprompted.** A green battery is evidence, not
  consent. PR comments go through `gh`, never the GitHub MCP service, and
  never before CI is green. Trailers:
  `Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>`.

## Where the truth lives

| Document | Answers |
| --- | --- |
| `docs/gsa-contract.md` | **Authoritative.** Grammar, selection, hidden seams, decision rows, exit codes, run record, failure policy, state layout, concurrency, change control |
| `AGENTS.md` | Rules, pitfalls, queue, shell hazards, fixture conventions |
| `docs/architecture.md` | Crate split, scheduler invariants, deep seams, runtime state by owner |
| `docs/build-guide.md` | Operations: families, inspect/dry-run/build, installation, environment surface, troubleshooting |
| `docs/portability.md` | Intensity profiles and formulas, `GSA_*` overrides, CPU/ISA policy |
| `docs/gsa-fixture-migration.md` | Per-fixture inventory: what each fixture pins |
| `CONTRIBUTING.md` | Change hygiene, the validation block, the commit policy |
| `SECURITY.md` | Trust model, privilege boundary, what must never be committed |
| `docs/JOURNAL.md` | The chronological log — read the tail, grep by date |
