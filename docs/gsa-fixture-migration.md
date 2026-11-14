# `gsa` fixture re-contract — per-fixture migration inventory and staging plan

> **Archive record — frozen at 2026-10-12, annotated 2026-11-14.** This is
> provenance, not specification: it records the clean-slate fixture re-contract
> that the cutover consumed. Its per-fixture inventory is **FROZEN at
> 2026-10-12 and is no longer the battery's inventory** — the section map and
> the measured counts below say what survived it.
>
> Live homes: fixture **conventions** are `docs/gsa-contract.md` §L.5, the
> **disposition of every contract gap G1–G12** is §M, the per-fixture
> how-to is `AGENTS.md` §Fixture conventions, and the vocabulary is
> `CONTEXT.md`. Nothing here is normative.

## Measured decay

The frozen inventory held one row per fixture: what it pins, which assertions
are behaviour (KEEP) versus engine-coupled (REWRITE), the contract spelling
that replaces each, and its flip phase. Counted 2026-11-14 against
`tests/run-all.sh:58-62`:

| Observation | Count |
| --- | --- |
| Fixtures the battery discovers today | 58 |
| Inventory rows (the frozen set) | 58 |
| Rows naming an existing fixture | 34 |
| Rows naming a fixture that is **gone** (dangling) | 24 |
| Current fixtures with **no** row | 24 |

Two corrections to this record's own header, both verified above: "Fixtures
inventoried: 56" undercounted its own 58 rows, and "the 26 recipe fixtures
moved" is really 24 removed rows of mixed provenance — the recipe half went to
`ZhangDM-520/gsa-recipe`, but the removed set also holds host/engine-side
fixtures (`modcache-check.sh`, `provides-audit.sh`, `glibc-package.sh`).

Re-measure, never trust a number above:

```sh
find tests -name '*.sh' ! -name run-all.sh \
    ! -path 'tests/assets/*' ! -path 'tests/lib/*' -printf '%f\n' | sort
git show 2635aac:docs/gsa-fixture-migration.md | grep -c '^| `tests/'   # rows
```

A dangling row is history, not work. A current fixture without a row was
written after the freeze against the live contract, which is where its
conventions came from.

## Section map

Old anchors are kept so code comments citing them still land; nothing was
renumbered.

| Old anchor | Where it lives now |
| --- | --- |
| §0 Enumeration | "Measured decay" above |
| §1 Phase vocabulary | §1 below |
| §2 Column legend | "Measured decay" above (KEEP/REWRITE defined inline) |
| §3 Staging rules | §3 below |
| §4 Inventory table (58 rows; the "row `tests/X.sh`" citation form) | **retired** — the frozen rows are recoverable verbatim from `git show 2635aac:docs/gsa-fixture-migration.md`; 34 name a live fixture, 24 are history |
| §5 Counts | §1 below (phase tally only) |
| §6 Retired without replacement (R-1 … R-5) | **§6 below, verbatim** |
| §7 Semantic-equivalence harness | **§7 below, verbatim** |
| §8 Contract gaps, §8.1 (G1 … G12) | §8 below (IDs only; dispositions in contract §M) |

Citation defect, pre-existing and out of scope here (`tests/` is not this
record's file): `tests/log-ownership.sh` cites "§3 fish-driven deviation", but
that deviation is the 2026-10-14 spelling note that sat in §4, not the staging
rules §3 titled. Both readings land on the discipline below ("a fixture that
needs the frozen oracle installs it explicitly").

## 1. Phase vocabulary and assignment

The five flip phases are the owner's, sourced from
`docs/plans/plan-native-pm.md` §7 — the contract assigns none (gap G7). This
is the assignment contract §M's G7 row points at; all five have landed.

| Phase | Name | Surfaces | Fixtures assigned (retained) |
| --- | --- | --- | --- |
| 1 | read-only core | `-Q*`, `-Sl`/`-Bl`, `--dry-run`, `-Qt`, strict loader, target/range | `config-diagnostics.sh`, `project.sh` (+5 removed) |
| 2 | scheduler | lanes, `format: 2`, cone-stop/parked, deferral, signals, intensity, core-solo, `build-tools` | `anchor-defer.sh`, `app-group.sh`, `dashboard.sh`, `log-ownership.sh`, `makepkg-conf-inject.sh`, `run-record.sh`, `scheduler-{core-solo,dispatch-order,intensity}.sh`, `signal-abort-lock.sh`, `skip-upstream.sh`, `srcinfo-freshness.sh`, `stable-sync-checksums.sh`, `toolchain-{drift,remediation,select}.sh` |
| 3 | install | install pipeline, decision rows, `--install-decide`, IgnorePkg registration, transactions | `abi-{batch-policy,drift-install,postinstall-probe}.sh`, `ignorepkg-register.sh`, `install-{archive-guard,conflict-ask}.sh`, `pacman-mutex-shim.sh`, `pgo-payload-guard.sh`, `resume-command.sh`, `sudo-keepalive.sh` |
| 4 | PM features | the `-M` band, `-Sw`/`-Sy`/`-Su`/`-Qu`, binpkg index, side-car DB | `abi-{closure-lint,exposure-audit}.sh`, `cleanup-extensions.sh`, `local-db-repair.sh`, `recipe-contract.sh`, `swap-completeness.sh` |
| 5 | cutover | one deliberate pass retiring old assertions and the fish harness | retires across all phases |
| — | no-flip | engine-independent content only: PKGBUILD, `.SRCINFO`, assets, repo policy, host tools | 19 removed rows, all recipe-side |

9 rows named a split phase and are counted by their primary
(`abi-drift-install.sh` installs at 3, its `-Qt` argv flips at 1).

The 24 removed rows are one fact, not an inventory: the recipe half — the
recipes, their assets and the package-content pins — moved to
`ZhangDM-520/gsa-recipe` with the recipes themselves, and this record keeps no
recipe-side inventory. Individual rows are recoverable from the frozen table
(`git show`, above); they are history, not work.

## 3. Staging rules

Kept because code comments cite this section; condensed to the rules that
still describe how the migration ran.

1. **Fixture files stayed byte-identical until their flip phase.** Assertions
   retired in one deliberate pass at cutover (Phase 5), never piecemeal, and
   the battery was green at every wave boundary.
2. **Behaviour was kept; only engine-coupled spellings changed.** Scheduler
   invariants, install-before-dependents, cone-stop semantics, exit codes
   (remapped per §G.1) and decision-row *meanings* survived; argv shapes,
   byte-pinned prose and `format: 1` parsing did not.
3. **No semantics were invented for a contract silence.** Every silence a
   fixture hit became a gap (§8) resolved in contract §M.
4. **One writer per staged file.** `tests/lib/fixture-lib.bash` stayed
   byte-identical for the fish fixtures; `tests/lib/rr-v2.bash`
   (sourced-only, `.bash` so discovery cannot match it) carried the
   `format: 2` parser, `run_engine`, and the `GSA_FAKE_*` knobs.
5. **A fixture needing the retired engine installs it explicitly.**
   `install_fish_oracle` copies `tests/assets/build-all.fish` beside the
   scratch workspace; the oracle is frozen reference material, never an engine
   of record, and there is no implicit root shim.

The `GSA_FAKE_*` knob table still exists twice, in `tests/lib/fixture-lib.bash`
and `tests/lib/rr-v2.bash`; that staging window is open as of 2026-11-14.
Verify with `grep -c GSA_FAKE tests/lib/fixture-lib.bash tests/lib/rr-v2.bash`.

## 6. Retired without replacement (Phase 5)

These assertions are deleted at cutover with **no v2 assertion of any kind**
checking the same thing:

- **R-1. Fish-implementation source-shape greps (9 sites).** gsa is a shipped
  binary; there is no engine source to grep and no find(1)-shaped walk to
  pin. The behaviour each guarded is separately kept (cited) and re-pins
  behaviourally at its flip:
  - `tests/local-db-repair.sh:181-196` — `--local-db-check` existence and
    `check_pacman_db_health`/`pacman_db_local_path` wiring greps (probe
    behaviour keeps at :95-203).
  - `tests/log-ownership.sh:338-350` — `find -prune` vs `-not -path`
    sweep-implementation greps (staging-exclusion behaviour keeps at
    :235-276).
  - `tests/signal-abort-lock.sh:367-393` (`stop_lane_process` /
    `_LANE_STOP_GRACE_S` shape), `:533-547` and `:646-652` (`.pacman-shim`
    artefact shape / `"$@"` passthrough — the PACMAN shim itself is carried
    by §K.3 and keeps, only the fish artefact pins go), `:686`
    (`write_lane_result … unknown` source grep).
  - `tests/cleanup-extensions.sh:122` and `tests/texlive-recipe.sh:176-183` —
    `_DOWNLOAD_ARCHIVE_EXTS` / svn-regex source pins (coverage re-pins from
    `gsa -Mccc` target rendering).
- **R-2. format:1-only row grammar (1 site).**
  `tests/run-record.sh:60-62` — the single-token reason rule of the
  `format: 1` row codec; §H.2 makes the reason the remainder of the line and
  `rr2_body` enforces the v2 shape.
- **R-3. Flag-existence pins for flags the contract drops (3 sites).**
  `tests/resume-command.sh:82-86`, `:100-108`, `:227-228` — existence of
  `--install`/`--forceinstall` spellings inside the resume command. §B.9
  drops both flags (install-before-dependents is `-S`'s semantics); the kept
  behaviour (a resume preserves install/force semantics) re-pins as the
  `command:` line restating `-S`/`-Sf` (§H.2).

Retired **as a spelling** (behaviour re-pins; listed for the Phase 5 pass):

- **R-4. `blocked` status-name pins (4 sites):**
  `tests/anchor-defer.sh:188`, `tests/run-record.sh:48`, `:293`,
  `tests/skip-upstream.sh:630`. §H.3 supersedes `blocked` with `parked`
  (reason `waits-on-deferred`); the rows re-pin via `rr2_outcome`.
- **R-5. Tab-framed row equalities (row-framing class, 27 sites):** e.g.
  `tests/abi-drift-install.sh:89-94` (the `planrow` codec),
  `tests/install-archive-guard.sh:431-438`, `tests/install-conflict-ask.sh:151-152`,
  `:176-177`. §E.2 replaces tab framing with positional `<pkgbase> <decision>
  <reason…>` rows; the row *meanings* keep and re-pin through the §E.2
  parser, and the tab codec has no v2 form.

## 7. Semantic-equivalence harness — DESIGN ONLY (not implemented)

Purpose: prove that for the same scenario the fish engine and `gsa` produce
the same *normalized outcome*, so a per-fixture flip can be validated against
the engine it replaces. This wave specifies the shape only; no harness file
is written.

- **Scenario input** (one declarative record per scenario):
  - workspace: synthetic topology records + one-line PKGBUILDs (+ staged
    archives/conf where the scenario installs), built with
    `make_workspace`/`add_package` (tests/lib/fixture-lib.bash);
  - stub set: which `bin/` stubs are installed (makepkg/sudo/pacman/date/…)
    and their `GSA_FAKE_*` knob values (declared in tests/lib/rr-v2.bash);
  - selection: targets / `@set` / ranges / `--leaf`, and the action
    (build-only / build+install / install-only / listing), modifiers
    (`--skip`, `--skip-built`, force, prune strength) as neutral intent;
  - per-engine argv maps: fish = today's spellings (the fixtures' current
    call sites), gsa = §B grammar; the map itself is the §B.9 disposition
    table.
- **Runner shape:** `tests/engine-equivalence.sh` (discovered) sourcing
  `tests/lib/equiv-lib.bash` (sourced-only), driving `run_engine` twice per
  scenario (`GSA_TEST_ENGINE=fish` and `=gsa`) over two independent
  `$TMPDIR` workspace clones with identical stubs.
- **Normalized outcome tuple** (what must be equal):
  1. exit class ∈ {success, usage(2), refusal(3), failure-cone(4),
     failure-fast(1), deferral-only(5), interrupted(130)} — gsa via §G.1;
     fish mapped through the documented remap (its rc classes are
     engine-coupled, the class is behaviour);
  2. decision rows: ordered `(pkgbase, decision, reason-key)` triples,
     decision ∈ §E.3 {install, skip, refuse, noop, parked}, detail after the
     reason key stripped;
  3. outcome rows: ordered `(pkg, status, rc-class, reason-key)` tuples —
     `dur` dropped, fish's `blocked` normalized to `parked`, statuses per
     §H.3, rc normalized to the §F.1 lane code;
  4. `remaining`: the ordered non-succeeded pkg list (both engines' own
     declaration vs the rows-derived set must agree first —
     `rr2_remaining` vs `rr2_continuation remaining`).
- **Equivalence rule:** tuples equal after the remap table (§B.9 + §G.1 +
  §H.3); any other divergence fails naming the scenario and the tuple field.
- **Phasing:** the harness lands with Phase 2 (the first phase where both
  engines run full scenarios); the fish side freezes at cutover and the
  harness retires with the fish engine in Phase 5.

## 8. Contract gaps found

Gap inventory only. Every disposition — fixed, fixed-by-amendment,
closed-by-documentation, deferred — is in `docs/gsa-contract.md` §M; read it
there, never here. The IDs stay because code comments cite §8 and §8.1.

### 8.1 G1 — the in-run ABI repair row

Labelled because a fixture asserts on it directly and cites this subsection.
§E.3's decision vocabulary had no form for the in-run ABI repair marker
(`tests/abi-drift-install.sh` pinned `repair <arch> …`) nor for the
stock-pinner refusal. §M's G1 row carries the disposition: the surface rides
the plan-row **reason**, never a new `plan` value, so no format bump — which
is why that fixture's fish section compares row sets directly.

### 8.2 The gap register

| Gap | Surface that was silent | One line |
| --- | --- | --- |
| G1 | §E.3 decision vocabulary | no form for the in-run ABI repair row or the stock-pinner refusal — see §8.1 |
| G2 | §H.2 scalars | run-level `outcome` values and `selection-source` grammar were example-only |
| G3 | §H.3 reason keys | `mutex-timeout`, `result-clear-failed`, `signal-term`/`-hup`/`-int` unnamed (additive, so they parsed) |
| G4 | §B.8 vs §H.4 | `--leaf=no` was no defined spelling, and negation mirroring was unstated |
| G5 | §K.3 | the teardown grace window had no flag, seam or env name |
| G6 | §B.8/§D.1 | the IgnorePkg registration target `pacman.conf` was unnamed |
| G7 | phase mapping | the contract assigns no phases — this record's §1 did |
| G8 | §H.1/§H.2 | the preflight-refusal path's block shape vs the full §H.2 shape |
| G9 | §L.5 | no v2 prose spec, so one rendering test cannot be written from the contract alone |
| G10 | §D.1 | `--lane-job`'s `flags…` payload tokens were undefined |
| G11 | §B | workspace discovery (cwd vs. config-relative) was unstated |
| G12 | §H | the strict-parser readings taken where the grammar was silent |

Two inventory notes survive as facts, not gaps: the contract preamble's
fixture count is stale (re-measure it, above), and the `GSA_FAKE_*` vocabulary
exists in two tables during staging (§3).
