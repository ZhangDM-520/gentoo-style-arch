# Copilot instructions — Gentoo_Style_Arch

A curated Arch Linux package set: 145 `PKGBUILD` recipe directories plus an
automatic-parallelism build scheduler. The repo holds recipes and topology
only — never upstream sources, package archives, downloaded signatures, PGP
caches, or build output.

## Relationship to the host's global instruction

The host loads this file **before** its global agent instruction, so where the two overlap
the global rule is the baseline and this file is its repo-specific refinement. Reviewed
against the global rules on 2026-09-18: the shell-boundary hazard (fish login shell vs bash
tool-call shells), the agent-shell git hardening (`GIT_CONFIG_COUNT=0` for bare-repo and
makepkg VCS operations), the concurrency check before a heavy build, the validation standard,
and the never-bypass-checksums-or-signatures rule all appear below in their concrete form
here, and nothing in this file contradicts them.

One global rule is inherited unchanged because this repo has no variant of it: workspace
isolation — canonical edits stay in this repository, scratch goes to `/tmp` or
`~/Workspace/`, and fixture scratch stays in the harness's `$TMPDIR` trees instead. The
commit routine also comes from the host's global instruction, but it is restated concretely
under **Committing** in Conventions below, because the global wording asks for permission
rather than granting it.

## Read before changing anything

| File | Role |
| --- | --- |
| `README.md` | Group sizes and each group's purpose; the fresh-checkout install and build path. |
| `docs/MEMORY.md` | The operational contract: golden rules, current stack shape, pitfall digest. Rules cite real breakage. |
| `docs/NOTE.md` | Chronological incident journal, one `## YYYY-MM-DD` section per incident. Opens with a naming-history table — entries predating 2026-09-15 use `.Static/.Heavy/.Heavyweight/.3rdP` paths and `static/heavy/critical/rocm` group names, and flags since removed (`-si`/`--sepinstall` went 2026-09-17). Prefer `--help` over the journal for current flags. |
| `docs/build-guide.md` | Install modes, `--cleanup`/`--nuclear`, sudo-keepalive behaviour, PGO/Meson reconfigure procedure. |
| `docs/architecture.md` | The four-module split and the scheduler's implicit invariants. |
| `docs/maintainer-guide.md` | Adding a recipe, coupled-stack updates, the `NOTE.md` entry format. |
| `docs/package-policy.md` | What a recipe directory may hold versus what is fetched at build time. |
| `docs/source-sharing.md` | The `--link-sources` contract and what qualifies as a valid canonical mirror. |
| `docs/portability.md` | Intensity profiles and their formulas, `GSA_*` overrides, CPU-tuning policy. |
| `CONTRIBUTING.md` | Recipe-change checklist, trimming standard, source-verification rules. |
| `SECURITY.md` | Trust model (a recipe executes arbitrary shell), safe-operation rules, what must never be committed. |
| `CONTEXT.md` | The project's own vocabulary: recipe, topology record, build-order edge, consumer expansion, coupled batch, lane, run record, continuation, deferral — each with the terms to avoid (e.g. "dependency" means a pacman dependency, never a build-order edge). |
| `docs/adr/` | One decision record per seam that fought back: the shared PGO gate (`0001`), the one-record topology (`0002`), the run record (`0003`). Read the matching ADR before re-opening a decision. |

`docs/NOTE.md` is the long chronological file (newest section first): grep a
dated section rather than reading it end to end, and remember its naming-history
table when an old entry mentions paths that no longer exist.

`docs/MEMORY.md` §5 **Queued (claim by editing this section)** is the project's
work queue: check it before starting unrelated work, and claim an item by
editing that section. Its convention is that finished items are *deleted*
rather than ticked, because an unchecked list reads as authority while going
stale; §5 is re-verified against the host rather than assumed.

## Commands

Shells are split deliberately: **the builder and its CLI are fish**
(`build-all.fish`); **the fixtures are bash**. Tool-call shells here are bash,
so bash syntax is fine inside a call — the hazard is crossing the boundary.
A command handed to the user, or `!cmd`, runs under the login shell (fish
4.9.3), so wrap ad-hoc one-liners in `bash -c '...'`. In a fish context: no
`export`, no `[[ ]]`, arrays are 1-indexed, and an **unmatched glob is a fatal
error that `2>/dev/null` does not suppress** — use `find -name`. Host aliases
also change what a bare name does (`ls` → `eza -al`, `grep --color=auto`), so
never assume a bare `ls`/`grep` flag works there.

```sh
# Inspect (always do this before building; all four are read-only)
fish build-all.fish --help
fish build-all.fish --list
fish build-all.fish --audit          # needs ripgrep
fish build-all.fish --dry-run --group git

# Fixture battery — the project's test suite
bash tests/run-all.sh                # every fixture, in parallel (nproc jobs)
bash tests/run-all.sh recipe         # substring filter, e.g. 'recipe', 'pgo'
bash tests/run-all.sh --serial       # one at a time (debugging a flaky fixture)
bash tests/recipe-sources.sh         # run one fixture directly
```

`tests/run-all.sh` discovers fixtures recursively (excluding `tests/assets/`
and `tests/lib/`)
and needs no edit for a new one. It runs them in parallel by default, which is
sound because every fixture is non-mutating and `$TMPDIR`-scoped, so none writes
what another reads — **a new fixture must keep that true** (bug in the fixture,
not a reason to drop `-j`). `-j N` / `RUN_ALL_JOBS` caps concurrency,
`--serial` runs one at a time, and the ✓/✗ report is printed alphabetically
regardless of completion order. The
filter is a plain substring of the filename, so `pgo` runs the whole PGO
family; `texlive`, `recipe`, `project`, `scheduler` and `sudo` each
narrow to one area, and `mkinitcpio`/`bpftune` isolate the two single-recipe
hook fixtures. A mistyped filter exits 2 with `matched no fixtures — typo?`
rather than silently passing an empty battery.

Fixtures are bash scripts that exit non-zero on failure, are non-mutating
(they build scratch trees under `$TMPDIR`, diff committed metadata, and assert
on builder output), and print a reason to stderr. **Run the whole battery, not
just the fixture near your change** — a `config/topology.conf` format change
was once caught by an unrelated recipe fixture.

Three harness conventions worth copying rather than reinventing: a fixture that
applies to many packages takes its package/project as `$1`/`$2`
(`tests/pgo-transition.sh` runs all eight of its pairs with no arguments, one
pair when given the four — the fourth names the build-system family,
`meson` or `autotools`); sibling areas share ONE file as sequential sections,
each absorbed script wrapped in a `( subshell )` so its variables, traps and
`fail()` prefix stay isolated (`kernel-recipes`, `log-ownership`, `noctalia-pgo`,
`zen-pgo`, `vencord`, `project`) — merge into an existing subject file rather
than adding a second top-level script for the same subject; and `tests/assets/`
is *not* discovered —
it holds frozen reference material such as the previous split-loop
implementation, so nothing there runs standalone.

Scheduler, install and cleanup fixtures never exercise the real repository.
They build a synthetic workspace under `$TMPDIR` — copy `build-all.fish`, then
write a minimal `config/` (a hand-written `topology.conf` and
`build-defaults.conf`, one-line `PKGBUILD`s) — and prefix `PATH` with
stub `makepkg`/`sudo`/`pacman` executables. Shared skeleton/stub synthesis
lives in `tests/lib/fixture-lib.bash`, which is **sourced, never executed**
(`.bash` extension plus a `lib/` exclusion in `run-all.sh` keep it out of the
battery — both are load-bearing); it covers workspace synthesis and trivial
byte-identical stubs only. Everything oracle-shaped — assertions, `fail()`
prefixes, the `( subshell )` section structure, scenario-specific stubs such
as fake `date` or marker-flipping pacman — stays inline in the fixture that
gives it meaning. Fixtures drive those stubs
through variables the *stub* defines, not the builder: `GSA_FAKE_SUDO_MODE`,
`GSA_FAKE_SUDO_STATE`, `GSA_FAKE_SUDO_LOG`, `GSA_FAKE_BUILD_SECONDS`,
`GSA_FAKE_MARKER_DIR`, `GSA_FAIL_PACKAGE`, `GSA_SPAWN_LOG`.
`tests/sudo-keepalive.sh` also stubs `date`, so the 150 s sudo keepalive
elapses on a virtual clock inside a run that lasts seconds. Those `GSA_FAKE_*`
names are fixture-side only: the builder honours exactly the seven variables
`--help` lists — `GSA_LANES`, `GSA_JOBS`, `GSA_INTENSITY`, `GSA_CPU_THREADS`,
`GSA_MEMORY_GIB`, `GSA_STATE_DIR`, `GSA_TARGET_CPU` — and
`GSA_CPU_THREADS`/`GSA_MEMORY_GIB` are the deterministic way to pin a profile
assertion. `GSA_BUILD_JOBS` is an output, not an input: `lane_job` exports the
lane's job count for recipes to read. Prefer expressing a scenario with a stub
over adding a test knob to the builder.

Validation for a change:

```sh
fish -n build-all.fish                                  # parse the scheduler
bash -n packages/<category>/<pkg>/PKGBUILD              # parse a recipe
makepkg --printsrcinfo --dir packages/<category>/<pkg> > packages/<category>/<pkg>/.SRCINFO
fish build-all.fish --audit && fish build-all.fish --list
fish build-all.fish --dry-run --group git            # repeat for stable, core
bash tests/run-all.sh
```

The `--audit`/`--list`/three-dry-run sweep is `CONTRIBUTING.md`'s submission
checklist and the cheapest way to prove a topology edit did not break the
loader: every one of them re-validates the whole map, graph and sort.

Never use a real rebuild as a syntax check. For changes to scheduling,
installation, cleanup, source sharing, or signals, add a focused fixture with
fake build/install commands that asserts exit status, logs, and child-process
cleanup. There is no CI workflow and no compilable language here — fixtures and
`makepkg` are the entire verification surface.

`tools/` is deliberately outside the battery: host-side diagnostics that are
heavy and mutating, so `tests/run-all.sh` never discovers them. Each one's
contract is still fixture-pinned at reduced scale — `tools/go-modcache-check.sh`
by `tests/modcache-check.sh`, `tools/provides-audit.sh` by
`tests/provides-audit.sh`, `tools/nvcheck.sh` by `tests/nvcheck-aggregator.sh`.
Re-list the directory (`ls tools/`) rather than
trusting a remembered inventory.

Agent shells inject git config (`safe.bareRepository=explicit`), which breaks
bare-repo and makepkg VCS operations. Prefix those with `GIT_CONFIG_COUNT=0`
(the committed fixtures that shell out to `makepkg` already do).

### Selection semantics

A selection of X — positional ref, `-g` group member, or app-prompt row —
expands to X plus its transitive **consumers** (reverse build-order edges: a
record `id|path|groups|edges` listing B in `edges` consumes B), so
`build-all.fish glib2-git` also rebuilds gtk4-git, networkmanager, fcitx5-git
and everything else that must build after glib2-git. Rebuilding X cannot break
what X consumes; the ABI risk is X's consumers. Upstream expansion is gone:
prerequisites are assumed installed and current, so a consumer's other
prerequisites are never pulled in (the same soundness `--no-deps` always made)
— bootstrap and fresh builds use `-g` group runs. `--no-deps` rebuilds exactly
the named packages, nothing else: a consumer-free name is already a leaf, and
`--no-deps` is what keeps a consumer-bearing name leaf.

The `app` group is where the prompt lives, not an expansion exception —
selections expand consumers here like everywhere else (app packages typically
have none). A TTY build or `-n` run first prompts to
multi-select (all unchecked + Enter = build every app, any checked = build only
those, `q` aborts non-zero), non-TTY runs and `-l` silently take the whole
group. A group run can reach across groups through consumers — `-g git` may
add app consumers via `glib2-git`. The prompt is a filter layer in front of the
normal pipeline: whatever it
returns becomes the group's contribution to the selection and every later step
(topo sort, ranges, lanes) is the existing code. Records sharing an
`app-cluster=<name>` topology tag present as ONE prompt row
(`fcitx5 [member ids]`; toggling checks/clears all members, "N checked" counts
rows, not packages) — presentation only: the packages stay separate in `-l`,
the run record, ranges and lanes.

```sh
fish build-all.fish --no-deps niri-spicy-git   # leaf rebuild only
fish build-all.fish -g git 22..38              # index range from '-l -g git'
fish build-all.fish -s --install -g git        # resume: skip already-built archives
```

A reference may be a recipe ID (`mesa-git`), a recipe path
(`packages/git/mesa-git`), a case-variant ID, or a pacman `pkgname` — including a
split output (`zen-browser` → `zen-browser-pgo`). The last two are exact lookups
against the committed `.SRCINFO` names and are announced when substituted; a typo
is never auto-corrected, it is reported with the nearest candidates.

`-g` takes repeats or commas (`-g git -g core` / `-g git,core`) and dedupes the
union, so group *and* explicit package selections can be combined in one run.
Ranges index the **selection** in build order (each package before its
consumers) and may be open-ended (`22..`,
`..15`), but a range still needs a `-g` or package selection to anchor it — read
`-l -g git` (not a bare `-l`, which lists the whole set in a different order)
before choosing one.

`-i` installs each package before its dependents compile (core selection turns
it on automatically), through `pacman -U --noconfirm --ask 4`, and an install
failure aborts the whole run rather than continuing to build dependents.
Before the transaction, `-i` compares each archive with the installed
database: a package whose exact version is already installed with an install
date not older than the archive skips its install (a same-version rebuild
still installs, and any doubt installs); `-fi`/`--forceinstall` implies `-i`
and bypasses that check, always running `pacman -U`.
`-ia`/`--installall` is the single-transaction escape hatch — it installs after
everything is built, so it must never stand in for `-i` on a set whose members
depend on each other; it forwards trailing arguments to pacman
(`-ia --overwrite '*'`). `-ccc`/`--nuclear` and `-ln`/`--link-sources` ask for
confirmation; `--link-sources` must be run as the build user, not under a root
supervisor. `--audit` and `--link-sources` are the only modes needing
`rg`/`git`. `--allow-broken-rustc` bypasses the rustc
sanity probe that guards against LLVM-snapshot ABI skew — it is an escape hatch
for runs that compile no Rust, not a way past a real ABI mismatch.

The remaining build-time flags: `-s`/`--skip` (skip a package whose
`.pkg.tar.zst` is newer than its `PKGBUILD` — the resume idiom), `--no-sync`
(skip the Arch version query and every explicitly opted-in nvchecker provider),
`--intensity LEVEL`
(`low`…`max`, default `xhigh`), `--lanes`, `--jobs`. Note the short-flag
overloads: `-s` is *not* install, `-l` is `--list`, `-n` is `--dry-run`, and
the three wipe strengths are `-c`/`--clean` (`src/`, `pkg/`, `build/` and the
archive of each selected package, run before the skip check so it forces a
rebuild), `-cc`/`--cleanup` (every built archive in the workspace) and
`-ccc`/`--nuclear` (pulled sources as well).
Installs run in the lanes through **one** pipeline — `install_plan` computes
silent decision rows (`install`/`skip`/`refuse`/`noop`) once, and only
`install_execute` renders and runs the single `pacman -U` transaction; `-ia`
shares the same pipeline in force mode (no same-version skip). The hidden
`--install-decide <checked|force>` seam prints those plan rows without
touching pacman, sudo, flock or makepkg (rc 0 plan / 1 refusal / 2 bad usage)
— that is the fixture entry point for install behaviour. All privilege
escalation is `sudo -n` and the builder **never prompts** (2026-09-26): the
preflight refuses to start an `-i` run when installs cannot succeed
(`sudo cannot install non-interactively`), and a credential lost mid-run stops
dispatch exactly once (`sudo credential expired and cannot be refreshed`)
with a non-zero exit — a TTY changes nothing. A system pacman database lock
is never deleted automatically. `sudo fish build-all.fish …` starts a root
supervisor while `makepkg` still runs as the
invoking user. Interactive terminals get a dashboard, pipes get plain output —
parse the latter.

## Architecture

Four modules, deliberately separated (`docs/architecture.md`):

1. **Recipes** — `packages/<category>/<package-id>/` with `PKGBUILD`,
   committed `.SRCINFO`, local patches/hooks/install scripts/desktop assets,
   upstream license material, and optional `.nvchecker.toml` / `BUILDING`.
2. **Topology** — declarative, under `config/`. `topology.conf` holds one
   record per package, `id|path|groups|edges[|tags]`, and is *the only* place
   that binds a package ID to a recipe path; the loader rejects malformed
   records by naming the offender and line. Group membership (comma list ⊂
   `git,stable,core,misc,app`, roster stated once; the `third-party` group was
   retired 2026-09-27 and its two recipes moved to `packages/stable/`) and local
   build-order edges (a trailing empty `edges` field is a deliberate no-edge
   record) live in the same record, as do optional `abi=must`/`abi=should`
   coupled-batch tags consumed by the generic batch gate, the
   `app-cluster=<name>` prompt-cluster tag, and the validated
   `version-sync=nvchecker` build-time provider opt-in. A `.nvchecker.toml`
   without that tag remains report-only. Tooling reads
   topology through the builder's `--topology` data channel, never by parsing
   `config/` directly. `build-defaults.conf` holds the GiB-per-job
   baselines (`memory_per_job_gib`, `core_memory_per_job_gib`,
   `reserved_memory_gib`) and the default `lanes`/`jobs`/`intensity`/`state_dir`.
   The five group names are stated once (`_GROUP_NAMES`) and nothing outside
   that roster is readable; any other file in `config/` is unreachable state
   that silently goes stale — `tests/project.sh` fails on it.
3. **Builder** — `build-all.fish` resolves IDs, expands consumers and sorts
   by build order, dispatches isolated fish child processes as lanes, serializes
   pacman transactions, owns the dashboard, and reports per-package logs —
   plus two sourced leaf modules, `lib/sources.fish` (PKGBUILD/.SRCINFO parsing,
   version sync, VCS freshness, checksum anchoring) and `lib/audit.fish`
   (workspace audit lints), cut out verbatim by the Design C split (2026-10-05).
4. **Runtime state** — split by owner. `.state/` (or `GSA_STATE_DIR`) holds
   builder-owned logs, lane results, and the pacman mutex. makepkg's own
   mirrors, `src/`, `pkg/`, and archives land **beside each recipe**
   (`SRCDEST`/`PKGDEST` default to `$startdir`). Both are Git-ignored.

Consequences worth internalising:

- The loader validates every topology record, the group roster, the build-order
  graph, and a complete topological sort on **every** invocation. One malformed
  record breaks `--list`, `--help`, and every build, not just the affected
  package.
- Do not infer build order or group membership from directory names. `core` is
  a logical group that deliberately overlaps the physical categories:
  `autofdo-git` and `libclc-git` are `packages/git/` recipes, while
  `hip-runtime`, `hsa-rocr` and `openssl` are `packages/stable/` recipes — all
  five are core members whose ABI must move as one batch.
- Scheduler invariants are part of the maintainer contract: selection is
  mandatory (a bare invocation never starts a rebuild), `-i` installs each
  package before its dependents compile, core packages run alone with a
  separate memory-aware job budget, and a failure stops new dispatches while
  draining existing lanes. A *deferral* is not a failure: a lane that exits 99
  (`lane_outcome_defer`) has its package parked — dependents wait
  (`waits on a deferred package`), dispatch continues — but the run still
  exits non-zero. Lane outcomes carry a named vocabulary
  (`lane_outcome_{ok 0, failed 1, defer 99, lost 125, hup 129, int 130, term
  143}`) and cross the process boundary only through the
  `lane_result_encode`/`decode` codec pair.
- The **run record** (ADR `0003`) is one builder-internal data structure —
  plan, per-package outcome rows, and the continuation — computed once and
  rendered three ways: the streaming dashboard, the prose summary, and an
  additive machine-checkable block on stdout (default-on, also emitted on the
  interrupt path). It is not persisted to `.state/`, and there is no opt-in
  flag. Continuation arguments come from one flag-rule table with an explicit
  not-mirrored list; ambient env knobs (`GSA_TARGET_CPU`, `GSA_STATE_DIR`) are
  warned about, not mirrored. Fixtures assert on the record, not on prose.
- The source-sharing seam is between a recipe's VCS source name and its runtime
  mirror. A missing canonical mirror is valid on a clean checkout — the first
  build populates it. A populated non-Git directory is never silently
  replaced. Mirrors and symlinks are runtime state and must stay ignored.
- Resource planning is entirely host-derived; the profiles and formulas are in
  `docs/portability.md`. Never predict a plan — read the `parallelism:` line the
  builder prints. `--lanes`/`--jobs` override `--intensity`.
- `build-all.fish` is an ~8 200-line fish entry (8 202 lines / 158 functions as
  of 2026-10-05) with two sourced leaf modules (Design C split, same day):
  `lib/sources.fish` (52 fns — PKGBUILD/.SRCINFO parsing, version sync, VCS
  freshness, checksum anchoring; documented out-param globals
  `_VCS_REVISION_ERROR`, `_VCS_SKIP_TOLERANCE`, `_FRESHNESS_WAIVER{,_REASON}`,
  `_DEFER_REASON`, `_VERSION_SYNC_TMP_ERROR`, `_SR_ROWS`/`_PB_ROWS`) and
  `lib/audit.fish` (10 fns — audit lints; writes no globals). They are cut out
  verbatim and sourced from `$SCRIPT_DIR/lib/` before `load_project_config` and
  the hidden seams; the loader, lane dispatcher, `INTENSITY_*` constants
  (inside `configure_intensity`) and `main` remain in the entry. `lib/pgo.sh`
  is the one module sourced by *recipes*, not by the builder. Synthetic
  workspace fixtures copy the modules beside the entry (`tests/lib/fixture-lib.bash`'s
  `make_workspace` does).

## Conventions

**Recipe registration.** Adding a recipe means: put it under the physical
category and add one topology record (`id|path|groups|edges[|tags]` in
`config/topology.conf`); add an `edges` entry only after verifying the dependency
against package metadata and a build-order reason. IgnorePkg registration is
dynamic (2026-10-05): an install run registers
each accepted archive's `pkgbase`+`pkgname` into the `[options]` `IgnorePkg`
closure of the target pacman.conf before `pacman -U`, an archive whose names
cannot be established refuses the install (fail-closed), `--no-register-ignorepkg`
skips the step, and `--register-ignorepkg` is the one-shot backfill of an
existing conf. `--audit` includes the recipe-contract lints
(provides-versioning, purged tools, provides swaps (Stock→house swap), ABI
closure, ABI exposure), report-only, and the hidden
`--audit-lint <provides|purged|swap|abi-closure|abi-exposure>`
seam runs one lint at a time (`tests/recipe-contract.sh` pins both); the
audit's exit status stays 0, so read the report. Per-recipe exceptions are
data: a recipe's own `FETCHED-ONLY` file (one source-basename glob per line)
excuses fetched-at-build-time names from `tests/recipe-sources.sh`'s
missing/untracked checks — never a name-matched branch in a repo-wide walker.
A new edge's reason belongs in
`docs/NOTE.md`, and a changed operational contract in `docs/MEMORY.md`.

**Meson staleness.** Re-running `meson setup` over an existing build directory
keeps stale option values. After *any* `meson-git` upgrade, purge every build
dir whose `meson-info.json` version differs before rebuilding — build dirs sit
at arbitrary depths, so a `maxdepth` sweep misses them.

**Bootloader boundary.** The set disables systemd's bootloader integration
(this project boots Limine), so stock `mkinitcpio` 42-1's systemd hooks try to
add the optional `/usr/lib/nvpcr/*.nvpcr` glob literally. The `mkinitcpio`
recipe here guards that absent optional input instead. Do not re-enable the
systemd bootloader feature to satisfy it — rebuild the guard:
`fish build-all.fish --no-deps --install mkinitcpio`, then `sudo mkinitcpio -P`.

**Local assets and ignore rules.** Two ignore layers must both pass. Some
recipes default-deny with a bare `*` plus `!` negations (`grep -rl '^\*$'
packages/*/*/.gitignore` lists them), so a new file without
a matching negation is silently dropped from the commit while still building
locally — a clean checkout then fails with "was not found in the build
directory". Separately, the *root* `.gitignore` denies `packages/*/*/*/`, i.e.
**every new subdirectory** under a recipe, and negates only `LICENSES/`; a
recipe that needs a directory of its own (not just a file) needs the negation
added to the root file too, since most recipes ship no local ignore file at
all. Add the negation in the same change and confirm with
`git check-ignore -v <asset>` (no output = visible). Never let a recipe
`.gitignore` match itself. `tests/recipe-sources.sh` walks every recipe and
enforces this repo-wide. Preserve package-local attribution and licence
material (`LICENSE`, `LICENSES/`, `REUSE.toml`): the root MIT licence covers
the scheduler and project docs only, and does not relicense recipes or bundled
upstream material.

**Concurrency.** Check for running `makepkg` processes and for runtime log
mtime changes before rebuilding a package that may already be in flight, and
never run two heavy builds at once — the failure mode is an OOM, not a queue.

**Provides discipline.** Toolchain `-git` packages carry *versioned* provides
(`provides=("meson=${pkgver}")`) — an unversioned provide cannot satisfy a
`>=N` makedepend and pacman silently falls back to the conflicting repo
package. Every library-shipping package declares *bare* soname provides
(`libfoo.so`); makepkg then auto-versions them from the packaged ELF soname.
Request a capability through its virtual (`java-runtime`, `java-environment`,
`libgl`), never through one concrete provider — Arch's OpenJDK packages are
mutually exclusive, so naming `jre-openjdk` can make pacman demand removal of a
package the dependency graph needs. Provides live in `.PKGINFO`, so a provides
change requires a real rebuild (`makepkg -Rf` only repackages). Verify with
`tar -xOf pkg.tar.zst .PKGINFO | grep provides`.

**Optimization policy.** The host's `makepkg.conf` is the default. Do not
append hard-coded `-O3`, `-march`, or `-mtune` to a recipe; host-derived native
settings are fine, and an explicit `GSA_TARGET_CPU` must be intentional and
documented. `mold-git` does not provide `mold` for depend resolution — the
house idiom is a runtime `command -v mold` guard. Meson recipes use
`arch-meson`. LTO/PGO phases, and the rules that must replace a *configure-time*
argument cache rather than only recompiling — Meson's `meson setup
--reconfigure`, and CMake's `CMakeCache.txt`, whose flags must be rewritten
*inside* the file (`make clean` keeps the cache, and deleting it also drops the
install prefix and the dependency selection) — are documented in
`docs/build-guide.md` and `MEMORY.md` §4/§6.

The instrumentation check needs **both predicates and both seams**, and the
per-recipe half is one shared module: `lib/pgo.sh`, sourced from each PGO
recipe as `source "$startdir/../../../lib/pgo.sh"` and called as the **last**
statement of every `package*` function (a split recipe gates each
`package_*`'s own `$pkgdir`):

```sh
verify_no_profile_instrumentation "$pkgdir" [extra-literal...]
```

The gate is fatal by design — `exit 1` on any hit, which kills makepkg's
function subshell. Do not "soften" a call with `|| return 1`: bash returns the
*last* command's status, so a mid-function call whose failure a later command
overwrites is silently discarded — that discarded-status convention is exactly
what the shared gate replaced. Inside `package()`, before makepkg strips, the
symbol predicate is the check
(`readelf -sW <lib> | grep -E '__gcov_|__llvm_profile'` must be empty);
against anything installed or already stripped that same command reports a
false clean, so the module also uses the baked path
(`strings -a <bin> | grep -c '\.gcda'`) — what survives stripping.
`tests/pgo-lib.sh` pins the module's fatal semantics (every assertion runs it
in a subshell) and the clean-checkout fact that each consuming PKGBUILD
resolves the tracked path. A new PGO family earns a fixture and extends
**this module** when its leak shapes are new; recipes only ever call it. The
families span five build-system
styles as of 2026-09-28: meson (glib2/gtk/cairo/…), CMake (`cmake-git`), Rust
(`mold-git`/`niri-spicy-git`/`ripgrep`), **C-autotools** (`jq`/`file`/`rsync`
— every phase re-runs `./configure`, and `-fprofile-generate=<dir>` must be
symmetric with `-fprofile-use=<dir>` or the profile is silently missed) and
**Go** (`fzf` — a `go tool pprof -proto` profile wired via `GOFLAGS+=-pgo=…`,
floor `pgo_min_samples`); every family falls back to a plain build when its
floor is missed (MEMORY §4) — the C-autotools and Go flavors of 2026-09-28
needed no module change.

The invariant is also enforced from the builder as the fail-closed backstop:
`pgo_payload_refusals` in `build-all.fish` (formerly `verify_pgo_payload`) is
a step of the one install pipeline, emitting silent `refuse pgo-*` plan rows
that abort before any archive from a `-fprofile-generate`/`-Cprofile-generate`
recipe carrying a baked `.gcda`/`.profraw` destination can be installed —
because most recipes instrument and only a handful guard themselves.

The builder exports `GSA_BUILD_JOBS` to every lane and rewrites `MAKEFLAGS`/
`NINJAFLAGS` without discarding the caller's other flags, so a recipe that
wants the lane's job count should read `GSA_BUILD_JOBS` rather than calling
`nproc` or hard-coding `-j`.

**Trimming.** Remove dead docs, man pages, tests, split packages, `depends`,
`makedepends`, `_pick` paths, and install/check paths *together*; a feature
disabled in `build()` must not leave a packaging step expecting its output.
Keep PGO-training suites, kmod compressors, the GTK4 Vulkan renderer, Rust
`profiler=true`, and CUPS/printing support. `!check` and `autodeps` are invalid
`options` entries in pacman 7.x and are rejected by lint. After a trim, re-grep
for removed tools in remaining `makedepends` and regenerate `.SRCINFO`.
Purged system packages (po4a, python-sphinx, python-myst-parser, cuda, gcc15, …)
must not be reintroduced via `makedepends` — makepkg reinstalls them silently.

**Source verification.** Never pass `--skippgpcheck` and never drop `#signed`.
A tag may be signed by a *subkey* while upstream `validpgpkeys` lists only the
primary fingerprint: run `git verify-tag <tag>`, confirm the reported
fingerprint against the maintainer's published key, then add it with a comment
naming the role. If it cannot be confirmed against a published key, stop and
report the mismatch.

**Documentation discipline.** `docs/MEMORY.md` holds rules and current state;
`docs/NOTE.md` holds the history. Every non-trivial packaging or scheduler
change earns a dated `NOTE.md` section: symptom → root cause → fix →
validation → durable rule. Update `MEMORY.md`'s maintainer rules when an
operational contract changes. Keep private paths, credentials, host logs, and
generated artifacts out of both.

**Committing.** The host's commit rule is a prompt, not a default: once a change
is finished, ask whether to commit, commit-and-push, or leave the tree alone,
and let only that answer decide. A green fixture battery is evidence, not
consent — never commit unprompted, including for documentation-only changes.
Every commit carries the descriptive body the log already uses (what changed →
why → how it was validated) plus the trailer
`Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>`, which
the global instruction specifies verbatim.

**ABI-coupled batches.** LLVM snapshots have no stable C++ ABI: after an
`llvm-git` bump, rebuild Rust, Mesa, SPIR-V, libclc, OpenShadingLanguage and
the other consumers in the same pass (`rust-git` cannot rebuild itself — the
bootstrap *is* the broken rustc). Qt private-API-coupled modules must move
together too. `git verify`/version strings are not evidence — verify the
installed ABI, provides, and dependency closure.
