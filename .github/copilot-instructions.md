# Copilot instructions — Gentoo_Style_Arch

A curated Arch Linux package set — `PKGBUILD` recipes plus `gsa`, the native
build engine that rebuilds the set as one coherent system. The repo holds
recipes, topology and engine source only — never upstream sources, package
archives, downloaded signatures, PGP caches, or build output.

Engine of record since the 2026-10-14 Phase 5 cutover: `gsa`, the Rust
workspace under `crates/`, packaged by `packages/core/gsa-pm` as
`/usr/bin/gsa`. The fish-era builder `build-all.fish` at the repo root is a
**retirement shim**: it prints the old→new spelling-migration table and exits
non-zero, running nothing — kept one release cycle after the cutover, then
deleted. The fish engine itself survives verbatim as
`tests/assets/build-all.fish` (plus `tests/assets/lib/`): **frozen-oracle test
material** that fixtures diff against, never a live command.

## Relationship to the host's global instruction

The host loads this file **before** its global agent instruction, so where the
two overlap the global rule is the baseline and this file is its repo-specific
refinement. Reviewed against the global rules on 2026-10-17: the shell-boundary
hazard (fish login shell vs bash tool-call shells), the agent-shell git
hardening (`GIT_CONFIG_COUNT=0` for bare-repo and makepkg VCS operations), the
concurrency check before a heavy build, the validation standard, and the
never-bypass-checksums-or-signatures rule all appear below in their concrete
form here, and nothing in this file contradicts them.

One global rule is inherited unchanged because this repo has no variant of it:
workspace isolation — canonical edits stay in this repository, scratch goes to
`~/Workspace/`, and fixture scratch stays in the harness's `$TMPDIR` trees
instead. The commit routine also comes from the host's global instruction, but
it is restated concretely under **Committing** in Conventions below, because
the global wording asks for permission rather than granting it.

## Read before changing anything

| File | Role |
| --- | --- |
| `README.md` | The two halves (recipe set + `gsa` engine), the quickstart path, the mental model. |
| `docs/MEMORY.md` | The operational contract: golden rules (§1), current state (§2 workspace / §3 stack), the optimization playbook (§4), the pending-task queue (§5 `Queued` — claim by editing that section; finished items are deleted, never ticked), the pitfall digest (§6). |
| `docs/NOTE.md` | Chronological incident journal (newest section first): symptom → root cause → fix → validation → durable rule. Opens with a naming-history table for pre-2026-09-15 path/group spellings. Grep a dated section rather than reading it end to end. |
| `docs/gsa-contract.md` | **The authoritative `gsa` interface spec.** Action-pass grammar (§B — incl. the complete old→new spelling table §B.9), selection semantics (§C), hidden test seams (§D), decision rows and the rc contract (§E), outcome vocabularies (§F), exit codes (§G), the run-record machine block `format: 2` (§H), failure policy (§I), state layout (§J), concurrency (§K). When any document conflicts with the contract, the contract wins — fix the document, never the contract in passing. |
| `docs/build-guide.md` | Inspect/dry-run/build path, installation modes, skip-and-resume, prune/cleanup strengths, the `GSA_*` environment surface, the engine output contract, troubleshooting, PGO/Meson reconfigure procedure. |
| `docs/architecture.md` | The four-module split (recipe set / topology / the `gsa` crates / runtime state by owner) and the scheduler's invariants. |
| `docs/maintainer-guide.md` | Adding a recipe, version-synced external releases, the `app` group, updating coupled stacks, the `NOTE.md` entry format. |
| `docs/package-policy.md` | What a recipe directory may hold versus what is fetched at build time. |
| `docs/source-sharing.md` | The shared-source-mirror contract (`gsa -Mm`) and what qualifies as a valid canonical mirror. |
| `docs/portability.md` | Intensity profiles and their formulas, `GSA_*` overrides, CPU-tuning policy. |
| `CONTRIBUTING.md` | Recipe-change checklist, trimming standard, source-verification rules, the validation block. |
| `SECURITY.md` | Trust model (a recipe executes arbitrary shell), safe-operation rules, what must never be committed. |
| `CONTEXT.md` | The project's vocabulary: recipe, topology record, build-order edge, consumer expansion, coupled batch, lane, run record, continuation, deferral — each with the terms to avoid (`dependency` means a pacman dependency, never a build-order edge). |
| `docs/adr/` | One decision record per seam that fought back: the shared PGO gate (`0001`), the one-record topology (`0002`), the run record (`0003`), the prefetch advisory (`0004`). Read the matching ADR before re-opening a decision. |

## Commands

The engine builds from this repository's Rust workspace:

```sh
cargo build --release          # ./target/release/gsa
cargo test --workspace         # engine test suite
gsa --help                     # the authoritative spelling roster
```

`packages/core/gsa-pm` packages the engine as `/usr/bin/gsa` (recipe contract:
an engine change bumps its `_commit` pin + `pkgver` + the committed `.SRCINFO`
in the same change).

### Grammar and families

```
gsa <FAMILY>[cluster-letters] [long-mods] [targets…] [ranges…] [-- <pacman args…>]
```

One family per invocation: `-Q` query, `-S` build + install, `-B` build-only,
`-U` install built archives, `-M` maintain. `gsa fetch` ≡ `gsa -Sw` (fetch and
verify sources ahead of builds). The old fish spellings are gone — the root
shim prints the old→new table and the full mapping is `docs/gsa-contract.md`
§B.9. Never write `fish build-all.fish …` as a live command; the only fish-era
artefacts left are frozen-oracle test material under `tests/assets/`.

### Selection semantics

- Selection is mandatory; a bare `gsa` is a usage error. Targets are a recipe
  ID, a recipe path, a case-variant ID, or a pacman `pkgname` (including split
  outputs); a typo is never auto-corrected — it is reported with the nearest
  candidates.
- Groups AND sets are `@name` targets (`gsa -S @git`, `gsa -B @core`). A
  selection may mix package refs, `@` sets and index ranges; members dedupe.
- A selection expands to its transitive **consumers** (reverse build-order
  edges): rebuilding X cannot break what X consumes — the ABI risk is X's
  consumers. Prerequisites are assumed installed and current, so nothing
  upstream is pulled in; bootstrap and fresh builds use `@group` runs.
  `--leaf` rebuilds exactly the named recipes, no consumer expansion.
- Ranges index the selection in build order (`22..38`, `22..`, `..15`) and
  need a selection to anchor them — read `gsa -Sl @git` before choosing one.
- The `app` group is a prompt layer, not an expansion exception: on a TTY a
  build/`--dry-run` run multi-selects app members (all unchecked + Enter =
  build every app), non-TTY runs take the whole group. Records sharing an
  `app-cluster=<name>` tag present as ONE prompt row — presentation only; the
  packages stay separate in listings, the run record, ranges and lanes.

### Everyday invocations

```sh
gsa -Sl @git                      # ordered listing; ranges address these indices
gsa -S --dry-run @git             # plan + decision rows, no mutation
gsa -S @core                      # build each package and install before its consumers compile
gsa -B --leaf ripgrep             # leaf-only build to archives (no install)
gsa -Sf mesa-git                  # force install (no same-version skip)
gsa -Ua -- --overwrite '*'        # whole-workspace install; trailing args go to pacman
gsa -Ma                           # audit lints — report-only, exit 0, read the report
gsa -Mm                           # shared source mirrors (build user only, never under root)
gsa -Mccc                         # prune strength 3 (prints targets, asks first)
gsa -Mh [--show <run-id>]         # run history
```

Useful modifiers: `--skip` (freshness-gated resume) / `--skip-built` (any
already-built set); `--no-sync`; `--intensity LEVEL` (`low`…`max`, default
`xhigh`), `--lanes`, `--jobs`; `--state-dir PATH`; `--fail-fast`;
`--allow-broken-rustc`; `--no-register-ignorepkg`; `-Mc`/`-Mcc`/`-Mccc` prune
strengths; `-- <args…>` pacman passthrough on install transactions. A flag
beats its `GSA_*` env twin (`GSA_INTENSITY`/`GSA_LANES`/`GSA_JOBS`);
`GSA_CPU_THREADS`/`GSA_MEMORY_GIB` are host overrides, normally unset. The
`gsa --help` roster is authoritative.

### Fixture battery — the project's test suite

```sh
bash tests/run-all.sh                # every fixture, in parallel
bash tests/run-all.sh recipe         # substring filter, e.g. 'recipe', 'pgo', 'scheduler'
bash tests/run-all.sh --serial       # one at a time (debugging a flaky fixture)
```

- `tests/run-all.sh` discovers fixtures recursively, excluding `tests/assets/`
  and `tests/lib/`; a new fixture needs no edit to the runner. A mistyped
  filter exits 2 (`matched no fixtures — typo?`) rather than passing empty.
- Fixtures are bash scripts, non-mutating and `$TMPDIR`-scoped — they build
  synthetic workspaces and PATH stubs under `$TMPDIR`, never the real
  repository. A new fixture must keep that true (the battery is parallel by
  default). Stubs fail closed; oracle-shaped stubs stay inline in the fixture
  that gives them meaning (`tests/lib/fixture-lib.bash` is the shared
  synthesis helper, sourced, never executed).
- The run-record machine block (`format: 2`, between
  `--- run record begin/end ---` on stdout) is the assertion surface
  (`tests/lib/rr-v2.bash`); prose output is pinned in exactly one place.
- Engine fixtures honour-or-build `GSA_TEST_GSA_BIN`: the runner prebuilds the
  engine once into `target/` — never cargo-build a private engine tree per
  fixture. `GSA_FAKE_*` names are fixture-side stub knobs, not engine
  vocabulary.
- `tests/assets/` is **not** discovered: it is frozen reference material — the
  retired fish engine (`tests/assets/build-all.fish` + `lib/`), installed
  beside a fixture's scratch workspace only where a section diffs against the
  oracle. That is the sole remaining fish-era use.
- `tools/` is deliberately outside the battery: host-side diagnostics that are
  heavy and mutating. Each contract is fixture-pinned at reduced scale
  (`tools/go-modcache-check.sh` ↔ `tests/modcache-check.sh`,
  `tools/provides-audit.sh` ↔ `tests/provides-audit.sh`,
  `tools/nvcheck.sh` ↔ `tests/nvcheck-aggregator.sh`). Re-list `ls tools/`
  rather than trusting this inventory.

### Shell boundaries (load-bearing host pitfalls)

- The login shell is **fish**; tool-call shells here are bash. A command
  handed to the user (or `!cmd`) runs under fish — wrap ad-hoc one-liners in
  `bash -c '...'`. In a fish context there is no `export`, no `[[ ]]`, arrays
  are 1-indexed, and an unmatched glob is a fatal error that `2>/dev/null` does
  not suppress. Host aliases change bare names (`ls` → `eza -al`,
  `grep --color=auto`).
- `rm` is a trash wrapper in the login shell: it moves targets to
  `~/.local/share/Trash`, ignores `-r`/`-R`/`-d`, and refuses `/` and `$HOME`.
- Agent shells inject git config (`safe.bareRepository=explicit`, …) that
  breaks bare-repo and makepkg VCS operations — prefix those with
  `GIT_CONFIG_COUNT=0`. The committed fixtures that shell out to `makepkg`
  (e.g. `makepkg_printsrcinfo`) already do.
- Inspect `~/.makepkg.conf` and `/etc/makepkg.conf` before package builds;
  `/etc/makepkg.conf` is locally modified here — compare it with the installed
  package (`pacman -Qkk pacman`) rather than assumed defaults.
- Never run two heavy builds at once — the failure mode is an OOM, not a
  queue. Before rebuilding anything that may already be in flight, check for
  running `makepkg` processes and for runtime log mtime changes.

### Validation

```sh
cargo test --workspace                                 # engine changes
bash tests/run-all.sh                                  # the whole battery, not just the near fixture
bash -n packages/<category>/<pkg>/PKGBUILD             # recipe parse
makepkg --printsrcinfo --dir packages/<category>/<pkg> \
  > packages/<category>/<pkg>/.SRCINFO                 # recipe changes regenerate .SRCINFO
gsa -Ma                                                # recipe/topology changes
gsa -S --dry-run @git                                  # topology edits (repeat for @core, @stable)
```

Never use a real rebuild as a syntax check. For changes to scheduling,
installation, cleanup, source sharing, or signals, add a focused fixture with
fake build/install commands asserting exit status, logs, and child-process
cleanup. There is no CI workflow — fixtures, `cargo test` and `makepkg` are
the entire verification surface.

## Architecture

Two halves plus the runtime state they share (`docs/architecture.md`):

1. **Recipes** — `packages/<category>/<package-id>/` with `PKGBUILD`,
   committed `.SRCINFO`, local patches/hooks/install scripts/desktop assets,
   upstream license material (`LICENSE`, `LICENSES/`, `REUSE.toml`), and
   optional `.nvchecker.toml` / `BUILDING`. The physical categories are
   `git`, `stable`, `core`, `misc` — logical groups deliberately overlap them,
   so never infer build order or group membership from directory names.
2. **Topology** — declarative, under `config/`. `topology.conf` holds one
   record per package, `id|path|groups|edges[|tags]`, and is *the only* place
   that binds a package ID to a recipe path. Group membership is a comma list
   over the roster `git, stable, core, misc, app, build-tools` (stated once,
   in the strict loader `gsa-topo`); `edges` are local build-order edges (a
   trailing empty field is the deliberate no-edge record); tags carry
   `abi=must`/`abi=should` coupled-batch policy, the
   `app-cluster=<name>` prompt-cluster tag, and the validated
   `version-sync=nvchecker` build-time provider opt-in (a `.nvchecker.toml`
   without that tag is report-only). `config/build-defaults.conf` holds the
   lanes/jobs/intensity defaults and the memory budgets
   (`memory_per_job_gib`, `core_memory_per_job_gib`,
   `reserved_memory_gib`). `config/` holds exactly the three files the engine
   reads (`topology.conf`, `build-defaults.conf`, `abi-exclusions.conf`) —
   anything else there is unreachable state that silently goes stale;
   `tests/project.sh` fails on it. The loader validates every record, the
   roster, the graph, and a complete topological sort on **every** invocation:
   one malformed record breaks every command, not just the affected package.
   Tooling reads topology through `gsa -Qt`, never by parsing `config/`.
3. **Engine** — `gsa`, the Rust workspace under `crates/`: `gsa-model` (core
   types, the run record), `gsa-topo` (strict config loaders),
   `gsa-recipe` (`.SRCINFO`/`PKGBUILD` parsing, version sync, VCS freshness,
   checksum anchoring), `gsa-graph` (consumer expansion, topological sort,
   coupled batches), `gsa-sched` (lane supervisor, budgets, failure policy,
   run lock), `gsa-build` (makepkg orchestration, the `PACMAN` shim),
   `gsa-install` (one decision seam + the `pacman -U` executor + IgnorePkg
   registration), `gsa-fetch` (fetch-ahead via `makepkg --verifysource`),
   `gsa-state` (side-car state DB, write-time ownership gate), `gsa-qa`
   (report-only lints, install-refusing checks), `gsa-maint` (the `-M`
   surface), `gsa-abi` (ABI tokens, subscriptions, refusal rows), `gsa-cli`
   (argv grammar and renderings). Crate roles are stated once in
   `docs/architecture.md` §3. The root `build-all.fish` is the retirement
   shim described at the top of this file; the implementation it guards is
   frozen under `tests/assets/` as the differential oracle.
4. **Runtime state** — split by owner:
   - Engine state root `/var/lib/gsa`: `index/` (hash-bound binpkg index),
     `abi/`, `world` + `sets/`, `runs/` (run history), `logs/`, `locks/`
     (pacman mutex, run lock), `toolchains/`, `abi-repair/`, and the
     `recipes/` canonical store (root-fetched from `recipe_url`, refreshed by
     `gsa -Sy`, never hand-edited). Resolution order
     `--state-dir PATH` > `GSA_STATE_DIR` > `gsa.conf` `state_dir`; no silent
     fallback to a workspace-local directory; the write-time ownership gate
     treats root-owned state as correct state (`docs/MEMORY.md` rule 19).
   - makepkg's `BUILDDIR`/`PKGDIR`/`PKGDEST` are the **build user's cache**:
     `<build_dir>/build|pkg|pkgs`, default `~/.cache/gsa` (`gsa.conf`
     `build_dir` / `GSA_BUILD_DIR`). Built archives do **not** sit beside the
     recipe any more — a pre-W4 recipe directory is only a truth-filtered
     legacy fallback for old archives. `SRCDEST` stays makepkg.conf-governed
     (env > the build user's `~/.makepkg.conf` > `/etc/makepkg.conf`).
   - Both classes are Git-ignored runtime state and absent from a clean
     checkout.

Consequences worth internalising:

- `core` is a logical group that deliberately overlaps the physical
  categories; `build-tools` is a dispatch-priority band whose members carry
  dual membership (`core,build-tools`) and which never overrides build-order
  edges. Do not infer either from paths.
- Scheduler invariants are part of the maintainer contract: selection is
  mandatory; `-S` installs each package before its consumers compile; core
  packages run alone with a separate memory-aware job budget. **Cone-stop is
  the default failure policy** — a failed package parks its transitive
  consumer cone (`parked waits-on-failed`) while dispatch continues outside
  it, and the run exits 4; `--fail-fast` stops dispatch and drains in-flight
  lanes (exit 1). A *deferral* (lane exit 99: `anchoring-refused`,
  `upstream-unverified`, `source-unfetchable`) parks its package — dependents
  wait, dispatch continues — but the run still exits non-zero (5 when it is
  the only blemish). An interrupt exits 130 with the full run record. Lane
  outcomes cross the process boundary only through `gsa-sched`'s typed
  lane-result codec.
- The **run record** (`format: 2`) is one structure rendered three ways — the
  TTY dashboard, the prose summary a pipe sees, and the machine block on
  stdout between `--- run record begin/end ---` — and is also persisted to run
  history (`gsa -Mh`). Fixtures assert on the record, not on prose.
- Never predict a plan — read the `parallelism:` line the engine prints.
  Resource planning is host-derived (`docs/portability.md`); explicit
  `--lanes`/`--jobs` override `--intensity`.
- Privilege is pacman-shaped: reads as any user, mutations as root
  (`sudo gsa …`). The engine and pacman run privileged; the makepkg family
  runs as the build user (`SUDO_UID`) via `setpriv`, with the identity
  environment (`HOME`/`USER`/`LOGNAME`) following the drop. The engine never
  prompts (`sudo -n` throughout), and a bare root shell refuses
  build-touching verbs (rc 3).
- Configuration layers `/etc/gsa.conf` then `~/.config/gsa/gsa.conf` (user
  wins; keys `project`, `recipe_url`, `build_dir`, `state_dir`; `~` resolves
  to the build user's home). `GSA_CONF` replaces both with one hermetic file
  for fixtures. An unknown key is a named error, never a silent default.
- The source-sharing seam sits between a recipe's VCS source name and its
  runtime mirror: a missing canonical mirror is valid on a clean checkout (the
  first build populates it), and a populated non-Git directory is never
  silently replaced.
- Install decisions are computed ONCE as typed rows
  (`install`/`skip`/`refuse`/`noop`/`parked`) by `gsa-install`'s decision
  seam; only the executor renders and runs the single `pacman -U`
  transaction. The hidden `--install-decide <checked|force>` seam prints those
  rows for fixtures without touching pacman, sudo, flock or makepkg.

## Conventions

**Recipe registration.** Adding a recipe means: put it under the physical
category and add one topology record (`id|path|groups|edges[|tags]` in
`config/topology.conf`); add an `edges` entry only after verifying the
relationship against package metadata and a build-order reason. A new edge's
reason belongs in `docs/NOTE.md`, a changed operational contract in
`docs/MEMORY.md`. IgnorePkg registration is dynamic: an install run registers
each accepted archive's `pkgbase`+`pkgname` into the `[options]` `IgnorePkg`
closure of the target `pacman.conf` before `pacman -U`; an archive whose names
cannot be established refuses the install (fail-closed);
`--no-register-ignorepkg` skips the step, `gsa -Mi --backfill` is the one-shot
backfill (`--prune` removes stale entries). `gsa -Ma` includes the
recipe-contract lints (provides-versioning, purged tools, provides swaps
(Stock→house swap), ABI closure, ABI exposure) — report-only, the exit status
stays 0, so read the report; the hidden single-lint seam is
`--qa-check <name>`. Per-recipe exceptions are data: a recipe's own
`FETCHED-ONLY` file (one source-basename glob per line) excuses
fetched-at-build-time names from `tests/recipe-sources.sh`'s missing/untracked
checks — never a name-matched branch in a repo-wide walker.

**Meson staleness.** Re-running `meson setup` over an existing build directory
keeps stale option values. After *any* `meson-git` upgrade, purge every build
dir whose `meson-info.json` version differs before rebuilding — build dirs sit
at arbitrary depths, so a `maxdepth` sweep misses them.

**Bootloader boundary.** The set disables systemd's bootloader integration
(this project boots Limine), so `mkinitcpio`'s systemd hooks try to add
optional inputs this host does not ship: the `/usr/lib/nvpcr/*.nvpcr` glob
(0001) and — after systemd 262 dropped them — `systemd-tpm2-setup` plus six
initrd PCR units (0002). The `mkinitcpio` recipe guards those absent optional
inputs instead. Do not re-enable the systemd bootloader feature to satisfy a
hook, and never delete host files for it — extend the guard, then rebuild:
`gsa -S --leaf mkinitcpio`, then `sudo mkinitcpio -P`. When a systemd bump
breaks the hook again, scan the whole hook input list against the installed
provider in one pass rather than one name per rebuild.

**Local assets and ignore rules.** Two ignore layers must both pass. Some
recipes default-deny with a bare `*` plus `!` negations
(`grep -rl '^\*$' packages/*/*/.gitignore` lists them), so a new file without
a matching negation is silently dropped from the commit while still building
locally — a clean checkout then fails with "was not found in the build
directory". Separately, the *root* `.gitignore` denies `packages/*/*/*/`, i.e.
**every new subdirectory** under a recipe, and negates only `LICENSES/`; a
recipe that needs a directory of its own needs the negation added to the root
file too, since most recipes ship no local ignore file at all. Add the
negation in the same change and confirm with `git check-ignore -v <asset>` (no
output = visible). Never let a recipe `.gitignore` match itself.
`tests/recipe-sources.sh` walks every recipe and enforces this repo-wide.
Preserve package-local attribution and licence material (`LICENSE`,
`LICENSES/`, `REUSE.toml`): the root MIT licence covers the scheduler and
project docs only, and does not relicense recipes or bundled upstream
material.

**Concurrency.** Check for running `makepkg` processes and for runtime log mtime
changes before rebuilding a package that may already be in flight, and never
run two heavy builds at once — the failure mode is an OOM, not a queue.

**Provides discipline.** Toolchain `-git` packages carry *versioned* provides
(`provides=("meson=${pkgver}")`) — an unversioned provide cannot satisfy a
`>=N` makedepend and pacman silently falls back to the conflicting repo
package. Every library-shipping package declares *bare* soname provides
(`libfoo.so`); makepkg then auto-versions them from the packaged ELF soname.
Request a capability through its virtual (`java-runtime`, `java-environment`,
`libgl`), never through one concrete provider — Arch's OpenJDK packages are
mutually exclusive, so naming `jre-openjdk` can make pacman demand removal of
a package the dependency graph needs. Provides live in `.PKGINFO`, so a
provides change requires a real rebuild (`makepkg -Rf` only repackages).
Verify with `tar -xOf pkg.tar.zst .PKGINFO | grep provides`.

**Optimization policy.** The host's `makepkg.conf` is the default. Do not
append hard-coded `-O3`, `-march`, or `-mtune` to a recipe; host-derived
native settings are fine, and an explicit `GSA_TARGET_CPU` must be intentional
and documented. `mold-git` does not provide `mold` for depend resolution — the
house idiom is a runtime `command -v mold` guard. Meson recipes use
`arch-meson`. LTO/PGO phases, and the rules that must replace a
*configure-time* argument cache rather than only recompiling — Meson's
`meson setup --reconfigure`, and CMake's `CMakeCache.txt`, whose flags must be
rewritten *inside* the file (`make clean` keeps the cache, and deleting it also
drops the install prefix and the dependency selection) — are documented in
`docs/build-guide.md` and `MEMORY.md` §4/§6.

**PGO gate (`lib/pgo.sh`).** The instrumentation check needs both predicates
and both seams, and the per-recipe half is one shared module: `lib/pgo.sh`,
sourced from each PGO recipe as `source "$startdir/../../../lib/pgo.sh"` and
called as the **last** statement of every `package*` function (a split recipe
gates each `package_*`'s own `$pkgdir`):

```sh
verify_no_profile_instrumentation "$pkgdir" [extra-literal...]
```

The gate is fatal by design — `exit 1` on any hit, which kills makepkg's
function subshell. Do not "soften" a call with `|| return 1`: bash returns the
*last* command's status, so a mid-function call whose failure a later command
overwrites is silently discarded — exactly what the shared gate replaced.
Inside `package()`, before makepkg strips, the symbol predicate is the check
(`readelf -sW <lib> | grep -E '__gcov_|__llvm_profile'` must be empty);
against anything installed or already stripped that command reports a false
clean, so the module also uses the baked path (`strings -a <bin> | grep -c
'\.gcda'`) — what survives stripping. `tests/pgo-lib.sh` pins the module's
fatal semantics and the clean-checkout fact that each consuming PKGBUILD
resolves the tracked path. A new PGO family earns a fixture and extends **this
module** when its leak shapes are new; recipes only ever call it. The families
span five build-system styles: meson (glib2/gtk/cairo/…), CMake
(`cmake-git`), Rust (`mold-git`/`niri-spicy-git`/`ripgrep`), C-autotools
(`jq`/`file`/`rsync` — every phase re-runs `./configure`, and
`-fprofile-generate=<dir>` must be symmetric with `-fprofile-use=<dir>` or the
profile is silently missed) and Go (`fzf` — a `go tool pprof -proto` profile
via `GOFLAGS+=-pgo=…`, floor `pgo_min_samples`); every family falls back to a
plain build when its floor is missed. The engine-side backstop is
fail-closed: `gsa-install`'s payload gate refuses (silent `refuse pgo-*` plan
rows) any archive from a `-fprofile-generate`/`-Cprofile-generate` recipe that
still carries a baked `.gcda`/`.profraw` destination — most recipes instrument
and only a handful guard themselves.

The engine exports `GSA_BUILD_JOBS` to every lane and rewrites `MAKEFLAGS`/
`NINJAFLAGS` without discarding the caller's other flags, so a recipe that
wants the lane's job count should read `GSA_BUILD_JOBS` rather than calling
`nproc` or hard-coding `-j`.

**Trimming.** Remove dead docs, man pages, tests, split packages, `depends`,
`makedepends`, `_pick` paths, and install/check paths *together*; a feature
disabled in `build()` must not leave a packaging step expecting its output.
Keep PGO-training suites, kmod compressors, the GTK4 Vulkan renderer, Rust
`profiler=true`, and CUPS/printing support. `!check` and `autodeps` are
invalid `options` entries in pacman 7.x and are rejected by lint. After a
trim, re-grep for removed tools in remaining `makedepends` and regenerate
`.SRCINFO`. Purged system packages (po4a, python-sphinx, python-myst-parser,
cuda, gcc15, …) must not be reintroduced via `makedepends` — makepkg
reinstalls them silently.

**Source verification.** Never pass `--skippgpcheck` and never drop
`#signed`. A tag may be signed by a *subkey* while upstream `validpgpkeys`
lists only the primary fingerprint: run `git verify-tag <tag>`, confirm the
reported fingerprint against the maintainer's published key, then add it with
a comment naming the role. If it cannot be confirmed against a published key,
stop and report the mismatch.

**Documentation discipline.** `docs/MEMORY.md` holds rules and current state;
`docs/NOTE.md` holds the history (dated incident sections, newest first);
`CONTEXT.md` holds the vocabulary. Every non-trivial packaging or scheduler
change earns a dated `NOTE.md` section: symptom → root cause → fix →
validation → durable rule. Update `MEMORY.md`'s maintainer rules when an
operational contract changes. Keep private paths, credentials, host logs, and
generated artifacts out of both.

**Committing.** The host's commit rule is a prompt, not a default: once a
change is finished, ask whether to commit, commit-and-push, or leave the tree
alone, and let only that answer decide. A green fixture battery is evidence,
not consent — never commit unprompted, including for documentation-only
changes. Every commit carries the descriptive body the log already uses (what
changed → why → how it was validated) plus the trailer
`Co-authored-by: Copilot <223556219+Copilot@users.noreply.github.com>`, which
the global instruction specifies verbatim.

**ABI-coupled batches.** LLVM snapshots have no stable C++ ABI: after an
`llvm-git` bump, rebuild Rust, Mesa, SPIR-V, libclc, OpenShadingLanguage and
the other consumers in the same pass (`rust-git` cannot rebuild itself — the
bootstrap *is* the broken rustc). Qt private-API-coupled modules must move
together too. `git verify`/version strings are not evidence — verify the
installed ABI, provides, and dependency closure.
