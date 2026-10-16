# Architecture

Gentoo_Style_Arch is a curated Arch Linux recipe set plus the `gsa` build
engine. Three parts, deliberately separate:

1. **The recipe set and its topology** — what is built, and in what order.
2. **The `gsa` engine** — the Rust workspace under `crates/`, shipped as one
   binary.
3. **Runtime state** — split by who owns it: engine state under the state
   root, makepkg state in the build user's cache.

The earlier four-module framing (recipes / topology / a fish builder /
runtime state) predates the engine migration and is gone.

## 1. The recipe set and topology

**Recipes** live under `packages/<category>/<package-id>/`: a `PKGBUILD`, its
committed `.SRCINFO`, the local files `makepkg` needs (patches, hooks, install
scripts, desktop/asset files), the package's upstream attribution and license
material (`LICENSE`, `LICENSES/`, `REUSE.toml` where upstream provides it),
and optional maintenance metadata (`.nvchecker.toml`, `BUILDING`). A new local
asset must survive two ignore layers — the recipe's own (most recipes
default-deny) and the root `.gitignore`, which denies new subdirectories
except `LICENSES/`; see `CONTRIBUTING.md` and `docs/maintainer-guide.md`.

**Topology** is one declarative file, `config/topology.conf`: one record per
recipe, `id|path|groups|edges[|tags]`.

- `id|path` binds the recipe ID to its recipe path — the only place that
  binding exists.
- `groups` is a comma list over the six group names
  (`git, stable, core, misc, app, build-tools`); the roster is stated once,
  in the strict loader `gsa-topo`. Membership is topology data and is never
  inferred from directory names: `core` deliberately overlaps the physical
  categories (`autofdo-git` and `libclc-git` are `packages/git/` recipes,
  `openssl` is a `packages/stable/` recipe — all core members), and
  `build-tools` members always carry `core,build-tools` because the band is
  dispatch priority, not a partition. Group purposes and membership rules are
  in `docs/maintainer-guide.md`.
- `edges` is the comma list of recipes this one consumes — its local
  build-order edges (a record ending in a bare `|` is a deliberate no-edge
  record). The vocabulary is `CONTEXT.md`'s: "dependency" means a pacman
  dependency, never a build-order edge.
- `tags` carries coupled-batch policy (`abi=must` / `abi=should`), the
  optional `app-cluster=<name>` prompt-cluster tag, and the explicit
  `version-sync=nvchecker` provider opt-in. A tracker file by itself does not
  change a recipe's build-time version source.

`config/build-defaults.conf` stays separate: lanes/jobs/intensity and the
memory budgets are knobs, not topology.

The strict loader resolves every record — map, graph and a complete
topological sort — on EVERY invocation, and one malformed record (or cycle)
breaks every command, naming the offender and its line. Tooling reads the
resolved records through `gsa -Qt`; nothing parses `config/` directly. The
file is declarative so maintainers can review graph changes without reading
scheduler implementation.

## 2. The `gsa` engine

The engine is the Rust workspace under `crates/`, shipped as one binary, `gsa`
(packaged by `packages/core/gsa-pm` as `/usr/bin/gsa`); it has been the
engine of record since the 2026-10-14 Phase 5 cutover. `docs/gsa-contract.md`
is the authoritative interface contract: where this document and the contract
disagree, the contract wins.

- `gsa-model` — core types: recipe identity, topology records, the run
  record (`format: 2`) and its machine rendering; also the checkout-roots and
  build-layout lookup ("Where artifacts live" below).
- `gsa-topo` — strict loaders for `config/topology.conf`,
  `build-defaults.conf`, `abi-exclusions.conf` and user sets; the group
  roster is stated here, once.
- `gsa-recipe` — committed `.SRCINFO` parsing plus a strict read-only
  `PKGBUILD` scan fallback (never shell evaluation); source classification,
  version sync, VCS freshness, checksum anchoring, toolchain identity.
- `gsa-graph` — consumer expansion (the reverse build-order closure), one
  canonical topological sort with cycle refusal, coupled-batch and
  `app-cluster` grouping.
- `gsa-sched` — the lane supervisor: intensity budgets
  (`docs/portability.md` formulas as data), the typed lane-result codec, the
  dispatch state machine (core-solo, the `build-tools` band, the failure
  policy), signal handling, the run lock and orphan sweeps.
- `gsa-build` — makepkg orchestration: the lane child entry, the makepkg
  argv/env contract (checksums and PGP never weakened, `GSA_BUILD_JOBS`
  exported, `MAKEFLAGS`/`NINJAFLAGS` rewritten), the `PACMAN` shim that
  routes makepkg's own dependency installs through the one transaction lock,
  and prune strength 1.
- `gsa-install` — the install pipeline: ONE decision seam
  (`gsa-install::decide`) producing typed decision rows, the fail-closed
  gates (PGO payload, ABI soname/consumer/stock-pinner), the `pacman -U`
  executor (`sudo -n` only) and the dynamic IgnorePkg registration.
- `gsa-fetch` — fetch-ahead through `makepkg --verifysource` as the only
  fetch/verify engine, plus the dispatcher's bounded prefetch window.
- `gsa-state` — the side-car state database under the state root (binpkg
  index, run history, key-value) and its write-time ownership gate.
- `gsa-qa` — the QA check registry: named report-only audit lints (the
  `-Ma` semantics) and install-refusing checks, plus the hidden `--qa-check`
  seam.
- `gsa-maint` — the `-M` maintain surface: audit/doctor reports, IgnorePkg
  closure repair, log browse, shared-source mirrors, prune strengths,
  sets/world, run history.
- `gsa-abi` — derived ABI tokens, `:=` subscription records and rebuild
  waves, the installed-ELF view, and the install seam's ABI refusal rows.
- `gsa-cli` — the `gsa` binary itself: the action-pass argv grammar
  (contract §B), selection semantics (§C), and the command surface and its
  renderings.

### Scheduler invariants

These are part of the maintainer contract, not implementation details:

- Selection is mandatory; build order is meaningful (plan, listing, run
  record and range order are all the one topological order).
- A selection expands to its transitive **consumers** (reverse build-order
  edges); prerequisites are assumed installed and current. `--leaf`
  suppresses the expansion and builds exactly the named recipes.
- The `-S` family installs each package before its consumers compile.
- `core` packages run alone with a separate memory-aware job budget.
- **Cone-stop is the default failure policy**: a failed package parks its
  transitive consumer cone (`parked waits-on-failed` rows) while dispatch
  continues outside the cone, in-flight lanes drain and their rows stand, and
  the run exits **4**. `--fail-fast` stops dispatch and drains (unstarted
  packages become `never-started dispatch-stopped`, exit **1**).
- A *deferral* is not a failure: a lane exiting 99 (`defer` — only
  `anchoring-refused`, `upstream-unverified`, `source-unfetchable` emit it)
  parks its package; dependents wait (`parked waits-on-deferred`) and
  dispatch continues — but a run whose only blemish is a deferral still exits
  non-zero (**5**).
- The `build-tools` band dispatches its members before all other ready
  packages, but never overrides build-order edges and never changes the
  reported order.
- A run stopped by a signal classifies what it started as `interrupted`
  (reason `interrupted-mid-build`) and what never launched as `never-started`
  (`interrupted-before-start`), prints the same summary, run record and
  continuation suggestion any completed run prints, then exits **130**
  (`gsa-sched`'s handler: one `SIGTERM` per child process group, a shared
  grace window, then `SIGKILL` for survivors).
- Resource budgets are host-derived (intensity profiles); never predict a
  plan — the `parallelism:` line the run prints is the truth.

### Deep seams in plain terms

Each of these is one decision or one structure, with everything else as a
view of it — the drift class the house style exists to prevent.

- **One decision, one seam (install).** `gsa-install::decide` computes the
  install decision ONCE, as typed rows (`install`/`skip`/`refuse`/`noop`/
  `parked`); rendering and execution never re-decide. The hidden
  `--install-decide <checked|force>` seam prints exactly those rows without
  touching pacman, sudo, flock or makepkg (rc 0 plan / 1 refusal / 2 bad
  usage), so the decision surface is fixture-testable without a build. The
  fail-closed gates (PGO payload, ABI soname/consumer/stock-pinner) live
  behind that same seam: a `refuse` row means no pacman call happens
  anywhere downstream of it.
- **One run record, three renderings.** `gsa-model`'s `RunRecord`
  (`format: 2`) — plan rows, one outcome row per package, and the
  continuation — is computed once and rendered three ways: the interactive
  dashboard (live), the prose summary a pipe sees, and a machine-readable
  block on stdout between `--- run record begin ---` and
  `--- run record end ---`. One seam with three renderings means no drift
  between what a human sees and what a script parses. The record is also
  persisted to the side-car run history (`gsa-state`; `gsa -Mh`) — storage
  of the same structure, not a fourth derivation.
- **The typed lane-result codec.** A lane's outcome crosses the process
  boundary ONLY through `gsa-sched`'s codec (enum + reason key + duration,
  atomic rename publication; contract §F): no hand-built rows, no string
  comparisons in the dispatcher, and a malformed result is rejected loudly
  (`lost`) rather than guessed at.
- **Where artifacts live (checkout roots and layout).** One lookup answers
  "where may this recipe's VCS checkouts live": `gsa-model`'s
  `checkout_roots` probes the W4a build tree scoped to the recipe's OWN
  pkgbase first (a same-named checkout under another pkgbase is someone
  else's evidence; a scoped miss fails closed), then the pre-W4 legacy roots
  beside the recipe, and the `SRCDEST` mirror only for ref-addressed
  recomputation — a mirror HEAD is the remote's default branch, never the
  built ref. One error policy accompanies it: `build_layout_for_run()`
  treats an unusable build-cache layout as fatal — never a silent fallback
  to recipe-dir trees (contract §J.3's no-silent-fallback rule).
- **The PGO payload invariant.** A package built from a recipe that
  instruments with `-fprofile-generate` is refused at install if its archive
  still carries an absolute `.gcda`/`.profraw` destination. The verification
  *code* lives in one module (`lib/pgo.sh`, called by each PGO recipe before
  makepkg strips), because verification copy-pasted into individual recipes
  is the failure mode that produced two recurrences in 2026-09; the
  engine-side gate (`gsa-install`, folded into the one decision seam) is the
  fail-closed whole-set backstop and must hold for every PGO recipe,
  including ones not yet written. It sits on the runtime-state seam too: the
  last point before files are written into `/usr`.

## 3. Runtime state, split by owner

**Engine state** lives under the state root: FHS `/var/lib/gsa` by default —
`index/` (the hash-bound binpkg index), `abi/` (ABI tokens and subscription
records), `world` and `sets/`, `runs/` (run history), `logs/`, `locks/` (the
pacman mutex and the run lock), `toolchains/` (per-recipe toolchain identity
records; a missing or changed identity invalidates that recipe's incremental
build tree before skip decisions), `abi-repair/` (forced-rebuild markers),
and `recipes/` (the canonical recipe store fetched from `recipe_url`). The
whole root relocates with `--state-dir PATH` (flag beats `GSA_STATE_DIR`
beats the `gsa.conf` `state_dir` key; contract §J.3) and there is never a
silent fallback. Every state write passes `gsa-state`'s write-time ownership
gate: engine state is root-owned, and root-owned is correct state, not
corruption (contract §J.5).

**makepkg state** — build trees, staging, and finished package archives —
lands in the **build user's cache**, never beside the recipe (the W4a
relocation): the engine passes `BUILDDIR`/`PKGDIR`/`PKGDEST` at
`<build_dir>/build|pkg|pkgs`, where `build_dir` resolves as `GSA_BUILD_DIR`
beats `gsa.conf` `build_dir` beats `<build-user-home>/.cache/gsa`. `SRCDEST`
stays governed by `makepkg.conf` untouched (env beats the build user's
`~/.makepkg.conf` beats `/etc/makepkg.conf`). Archive discovery scans the
shared `PKGDEST` plus the pre-W4 recipe dirs as a truth-filtered LEGACY
fallback for old archives — every candidate is matched by its
`.PKGINFO`/output-name truth, so a shared `PKGDEST` can never hand over
another recipe's archive (contract §J.2). Per-archive VCS revision baselines
stay with their archives. Both classes of state are Git-ignored where they
fall inside the tree and absent from a clean checkout.

The source-sharing seam is intentionally between a recipe's VCS source name
and its runtime mirror. A missing canonical mirror is valid on a clean
checkout; the first build populates it. A populated non-Git directory is
never silently replaced (`docs/source-sharing.md`).
