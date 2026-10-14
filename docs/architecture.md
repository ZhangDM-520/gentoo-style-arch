# Architecture

Gentoo_Style_Arch has four deliberately separate modules:

1. **Recipes** under `packages/<category>/<package-id>/` are the package-facing
   interface: a `PKGBUILD`, its `.SRCINFO`, the local files `makepkg` needs
   (patches, hooks, install scripts, desktop/asset files), the package's
   upstream attribution and license material (`LICENSE`, `LICENSES/`,
   `REUSE.toml` where upstream provides it), and optional maintenance metadata
   (`.nvchecker.toml`, `BUILDING`). A new local asset must survive the recipe's
   ignore rules — most recipes default-deny, see `CONTRIBUTING.md`.
2. **Topology** is one declarative file, `config/topology.conf`: one record
   per package, `id|path|groups|edges[|tags]`. The `id|path` pair binds the
   package ID to its recipe path — the only place that binding exists —
   `groups` states group membership as a comma list over the six logical
   groups (`git, stable, core, misc, app, build-tools`; the roster is stated
   once, in the strict loader `gsa-topo`), `edges` is the comma list of packages this one
   consumes — its local build-order edges (a lone `id|path|groups|` is a
   deliberate no-edge record),
   and `tags` carries coupled-batch policy (`abi=must` / `abi=should`), the
   optional `app-cluster=<name>` prompt-cluster tag, and the explicit
   `version-sync=nvchecker` provider opt-in. A tracker file by itself does not
   change a recipe's build-time version source.
   `config/build-defaults.conf` stays separate: lanes/jobs/intensity and the
   memory budgets are knobs, not topology. The loader resolves every record
   on EVERY invocation and one malformed record breaks every command; the
   engine also exposes the resolved records through `gsa -Qt`, so tooling
   never parses `config/` itself. It is declarative so maintainers can review
   graph changes without editing scheduler implementation.
3. **Builder** is the native `gsa` engine — the Rust workspace under
   `crates/`, one shipped binary (`docs/gsa-contract.md`; engine of record
   since the 2026-10-14 Phase 5 cutover). The crates and their roles:
   - `gsa-model` — core types: recipe identity, topology records, the run
     record (`format: 2`) and its machine rendering (the "one record, three
     renderings" seam of ADR 0003).
   - `gsa-topo` — strict loaders for `config/topology.conf`,
     `build-defaults.conf`, `abi-exclusions.conf` and user sets; one malformed
     record breaks every command, naming the offender and its line.
   - `gsa-recipe` — committed `.SRCINFO` parsing plus a strict read-only
     `PKGBUILD` scan fallback (never shell evaluation), source
     classification, version sync, VCS freshness, checksum anchoring,
     toolchain identity records.
   - `gsa-graph` — consumer expansion (reverse build-order closure), one
     canonical topological sort with cycle refusal, coupled-batch and
     `app-cluster` grouping.
   - `gsa-sched` — the lane supervisor: intensity budgets
     (`docs/portability.md` formulas as data), the typed lane-result codec,
     the dispatch state machine (core-solo, the `build-tools` band, the
     failure policy), signal handling and the run lock/orphan sweeps.
   - `gsa-build` — makepkg orchestration: the lane child entry, the makepkg
     argv/env contract (checksums/PGP never weakened, `GSA_BUILD_JOBS`
     exported, `MAKEFLAGS`/`NINJAFLAGS` rewritten), the `PACMAN` shim that
     routes makepkg's dependency installs through the one transaction lock,
     and prune strength 1.
   - `gsa-install` — the install pipeline: ONE decision seam producing typed
     decision rows (`gsa-install::decide`), the fail-closed gates (PGO
     payload, ABI soname/consumer/stock-pinner), the `pacman -U` executor
     (`sudo -n` only) and the dynamic IgnorePkg registration.
   - `gsa-fetch` — fetch-ahead: fetch-and-verify of recipe sources through
     `makepkg --verifysource` as the only fetch/verify engine, plus the
     dispatcher's bounded prefetch window.
   - `gsa-state` — the side-car state database under the state root (binpkg
     index, run history, key-value) and its write-time ownership gate.
   - `gsa-qa` — the QA check registry: named report-only lints (the
     `--audit` semantics, ported natively) and install-refusing checks, plus
     the hidden `--qa-check` seam.
   - `gsa-maint` — the `-M` maintain surface: audit/doctor reports, IgnorePkg
     closure repair, log browse, shared-source mirrors, prune strengths,
     sets/world, run history.
   - `gsa-abi` — derived ABI tokens, `:=` subscription records and rebuild
     waves, the installed-ELF view, and the install seam's ABI refusal rows.
   - `gsa-cli` — the `gsa` binary itself: the action-pass argv grammar
     (§B), selection semantics (§C), and the command surface and its
     renderings. Stable recipes
   use Arch metadata unless their topology record explicitly selects an
   nvchecker provider.
4. **Runtime state** is split in two by who owns it. The engine's state root
   is FHS `/var/lib/gsa` by default — relocated as a whole by
   `--state-dir PATH` (flag beats env) or `GSA_STATE_DIR`; there is never a
   silent fallback to a workspace-local directory (contract §J). `gsa-state`
   owns the side-car stores there — `index/` (the hash-bound binpkg index),
   `abi/` (ABI token and subscription records), `world` and `sets/`, `runs/`
   (run history) — and its write-time ownership gate, while `gsa-build` and
   `gsa-sched` keep `logs/`, `locks/` (the pacman mutex and run lock),
   `toolchains/` (per-recipe toolchain identity records; a missing or changed
   identity invalidates that recipe's incremental build tree before skip
   decisions) and `abi-repair/` (forced-rebuild markers) under the same root.
   Per-archive VCS revision
   records live beside their package archives so they stay associated with the
   built artifact.
   `makepkg` state — source mirrors, `src/`, `pkg/`, and package archives —
   lands **beside each recipe**, because `SRCDEST`/`PKGDEST` default to
   `$startdir`; the binpkg index refers to those archives by hash and never
   moves them (contract §J.2). Both classes are ignored by Git where they
   fall inside the tree and are absent from a clean checkout.

The source-sharing seam is intentionally between a recipe's VCS source name
and its runtime mirror. A missing canonical mirror is valid on a clean
checkout; the first build populates it. A populated non-Git directory is never
silently replaced.

The scheduler's interface includes more than its flags: package selection is
mandatory, build order is meaningful, the `-S` family installs each package
before its consumers compile, core packages run alone with a separate
memory-aware job budget, and the failure policy is dispatch-shaped
(`gsa-sched`'s dispatch machine): **cone-stop is the default** — a failed
package parks its transitive consumer cone (`parked waits-on-failed` rows)
while dispatch continues with everything outside the cone — and in-flight
lanes are never killed by a failure; they drain and their rows stand.
`--fail-fast` restores the stop-dispatch-and-drain policy (unstarted packages
become `never-started dispatch-stopped`, exit 1); a cone-stop run with a
failure exits 4. The `build-tools` dispatch band
is one more scheduler invariant: within a run, `build-tools`
members are dispatched before all other ready packages, but the band never
overrides build-order edges, and plan/listing/run-record/range order stays
topological build order. These invariants are part of the
maintainer contract. A *deferral* is not a failure: a lane that exits 99
(`defer`, the only paths that emit it: `anchoring-refused`,
`upstream-unverified`, `source-unfetchable`) has its package parked —
dependents wait (`parked waits-on-deferred`), dispatch continues — but the
run still exits non-zero (5 when a deferral is the only blemish). Outcome
codes cross the process boundary only through `gsa-sched`'s typed lane-result
codec. A run stopped by a signal classifies
what it started as `interrupted` (reason `interrupted-mid-build`) and what
never launched as `never-started` (reason `interrupted-before-start`); it
prints the same summary, run record and continuation suggestion any completed
run prints, then exits 130 (`gsa-sched`'s signal handler: one `SIGTERM` per
child process group, a shared grace window, then `SIGKILL` for survivors).

Reporting has one seam too: one run record (`gsa-model`'s `RunRecord`,
`format: 2`) — the run's plan rows, one outcome row per package, and the
continuation — is computed once and rendered three ways:
the interactive dashboard (live), the plain output a pipe sees (the prose
summary), and a machine-readable block on stdout between
`--- run record begin ---` and `--- run record end ---` (scalars plus
`--- plan ---`, `--- outcome ---` and `--- continuation ---` sections). One
seam with three renderings
means no drift between what a human sees and what a script parses: the
dashboard, the summary and the machine block are views of the same rows, not
three parallel accounts of the run. The record is also persisted to the
side-car run history (`gsa-state`; `gsa -Mh`) — storage of the same
structure, not a fourth derivation (the ADR 0003 amendment).

The install path is one deep module in the same sense: `gsa-install`'s
decision seam decides once (typed `install`/`skip`/`refuse`/`noop`/`parked`
rows) and the executor renders and transacts, and the hidden
`--install-decide` seam prints those same rows for fixtures — the decision
surface is testable without pacman, sudo or a build. Fail-closed gates (PGO
payload, ABI soname/consumer/stock-pinner) live behind that same seam: a
`refuse` row means no `pacman` call happens anywhere downstream of it.

The install path also owns one payload invariant: a package built from a
recipe that instruments with `-fprofile-generate` is refused if its archive
still carries an absolute `.gcda`/`.profraw` destination. The verification *code*
belongs in one module (`lib/pgo.sh`), because verification copy-pasted into
individual recipes is the failure mode that produced two separate recurrences
in 2026-09-16 and 2026-09-19; the per-recipe *calls* remain, because the
`readelf`/symbol predicate is only reachable before makepkg strips. The
engine-side payload verification is the fail-closed whole-set backstop
(`gsa-install`'s gates, folded into the one decision seam), and it
must hold for every PGO recipe, including ones that have not been written
yet. The check sits on the runtime state seam as well: it is the last point
before files are written into `/usr`.
