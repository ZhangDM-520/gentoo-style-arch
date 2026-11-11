# AGENTS.md — engine memory & entry point

Last reviewed: 2026-11-10. This file is the engine repository's whole memory:
overview, rules, pitfalls, queue, pointers. It holds the RULE text and one line
per pitfall MECHANISM; the incidents, dates and measurements behind both live in
`docs/JOURNAL.md` and never here.

| Layer | Path | Role | Write policy |
| --- | --- | --- | --- |
| Global memory | `AGENTS.md` (this file) | Overview, boundary, commands, rules, pitfalls, queue, pointers | Rewrite only when a rule, invariant or the boundary changes |
| Historical log | `docs/JOURNAL.md` | One dense line per action, oldest first | Append exactly one line; detail lives in the export, not the line |
| Active buffer | `.logs/scratchpad.md` | Current task, dense tool output, milestones | Reset to a stub after every action |
| Action exports | `.logs/action-<ISO-date>-<task>.md` | Atomic per-action summary | Written once, never edited, never tracked |

Protocol: read this file and the tail of `docs/JOURNAL.md` first; put dense
output in `.logs/scratchpad.md`, not in context and not in `docs/`; after an
action write the export, append ONE `docs/JOURNAL.md` line, reset the
scratchpad. A finished queue item is DELETED from §6, never ticked. Never
commit or push unprompted — a green battery is evidence, not consent.

## 0 · What this repository is

The `gsa` engine: a 13-crate Rust workspace (`crates/`) plus its fixtures
(`tests/`), diagnostics (`tools/`), contract and engine docs. One binary,
`gsa`, built with `cargo build --release` and installed as `/usr/bin/gsa` by
the `gsa-pm` recipe (a recipe, so it lives in `gsa-recipe`).

The recipe half lives in the **`gsa-recipe`** repository
(`https://github.com/ZhangDM-520/gsa-recipe`): `packages/` (`PKGBUILD`,
`.SRCINFO`, local assets), `config/topology.conf`,
`config/build-defaults.conf`, `config/abi-exclusions.conf`, `lib/` (shared
recipe modules), and the recipe fixtures. This repository holds none of it.
Its memory is that repository's own `AGENTS.md`; recipe policy — what a recipe
directory may hold, the ignore layers, the optimization playbook, trimming,
the PGO gate — is stated there and never restated here.

The boundary: the engine CONSUMES the recipe repository through the canonical
recipe store — a build-user working copy fetched from `recipe_url` (default
the recipe repository) and refreshed in place by `gsa -Sy`; the dev checkout
is read-only input, selected by `GSA_CONF`'s `project` key or by
`GSA_RECIPE_CHECKOUT` for the real-tree checks. Two repositories, one engine
binary. Editing a recipe checkout never changes what a build sees until the
store syncs; editing `crates/` never changes a recipe.

`docs/gsa-contract.md` is the authoritative interface and wins over every
other document, including this one. When they disagree, fix the document.

## 1 · Read before changing anything

| File | Role |
| --- | --- |
| `docs/gsa-contract.md` | **Authoritative.** Action-pass grammar (§B), selection (§C), hidden seams (§D), decision rows and the rc contract (§E), outcome vocabularies (§F), exit codes (§G), the `format: 2` run record (§H), failure policy (§I), state layout (§J), concurrency (§K), change control (§L) |
| `docs/architecture.md` | The crate split, scheduler invariants, the deep seams in plain terms, runtime state by owner |
| `docs/build-guide.md` | Operations: families, inspect/dry-run/build, installation semantics, skip/resume, version sync, privilege model, cleanup, environment surface, troubleshooting |
| `docs/portability.md` | Intensity profiles and their formulas, `GSA_*` overrides, CPU/ISA policy |
| `docs/gsa-fixture-migration.md` | Per-fixture inventory: what each fixture pins, KEEP vs REWRITE, what replaced each retired spelling |
| `docs/adr/` | The decision records — `README.md` indexes them; numbering starts at 0003 because 0001/0002 moved to the recipe repository with that half |
| `docs/adr/0003-run-record.md` | Why one record, three renderings, default-on machine block |
| `docs/adr/0004-prefetch-advisory.md` | Why fetch-ahead is advisory and makepkg stays the build-time gate |
| `docs/adr/0005-engine-owned-makepkg-conf.md` | Why the engine owns the makepkg configuration, the per-compiler bodies, the selection ladder and the identity digest |
| `CONTEXT.md` | Vocabulary: recipe, topology record, build-order edge, consumer expansion, lane, run record, continuation, deferral, decision row |
| `CONTRIBUTING.md` | What an engine change looks like, the validation block, the commit policy |
| `SECURITY.md` | Trust model, privilege boundary, what must never be committed |
| `docs/JOURNAL.md` | The chronological log — read the tail for what just changed; grep by date, never read end to end |
| `docs/plans/` | Archive-class design records cited by section from `crates/` and the contract — provenance, never specification (`README.md` is the index) |

## 2 · Commands

```sh
cargo build --release            # ./target/release/gsa
cargo test --workspace           # workspace tests (see the flake note)
cargo test -p gsa-sched          # one crate
cargo clippy                     # lint pass (clean at HEAD; `--all-targets` too)
tools/fmt.sh                     # rustfmt check (`--write`); `cargo fmt` is broken here
bash tests/run-all.sh            # the whole fixture battery, in parallel
bash tests/run-all.sh abi        # substring filter; a mismatch exits 2 (typo)
bash tests/run-all.sh --serial   # one at a time, for a flaky fixture
GSA_TEST_GSA_BIN=$PWD/target/debug/gsa bash tests/run-all.sh   # pre-install deviation
gsa --help                       # authoritative spelling roster, incl. environment inputs
```

Non-obvious, in order:

- **There is no CI, by decision.** The validation block in `CONTRIBUTING.md`
  is the gate and the maintainer runs it; do not propose a workflow, and never
  write "CI is green" in a document (2026-11-10).
- `tools/fmt.sh` is the formatting command. `cargo fmt` shells out to
  `cargo-fmt`, which aborts at startup on the 2026-11 nightly (glibc malloc
  assertion) while `rustfmt` itself is fine; the script calls it directly.
- `tests/run-all.sh` defaults to the INSTALLED `/usr/bin/gsa` (`command -v
  gsa`) and prints the binary and its owning package. That is the contract
  (§L.10); `GSA_TEST_GSA_BIN` is the explicit pre-install override and must be
  reported as a deviation, never passed off as a validated engine.
- `cargo test --workspace` runs two supervisor timing tests that are
  load-flaky under full parallelism. The flake is pre-existing and measured at
  HEAD — never a regression to chase. For a deterministic run:
  `cargo test --workspace -- --test-threads=1`.
- Fixtures are non-mutating and `$TMPDIR`-scoped, and the runner gives each
  fixture its own `GSA_BUILD_DIR`. A fixture that needs the real recipe tree
  reads `GSA_RECIPE_CHECKOUT` and SKIPs loudly when it is unset.
- Never use a real rebuild as a syntax check. A behavioural change to
  scheduling, install, state or signals needs a fixture in the same change.

### Fixture conventions

- `tests/lib/fixture-lib.bash` is the ONE synthesis/interface helper —
  sourced, never executed. `make_workspace DIR [lanes [jobs [intensity]]]`
  builds the complete workspace skeleton (the loader validates records, the
  roster, the graph and a full topological sort on EVERY invocation, so a
  fixture workspace must be complete or every run dies in the loader);
  `add_package DIR ID [extra-pkglines [group]]` adds one synthetic package
  (one-line PKGBUILD + its topology record `ID|packages/ID|GROUP|`; extra
  PKGBUILD lines are passed verbatim, never guessed); `set_topology_record DIR
  ID GROUPS [EDGES [TAGS]]` is the single writer for records that need
  multiple groups, edges or tags (replace-or-append); `stub_sudo`/`stub_pacman`/`stub_makepkg`/`stub_sleep` write the trivial
  byte-identical PATH stubs. A fixture section that exercises the frozen fish
  oracle installs it explicitly next to its scratch workspace with
  `install_fish_oracle` (the root shim was deleted 2026-11-09, so only that
  explicit call can supply it).
  `stub_sudo` is a passthrough that strips the
  builder's non-interactive flags (`-n`, `-v`, `--`) **and `--preserve-env`** —
  some hosts wrap `sudo` in a fish function that re-execs it as `command sudo
  --preserve-env …`, and a stub that chokes on that flag would fail every
  install fixture in the preflight probe. `stub_sleep` is the capped clock for
  SUT-side waits: numeric operands ≥ 0.4 s collapse to 0.05 s, shorter ones
  pass through untouched — install it only where no long sleep is a lease
  (`sleep 60 60<"$lock"`) or a measured duration (run-record's mid-build
  `sleep 3`, scheduler-core-solo's duration table). Oracle-shaped stubs (fake
  `date`, marker
  flipping, `-Qp`/`-Qi` answers, signal loggers) stay inline in the fixture
  that gives them meaning, as do assertions, `fail()` prefixes and the
  `( subshell )` section structure of multi-subject fixtures.
- `run_builder CMD…` is the capture helper: combined stdout+stderr in
  `FIXTURE_OUTPUT`, exit status in `FIXTURE_RC`, and it ALWAYS returns 0 — a
  failing builder is the fixture's data, not a reason to trip the fixture's
  own `set -e` — so assert on `$FIXTURE_RC` explicitly. `run_engine WORKSPACE
  ARG…` (`tests/lib/rr-v2.bash`) invokes the engine under test with the same
  capture contract — `gsa` by default, the frozen oracle under
  `GSA_TEST_ENGINE=fish`.
  `makepkg_printsrcinfo DIR` is `makepkg --printsrcinfo --dir` carrying
  `GIT_CONFIG_COUNT=0` (agent shells inject git config that breaks makepkg VCS
  operations). Both are plain bash functions and do not cross a process
  boundary on their own: a fixture running them inside `bash -c` workers must
  `export -f` them (`tests/srcinfo-freshness.sh` exports `check_recipe` and
  `makepkg_printsrcinfo` for exactly that reason).
- Every stub knob is named `GSA_FAKE_*` and is fixture-side only: read by the
  stub script, never by the engine (`GSA_FAKE_*` is not engine vocabulary,
  contract §D.2). The engine's real environment surface —
  its `GSA_*` inputs, the inherited environment that silently changes
  behaviour, and its outputs to recipes — is one list in `docs/build-guide.md`
  § Environment surface; check the input roster with `gsa --help`
  (contract §B.8) rather than counting names. A new fixture knob keeps the
  `GSA_FAKE_*` prefix (full table in the helper's header). (last reviewed
  2026-10-14)
- `tests/run-all.sh` discovers fixtures recursively (`find . -name '*.sh'`)
  and excludes `tests/assets/` (frozen reference material, never runs
  standalone) and `./lib/*`; the helper is `fixture-lib.bash` (`.bash`, not
  `.sh`) so discovery can never match it, and the `lib/` exclusion is defence
  in depth against a future `tests/lib/anything.sh` becoming a phantom
  fixture. Sibling subjects merge into ONE file as `( subshell )` sections
  rather than growing another top-level script.
- The run-record machine block (`format: 2`) is the assertion surface: the
  strict `rr2_body` parser and `rr2_*` accessors in
  `tests/lib/rr-v2.bash` extract it from stdin (the strict rules they enforce
  are contract §H.2; cutover gap G12 in §M). The
  parser is the interface under test. Prose WORDING is
  pinned in exactly ONE place, the rendering section of `tests/dashboard.sh`
  (cosmetic GEOMETRY — the `-Q` table, colour, width fitting, footer
  alignment — lives in `tests/rendering.sh`, rule 75); scenario-bound rendering
  pins (prompt layout, deferral label, sudo message frequency) stay co-located
  with the scenario they describe.
- `tests/project.sh` drives its topology commands through `run_engine`
  (`tests/lib/rr-v2.bash`), one runner for every gsa invocation. The fish-era
  parallel pre-executor and its `expected_invocations` self-scrape pin retired
  2026-10-28 with the fish argv they cached — a fixture that grows new
  commands adds `run_engine` calls and needs no inventory pin.
- Fixture assertions never pipe a producer into an early-exit `grep`
  (`printf '%s\n' "$VAR" | grep -q …`): under `pipefail`, contention can
  SIGPIPE the producer after `grep -q` matched, reddening a passing capture.
  Use `vgrep VALUE ARG…` (`tests/lib/rr-v2.bash`) for a value producer or
  `grep … < <(PRODUCER)` for a command producer (176 sites converted
  2026-10-15, JOURNAL same date). Privilege/drop assertions belong ONLY in
  `tests/gsa-privilege.sh` (real `sudo -n`, euid 0 observable): a fixture
  that stubs `sudo` cannot see the build-user drop, and a uid assertion there
  passes vacuously. Engine fixtures test the INSTALLED engine (contract
  §L.10 — `tests/run-all.sh` resolves `command -v gsa`, and the battery
  names the binary and its package so "tested X, shipped Y" cannot pass
  silently): during development set `GSA_TEST_GSA_BIN=$PWD/target/release/gsa`
  explicitly — the runner never prebuilds, so a stale `/usr/bin/gsa` makes
  the battery silently test OLD code (2026-11-01: two "fixture failures"
  were just the installed engine missing in-tree fixes). Never cargo-build
  a private engine tree per fixture (concurrent ~5 GiB trees once filled
  the 16 GiB `/tmp` tmpfs mid-battery). (last reviewed 2026-11-01)

## 3 · Architecture

Thirteen crates, one binary:

| Crate | One line |
| --- | --- |
| `gsa-model` | Core types: recipe identity, topology records, the `format: 2` run record and its machine rendering; config resolution (`resolve`, `resolve_opt`), privilege (`build_command`), layout (`build_layout_for_run`, `checkout_roots`), three-state reads (`read`) |
| `gsa-topo` | Strict loaders for `config/topology.conf`, `build-defaults.conf`, `abi-exclusions.conf`, user sets; the group roster and the `store_format` gate are stated here once |
| `gsa-recipe` | `.SRCINFO` parsing, strict read-only `PKGBUILD` scan, source classification, version sync and checksum anchoring, VCS freshness, toolchain identity |
| `gsa-graph` | Consumer expansion (reverse build-order closure), one topological sort with cycle refusal, coupled batches, `app-cluster` grouping |
| `gsa-sched` | Lane supervisor: intensity budgets, typed lane-result codec, dispatch state machine (core-solo, `build-tools` band, failure policy), signals, run lock, orphan sweeps, `progress::Progress` |
| `gsa-build` | makepkg orchestration: lane child entry, the argv/env contract (`MAKEPKG_BASE_ARGS`, `GSA_BUILD_JOBS`, `MAKEFLAGS`/`NINJAFLAGS` rewriting), the `PACMAN` shim, prune strength 1 |
| `gsa-install` | The one decision seam (`decide`), the fail-closed gates (PGO payload, ABI soname/consumer/stock-pinner), the `pacman -U` executor, dynamic IgnorePkg registration |
| `gsa-fetch` | Fetch-ahead through `makepkg --verifysource` as the only fetch/verify engine; the bounded prefetch window |
| `gsa-state` | Side-car state under the state root (binpkg index, run history, key-value), the write-time ownership gate, the canonical recipe store (fetch/refresh, `ensure_store`) |
| `gsa-qa` | Audit lint registry (`-Ma`, report-only) and install-refusing checks; the hidden `--qa-check` seam |
| `gsa-maint` | The `-M` surface: audit/doctor, IgnorePkg repair, log browse, shared mirrors, prune strengths, sets/world, run history |
| `gsa-abi` | Derived ABI tokens, `:=` subscription records, rebuild waves, the installed-ELF view, the install seam's refusal rows |
| `gsa-cli` | The binary: argv grammar (§B), selection (§C), the command surface and its renderings, `exit` (the one rc renderer), `help` (the one environment roster) |

**Ownership of topology and the recipe store.** Topology records, groups,
edges and tags are `gsa-recipe`'s data; this repository only reads them,
through `gsa -Qt` — nothing parses `config/` directly. The canonical store is
build-user working data (`GSA_RECIPES_DIR` > `recipe_dir` >
`<build-user-home>/.local/share/gsa/recipes`), never below the state root, and
`gsa -Sy` hard-resets it.

**Owners of runtime state.** Three, never mixed:

- the state root (`/var/lib/gsa`; `--state-dir` > `GSA_STATE_DIR` > config
  `state_dir`): root-owned engine state — `index/`, `abi/`, `world`,
  `sets/`, `runs/`, `logs/`, `locks/`, `toolchains/`, `abi-repair/`,
  `standalone/`, `recipes.last-fetch`;
- the build user's cache (`--build-dir` > `GSA_BUILD_DIR` > config
  `build_dir` > `<build-user-home>/.cache/gsa`): `build/`, `pkg/`, `pkgs/`
  from makepkg's `BUILDDIR`/`PKGDIR`/`PKGDEST`; `SRCDEST` stays
  `makepkg.conf`'s;
- the recipe store, build-user working data as above.

**Five invariants a change must not break.**

1. **Selection is mandatory.** A bare `gsa` is a usage error (rc 2); build
   order is meaningful, and plan, listing, record and range order are the one
   topological order.
2. **`-S` installs each package before its consumers compile** — through the
   single `pacman -U --noconfirm --ask 4` executor; a refused install aborts
   the run.
3. **Cone-stop is the default failure policy.** A failed package parks its
   transitive consumer cone (`parked waits-on-failed`) while dispatch
   continues outside it; the run exits 4 (`--fail-fast` stops dispatch: 1;
   deferral-only: 5; interrupt: 130 with the full record).
4. **One record, three renderings.** The run record (`format: 2`) is computed
   once; the dashboard is a projection of it (`gsa_sched::progress`), and the
   prose summary and the machine block are views. No rendering re-derives
   state.
5. **A typed refusal owes a record.** A refusal returns `Exit::Refuse` with
   `RecordOwed`; a `Yes` refusal already emitted the record and prints
   nothing more, a `No` refusal owns its note lines. No step invents an rc.

## 4 · Rules

**Rule map.** Numbers are the retired `docs/MEMORY.md` numbers, preserved
verbatim because ~190 code comments and contract §L.3 cite them by number — do
not renumber, and do not reuse a dropped number. Rules owned by the other repo
are pointers only, never restated here: `rule 3` (PKGBUILD validation), `4`
(provides), `5→14` (Qt coupling), `7` (in-progress builds), `8` (purged
tools), `14`, `15` (source verification), `16` (bulk `prepare()`), `17`
(recipes are public), `20′` (venv runtime paths — renumbered in `gsa-recipe`,
because 20 is the install seam here), `21` (group membership), `22` (fleet
reconciliation), `24` (one record per id), `28` (git-absent inputs), `29`
(swap leftovers), `30` (soname bookkeeping), `31` (`?signed` refs), `32`
(patch removal), `33` (dirty `$srcdir`), `34` (tool-materialized files), `36`
(stock ELF sweep), `37` (toolchain compile transitions), `39` (`mold`
opt-out), `40` (ccache double-wrap), `41`–`43`, `45`–`50`, `52` (consumer
edges), `53` (ccache probe), `55` (NEEDED consumers), `64` (Monday snapshot
pins), `70` (flag edit needs a clean tree) → `gsa-recipe` AGENTS.md.

Dropped: `35` (fish `(cd …)` leak — no live fish source), `38` (fish-era `$W`
sync — its surviving invariant, a semantic merge that preserves
`pkgver`/`pkgrel` marks, is folded into rule 63), `44` (superseded by the
`upstream-unverified` pitfall), `51` (its split example is retired, and the
rule is recipe-side). Merged: `5→14`, `38→63`, `62→73`, and the second `64`
(the `SRCDEST` env rung) `→73`. Collisions resolved: **20** stays with the
install decision seam, and the recipe venv rule is renumbered in `gsa-recipe`;
**35** and **64** have no engine claimant, so no renumbering debt crosses the
split.

1. **Cross-shell commands go through `bash -c '…'`.** fish has no `export`, no
   `[[ ]]`, 1-indexed arrays, and an unmatched glob is fatal even with
   `2>/dev/null` — use `find -name`. Aliases rewrite `ls`/`grep`/`rm`;
   `script(1) -qec` parses with `$SHELL`, so stage bash-only quoting in a
   script file. User-facing recipe commands are `gsa-recipe`'s half.

2. **Agent shells inject `safe.bareRepository=explicit`.** Prefix every
   bare-repo or makepkg VCS git command with `GIT_CONFIG_COUNT=0` — the engine
   already runs its own git calls that way. Without it, `?signed` tag checks
   report SIGNATURE NOT FOUND and git-lfs fetches exit 128, leaving an empty
   LFS store that extracts as `remote missing object`.

6. **Toolchain identity, not mtime, decides whether a build tree is
   reusable.** The per-recipe marker under the state root's `toolchains/` is
   `<family>|<compiler version line>|<sha256 of the effective makepkg
   config>` (the composite plus its site files' bytes), so a compiler upgrade AND a flag edit each change the identity
   and force the one-time clean — no manual purge. `gsa --build-identity
   gcc|clang` prints the value. Meson `--reconfigure`, `CMakeCache.txt`
   rewriting and `*.la` purging are `gsa-recipe`'s half.

9. **IgnorePkg registration is dynamic.** Each accepted archive's
   `pkgbase`/`pkgname` (`.PKGINFO`, else `.SRCINFO`, else PKGBUILD) enters the
   target `pacman.conf`'s `[options]` `IgnorePkg` at acceptance and before
   `pacman -U`; unresolvable names refuse the install. Never delete a held
   `db.lck`. Hatches: `--no-register-ignorepkg`, `gsa -Mi --backfill`
   (`--prune` drops stale entries). Verify with `pacman-conf IgnorePkg`.

10. **Every action leaves one journal line and one export.** Detail goes in
    `.logs/action-<date>-<task>.md`; `docs/JOURNAL.md` gets one dense line
    pointing at it. Never restate a rule or an incident in the journal, and
    never keep a finished queue item — delete it.

11. **`-S` installs each package immediately after its build**, through the
    one `pacman -U --noconfirm --ask 4` executor; a refused install aborts the
    run. Never build-then-install-collectively; `gsa -Ua` is the
    one-transaction hatch, never for interdependent sets. Checked installs skip
    identical-or-not-newer archives (`-Sf`/`-Uf` force); unknown version
    metadata refuses.

12. **Selection is mandatory.** A bare `gsa` is a usage error: pass `@group`
    and/or package refs. A selection expands to its transitive consumers;
    `--leaf` builds exactly the named recipes, so keep a consumer-bearing name
    leaf. ABI-coupled updates use `-S @core`. Add a build-order edge only after
    verifying it against `pacman -Qi` metadata and a build-order reason.
    `<id>-snapshot` is an INPUT alias, not a name: it resolves only for a
    recipe whose primary `source=()` entry carries `#commit=`, the refusal
    names the ref it tracks, and every record, listing and continuation prints
    the true `-git` id (contract §C.1).

13. **A coupled ABI batch moves whole.** The `abi=must` gate adds omitted
    members to the selection, and a solo install of a provide-moving provider
    refuses. LLVM snapshots have no stable C++ ABI, so `llvm-git` and the GPU
    stack travel together; the recipe half (rebuild set, stage0 recovery,
    resume with `--skip`) is `gsa-recipe`'s.

18. **Anchor every auto-updated value to an authority the builder did not
    produce.** Diff the *moved* sources, match them to the official
    `.SRCINFO`, refresh with staged `updpkgsums`. A published mismatch stops
    the run and restores; no published checksum is a disclosed fetch-only
    refresh; a recipe superset refuses. Only a `version-sync=nvchecker` tag
    selects an external provider.

19. **Runtime state is owned at WRITE time.** `gsa-state`'s gate chowns the
    state root and repairs owners before every open (`sudo -u touch` for
    missing files, never as root); an unprivileged read of an unopenable file
    quarantines it as `<path>.stale.<epoch>.<pid>` or fails — never truncate.
    Never rename a held pacman lock; root-owned state is correct state.

20. **One install decision, one seam.** `gsa-install::decide` computes the
    plan once as typed rows (`install`/`skip`/`refuse`/`noop`/`parked`); only
    the `pacman -U` executor transacts, and it never re-decides. Fail closed:
    an empty list refuses under `-S` (rc 1) and no-ops under `-Ua`; an archive
    from a `-fprofile-generate` recipe with a baked `.gcda`/`.profraw`
    destination refuses `pgo-*`. Assert through `--install-decide`, never
    scraped prose.

22. **Parallel work is reconciled by artifacts, never by trust.** Every
    agent writes its own file (`.logs/<lane>-*.md`); ONE writer merges, so no
    two lanes ever edit the same mutable file. A lane's report is an unverified
    assertion: re-run its gate or inspect the artifact before building on it,
    and send a verifier that is told to *falsify* the claim rather than admire
    the change.
23. **`--ask 4` auto-confirms removal, not safety.** The
    `ALPM_QUESTION_CONFLICT_PKG` consent lives in the plan rows. The plan
    refuses `.PKGINFO` provide drift before the force branch (`-Sf`/`-Uf`/
    `-Ua`), matched against the pkgname or its `abi_stock_name`; tier-1
    exposure is never excludable. `provides=`/`conflicts=` and
    `abi-exclusions.conf` rows are `gsa-recipe`'s.

25. **ABI closure guard, engine clauses.** (b) every `DT_NEEDED` resolves via
    a workspace provide, a base-system soname, an exclusions entry, or file
    truth; (c) link truth only (`abi_at_risk_stems`/`abi_links_stems`), never
    name or graph reachability, transitivity through `abi=` tags; (c2) waves
    strictly downstream; (d) never install a moving or removed soname with an
    uncovered linked consumer; (e) the post-install NEEDED probe aborts loudly
    and is file-backed; (g) the exposure audit maps provider → installed
    consumers; (h) refusing plans are pacman-free and an unreadable `.PKGINFO`
    is skipped, never probed; (j) fixture expectations derive from records,
    never pinned counts. Recipe clauses (a) bare soname provides, (f) the
    exclusions file, (i) promotion: `gsa-recipe`.

26. **Re-time `gsa -Sl` after every roster-size jump.** The loader validates
    every record, every edge and the complete sort on EVERY invocation, so
    roster growth is a listing-latency event. Never pin wall-times in
    fixtures — timing assertions block the perf work that removes the latency.
    Roster growth itself is `gsa-recipe`'s.

27. **Match archive filenames against the full `epoch:pkgver`**
    (`get_full_version`); a bare `pkgver` misses epoch archives, so an index
    row and its archive never join. The index key uses the same canonical form.
    Strict `=` pins and lib32 pkgrel bumps are `gsa-recipe`'s.

54. **A library the build links into the payload is a `depends` entry.** The
    engine guard is `gsa --qa-check declared-deps`, report-only, so assert its
    `clean` tail after regenerating `.SRCINFO`. A stem may be spelled `.so`
    only when the provider's provide is stamped. Declaration and spelling are
    `gsa-recipe`'s.

56. **Every non-interactive spawn passes `--noconfirm`.** makepkg's `-s`
    otherwise prompts and aborts rc 8 on missing makedepends
    (`MAKEPKG_BASE_ARGS` carries it), and `pacman -U` uses `--noconfirm
    --ask 4`. A hand-written build command in either repository owes the same
    flag.

57. **Build-domain spawns, layout resolution and tool-prose parsing each have
    ONE seam.** Spawns via `gsa_model::privilege::build_command` with HOME
    following the drop; layout via `build_layout_for_run()` (fatal, never a
    silent fallback); `create_owned_dir` chowns the ancestors it creates;
    `checkout_roots` scopes `<build_dir>/<pkgbase>/src`, `SRCDEST` only for ref
    recomputation; the makepkg configuration via
    `gsa_model::makepkg_conf::{render,install}` (one composite per family,
    `--config` on every spawn, never the host's `makepkg.conf`); tool prose
    under `LC_ALL=C`; the `PACMAN` shim quotes paths; fixtures fail closed
    with a per-fixture `GSA_BUILD_DIR` and `GSA_CONF_DIR` — the configuration
    guard is **exported** by `rr2_engine_argv` (the state/build/store guards
    stay per-invocation, because a fixture tests those ladders), so a fixture
    that builds its own env array for a direct engine call cannot silently read
    the host's `/etc/gsa` and take a surprise identity clean mid-run.

58. **A living doc teaches how to CHECK, never the shape of a retired era.**
    When a change moves a home or renames a spelling, update the doc; retired
    spellings survive only in contract §B.9's migration table. Volatile facts
    are dated or printed (`gsa -Sl`), never asserted in prose. `gsa-recipe`'s
    docs obey the same rule.

59. **A lane's signal receipt is load-bearing.** A lane spawns no makepkg
    under a pending signal and TERMs its makepkg on a mid-build receipt;
    unattributable teardown deaths in an interrupted run settle
    `interrupted-mid-build`. For an unwritable park marker
    (`park-marker-unwritable`) SIGKILL that lane's process group — never TERM,
    which reclassifies the outcome.

60. **Build-domain tools never write engine-owned state.** The store is
    build-user working data: `GSA_RECIPES_DIR` > `recipe_dir` >
    `<build-user-home>/.local/share/gsa/recipes`, never below `--state-dir`,
    and the engine chowns only the levels it creates. The state root stays
    root-owned (rule 19). `ensure_store` migrates a legacy `<state>/recipes`;
    both present → the resolved store wins; a move failure is fatal. Store
    content is `gsa-recipe`'s.

61. **Smoke checks and the fixture battery run the INSTALLED engine.**
    `tests/run-all.sh` defaults to `command -v gsa`, names the binary and its
    owning package, and `GSA_TEST_GSA_BIN` is the explicit pre-install
    deviation. A nested `target/*/gsa` build is never the smoke subject. Ship →
    `sudo gsa -Sy` → `sudo gsa -S gsa-pm` → validate what was installed.

63. **A version-sync rewrite is volatile store state.** `gsa -Sy` hard-resets
    the store (`fetch origin HEAD` + `reset --hard`), destroying the sync
    pass's uncommitted PKGBUILD/`.SRCINFO` rewrites; the sync itself applies
    only the semantic change the incoming commits make and never resets
    `pkgver`/`pkgrel` marks. Run one sync at a time, copy rewrites into the dev
    tree and commit them, and verify fetch-only sums with an independent
    download.

65. **A parallel writer turns measurement into noise — hash the inputs
    first.** When two identical runs disagree, suspect the inputs: `sha256sum`
    + `ls --time-style=full-iso` before theorizing, and record content hashes
    in every tree reconciliation. Exactly one writer per mutable tree; a pause
    means zero writes; a concurrent job's notes are self-reports.

66. **Link truth scopes to the moved provide ENTRY.** Match with
    `provide_covers` over `Drift.inst_ver`, ELF-class-scoped
    (`entry_class`/`path_class`), never a stem prefix. Installed PKGNAMES
    (split outputs) map to RECIPE IDS through contract §E.3 gap-G1
    `workspace_recipe_of_name`, or the row refuses. Fixtures use physical
    sonames (`libgreet.so.1`); the class lives in the provide version.

67. **The workspace resolution chain can silently shrink a run's roster.**
    `project` > the deprecated cwd walk (fixtures depend on it) > the canonical
    store. A stale store plans its own smaller roster and a gate failure then
    looks like a recipe bug. This repository has no workspace: real-tree checks
    read `GSA_RECIPE_CHECKOUT` and SKIP loudly (rc 0), never fail. Check
    `gsa -Qt | wc -l` against the store; never pin `project` in a fixture
    without `GSA_CONF`.

68. **A `:=` subscription record can outlive its consumer.** A subscriber that
    is neither topology-known nor installed is dead: skip it with a loud
    `abi-stale-record <provider> <consumer> dead-record` at both seams (build
    `wave_check`, `-U` `compute_swap`), never `refuse abi-consumer-uncovered`
    (that is installed-AND-unbuildable only). Fail closed on unreadable
    installed state (`installed: None`, never an empty view); check pkgnames
    and the canonical recipe id.

69. **A breaking soname move lands only as one atomic heal batch.** One
    `pacman -U` carrying the provider plus every rebuilt pinning consumer,
    dry-run first; a solo refusal is the discipline working. `install-refused`
    names only the FIRST reason, so probe the whole matrix read-only. Stock
    pinners obey the no-under-expand scope. `heal-batch-needed` and staged
    swaps remain unbuilt (contract §M gap).

71. **An unreadable file is not an absent one.** Never collapse the two with
    `if let Ok` or `unwrap_or_default`: that stands every gate down (a corrupt
    `.SRCINFO` disabled `partial-set`; an unreadable index let `-Mccc` claim
    success; an unopenable mutex blamed a concurrent run). Use
    `gsa_model::read::{required, optional}` and refuse on `Broken`; a `failed`
    row must reach the exit code.

72. **A live view is a PROJECTION of the run record.**
    `gsa_sched::progress::Progress` is the one fold (plan order plus settled
    rows); the dashboard renders it and `build.rs` asserts `drift()` is `None`
    after a run. A new view reads `Progress`; never add a counter that can
    disagree with the rows.

73. **One resolution ladder per setting, and it names the rung.** Build root,
    state root, recipe store and `SRCDEST` all resolve through
    `gsa_model::config::{resolve, resolve_opt}` with a provenance label, and
    `gsa_state::DEFAULT_STATE_ROOT` re-exports the model literal. A new setting
    adds a rung list to that ladder — never a second
    `if let Some(env) … if let Some(cfg)` chain, never a copied default.

74. **An early exit is a typed `Exit`; one renderer owns the code.**
    `gsa_cli::exit` owns the §G.1 mapping and prints only what a refusal still
    owes (`RecordOwed::Yes` owes nothing). Steps return
    `Err(Exit::Usage(..))`/`Err(Exit::Refuse(..))`, never `return 2` or
    `return 3`. Exceptions stay: the `--local-db-check` fence, `lib.rs` dispatch
    codes, `maint` row-derived refusals, `gsa-qa`.
75. **Colour is one seam, never in the machine channel, never the only
    signal.** Renderers ask `gsa-cli::style` for a ROLE (`Ok`/`Fail`/`Warn`/
    `Accent`/`Dim`/`Bold`/`Info`); a raw escape at a call site is the change to
    reject. The ladder is resolved once at dispatch (`--machine` → off; a
    captured stdout → the machine vocabulary, uncoloured; `--color=never` →
    off; `always` → the human rendering WITH colour, even through a pipe;
    `auto` → a terminal whose `TERM` is not `dumb`, with `NO_COLOR` unset —
    `NO_COLOR` is on the `ENV_INPUTS` roster but never `env-required`, because
    presentation is not a resume dependency). Width is VISIBLE width
    (`visible_width`, `fit`, `pad`, `pad_left`); the truncators
    (`truncate_middle`, `truncate_end`) take PLAIN text and say so with a
    debug assertion — paint after truncating. Every state keeps its word and
    glyph, so a `NO_COLOR` reader loses nothing. The machine rows (the record,
    the kv lines, the decision rows, `-Qb`'s wire row) are byte-stable; the
    human shapes — the `-Q` table, the `-Qg`/`-Sl` footers, `-Qi` wrapping —
    may change, and `tests/rendering.sh` is the one fixture that pins their
    geometry (prose WORDING stays pinned in `tests/dashboard.sh`).

## 5 · Pitfalls

One line per MECHANISM: the claim, then the tell or the fix. Dates,
measurements and incident narratives belong in `docs/JOURNAL.md`; an entry that
only restates a numbered rule belongs nowhere. Grouped by the surface it bites.

### Sources, refs and freshness

- **A source URL's scheme is makepkg's `get_protocol`, not a `<vcs>+` prefix**:
  the scheme is the text before `://` minus any `+`, so bare `git://` is a git
  checkout exactly like `git+https://`. One derivation —
  `freshness::scheme_vcs`; `classify_source` only adds Remote-vs-Vcs.
- **Self-consistent is not verified**: a pkgver bump without refreshed sums, or
  `--skipchecksums` behind a quiet flag, is disclosure, not anchoring. Anchor
  against the official `.SRCINFO` (`updpkgsums`, verify) or refuse; DEFER when
  no official document exists.
- **Matching a source to its checksum needs makepkg's own three rules**: sums
  line up only within one algorithm (take the first contiguous same-algorithm
  run; its length must equal the source list, else fail closed); the fetched
  filename is the `name::url` override first, not the URL basename; and a VCS
  source's sum is a git-archive hash, so mirror with `git clone --bare` — a
  `--filter=blob:none` mirror renders `export-subst` differently.
- **`SIGNATURE NOT FOUND` on a `?signed` git source is usually the
  environment**: the injected `GIT_CONFIG_COUNT` hardening makes a bare cache
  unusable (`fatal: cannot use bare repository`) and a full `$TMPDIR` kills gpg
  status writes. Discriminate with `GIT_CONFIG_COUNT=0 git -C ~/.gsa-src/<pkg>
  verify-tag <tag>`.
- **mtime over-reports staleness**: a content-identical rewrite flags the tree.
  Judge by content and commit time plus pkgver-vs-archive-name.
- **VCS `--skip` freshness covers every declared ref**: skip only when each ref
  resolves to the revision recorded for that archive; an unanswerable ref (6
  attempts, 2/5/10/20/40 s) PARKS the recipe — lane rc 99, `upstream-unverified`.
- **The VCS baseline is read from the build's `$srcdir` working copy**, then the
  package root, then an exported `SRCDEST` — never the reverse: a mirror carries
  the default HEAD, not the built ref.
- **A pkgrel floor is unsound on version-synced recipes**: the provider resets
  `pkgrel=1` on a pkgver advance, so pin the fix's content greps, never `>= N`.

### Store, workspace and builders

- **`gsa -Sy` refreshes only when the resolved workspace IS the store**
  (`sync_phase` compares `root == store`): from a repo cwd it refreshes nothing,
  so a pushed fix stays invisible to builds. Run it from a neutral cwd and
  verify the store's own `git log -1`.
- **makepkg WRITES the recipe it touches, and a run writes its workspace**:
  `--nobuild` rewrites `pkgver=` in place and fetch-side rewriting is
  workspace-local — against the git tree it dirties every PKGBUILD the run
  touches and leaves `.SRCINFO` stale. Sweep in a COPY (a global `SRCDEST`
  keeps the cache shared) or from the store; regenerate `.SRCINFO` for
  everything a run touched.
- **Scratch inside the repository is doubly corrupting**: cwd discovery answers
  with the real topology and a sync fixture rewrites real recipes. Keep it
  outside the tree and outside `/tmp`; the engine refuses a `TMPDIR` inside it.
- **A twin sync must cover `config/`, and a `--leaf` selection its members'
  unmet HOUSE prerequisites** — otherwise an edge fix sorts wrongly and makepkg
  installs STOCK replacements. Include the unmet prereqs or use a group run.
- **Moving `SRCDEST` strands `objects/info/alternates`**: older working copies
  hard-fail at "Creating working copy". Sweep
  `grep -rl "\.cache/gsa-src" $BUILD --include=alternates` and redirect each.
- **Every path crossing into the makepkg child must be absolute**: makepkg runs
  with the recipe's cwd, so a relative `--state-dir` yields
  `PACMAN=.state/locks/pacman-shim` and `makepkg -sf` dies "An unknown error has
  occurred."
- **A config file beats the environment inside makepkg**: `--config` makes
  makepkg skip its own layering, so the generated composite must end by
  re-asserting `BUILDDIR`/`PKGDIR`/`PKGDEST`/`SRCDEST` from `GSA_LANE_*` and
  the job flags last — a site file that sets them would otherwise own the
  build cache again. The composite must never `source` `gsa.conf` (it is the
  engine's `key = value` file, not shell: sourcing it prints
  `build_dir: command not found` into every lane log), and
  `makepkg --verifysource` needs the same `--config` or a fetch writes into a
  different source cache than the build reads.
- **makepkg source-cache mechanics**: it rejects a mirror whose origin URL
  differs ("is not a clone of"), re-fetches every build, leaves `<file>.part` on
  a partial download (servers without byte ranges then fail — delete it, `curl
  --retry`), and a config-changing retry must wipe the build workspace.

### Install, ABI and the record

- **A completeness check must not bless the empty set**: `missing.is_empty()`
  over an empty expectation reads as "all covered". Zero archives is always
  `nothing-built` → build.
- **A cache glob `name-*.pkg.tar.*` matches detached `.sig` files and
  prefix-twin names** (`linux-cachyos` vs `linux-cachyos-headers-*`). Whitelist
  the real extensions and reconstruct the name by right-split; never make a
  check-transport failure fatal.
- **A drifted soname provide refuses at install PER SE**: `abi-soname` is
  unconditional (contract §M). `--leaf` suppresses selection expansion, not the
  record-mismatch wave closure, `--skip-built` still forces wave providers to
  rebuild, and `--no-deps` is the retired `--leaf`.
- **An `-S` plan drags the consumer wave of every selected provider whose newest
  token ≠ its `:=` records** (missing records engage the whole-closure
  fallback; waves merge). Exclude wave TRIGGERS to keep heavy toolchains out —
  suppressing members parks at the ABI gate.
- **A version-sync that moves a SONAME is a decision, not a build**:
  `abi-soname` refuses unconditionally and run-level (rc 3). Compare `.PKGINFO`
  provides with installed first, then land `pacman -U --assume-installed
  <old-provide>` plus an engine re-bless.
- **The install gate halts at the first miss, so one run sizes one offender** —
  expect a wall per peel. Census the artifact (`tar -tf`, `readelf -d` of every
  `*.node`/`*.so`) and strip the whole class.
- **A lib census is host ∪ shipped, by exact path**: private libs the package
  itself ships (`RUNPATH $ORIGIN` natives) resolve nothing until the gate
  consults `ShippedBytes::ships`, and `DT_NEEDED` records a PATH for a
  SONAME-less DSO linked by absolute path, so map NEEDED→package by exact
  owned/shipped paths, never basenames (`install_needed_probe`;
  `tests/abi-postinstall-probe.sh` I/J).
- **An `-S` of an LLVM-ABI provider replaces SONAMEs the LIVE GUI stack
  dlopens**: stock mesa dlopening `libLLVM.so.NN` under a house `llvm-libs-git`
  is a black desktop and a hard freeze. Stop the GUI; a black screen is first a
  `libLLVM*` check.
- **alpm hook input is names on stdin, a local-file `-U` is skipped, and a
  failing hook does NOT abort without `AbortOnFail`**: `NeedsTargets` gives one
  name per line (no argv), `Operation =` one line per value, the transaction
  kind comes from argv ancestry — and pacman logs `error: command failed to
  execute correctly` and commits anyway. Probe gates at transaction level.
- **A transaction gate's attribution must be free on the clean path and the
  loader cache must be indexed, not rescanned**: a fatal line that only names
  the symptom is half a finding — say WHOSE package is behind it (the
  `abi-need-check` summary reads `<stem>=` out of the side-car `binpkg.jsonl`
  in one pass, names only, nothing read when there are no findings, never a
  `gsa`/`pacman` spawn). And `ldconfig -p` is ~5.8k rows: build the map once
  (103 ms per miss against 0.2 ms when the old loop rescanned per soname — a
  100-miss payload went 9.25 s → 0.62 s).
- **A multi-output index instance is a SET of per-output token rows, and a `-`
  token is NO token**: a fold keyed `(recipe_id, instance)` keeps only the last
  output, so every split rebuild reads as a token move and every placeholder as
  a mismatch. One verdict: `gsa_abi::records_moved`.
- **Binpkg index rows share one `PKGDEST` path across same-version rebuilds**:
  retention deletes only files no surviving row references, and an `abi-repair`
  marker is consumed only by its own recipe's install.
- **IgnorePkg closure drifts short with every addition**: registration is
  dynamic (rule 9), so an install run registers accepted archives itself. Keep
  the diff empty; back up `/etc/pacman.conf` first.
- **The resume suggestion must include the failed package** — the resume line
  and its remaining count once excluded it (`tests/resume-command.sh` pins it).
- **A fourth derivation always drifts — make the second one a projection**: the
  dashboard is a `Progress` fold, the roots resolve through
  `config::resolve` with provenance, an early exit is a typed `Exit` behind one
  renderer (rules 72–74).

### Signals, lanes and runs

- **A signal storm corrupts what it kills**: one TERM per group, one 30 s
  grace, one logged SIGKILL (a TERM every 50 ms left `db.lck` behind); a stale
  lock needs two idle probes 1 s apart, and lane pacman shares one flock. A run
  killed mid-transaction leaves `local/<pkg>-<ver>/` without `desc`/`files`,
  and `invalid or corrupted package` then indicts the LOCAL db — repair by
  entry removal plus `pacman -U` (`--overwrite '*'` for orphans), seam
  `--local-db-check <path>`.
- **A lane records its own death**: `dispatcher.log` gets `signal:`, and the
  lane writes an honest 129/130/143 before re-raising. rc=125 with no bytes is
  a lost race — the reap re-reads the result file.
- **A build attached to a terminal scope dies with that terminal**: a
  compositor/protocol error stops the scope and SIGTERMs every descendant
  (`interrupted-mid-build`, rc 143), with no OOM behind it. Launch detached;
  progress truth is `<state>/runs/<id>/*.result`.
- **Queued lanes that never start are the core-run-alone invariant, not a
  stall**: a `core` member waits for an idle machine and blocks dispatch, and
  consumers chain behind prerequisites. Read the group column and
  `machine.rs::can_dispatch`.
- **A swap window breaks children in ways that look like recipe bugs**: a child
  spawned during `pacman -U` dies in the loader (`error while loading shared
  libraries`); a lane starting `makepkg` while house `pacman` replaces
  `/usr/share/makepkg/*` dies on `util.sh: No such file`; snap-pac's pre-hook
  fails 127 until the post-hook succeeds (its `Command failed: snapper …`
  notification is filterable while `db.lck` exists). Transient: verify the
  toolchain and resume, never fix the victim.
- **`gsa -S --leaf` can be hijacked wholesale by the GCC identity gate**: after
  a compiler-identity change a leaf run dispatches the toolchain block and
  unrelated lanes. Until fixed, recipe one-offs use plain `makepkg`
  (`GIT_CONFIG_COUNT=0`, `PKGDEST` outside the repo) plus one `pacman -U`.

### Build cache and disk

- **The path is not the filesystem — a mount can be stale or phantom**:
  `mountpoint -q` passes on a stale mount of an OFFLINE device (`mkdir` returns
  EIO while reads come from page cache); an unmounted drive's writes land in
  `/run`/`/tmp` until ENOSPC reads as "No space left" with no disk error; an
  automount can vanish silently (the linker dies SIGBUS); a dropped dock leaves
  `build_dir` as a tmpfs impostor whose writes "succeed" until ENOSPC and gpg
  dies. Tell: `df <path>` answers the PARENT or `tmpfs /run`. Guard with the
  real operation (`mkdir -p … 2>/dev/null`), never with `mountpoint`.
- **A deny-list and a delete-list are the same list**: the root archive set and
  the cleanup matcher drift apart otherwise (36 MB of upstream archives once
  got committed). One list — `gsa-maint/src/prune.rs` `download_patterns` —
  cross-checked in both directions by `tests/cleanup-extensions.sh`.
- **A completed build dir is not free disk**: downstream builds embed
  build-internals paths, so prune only trees with no pending consumers.
- **An in-flight prune keep-list comes from live PIDs, never lane names**: the
  build-dir name can differ from the package id (`build/zen-browser` vs lane
  `zen-browser-pgo`). Resolve keep-paths via
  `ls -l /proc/<makepkg-pid>/cwd`.

### Fixtures

- **Re-contract a needle from a captured sample, never from memory of the
  message**: `output::squash` maps whitespace runs to `_` and keeps punctuation
  verbatim. Capture first, paste the needle.
- **A no-message event must render nothing, not an empty line**: a `{line}\n`
  frame turns "renders nothing" into a stray blank per tick in machine streams.
  Return `String::new()` before the frame and pin the empty string.
- **Check which vocabulary a captured fixture file carries before
  re-contracting its needles**: an anchor in the wrong vocabulary matches
  nothing and `set -e` exits green over zero lines. Sweep WHO produces each
  captured file.
- **Fixture stub argv shapes ARE the contract**: a helper is safe only when the
  forked argv is char-for-char identical (adding `--` to `pacman -Q NAME` once
  disabled the ABI-batch refusal). Probe oracles stay separator-agnostic
  (`OP [--] NAME`).
- **Fixture scale pins are probe/CALL counts and EVENT waits, never
  wall-clock**: wait on a marker or a log line; a `sleep 1.5` races the
  pre-dispatch phase under parallelism.
- **A fixture pacman oracle counts TRANSACTIONS, never invocations**: the
  toolchain preflight's read-only `pacman -Q rust-git` probe runs on every
  build-family run — assert on `pacman -U` lines or tolerate exactly that line.
- **The parallel battery makes two things contractual**: every fixture is
  parallel-safe (non-mutating, `$TMPDIR`-scoped, assertions scoped to its own
  `$fixture`), and sibling subjects merge into ONE file as `( subshell )`
  sections. `_LANE_STOP_GRACE_S` is internal, never a `GSA_*` input.
- **The battery is unsafe beside a live `-S`/`-Ua`**: install preflights read
  the REAL `db.lck`, so a live `pacman -U` makes fixtures refuse. Run batteries
  between builds.
- **User-level fish wrapper functions intercept the battery's PATH stubs**: fish
  autoloads `$fish_function_path` before PATH, so a user `sudo` wrapper shadows
  the stub. Never set `fish_function_path=/nonexistent-fp` — fish imports it as
  one element and drops every function directory.
- **GNU tar emits byte-identical archives for same-content repeats within one
  second**: a fixture modelling "replaced bytes" must change the payload.
- **Tree exclusions in `find` are `-prune`, never `-not -path`**: the latter
  filters output only and the sweep descends every `src/`/`pkg/`/`build/`
  (`tests/log-ownership.sh` §1b pins it).
- **A diagnostic on captured stdout is swallowed**: write it to stderr. A typo
  is never auto-corrected (≤3 candidates); a range indexes the SELECTION, not
  the whole set.

## 6 · Queued

- **Snapshot pins in `@core`/`@build-tools` (QUEUED for the owner's weekend
  full rebuild, opened 2026-11-09).**
  136 recipes whose source ref moves (113 floating + 23 `#branch=`-pinned) take
  `#commit=` = the last commit at or before Monday 00:00 UTC. **Nothing is
  renamed**: the recipe, its `pkgname`s and its `provides=` stay `-git`, so
  pacman, topology, IgnorePkg and the index see no move at all. The snapshot
  name is a FRONTEND surface — `gsa` accepts `<id>-snapshot` as an input alias
  for a pinned `<id>` (rc 2, naming the ref, when it is not one) — and that
  engine half (W0) LANDED 2026-11-09 (`select::resolve_snapshot_alias`, contract
  §C.1, `tests/project.sh` §9). The `-Sy` provider that advances the pins (W5)
  is the remaining engine work and lands LAST, after the recipe waves.
  State: W1 (64 fan-out ≤ 4 trackers) is PINNED with fresh `.SRCINFO` but not
  built and not installed — the owner deferred every real build to the weekend
  campaign ("do not do real build test, i am not ready"), so archives from the
  discarded validation pass are stale and untrusted. W2–W4 (72 recipes) are
  unpinned. `gsa-pm` stays exempt. Reconciliation and waves: the recipe
  repository's `docs/snapshot-expansion.md` §8.
  Blocked on: the owner's weekend rebuild (build + install W1, then W2–W4).

## 7 · Environment and shell boundaries

- **The login shell is fish; agent tool calls run in bash.** A command handed
  to the user, or `!cmd`, runs under fish — wrap ad-hoc one-liners in
  `bash -c '…'`. In a fish context there is no `export`, no `[[ ]]`, arrays
  are 1-indexed, an unmatched glob is fatal (`2>/dev/null` does not suppress
  it), and host aliases change bare names (`ls` → `eza -al`,
  `grep --color=auto`).
- **`rm` is a trash wrapper in the login shell.** It moves targets to
  `~/.local/share/Trash`, ignores `-r`/`-R`/`-d`, and refuses `/` and `$HOME`
  — so "cleanup worked" while leaving everything behind. Use `command rm` or
  `find -delete` in any script the host runs.
- **Agent shells inject git config** (`safe.bareRepository=explicit`, …) that
  breaks bare-repo and makepkg VCS operations: prefix those with
  `GIT_CONFIG_COUNT=0`. The engine already runs its own git calls that way, so
  a failure here is always a hand-run command.
- **The engine environment roster is `gsa --help`'s environment section**,
  whose single source of truth is `help::ENV_INPUTS` filtered against contract
  §B.8. Do not copy the variable list into a document — it changes, and a copy
  rots. A flag beats its env twin; `GSA_BUILD_JOBS` is engine OUTPUT, never an
  input.
- **A fixture-only knob carries the `_GSA_` prefix and is never a `GSA_`
  input.** Stub behaviour is driven through `GSA_FAKE_*` (§D.2); a new scenario
  is expressed with a stub, never with a new engine knob.
- **`SRCDEST` is makepkg's, not the engine's.** It resolves environment > the
  build user's `~/.makepkg.conf` > `/etc/makepkg.conf`, and `sudo` carries the
  invoking shell's environment — so never export it. Probe: `env | grep
  SRCDEST` must be empty; a session predating the fix needs `env -u SRCDEST`.
- **Never run two heavy builds at once.** The failure mode is an OOM, not a
  queue. Check for running `makepkg` processes and runtime-log mtime changes
  before rebuilding anything that may already be in flight, and keep the
  battery out of a live `-S`/`-Ua` run's window.
