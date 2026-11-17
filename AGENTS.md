# AGENTS.md — engine mental model, rules and entry point

Last reviewed: 2026-11-17. This file is the repo's agent entry point: what the engine is, what to read, how to validate, the numbered rule index, the pitfall index and the open queue — whose bodies were retired to the maintainer's private warehouse on 2026-11-17. `docs/gsa-contract.md` is authoritative over every document here, including this one.

Durable project memory — measurements, campaign history, review verdicts, host facts — lives outside this public repository in the owner's private BRAIN store, whose `AGENTS.md` describes its layout. Keep host-specific detail out of tracked files.

## 0 · What this repository is

The `gsa` engine: a 13-crate Rust workspace (`crates/`), a fixture battery (`tests/`), diagnostics (`tools/`), and the contract and operating docs that describe them. It produces `/usr/bin/gsa`, packaged by `gsa-pm` in `ZhangDM-520/gsa-recipe`.

- **Engine/recipe split.** `gsa-recipe` owns `packages/`, `config/{topology,build-defaults,abi-exclusions}.conf`, `lib/` and recipe policy; none of that is restated here. The engine consumes the build-user recipe store (`gsa -Sy` hard-resets it) or a dev checkout via `GSA_CONF` `project` / `GSA_RECIPE_CHECKOUT` (read-only input).
- **Three runtime owners, never mixed.** Root-owned `/var/lib/gsa`; the build user's `~/.cache/gsa`; the build-user recipe store. `SRCDEST` belongs to `gsa.conf`, never an environment variable.
- **Five invariants.** (1) Mandatory selection and one topological order. (2) `-S` installs each package before its consumers through one `pacman -U --noconfirm --ask 4` executor. (3) Cone-stop failure policy: rc 4 default, `--fail-fast` 1, deferral 5, interrupt 130. (4) One `format: 2` record, three views projected from one `Progress` fold. (5) Typed `Exit::Refuse` + `RecordOwed` own exit codes and error notes.
- **Change shape.** One decision site per question. A change that adds a second decision site, a second counter or a second config ladder is the change to reject in review.

## 1 · Read before changing anything

| File | Role |
|---|---|
| `docs/gsa-contract.md` | **Authoritative.** Grammar (§B), selection (§C), seams (§D), decision rows/rc (§E), outcomes (§F), exit codes (§G), `format: 2` record (§H), failure policy (§I), state layout (§J), concurrency (§K), change control (§L) |
| `.github/copilot-instructions.md` | Build/test/lint commands, crate table, seam conventions, commit/PR policy |
| `CONTRIBUTING.md`, `SECURITY.md`, `CONTEXT.md` | Validation block and commit policy; trust and privilege model; vocabulary |
| `docs/architecture.md` | Crate split, scheduler invariants, deep seams, runtime state by owner |
| `docs/build-guide.md` | Operations: inspect, dry-run, build, skip/resume, privilege model, `GSA_*` surface, troubleshooting |
| `docs/portability.md` | Intensity profiles and formulas, `GSA_*` overrides, CPU/ISA policy |
| `docs/adr/` (0003–0006) | Run record, prefetch advisory, engine-owned makepkg conf, shipped-seam packaging; `0001`/`0002` live in `gsa-recipe` |
| `docs/plans/` | Frozen design provenance cited by path and section from code and contract — never edit |
| The maintainer's private warehouse | Rule, pitfall and queue bodies for §4–§6 below; not in this public repository |

## 2 · Commands

```sh
cargo build --release                                  # ./target/release/gsa
cargo test --workspace [-- --test-threads=1]           # 13 crates; serial run is deterministic
cargo clippy --workspace --all-targets                 # hold the HEAD warning count
tools/fmt.sh                                           # rustfmt check (`--write` applies; `cargo fmt` aborts on nightly)
bash tests/run-all.sh [filter|--serial|-j N]           # defaults to installed /usr/bin/gsa
GSA_TEST_GSA_BIN=$PWD/target/release/gsa bash tests/run-all.sh   # explicit pre-install deviation
GSA_RECIPE_CHECKOUT=~/Projects/gsa-recipe bash tests/run-all.sh  # real-tree sections; SKIP when unset
gsa --help                                             # authoritative spelling and ENV_INPUTS roster
```

- **No CI by decision.** The `CONTRIBUTING.md` validation block is the local gate, and deviations (`GSA_TEST_GSA_BIN`, a missing recipe checkout) are reported, never passed off as a full pass.
- **Never** use a real rebuild as a syntax check, or run the battery beside live `-S`/`-Ua`.
- **Dev smoke (read-only)**: `--help`, `-Qt`, `-Sl @git`, `-S --dry-run @git`, `-Ma`. Bare `gsa`/`--version` exit `2`; mutating verbs exit `3` without root (§B.10).

## 3 · Architecture

One-way crate DAG: `gsa-model` base → `gsa-{topo,recipe,graph,sched,build,install,fetch,state,qa,maint,abi}` → `gsa-cli` root. The crate table and navigation map live in `.github/copilot-instructions.md`.

The load-bearing seams: `gsa_install::decide` (typed plan rows, executed only), `gsa_model::read::{required,optional}` (refuse `Broken`), `gsa_model::config::{resolve,resolve_opt}` (the only root ladder), `gsa_model::makepkg_conf` + `build_layout_for_run` + `privilege::build_command` (the build-domain seams), `gsa_sched::progress::Progress` (the only state fold), `gsa_cli::exit` (the only exit renderer), `gsa_cli::style` (the only colour/width seam).

Topology is read only through `gsa -Qt`: nothing parses `config/` directly, and the strict loader validates every record, edge and sort on every invocation.

## 4 · Rules

Rule numbers preserve retired numbering: ~190 code comments and contract §L.3 cite them, so numbers are never renumbered, reused or invented. Borrowed numbers whose bodies live in `gsa-recipe`: `3, 4, 5→14, 7, 8, 14–17, 20′, 21, 24, 28–34, 36, 37, 39–43, 45–50, 52, 53, 55, 64, 70`. Dropped: `35, 38→63, 44, 51, 62→73, 64(SRCDEST)→73`. Full bodies: retired to the maintainer's private warehouse on 2026-11-17.

| # | Rule | Essence |
|---|---|---|
| 1 | Cross-shell `bash -c` | Fish traps: no `export`/`[[ ]]`, 1-indexed arrays, unmatched-glob errors, aliased `ls`/`grep`/`rm` |
| 2 | Agent git hardening | `GIT_CONFIG_COUNT=0` before bare-repo and makepkg VCS git calls |
| 6 | Toolchain identity | Build-tree reuse keyed by `<family>\|<compiler line>\|<config sha256>` |
| 9 | Dynamic `IgnorePkg` | Register accepted names before `pacman -U`; never delete a held `db.lck` |
| 10 | Journal and action exports | Retired to the private warehouse: one dense line per action, detail in the export, reset the buffer, delete a finished queue item |
| 11 | Immediate `-S` install | `pacman -U --noconfirm --ask 4` after each build; emit `SupEvent::Archive` |
| 12 | Mandatory selection | Bare `gsa` exits 2; expand to consumers; `--leaf` overrides; `<id>-snapshot` is an input alias |
| 13 | Coupled `abi=must` batches | Move LLVM/GPU and ABI-coupled members together; refuse solo provide-moving installs |
| 18 | Anchor auto-updates | Verify moved sources against official `.SRCINFO` via staged `updpkgsums` |
| 19 | Write-time state ownership | Chown the state root before open; quarantine unreadable state, never truncate |
| 20 | Single install decision seam | Typed rows computed once; refuse PGO leaks; test via `--install-decide` |
| 22 | Artifact-based reconciliation | One writer per mutable file; verify parallel work by re-running gates |
| 23 | `--ask 4` consent vs safety | Refuse `.PKGINFO` provide drift before force branches; tier-1 exposure is never excludable |
| 25 | ABI closure guard | Clauses b/c/c2/d/e/g/h/j: link truth, downstream waves, post-install NEEDED probe, derived fixtures |
| 26–27 | Roster latency and `epoch:pkgver` | Re-time `gsa -Sl` on roster jumps; match index/archives on full `epoch:pkgver` |
| 54, 56 | `depends` QA and `--noconfirm` | Gate linked libs via `--qa-check declared-deps`; `--noconfirm` on every spawn |
| 57 | Build, layout, config seams | `build_command`, `build_layout_for_run`, `makepkg_conf`; `LC_ALL=C` prose parsing |
| 58 | Living docs | Teach how to probe/verify; retired spellings only in contract §B.9 |
| 59 | Lane signal receipt | Never spawn with a pending signal; TERM mid-build, SIGKILL on `park-marker-unwritable` |
| 60 | Build domain vs engine state | Keep the store outside `--state-dir`; `ensure_store` migrates fatally |
| 61 | Installed `/usr/bin/gsa` battery | Validate the installed binary; `GSA_TEST_GSA_BIN` is a reported deviation |
| 63 | Volatile `-Sy` store | It hard-resets the store; copy rewrites out and verify sums independently |
| 65 | Hash inputs first | `sha256sum` + `ls --time-style=full-iso` before debugging parallel variance |
| 66 | Scoped link truth | Scope `provide_covers` by ELF class; map split pkgnames via `workspace_recipe_of_name` |
| 67 | Workspace precedence | `project` > cwd > store; real-tree checks read `GSA_RECIPE_CHECKOUT` and SKIP when unset |
| 68 | Dead `:=` subscriptions | Emit `abi-stale-record … dead-record` and fail closed on `installed: None` |
| 69 | Atomic heal batches | Provider + pinning consumers in one `pacman -U`; probe the matrix read-only first |
| 71 | Unreadable ≠ absent | `read::{required,optional}`; never `if let Ok` / `unwrap_or_default` |
| 72 | Single `Progress` fold | Every view projects `Progress`; no parallel counters |
| 73 | Single `config::resolve` ladder | Build root, state root, store and `SRCDEST` resolve with provenance labels |
| 74 | Typed `Exit` renderer | `Err(Exit::...)` via `gsa_cli::exit`; `RecordOwed::Yes` prints nothing extra |
| 75 | Single `gsa-cli::style` seam | Resolve colour/width once; paint after `truncate_{middle,end}` |

## 5 · Pitfalls

One line per mechanism; the full explanations and probe commands were retired to the maintainer's private warehouse (2026-11-17).

**Sources, refs, freshness** — an unreadable `SRCDEST` mirror is `mirror-unusable`, never a bad ref; snapshot pins walk `--first-parent` mainline only; `scheme_vcs` strips `+`; checksums match contiguous same-algorithm runs with `name::url` overrides; mirror VCS with `git clone --bare`; a `?signed` failure is usually injected `GIT_CONFIG_*` or a full `$TMPDIR`; VCS `--skip` verifies every declared ref; freshness reads `$srcdir` first and never pins `pkgrel >= N`.

**Store, workspace, builders** — `-Sy` refreshes only from a neutral cwd; `makepkg --nobuild` dirties trees; keep scratch out of the repo and `/tmp`; sync `config/` alongside packages; update moved `SRCDEST` `alternates`; resolve absolute child paths; re-assert `GSA_LANE_*` last in a `--config` composite and pass the same `--config` to `--verifysource`; pin `GSA_RECIPES_DIR` in every fixture.

**Install, ABI, record** — a new `--print-*` seam owes a `gsa-pm` `install` line; zero expected archives return `nothing-built` and globs must exclude `.sig` and prefix twins; `--leaf` still expands `:=` mismatch waves; map `DT_NEEDED` by exact `host ∪ shipped` path; stop the GUI session before a major `libLLVM*` move; ALPM `NeedsTargets` hooks need `AbortOnFail`; index `ldconfig -p` + `binpkg.jsonl` once on failure; key `kv.jsonl` rows per `(recipe_id, output)`; a torn tail is repaired by the printed `truncate -s` offset, never automatically.

**Signals, lanes, runs** — one TERM per lane + 30 s grace + one SIGKILL; a TERM storm leaves `db.lck` and a stripped local DB (repair via `--local-db-check`); launch detached from terminal scopes; concurrent `pacman -U` swaps can transiently break sibling loaders.

**Build cache and disk** — probe mounts with `mkdir -p` + `df`, never `mountpoint -q`; keep `download_patterns` equal to `.gitignore`; resolve in-flight keep-paths from `/proc/<pid>/cwd`; never prune a build dir with pending consumers.

**Fixtures** — capture `output::squash` needles from real output; return an empty string for a no-op tick; match stub argv verbatim; wait on events/counts; stay out of live runs; use `find ... -prune` for tree scans.

## 6 · Queued

Full specs and campaign evidence were retired to the maintainer's private warehouse (2026-11-17); delete an item once it lands.

1. **Per-package resource measurement (sequence first)** — root pre-`setpriv` cgroup `memory.stat` `anon` sampling into `metrics/pkg.jsonl`, consumed as a downward-only bytes-per-job `-j` clamp. Blocked on a written plan and the history-retention decision.
2. **Adaptive per-lane job count** — spawn-time `-j` widening when the ready set is small; a global jobserver was rejected (no GNU make protocol in ninja/cargo). Blocked on item 1.
3. **`core`-alone boolean for the heterogeneous group** — `core`/`build-tools` is 50% of the roster at a 17 s median, while `gtk4` hazards are unmodeled; simulation favours keeping solo plus documenting the rationale. Blocked on an owner decision.
4. **Install vs concurrent build race (UNGUARDED)** — `pacman -U` runs while sibling lanes compile (13 clean passes, weak negative). Fix belongs in the supervisor loop; blocked on a plan and the quiesce-vs-pause decision.
5. **Snapshot pins in `@core`/`@build-tools`** — engine W0/W5 landed; 82 of 233 VCS records still move and the work is recipe data in `gsa-recipe` plus an owner rebuild.

## 7 · Memory and records

- **In-repo:** nothing — the action history, the per-action exports and the scratchpad were retired to the maintainer's private warehouse (2026-11-17); `tests/memory-layout.sh` gates that the bookkeeping paths stay absent and `AGENTS.md` exists.
- **Out-of-repo:** durable memory (measurements, campaign history, review verdicts, host facts) lives in the owner's private store. This repository is public: no host paths, private timings or credentials in tracked files.
- **Doc edits:** a behaviour change updates the contract (dated amendment), the guide that teaches it, and the rule or pitfall it encodes — in the same pass.
