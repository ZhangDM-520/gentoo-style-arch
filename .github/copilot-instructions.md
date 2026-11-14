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
cargo test -p gsa-cli --test preflight_contract   # one integration test file
cargo test --workspace -- --test-threads=1   # deterministic; see flake note
cargo clippy --workspace --all-targets       # must be clean
tools/fmt.sh                                 # rustfmt check; --write to apply
```

Ten crates carry a `crates/<crate>/tests/` integration directory in addition to
in-crate `#[cfg(test)]` modules, so `--test <file>` selects one integration
file and a bare `budget::tests::…`-style path selects one unit test. The crate
name is `gsa-sched`, the binary name is `gsa`, and they differ: `-p gsa-cli`
builds the binary package.

`cargo test --workspace` runs two supervisor timing tests that are load-flaky
under full parallelism. That flake is pre-existing and measured at HEAD — never
a regression to chase, and `--test-threads=1` is the deterministic run.

There is **no `rust-toolchain` file**: the toolchain is the distro `rust-git`
nightly (`rustc 1.101.0-nightly` at the time of writing), and that is why
`cargo fmt` aborts and `tools/fmt.sh` exists. Never add a toolchain file to work
around it, and never rely on a specific nightly feature without checking the
installed one.

**There is no CI: the validation block in `CONTRIBUTING.md` is the gate.** A
change is validated only when those commands have been run locally and their
results reported. Formatting uses `tools/fmt.sh`, not `cargo fmt`: `cargo-fmt`
aborts at startup on the nightly this repository builds with. The binary ships
as `/usr/bin/gsa` through the `gsa-pm` recipe in the recipe repository.

### Running the dev binary

```sh
./target/release/gsa --help            # the authoritative command/env roster
./target/release/gsa -Qt | wc -l       # roster size; the fastest read-only smoke
./target/release/gsa -Sl @git          # the set, in build order — read-only
./target/release/gsa -S --dry-run @git # plan and decision rows, no mutation
```

`gsa` has **no `--version` spelling** (contract §B): identity is the resolved
path, the digest of its bytes and the owning package, which is what
`tools/perf/lib.sh` records. `--version` is rc 2 like any unknown flag, as is a
bare `gsa`. Read-only (any user, never writes state): every `-Q*`, `-Sl`,
`-Bl`, `--dry-run`, `-Ma`, and the *report* forms of the `-M` verbs. Mutating
(root required, early refusal rc 3 otherwise): `-S`, `-B`, `-U`, `-Sw`, `-Sy`,
`-Su`, every `-Mc*`, and the write flags on `-M` verbs (`-Ml --keep`,
`-Mh --prune`, `-Mi --backfill`, …). The class table is contract §B.10.

The engine needs a recipe workspace: a checkout selected by `gsa.conf`'s
`project` key, or hermetically by `GSA_CONF`/`GSA_CONF_DIR` and
`GSA_RECIPE_CHECKOUT`. Inspect with `--dry-run`/`-Sl`; a real `-S` mutates the
host (root-owned state root, pacman transaction), so it is never an agent's
first reach. `packages` is excluded from the cargo workspace in `Cargo.toml`,
so an in-tree recipe build tree cannot break `cargo`.

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
RUN_ALL_JOBS=2 bash tests/run-all.sh     # same cap, via the env twin
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
live `-S`/`-Ua` run (install preflights read the real `db.lck`). Deployment ends
with validating what was installed: ship → `sudo gsa -Sy` →
`sudo gsa -S gsa-pm` → run the battery, which exercises `/usr/bin/gsa`.

A fixture edit is checked in this order: `bash -n tests/<name>.sh`, then the
fixture standalone, then `bash tests/run-all.sh <name>`, then the whole
battery. `GSA_TEST_ENGINE=fish` makes `run_engine` drive the frozen fish-era
oracle in `tests/assets/` for a differential section; leave it unset otherwise.

`tests/lib/rr-v2.bash` provides `run_engine` and the strict `rr2_*` record
parser; `tests/lib/fixture-lib.bash` retains the fish-era synthesis helpers
(`make_workspace`, `add_package`, `stub_*`, `run_builder`) during the staged
migration. `tests/assets/` is the frozen fish-era engine kept as a differential
oracle — reference material, never a fixture.

## Architecture

Thirteen crates under `crates/`, one binary. Dependencies are one-way:
`gsa-model` is the base, no crate depends on `gsa-cli`, and `gsa-cli` is the
composition root that depends on all the others. `tools/` holds the ABI
pre-transaction checker and its pacman hook, installed by `gsa-pm`.

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

### Navigating the code

Start at the composition root and follow the one-way edges down; no crate
depends on `gsa-cli`. Entry is `crates/gsa-cli/src/main.rs` → `lib.rs::run`
(dispatch) → `args.rs::parse` (the §B grammar). From there every decision
surface is a named module, not a search:

| Question | File |
| --- | --- |
| How is this argv parsed? | `gsa-cli/src/args.rs`, grammar in `docs/gsa-contract.md` §B |
| What does this reference select? | `gsa-cli/src/select.rs` (§C) |
| Which exit code does this path produce? | `gsa-cli/src/exit.rs` (§G) — the only rc renderer |
| Which env vars/commands exist? | `gsa-cli/src/help.rs` (`ENV_INPUTS`) |
| Why is this cell coloured/wide? | `gsa-cli/src/style.rs`, `render.rs` (§L.9) |
| Which row vocabulary is this? | `gsa-model` (record types) + `gsa-cli/src/output.rs::kv_line` (§L.9) |
| Should this install happen? | `gsa-install/src/lib.rs::decide` (§E) — the only seam |
| Why did this lane stop? | `gsa-sched/src/machine.rs` (dispatch), `signals.rs` |
| What is the run's state? | `gsa-sched/src/progress.rs` (the one projection) |
| Which state file? | `gsa-state`; layout in `docs/gsa-contract.md` §J |

Add a module, not a branch: the crates are separated so that a new behaviour
lands in the crate that owns the noun (a new gate in `gsa-install::gates`, a
new lint in `gsa-qa`, a new `-M` verb in `gsa-maint`), and `gsa-cli` only
parses, selects, renders and exits.

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
- **A new flag lands in three places in one change** (contract §L.1): `gsa
  --help` (the authoritative roster), the continuation flag-rule table as
  `mirrored` or `not-mirrored`, and at least one fixture. A flag absent from
  `--help` does not exist. A row/record grammar change bumps `format` and
  updates the parser fixture in the same change (§L.2).
- **Falsify every new check red-first** (contract §L.4): break one input in a
  scratch copy and watch the check fail naming what broke; a check that cannot
  fail is deleted, not kept green.
- **Privilege is pacman-shaped and nothing prompts** (`SECURITY.md`): reads run
  as any user, mutations require root, `makepkg` and recipe code drop to the
  build user via `setpriv`, and escalation is `sudo -n` only. Source
  verification is never weakened — `--skipchecksums`, `--skippgpcheck` and
  `--skipinteg` are rejected everywhere.
- **Performance claims owe numbers** (`tools/perf/`, a measurement tool and
  never a gate): `cargo build --profile profiling`, then
  `tools/perf/bench.sh --runs 7 -- gsa -Q` (median + IQR noise floor),
  `tools/perf/probe.sh -- gsa -Q` (syscalls), `tools/perf/matrix.sh`,
  `tools/perf/stub-run.sh --packages 32`. A delta smaller than the IQR is *not
  measured*, not faster; quote instruction/syscall counts as the primary
  evidence on this hybrid-CPU host.
- **Keep working state in-repo** (`AGENTS.md` protocol): dense output to
  `.logs/scratchpad.md`, one dense dated line per action in `docs/JOURNAL.md`,
  detail in `.logs/action-<date>-<task>.md`. Never write memory files in
  `$HOME`; `.logs/` is git-excluded apart from the scratchpad, so an action
  export is never staged.
- **The docs are layered, and each layer has one job.** `AGENTS.md` holds the
  rule text and one line per pitfall mechanism; incidents, dates and
  measurements go in `docs/JOURNAL.md`; `docs/adr/` holds the *why* behind a
  rule; `docs/plans/` are frozen provenance records cited by section and must
  never be edited to change behaviour (the contract or a new ADR is the place).
  Do not restate a rule in a second file — a copied rule drifts in one of them.
  `AGENTS.md` §6 is a queue: a finished item is deleted, never ticked.
- **A doc that teaches how to check, never the shape of a retired era.** No
  live doc asserts a volatile fact; it names the command that prints it
  (`gsa -Sl`, `gsa --help`, `gsa -Qt`). Retired spellings survive only in the
  contract's migration table (§B.9).
- **The scratchpad is reset, not appended forever.** After an action, write the
  export, append exactly one `docs/JOURNAL.md` line, then reset
  `.logs/scratchpad.md` to the stub. It is the only tracked file under
  `.logs/`.
- **The run record is the assertion surface.** Assert on the `format: 2`
  machine block via `tests/lib/rr-v2.bash`, not on prose. Prose pins live in
  exactly one place (`tests/dashboard.sh`'s rendering section).
- **Hidden seams are the fixture interface, not prose.** The `--`-prefixed
  seams (contract §D.1's roster) answer in typed rows or stable keywords:
  `--install-decide` prints the decision rows, `--qa-check <name>` runs one
  lint, `--build-identity <gcc|clang>` prints the toolchain marker,
  `--local-db-check`/`--stale-lock-check` are the production probes without a
  run. Assert on those rather than scraped messages, and never add a debug
  knob outside that roster.
- **Fixtures.** Assertions use `vgrep VALUE ARG…` or `grep … < <(PRODUCER)`,
  never `printf … | grep -q` (pipefail SIGPIPE). Sibling subjects merge into
  one file as `( subshell )` sections. Stub knobs are `GSA_FAKE_*`, read by the
  stub only — never an engine input. `tests/lib/` helpers take `.bash` so
  discovery cannot match them; `run_builder` always returns 0, so assert
  `$FIXTURE_RC`. Privilege assertions belong only in `tests/gsa-privilege.sh`.
  The loader validates every record, edge and the whole topological sort on
  every invocation, so `make_workspace` must produce a complete workspace and
  `add_package`/`set_topology_record` are the only writers for records.
- **Scale pins are probe/CALL counts and event waits, never wall-clock.**
  Wait on a marker or a log line; a `sleep` races the pre-dispatch phase under
  parallelism. `stub_sleep` is the capped clock for SUT-side waits, installed
  only where no long sleep is a lease or a measured duration.
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
  never before the `CONTRIBUTING.md` validation block is green. A PR body
  follows `.github/pull_request_template.md` and ticks only the commands
  actually run — each with its result, deviations named as deviations.
  Every commit ends with the two trailers `CONTRIBUTING.md` § Committing
  specifies — `Assisted-by: LLM (human-reviewed)` then `Signed-off-by` — and
  never a `Co-authored-by: Copilot` line, which duplicates the disclosure.

## Where the truth lives

| Document | Answers |
| --- | --- |
| `docs/gsa-contract.md` | **Authoritative.** Grammar, selection, hidden seams, decision rows, exit codes, run record, failure policy, state layout, concurrency, change control |
| `AGENTS.md` | Rules, pitfalls, queue, shell hazards, fixture conventions |
| `docs/architecture.md` | Crate split, scheduler invariants, deep seams, runtime state by owner |
| `docs/build-guide.md` | Operations: families, inspect/dry-run/build, installation, environment surface, troubleshooting |
| `docs/portability.md` | Intensity profiles and formulas, `GSA_*` overrides, CPU/ISA policy |
| `docs/gsa-fixture-migration.md` | Per-fixture inventory: what each fixture pins |
| `CONTEXT.md` | Vocabulary: recipe, topology record, build-order edge, lane, run record, decision row |
| `CONTRIBUTING.md` | Change hygiene, the validation block, the commit policy |
| `SECURITY.md` | Trust model, privilege boundary, what must never be committed |
| `docs/adr/` | Decision records (`README.md` indexes them; numbering starts at 0003 — 0001/0002 moved to the recipe repo): the run record, the prefetch advisory, engine-owned makepkg config, and why a `--print-*` seam owes a shipped file |
| `docs/plans/` | Frozen design records (`README.md` is the index) cited by section from code and the contract — provenance, never specification; they carry ~148 citation lines, so never delete one to "clean up" |
| `docs/JOURNAL.md` | The chronological log — read the tail, grep by date |
| `crates/README.md` | **Stale — do not trust it.** It still describes phase 1 and lists eight crates as "not yet in this workspace", and it recommends `cargo fmt --check`, which is the command that aborts. `AGENTS.md` §3 and the table above are current. |
