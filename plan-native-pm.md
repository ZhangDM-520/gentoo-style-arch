# plan-native-pm.md — a native, Portage-class package manager for Gentoo_Style_Arch

**Status:** design plan only. No implementation accompanies this document; it changes nothing
else in the tree.

**Question answered:** how do we replace the ~8.7k-line fish builder with a native compiled
package manager (C or Rust) that keeps the recipes in this git repo, ports the existing logic,
adds the package-management features Portage is loved for — subslots/`:=`/preserved-rebuild-class
ABI handling and a real user-facing tool surface — while the host system stays pacman-managed?

**Relationship to the two prior research deliverables (read them first, this plan does not
repeat them):**

- `plan-gentoo-qol.md` owns the *mechanism* research (8-item ranked shortlist + 5 owner
  decisions). This plan says **where each item lands** in the native architecture and which
  items are subsumed by it (see §3.4). Where both speak, that file owns "what Gentoo does and
  why it helps"; this file owns "what we build".
- `plan.md` owns the fetch-ahead design (lookahead window, `--fetch-job` children). It becomes
  a **subsystem of the native scheduler** (`gsa-fetch`, §3.3/§6), not a parallel project. Its
  advisory failure semantics, single-flight policy and signal bar carry over unchanged.

**Ground rules carried from the repo (non-negotiable, restated because they bound every
section):** source verification is never weakened — no `--skipchecksums`/`--skippgpcheck`
anywhere (`docs/MEMORY.md:261-300` rule 15; `CONTRIBUTING.md` "Source verification and signing
keys"); the recipes and topology stay in the git repo and the binary reads them from there; the
host's pacman-managed system must survive every failure mode — a design that can brick
`/var/lib/pacman` is wrong on arrival (`docs/MEMORY.md:453-474` rule 23; `SECURITY.md`);
fixtures pin argv shapes and output seams that "ARE the contract" (`docs/MEMORY.md` §2
"Fixture conventions", §6 pitfall digest 2026-10-05) — any engine swap must keep or
deliberately re-contract them.

**Grounding measurements for this plan** (read-only commands run against the working tree on
2026-10-06; the tree carries uncommitted work, so figures differ slightly from older docs —
the owner brief's "~8,200 lines / 158 functions" is now 8,698 lines / 168 `function`
definitions in `build-all.fish`, 2,773/52 in `lib/sources.fish`, 1,552/13 in `lib/audit.fish`):

- `config/topology.conf` holds 653 active records (653 non-comment lines; `linux-cachyos`'s
  record is commented out by owner decision — `config/topology.conf:68-72`); tag census:
  27 × `abi=must`, 22 × `abi=should`, 7 × `app-cluster=`, 3 × `version-sync=nvchecker`.
- `tests/` holds 55 fixtures plus `tests/run-all.sh` (56 `*.sh`, minus the runner).
- Builder startup cost (bash `time`, user-CPU figures reliable; wall times taken while another
  agent's fixture battery was loading the host): `fish -n build-all.fish` (parse only) 0.039 s
  wall / 0.032 s user; `fish -c true` 0.087 s / 0.035 s user; a no-arg invocation (full config
  load, then usage error) 2.75 s wall / 2.23 s user; `--topology` (load + validate + render 653
  records) 5.93 s / 4.20 s user; `--list` (all packages) 8.5–9.3 s wall / 4.4–4.6 s user;
  `--help` 7.26 s wall / 3.47 s user. The cost is *interpreted execution* of the ~13k lines of
  fish across the entry + two sourced modules, not parsing. The brief's "~1.1 s CPU at startup
  before any work" is a lower-bound figure from earlier measurements; today we measure 2.2–4.6 s
  CPU per invocation, and every `--lane-job` child pays it again (`build-all.fish:8479-8528`).

---

## 1. Open questions for the owner (answer these first)

Each question states my recommendation and what the alternative costs. Questions 1–5 are the
brief's minimum set; 6–8 are the next decisions an implementation team cannot make for you.
The five owner questions already open in `plan-gentoo-qol.md` §1 (ABI-token source, failure
default, archive retention, QA gate line, index integrity) stay open; where they intersect a
question here, the pointer says so.

**Q1. Language: C or Rust?** — **Recommendation: Rust** (verdict and evidence in §2).
Cost of deciding for C: every concurrency/state-handling invariant this repo has ever been
bitten by (lane-result codecs, keyed dispatch markers, foreign-line rejection,
signal teardown — `build-all.fish:4866-4954`, `:5095-5393`, `:8376-8475`) becomes hand-rolled
memory management in exactly the code that runs lanes concurrently; expect a larger defect
budget and a longer path to feature parity. Cost of deciding for Rust: bootstrap needs
`rustc`+`cargo` on the host (one `pacman -S rust`, or the workspace's own `rust-git` recipe —
see §7 bootstrap), and the team needs Rust fluency.

**Q2. Relationship to pacman: coexist-as-a-build-orchestrator, own installed-database, or
hybrid?** The host's `/usr` and `/var/lib/pacman` are pacman-managed today; `-i` runs
`pacman -U --noconfirm --ask 4` per package (`docs/MEMORY.md:815-845`; `build-all.fish:3266-3436`).
— **Recommendation: hybrid.** pacman/ALPM stays the *only* installed-package database and
transaction executor; the native PM owns a *side-car* database (binpkg index, ABI tokens,
subscriptions, world/sets, preserved-lib registry, run history) keyed by pacman's local DB.
Cost of a fully separate installed-database (Portage's vdb shape): two truths about `/usr`,
we must reimplement transactions/scriptlets/ldconfig, and every disagreement is a brick risk —
forbidden by the ground rules. Cost of pure coexist (no side-car DB at all): the Portage-class
features (computed rebuild sets, preserved-libs, binpkg index, world/sets, rollback) have
nowhere to live and we keep re-deriving state from filenames and logs, which is the current
pain (`docs/NOTE.md:40-103`, run #31).

**Q3. Recipe format: keep PKGBUILD-as-bash (executed by makepkg), or move to a declarative
manifest compiled/interpreted natively?** `SECURITY.md:1-7` is explicit: a recipe executes
arbitrary shell; the trust model is "review changes before running them". — **Recommendation:
keep PKGBUILD as the recipe of record and the build payload**, but stop *reading* it with shell
evaluation: the native engine reads committed `.SRCINFO` (plus a strict scan fallback) for all
scheduling/metadata decisions, and PKGBUILD shell runs only inside `makepkg` at build time,
exactly where the trust model already places it. Cost of the other way (a declarative manifest):
653 recipes migrate; `build()`/`prepare()`/PGO phase logic (`lib/pgo.sh` calls before strip,
`docs/adr/0001-pgo-shared-gate.md`) cannot be declarative without inventing a build DSL;
makepkg compatibility is lost or a generator must be maintained; and the trust model does not
actually improve — the *build* still executes recipe-derived shell. Cost of keeping bash as-is
(with eval-based reads): arbitrary shell stays in the read path too (today
`pkgbuild_array_checked`, `lib/sources.fish:318-336`, evaluates recipes in bash subprocesses —
`SECURITY.md:10-13` calls this out), and read-side evaluation keeps its fork cost (§8).

**Q4. "User management tools" — which reading?** The phrase reads two ways and both are
plausible here:
  (a) **user-facing management CLI** — the emerge/revdep-rebuild/eselect/etc-update-shaped verb
  surface (what §5 designs);
  (b) **multi-user / package-ownership administration** — who may build/install (root-supervisor
  vs unprivileged, `sudo -n` policy — `docs/MEMORY.md:815-845`), who owns state files
  (write-time ownership, rule 19 `docs/MEMORY.md:375-396`), per-user package sets or shared
  system-wide installs, build-user management.
— **Recommendation: (a) in full, plus the ownership-hygiene slice of (b)** (state ownership
verbs, `sudo` policy kept as today's single non-interactive contract, per-user config for
profiles/sets). Cost of choosing (b) in full: per-user installed databases or per-user overlay
roots are a Portage-scale project of their own and collide with Q2 (pacman is system-wide);
cost of ignoring (b) entirely: the root-supervisor mode's ownership repair
(`docs/MEMORY.md:375-396`) and multi-user state-dir hazards stay tribal knowledge.

**Q5. Compatibility promise for existing flags, fixtures, and run-record consumers.** Today
`tests/run-all.sh` + 55 fixtures assert on flag argv shapes, `--install-decide` rows
(`install|skip|refuse|noop`, rc 0 plan / 1 refusal / 2 bad usage — `docs/build-guide.md:48-58`),
and the machine run-record block (`--- run record begin ---`, `format: 1` —
`docs/build-guide.md:430-502`; `build-all.fish:7241-7256`). — **Recommendation: freeze all
three seams byte-stable** (flags keep spelling and semantics; run-record stays `format: 1`;
decision rows keep their vocabulary and rc contract), and put the new PM surface on top as new
subcommands/verbs, with `build-all.fish` surviving as a thin argv-mapping shim (§7). Cost of a
clean-slate CLI: the 55 fixtures, the `rr_*` parser (`tests/lib/fixture-lib.bash:374-389`), any
user scripts, and the differential oracle (§7 Phase 0) all break at once — the riskiest
possible first step. Cost of freezing: some flag spellings are suboptimal forever (mitigate
with aliases), and the machine block's grammar limits how much new data can be added without a
`format: 2` bump (additive `key: value` scalars only — precedent in `plan.md` §3.4).

**Q6. Transaction engine: keep `pacman -U` subprocesses, or link libalpm directly?**
— **Recommendation: subprocess first (Phases 0–3), libalpm bindings later (Phase 4+) behind
the same decision seam.** Subprocess keeps the stub universe (`tests/lib/fixture-lib.bash`
`stub_pacman`/`stub_sudo`) working unchanged and keeps privileged work out of the PM process.
Cost of libalpm from day one: the fixture stubs stop intercepting transactions (the harness
must learn a fake-library mode), and transaction code runs privileged in-process. Cost of never
using libalpm: richer questions (conflict resolution, file-level ownership checks) stay
text-scraping `pacman` output forever.

**Q7. Failure default for long runs: keep fail-fast, or make cone-stop (`--keep-going`
analogue) the default?** Carries `plan-gentoo-qol.md` owner Q2. — **Recommendation: keep
fail-fast as the default; cone-stop as an explicit mode**, because fail-fast has repeatedly
stopped compounding breakage (`docs/MEMORY.md:185` rule 11 context; `plan-gentoo-qol.md` M4).
Cost of the other default: systemic breakage gets buried under a green-ish partial run;
cost of never building cone-stop: one defect keeps stranding 600-package runs
(`docs/NOTE.md:889-907` epoch wall, cited in `plan-gentoo-qol.md` M4).

**Q8. Side-car state location and archive retention budget.** Keep `.state/` + `GSA_STATE_DIR`
(`docs/architecture.md` §4) for the side-car DB, or graduate to `/var/lib/gsa`? And how many
binpkg instances per recipe (carries `plan-gentoo-qol.md` owner Q3)? — **Recommendation: stay
under `GSA_STATE_DIR`/`.state/` through Phase 4** (fixtures synthesize workspaces there; moving
to FHS paths mid-port adds root-write requirements), retention default **N=2 instances for
provider/hub recipes (`core` or ≥2 consumers), N=1 elsewhere** (memory: the texlive 38 GB
landmine, `docs/MEMORY.md` §2 "Landmines"). Cost of the other way each: FHS migration early =
fixtures and unprivileged runs fight permissions; unbounded retention = disk landmines; N=1
everywhere = no rollback artifact for ABI waves (§4).

---

## 2. Language verdict

**Verdict: Rust. One native binary (`gsa`), no C in the shipped core; C interop only via the
system's `libalpm` if/when Q6 lands on linking it.** Not a survey — the case, grounded in
what this codebase actually does:

1. **The engine is a concurrent supervisor with hard state-handling invariants.** The fish
   builder's most scarred code is the lane lifecycle: atomic result publication with a
   foreign-line-rejecting codec (`build-all.fish:4866-4954`), process-group teardown with a
   exactly-one-TERM discipline (`build-all.fish:5095-5393`), signal latches and second-signal
   escalation (`build-all.fish:8376-8475`), a run lock and orphan sweeps
   (`build-all.fish:5293-5392`). These exist because a dynamic language gives no help; Rust's
   ownership/Send/Sync model makes the same invariants compiler-enforced. In C, this is the
   class where use-after-free and double-kill bugs live — precisely the code the repo's
   incident journal (`docs/MEMORY.md` §1) spent months hardening.
2. **Parse/eval performance is a measured bottleneck.** Metadata reads fork bash per recipe
   (`pkgbuild_array_checked`, `lib/sources.fish:318-336`; `SECURITY.md:10-13`) and the lint
   family historically paid "8–10 k forks" until shared parses landed
   (`docs/MEMORY.md:1217-1235` region, rule: "lint/audit I-O goes through the shared parses —
   never fork per recipe"). Startup itself burns 2.2–4.6 s CPU per invocation (§0
   measurements). Native parsing of `topology.conf` (653 records), `.SRCINFO`, and archive
   `.PKGINFO` is milliseconds; Rust string handling with `nom`/hand parsers or plain
   `split_once` is safe and fast. C matches the speed but every parser is a buffer-discipline
   exercise.
3. **ELF/soname tooling exists in mature Rust form.** The ABI guard needs `readelf -d`-class
   functionality (DT_NEEDED, SONAME, provides derivation) at scale — today it shells to
   `readelf`/`tar` (`build-all.fish:1938-1946` `archive_pkginfo`, `:1441-1500`
   `abi_*` helpers). Rust: `goblin`/`object` crates (pure Rust, no system deps), `zstd`+`tar`
   crates for `.PKGINFO` extraction. C: libelf/elfutils works but adds a system-library API
   layer. Either can do it; Rust ships it with tests and fuzzing cheaply.
4. **libalpm bindings exist and are production-proven in Rust.** The `alpm`/`alpm-sys` crates
   are what `paru` (a Rust Arch helper) uses; if Q6 goes to direct ALPM, the binding is a
   dependency, not a project. C links libalpm natively — its one real advantage here.
5. **The decision surfaces want typed enums, not tab-framed strings.** Install plan rows
   (`install|skip|refuse|noop`, `build-all.fish:3047-3124`), lane outcomes
   (`lane_outcome_{ok,failed,defer,lost,hup,int,term}`, `build-all.fish:211` + `:4866-4895`),
   run-record statuses (`docs/build-guide.md:461-487`) and the continuation flag-rule classes
   (`value|flavour|semantics|replaced|not-mirrored`, `build-all.fish:7082-7103`) are exactly
   the shapes that drift when re-parsed by hand. `enum` + `serde` makes the run record one
   struct rendered three ways (ADR 0003) a compile-time guarantee.
6. **Bootstrap is already half-solved on this host.** The workspace maintains `rust-git`
   (`packages/core/rust-git`), the builder has a rustc sanity probe and a bypass flag
   (`check_rustc_sanity`, `build-all.fish:5416-5463`; `--allow-broken-rustc` in
   `docs/build-guide.md`-documented flags), and Arch ships `rust` in the repos. C bootstraps
   with `base-devel` alone (`README.md:40-44`) — its one advantage — but the workspace already
   treats rustc as part of the toolchain it must survive (rule: llvm↔rust coupled batches,
   `docs/MEMORY.md:234-252`).
7. **Hybrid (Rust core + C shims) was considered and rejected as unnecessary.** There is no
   hot path needing C; the one plausible C shim (libalpm FFI) is covered by `alpm-sys`. A
   **C library-first design** (libgsa + thin CLI, pacman's shape) was also considered and
   rejected: our value is policy and orchestration (a deep module per `docs/architecture.md`),
   not a library for third-party linkers; library-first adds an ABI-stability burden with zero
   consumers. Internal crate boundaries (§3.1) keep the option open without paying for it.

Counter-case kept honest: a C implementation is fully feasible (pacman itself is C), its
bootstrap is marginally simpler, and a small expert team can hold the concurrency invariants
manually. It is simply the wrong trade for *this* codebase's dominant risk profile.

---

## 3. Architecture

### 3.1 Native component layout (Rust workspace)

One workspace, one shipped binary `gsa` (plus the compat shim name `build-all.fish`). Hidden
fixture seams (`--lane-job`, `--install-decide`, `--stale-lock-check`, `--local-db-check`,
`--install-register`, `--register-ignorepkg`, `--audit-lint` — `build-all.fish:7082-7103`,
`:8479-8608`) become hidden subcommands with identical argv shapes (Q5).

```
crates/
  gsa-cli        argv parsing, help, the three renderings (dashboard, prose, machine block),
                 continuation table (the _CONTINUATION_RULES port, build-all.fish:7082-7157)
  gsa-model      core types: RecipeId, TopologyRecord, RunRecord, PlanRow, OutcomeRow,
                 LaneOutcome, enums + serde; the "one record, three renderings" seam (ADR 0003)
  gsa-topo       config/topology.conf + build-defaults.conf + abi-exclusions.conf loaders and
                 validators (strict-loader contract: one malformed record breaks every command,
                 offender named — build-all.fish:481-710)
  gsa-recipe     .SRCINFO parser + cache, PKGBUILD scan fallback (read-only), source
                 classification, version-sync providers (Arch query, nvchecker, AUR, GitHub),
                 checksum anchoring, VCS freshness baselines
  gsa-graph      consumer expansion, topological sort, coupled batches (abi=must/should),
                 and the NEW: computed rebuild sets / ABI wave planner (§4)
  gsa-sched      lane supervisor: dispatch state machine, budgets, result codec, signals,
                 locks, orphan sweeps; owns gsa-fetch (plan.md's prefetch subsystem, §3.3)
  gsa-build      makepkg orchestration: freshness gates, toolchain identity, PGO gates,
                 link-sources, cleanup modes
  gsa-install    install plan rows (one decision, one seam), transaction execution (pacman
                 subprocess → optional libalpm), IgnorePkg registration, staged swaps/waves,
                 preserved-libs registry, rollback
  gsa-abi        ELF/soname: provides derivation, DT_NEEDED scans, installed-ELF index,
                 abi-token computation, revdep queries (§4)
  gsa-state      side-car DB (binpkg index, abi-token/subscription records, world/sets, run
                 history), log ownership/retention (rule 19, docs/MEMORY.md:375-396)
  gsa-qa         check registry: named checks with scope + severity + stable keyword
                 (install-qa-check.d analogue), hosts the migrated audit lints (§5.3)
  gsa-maint      `maintain`/`logs`/`clean` verbs (emaint analogues, §5)
```

### 3.2 The four-module split maps to native components

`docs/architecture.md:1-40` splits the project into Recipes / Topology / Builder / Runtime
state. The split survives the port — the binary is a new *Builder*, not a new architecture:

| Module (docs/architecture.md) | Native home | Contract kept |
|---|---|---|
| Recipes (`packages/<category>/<id>/PKGBUILD` + `.SRCINFO` + assets) | `gsa-recipe` reads; `makepkg` executes | PKGBUILD is source of truth (`docs/package-policy.md`); `.SRCINFO` committed; assets/ignore rules (`CONTRIBUTING.md:19-27`) untouched |
| Topology (`config/topology.conf`, `build-defaults.conf`, `abi-exclusions.conf`) | `gsa-topo` + `gsa-graph` | one record per package `id\|path\|groups\|edges[\|tags]`; strict loader; `--topology` stays the data channel (`build-all.fish:7266-7301`) |
| Builder (scheduler + install + reporting) | `gsa-sched`, `gsa-build`, `gsa-install`, `gsa-cli` | scheduler invariants (`docs/architecture.md:55-100`): selection expands consumers, build order meaningful, install-before-dependents, core-solo, failure-stop-drain + deferral amendment, build-tools band, one-run-record/three-renderings, one-install-decision seam |
| Runtime state (`.state/`/`GSA_STATE_DIR` vs makepkg state beside recipes) | `gsa-state` (+ unchanged makepkg layout) | write-time ownership (rule 19); makepkg `src/`/`pkg/`/archives stay beside recipes; side-car DB joins `.state/` (Q8) |

### 3.3 Where the fish functions land (mapping table)

Line numbers are against the current working tree (2026-10-06). "Verbatim semantics" = the
fixture-pinned behaviour does not change; "subsumed" = the native component replaces the
mechanism with a stronger one but keeps the seam.

| fish function / area (file:lines) | Native module | Notes |
|---|---|---|
| topology loader/validation — `read_config_defaults` `build-all.fish:397-467`, `read_topology_config` `:481-670`, `read_abi_exclusions` `:671-710`, `load_project_config` `:711-787` | `gsa-topo` | verbatim semantics: strict loader, every invocation, offender+line named; native speed kills the 2.2 s config-load floor (§8) |
| consumer expansion + topo sort — `expand_consumers` `:952-1021`, `topo_sort` `:788-951`, `_topo_key` `:468-480` | `gsa-graph` | verbatim semantics: reverse-edge closure, cycle refusal, build-tools band never overrides edges; key scheme becomes typed `RecipeId` |
| selection/name resolution — `canonicalize_pkg_ref` `:3666-3701`, `_pkgname_index`/`_pkgname_owner` `:3510-3557`, `resolve_group` `:7525-7579`, `prompt_app_selection` `:7580-7691`, `list_packages` `:7494-7524` | `gsa-cli::select` + `gsa-graph` | app-cluster prompt behaviour verbatim (`docs/maintainer-guide.md` "The app group") |
| lane dispatcher + outcome codec — `run_lanes` `:5975-6894`, `pick_next_ready` `:5654-5813`, `dispatch_state_refresh` `:5533-5604`, `lane_job` `:5853-5941`, `lane_argv`/`lane_argv_check` `:5814-5852`, `lane_result_encode`/`decode` `:4866-4928`, `write_lane_result` `:4929-4954` | `gsa-sched` | codec wire format and foreign-line rejection stay byte-compatible during Phases 0–3 (fixtures read the result files); the 0.5 s poll cycle dies (§8); lanes become `exec`'d makepkg supervisors, not fish interpreters |
| lane lifecycle/signals/locks — `cleanup_active_lanes` `:5195-5292`, `run_lock_acquire`/`release` `:5293-5363`, `orphan_lane_sweep` `:5364-5392`, `sweep_stale_run_artifacts` `:5393-5415`, `gsa_handle_signal` `:8376-8435`, `kill_active_lanes_immediate` `:8436-8455`, watchdog `:8483-8505` | `gsa-sched::lifecycle` | the signal-abort-lock fixture's bar (one TERM, grace, KILL; exit 130 with full run record) is the acceptance test |
| install pipeline + decision rows — `install_plan` `:3047-3124`, `install_execute` `:3266-3436`, `install_skip_reason` `:2952-3038`, `install_pkgs_now` `:3437-3457`, `install_all` `:1320-1440`, `install_register_ignorepkg` `:3206-3265`, `install_register_names` `:3162-3205`, `--install-decide` seam `:8557-8607` | `gsa-install` | **one decision, one seam** (`docs/MEMORY.md:397-411` rule 20) becomes one Rust function returning `Vec<PlanRow>`; rows and rc contract frozen (Q5) |
| install-time ABI/PGO gates — `abi_provide_refusals` `:1996-2115`, `install_needed_probe` `:2116-2300`, `pgo_payload_refusals` `:2301-2352`, `archive_pkginfo` `:1938-1945` | `gsa-install::gates` + `gsa-abi` | row shapes (`refuse abi-soname …`, `refuse abi-consumer …`) frozen; `.PKGINFO` reading becomes a native tar/zstd read; the Stock→house counterpart rule (`docs/NOTE.md:40-103`) becomes first-class surface-move planning (§4.4) |
| version sync — `sync_stable_version` `lib/sources.fish:558-805` (Arch `pacman -Si` + official `.SRCINFO` anchoring, `anchor_sums_from_official` `:2612-2634`), `sync_nvchecker_version` `:822-1147` (nvchecker sections, AUR `.SRCINFO` `:886-965`, GitHub release digests `github_release_checksum_map` `:2025-2102`), `anchor_sums_from_provider` `:2224-2611` | `gsa-recipe::sync` | provider semantics verbatim per `docs/build-guide.md:134-306`: anchoring to the authority the value came from (rule 18, `docs/MEMORY.md:310-374`), provider outage = defer, checksum mismatch = integrity stop + restore; rewrites stay transactional (`restore_pkgbuild_snapshot` `:337-351`, `apply_pkgver_version` `:410-522`) |
| VCS freshness + checksum anchoring — `freshness_skip_decision` `build-all.fish:1196-1280`, `vcs_archive_is_current` `lib/sources.fish:1712-1894`, `record_vcs_archive_revisions` `:1449-1558`, `git_ls_remote_quiet` `:1310-1335`, `vcs_remote_revision` `:1336-1448` | `gsa-recipe::freshness` | manifest-v2 currency (complete output set + `pacman -Qp` readability + sha256+size baseline, `docs/build-guide.md:81-131`) verbatim; transport-retry classification (0/2 vs retryable) and `upstream-unverified` deferral verbatim |
| metadata parsing — `pkgbuild_var` `lib/sources.fish:26-43`, `pkgbuild_array_checked` `:318-336`, `srcinfo_*` `:1901-2024`, `srcinfo_rows` `:2706-2721`, `pkgbuild_scan_rows` `:2722-2736` | `gsa-recipe::meta` | native `.SRCINFO` parser + cache subsumes the shared tagged parses; bash evaluation survives only inside makepkg (Q3) |
| run record — `run_record_row`/`field`/`plan`/`finalize` `:6895-7040`, `print_run_record` `:7241-7256` | `gsa-model::runrecord` + `gsa-cli` | one struct, three renderings (ADR 0003); machine block stays `format: 1` (Q5) |
| dashboard vs plain — `render_dashboard` `:5007-5065`, `finish_dashboard`/`abort_dashboard` `:5066-5094`, `fit_dashboard_line` `:4979-5006`, `print_run_summary` `:7158-7240`, `print_log_tail` `:3485-3509` | `gsa-cli::render` | prose pinned only by the dashboard rendering test (`tests/dashboard.sh`, `docs/MEMORY.md` fixture conventions) stays the rule |
| continuation/flag-rule table — `continuation_args` `:7104-7157`, `_CONTINUATION_RULES` `:7082-7103` | `gsa-cli::continuation` | table-driven port; every new flag must land in the table in the same change (the `plan.md` Q1 note) — now enforced by a property test (§9) |
| audit lints — `lib/audit.fish`: `audit_lint_abi_closure` `:29-246`, `audit_lint_abi_exposure` `:247-559`, `audit_lint_provides` `:572-703`, `audit_lint_purged` `:704-761`, `audit_lint_swap` `:1102-1254`, `audit_workspace` `:1255-end`, IgnorePkg machinery `:762-1101` | `gsa-qa::checks` (registry, §5.3) + `gsa-maint` | each lint becomes a declared check (name, scope, severity `report`, stable keyword); report-only contract (`CONTEXT.md` "Audit lint") preserved |
| resource budgets — `configure_intensity` `build-all.fish:352-396`, `available_memory_gib` `:5942-5962`, `available_cpu_threads` `:5963-5974` | `gsa-sched::budget` | the portability.md:33-56 formulas move as data (per-profile constants + build-defaults baselines); behaviour identical |
| pacman host seams — `ensure_pacman_shim` `:2424-2459`, `run_pacman_locked` `:2353-2423`, `check_pacman_lock`/`lock_holder_lines` `:4504-4632`, `check_pacman_db_health` `:4672-4749`, `install_preflight` `:4750-4784`, `sudo_probe` `:4826-4865` | `gsa-install::host` | rules: never delete `db.lck`, prove idleness via `/proc/*/fd` inode scan, `sudo -n` only, preflight refuses before building (`docs/MEMORY.md:815-845`) all verbatim |
| cleanup/links — `cleanup_pkgs` `:2460-2496`, `nuclear_cleanup` `:2497-2679`, `link_sources` `:2704-2951` | `gsa-build::clean`, `gsa-maint` | `-cc`/`-ccc`/`-ln` one-shot semantics verbatim (`docs/source-sharing.md`) |
| fetch-ahead (planned, not yet in tree) — `plan.md` §2 (`prefetch_tick`, `--fetch-job`, `_PF_*`) | `gsa-sched` + `gsa-fetch` | the fish-shaped design lands natively: dispatcher-owned one-shot fetch children become supervised tasks; `makepkg --verifysource` remains the fetch/verify engine so checksum/PGP enforcement is *identical* to the lane (`plan.md` §2.2); advisory failure semantics, single-flight, disk floor, kill-with-the-run all carry over |

### 3.4 Where plan-gentoo-qol.md's shortlist lands (and what is subsumed)

| # | Shortlist item (`plan-gentoo-qol.md` §1) | Native home | Subsumed by the PM core? |
|---|---|---|---|
| 1 | subslot/`:=` subscriptions + heal-set wave | `gsa-graph` rebuild-set planner + `gsa-abi` tokens + `gsa-state` subscription records (§4) | **Yes — this IS the ABI subsystem**, the reason for the move |
| 2 | staged atomic swap + last-known-good retention | `gsa-install` wave transactions + `gsa-state` binpkg retention (§4.5) | Yes |
| 3 | archive index + install-from-archives | `gsa-state` binpkg index (§5.2) | Yes |
| 4 | cone-stop keep-going + resume hygiene | `gsa-sched` failure policy + `gsa-cli::continuation` + `maintain resume` | Partly — resume/continuation is core; cone-stop stays opt-in (Q7) |
| 5 | pluggable install QA + check registry | `gsa-qa` (§5.3) | Yes |
| 6 | `--stale` query + version-sync skew lint | `gsa-recipe::freshness` query mode + one `gsa-qa` check | Partly — small, riding the existing provider machinery |
| 7 | host-state hygiene verbs | `gsa-maint` (`logs`, `prune-ignorepkg`, `doctor`) | Partly — one verb family |
| 8 | disk/load admission guards | `gsa-sched::budget` admission checks | Yes — one policy block beside the intensity formulas |

Its five owner questions fold into Q1/Q7/Q8 here (ABI-token source → §4.1 default; failure
default → Q7; retention → Q8; QA gate line → §5.3 severity attribute recommendation; index
integrity → deferred with M3's "skip by default" lean).

---

## 4. Gentoo ABI handling, concretely

Gentoo's model (PMS §7.2 sub-slots; PMS §8.3.3 slot operators `:=`/`:*`, both EAPI-5 features —
see the erratum in §6; devmanual "Slotting"/"ABI breakage"): a provider declares a sub-slot
that changes when its ABI changes; consumers *subscribe*; the package manager records the
slot/sub-slot pair at build time and, on a sub-slot move, schedules exactly the subscribers for
rebuild. `FEATURES=preserve-libs` keeps the old library alive while consumers remain, and
`@preserved-rebuild` is the computed heal set (make.conf(5); portage `sets.docbook`). We map
each piece onto data we already keep.

### 4.1 ABI token (= sub-slot): derived, with a declared override

- **Derived token (default):** for every built archive, compute
  `abi-token = hash(sorted bare-soname provide set actually shipped)` from `.PKGINFO`
  `provides` + a payload scan (`readelf -d` over shipped ELF files — the machinery already
  exists in `abi_soname_stems`/`abi_provide_refusals` `build-all.fish:1478-1490`, `:1996-2115`
  and `audit_lint_abi_closure` `lib/audit.fish:29-246`). Hash bare stems only
  (`libfoo.so`, never `libfoo.so=1-64`) — the auto-version suffix churns with every pkgver
  while the ABI stands still (rule 30 "soname beats pkgver", `docs/MEMORY.md:611-628`; rule
  25(a) bare-provides-only, `:491-544`).
- **Declared override:** optional topology tag `abi-rev=<n>` on the provider record for
  non-soname ABI moves — LLVM C++ ABI snapshots (`docs/MEMORY.md:234-252` rule 13) and Qt
  private-API tags (`:82-85` rule 5) move ABI with no soname change. This is the answer to
  `plan-gentoo-qol.md` M1's open "derived vs declared" question: **derived by default,
  declared only where derivation provably cannot see the break.**
- The token is recorded twice: in the **binpkg index** row at build time (§5.2) and in the
  **installed-ABI record** at install time (`gsa-state`), i.e. Portage's "store the slot/sub-slot
  pair of the best installed version" (PMS §8.3.3) becomes `consumer|version|provider|token`.

### 4.2 `:=` and `:*` mapped onto our topology edges

Our edges already say "A consumes B" (`CONTEXT.md`, "Build-order edge"). They now carry one of
two subscription classes:

- **`:=` (ABI-subscribed)** — A's shipped ELF NEEDED entries resolve through B's provide set
  (computed by `gsa-abi`, seeded by today's closure machinery
  `abi_name_edges`/`abi_consumer_closure` `build-all.fish:1767-1898`). When B's abi-token
  changes vs what A recorded at build time, A is a rebuild candidate. Declaring an edge is not
  enough to trigger; the *recorded token mismatch or an actual soname link* is. This replaces
  today's coarse rule "provider whose bare-stem provide set changes rebuilds its FULL in-tree
  consumer closure" (rule 25(c), `docs/MEMORY.md:491-544`) with a computed set — the rule's
  safety intent is kept as the default when subscription data is missing (fail toward
  rebuilding).
- **`:*` (build-order-only)** — edges like the cargo recipes' `rust-git` edge
  (`docs/maintainer-guide.md` group rules; `--audit` lint at `docs/MEMORY.md:149-184`) order
  builds but never trigger rebuilds.

### 4.3 Computed rebuild sets — the `@preserved-rebuild` analogue

`gsa revdep-rebuild --pretend` (and the run-record plan line) computes, for each provider P
whose abi-token moved vs installed:

```
R(P)  = installed packages whose recorded subscription token for P differs   (:= mismatches)
      ∪ installed packages whose DT_NEEDED resolves through a provide P dropped/changed
        (content truth — the file-backed resolution source of rule 25(b)/(e))
      ∪ P's coupled batch members (abi=must same-pass; abi=should noted)
wave  = R(P) ∪ transitive consumers of R(P) per the topology graph, one coupled batch
```

This is `plan-gentoo-qol.md` M1's wave planner placed in `gsa-graph`, fed by `gsa-abi`. The
second set term is the queued blind-spot fix ("consult the local DB's reverse deps of the
moving provide and name the stock-side consumers", `docs/MEMORY.md:1203-1212` §5). The wave is
dispatched with the existing batch gate semantics (`has_abi_tagged_dependency`
`build-all.fish:4253-4286`, `abi_batch_dependents` `:4314-4341`) and reported like
`emerge --verbose-slot-rebuilds`: "libicu-git 78→79 forces rebuild of {…}" as a plan section in
the run record. Over-expansion is bounded by hashing bare stems only (§4.1) and by the
`config/abi-exclusions.conf` registry (strict `id|reason|review-by` loader,
`build-all.fish:671-710`; rule 25(f)).

### 4.4 preserved-libs-style detection from the installed ELF DB

Portage's `preserve-libs` contract: "Preserve libraries when the sonames change during upgrade
or downgrade… Preserved libraries are automatically removed when there are no remaining
consumers" (make.conf(5), FEATURES). pacman has no such feature, so we emulate its *contract*
in `gsa-abi` + `gsa-install`:

1. **Installed-ELF index** (`gsa-state`): for each installed ELF file, its SONAME and
   DT_NEEDED set — built incrementally at install time (the post-install probe
   `install_needed_probe` `build-all.fish:2116-2300` already resolves NEEDED against
   provide-set ∪ shipped bytes ∪ installed files; it becomes the index writer) and repairable
   by `gsa maintain doctor`. This is the "installed ELF DB" the revdep checks read.
2. **Detection at plan time:** a transaction that would remove or replace a soname file with
   still-installed consumers raises one of two named plan shapes (below). Today's equivalent
   is the Layer-3 refusal (`refuse abi-soname`/`abi-consumer` rows,
   `build-all.fish:1996-2115`) which fires when the *consumer closure is not in the
   transaction* — rule 25(d) "never install a moving/removed soname provide with part of its
   consumer closure outside the transaction".
3. **Two remedies:** (a) *refuse-and-heal* (default): the refusal names the missing consumers,
   the operator (or `gsa update`) composes the full wave into one transaction — safety over
   convenience; (b) *preserve* mode (long waves only): the old `.so` is retained at a recorded
   path in the preserved-lib registry with its owning package/version, `gsa revdep-check`
   lists the survivors (make.conf(5): "Run `emerge @preserved-rebuild` in order to rebuild all
   consumers of preserved libraries"), and the retained file is auto-removed when its last
   consumer is gone. Mode (b) exists to kill the ICU asymmetry: "long-running processes keep
   running on deleted inodes while every NEW exec dies at the loader" (rule 30(b),
   `docs/MEMORY.md:611-628`; `docs/NOTE.md:545-578` noctalia "PAM start failed").

### 4.5 The Stock→house swap and atomic staged swaps

Run #31 (`docs/NOTE.md:40-103`) is the canonical failure: `bzip2-git` (Class A swap:
`provides=("bzip2=$pkgver" 'libbz2.so')` + `conflicts=('bzip2')`) moved the soname surface to a
new pkgname and the Layer-3 gate — comparing provides only against the *same pkgname* — could
not see it. The fix (counterpart via `abi_stock_name` `build-all.fish:1441-1446`, double-negative
fresh-install rule, `audit_lint_swap` soname-drift half `lib/audit.fish:1102-1254`) is a
patch on a name-keyed model. The native design changes the model:

- **Surface identity is first-class.** A *surface* = the provide set + sonames + file
  ownership a package name exposes. An install plan models `SurfaceMove { from: stock name,
  to: house pkgname, provides-diff, soname-diff }` and requires the whole move in **one
  transaction** (`install <house>` + stock removal + every installed pinner of the moved
  provides). The counterpart is declared (`replaces=`-shaped recipe metadata) or derived by
  the `abi_stock_name` heuristic as fallback; the Layer-3 comparison rule (rule 23,
  `docs/MEMORY.md:453-474`; durable rules at `docs/NOTE.md:96-102`) is preserved as the
  gate's semantics: "whatever provides the pkgname, else its stock counterpart; a fresh-install
  skip needs the double negative, because a swap MOVES the surface."
- **Swap waves retire exact-pin leftovers, never rebuild them** (rule 29,
  `docs/MEMORY.md:601-610`): the planner sweeps installed exact-version pins on swap-set
  packages (`expac -Q '%n\t%D'`-equivalent over the installed-ELF/DB index) and proposes
  retirement rows, never a rebuild of a deliberately trimmed package.
- **Atomic staged swap + last-known-good** (M2/M3 of `plan-gentoo-qol.md`): a wave transaction
  stages all archives (provider + consumer closure + swap removals), runs every gate on the
  *whole set* (PGO payload `pgo_payload_refusals` `build-all.fish:2301-2352`, ABI rows, QA
  checks), then commits as **one** `pacman -U --ask 4` — with the rule that `--ask 4` is
  *removal consent decided in the plan*, never safety (rule 23). The binpkg index retains the
  previous instance (Q8 retention) as the rollback artifact, so recovery is
  `gsa install --rollback <pkg>` from the index instead of the `/var/log/pacman.log`
  archaeology the ICU recovery needed (`docs/MEMORY.md:234-252` rule 13 recovery).
- This also closes the M2 "staged provider" seam: `install_plan` gains a `wave` row shape and
  the ICU/spandsp playbook (`docs/NOTE.md:730-757`) stops being tribal knowledge. The
  recipe-side staging hazard (`.pc`/libdir rewrites, spandsp trap) stays fail-closed: if link
  metadata cannot be rewritten, the wave refuses.

---

## 5. Package-manager tool surface

### 5.1 Verbs

One binary, verb-style subcommands (aliases keep the old flag spellings for the frozen seams —
Q5). Each row cites the Portage mechanism it maps (full mapping in §6).

| Verb | Behaviour in our terms | Portage analogue |
|---|---|---|
| `gsa sync` | version-sync pass: Arch query (`pacman -Si`), nvchecker providers, AUR `.SRCINFO`, GitHub release digests; checksum re-anchoring to the authority (rule 18); uncommitted rewrites reported (`docs/build-guide.md:134-306`) | `emerge --sync` (but ours syncs *recipe versions to providers*, not an rsync repo) |
| `gsa fetch` | fetch+verify sources ahead of builds: `plan.md`'s subsystem, `makepkg --verifysource` as the only engine | `emerge --fetchonly` / `FEATURES=parallel-fetch` |
| `gsa build` | dispatch lanes, makepkg per recipe, freshness gates, toolchain identity, PGO gates | compile phases |
| `gsa install` | install plan rows → one transaction per package/wave; `--from-archives`, `--rollback`, `--decide` (the frozen seam) | `emerge` merge |
| `gsa deselect` (alias `dequeueremove`) | remove a name from the world file so future `update` passes skip it | `emerge --deselect` |
| `gsa update` | sync + computed stale/rebuild sets + build + install (the `@world` transaction) | `emerge -uDN @world` |
| `gsa world` / `gsa sets` | world file (explicit wanted set) and named sets: `@world`, `@preserved-rebuild`, `@live-rebuild` (the `git` group), `@stale`, `@abi-must:<anchor>`, user sets in `config/sets/` | world/sets (portage(5), sets.docbook) |
| `gsa query` / `search` / `info` | read-only over `.SRCINFO`, binpkg index, side-car DB, installed DB (`expac`-shaped output) | `equery`/`emerge --search` |
| `gsa revdep-check` | installed-ELF index scan: unresolved NEEDED, preserved-lib survivors, exact-pin leftovers | `revdep-rebuild` check half, `--depclean-lib-check` |
| `gsa revdep-rebuild` | computed rebuild set (§4.3), `--pretend` renders the wave | `@preserved-rebuild` + `revdep-rebuild` |
| `gsa pretend` | dry-run: plan order + install-plan rows + wave reasons without building | `emerge -p` |
| `gsa clean` | archive retention pruning (Q8), `-cc`/`-ccc` semantics preserved | `FEATURES=clean-logs`, `emaint` |
| `gsa maintain` | sub-verbs: `index` (binpkg index regen), `resume` (history hygiene), `logs` (retention), `doctor` (lane/run/log reconciliation, db health report), `prune-ignorepkg` (stale IgnorePkg removal with dated pre-image, rule 9), `world` (repair) | `emaint binhost/cleanresume/logs/merges/cleanconfmem/world` |
| `gsa logs` | per-package log browse/tail with retention policy | `PORTAGE_LOGDIR` + `clean-logs` |

### 5.2 Binary-package model (buildpkg / usepkg / Packages / multi-instance)

Adopting `plan-gentoo-qol.md` M3's mapping inside `gsa-state`:

- **Binpkg index**: one row per built instance —
  `pkgbase|pkgname…|full-version(epoch:pkgver-pkgrel)|archive-sha256|abi-token|provides|vcs-baseline|built-at` —
  written only after the manifest-v2 baseline lands (fail closed on divergence, M3 risk note).
  It is our `Packages` index (`emaint binhost`): `-s` currency, install discovery and
  provenance read the index instead of re-deriving filenames (the epoch bug class,
  `docs/NOTE.md:889-907`).
- **Install-from-archives**: `gsa install --from-archives` installs the index-complete set
  with zero building (the `--usepkgonly` analogue) — the escape hatch for walled upstreams.
- **Retention**: N instances per recipe (Q8 default N=2 for providers/hubs) —
  `binpkg-multi-instance` as artifact retention only, never parallel installs (pacman is
  one-version-per-name).
- **Skipped deliberately**: `quickpkg` (repacking installed files would bypass the pre-strip
  PGO gate — `docs/adr/0001-pgo-shared-gate.md`), gpkg/GLEP-78 signing (artifacts are
  host-tuned and not redistributable — `README.md`; index signing remains
  `plan-gentoo-qol.md` owner Q5).

### 5.3 QA-check registry (install-qa-check.d analogue)

`gsa-qa` defines one declaration surface: `name, scope (recipe|topology|host|install),
severity (report|refuse), stable keyword`. Existing code migrates behind declarations with no
behaviour change: the audit lints (`lib/audit.fish`) become `report` checks; the PGO payload
gate and ABI provide gate become `refuse` install checks (their fail-closed contract is
rule 25(h), `docs/MEMORY.md:491-544`); `install_needed_probe`'s unresolved-soname report is
the `qa-unresolved-soname-deps` analogue and runs at both audit and install time. Portage's
drop-in scripts (`bin/install-qa-check.d/10executable-issues`, `80libraries`,
`90world-writable`, …; `FEATURES=strict`/`stricter`) are the shape: a new recurring breakage
class becomes one named check with a fixture, not a one-off lint (`plan-gentoo-qol.md` M5).
**Recommendation on its owner Q4 (the QA gate line):** severity is a per-check attribute —
`report` for drift/observations, `refuse` reserved for the existing fail-closed classes
(checksum/PGP provenance, PGO payload, ABI surface loss) and anything new must argue for it.
This keeps `CONTEXT.md`'s "audit lint is report-only by contract" true for the audit *scope*
while the install seam keeps its teeth.

---

## 6. Portage reference mapping

**Errata carried from `plan-gentoo-qol.md` §4 (the brief's GLEP numbers were wrong):**
**GLEP 55 is NOT slot operators** — GLEP 55 ("Use EAPI-suffixed ebuilds") is Rejected;
sub-slots and slot operators `:=`/`:*` are **EAPI-5 PMS features: PMS §7.2 (sub-slot) and
§8.3.3 (slot-operator dependencies)**, practice guidance in the devmanual's Slotting page
(https://projects.gentoo.org/pms/9/pms.html, https://devmanual.gentoo.org/general-concepts/slotting/).
**Licenses are GLEP 23** ("Handling of ACCEPT_LICENSE", https://www.gentoo.org/glep/glep-0023.html),
not GLEP 61/75. (Also from that file: `FEATURES=preserve-logs` and `FEATURES=qa` do not exist;
the real knobs are `clean-logs`/`binpkg-logs`/`unmerge-logs`/`compress-build-logs` and
`strict`/`stricter`/`QA_STRICT_*`.)

| Portage subsystem | What we take | What we deliberately do NOT take (Portage is Python and slow; we are native) | Our version |
|---|---|---|---|
| ebuild phases (fetch/src/configure/build/install; devmanual phase functions) | phase *separation*: fetch+verify is its own gate ahead of build (`plan.md` §5); named failure points | the bash phase runner itself — **makepkg is our phase runner**; PKGBUILD `build()/check()/package()` stay (`Q3`) | `gsa fetch` / `gsa build` over makepkg |
| depgraph / resolver (emerge) | pretend rendering, blocker-shaped refusals (a missing consumer in a wave refuses) | the resolver: slot solving, USE-deps, dynamic deps, `--complete-graph` — our build-order graph is hand-wired (`CONTEXT.md`) | topology graph + consumer expansion (`gsa-graph`) |
| slot operators / sub-slots (PMS §7.2/§8.3.3) | recorded-subscription rebuild semantics: abi-token, `:=`/`:*` edge classes, computed rebuild set | parallel slot installs of multiple versions (devmanual Slotting) — pacman is one-version-per-name | `abi-token` + `revdep-rebuild` (§4) |
| `FEATURES=preserve-libs`, `@preserved-rebuild` (make.conf(5), sets.docbook) | preserve contract + auto-remove-when-consumers-gone + heal-set name | nothing else — ALPM has no file-level preserve | preserved-lib registry + `gsa revdep-rebuild` (§4.4) |
| binhost / `Packages` index (`emaint binhost`, portage(5) `binrepos.conf`) | one index row per built instance; install-from-archives; multi-instance retention | distribution/transport/signing (GLEP 78 gpkg, `verify-signature`) — artifacts are not redistributable | binpkg index (§5.2) |
| `emaint` (emaint(1)) | the maintenance verb surface | its Python implementation | `gsa maintain` (§5.1) |
| `etc-update` / `dispatch-conf` (CONFIG_PROTECT flow) | essentially nothing — we have no CONFIG_PROTECT file class; our clobbering problem is already solved by dynamic IgnorePkg (rule 9, `docs/MEMORY.md:149-184`) | the prompt/merge/patch machinery | only `maintain prune-ignorepkg` (cleanconfmem analogue) |
| `revdep-rebuild` (gentoolkit) | link-level breakage detection + rebuild trigger | gentoolkit itself | `gsa revdep-check` + `gsa revdep-rebuild` |
| `eselect` | at most a selector concept later (e.g. kernel/profile choice) | the module framework — skip in v1 | none |
| world / sets (portage(5), sets.docbook) | world file of wanted atoms + named computed sets | world as dependency-solver input (we have no solver) | `gsa world` / `gsa sets` (§5.1) |
| FEATURES (make.conf(5)) | named policy toggles as config keys: buildpkg (=always-index), keep-going, preserve mode, clean-logs, load/disk admission (emerge(1) `--load-average`, `--jobs-tmpdir-require-free-gb`) | USE flags, profiles, keyword masking, license gating (licenses are GLEP 23 attribution for us, `docs/package-policy.md`) | `config/build-defaults.conf` extension + `gsa-sched::budget` |
| logs (PORTAGE_LOGDIR, `clean-logs`) | per-package timestamped logs + retention policy (rule 19 log ownership, `docs/MEMORY.md:375-396`) | `compress-build-logs` etc. as separate features | `gsa logs` / `maintain logs` |

---

## 7. Migration / strangler plan

Principle: **both engines work at every phase**, and the fixtures keep proving behaviour
against whichever engine is behind the frozen seams. Every phase ends with
`RUN_ALL_JOBS=6 bash tests/run-all.sh` green (55 fixtures; the battery's conventions:
non-mutating, `$TMPDIR`-scoped, parallel-safe — `tests/run-all.sh:1-25`).

**Phase 0 — contract freeze + golden masters.** Write the seam manifest: every flag, the
run-record grammar (`format: 1`, `docs/build-guide.md:430-502`), the `--install-decide`
rows/rc (`:48-58`), the lane-result wire (`build-all.fish:4866-4954`), the hidden-seam argv
shapes (`:7082-7103`). Capture golden outputs of the fish engine for a corpus of fixture
workspaces into `tests/assets/` (the repo's frozen-oracle pattern, `CONTEXT.md` "Frozen
oracle"). *Done when:* every seam the binary must keep is named and golden files exist; battery
green.

**Phase 1 — native read-only core.** `gsa topology|list|pretend|query` parses
`topology.conf`/`build-defaults.conf`/`abi-exclusions.conf` + committed `.SRCINFO` natively.
No builds, no installs. *Done when:* `--topology`, `-l`, `-n` output is byte-identical to the
fish engine on every fixture workspace and the real tree (differential test against the
Phase-0 goldens); startup budget (§8) met; battery green (fixtures still drive fish).

**Phase 2 — native scheduler + build engine, installs still fish.** `gsa build --no-install`
runs lanes (makepkg children), the codec, signals, locks, run record. The fish engine keeps
serving `-i`. *Done when:* the scheduler/install-free fixtures
(`scheduler-core-solo`, `scheduler-dispatch-order`, `scheduler-intensity`,
`signal-abort-lock`, `run-record`, `resume-command`, `dashboard`) pass against **both**
engines; the run-record block is byte-stable (`format: 1`); deferral (rc 99) and interrupt
(exit 130) semantics identical.

**Phase 3 — native install pipeline.** Port `install_plan`/`install_execute` behind the
`--install-decide` seam; transactions still `pacman -U` subprocesses (Q6). *Done when:* the
install fixtures (`install-archive-guard`, `install-conflict-ask`, `install-needed`/
`abi-postinstall-probe`, `ignorepkg-register`, `abi-drift-install`, `pgo-payload-guard`,
`local-db-repair`, `pacman-mutex-shim`) pass against the binary with zero behaviour drift —
including the zero-pacman-call refusals (rule 25(h)); `build-all.fish` becomes a thin shim for
all build/install paths.

**Phase 4 — package-manager features.** binpkg index + retention + `--from-archives` +
rollback; abi-token DB + subscriptions + `revdep-rebuild`/`revdep-check`; wave transactions
(staged swap, surface moves); QA registry; `maintain`/`logs`/`world`/`sets`; `gsa fetch`
(plan.md's subsystem natively); cone-stop mode (Q7). *Done when:* each feature has fixtures
that derive expectations from records (rule 25(j)); the ICU/spandsp/run-#31 scenarios exist as
wave fixtures (extend `tests/swap-completeness.sh`/`tests/abi-drift-install.sh` shapes); the
full battery is green against the binary.

**Phase 5 — cutover + retire the fish engine.** `build-all.fish` remains a documented
argv-mapping shim for one release cycle (Q5); the fish engine itself is archived under
`tests/assets/` as the frozen differential oracle, then removed when the oracle diffs are
clean for a full release. Docs (`docs/architecture.md` four-module description,
`docs/MEMORY.md` rules with function handles, `docs/build-guide.md` output contract) are
re-pointed in the same change. *Done when:* the shim + battery are green, the oracle diffs are
empty, and `docs/NOTE.md` carries the migration entry.

**Bootstrap.** The binary ships as a recipe in the repo it manages — `packages/core/gsa-pm`
(cargo workspace build). Rules: crates are vendored (`cargo vendor`) and checksum-pinned like
any source — **never** `--skipchecksums`; `.SRCINFO` regenerated; a topology record added
(`core,build-tools`, no edges until it builds itself). Bootstrap order: Arch's `rust` (or the
workspace's `rust-git`) builds the first `gsa` from a clean checkout; `gsa build gsa-pm` then
self-hosts. The builder already treats rustc as toolchain surface it must survive
(`check_rustc_sanity` `build-all.fish:5416-5463`), so no new trust class is introduced. The
PM never needs itself to build — a broken `gsa` is recoverable with `makepkg` alone.

---

## 8. Performance budget

Targets are budgets to design against, not measured facts about code that does not exist yet.
Baselines are the measured/recorded numbers in §0 and `docs/NOTE.md:105-150`.

| Metric | Today (evidence) | Target | How it dies/lands |
|---|---|---|---|
| Invocation startup (no-op) | 2.2–4.6 s CPU per builder invocation (§0 measurements; the brief's ~1.1 s figure is an earlier lower bound); each `--lane-job` child pays it again (`build-all.fish:8479-8528`) | < 50 ms process start, < 150 ms including topology load (653 records) | native parsing replaces interpreted execution of ~13k fish lines; `.SRCINFO` cache replaces forked eval |
| `--list`/`--topology` full render | 4.2–4.6 s CPU / 5.9–9.3 s wall (§0) | < 250 ms | one pass over an in-memory graph |
| Dispatch latency | ≤ 1 package per lane per 0.5 s poll (`build-all.fish:5975-6894` tracked sleep); measured 244 stub packages @ lanes=1 = **276–317 s of pure dispatch latency**; 30 stubs = 15.7 s @ lanes=1 vs 1.2 s @ lanes=8 (`docs/NOTE.md:105-150`) | < 5 ms per dispatch; 244 stubs dispatch < 2 s at any lane count | event-driven supervisor (waitpid + readiness queue); the poll cycle dies by construction |
| Fixture battery wall | 178.4 s @ RUN_ALL_JOBS=6 (down from 309.6 s — `docs/NOTE.md:105-150`) | < 60 s with equal coverage | startup + poll death + native metadata reads; transport-retry backoffs stay (they are the tested semantics) |
| Parallel build throughput | bounded by makepkg compiles; 2 lanes × -jN on a 24-thread undervolted host (`docs/portability.md:6-70`) | scheduler overhead < 1 % of lane time at 8 lanes; zero added memory contention | same budget formulas (ported as data); `gsa fetch` hides network stalls (advisory, `plan.md`) |
| Memory per lane / dispatcher | fish interpreter per lane child + dispatcher globals | lane supervisor < 5 MB RSS above the makepkg it runs; dispatcher < 100 MB at 653-record + full index load | lanes `exec` makepkg; the DB is mmap/stream-friendly (SQLite or plain append-only files under `.state/`) |
| Metadata probes (lint/audit) | historically 8–10k forks per lint pass; already reduced via shared parses (`docs/MEMORY.md:1217-1235`) | zero fork per recipe for metadata; ≤ 1 process per archive for payload reads, batched | native `.SRCINFO`/`.PKGINFO`/ELF readers |

Bottlenecks that die **by construction**: the 0.5 s dispatch poll; per-invocation and
per-lane fish interpretation; fork-per-eval metadata reads (Q3); string-split plan-row codecs
(`plan_row`/`plan_row_fields` `build-all.fish:3039-3046` → typed structs); the O(P×T) tag
re-scan class already flagged in `print_topology` (`build-all.fish:7266-7301` comment).
Bottlenecks that do **not** die and must not be "fixed": makepkg compile time, network
transport-retry windows (`git_ls_remote_quiet` 2/5/10 s — tested semantics), and checksum/PGP
verification cost (load-bearing, rule 15).

---

## 9. Testing strategy

**Keep the 55 bash fixtures driving the engine as a black box — and add native tests beside
them. Both, deliberately.** The argument:

1. The fixtures are not unit tests of fish; they are the *behaviour contract* at the process
   boundary: stub `makepkg`/`sudo`/`pacman` binaries driven through `GSA_FAKE_*` knobs
   (`tests/lib/fixture-lib.bash:28-130`), assertions on argv shapes that "ARE the contract",
   zero-mutating guarantees, and the run-record machine block as the assertion surface
   (`rr_*` family, `tests/lib/fixture-lib.bash:374-389`). A native rewrite re-derived as unit
   tests would silently re-derive the expectations too — the exact drift the frozen seams
   (Q5) exist to prevent. Because the binary still `exec`s makepkg/pacman/sudo (Q6), every
   stub keeps working unchanged through Phase 3.
2. Native tests add what bash cannot: parser unit + fuzz tests (`.SRCINFO`, `topology.conf`,
   `.PKGINFO`, ELF headers), and property tests over the invariants the fish code defends
   procedurally — codec round-trip (`lane_result_encode`/`decode` `build-all.fish:4866-4928`),
   "topological order respects every edge", "consumer expansion equals reverse-reachability
   closure", "every archive gets exactly one install-plan row", "an unchanged provide set
   yields an unchanged abi-token", "every accepted flag appears in the continuation table"
   (the `tests/project.sh` self-scan pin (`expected_invocations=20`,
   `docs/MEMORY.md` fixture conventions) is this property, hand-rolled).
3. **Differential/frozen-oracle testing** (the repo's own pattern, `CONTEXT.md` "Frozen
   oracle"): Phases 1–3 run fish and binary engines over the same synthetic workspaces and
   diff `--topology`, `-l`, `-n`, `--install-decide` rows and run-record blocks against the
   Phase-0 goldens in `tests/assets/`.
4. **Falsification standards the repo already enforces** (carried verbatim): every new check
   is falsified from a scratch copy with one broken input and must fail naming what broke (the
   pattern in every `docs/NOTE.md` "Validation" paragraph, e.g. `:83-87`); fixture
   expectations about topology-derived sizes are computed from records, never pinned counts
   (rule 25(j), `docs/MEMORY.md:491-544`); fixtures never read host state (fabricated DBs —
   `docs/NOTE.md:89-93`); prose output pinned in exactly one place (dashboard rendering test);
   sibling scenarios share one fixture file as `( subshell )` sections.
5. Harness mechanics stay: `tests/run-all.sh` discovery (recursive, `tests/assets/` and
   `lib/` excluded, parallel-safe — `tests/run-all.sh:1-25`); `run_builder` capture helper
   swaps its engine argument from `fish build-all.fish` to `gsa` per phase (or runs both);
   the battery must never depend on wall-clock (the `stub_sleep` capped-clock discipline,
   `docs/NOTE.md:105-150`).

---

## 10. Risks and non-goals

**Risks (first-class, with the design answer):**

1. **System bricking via pacman misuse.** Answer: pacman stays the only writer of
   `/var/lib/pacman`; one transaction gate; `--ask 4` consent lives in plan rows (rule 23);
   `db.lck` and broken local-db entries are never auto-deleted (`docs/MEMORY.md:815-845`);
   fail-closed install planning (rule 25(h)); preflight refuses before building.
2. **Dual-engine drift during the strangler.** Answer: frozen seams (Q5), golden masters,
   differential oracle (§7/§9); one install decision seam (rule 20) in both engines.
3. **Fixture blast radius.** The install-plan seams carry an explicit standing warning
   (`docs/MEMORY.md` §5 queue on ABI-refusal rows); every Phase 3 change lands with the
   `--install-decide` fixtures red-then-green.
4. **ABI over/under-expansion.** Over: token churn (mitigated: bare-stem hashing, `abi-rev`
   override, exclusions registry); under: missing subscription records (mitigated: fail
   toward the old whole-closure rule 25(c)).
5. **Rust toolchain drift/bootstrap.** Mitigated: `check_rustc_sanity` precedent, vendored +
   checksummed crates, the PM never required to build itself.
6. **Scope creep toward a resolver.** The topology graph is hand-wired on purpose
   (`CONTEXT.md`); a depgraph is a non-goal (below) and review should reject it.
7. **Unvalidated performance targets.** §8 targets are budgets; Phase 1 measures before
   Phase 2 commits to dispatch numbers.
8. **Trust model unchanged.** Recipes still execute arbitrary shell at build time
   (`SECURITY.md`); the native engine narrows the *read* path (Q3) but is not a sandbox and
   must never claim to be.

**Non-goals (explicit):**

- Replacing pacman as the host's system package manager, or maintaining a second
  installed-database of record (Q2).
- A dependency resolver, slot solver, USE flags, profiles, keyword masking, license gating
  (GLEP 23 material is attribution only here, `docs/package-policy.md`).
- Parallel installation of multiple versions of one package.
- Sandboxing recipe execution; changing the "review before running" trust model.
- Making built artifacts redistributable; binary distribution/signing infrastructure
  (GLEP 74/78-shaped tree/binpkg signing — deferred to `plan-gentoo-qol.md` owner Q5).
- Multi-host builds, distcc/ccache/icecream (second stale-object cache — `plan-gentoo-qol.md`
  M4), glsa-check/@security (no advisory feed).
- Reimplementing makepkg, its phase runner, or its verification machinery — checksums/PGP
  stay exactly where they are and are never bypassed.
