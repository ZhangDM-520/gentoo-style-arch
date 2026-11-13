# Plan — per-recipe snapshot boundary (2026-11-12)

**Status: QUEUED enhancement, not in this campaign.** Opened during the
2026-11-12 full-rebuild campaign at the owner's request; deliberately not
implemented mid-campaign.

Evidence record (claims with re-runnable handles, boundary table, falsification
log): `2026-11-12-per-recipe-snapshot-boundary-research.md`, same directory.
Claim ids below (`A*`, `B*`, `C*`) refer to that record.

## The problem, stated precisely

The snapshot-pin provider advances every `#commit=` recipe to the last commit
at or before the most recent **Monday 00:00 UTC** — one global instant for the
whole tree. Two recipes can therefore be cut days apart from each other, and a
coupled pair can straddle a provider's change: the provider moves into a new
commit range while its consumer still sits in the old one.

The campaign hit exactly that. Measured, not theorised (B10, B11):

| deterministic cut | weekday | verdict |
| --- | --- | --- |
| 2026-11-05 | Thursday | FINE |
| 2026-11-06 | Friday | FINE |
| 2026-11-07 | Saturday | FINE |
| 2026-11-08 | Sunday | **BROKEN** |
| 2026-11-09 | Monday | **BROKEN** |
| 2026-11-10 | Tuesday | **BROKEN** |
| 2026-11-11 | Wednesday | **BROKEN** |
| 2026-11-12 | Thursday | FINE |

`llvm-git` sat on the Monday 11-09 cut; `rust-git` sat on the Monday **11-02**
cut — six days apart in content. LLVM PR #239919 renamed
`codegen::InitTargetOptionsFromCodeGenFlags` →
`codegen::getTargetOptions(cl::LibraryOptionsContext&, const Triple&)` at
2026-11-07T18:19Z (B5), and upstream rust's fix reached `main` only at
2026-11-11T11:06Z (B9). The provider's cut was after the rename; the
consumer's was before the fix. Hence `rustc: symbol lookup error … undefined
symbol _ZN4llvm7codegen33InitTargetOptionsFromCodeGenFlags…`.

**The owner's hypothesis — "llvm should use a Friday checkout" — is right about
the observed date and wrong about the mechanism.** A Friday cut *would* have
avoided this incident, but only because it fell outside the rename→fix window.
The window is not weekday-aligned: the same Monday cadence is fine in an
ordinary week and broken in three consecutive weeks here because the window
lasted four days (B10). So "pin LLVM to Friday" is a coincidence that happens
to hold this week, and encoding it as policy would displace the real invariant.

**The real invariant is a RELATIONSHIP, not a date.** A consumer must be cut at
a commit that knows the provider's API, *and* the provider must be cut at a
commit whose API the consumer knows. Either side moving alone can break it
(B1, B2, B11).

## What the engine already gives us

Three findings make this cheap, and one makes it subtle.

1. **The plumbing is already per-recipe.** `monday_boundary(now)` is a pure
   function with exactly one production call site, `prepare.rs:330`, inside
   `sync_one` — which runs once per recipe (A1, A2). The boundary value is
   already a `&str` parameter threaded into `sync_snapshot` and on to
   `git rev-list --before=` (A3). Only the *value's source* is global; the
   *shape* needs no change.
2. **A per-recipe channel already exists in this exact pass.** The provider
   already reads the PKGBUILD variable `_snapshot_ref=` through `pkgbuild_var`,
   which sources the PKGBUILD and returns any declared scalar with no
   allow-list of names (A13). A sibling `_snapshot_boundary=` therefore needs
   **no** new grammar: no topology tag (`Tag` is a closed enum), no CLI flag
   (contract §L.1's three places), no `config/*.conf` (which would inherit the
   abi-exclusions two-parse-sites duplication), no `gsa.conf` key (closed
   roster) (A12, A14, A16).
3. **The diagnostic that fired is already correct and loud.** The engine's
   `rustc` sanity probe caught the dead consumer, tried the rule-2026-10-02
   narrow remediation build, and refused rc 3 when that build also failed
   rather than compiling anything else with a broken `rustc`. That is the
   discipline working; nothing here asks to weaken it.

**The subtlety:** a plain `-S` also runs the sync pass, not only `-Sy`
(A9) — operationally confirmed this session, when two `-S --leaf` runs quietly
re-advanced the pin until `--no-sync` was passed. Any per-recipe boundary
design must therefore be honoured on *every* sync-enabled run, and a campaign
that wants a frozen tree must pass `--no-sync` explicitly. A per-recipe value
that is only read by `-Sy` would be a trap.

## Proposed design (queued; three options, ranked)

The failure-mode research (C1–C22, F1–F12, contradictions X1–X3) found that the
obvious design is not the safe one. Ranked accordingly.

### P1 — report-only lint, then declared pair (RECOMMENDED; two stages)

**Stage 1 — a `topology`-scope, `severity report` lint. Ship this first.**

Walk the recorded build-order edges and compare each pair's *effective*
cutoff; report any pair whose boundaries differ, naming both. This is the only
seam that can express a cross-recipe fact at all (C18), and it needs no contract
amendment, no new vocabulary, and no change to how pins are chosen.

It catches F1 — two coupled recipes declaring different cutoffs — which today
has **nothing** guarding it: the graph carries no pin (C9) and `wave_check`
never sees a cutoff. It also catches F2's consequence (a provider whose pin
moved while its sonames did not, so no wave engages and consumers silently keep
building against the previous provider bytes, C10/C21) as a *report*, which is
honest about what the engine can know.

**Stage 2 — `_snapshot_boundary=` plus a straddle refusal, only after X1–X3 are ruled on.**

- `_snapshot_boundary=YYYY-MM-DD`, optional per recipe, read by the same
  `pkgbuild_var` call that already reads `_snapshot_ref` (A13) — no grammar
  change, no `format` or `store_format` bump, and 213 existing pins unaffected
  (A18).
- Coupling is expressed by **both recipes carrying the same value**; `abi=must`
  couples rebuild/install only and nothing couples sync boundaries today (A15).
- Report the resolved value with its rung, the way every other setting names
  its provenance (rule 73): the declared value, or `the global Monday boundary`.

### P2 — procedure, not engine: cut the pair together by hand

Until an engine rule exists: when advancing a coupled pair, give both the same
boundary, and treat the pair as one unit rather than two recipes. This is what
the campaign is doing now (frozen checkout + one patch in the store). Cheap,
honest, and it needs no design. Recorded because it is what the next campaign
should actually do.

### P3 — per-recipe boundary with no pairing rule (REJECTED)

Widens the failure surface: two coupled recipes could drift further apart than
the global rule allows and nothing would say so. The global cadence is at least
uniformly wrong; an unconstrained per-recipe date is unpredictably wrong.

### Blocking contradictions found in the failure-mode research

These are why Stage 2 is gated rather than queued as one piece.

- **X1 — the defer/refuse split cannot classify a declared cutoff.** Contract
  §-235–242 says a defective *recipe* refuses (rc 3) while defective *evidence*
  defers (rc 5). But an empty `rev-list` result — `NoCommitBeforeBoundary` — is
  routed through the **defer** arm (`sync.rs:2145-2155`), with a comment saying
  it is a property of the mirror. That is true **only while the boundary is
  clock-derived**. Under a declared cutoff the same empty result is an
  authoring defect, and the contract's own rule says it must refuse.
- **X2 — forward-only is the wrong predicate for a pair-hold.** `merge-base
  --is-ancestor` treats "not a descendant of the recorded pin" as
  `NoChangeReason::Current` — a *silent* no-op (`sync.rs:2165-2176`), and a
  spawn failure already collapses into the same answer (`unwrap_or(false)`,
  C22). A pair cutoff exists precisely to hold one member behind another, which
  is exactly that case, so wiring it through the existing check would convert an
  intended hold into an indistinguishable no-op.
- **X3 — the contract says this surface has no per-recipe opt-in.**
  `docs/gsa-contract.md:759-762` states the snapshot surface "needs no topology
  vocabulary and no per-recipe opt-in". A per-recipe or per-pair cutoff is
  definitionally per-recipe vocabulary: the change is a **contract amendment**,
  not an implementation detail, and must be written as one.

### Explicitly NOT proposed

- **Adding `libcrypto.so.3`-style names or API names to any registry.** Unrelated
  registry, and it stands a gate down instead of classifying.
- **A Friday (or any weekday) default.** B10 refutes it as policy.
- **Vendoring rust's `llvm-wrapper` or forcing a minimum LLVM.** Windows are
  already expressed as `LLVM_VERSION_GE/LT` macros and a major-equality
  runtime gate (B4, B12); the defect was a name, invisible to all of them.
- **Bumping `store_format`.** Not needed: `toolchain=gcc|clang` landed as
  vocabulary without one (A12).

## Open questions the owner must rule on

1. **X1 — should a declared cutoff that resolves nothing DEFER (rc 5) or REFUSE
   (rc 3)?** The current routing defers, which is only right for a clock-derived
   boundary. Recommended: refuse, matching contract §-235–242's own
   defective-recipe rule, and keep the deferral for a *missing mirror*.
2. **X2 — how does a pair-hold stay distinguishable from a no-op?** Today
   "not a descendant" is silently `Current`. A held member must be reported as
   held, naming the pair, or the design reproduces the exact silent-drift class
   it is meant to prevent.
3. **X3 / pairing form — declared equality, or an engine-inferred rule?**
   Equality is checkable and cheap; inference ("any consumer of a snapshotted
   provider shares its boundary") needs the engine to choose boundaries for a
   whole cone and would fight the per-recipe spirit. Either is a **contract
   amendment** (§759–762 says this surface has none today).
4. **Where does the pairing declaration live** — both PKGBUILDs, or one
   topology line? Both-PKGBUILDs needs no grammar; one-topology-line states the
   relationship once instead of twice but is a record-vocabulary change (A12).
5. **Does the Monday cadence stay the default?** Recommended: yes, unchanged.
   The incident was a relationship failure, not a cadence failure.

## Not in this plan

Applying it. This campaign continues on the frozen pre-campaign checkout with
the `rust-git` patch applied directly to the store (see
`docs/JOURNAL.md`, 2026-11-12). The engine change belongs to a future cadence
pass, with its own fixture and contract §B.4 amendment — and it owes the
"plain `-S` also syncs" consequence its own line in `docs/build-guide.md`.
