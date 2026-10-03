# gentoo-style-arch

A curated Arch Linux package set (recipes + declarative topology) with an
automatic-parallelism build scheduler. This glossary names the project's own
concepts; implementation lives in `docs/architecture.md`, history in
`docs/NOTE.md`, rules in `docs/MEMORY.md`.

## Language

### Topology

**Recipe**:
One package's build definition: a directory under
`packages/<category>/<package-id>/` holding a `PKGBUILD` and its committed
metadata (`.SRCINFO`, local assets, licence material).
_Avoid_: spec, formula

**Topology record**:
The single per-package statement of topology facts: identity, recipe path,
group membership, build-order edges, and coupled-batch tags.
_Avoid_: map entry, dependency record (names for the pre-2026-09-26 four-file split)

**Version-sync opt-in**:
The validated `version-sync=nvchecker` topology tag that selects a recipe's
build-time provider from its `.nvchecker.toml`; the file's presence alone is
not an opt-in.
_Avoid_: tracker presence means auto-sync

**Group**:
A logical scheduling class (git, stable, core, misc, app, build-tools) with
scheduling semantics such as core-runs-alone, the build-tools dispatch band,
and the app multi-select prompt. Deliberately
overlaps physical layout.
_Avoid_: category (that is the directory layout)

**build-tools group**:
The dispatch-priority class: within a run its members are dispatched before
all other ready packages, but the band never overrides build-order edges and
the plan, `--list`, run-record and range order stay topological build order.
Membership is always dual `core,build-tools`.
_Avoid_: toolchain dependency (that is a build-order edge; build-tools is
scheduling, not dependency)

**Build-order edge**:
The fact "this package must build after that one". Not a package dependency.
_Avoid_: dependency (pacman dependencies are a different concept)

**Consumer expansion**:
Selecting a package also selects everything that must rebuild after it — its
transitive consumers, reached by reversing build-order edges (if A lists B in
its `edges`, A consumes B). Prerequisites are never expanded: they are assumed
installed and current.
_Avoid_: dependency chain, downstream deps

**Coupled batch**:
A set of packages whose ABIs must move in the same rebuild pass, declared as
membership tags on topology records with `must`/`should` severity.
_Avoid_: ABI group, batch prose

### Build run

**Lane**:
An isolated builder child process that builds (and optionally installs) one
package at a time under a shared CPU/memory budget.
_Avoid_: worker, thread

**Run record**:
One builder invocation's plan and outcome as data: selection, order, budgets,
per-package status, and the continuation. Prose, dashboard, and machine output
are renderings of it.
_Avoid_: summary (that is one rendering)

**Continuation**:
The restated invocation that resumes or re-runs an unfinished build, derived
from the run record and one flag-rule table.
_Avoid_: resume command (one rendering of a continuation)

**Deferral**:
A lane outcome that parks a package (e.g. anchor sums unavailable) without
being a failure: dependents wait, dispatch continues, the run still exits
non-zero.
_Avoid_: failure, skip

**Intensity profile**:
The resource-budget policy (low…max) derived from host CPU threads and free
memory; overridable but never predicted by hand.
_Avoid_: preset, level

**Install plan**:
The decision data for one install transaction: which archives install, which
skip as already-current, which are refused and why. Execution is separate.
_Avoid_: install policy (that names the rules; the plan is their output)

### Verification

**PGO gate**:
The recipe-side verification that no profile instrumentation survives into
shipped binaries: one shared implementation, called per recipe before makepkg
strips. Its symbol predicate is only reachable at this seam.
_Avoid_: per-recipe verify copy (the pre-2026-09-26 recurrence engine)

**Payload verification**:
The builder-side, fail-closed check at the install seam that an archive from an
instrumented recipe carries no baked profiling destination. Whole-set,
post-strip, strings-only.
_Avoid_: central gate (ambiguous)

**Audit lint**:
A read-only drift check run via `--audit` over recipes, topology, or host
state, reported with the offender named. Report-only by contract; gating
happens in fixtures.
_Avoid_: check, linter

**Fetched-only pattern**:
A recipe-declared list of build outputs that are downloaded state, not
committed assets, exempting them from the local-asset walk.
_Avoid_: carve-out, exception

### Fixtures

**Fixture**:
A non-mutating bash test under `tests/` that synthesizes a scratch workspace
under `$TMPDIR` and asserts on exit status, logs, and output.
_Avoid_: test case (fixtures carry specific conventions)

**Stub**:
A fixture-side fake of a host tool (makepkg, sudo, pacman) whose behaviour the
fixture drives through `GSA_FAKE_*` variables.
_Avoid_: mock

**Frozen oracle**:
A committed reference implementation kept under `tests/assets/` for
differential testing against a rewritten one.
_Avoid_: golden file
