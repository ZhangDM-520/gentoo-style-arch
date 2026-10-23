# `gsa` interface contract v2 — clean-slate re-contract

Date: 2026-10-12. Status: normative contract for the native package manager
`gsa` (one shipped Rust binary). This document defines the CLI surface, the
selection vocabulary, the decision/outcome/exit-code contracts, the run-record
machine grammar `format: 2`, the failure policy, the state layout, the process
contract, and the change-control rules.

It is a **clean-slate re-contract** (owner decision): byte-compatibility with
the fish engine is NOT a goal. The 55 bash fixtures, the `rr_*` run-record
parser (`tests/lib/fixture-lib.bash`), and any user scripts are re-contracted
once, against this document. What IS binding is **behavioural equivalence of
scheduling and install semantics** with `build-all.fish` as documented in
`docs/architecture.md`, `docs/build-guide.md` and `CONTEXT.md`, unless this
document names the change explicitly (the deliberate changes are: cone-stop
default, the action-pass grammar, `format: 2`, the side-car database, and the
hidden-seam set).

Grounding that constrains this contract (cited inline where binding):
`plan-native-pm.md` §3 (component layout), §3.3 (function mapping), §7
(phases), §9 (testing), §10 (non-goals); `plan.md` §2 (fetch-ahead process
model), §3 (advisory failure semantics), §4 (fetch result codec, verdict
vocabulary); `plan-gentoo-qol.md` §1 (shortlist items that become verbs/rows)
and M4; `docs/build-guide.md` (current flags, `--install-decide` rows and rc
contract, run-record `format: 1`); `docs/architecture.md` (four-module split,
scheduler invariants); `CONTEXT.md` (vocabulary and terms to avoid);
`docs/MEMORY.md` rules 11, 15, 19, 20, 23, 25 (rule numbers, not page dumps);
`docs/adr/0003-run-record.md` (one record, three renderings);
`tests/lib/fixture-lib.bash` (`rr_*` parser, `GSA_FAKE_*` stub knobs); and the
authoritative current flag inventory `fish build-all.fish --help`.

---

## A. Purpose, scope, non-goals

### A.1 Purpose

`gsa` is the native build-and-install orchestrator for the curated recipe set
in this repository, and the package-management surface over it. It replaces the
fish builder (`build-all.fish`, `lib/sources.fish`, `lib/audit.fish`) with one
compiled binary that keeps the same architecture: Recipes / Topology / Builder
/ Runtime state (`docs/architecture.md`), with `gsa` as the new Builder.

### A.2 Scope (normative)

1. **Language and shape.** One shipped binary `gsa`, written in Rust
   (`plan-native-pm.md` §2). Internal crate layout is an implementation matter;
   the contract is this CLI and the record grammars below.
2. **pacman relationship — HYBRID.** pacman remains the ONLY installed-package
   database of record and the ONLY transaction executor. Phases 0–3 transact
   exclusively through `pacman -U` subprocesses; direct libalpm bindings may
   arrive later **behind the same decision seam** (§E), never in front of it.
   `gsa` owns a **side-car database** (binpkg index, ABI token and subscription
   records, world/sets, run history) keyed by pacman's local database; every
   side-car row must be reconcilable against pacman's local DB, and a row that
   cannot be reconciled is report-only until `gsa -Md` repairs or prunes it.
3. **Recipe format.** PKGBUILD stays the recipe of record AND the build
   payload: `makepkg` executes it. The engine's read path never evaluates
   recipe shell. It reads committed `.SRCINFO` for metadata and scheduling
   facts, with a strict read-only scan fallback for facts `.SRCINFO` does not
   carry; a recipe whose read path cannot be answered from those two sources is
   a usage-level error naming the recipe and the missing fact, never a shell
   evaluation.
4. **CLI shape.** User-facing CLI only. There is NO ownership-hygiene or
   multi-user administration slice in v2 (state ownership rules are enforced by
   the engine per §J, but there is no user-management verb family).
5. **Action pass grammar.** PASCAL-STYLE PACMAN GRAMMAR: uppercase family
   options (`-Q -S -B -U -M`), lowercase sub-options (§B).
6. **Failure default.** Cone-stop is the default everywhere (§I).
7. **State.** The side-car DB lives at FHS `/var/lib/gsa` early (root write
   accepted); a state-dir override stays first-class for fixtures, unprivileged
   runs, and `$TMPDIR` workspaces (§J).

### A.3 Non-goals (normative, carried verbatim in meaning)

1. **No dependency resolver, slot solver, USE flags, profiles, keyword masking,
   or license gating.** The build-order graph is hand-wired topology
   (`CONTEXT.md`: build-order edge, not "dependency"); the ABI subscription
   model of `plan-native-pm.md` §4 is rebuild-set computation over that graph,
   not a solver.
2. **No second installed database of record.** `/usr` and `/var/lib/pacman`
   belong to pacman; a design that can brick `/var/lib/pacman` is wrong on
   arrival (`docs/MEMORY.md` rule 23).
3. **No sandbox claims.** A recipe executes arbitrary shell at build time; the
   trust model is "review before running" (`SECURITY.md`). The narrowed read
   path (A.2.3) is not a sandbox and must never be described as one.
4. **makepkg verification is never reimplemented and never weakened.**
   Checksums and PGP stay exactly where makepkg enforces them. There is no
   `--skipchecksums` and no `--skippgpcheck` anywhere in `gsa`, in any phase,
   including hidden seams (`docs/MEMORY.md` rule 15; `docs/build-guide.md`
   "never passed by the builder").
5. **No byte-compatibility promise** to the fish engine's flags, output
   strings, run-record `format: 1`, or fixture argv shapes (owner decision:
   clean slate). Behavioural equivalence of the scheduling/install semantics in
   §C–§K is the promise.
6. **No parallel installation of multiple versions of one name**, no
   redistribution/signing infrastructure, no multi-host builds. Signed index
   manifests are deferred (§J.4).

---

## B. Action-pass grammar

### B.1 Form

```
gsa <FAMILY>[cluster] [long-modifiers] [targets…] [ranges…] [-- <pacman args…>]
```

- Exactly one family per invocation. A bare `gsa` is a usage error (rc 2) that
  prints `gsa --help`; a build never starts without a selection (invariant kept
  from `docs/MEMORY.md` rule 12).
- The cluster is a run of lowercase sub-option **letters**, family-scoped. One
  **action letter** per invocation (or none, meaning the family's default
  action). **Modifier letters** may join the cluster in any order after the
  action letter. Combining a terminal query letter with a build modifier is a
  usage error (rc 2).
- `-- <pacman args…>` trailing arguments are forwarded verbatim to the
  `pacman -U` invocation of an install transaction (today's `-ia --overwrite
  '*'` idiom). They never reach any other family.
- Word alias: `gsa fetch` is accepted and is exactly `gsa -Sw` (owner decision
  names it). No other word verbs exist; the verb list in `plan-native-pm.md`
  §5.1 is superseded by this grammar.

### B.2 Families

| Family | Name | Default action | Sources read |
| --- | --- | --- | --- |
| `-Q` | query | list installed workspace packages with side-car columns | pacman local DB (read-only), side-car DB, committed `.SRCINFO` + topology |
| `-S` | build + install | build the selection and install each package before its consumers compile | as `-Q`, plus recipe sources |
| `-B` | build-only | build the selection to archives; nothing is installed | as `-S`, minus install |
| `-U` | install from archives | install named archives/refs from the binpkg index | side-car DB, archives on disk, pacman local DB |
| `-M` | maintain | report/repair engine state and sets | side-car DB, state root, logs, recipes |

### B.3 `-Q` — query (read-only; installed + side-car DB)

| Spelling | Action |
| --- | --- |
| `gsa -Q` | list installed packages, with side-car columns (abi-token, built version, binpkg instances) where a side-car row exists |
| `gsa -Qi <ref…>` | info: pacman fields plus the side-car record (abi-token, subscriptions in/out, retained binpkg instances, VCS baseline) |
| `gsa -Qs <pattern…>` | search installed names/descriptions (pacman `-Qs` semantics) |
| `gsa -Ql <ref…>` | list owned files (pacman `-Ql` semantics) |
| `gsa -Qo <path…>` | file owner (pacman `-Qo` semantics) |
| `gsa -Qp <archive…>` | archive probe: read `.PKGINFO`, match the binpkg index row, report hash/size agreement |
| `gsa -Qb [ref…]` | binpkg index rows (retained built instances) |
| `gsa -Qa <ref…>` | ABI report: derived token, `abi-rev=` override if any, subscriptions recorded against it |
| `gsa -Qu` | stale set: recipes whose tracked upstream/provider version moved since their newest built instance (the `--stale` query, `plan-gentoo-qol.md` shortlist 6) |
| `gsa -Qt` | print resolved topology records `id\|path\|groups\|edges\|tags`, one per line — the tooling data channel (today `--topology`; tooling must never parse `config/` directly) |
| `gsa -Qr` | revdep report over the installed-ELF index: unresolved `DT_NEEDED`, preserved-lib survivors, exact-pin leftovers — **deferred to a later phase** (needs the installed-ELF index of `plan-native-pm.md` §4.4) |

### B.4 `-S` — build + install

| Spelling | Action |
| --- | --- |
| `gsa -S <targets…> [ranges…]` | build the selection in build order; install each package's archives immediately after its build and **before any consumer builds** (install-before-dependents, `docs/MEMORY.md` rule 11). Install decision is *checked* (§E) |
| `gsa -Ss <pattern…>` | search the buildable universe (topology + committed `.SRCINFO`) |
| `gsa -Si <ref…>` | recipe info: metadata, topology record, groups, build-order edges, tags |
| `gsa -Sl [targets…] [ranges…]` | list the ordered selection with the indices ranges address (today `-l`; with no selection, the whole set in build order) |
| `gsa -Sg [name…]` | list groups/sets and their members (no name: all six group names with counts) |
| `gsa -Sw <targets…>` | **fetch-only, Phase 4** (`plan.md` §2): fetch and verify sources ahead of builds; no build, no install. Verdict rows are advisory (§D) |
| `gsa -Sy` | version-sync pass only: provider queries, recipe rewrites left uncommitted, disposition block printed (today's automatic pre-build sync made explicitly runnable) |
| `gsa -Su` | update: `-Sy`, then build+install the stale set — **Phase 4** |

Cluster letters: `f` = force install (today `-fi`: always run `pacman -U`, no
same-version skip); `c` = prune strength 1 first (today `-c`: remove the
selection's `src/`/`pkg/`/`build/` trees and archives before the skip check, so
the run rebuilds). Example: `gsa -Sfc @git --lanes 2` = clean, build and
install the `git` group's selection with two lanes.

A `-S` run performs the version-sync step before building unless `--no-sync` is
given (behaviour kept). A `core` selection needs no special flag: `-S @core`
installs as it builds; `-B @core` is a deliberate build-only choice whose
archives are installed later by `-U`.

*Amendment (2026-10-17, version-sync seam — sticky mixed state, honesty).*
The rewrite is transactional per file (each publish is one tmp+mv), but the
PKGBUILD and the committed `.SRCINFO` publish in two separate steps: a crash
between the PKGBUILD publish and the `.SRCINFO` rename leaves a **sticky
mixed state** — the PKGBUILD at the new version, the committed `.SRCINFO`
still at the old one. A re-run does **not** repair it: the pass compares the
PKGBUILD's own `pkgver`/`pkgrel` against the provider and short-circuits
`NoChangeReason::Current` (`gsa-recipe::sync`) before any `.SRCINFO` work.
The named repair is `makepkg --printsrcinfo` + manual re-anchor (rule 18's
checksum anchor). A skew lint is explicitly out of scope.

### B.5 `-B` — build-only

| Spelling | Action |
| --- | --- |
| `gsa -B <targets…> [ranges…]` | build the selection to archives in the build cache (§J.2: `$GSA_BUILD_DIR` > config `build_dir` > `<build-user-home>/.cache/gsa`; the recipe dir is only the pre-W4 legacy scan fallback) — no install, no `pacman` call |
| `gsa -Bl [targets…] [ranges…]` | same listing as `-Sl` (the listing is selection-shaped, not family-shaped) |

Cluster letters: `c` = prune strength 1 first. Long modifiers as in B.6.

*Amendment (2026-10-17, §B.5 archive location).* The row previously said
"archives beside their recipes" — that is the pre-W4 layout, not the code.
Code truth (`gsa-model::config::build_root`): `$GSA_BUILD_DIR` env > config
`build_dir` > the build user's `~/.cache/gsa`, exactly as §J.2 already
states; the recipe dir survives only as the pre-W4 legacy scan fallback in
archive discovery (§J.2). Wording-only correction (§L.2: no `format:` bump);
behaviour is pinned elsewhere, no fixture changes.

### B.6 `-U` — install from archives

| Spelling | Action |
| --- | --- |
| `gsa -U <ref…|archive-path…>` | install the named packages' newest index-complete archives (or the named paths) in ONE `pacman -U` transaction; nothing is built |
| `gsa -Ua` | install ALL index-complete archives in the workspace in one transaction (today `-ia`) — the group-install escape hatch: it cannot satisfy install-before-dependents and must never stand in for `-S` on a set whose members depend on each other (`docs/MEMORY.md` rule 11) |
| `gsa -Uf` | force: bypass the same-version already-installed skip (today `-fi` as applied to installs) |

`-Ua` runs in force mode inherently (no same-version skip), matching today's
`-ia` pipeline. An empty eligible set is `noop empty-list` under `-Ua` and a
refusal under `-S` (§E).

### B.7 `-M` — maintain

| Spelling | Action |
| --- | --- |
| `gsa -Ma` | audit report: legacy paths, package drift, stale runtime artifacts, cargo/rustc recipes with no `rust-git` edge, the recipe-contract lints, installed PGO payload report (today `--audit`). Report-only by contract (§E.4); exit 0, read the report |
| `gsa -Md [--fix]` | doctor: runtime-state reconciliation — log ownership, stale lane/run artifacts, pacman local-DB health report, binpkg index/`sha256+size` consistency, side-car rows with no pacman counterpart. Default reports; `--fix` applies the named repairs |
| `gsa -Mi [--prune\|--backfill]` | IgnorePkg closure repair of the target `pacman.conf`: default reports drift; `--prune` removes stale entries; `--backfill` adds missing ones (today's hidden `--register-ignorepkg`) |
| `gsa -Ml [--tail <ref>] [--keep N]` | per-package log browse/tail; `--keep N` is the log-retention prune |
| `gsa -Mm` | mirrors: dedupe VCS source clones into canonical mirrors (today `--link-sources`). Confirmation-gated, never prompts (§K.3): without `--noconfirm` it prints its plan/targets and stops rc 3 `confirmation-required`; must run as the build user, never under a root supervisor |
| `gsa -Mc <targets…>` | prune strength 1: `src/`/`pkg/`/`build/` trees and archives of the selection (today `-c` as a wipe) |
| `gsa -Mcc` | prune strength 2: every built archive in the workspace plus its VCS-revision sidecar; symlinks are never deleted or followed (today `-cc`) |
| `gsa -Mccc` | prune strength 3: additionally remove pulled sources — source clones, downloaded tarballs (extension-matched to the root `.gitignore` set), staging dirs. Prints its target list and stops rc 3 `confirmation-required` without `--noconfirm` (today `-ccc`) |
| `gsa -Ms [name…] [--add\|--remove <ref…>]` | named sets: list sets and members; manage user sets under `config/sets/`. Computed sets (`@preserved-rebuild`, `@stale`, `@live-rebuild`) are listed but not editable — **`@preserved-rebuild` is Phase 4** |
| `gsa -Mw [--add\|--remove <ref…>]` | world: the explicitly wanted set. Default lists it; `--add`/`--remove` edit it (remove = deselect) |
| `gsa -Mh [--prune] [--show <run-id>]` | run history: list recorded run records and their continuations; `--show` renders one; `--prune` enforces the bounded retention |

The strength idiom `-Mc`/`-Mcc`/`-Mccc` is deliberately pacman's `-Sc`/`-Scc`
cache-prune shape. `-Mm` and `-Mccc` are confirmation-gated and **never
prompt** (§K.3): without `--noconfirm` each prints its plan/targets and stops
rc 3 `confirmation-required`; `--dry-run` renders the same targets at rc 0;
`--noconfirm` applies. `-Mh --show` is a pure read — no confirmation, no gate.

*Amendment (2026-10-17, §B.7 confirmation semantics).* The `-Mm` row
("Interactive confirmation"), the `-Mccc` row ("asks first"), and the trailing
line (`-Mm`, `-Mccc` and `-Mh --show` "accept a confirmation or a `--dry-run`
rendering") all contradicted §K.3 and the code. Code truth
(`gsa-cli::maint` MaintVerb::Mirrors / strength-≥3 Maintenance gates;
`gsa-maint` `CONFIRMATION_REQUIRED` + `RC_REFUSAL` = 3): the engine never
prompts (a TTY changes nothing) — without `--noconfirm` the verb prints its
plan/targets and stops rc 3 `confirmation-required`; `--dry-run` renders at
rc 0; `--noconfirm` applies. The gate covers `-Mm`/`-Mccc` only: `-Mh --show`
is a pure read with no confirmation at all. Wording-only (§L.2); pinned by
`tests/gsa-maint-v2.sh`, no fixture changes.

### B.8 Global long modifiers (combinable with the families that can act)

| Modifier | Meaning |
| --- | --- |
| `--dry-run` | render plan + decision rows without building, installing, fetching, or mutating anything (today `-n`) |
| `--leaf` | leaf-only selection: build exactly the named recipes, no consumer expansion (today `--no-deps`) |
| `--skip` | skip-if-fresh resume (today `-s`): skip a package whose archive set is fresh against its recorded VCS baselines; the `freshness-waived` and `abi-provider-waived` waiver reasons and the `upstream-unverified` deferral are kept verbatim (`docs/build-guide.md` "Skip and resume") |
| `--skip-built` | skip anything already built: newest complete, payload-valid output set at any version; no upstream probes, no waivers; a recipe commit newer than the set rebuilds (kept verbatim) |
| `--vcs-skip-tolerance N` | the `--skip` waive threshold (positive integers only; overrides `GSA_VCS_SKIP_TOLERANCE`) |
| `--no-sync` | build the committed version and sums as-is: no provider query, no anchoring, no rewrite (kept) |
| `--allow-broken-rustc` | skip the rustc sanity probe; escape hatch for runs that compile no Rust (kept) |
| `--no-register-ignorepkg` | skip the dynamic IgnorePkg registration an install run performs at archive acceptance; the skip is loud (kept) |
| `--fail-fast` | restore the stop-dispatch-and-drain failure policy (§I) |
| `--lanes N\|auto`, `--jobs N\|auto`, `--intensity LEVEL` | parallelism overrides (kept; a flag beats its env twin) |
| `--state-dir PATH` | state-root override (§J.3); flag beats `GSA_STATE_DIR` |
| `--no-prefetch`, `--prefetch-ahead N` | advisory fetch-ahead window (default-on): `--no-prefetch` opts out, `--prefetch-ahead N` sizes it; the two are mutually exclusive (added 2026-10-14, see amendment 4) |
| `--config PATH`, `--noconfirm` | pacman-familiar globals; `--noconfirm` applies to the engine's own confirmations (`-Mm`, `-Mccc`) and never to a pacman question flag |
| `--quiet`, `--verbose` | **deferred**: recognised and refused (rc 2, naming the flag) by every command; never mirrored (§H.2) |

Engine environment inputs (the roster `gsa --help` must print; rendered from
`crates/gsa-cli/src/help.rs`, the single layout source): `GSA_CONF`,
`GSA_STATE_DIR`, `GSA_BUILD_DIR`, `GSA_RECIPES_DIR`, `GSA_LANES`, `GSA_JOBS`,
`GSA_INTENSITY`, `GSA_CPU_THREADS`, `GSA_MEMORY_GIB`, `GSA_TARGET_CPU`,
`GSA_VCS_SKIP_TOLERANCE`. `GSA_BUILD_JOBS` is engine OUTPUT
exported per lane, never an input. `GSA_FAKE_*` is not an engine vocabulary
(§D.2).

*Amendments (2026-10-14, cutover gaps G6/G11 + G4).* Three operational
points this section was silent on, resolved as the code behaves:

1. **Workspace discovery (G11):** `gsa` locates the workspace from the
   current directory upward, stopping at the directory holding
   `config/topology.conf`; nothing else selects a workspace (`gsa-cli::find_root`,
   `gsa-build::find_root`). A run outside a workspace is a usage error (rc 2)
   that names the search. The frozen fish oracle under `tests/assets/` is the
   one exception: it resolves its workspace from its own location (historical
   engine behaviour, `build-all.fish` `SCRIPT_DIR`) — which is why a fixture
   runs it from a copy beside the workspace it exercises.
2. **IgnorePkg registration target (G6):** `--config PATH` names the ONE
   `pacman.conf` an install run reads and rewrites (`[options]` `IgnorePkg`
   closure; default `/etc/pacman.conf`); `--no-register-ignorepkg` skips the
   write, and hidden `--install-register <conf> <subject> <names…>` (§D.1)
   names its conf explicitly because it is the isolated write seam.
3. **`--leaf` (G4):** the bare boolean of this table is the only spelling.
   Continuations mirror it only in its true form (§H.2); `--leaf=no` and
   `--leaf=yes` are not accepted spellings and no engine output may contain
   them.
4. **Fetch-ahead modifiers (cutover re-point finding, 2026-10-14):** the
   table above had omitted `--no-prefetch`/`--prefetch-ahead N` although the
   code ships them (`gsa-cli::build::resolve_prefetch`; `--help` roster) and
   §H.2's flag-rule table already mirrored them. Code truth is the decided
   truth here: the table row is the definition, the mirroring rule stays
   §H.2's (non-default values only), and the advisory run log is
   `$STATE/prefetch.log` with the `prefetch-warnings` extension scalar (§H.2
   permits extension scalars without a format bump).

*Amendment (2026-10-17, `--quiet`/`--verbose` disposition).* The table
previously listed `--quiet`/`--verbose` among live "pacman-familiar globals"
alongside `--config`/`--noconfirm`. Code truth is parse-and-refuse: both are
recognised into `deferred_flags` (`gsa-cli::args`) and every command answers
rc 2 `gsa: deferred to a later phase: <flag> …` (`gsa-cli::classify` plus the
rc-usage print) — they appear in no accepted roster (`build::REAL_BUILD_FLAGS`
/ `REAL_INSTALL_FLAGS`, `install::REAL_UPGRADE_FLAGS`, `maint::accepted_flags`)
and are never mirrored (§H.2). `--help` already said exactly this ("Deferred
(parse and refuse, so the message names them)"); the row is split to match.
Wording-only (§L.2); the flag pin lives in `gsa-cli`'s
`deferred_spellings_refuse_with_a_clear_message`.

*Amendment (2026-10-17, "newest" = version-ranked).* Archive and set
selection rank by **version first** (`vercmp` order over the canonical
`epoch:pkgver-pkgrel`), newest-mtime as tiebreak, and keep mtime order when
`vercmp` is unavailable — never lexical order. This defines what `-U`'s
"newest index-complete archives" (§B.6) and `--skip-built`'s "newest complete
set" mean: the highest-version set, set-scoped so the split outputs of one
version stay together. `--skip` set membership is unchanged (it was already
version-keyed). Build **registration** (§J.4) is not selection: a finished
build registers the outputs it just wrote (newest-mtime rank), never the
version-ranked winner — a stale higher-version archive lying beside the
recipe must not become that build's row.

### B.9 Capability disposition — every current spelling

| Today (`build-all.fish`) | v2 spelling | Disposition |
| --- | --- | --- |
| `-g/--group GRP` | `@name` targets (`gsa -S @git`, `gsa -B @core`) | renamed: groups and sets share one `@` namespace (§C.2) |
| `-l/--list` | `-Sl` (also `-Bl`) | carried, family-scoped |
| `-n/--dry-run` | `--dry-run` | carried as long-only |
| `-i/--install` | implicit in `-S` | dropped as a flag: the family IS the install decision |
| `-fi/--forceinstall` | `-Sf` / `-Uf` | carried as cluster letter |
| `-ia/--installall` (+ `--overwrite` passthrough) | `-Ua -- <pacman args…>` | carried; pacman passthrough via `--` |
| `--no-deps` | `--leaf` | renamed (leaf-only mode) |
| `-c/--clean` | `-Mc`, and cluster letter `c` on `-S`/`-B` | split: prune verb vs build-run modifier |
| `-cc/--cleanup` | `-Mcc` | carried |
| `-ccc/--nuclear` | `-Mccc` | carried (still asks first, still prints targets) |
| `-s/--skip` | `--skip` | carried as long-only; short `-s` dropped (collides with the pacman search idiom `-Ss`) |
| `--skip-built` | `--skip-built` | carried |
| `--vcs-skip-tolerance N` | same | carried |
| `--no-sync` | same | carried |
| `--audit` | `-Ma` | carried; still report-only |
| `--audit-lint <family>` | hidden `--qa-check <name>` | renamed (§D.1) |
| `--topology` | `-Qt` | carried as a query action |
| `-ln/--link-sources` | `-Mm` | carried |
| `--no-register-ignorepkg` | same | carried |
| `--register-ignorepkg` (hidden one-shot backfill) | `gsa -Mi --backfill` | public maintain verb |
| `--lanes/--jobs/--intensity` | same | carried |
| `--allow-broken-rustc` | same | carried |
| `-h/--help` | `gsa --help` | carried; the roster printed is authoritative |
| package refs: recipe ID / recipe path / case-variant ID / pacman pkgname incl. split outputs / typo + nearest candidates | same targets | carried verbatim (§C.1) |
| index ranges `22..38`, `22..`, `..15` | same | carried verbatim (§C.3) |
| `app` multi-select prompt, `app-cluster` rows | same behaviour | carried (§C.4) |
| core auto-install; core-runs-solo; `build-tools` dispatch band | scheduler invariants | carried (§K.2); core auto-install is subsumed by `-S` |
| `-s` waiver reasons, deferral reasons (rc 99) | same reason keys | carried (§F, §H) |
| signal/interrupt behaviour (exit 130, full record) | no flag | carried (§I.4, §K.3) |
| run-record `format: 1` | `format: 2` | **re-contracted** (§H) |
| `rr_*` fixture parser, 55 fixtures' argv shapes | v2 fixture parser + re-contracted fixtures | re-contracted once (§D.2, §L) |
| `--install-decide` | hidden `--install-decide` (same shape) | carried as hidden seam (§D.1) |
| `-si/--sepinstall`, any pre-2026-09-17 spelling | — | not carried (already retired) |

Deliberately NOT carried over, with reasons:

- `-s` as a short spelling — the pacman grammar owns short letters per family;
  `s` is search.
- `-i`/`--install` — install-before-dependents is the `-S` family's semantics,
  not an optional flag (rule 11 is satisfied by construction).
- `-g` — replaced by the `@` set namespace; a second group-selection grammar is
  exactly the drift class `CONTEXT.md` warns about.
- Byte-identical output strings, the `format: 1` block, and the old
  `--install-decide` row framing — clean-slate re-contract (§E, §H).
- The verb surface proposed in `plan-native-pm.md` §5.1 (`gsa sync`,
  `gsa build`, `gsa install`, …) — superseded by this action-pass grammar,
  except the single owner-named alias `gsa fetch` ≡ `-Sw`.

---

### B.10 Privilege (the transparent handle)

gsa is pacman-shaped: **reads run as any user; mutations require root.**

| Class | Spellings | Rule |
| --- | --- | --- |
| read-only | every `-Q*`, `-Ss/-Si/-Sl/-Sg`, `-Bl`, `--dry-run` plans, `-Ma`, report forms of `-Md/-Mi/-Ml/-Mh/-Ms/-Mw`, the hidden read seams (`--install-decide`, `--local-db-check`, `--qa-check`, `--stale-lock-check`), `--help` | any user; never writes state |
| mutating | `-S`, `-B`, `-U`, `-Sw`, `-Sy`, `-Su`, `-Mi --prune/--backfill`, `-Md --fix`, `-Ml --keep`, `-Mh --prune`, `-Ms/-Mw --add/--remove`, every `-Mc/-Mcc/-Mccc`, hidden write seams (`--install-register`, `--register-ignorepkg`) | **root required**; unprivileged → early refusal, **rc 3** (§G.1), wording `you cannot perform this operation unless you are root` plus a `sudo` remedy |
| build-user-only | `-Mm` (mirrors) | never under a root supervisor (`docs/source-sharing.md`); refused with rc 3 when euid 0 |

Under root (`sudo gsa …`):

- every build-side command (the makepkg family, recipe-code evals) is dropped
  to the **build user** (`SUDO_UID`/`SUDO_GID`) via `setpriv`, so `makepkg`
  never runs as root and recipe code never executes as root; the environment
  survives the drop (`GSA_BUILD_JOBS`, `MAKEFLAGS`, `SRCDEST`, fixture stubs);
- a bare root shell (no `SUDO_UID`) is refused for build-touching verbs with
  guidance to `sudo` from the build user — the engine never improvises a user;
- engine-side writes into build-user paths (recipe-tree publishes) are chowned
  back to the build user — the workspace is never left root-owned;
- one banner line on `err` names the split (`engine and pacman as root; makepkg
  and build-cache writes as <user> (uid N)`). Hidden seams stay quiet.

The gate runs **after each entry's usage preflights** and before the first
state write: §G.1's precedence (usage 2 > refusal 3) means a typo is always
reported before privilege. `--dry-run` renders plans and is never gated.

### B.11 Configuration, workspace resolution, and staging

**The `gsa.conf` layers** (plan-gsa-isolation.md W2): the engine auto-reads
`/etc/gsa.conf` (system) then `~/.config/gsa/gsa.conf` (user), user over
system over built-in defaults. Keys: `project`, `recipe_url`, `build_dir`,
`state_dir`, `recipe_dir`. `~` expands to the build user's home (`SUDO_UID`'s home when
running under `sudo`, else `HOME`); an unknown key or malformed line is an
error naming file:line and key — never a silent default (usage class, rc 2).
`GSA_CONF` replaces both auto-read layers with exactly one file (fixture and
hermetic control, like `GSA_STATE_DIR`).

**Workspace resolution** (plan-gsa-isolation.md W3), in order: the `project`
config key (dev/deployment override); the cwd walk (deprecated — a TTY run
notes it, pipe output stays byte-stable); the canonical recipe store — the
build user's working copy at `GSA_RECIPES_DIR` > config `recipe_dir` >
`<build-user-home>/.local/share/gsa/recipes` (§J.2), fetched on demand from
`recipe_url` (default: the recipe repository) by mutating runs and refreshed in
place by `gsa -Sy`. The store is BUILD-USER working data, never below the
state root (`--state-dir`/`GSA_STATE_DIR` never influence it), and a refresh
hard-resets it, so hand edits to it are not preserved — the dev checkout is
edit-only and `project` is the dev override (ownership and the one-shot
migration: §J.2). Every user-visible workspace-not-found path renders the
shared hint (code truth: `gsa_model::config::WORKSPACE_HINT`): *set `project`
in gsa.conf, run inside the recipe repository, or fetch the store with
`sudo gsa -Sy`* — the old cwd-only advice is retired.

**Standalone staging** (plan-gsa-isolation.md W4, target shapes in §C.1): a
run of standalone targets stages each as `packages/misc/<id>/` in its own
one-node workspace under `<state-dir>/standalone/` (`config/topology.conf`
record `<id>|packages/misc/<id>|misc|`, the build-defaults skeleton, no
edges), rewritten wholesale on every run (delete first). A `--dry-run` and a
run the privilege gate will refuse stage **ephemerally** under the temp dir
and clean up after dispatch — a dry run writes nothing (§B.10) and a refused
run leaves no state. The staged ids replace the run's targets and the entry
resolves its workspace as the staged one; each staged recipe tree is handed to
the build user (`own_to_build_user`, §B.10) so build-side commands may write
there. Staging failures (unreadable target, `curl` failure, unusable name) are
usage errors naming the target.

*Amendment (2026-10-17, recipe-store relocation out of the state root).* The
canonical store is no longer `<state-dir>/recipes`. Production class: makepkg-
family tools run AS THE BUILD USER (`setpriv`; makepkg refuses root) but their
write surface was the ROOT-OWNED store — `sudo gsa -Sy` died at `updpkgsums
could not refresh the checksums … ERROR: No write permission in
/var/lib/gsa/recipes/packages/stable/curl` → `anchoring-refused` — and the
sync's chown-back had already made store PKGBUILDs build-user-owned. Decided
semantics: the store resolves `GSA_RECIPES_DIR` env > config `recipe_dir`
(new key, `~` expands) > `<build-user-home>/.local/share/gsa/recipes`, is
build-user working data (the engine chowns what it lands: after fetch, after
migration, after a root-side git reset), and `--state-dir`/`GSA_STATE_DIR`
never influence it (§J.2/§J.3). §B.8's env roster gains `GSA_RECIPES_DIR`,
the twin of `recipe_dir` (`build_dir`/`GSA_BUILD_DIR` precedent). Pinned by
`tests/gsa-store-v2.sh` sections a/d/e/f/g and `tests/gsa-sync-v2.sh`
section 7.

## C. Selection semantics

Vocabulary is `CONTEXT.md`'s and is normative: **recipe**, **topology record**,
**build-order edge**, **consumer expansion**, **coupled batch**, **lane**,
**run record**, **continuation**, **deferral**. The word "dependency" means a
pacman dependency and is never used for a build-order edge.

### C.1 Targets

A target may be a recipe ID (`mesa-git`), a recipe path
(`packages/git/mesa-git`), a case-variant ID (matched and reported), a pacman
`pkgname` including a split output (`zen-browser` → `zen-browser-pgo`), an
archive path (only under `-U`), or a `@` set/group name. Exact lookup only: a
typo is NEVER auto-corrected — the command fails as a usage error (rc 2)
naming the unknown reference and the nearest candidates. A selection that
resolves to zero packages (for example a roster group with no members) is a
usage error (rc 2) with the reason `selection resolved to no packages` — never
a successful no-op.

**Standalone PKGBUILD input** (plan-gsa-isolation.md W4's distribution unit:
"sharing a package = sharing its PKGBUILD; rebuilding = gsa + the recipe, no
project clone required"). A target may also name a shared recipe directly:

- a `PKGBUILD` **file path** (only that file is staged; sibling local sources
  must be URLs — the v1 limitation is documented, not hidden),
- a **directory holding a `PKGBUILD`** (copied minus makepkg's output dirs
  `src/`, `pkg/`, `build/` and `*.pkg.tar.zst` archives at the top level), or
- a **URL** of a `PKGBUILD` (`http(s)://…`, or `file://…` for a local mirror —
  whatever `curl` speaks; only the PKGBUILD is fetched).

Each such target is **staged** as its own recipe in a one-node workspace and
the run operates on that workspace (§B.11's staging model). Workspace
references win: a token a discoverable workspace answers as a reference (the
vocabulary above) stays one even if it also names a directory holding a
`PKGBUILD` — documented recipe-path refs keep working inside the recipe
repository. A run cannot mix standalone targets with workspace references
(usage error naming both sets). Build/install/fetch/maintain runs and their
`--dry-run` plan take standalone targets; query/report verbs do not (yet) and
answer a usage error naming the limitation. The staged id is derived from the
target (directory name; the file's parent directory name; the URL path segment
before the `PKGBUILD` leaf), sanitized to the topology id charset.

### C.2 Groups and sets

Groups (`git`, `stable`, `core`, `misc`, `app`, `build-tools`) and user sets
(`config/sets/`) share one `@name` namespace. A name resolving to both a group
and a user set is a configuration error named by the strict loader. Group
membership comes from the topology record only (`docs/architecture.md`); it is
never inferred from directory names. The `build-tools` band (members dispatch
before other ready packages, never over build-order edges) and
core-runs-alone are scheduler invariants (§K.2), not selection semantics.

### C.3 Consumer expansion and ranges

A selection of X expands to X plus its transitive **consumers** — the reverse
build-order closure (a record listing B in `edges` consumes B). Prerequisites
are never expanded: they are assumed installed and current; bootstrap and
fresh builds use group runs. Rebuilding X cannot break what X consumes; the ABI
risk lives in X's consumers. `--leaf` suppresses the expansion and builds
exactly the named recipes.

Ranges (`22..38`, `22..`, `..15`) index the **selection** in build order after
expansion, exactly as the `-Sl` listing prints them. A range requires a
selection to anchor it; a bare range is a usage error. Group runs may cross
groups through consumers (`-S @git` may add `app` consumers via `glib2-git`);
the union of multiple targets/groups is deduplicated before sorting.

### C.4 The `app` prompt and `app-cluster` rows

An `@app` build or `--dry-run` on a TTY prompts to multi-select before the
normal pipeline runs: all unchecked + Enter = the whole group; any checked =
only those; `q` aborts with a usage-class exit. Non-TTY runs and listings take
the whole group silently. Records carrying the same `app-cluster=<name>` tag
present as ONE row (toggling checks the whole cluster; "N checked" counts
rows). The prompt is a FILTER in front of the normal pipeline: whatever it
returns becomes the group's contribution to the selection, and every later step
(expansion, sort, ranges, lanes) is the ordinary path. Cluster presentation is
presentation only — the packages stay separate in listings, the run record,
ranges, and lanes.

### C.5 Build order

The order is one topological sort over the build-order graph, validated on
every invocation; a cycle or a malformed topology record breaks every command,
naming the offender and line. Plan, listing, run-record and range order are all
that same topological order. The `build-tools` dispatch band changes when a
ready package is dispatched, never the order the record reports.

---

## D. Hidden test seams and stub conventions

Hidden seams are argv shapes that drive production code paths without a build.
They are excluded from `gsa --help`, excluded from the continuation table
(never mirrored — a continuation must never replay one), reject invalid
invocations with rc 2, and are callable only by fixtures.

### D.1 Hidden seam set (v2)

| Seam | Shape | Contract |
| --- | --- | --- |
| `--install-decide` | `gsa --install-decide <checked\|force> <archive…>` | prints decision rows (§E) on stdout and touches nothing else: no pacman, sudo, flock, or makepkg. rc 0 plan / 1 refusal / 2 bad usage |
| `--lane-job` | `gsa --lane-job <pkg> <result-path> <jobs> <flags…>` | the lane child entry: one package, one result file. Positional payload, control characters rejected, invalid flag/job rejected with rc 2 and a message naming the argument. Writes exactly one result row through the typed codec (§F.2) |
| `--fetch-job` | `gsa --fetch-job <pkg> <result-path> …` | **Phase 4** (`plan.md` §2.1): one-shot fetch child, `makepkg --verifysource` as the only fetch/verify engine. Publishes `ok\|failed\|skipped` + kebab reason (`not-a-candidate`, `vcs-only`, …). Advisory: it never writes a run-record row and never changes the run rc (`plan.md` §3.3) |
| `--stale-lock-check` | `gsa --stale-lock-check` | the production pacman-lock probe without a run (holder identification via `/proc/*/fd`, never `db.lck` deletion) |
| `--local-db-check` | `gsa --local-db-check` | the production pacman local-DB health probe without a run |
| `--install-register` | `gsa --install-register <conf> <subject> <names…>` | the IgnorePkg registration write path in isolation, including its bounded `db.lck` wait |
| `--qa-check` | `gsa --qa-check <name> …` | run exactly one QA check (today `--audit-lint <family>`); the check registry's single-entry point |

*Amendment (2026-10-14, cutover gap G10 — the `--lane-job` flags payload
grammar).* `<flags…>` is the makepkg argument set the lane forwards verbatim
(job flags included — `GSA_BUILD_JOBS`/`MAKEFLAGS` shaping happens before).
Each token is validated by `gsa-build::makepkg::check_flag_payload`: non-empty,
no control characters, short flags `-<alnum…>`, long flags `--<name[=value]>`
(name `[a-z-]+`, value free of control characters), and the three
verification-bypass tokens `--skipchecksums`, `--skippgpcheck`, `--skipinteg`
are **forbidden anywhere in `gsa`** (§A.3.4/§L.8) — a payload carrying one is
a usage error naming the argument (rc 2), never a build.

### D.2 Stub-knob convention

`GSA_FAKE_*` names belong to FIXTURES, never to the engine. Every knob a stub
reads is declared in the vocabulary table of the fixture library
(`tests/lib/fixture-lib.bash` today; its v2 successor keeps the same role) and
added there in the same change that introduces it. The engine's own inputs are
exactly the `GSA_*` roster in §B.8; `GSA_BUILD_JOBS` is engine output. A
fixture must never need a new engine-side knob to express a scenario — the
scenario is expressed with a stub (this is the rule the house fixtures already
follow). Fixtures remain bash, non-mutating, `$TMPDIR`-scoped, parallel-safe,
and discovered by the runner; the v2 `rr_*` successor parses the `format: 2`
block and derives expectations from its rows rather than prose.

---

## E. Decision rows and the rc contract

### E.1 One decision, one seam

The install decision is computed ONCE, as typed rows, by one function
(`docs/MEMORY.md` rule 20). Rendering and execution never re-decide. The hidden
`--install-decide` seam prints exactly those rows. Transactions are `pacman -U`
subprocesses; a future libalpm executor must consume the same rows without
changing them.

### E.2 Row grammar

```
<pkgbase> <decision> <reason…>
```

One row per archive candidate, in plan order, full rows (never
exceptions-only), single spaces between the first two fields; `<reason…>` is
the remainder of the line (a kebab reason key, optionally followed by detail).
This framing replaces the tab-framed `plan_row` codec of `build-all.fish`;
fixtures parse fields positionally with the reason as the remainder, as the
run-record rows do.

*Amendment (2026-10-14, cutover gap G1/§E.2).* "One row per archive
candidate" is one row per candidate **finding**: a candidate with several
findings — several PGO hits, a PGO refusal stacked on an ABI refusal —
carries several rows sharing its subject (code truth:
`gsa-install::decide`; the fixtures pin "a refusing PGO/ABI candidate emits
several"). The seam keeps that granularity; the run record collapses it per
subject (§H.2, same date).

### E.3 Row vocabulary

| Decision | Meaning |
| --- | --- |
| `install` | the archive clears every gate and joins the transaction |
| `skip` | deliberately not transacted, with a named reason — `already-current` (checked mode: exact version installed with an install date not older than the archive), `skip-built`/`freshness-waived`/`abi-provider-waived` installs of a skipped build (the archive still installs), `unreadable-pkginfo` (excluded from discovery, never probed — `docs/MEMORY.md` rule 25(h)) |
| `refuse` | fail-closed: this row and everything downstream of it abort before any `pacman` call. Reasons include `empty-list`, `pgo-*` (baked profiling destination), `abi-soname`, `abi-consumer`, `abi-consumer-uncovered` (a moving/removed soname provide with a linked consumer outside the transaction — rule 25(d)), `abi-stock-pinner` (an out-of-tree package pins the moving provide exactly — 2026-10-14 amendment: named here as the code emits it, `gsa-abi::rows::abi_refusal_rows`), `partial-set`, `discover-failed`, `plan-failed`, and any `severity: refuse` QA keyword (§E.4) |
| `noop` | nothing to do and that is not a failure — `empty-list` under `-Ua` |
| `parked` | **new**: the package is parked — `waits-on-failed` (cone-stop) or `waits-on-deferred` / a deferral reason (`anchoring-refused`, `upstream-unverified`, `source-unfetchable`). The seam neither installs nor refuses; the row records the park |

*Amendment (2026-10-14, gap G1 — the repair surface).* In-run repair
coverage (rule 25(d)) never adds a decision kind: when the ABI gate's
`abi-consumer`/`abi-stock-pinner` refusal is suppressed because the consumer
is scheduled later in the same run (`DecisionContext.later_installs`), the
provider's plan row carries `repair <consumer> <provider-id>` detail in its
open REASON, and the provider's install stages the consumer's forced-rebuild
marker (`<state>/abi-repair/<consumer-id>`) before the transaction. The seam
itself stays order-blind (`--install-decide` takes no run order), so its rows
for that state are the refusal rows. Write half deferred — see §M.

### E.4 QA gate line

Every QA check declares `name`, `scope` (`recipe|topology|host|install`),
`severity` (`report|refuse`), and a stable keyword. **`report` is the default.**
A `refuse` check emits `refuse <keyword>` decision rows and can stop an
install; the existing fail-closed classes above are `refuse` by construction. A
new `refuse`-severity check must state in its change why `report` is
insufficient. Audit lints (`gsa -Ma`) stay **report-only by contract**
(`CONTEXT.md` "Audit lint"): an audit run never refuses anything and exits 0;
gating happens in fixtures.

### E.5 rc contract (decision seam)

- **0** — a plan was produced and contains no `refuse` row (`install`, `skip`,
  `noop`, `parked` rows may all be present).
- **1** — the plan contains at least one `refuse` row. The full plan is still
  printed. A refusing plan is pacman-free end to end (rule 25(h)).
- **2** — bad usage (unknown mode, malformed archive argument, unreadable
  argument list).

`parked` alone never yields rc 1: parking is a deferral-class event (§I.3),
not a safety refusal. The seam never defers by itself — deferral originates in
the build path (rc 99) and is *reported* here as `parked`. The seam refuses
when a safety/completeness gate fails for an otherwise installable archive; it
reports `parked` when no trustworthy archive or no valid install position
exists at all.

---

## F. Outcome vocabularies

### F.1 Lane outcome codes (process boundary)

| Name | Code | Meaning |
| --- | --- | --- |
| `ok` | 0 | built (and, for `-S`, its install succeeded) |
| `failed` | 1 | build or its install failed |
| `parked` | 98 | **new**: the lane child stood down before building (spawn-to-build race after its cone was parked); nothing was built |
| `defer` | 99 | non-failure park: `anchoring-refused`, `upstream-unverified`, `source-unfetchable` (the only paths that emit it) |
| `lost` | 125 | reap anomaly: the child vanished without a publishable result |
| `hup` | 129 | killed by SIGHUP during teardown |
| `int` | 130 | killed by SIGINT |
| `term` | 143 | killed by SIGTERM |

Codes are stable wire values; names are the typed enum. `parked` (98) is the
cone-stop state crossing the boundary; a package parked before dispatch never
gets a lane and appears only as a run-record row (§H).

*Amendment (2026-10-17, teardown classification + receipt discipline).*
`lost` (125) is the **non-teardown** reap anomaly only. In an interrupted
run, a lane that dies without a publishable result during teardown settles
`interrupted-mid-build` under the interrupted signal's code — the no-result
branch now matches the long-standing late-result rule — while a vanished lane
in a run that was never interrupted still settles `lane-lost` (125). And a
lane child now acts on its signal receipt: it never spawns makepkg under a
pending receipt and TERMs its own makepkg on receipt mid-build (§K.3's
one-TERM-per-group discipline is the supervisor's group sweep; a lane
signalling its own child is not a second group TERM).

Run-record per-package statuses are a second, coarser vocabulary
(`succeeded|failed|deferred|parked|never-started|interrupted`, §H.3); the
mapping from lane code to status is total and defined in §H.3.

### F.2 Wire rule

1. **Typed codec.** A lane outcome crosses the process boundary ONLY through
   the codec: enum + reason key + duration → one line
   (`v2 <pkg> <code> <dur> <reason…>`), and back. No hand-built rows, no
   string comparisons on names in the dispatcher. A line that fails validation
   (unknown version tag, unknown code, control characters) is rejected and
   mapped to `lost 125` with a loud diagnostic naming the file — never
   silently accepted.
2. **Atomic publication.** Each lane child writes its result to a temp name in
   the same directory (`<result>.tmp.<pid>`) and publishes with `rename(2)`.
   Readers must ignore non-final names and must tolerate exactly one final
   result per lane; a second publication is a reap anomaly (`lost`).
3. **Round-trip.** encode→decode is an identity on valid outcomes (property
   test, `plan-native-pm.md` §9); decoding must fail closed, never guess.

---

## G. Exit codes

### G.1 Run-level

| Code | Class | Condition |
| --- | --- | --- |
| 0 | success | every selected package `succeeded` (including skip reasons); no `failed`, `deferred`, or `parked` row |
| 1 | build failure under `--fail-fast` | ≥1 `failed` row and dispatch stopped (drain completed) |
| 2 | usage error | bad flags, unknown reference/typo (with nearest candidates), invalid range, **empty selection** (`selection resolved to no packages`), malformed config record or `gsa.conf` layer (§B.11), a standalone-target refusal (mixed with workspace references, query/report verb, staging failure — §C.1) |
| 3 | refusal | the run refused to start or aborted at a fail-closed gate: privilege refusal (§B.10 — not root, no build user, or `-Mm` under root), preflight (`sudo cannot install non-interactively`), integrity stop (published checksum mismatch — `docs/build-guide.md`), install refusal (a `refuse` decision row reached execution), confirmation gate (`-Mm`/`-Mccc` without `--noconfirm`: plan printed, `confirmation-required` — the engine never prompts, §K.3) |
| 4 | parked-cone-with-failures | **cone-stop (default) run with ≥1 `failed` row** — dispatch continued with unrelated work; parked rows may be empty when the failed package is a leaf |
| 5 | deferral-only | ≥1 `deferred`/`parked` row and no `failed` row (extension of the six-class list; preserves "a deferral exits non-zero" without claiming a build failure) |
| 130 | interrupted | a signal terminated the run; the full run record is emitted first |

**Precise answer for the cone-stop case:** a cone-stop run in which at least
one package failed and others succeeded returns **4** — not 0 (a failure
happened), not 1 (that code means dispatch stopped). This holds whether zero,
one, or many packages were parked.

Precedence on a completed run: usage (2) > refusal (3) > failure (4 or 1 per
policy) > deferral-only (5) > success (0). An interrupted run exits 130
regardless of earlier failures; the record still carries them.

### G.2 Per-package lane codes

The lane codes of §F.1 (0, 1, 98, 99, 125, 129, 130, 143). A lane's exit code
IS its outcome code; the codec carries it, and the dispatcher never infers an
outcome from prose or log content.

---

## H. Run-record machine block — `format: 2`

### H.1 Invariant (kept from ADR 0003)

ONE run record — plan + per-package outcome rows + continuation — is computed
once, as one typed structure, and rendered three ways: the streaming dashboard,
the prose summary, and the machine block. The three renderings are views of the
same rows; no rendering re-derives state. The block is default-on, printed to
stdout after the dashboard finishes, and emitted on the interrupt and
preflight-refusal paths too.

**One deliberate amendment to ADR 0003:** the record is now also *persisted*
into the side-car run history (§J.2, `gsa -Mh`), because the side-car DB owns
run history by owner decision. Persistence is storage of the same structure,
not a fourth derivation. `docs/adr/0003-run-record.md` must record this
amendment (§L).

### H.2 Grammar

```
block   = "--- run record begin ---" NL
          *scalar                       ; key: value, fixed keys first
          "--- plan ---"      NL *plan-row
          "--- outcome ---"   NL *outcome-row
          "--- continuation ---" NL *continuation-line
          "--- run record end ---" NL
scalar  = key ":" SP value NL           ; key = [a-z0-9-]+, value = rest of line
plan-row     = pkg SP plan SP reason… NL
outcome-row  = pkg SP status SP rc SP dur SP reason… NL
continuation-line = key ":" SP value NL
```

Scalars (fixed order): `format` (`2`), `selection-source`, `order`, `lanes`,
`normal-jobs`, `core-jobs`, `intensity`, `outcome`, `rc`. Extension scalars may
be appended after the fixed set without a format bump. Values never contain a
newline or a line starting with `--- `.

*Amendment (2026-10-14, cutover gap G2 + budget conformance).* Three
tightenings of this grammar, all code truth (`gsa-model::RunRecord::
render_machine`, `gsa-model::RunOutcome`, and the strict `format: 2` parser
`tests/lib/rr-v2.bash rr2_body`), recorded here rather than invented in the
parser:

1. **Budget scalars are always non-negative integers.** `lanes`,
   `normal-jobs` and `core-jobs` render `0` — never `-` — for any record
   whose run dispatched nothing (dry-run plan records, `-U` transaction
   records, preflight refusals). `-` remains valid ONLY for a row's
   `rc`/`dur`.
2. **`selection-source:` grammar** (previously example-only):
   `sets=<targets,…|-> leaf=<yes|no> range=<ranges,…|->`. The `leaf=no`
   VALUE is a value, not a flag spelling — see §B.8's `--leaf` mirroring.
3. **`outcome:` vocabulary (gap G2, previously opaque):** `planned` (dry
   run), `success`, `refused`, `failed`, `deferral`, `interrupted`. A new
   outcome value is a grammar change (§L.2) and lands here in the same
   change.

**Rows are now first-class** — plan rows, outcome rows and the continuation
section coexist with distinct column grammars. That is why this is a new
format: in `format: 1` any non-scalar line was a package row, so a plan or
continuation row would have poisoned the row stream (`tests/lib/fixture-lib.bash`
`rr_rows`).

Plan row `plan` values: `build`, `build-install`, `install`, `fetch`, `skip`
(reason `skip-built`/`freshness-waived`/`abi-provider-waived`), `parked`
(reason `waits-on-failed`/`waits-on-deferred`), `refused`, `noop`. Rows are
full (one per selected package), in topological order.

*Amendment (2026-10-14, cutover gap (a) — multi-row candidates).* "One per
selected package" is normative for the record even when the decision seam
produced several rows for one package (§E.2's per-finding rows): a `-U`
record **collapses per subject** — one plan row and one outcome row per
package, `order` free of duplicates (the strict parser rejects duplicates).
The plan action is the strongest of the group (`refused` > `parked` >
`install` > `skip` > `noop`), the outcome status the worst (`failed` >
`interrupted` > `deferred` > `parked` > `never-started` > `succeeded`, so
`remaining:` keeps any subject that did not fully succeed), `rc`/`dur` come
from the winning outcome row, and the reason is every row's reason joined in
row order (exact repeats dropped). The `--install-decide` stdout keeps full
per-finding granularity (it is the first rendering, §E.1). A plan whose rows
already explain a refusal (every candidate rejected before the seam — a
shrunken split set, a failed discovery) never synthesizes an `empty-list`
row: `empty-list` belongs to a genuinely empty candidate plan.

Continuation lines: `command:` (the restated invocation), `remaining:` (space-
separated package IDs — every row not `succeeded`, in row order: failed,
parked, deferred, never-started, interrupted — a failed package must rebuild
before its consumers), `not-mirrored:` (the flags deliberately not replayed),
`env-required:` (ambient variables the resume must set). Continuation
arguments come from ONE flag-rule table with an explicit not-mirrored list;
`--dry-run`, `--leaf`, `--skip`, `--skip-built`, `--vcs-skip-tolerance`,
`--no-sync`, `--allow-broken-rustc`, `--fail-fast`, and the resolved
`--lanes`/`--jobs`/`--intensity` values are mirrored as explicit flags;
prune strengths, one-shot actions (`-Q*`, `-Sy`, `-Ua`, `-M*`), and hidden
seams are never mirrored. Environment inputs are warned about (`env-required`),
never baked in.

*Amendment (2026-10-14, cutover gap (b)/G4 — the flag-rule table as
implemented).* The mirrored set is exactly what
`crates/gsa-cli/src/record.rs` (`mirror_flags`/`NOT_MIRRORED`) replays, and
the resume fixtures pin that a dropped semantic flag is a bug. Mirrored:
`--dry-run`, `--leaf` (**true form only**), `--skip`, `--skip-built`,
`--vcs-skip-tolerance N`, `--no-sync`, `--allow-broken-rustc`, `--fail-fast`,
`--state-dir PATH`, `--config PATH`, `--no-register-ignorepkg`,
`--no-prefetch`, `--prefetch-ahead N` (non-default only), the `f` cluster
letter, and the resolved `--lanes`/`--jobs`/`--intensity` values. Never
mirrored: the prune-strength `c` and `-Mc`/`-Mcc`/`-Mccc`; one-shot actions
(`-Q*`, `-Sy`, `-Su`, `-Ua`, `-M*`) and their sub-flags (`--fix`, `--prune`,
`--backfill`, `--tail`, `--keep`, `--show`, `--add`, `--remove`);
`--noconfirm`, `--quiet`, `--verbose`; and every hidden seam (`--install-decide`,
`--lane-job`, `--fetch-job`, `--stale-lock-check`, `--local-db-check`,
`--install-register`, `--register-ignorepkg`, `--qa-check`). **`--leaf` is
mirrored only as the bare flag when true (gap G4): `--leaf=no`/`--leaf=yes`
are not spellings §B.8 defines and must never appear in `command:` — a
non-leaf continuation mirrors nothing and the absence IS the negation.**
`--state-dir`/`--config` are mirrored because a resume that loses the state
root or the IgnorePkg registration target changes behaviour — the previous
list here was incomplete, not the code excessive.

### H.3 Status vocabulary and reason keys

| Status | Lane code(s) | Reasons |
| --- | --- | --- |
| `succeeded` | 0 | `ok`, `skip-built`, `freshness-waived`, `abi-provider-waived` |
| `failed` | 1, 125 | `build-failed`, `install-failed`, `lane-lost`, `log-unwritable` |
| `deferred` | 99 | `anchoring-refused`, `upstream-unverified`, `source-unfetchable` |
| `parked` | 98 | `waits-on-failed`, `waits-on-deferred` (and `coupled-batch` if the open decision resolves that way) |
| `never-started` | — | `dispatch-stopped`, `preflight-refused`, `interrupted-before-start`, `never-ready` |
| `interrupted` | 129, 130, 143 | `interrupted-mid-build` |

`blocked` (the `format: 1` name for `waits-on-deferred`) is superseded by
`parked`; deferral semantics themselves are unchanged (§I.3). A reason key
never claims more than the row means — a waiver row keeps its waiver reason,
not `ok`.

*Amendment (2026-10-14, cutover gap G3 — additive keys named).* §L.2 makes
reason keys open; this closes their opacity. Observed additions beyond the
table above (fixtures pin them): `mutex-timeout` (failed),
`result-clear-failed` (failed), `signal-term`/`signal-hup`/`signal-int`
(interrupted — the signal that ended the lane; `interrupted-mid-build` stays
the no-signal case), `install-refused <cause>` (never-started — the §E.3
refusal seen through the outcome rendering), `dry-run` (never-started),
`held-after-install-failed` (never-started — a staged wave group after an
earlier group failed), `log-unwritable` and `interrupted-mid-build` as
listed. Any new key lands here in the same change.

### H.4 Annotated example

```
--- run record begin ---
format: 2
selection-source: sets=@git leaf=no range=-
order: glib2-git gtk4-git gimp-git niri-spicy-git
lanes: 2
normal-jobs: 6
core-jobs: 4
intensity: xhigh
outcome: failed                    <- run-level outcome, from the rows below
rc: 4                              <- cone-stop run with a failure (§G.1)
--- plan ---
glib2-git build-install ok         <- planned action before dispatch
gtk4-git build-install ok
gimp-git build-install ok
niri-spicy-git build-install ok
--- outcome ---
glib2-git failed 1 812 build-failed        <- the failure
gtk4-git parked - - waits-on-failed        <- consumer cone parked (§I.1)
gimp-git parked - - waits-on-failed        <- cone reaches it through gtk4-git
niri-spicy-git succeeded 0 1450 ok         <- unrelated work ran to completion
--- continuation ---
command: gsa -S glib2-git gtk4-git gimp-git
remaining: glib2-git gtk4-git gimp-git
not-mirrored: -Mcc -Mccc -Sy
env-required: GSA_STATE_DIR
--- run record end ---
```

`rc` and `dur` are integers (seconds) or `-` when the package never produced
one. The reason is the remainder of the line.

---

## I. Failure policy

### I.1 Cone-stop is the default everywhere

A failed package **parks its dependent cone**: the transitive closure of its
consumers over build-order edges, computed from the topology at run start.
Parked packages are not dispatched, get explicit run-record rows
(`parked waits-on-failed`), and land in the continuation's `remaining` list.
Dispatch continues with every package outside the failed package's cone. The
run exits non-zero (§G.1: code 4).

### I.2 What happens to lanes already running

In-flight lanes are NEVER killed by a failure. They drain; their builds and
installs complete and their outcome rows stand. Only dispatch of not-yet-started
cone members is suppressed. A lane child that was spawned but had not started
its build when the park landed writes `parked 98` (§F.1).

### I.3 `--fail-fast`, deferral, and interrupt

- **`--fail-fast`** restores the old contract: the first failure stops new
  dispatch, in-flight lanes drain, unstarted packages become
  `never-started dispatch-stopped`, and the run exits 1.
- **Deferral keeps its existing semantics and is independent of both modes**: a
  rc-99 lane (`anchoring-refused`, `upstream-unverified`,
  `source-unfetchable`) parks only its own dependents
  (`parked waits-on-deferred`), dispatch continues with unrelated work in
  `--fail-fast` runs too, and the run exits non-zero (5 when it is the only
  blemish). A deferral never licenses a skip and never fails the run.
- **Interrupt**: one signal → §K.3 teardown → exit **130** with the full run
  record (plan, outcomes, continuation) exactly as a completed run prints.
  What started is `interrupted interrupted-mid-build`; what never launched is
  `never-started interrupted-before-start`.

### I.4 Loud reporting (the fail-fast mitigation)

Today's documentation calls fail-fast load-bearing: it stopped the 2026-09-06
rust-git-against-minimal-llvm-git class from compounding
(`docs/MEMORY.md` rule 11 context; `plan-gentoo-qol.md` M4/Q2). The owner chose
cone-stop as the default anyway; the mitigation is **loud reporting plus the
escape flag**, and both are normative here:

1. the prose summary names every failed package with its log path, the full
   parked cone with each member's park reason and the failure that parked it,
   and every deferred package with its reason;
2. the machine block carries the same rows (`parked` is a status, not prose);
3. the exit code is distinct and non-zero (4), so an unattended script cannot
   mistake a continued run for a clean one;
4. `--fail-fast` exists, is documented in `gsa --help`, is mirrored in
   continuations, and is fixture-covered.

---

## J. State layout

### J.1 `/var/lib/gsa` (the state root)

| Path | Content |
| --- | --- |
| `/var/lib/gsa/index/` | the binpkg index (J.4) |
| `recipes.last-fetch` (in the state root) | the recipe store's fetch/refresh stamp — state, not store: the store itself lives outside the state root (§J.2) |
| `/var/lib/gsa/standalone/` | standalone-target staging work areas (§B.11, §C.1): one staged one-node workspace per run, rewritten wholesale |
| `/var/lib/gsa/abi/` | ABI token records and subscription records (`consumer\|version\|provider\|token`), installed-ELF index (Phase 4), preserved-lib registry (Phase 4) |
| `/var/lib/gsa/world`, `/var/lib/gsa/sets/` | the world file and user sets (`config/sets/` remains the committed source; the state root holds the runtime copy) |
| `/var/lib/gsa/runs/` | run history: one recorded run record per run (the `format: 2` struct), its continuation, and the bounded retention bookkeeping |
| `/var/lib/gsa/logs/` | per-package build logs (today `.state/logs/`) |
| `/var/lib/gsa/locks/` | the pacman mutex and run lock |
| `/var/lib/gsa/toolchains/` | per-recipe toolchain identity records (GCC-identity invalidation, `docs/architecture.md` §4) |
| `/var/lib/gsa/abi-repair/` | forced-rebuild markers for in-run ABI repair (rule 25(d)) |

Logs live under the state root, not `/var/log/gsa`: one root means one
ownership rule (§J.5), one override, and one prune story; these are per-run
engine artifacts, not syslog material.

*Amendment (2026-10-17, recipe store moved out of the state root).* The former
`/var/lib/gsa/recipes/` row is gone: the canonical recipe store is build-user
working data outside the state root (§J.2), and the root keeps only the
`recipes.last-fetch` refresh stamp. `--state-dir`/`GSA_STATE_DIR` therefore
relocate engine state only, never the store (§J.3). Pinned by
`tests/gsa-store-v2.sh` sections a/d/e/f/g and `tests/gsa-sync-v2.sh`
section 7.

*Amendment (2026-10-23, lane-state markers).* Two run-scoped observability
files join the state layout — they make "is it stuck?" answerable without the
event stream:

| Path | Content |
| --- | --- |
| `/var/lib/gsa/runs/current` | a pointer file naming the live run id (atomically replaced at run start; keeps naming the last run after it ends) |
| `/var/lib/gsa/runs/<run-id>/<pkg>.started` | one line `pid=<pid> epoch=<secs> log-offset=<bytes>` per spawned lane — the log offset is sampled BEFORE the spawn, because `logs/<pkg>.log` is appended across runs and the offset is what makes a tail run-scoped |

Observability, never behaviour: a marker/pointer write failure is a loud
`note` event and never stops a run (unlike §F.1's fail-closed park markers).
The startup orphan sweep reaps a dead run's `.started` files with its `.result`
/`.park` files. Pinned by `supervisor::tests::
lane_state_markers_and_the_view_tick_land_during_a_run` and consumed by the
dashboard tails (`tests/dashboard-pty.sh` section A).

### J.2 What stays with the build user (W4's relocation)

makepkg's working state lands in the **build user's cache**, never beside the
recipe: the engine passes `BUILDDIR` (build trees), `PKGDIR` (staging) and
`PKGDEST` (finished `.pkg.tar.zst` archives) at `$GSA_BUILD_DIR` /
config `build_dir` / `<build-user-home>/.cache/gsa` (`build/`, `pkg/`, `pkgs/`
below it), creating and handing those dirs to the build user (§B.10).
`SRCDEST` stays governed by `makepkg.conf` untouched. The binpkg index refers
to the archives by hash wherever they live; archive discovery scans the shared
`PKGDEST` plus the recipe dir (pre-W4 trees) and matches every candidate by
`.PKGINFO`/output-name truth, so a shared `PKGDEST` can never hand over
another recipe's archive. Per-archive VCS revision baselines stay with their
archives.

**The canonical recipe store** (2026-10-17 relocation) is also build-user
working data, never engine state. It resolves `GSA_RECIPES_DIR` env > config
`recipe_dir` (`~` expands) > `<build-user-home>/.local/share/gsa/recipes`
(`gsa_model::config::recipe_root`) and is deliberately NOT below the state
root: build-domain tools (makepkg, `updpkgsums`, recipe-eval bash) run as the
build user (§B.10) and must be able to write where they run. It is the build
user's working copy of the recipe repository, fetched from `recipe_url`
(default: the recipe repository's origin) and refreshed in place by `gsa -Sy`
(`fetch origin HEAD` + hard reset — hand edits are not preserved); the dev
checkout is edit-only, `project` its override (§B.11). The engine chowns what
it lands — after every root-side clone/fetch/reset, after migration — and only
engine-created directory levels are ever handed over (class-b hardening: a
user-configured store root or `build_dir` root is never recursively chowned).
One-shot migration (`gsa_state::recipes::ensure_store`, fired on read paths
too, so there is never two-store ambiguity): a legacy `<state-dir>/recipes`
with the resolved store absent is MOVED into place — `rename(2)`, falling back
to `mv` across devices — preserving `.git` and any dirty worktree byte-for-
byte, then chowned, with one loud note; when BOTH trees exist the resolved
store wins, the legacy tree is left in place with a note and never deleted; a
move failure is a hard error naming the manual remedy (`move it manually or
run sudo gsa -Sy once`).

### J.3 State-dir override (first-class)

`--state-dir PATH` beats `GSA_STATE_DIR` beats the `gsa.conf` layers'
`state_dir` (§B.11) beats the built-in `/var/lib/gsa` — fixtures use a
`$TMPDIR` workspace, unprivileged runs may use a user-writable path. When the
resolved root is unwritable and no override is given, the run fails early,
naming `--state-dir` as the remedy. There is never a silent fallback to a home
or workspace-local directory: a split state root is the failure mode §J.5
exists to prevent. `GSA_BUILD_DIR` (or config `build_dir`, §J.2) is the
matching override for the build cache — the two roots are relocated
separately and never silently merged. The canonical recipe store is
deliberately outside this override: `--state-dir`/`GSA_STATE_DIR` never
influence it (§J.2) — its twins are `GSA_RECIPES_DIR` and config
`recipe_dir`.

### J.4 The binpkg index (hash-bound, manifest-v2 style)

One row per retained built instance:

```
pkgbase|pkgname,…|full-version(epoch:pkgver-pkgrel)|archive-filename|sha256|size|abi-token|provides|vcs-baseline|built-at
```

`sha256` and `size` are computed from the archive bytes at index-write time;
the row is written only after both are known (fail closed on divergence). An
archive whose bytes disagree with its row is index-invalid: it never installs,
and `-Md` reports/repairs it. `-s` currency, install discovery, and provenance
read the index instead of re-deriving filenames. The ABI token is **derived**:
`hash(sorted bare-soname provide set actually shipped)` (bare stems only —
`libfoo.so`, never the auto-versioned form; `docs/MEMORY.md` rules 25(a) and
30), with an optional declared `abi-rev=<n>` topology tag as an override for
ABI moves derivation cannot see (LLVM C++ ABI snapshots, Qt private API —
`docs/MEMORY.md` rules 5 and 13). The token is recorded in the index row at
build time and in the installed-ABI record at install time. **Signed indexes
are deferred** (owner decision); the index is tamper-evident only through
content hashes.

### J.5 Write-time ownership (rule 19)

Every state file is owned by the **privileged runner** from the moment it is
created: mutating runs are root (§B.10), so engine state (`index/`, `runs/`,
`logs/`, `locks/`, `kv/`) is root-owned and `run.lock` root-owned is correct
state, not corruption (plan-gsa-isolation.md). The gate covers the state root
ONLY: the canonical recipe store (§J.2) is build-user working data outside it —
build-user ownership there is correct state, and a root-owned store is the bug
class the 2026-10-17 relocation removed. The write-time gate quarantines
any file owned by someone the running engine is not as
`<path>.stale.<epoch>.<pid>` (preserved, announced — never a silent adoption)
before the write opens it, or fails naming the remedy (`--state-dir`). The
pacman mutex inode is the exception that proves the rule: a transaction flocks
it in place (`sudo -n flock -x -w 600`, `crates/gsa-build/src/shim.rs`) and a
possibly-held lock inode is never renamed. Any new state-write site must pass
the ownership gate before opening.

*Amendment (2026-10-17, fd-based gate).* The gate opens the target with
`O_NOFOLLOW` and checks the fstat of the very fd the write uses (one seam,
`gsa-sched::lock`; the `gsa-state` gate is a thin wrapper), closing the
symlink-follow and check-then-use races on the final path component. Residual
(scope, not oversight): parent path components still trust the runner-owned
state root.

---

## K. Concurrency and process contract

### K.1 Lanes

A lane is an isolated child process group per package that **exec's** the
makepkg supervisor — no interpreter per lane. Build-side commands are dropped
to the build user (§B.10); `makepkg` never runs as root. The engine exports
the lane's job count as `GSA_BUILD_JOBS` and rewrites `MAKEFLAGS`/`NINJAFLAGS`
(stripping their `-jN`, preserving the caller's other flags). Every makepkg
spawn additionally carries `BUILDDIR`/`PKGDIR`/`PKGDEST` for the build-user
cache (§J.2) and `GIT_CONFIG_COUNT=0`; the `PACMAN` shim keeps makepkg's own
dependency installs on the transaction lock (§K.3). Per-package logs are
written under the state root through the ownership gate (§J.5).

### K.2 Scheduling invariants (kept)

Selection is mandatory; build order is meaningful; under `-S` each package is
installed before its consumers compile; `core` members run alone with a
separate memory-aware job budget; the `build-tools` band dispatches its members
before other ready packages but never over build-order edges; resource budgets
are host-derived (intensity profiles) and never hand-predicted — the plan line
the run prints is the truth. A deferral parks one recipe and never stops
dispatch; a failure parks a cone (§I).

### K.3 Transactions and signals

- **One `pacman -U` at a time**, serialized by the state-root mutex; makepkg's
  own dependency installs are routed through the same lock (the `PACMAN` shim).
  A system `db.lck` is NEVER deleted automatically; lock idleness is proven by
  an open-file-descriptor scan, not by filenames.
- **`sudo -n` only.** The engine never prompts (a TTY changes nothing). The
  preflight refuses to start an install run whose installs cannot succeed;
  a credential lost mid-run stops dispatch exactly once, drains in-flight
  lanes, and exits non-zero.
- **Signals**: the first signal sends ONE `SIGTERM` to each child process
  group, starts a shared grace window, then `SIGKILL`s survivors. A second
  signal escalates immediately (kill children now, no further grace). The run
  then writes the full run record (§H) and exits 130. SIGHUP/SIGTERM/SIGINT
  receipt by a child is reported through the lane codes 129/143/130.
  *Amendment (2026-10-14, gap G5 closed by documentation):* the grace window
  is 30 s (`gsa-sched::signals::STOP_GRACE_DEFAULT_S`) and its knob is
  `_GSA_STOP_GRACE_S` — deliberately **not** in the §B.8 roster: an
  unadvertised fixture override (the fish `_LANE_STOP_GRACE_S` seam carried
  over unchanged), unparsable values falling back to the default.
- **Orphan sweeps**: startup and post-run sweeps reap `--lane-job` /
  `--fetch-job` processes from earlier runs whose result files are unowned,
  and stale run artifacts (`.tmp.*`, abandoned result files). Unrelated
  `makepkg` processes are never touched.

---

## L. Change-control rules

1. **Every new flag lands in three places in the same change**: `gsa --help`
   (the authoritative roster), the continuation flag-rule table (as `mirrored`
   or `not-mirrored`, explicitly), and at least one fixture. A flag absent from
   the table is a bug; a flag absent from `--help` does not exist.
2. **Row/record grammar changes bump the format number** (`format: 2` → `3`),
   land with the parser fixture updated in the same change, and are listed in
   this document. Additive scalars and additive reason keys do not bump.
3. **Fixture expectations are derived from records, never from pinned counts**
   (`docs/MEMORY.md` rule 25(j)): sizes, cone membership, order, and remaining
   sets are computed from the topology and the run record the run produced.
4. **Every check is falsified red-first**: before trusting a new check, break
   one input in a scratch copy and watch it fail naming what broke. A check
   that cannot fail is deleted, not kept green.
5. **Fixture conventions hold**: non-mutating, `$TMPDIR`-scoped, parallel-safe,
   stub-driven through `GSA_FAKE_*` (§D.2), sibling scenarios as `( subshell )`
   sections in one file per subject, expectations asserted on the machine
   record (prose is pinned in exactly one rendering test).
6. **Behavioural changes to scheduling, install, state, or signals require a
   fixture in the same change** — there is no CI and no compiled test surface
   beyond fixtures and `makepkg`; a real rebuild is never a syntax check.
7. **`docs/MEMORY.md` and `docs/adr/` move with the contract**: an operational
   contract change updates the matching MEMORY rule; this document's amendment
   to ADR 0003 (run-record persistence, §H.1) must be recorded in that ADR
   when the side-car run history lands.
8. **Verification is never weakened to get green** (`docs/MEMORY.md` rule 15;
   §A.3.4): no `--skipchecksums`, no `--skippgpcheck`, no dropped `#signed`, in
   any code path including hidden seams and future phases.
9. **Two vocabularies, one meaning** (owner decision 2026-10-23): the human
   default is readable prose — a TTY run renders the live progress box
   (progress header, per-lane rows with run-scoped log tails, spinner +
   last-event footer), a pipe renders append-only event lines plus the 10 s
   `STATUS:` hint under `--human`; the machine vocabulary is the leveled
   `LEVEL event k=v` grammar (`output::kv_line`: one line per event,
   space-free values, `action=` names the next move). Every event renders in
   BOTH vocabularies and the machine grammar is unit-pinned
   (`render::tests`), the box is fixture-pinned (`tests/dashboard-pty.sh`).
   A wording change breaks exactly those pins, never the record grammar
   (§H/§L.2).
10. **Smoke tests run the INSTALLED engine** (owner decision 2026-10-23):
   "it works" means the packaged `gsa` binary behaves. Every smoke check and
   the fixture battery (`tests/run-all.sh`) default to `command -v gsa` and
   name the binary they exercised; a nested crate build (`target/*/gsa`, a
   per-fixture `--target-dir` tree) is NEVER the smoke subject.
   `GSA_TEST_GSA_BIN` is the explicit pre-install override and a recorded
   deviation. The deploy loop therefore ends: ship → install (`sudo gsa -Sy`
   + `sudo gsa -S gsa-pm`) → validate what was installed. (Violated once:
   green battery against `target/debug/gsa` while the installed r418 engine
   shipped old behaviour — the gap that produced this rule.)

*Recorded deviations (2026-10-23, UX wave).* (a) the dashboard width is
probed once per run (`tput cols` → `COLUMNS` → 80, floored at 20) — a mid-run
terminal resize refits on the next run; (b) the install transaction's
interrupt lines (`install.rs`: `signal <sig>` / `teardown …`) deliberately
stay prose in BOTH vocabularies — they ride the transaction surface, not the
event catalog, until that surface splits.

---

## Open decisions for the owner

1. **Cone-stop inside a coupled batch.** §I.1 parks exactly the failed
   package's transitive consumer cone, per the owner decision. Should members
   of the same `abi=must`/`abi=should` coupled batch also be parked (reason
   `coupled-batch`) when one member fails, even if they are not consumers?
   — **Recommendation: yes, park them** (reason `coupled-batch`): a half-moved
   ABI wave is precisely the bricking class `docs/MEMORY.md` rules 13/23
   guard against, and the batch is defined to move as one pass.
2. **Binpkg retention budget.** §J.4 says "retained instance" without a number.
   — **Recommendation: N=2 instances for provider/hub recipes (`core`
   membership or ≥2 consumers), N=1 elsewhere**, citing the 38 GB texlive
   landmine (`docs/MEMORY.md` §2 "Landmines") and the rollback use in ABI
   waves; `gsa -Mh`-style `--prune` and `gsa -Md` enforce it.
3. **World seeding at cutover.** The world file needs an initial content when
   the side-car DB is created. — **Recommendation: seed world with every recipe
   in `git`, `stable`, `core`, `misc`, `build-tools`, and leave `app` members
   out unless explicitly added** (`app` is documented as optional
   applications); one `gsa -Mw --add` pass can change it.
4. **`format: 2` adoption width.** The run history (§J.1) will store `format:
   2` records from day one of the side-car DB, so no `format: 1` reader exists
   in the native engine. — **Recommendation: confirm that no out-of-tree
   consumer of the `format: 1` block needs a compatibility window** (the
   55 fixtures and `rr_*` are re-contracted anyway per the clean-slate
   decision).

---

## M. Cutover amendments and deferrals (2026-10-14)

The Phase 5 cutover (engine of record = `gsa`; the fish engine frozen under
`tests/assets/` as an oracle) landed these amendments, each also marked in
place above. Nothing here is silent; the deferred items carry one line of
rationale each.

| Gap | Disposition | Where |
| --- | --- | --- |
| (a) `-U`/plan record conformance | **fixed**: budget scalars always integers (`0` when nothing dispatches), per-subject row collapse (order/plan/outcome one-to-one), the phantom `refused empty-list` row of a self-explaining refusal plan retired | §H.2 amendments; `gsa-model::RunRecord::render_machine`, `gsa-cli::record::collapse_txn_rows`, `gsa-cli::install` (self-explaining plans) |
| (b) `mirror_flags` vs the flag-rule table | **fixed by amendment**: the table now lists the full mirrored set (`--state-dir`/`--config`/`--no-register-ignorepkg`/`--no-prefetch`/`--prefetch-ahead`/`f` included — a resume that drops them changes behaviour) | §H.2 amendment |
| (c) G1 — repair-marker write half | **write surface decided, implementation deferred**: the marker is staged by the provider's install step for every consumer its ABI refusal was suppressed for (`gsa-abi::rows` coverage via `later_installs`), written under `<state>/abi-repair/<consumer-id>` BEFORE the transaction and fail-closed on write error; the surface rides the existing plan-row **reason** (`repair <consumer> <provider-id>` detail on the provider's row), never a new `plan` value — so no format bump (§L.2). Deferred one line: the consume half (2026-10-14) and the fish oracle's K/L/M/N cases pin the semantics; the write half lands with the ABI-wave hardening pass rather than at cutover | §E.3 note; `tests/abi-drift-install.sh` K/L/M/N (fish oracle) |
| (d) G2 outcome vocabulary | **fixed by documentation**: `planned\|success\|refused\|failed\|deferral\|interrupted` | §H.2 amendment |
| (d) G4 `--leaf=no` replay hazard | **fixed**: `--leaf` mirrors only in its true form; the negated spellings appear nowhere | §B.8/§H.2 amendments; `gsa-cli::record::build_plan_record` |
| G3 reason-key opacity | **fixed by documentation**: additive keys named | §H.3 amendment |
| G5 teardown grace knob | **closed by documentation**: `_GSA_STOP_GRACE_S`, non-roster fixture override | §K.3 amendment |
| G6 registration target conf | **closed by documentation**: `--config PATH`, default `/etc/pacman.conf` | §B.8 amendment |
| G8 preflight-refusal block shape | **closed by documentation**: the preflight-refusal and refusing-plan paths emit the FULL block (one plan and one outcome row per selected package, matching `order`) — the strict parser accepts no other shape | §H.2 amendment |
| G10 `--lane-job` flags grammar | **closed by documentation**: `check_flag_payload` grammar + the three forbidden verification-bypass tokens | §D.1 amendment |
| G11 workspace discovery | **closed by documentation**: `config/topology.conf` found from the cwd upward; the frozen fish oracle is the one self-located exception | §B.8 amendment |
| G12 parser strictness | **closed by documentation**: the strict `format: 2` rules (no blank lines/control characters, no duplicate scalars/rows/continuation keys, plan/outcome rows agree with `order`, `rc` is the status's lane code or `-`, all four sections required, unknown continuation keys rejected, extension scalars accepted) are the normative reading, implemented by `tests/lib/rr-v2.bash rr2_body` | §H.2 amendment |
| G7 phase mapping | **no action needed**: the phases were the migration plan's, not the contract's; the inventory assigned them and all five have landed | `docs/gsa-fixture-migration.md` |
| G9 v2 prose spec | **deferred**: prose wording is pinned in exactly one rendering test only (§L.5); a normative prose spec is a design task, not a cutover fix | §L.5 |
| selection-source grammar (G2 half) | **fixed by documentation**: `sets=<…> leaf=<yes\|no> range=<…>` | §H.2 amendment |
