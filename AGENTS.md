# AGENTS.md — the `gsa` engine

`gsa` builds and installs a curated Arch Linux package set: it reads a declarative topology, resolves the build order, builds each package and installs it before its consumers compile, and keeps the run accountable as one `format: 2` record. This repository is the **engine only** — a thirteen-crate Rust workspace producing `/usr/bin/gsa`, a `$TMPDIR` fixture battery, diagnostics, and the contract and operating docs. `packages/`, `config/` and recipe policy live in `ZhangDM-520/gsa-recipe`, whose `gsa-pm` recipe packages this binary.

Operational detail stays where it belongs and is not restated here: build, test, lint and dev-smoke commands, the crate map, seam conventions and hazards are `.github/copilot-instructions.md`; the validation block and commit policy are `CONTRIBUTING.md`; the trust and privilege model is `SECURITY.md`; the domain vocabulary is `CONTEXT.md`; the authoritative interface is `docs/gsa-contract.md`; the crate split and scheduler invariants are `docs/architecture.md`.

## Mental model

- **Engine/recipe split.** The recipe repository owns `packages/`, `config/{topology,build-defaults,abi-exclusions}.conf`, `lib/` and recipe policy; none of it is restated here. The engine consumes the build-user recipe store (`gsa -Sy` hard-resets it) or a dev checkout via `GSA_CONF` `project` / `GSA_RECIPE_CHECKOUT` (read-only input).
- **Three runtime owners, never mixed.** Root-owned `/var/lib/gsa`; the build user's `~/.cache/gsa`; the build-user recipe store. `SRCDEST` belongs to `gsa.conf`, never an environment variable.
- **Five invariants.** (1) Mandatory selection and one topological order. (2) `-S` installs each package before its consumers through one `pacman -U --noconfirm --ask 4` executor. (3) Cone-stop failure policy: rc 4 default, `--fail-fast` 1, deferral 5, interrupt 130. (4) One `format: 2` record, three views projected from one `Progress` fold. (5) Typed `Exit::Refuse` + `RecordOwed` own exit codes and error notes.
- **Change shape.** One decision site per question. A change that adds a second decision site, a second counter or a second config ladder is the change to reject in review.

## How to work here

1. Read the document the task touches before editing it: `docs/gsa-contract.md` first (**authoritative — it wins over every other document, including this one**), then `docs/architecture.md`, `docs/build-guide.md` or `docs/portability.md` as the area demands.
2. Reproduce the defect before fixing it. Judge by artifacts and read output, never by exit codes; falsify every new check red-first, and never weaken an assertion to reach green.
3. Verify with the narrowest command that covers the change, then the `CONTRIBUTING.md` block. There is no CI: that block is the gate, and a deviation (`GSA_TEST_GSA_BIN`, a missing recipe checkout) is reported, never presented as a full pass.
4. Change hygiene: surgical edits; a behaviour change ships its fixture and its dead-code removal in the same pass, and unrelated pre-existing defects stay out of the commit.
5. Ask before committing, pushing or replying. A green battery is evidence, not consent.

## Durable rules

Rule numbers are preserved forever: ~190 code comments and contract §L.3 cite them, so they are never renumbered, reused or invented. Borrowed numbers whose bodies live in `gsa-recipe`: `3, 4, 5→14, 7, 8, 14–17, 20′, 21, 24, 28–34, 36, 37, 39–43, 45–50, 52, 53, 55, 64, 70`; dropped: `35, 38→63, 44, 51, 62→73, 64(SRCDEST)→73`. Full bodies live in the maintainer's private warehouse.

| # | Rule | Essence |
|---|---|---|
| 1 | Cross-shell `bash -c` | Fish traps: no `export`/`[[ ]]`, 1-indexed arrays, unmatched-glob errors, aliased `ls`/`grep`/`rm` |
| 2 | Agent git hardening | `GIT_CONFIG_COUNT=0` before bare-repo and makepkg VCS git calls |
| 6 | Toolchain identity | Build-tree reuse keyed by `<family>\|<compiler line>\|<config sha256>` |
| 9 | Dynamic `IgnorePkg` | Register accepted names before `pacman -U`; never delete a held `db.lck` |
| 10 | Journal and action exports | One dense line per action, the detail in the entry — in the private warehouse, never a tracked file |
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
| 76 | Installed world bounds expansion | A consumer joins only when one of its outputs is installed (∪ the seeds/planned set); the wave obeys the same rule |
| 77 | One transaction carries the stock consumer | `--with` archives join the provider's single `pacman -U` and the gate's ONE membership class (`tx_names` ∪ provenance-labelled `with_names`, never a second coverage predicate); their own links are verified (`with-unresolved`), and a refusal standing on out-of-tree names advertises the exact repair it can actually transact |
| 78 | A transaction does not silently drop a soname | The pre-transaction hook diffs each incoming package's shipped sonames against the installed package's (class-scoped: a 32-bit co-ship never covers a 64-bit drop), then resolves installed consumers of what disappears — minus those resolving it through their own RUNPATH — into `need-rebuild` rows; standing `first`-reason record rows never carry the repair |

## Pitfalls index

One line per mechanism; the full explanations and probe commands live in the maintainer's private warehouse.

**Sources, refs, freshness** — an unreadable `SRCDEST` mirror is `mirror-unusable`, never a bad ref; snapshot pins walk `--first-parent` mainline only; `scheme_vcs` strips `+`; checksums match contiguous same-algorithm runs with `name::url` overrides; mirror VCS with `git clone --bare`; a `?signed` failure is usually injected `GIT_CONFIG_*` or a full `$TMPDIR`; VCS `--skip` verifies every declared ref; freshness reads `$srcdir` first and never pins `pkgrel >= N`.

**Store, workspace, builders** — `-Sy` refreshes only from a neutral cwd; `makepkg --nobuild` dirties trees; keep scratch out of the repo and `/tmp`; sync `config/` alongside packages; update moved `SRCDEST` `alternates`; resolve absolute child paths; re-assert `GSA_LANE_*` last in a `--config` composite and pass the same `--config` to `--verifysource`; pin `GSA_RECIPES_DIR` in every fixture.

**Install, ABI, record** — a stock consumer of a moved soname joins the transaction or the refusal stands (`--with`; install-stock-first is impossible, and `-U` cannot carry the in-run repair); every resolved `--with` member is announced once and a step that does not need it transacts nothing (no per-step row); the drop-side hook scan is gated on an actual soname drop (22.8k candidates ≈ 5 s) and is narrowed to executables and `*.so*` — the engine's `-Qr` remains the exhaustive report; a step's refusal rows collapse to the FIRST reason in the record, so a repair hint needs notes; a new `--print-*` seam owes a `gsa-pm` `install` line; zero expected archives return `nothing-built` and globs must exclude `.sig` and prefix twins; `--leaf` keeps the `:=` wave diagnostic (rows render, no addition, no refusal); a recipe installed nowhere cannot link, so neither expansion site may add it or the prerequisites it drags in (`-Sl` names the skip; runs stay silent); map `DT_NEEDED` by exact `host ∪ shipped` path; stop the GUI session before a major `libLLVM*` move; ALPM `NeedsTargets` hooks need `AbortOnFail`; index `ldconfig -p` + `binpkg.jsonl` once on failure; key `kv.jsonl` rows per `(recipe_id, output)`; a torn tail is repaired by the printed `truncate -s` offset, never automatically.

**Signals, lanes, runs** — one TERM per lane + 30 s grace + one SIGKILL; a TERM storm leaves `db.lck` and a stripped local DB (repair via `--local-db-check`); launch detached from terminal scopes; concurrent `pacman -U` swaps can transiently break sibling loaders.

**Build cache and disk** — probe mounts with `mkdir -p` + `df`, never `mountpoint -q`; keep `download_patterns` equal to `.gitignore`; resolve in-flight keep-paths from `/proc/<pid>/cwd`; never prune a build dir with pending consumers.

**Fixtures** — capture `output::squash` needles from real output; return an empty string for a no-op tick; match stub argv verbatim; wait on events/counts; stay out of live runs; use `find ... -prune` for tree scans.

## Memory

- **Durable memory lives outside this repository, in the maintainer's private warehouse**: measurements, campaign history, owner rulings, review verdicts, the rule and pitfall bodies, the action log and the live working note. The retired design records, ADRs and fixture inventory stay recoverable from git history, never re-created here. Read the matching lesson note before touching an area, and write each action's entry as it happens, not in a batch.
- **Nothing of that shape belongs in a tracked file.** This repository is public: no host paths, private timings, credentials, or incident narrative. `tests/memory-layout.sh` gates it — the retired bookkeeping paths stay absent and this file stays present.
- **Doc edits follow behaviour**: a behaviour change updates the contract (a dated amendment), the guide that teaches it, and the rule or pitfall it encodes, in the same pass.
