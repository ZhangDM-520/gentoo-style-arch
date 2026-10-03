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
   `groups` states group membership as a comma list over the five logical
   groups (`git, stable, core, misc, app`; the roster is stated
   once, in the builder), `edges` is the comma list of packages this one
   consumes — its local build-order edges (a lone `id|path|groups|` is a
   deliberate no-edge record),
   and `tags` carries coupled-batch policy (`abi=must` / `abi=should`), the
   optional `app-cluster=<name>` prompt-cluster tag, and the explicit
   `version-sync=nvchecker` provider opt-in. A tracker file by itself does not
   change a recipe's build-time version source.
   `config/build-defaults.conf` stays separate: lanes/jobs/intensity and the
   memory budgets are knobs, not topology. The loader resolves every record
   on EVERY invocation and one malformed record breaks every command; the
   builder also exposes the resolved records through `--topology`, so tooling
   never parses `config/` itself. It is declarative so maintainers can review
   graph changes without editing scheduler implementation.
3. **Builder** in `build-all.fish` is the operational interface. It resolves
   package IDs, expands consumers and sorts by build order, dispatches isolated
   lanes, serializes pacman transactions, owns the interactive dashboard, and
   reports failures through per-package logs. Stable recipes use Arch metadata
   unless their topology record explicitly selects an nvchecker provider.
4. **Runtime state** is split in two by who owns it. Under `.state/` (or
   `GSA_STATE_DIR`) the builder keeps its own state: `logs/`, the pacman
   mutex, lane result files, and per-recipe GCC identity records under
   `toolchains/`. A missing or changed identity invalidates that recipe's
   incremental build tree before skip decisions. Per-archive VCS revision
   records live beside their package archives so they stay associated with the
   built artifact.
   `makepkg` state — source mirrors, `src/`, `pkg/`, and package archives —
   lands **beside each recipe**, because `SRCDEST`/`PKGDEST` default to
   `$startdir`. Both classes are ignored by Git and are absent from a clean
   checkout.

The source-sharing seam is intentionally between a recipe's VCS source name
and its runtime mirror. A missing canonical mirror is valid on a clean
checkout; the first build populates it. A populated non-Git directory is never
silently replaced.

The scheduler's interface includes more than its flags: package selection is
mandatory, build order is meaningful, `--install` installs before a
dependent build starts, core packages run alone, and failures stop new
dispatches while draining existing lanes. These invariants are part of the
maintainer contract. The failure-stop invariant has two named amendments: a
recipe whose checksum anchoring is refused, and a `-s` recipe whose upstream
never answers its ref query after transport retries, are *deferred*, not
failed — their lane exits with rc 99 (`lane_outcome_defer`, the only path that
emits it), the run record gives the package the `deferred` status (rc 99,
reason `anchoring-refused` or `upstream-unverified`), dispatch continues while
its dependents are held back as `blocked` (reason `waits-on-deferred`), and
the run still exits non-zero with the parked recipes in the resume command.
A run stopped by a signal classifies
what it started as `interrupted` (reason `interrupted-mid-build`) and what
never launched as `never-started` (reason `interrupted-before-start`); it
prints the same summary, run record and continuation suggestion any completed
run prints, then exits 130.

Reporting has one seam too: one run record — the run's plan plus one outcome
row per package — is computed once inside the builder and rendered three ways:
the interactive dashboard (live), the plain output a pipe sees (the prose
summary), and a machine-readable block on stdout between
`--- run record begin ---` and `--- run record end ---` (one
`pkg status rc dur reason` row per package). One seam with three renderings
means no drift between what a human sees and what a script parses: the
dashboard, the summary and the machine block are views of the same rows, not
three parallel accounts of the run.

The install path is one deep module in the same sense: `install_plan` decides
once (silent rows) and `install_execute` renders and transacts, and the hidden
`--install-decide` seam prints those same rows for fixtures — the decision
surface is testable without pacman, sudo or a build.

The install path also owns one payload invariant: a package built from a
recipe that instruments with `-fprofile-generate` is refused if its archive
still carries an absolute `.gcda` destination. The verification *code*
belongs in one module (`lib/pgo.sh`), because verification copy-pasted into
individual recipes is the failure mode that produced two separate recurrences
in 2026-09-16 and 2026-09-19; the per-recipe *calls* remain, because the
`readelf`/symbol predicate is only reachable before makepkg strips. The
builder's payload verification is the fail-closed whole-set backstop, and it
must hold for every PGO recipe, including ones that have not been written
yet. The check sits on the runtime state seam as well: it is the last point
before files are written into `/usr`.
