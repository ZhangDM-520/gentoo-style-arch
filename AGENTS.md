# AGENTS.md — engine memory & entry point

Last reviewed: 2026-11-09. This file is the engine repository's whole memory:
overview, rules, pitfalls, queue, pointers. It holds the rule text; the
history lives in `docs/JOURNAL.md` and never here.

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

The recipe half lives in the **`gsa-recipe`** repository: `packages/`
(`PKGBUILD`, `.SRCINFO`, local assets), `config/topology.conf`,
`config/build-defaults.conf`, `config/abi-exclusions.conf`, `lib/` (shared
recipe modules), and the recipe fixtures. This repository holds none of it.

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
| `docs/adr/0003-run-record.md` | Why one record, three renderings, default-on machine block |
| `docs/adr/0004-prefetch-advisory.md` | Why fetch-ahead is advisory and makepkg stays the build-time gate |
| `CONTEXT.md` | Vocabulary: recipe, topology record, build-order edge, consumer expansion, lane, run record, continuation, deferral, decision row |
| `CONTRIBUTING.md` | Change hygiene, validation standard, commit policy, trimming standard |
| `SECURITY.md` | Trust model, privilege boundary, what must never be committed |
| `docs/JOURNAL.md` | The chronological log — read the tail for what just changed; grep by date, never read end to end |

## 2 · Commands

```sh
cargo build --release            # ./target/release/gsa
cargo test --workspace           # workspace tests (see the flake note)
cargo test -p gsa-sched          # one crate
cargo clippy                     # lint pass
bash tests/run-all.sh            # the whole fixture battery, in parallel
bash tests/run-all.sh abi        # substring filter; a mismatch exits 2 (typo)
bash tests/run-all.sh --serial   # one at a time, for a flaky fixture
GSA_TEST_GSA_BIN=$PWD/target/debug/gsa bash tests/run-all.sh   # pre-install deviation
gsa --help                       # authoritative spelling roster, incl. environment inputs
```

Non-obvious, in order:

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
  `install_fish_oracle` (the root shim is never picked up by accident).
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
  parser is the interface under test. Prose output is
  pinned in exactly ONE place, the rendering section of `tests/dashboard.sh`;
  scenario-bound rendering pins (prompt layout, deferral label, sudo message
  frequency) stay co-located with the scenario they describe.
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
   reusable.** A flag edit leaves `<build_dir>/{build,pkg,tmp}` stale until the
   per-recipe identity under the state root's `toolchains/` changes (queued: a
   flags digest). Purge that tree after any flag edit. Meson `--reconfigure`,
   `CMakeCache.txt` rewriting and `*.la` purging are `gsa-recipe`'s half.

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
    recomputation; tool prose under `LC_ALL=C`; the `PACMAN` shim quotes
    paths; fixtures fail closed with a per-fixture `GSA_BUILD_DIR`.

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

## 5 · Pitfalls

- **An unreadable read is not an absent one — and a `failed` row must reach the
  exit code** (2026-11-08): the wave that landed rule 71 across discovery, QA,
  doctor — the `-Syu` refusal through `refuse_before_dispatch`, the fail-closed
  ABI wave gate, `lane-wait-failed` teardown, `MutexError::{Busy,Unopenable}`,
  one `help::ENV_INPUTS` roster, `_GSA_` fixture knobs.
- **A fourth derivation always drifts — make the second one a projection**
  (2026-11-09): the wave that landed rules 72–74 — the dashboard folded onto
  `gsa_sched::progress::Progress`, four root ladders collapsed onto
  `gsa-model::config::resolve` with provenance, every `return 2`/`return 3` in
  `gsa-cli` turned into a typed `Exit` behind one renderer.
- **A multi-output index instance is a SET of per-output token rows, and a `-`
  token is NO token** (2026-11-03): a fold keyed `(recipe_id, instance)` kept
  only the last output, so every split rebuild read as a token move and 306
  placeholders as mismatches. One verdict: `gsa_abi::records_moved`.
- **Re-contract a needle from a captured engine sample, never from memory of
  the message** (2026-10-23): a guessed literal carried parens the squashed
  text lacks. `output::squash` turns whitespace runs into `_` and keeps
  punctuation verbatim. Capture first, paste the needle.
- **A `{line}\n` frame wrapper turns "this event renders nothing" into a stray
  blank line** (2026-10-23, `SupEvent::Tick`): one bare `\n` per second into
  machine streams. A no-message event returns `String::new()` before the frame,
  and the pin asserts the EMPTY string.
- **Check which vocabulary a captured fixture file carries before
  re-contracting its needles** (2026-10-23, `app-group.sh`): `order_seq`/
  `order_pairs` parse fish PTY sections; flipped anchors matched nothing and
  `set -e` exited green over zero lines. Sweep WHO produces each captured file.
- **Fixture or build scratch inside the repository is doubly corrupting**
  (2026-10-23, `TMPDIR=$PWD/.battery-tmp`): cwd discovery answered with the
  real topology and a sync fixture rewrote real recipes. Keep scratch outside
  the tree and outside `/tmp`; the engine refuses a `TMPDIR` inside the
  repository.
- **A cache glob `name-*.pkg.tar.*` matches detached `.sig` files and
  prefix-twin names** (2026-10-22): a `.sig` won newest-wins and aborted a
  50-package upgrade; `linux-cachyos` globbed `linux-cachyos-headers-*`.
  Whitelist the real extensions, reconstruct
  `<pkgname>-<pkgver>-<pkgrel>-<arch>` by right-split, never make a
  check-transport failure fatal.
- **`mountpoint -q` passes on a stale mount of an OFFLINE device — probe a
  write** (2026-10-22): reads served from page cache while `mkdir` returned
  EIO, and a `mountpoint`-guarded conf exported a dead `TMPDIR`. Guard with the
  actual operation (`mkdir -p … 2>/dev/null`) and fall through.
- **A build path can silently be a tmpfs shadow** (2026-10-21): an unmounted
  drive leaves an empty mountpoint and writes land in `/run` or `/tmp` until
  ENOSPC, reported as "No space left" with no disk error. Check the filesystem
  behind the path (`df -h`, `mountpoint -q <mount-root>`), not the path.
- **`gsa -Sy` refreshes only when the resolved workspace IS the store**
  (2026-10-21): with a repo cwd it refreshes nothing (`sync_phase` compares
  `root == store`). Run `sudo gsa -Sy` from a neutral cwd, then verify
  `git -C ~/.local/share/gsa/recipes log --oneline -1`.
- **A build run whose workspace is the git tree rewrites the git tree**
  (2026-10-19): fetch-side `pkgver()` rewriting is workspace-local by design;
  against the repo it dirtied 544 PKGBUILDs and left `.SRCINFO` stale, so
  `srcinfo-freshness` failed. Clean with `git checkout -- <PKGBUILDs>` or run
  from the store.
- **A child spawned inside a `pacman -U` library-replacement window can die in
  the dynamic loader** (2026-10-19, gdb during the libselinux swap): `mv: error
  while loading shared libraries: libselinux.so.1`. Transient and
  self-healing — retry the recipe, never "fix" it.
- **A pushed engine or recipe fix is invisible to builds until the canonical
  store syncs** (2026-10-19): builds read the store, so the order is commit →
  push → `sudo gsa -Sy` → resume.
- **A `Command failed: snapper …` notification during a run is a loader-window
  artifact** (2026-10-19): snap-pac's pre-hook snapshot dies (exit 127) while a
  swap replaces the library, until the post-hook succeeds. Filter at the
  notifier while `/var/lib/pacman/db.lck` exists.
- **A completeness check must not bless the empty set — test emptiness before
  coverage** (2026-10-18, the `--skip-built` phantom): `missing.is_empty()`
  read as "every output covered" over an empty expectation. Zero archives is
  always `nothing-built` → build.
- **Budget scalars are integers and a run record is one row per subject**
  (2026-10-14): the strict `format: 2` parser rejects `lanes: -` and duplicate
  `order:` entries. Cite contract §H.2, not this entry.
- **`--leaf=no`/`--leaf=yes` are not replayable spellings** (2026-10-14): a
  continuation mirrors `--leaf` only in its true form — absence IS the negation
  (§B.8). Code truth: `gsa-cli/src/record.rs` (`mirror_flags`/`NOT_MIRRORED`);
  any `--leaf=<value>` is rc 2 naming the flag.
- **An amendment claiming "fixtures pin them" must name one that does**
  (2026-10-28, T6/T9): §H.3 listed signal keys nothing emitted, while two
  genuinely pinned keys were missing. A reason key is emitted-or-it-is-not,
  never "planned".
- **A fixture pacman oracle must count TRANSACTIONS, never invocations**
  (2026-10-14): the toolchain preflight's read-only `pacman -Q rust-git` probe
  runs on every build-family run. Assert on `pacman -U` lines, or tolerate
  exactly the probe line.
- **GNU tar emits byte-identical archives for same-content repeats within one
  second** (2026-10-14): a fixture modelling "replaced bytes" must change the
  payload — `tar --zstd` of a regenerated `.PKGINFO` gave equal sha256 twice.
- **Paths handed to makepkg must be absolute** (2026-10-14): makepkg runs with
  the recipe's cwd, so a relative `--state-dir` gave it
  `PACMAN=.state/locks/pacman-shim` and `makepkg -sf` died "An unknown error
  has occurred." Absolutise every path crossing into the makepkg child.
- **Binpkg index rows share one `PKGDEST` path across same-version rebuilds**
  (2026-10-14): retention may delete only a file no surviving row references,
  and an `abi-repair` marker is consumed only by the marked recipe's own
  successful install.
- **A `$W` twin sync must cover `config/`, and a `--leaf` selection its
  members' unmet HOUSE prerequisites** (2026-10-09): an edge fix sorted wrongly
  because `topology.conf` was never copied; a `--leaf` set omitting
  `qt6-quick3d` let makepkg install STOCK replacements. Include unmet house
  prereqs or use a group run.
- **An `-S` install of an LLVM-ABI provider replaces the SONAMEs the LIVE mesa
  stack dlopens** (2026-10-07): a house `llvm-libs-git` swapped
  `libLLVM.so.23.1` under stock mesa — black desktop, hard freeze. Stop the
  GUI or accept a session restart; a black screen is first a `libLLVM*` check.
- **`DT_NEEDED` has a path form** (2026-10-10): a SONAME-less DSO linked by
  absolute path records the PATH, so NEEDED→package mapping matches exact
  owned/shipped paths, never basenames. `install_needed_probe` does; pinned by
  `tests/abi-postinstall-probe.sh` cases I/J.
- **`makepkg` is a WRITER of the recipe it touches** (2026-10-06): `--nobuild`
  still runs `pkgver()` and rewrites `pkgver=` in place, so a "read-only"
  screening sweep dirtied 12 tracked PKGBUILDs and red-legged
  `srcinfo-freshness`. Run any makepkg-shelling sweep in a recipe-dir COPY
  (a global `SRCDEST` keeps the cache shared).
- **The fixture battery is unsafe beside a live `-S`/`-Ua` install run**
  (2026-10-06): install preflights read the REAL `/var/lib/pacman/db.lck`, so
  a live `sudo pacman -U` makes fixtures refuse and install fixtures go red.
  Run batteries between builds.
- **A pkgrel floor is unsound on version-synced recipes** (2026-10-06): the
  provider resets `pkgrel=1` when it advances pkgver (`sync.rs`
  `new_pkgrel`), so `pkgrel >= N` ratchets break on the next advance. Pin the
  fix's content greps, never its release number.
- **Fixture stub argv shapes ARE the contract** (2026-10-05): a helper is safe
  only when the forked argv is char-for-char identical — adding `--` to
  `pacman -Q NAME` silently disabled the ABI-batch refusal path. Probe-count
  oracles must be separator-agnostic (`OP [--] NAME`).
- **Fixture scale pins are probe/CALL counts, never wall-clock** (2026-10-05):
  a step that must follow a phase start waits on an EVENT (marker file, log
  line), never a sleep — a `sleep 1.5` raced the pre-dispatch phase under
  battery parallelism.
- **The resume suggestion must include the failed package** (2026-09-26): the
  "To resume, run:" line and its "Remaining" count both excluded it, leaving
  it stale while dependents built against stale installed copies.
  `tests/resume-command.sh` pins it.
- **mtime alone over-reports recipe staleness** (2026-09-26): a
  PKGBUILD-vs-archive mtime comparison flagged much of the tree after a
  content-identical rewrite; the content-aware audit (last commit touching the
  PKGBUILD vs newest archive, plus pkgver-vs-archive-name) showed none. Judge
  by content and commit time.
- **VCS `--skip` freshness includes each declared source ref** (2026-10-01):
  after the mtime gate, skip only when every declared ref resolves to the
  revision recorded for that archive; an unanswerable ref (6 attempts,
  2/5/10/20/40 s) PARKS the recipe — lane rc 99, `upstream-unverified`.
- **The recorded VCS baseline is read from the build's `$srcdir` working
  copy** (2026-10-02): `vcs_source_checkout` probes
  `<recipe>/src/<name{,.git-stripped}>`, then the package root, then an
  exported `SRCDEST` — never the reverse; a mirror carries the default HEAD,
  not the built ref.
- **Self-consistent is not verified** (2026-09-20): a sync that bumps pkgver
  without refreshing sums, plus `--skipchecksums` behind a quiet flag, is
  disclosure rather than anchoring. Fetch the official `.SRCINFO`, match moved
  sources, `updpkgsums`, verify; anchor-or-refuse, loud fetch-only, or DEFER
  when no official document exists.
- **Sources and checksums in a `.SRCINFO` line up only within one algorithm**
  (2026-09-20): Arch concatenates one list per algorithm, so a flat read cannot
  index by source (8 of 28 refused). Take the first contiguous same-algorithm
  run; its length must equal the source list, else fail closed.
- **The name makepkg fetches under is not the URL's basename** (2026-09-20): a
  `name::url` override downloads to `name` (`udisks2`), and a renamed
  `LICENSE` matched a different file of the same name. Resolve the filename as
  makepkg does — override first.
- **A VCS source's checksum is a git-archive hash** (2026-09-20):
  `calc_checksum_git` hashes `git archive --format tar v`; off a
  `--filter=blob:none` mirror an `export-subst` file renders differently.
  Mirror with `git clone --bare`, never a filter.
- **A deny-list and a delete-list are the same list** (2026-09-20): the root
  archive set and `nuclear_cleanup()`'s match test drifted twice, committing
  36 MB of upstream archives. One list now —
  `gsa-maint/src/prune.rs` `download_patterns` — cross-checked in both
  directions by `tests/cleanup-extensions.sh`.
- **A diagnostic on captured stdout is swallowed, and a range indexes the
  selection, not the whole set** (2026-09-19): a group-resolution error written
  inside a command substitution exited 1 printing nothing — diagnostics go to
  stderr. A typo is never auto-corrected (`≤3` candidates); ranges clamp and
  refuse `..`.
- **IgnorePkg closure drift** (undated): the closure drifted short twice; keep
  the diff empty after adding any package (rule 9) — registration is dynamic,
  so an install run registers accepted archives itself. Back up
  `/etc/pacman.conf` first (`IgnorePkg =` lines accumulate).
- **A signal storm corrupts what it kills** (2026-09-23): one TERM per child
  group, one 30 s grace, one logged SIGKILL — a TERM every 50 ms left `db.lck`
  and later installs failed. A stale lock needs two idle probes 1 s apart; lane
  pacman shares one flock.
- **Closing the terminal window SIGTERMs the whole run and half-commits
  pacman's local db** (2026-09-24): the corpse is `local/<pkg>-<ver>/` missing
  `desc`/`files`, and the headline `invalid or corrupted package` indicts the
  LOCAL db. Repair by entry removal + `pacman -U` (`--overwrite '*'` for
  orphans); the seam is `--local-db-check <path>`.
- **A lane must record its own death** (2026-09-23): the dispatcher logs
  `signal:` (INT/TERM/HUP) to `dispatcher.log`; the lane writes an honest
  result (129/130/143) before re-raising. rc=125 with no bytes can be a lost
  race, so the reap re-reads the result file.
- **The parallel battery makes two things contractual** (2026-09-24): a
  fixture must be parallel-safe (non-mutating, `$TMPDIR`-scoped, process
  assertions scoped to its own `$fixture` path), and sibling subjects merge
  into ONE file as `( subshell )` sections. `_LANE_STOP_GRACE_S` is an internal
  seam, never a `GSA_*` input.
- **User-level fish wrapper functions intercept the battery's PATH stubs**
  (2026-09-26, corrected 2026-10-09): fish autoloads `$fish_function_path`
  before PATH, so a user `sudo` wrapper shadows the stub (`stub_sudo` strips
  `--preserve-env`). Never set `fish_function_path=/nonexistent-fp`: fish
  imports it as one element and drops every function directory.
- **Tree exclusions in `find` are `-prune`, never `-not -path`** (2026-10-09):
  `-not -path` filters output only, so an artifact sweep descended every
  `src/`/`pkg/`/`build/` — 11+ minutes before the first dispatch.
  `tests/log-ownership.sh` §1b pins the boundary.
- **A missing makepkg/lib file during a `pacman` recipe install is a
  self-hosting race** (2026-10-09): installing house `pacman` replaces
  `/usr/share/makepkg/*`, so a lane starting `makepkg` in that window dies on
  `util.sh: No such file`. Verify the toolchain and resume; never "fix" the
  victim recipe.
- **The install gate halts at the first miss — a run sizes one offender, never
  the class** (2026-10-21): two runs named tree-sitter/arm64 then
  lightningcss/musl, one wall, ~45 min per peel. Census the artifact
  (`tar -tf | grep -i musl`, `readelf -d` of every `*.node`/`*.so`) and strip
  the class.
- **A host-only lib census false-alarms on private libs the package itself
  ships** (2026-10-21): `RUNPATH $ORIGIN` natives resolved nothing until the
  gate consulted the transaction's shipped basenames (`ShippedBytes::ships`).
  Check closure against host ∪ shipped basenames before naming an offender.
- **Queued lanes that never start are usually the core-run-alone invariant,
  not a stall** (2026-10-21): a `core` member starts only on an idle machine
  and blocks other dispatch, and selected consumers chain behind
  prerequisites. Read the group column and
  `gsa-sched/src/machine.rs::can_dispatch`; progress truth is
  `<state>/runs/<id>/*.result`.
- **An automount-managed build drive can vanish with no kernel event**
  (2026-10-22): writes spill into the mountpoint's parent tmpfs and the linker
  dies SIGBUS. Diagnose with `findmnt`/`df`/`lsblk` (df shows the PARENT fs
  when unmounted); long builds on removable media start from a kernel mount.
- **A drifted soname provide refuses at install PER SE** (2026-10-22):
  `abi-soname` is unconditional (in-run repair is fish-era; contract §M).
  `--leaf` suppresses selection expansion, not the record-mismatch wave
  closure; `--skip-built` claims closure members but forces real rebuilds of
  wave providers; `--no-deps` is the retired spelling of `--leaf`.
- **Moving `SRCDEST` strands `objects/info/alternates` in old VCS working
  copies** (2026-10-22): the pre-move path is gone and every older tree
  hard-fails at "Creating working copy". Sweep
  `grep -rl "\.cache/gsa-src" $BUILD --include=alternates` and redirect each
  to `~/.gsa-src/<name>/objects`.
- **A build attached to a terminal scope dies with that terminal** (2026-10-22):
  a Wayland protocol error killed the surface, its scope stopped, and every
  descendant got SIGTERM (`interrupted-mid-build`, rc 143) — no OOM. Launch
  long runs detached; progress truth is `<state>/runs/<id>/*.result`.
- **A pacman hook's failing command does NOT stop the transaction without
  `AbortOnFail`** (2026-10-22, measured): pacman logs `error: command failed to
  execute correctly` and commits anyway — a red probe installed the broken
  package. Probe every blocking gate at transaction level.
- **alpm hook input is package NAMES on stdin, and a local-file `-U` is
  skipped** (2026-10-22): `NeedsTargets` passes one name per line, no argv;
  `Operation =` takes one line per value; the gate reads the transaction kind
  from argv via process ancestry, never a cached twin.
- **An `-S` plan drags the whole consumer wave of every selected provider
  whose newest token ≠ its `:=` records** (2026-10-23): missing subscription
  records engage the fail-toward whole-closure fallback; overlapping waves
  merge into one. Keep heavy toolchains out by excluding wave TRIGGERS;
  suppressing members parks installs at the ABI gate.
- **PR comments go through `gh` only, and never before CI is green**
  (2026-10-24): do not post through the GitHub MCP service; a confirmation
  under red or unverified CI is wrong, and the checks table can be stale.
- **makepkg source-cache mechanics** (2026-10-24, measured): makepkg rejects a
  mirror whose origin URL differs ("is not a clone of"); every build fetches
  the mirror; a partial download leaves `<file>.part` and the retry dies on
  servers without byte ranges (delete it, `curl --retry`); a config-changing
  retry must wipe the build workspace.
- **`SIGNATURE NOT FOUND` on a `?signed` git source is usually the
  environment** (2026-10-28): the injected `GIT_CONFIG_COUNT=3` hardening makes
  a bare cache unusable (`fatal: cannot use bare repository`), and a full
  `$TMPDIR` kills gpg status writes. Discriminate with `GIT_CONFIG_COUNT=0 git
  -C ~/.gsa-src/<pkg> verify-tag <tag>`.
- **A dropped USB dock turns `build_dir` into a tmpfs impostor**
  (2026-10-28): the unmounted tree survives as plain directories the next
  `mkdir -p` recreates on `/run`; writes "succeed" until ENOSPC and gpg dies
  (→ SIGNATURE NOT FOUND). Tell: `df <build_dir>` answers `tmpfs /run`. Rescue
  `pkgs/`, `findmnt`, mount the device.
- **A version-sync that moves a SONAME is a decision, not a build**
  (2026-11-02, poppler 26.10): `abi-soname` refusals are unconditional and
  run-level (rc 3, dispatch stopped). Check `.PKGINFO` provides against
  installed before feeding a package to a wave; land with `pacman -U
  --assume-installed <old-provide>` plus an engine re-bless, then
  `--skip-built`.
- **A completed build dir is not free disk; downstream builds can embed its
  paths** (2026-11-02/03): pruning `build/qt6-base-git` broke every later Qt6
  module through build-internals cmake paths. Prune only trees with no pending
  consumers.
- **An in-flight prune keep-list must come from live PIDs, never lane names**
  (2026-11-03): the build-dir name can differ from the package id
  (`build/zen-browser` vs lane `zen-browser-pgo`), and a name-mismatched prune
  deleted a mid-build tree. Resolve keep-paths via
  `ls -l /proc/<makepkg-pid>/cwd`.
- **`gsa -S --leaf` can be hijacked wholesale by the GCC identity gate**
  (2026-11-03): a `--leaf glib2-git` run dispatched the toolchain block and
  unrelated lanes after a compiler-identity change, ignoring the selection.
  Until fixed, recipe one-offs go through plain `makepkg`
  (`GIT_CONFIG_COUNT=0`, `PKGDEST` outside the repo) and one `pacman -U`.

## 6 · Queued

- **Recipe-repository split (2026-11-08): finish E1, then cut the tree.** The
  gate for everything else. E1 is the `store_format` marker in `gsa-topo`, the
  store retarget in `gsa-state/src/recipes.rs`, and `GSA_RECIPE_CHECKOUT` for
  the real-tree checks; then `git filter-repo` the recipe half out and repoint
  `DEFAULT_RECIPE_URL`. Blocked on: engine release E1 and a green battery.
- **Wave freshness gate (2026-11-01).** `gsa-graph`/`gsa-sched` wave members
  must gate on binpkg-index freshness. Blocked on: the `-O3` restart finishing.
- **Toolchain marker ignores flag changes (2026-11-01, CFLAGS incident).**
  Extend the GCC identity marker with a flags digest (or add an `-M`
  cache-sweep seam); until then an operator MUST wipe
  `<build_dir>/{build,pkg,tmp}` after a flag edit. Blocked on: an owner call on
  digest versus sweep.
- **Snapshot-pin expansion, `-git` → `-snapshot` (2026-11-01).** Owner
  decided, implementation deferred; the `-Sy` "last commit ≤ Monday 00:00Z"
  provider is engine work and must land LAST. Blocked on: the rebuild-campaign
  goal and the recipe half landing first.
- **`--skip` version-keyed local claim churns fast-VCS recipes (2026-10-18).**
  `gsa-recipe::freshness`, contract-adjacent (§B.8). Blocked on: deciding the
  semantics before coding, then a `skip-upstream.sh` scenario.
- **"One-time clean" prints per recipe per invocation (2026-10-18).** The
  prep-phase message fires dozens of times per run; find the trigger and make
  it fire once. Blocked on: nothing but a repro.
- **Freshness-gate `-S` sync prep (2026-10-18).** `-S` re-runs the provider
  sync pass; skip already-anchored recipes via a `recipes.last-fetch` stamp
  instead of `--no-sync`. Blocked on: nothing.
- **Pre-install package-internal NEEDED probe (2026-10-07).** `gsa-install`
  gate class (§E.3): `readelf -d` the staged payload and refuse
  self-inconsistent sonames; fixture through `--install-decide`. Blocked on:
  nothing.
- **ABI-batch install deferral (2026-10-07).** Owner decision on design — (a)
  a staged anchor, (b) SONAME coexistence, (c) status quo; a plain deferral is
  unsound. Blocked on: the owner's choice, then `--install-decide` fixtures and
  a record row.
- **Fixture-safe pacman lock preflight (2026-10-06).** Give fixtures a
  `pacman-conf` stub whose DBPath is workspace-local — an owner-blessed stub,
  not a builder knob. Blocked on: nothing (the idiom is blessed).
- **Swap-drift owner calls (2026-10-06).** Keep the soname-drift lint
  symmetric or narrow it to drop-only; then dispose of the 18 host drift rows
  as recipe fixes or retired debt. Blocked on: the owner's call.
- **version-sync versus pkgrel rebuild triggers (2026-10-04).** Sync resets
  `pkgrel=1` while fixture pins demand `pkgrel >= 2`: teach sync to preserve
  trigger bumps, or re-express the pins as content checks. Blocked on: a
  decision, then the fixture rewrite.
- **ABI provide-refusal blind spot (2026-10-06, stock half fixed).** Decide
  whether the stock-pinner check also names workspace exact pinners
  (transaction coverage), or in-run repair requires a bare pin. Blocked on: the
  owner's decision.
- **rustc sanity probe misses non-Rust recipes that compile Rust
  (2026-10-06).** The `--allow-broken-rustc` probe fires only for the Rust
  family; widen it to rustc-in-makedepends or once per run. Blocked on: the
  fixture-pinned probe seam.
- **The 2026-09-01 unclean-shutdown cluster is still unexplained
  (host-class).** `last -x` over the whole wtmp shows ~23 unclean shutdowns;
  the first four sit inside 27 minutes of the first `ryzenadj` +
  `ryzen_smu-dkms-git` install and predate `scx-scheds-git`, so the
  CVE-2026-90432 freeze class cannot explain them. Prime suspect is the
  per-login `ryzenadj` undervolt: its `--set-coper` half cannot be read back
  (CO is not readable) and the login script discards `ryzenadj`'s exit
  status. All AER counters are zero on the NVMe device and its root port, so
  the link-fault lead is absence of evidence. The one full-length rebuild
  that passed (Tctl 91 °C) ran with sched_ext unloaded, so it is not a
  control. Blocked on: a control run with CO disabled and the exit status
  recorded.

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
