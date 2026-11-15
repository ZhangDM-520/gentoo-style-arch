# Plan — snapshot anchor spanning: what the measurements actually say (2026-11-15)

**Status: LANDED 2026-11-15 — Task 1 (`--first-parent`) and Task 2 (docs) only;
Task 3 deferred as this plan recommends.** Supersedes the open questions of
`2026-11-12-per-recipe-snapshot-boundary.md` with measured verdicts.
Evidence record for this plan: `2026-11-15-snapshot-anchor-spanning-research.md`
(claims S1–S34, each with a re-runnable handle and a recheck date).

Landed: `crates/gsa-recipe/src/sync.rs::snapshot_commit_before` carries
`--first-parent`; the unit test
`snapshot_pin_walks_the_mainline_not_a_merged_side_history` and
`tests/sync-snapshot.sh` §1c pin it, both **falsified red** with the flag
removed; contract §B.4 carries the amendment; the 2026-11-12 plan records the
weekday span as measured-and-rejected. The task numbers below are this record's
own; the fixture arm shipped as §1c of `tests/sync-snapshot.sh`.

## The ask

> Span the snapshot anchor across the week: `llvm` at Monday, `rust-git` at
> Wednesday, further downstream ABI consumers at Friday, so an upstream LLVM
> API change near Monday cannot land in the same cut as a consumer that has
> not picked it up yet.

## Headline: the proposal does not work, and the incident had a different cause

I reproduced the exact incident with a compile harness (`PassWrapper.cpp` of a
git `rust` built against `llvm/include` of an `llvm` commit), then swept 10
weeks × 3 policies (the harness is embedded in the evidence record's appendix,
so the grid is re-runnable):

| policy | verdict over 10 anchored weeks |
| --- | --- |
| same instant (status quo) | **9 FINE / 1 BROKEN** — the broken one is 11-09, the incident |
| provider Mon, consumer +2d (Wed) | **9 FINE / 1 BROKEN** — the same week (11-09), break-even |
| provider Mon, consumer +4d (Fri) | **8 FINE / 2 BROKEN** (09-14, 09-28) — and it fixes 11-09 |

**Spanning is never better and can be worse.** +2d is break-even with the status
quo (same week, same failure); +4d trades the incident for two *new* failures
(09-14, 09-28) that the same-instant policy gets right. So it does not repair the
incident at +2d, and at +4d it repairs it only by breaking two other weeks.

> Correction (2026-11-15, review): an earlier draft of this table stated +2d as
> 8 FINE / 2 BROKEN (09-14 and 11-09). The sweep's own raw output has exactly
> one BROKEN in that column (`span2 … 2026-09-14 rust@2026-09-16 COMPILES`), so
> +2d is 9/10 — the same failure set as the status quo. The conclusion that the
> span is not a fix is unchanged; the *strictly increases* phrasing was wrong
> and is corrected here and in every record that copied it.

And the direction is not a fix even in principle: a provider cut *earlier* than
its consumer means the consumer sees an **older** LLVM than the one it targets.
Measured both ways, every asymmetry fails on some week:

- `llvm@11-09 + rust@11-12` COMPILES, but `llvm@11-06 + rust@11-12` is
  `'getTargetOptions' is not a member` (provider too old for a fixed consumer).
- `llvm@09-14 + rust@09-18` is `no matching function for call to
  'llvm::RuntimeLibraryInfo'` (a *different* API, two weeks later).
- Reverse direction (`llvm@09-18 + rust@09-14`) is `'class llvm::TargetOptions'
  has no member named 'ThreadSafeModule'`.

So "who is earlier" is not the safety axis either. The safety axis is **the
pair must be mutually compatible, which is a property of the two commits and
not of their dates** — confirmed independently of the earlier plan's claim, and
now confirmed *against* the weekday remedy that plan left as an open option.

## The incident did not have the cause the plan assumed

The earlier research (B11) recorded `llvm-git` on the 11-09 cut and `rust-git`
on the **11-02** cut — six days apart. Re-measuring the same mirrors today:

```
live pins:  llvm-git #commit=2d12c0df533b   rust-git #commit=b5fc745fd7cc
resolved at boundary 2026-11-09T00:00:00Z:
  llvm = 2d12c0df533b   (== the pin)
  rust = b5fc745fd7cc   (== the pin)
```

Both live pins are the **11-09** boundary. There is no six-day skew today; the
11-02 reading was stale `rust` pin state from the campaign window (the recipe
repo has since landed `7837c33 … 950600c` carrying the rewrites). **The
incident was a same-instant failure, not a skew failure.** That removes the
premise the "span the week" remedy was built on: there was never an asymmetry
to correct.

The true cause is still B5/B9: LLVM renamed the symbol on 11-07T18:19Z and
upstream `rust`'s fix merged on 11-11T11:06Z. Any cut inside that window — at
any weekday — is broken. Measured over 11-04…11-13, **BROKEN for 11-08, 11-09,
11-10, 11-11** and FINE on both sides, exactly matching B10.

## And the pair is already repaired — by content, not by dates

`rust-git` carries `0009-compiler-Update-LLVM-24-targetoptions-call.patch`
(upstream `ec4acfa`, authored 11-09). Applied at the **broken** instant
(`llvm@11-09` + `rust@11-09`), measured:

```
unpatched: 1 error: 'InitTargetOptionsFromCodeGenFlags' is not a member of 'llvm::codegen'
patched:   0 errors
```

A patch is a *content* fix. It repairs the pair at a cut that no date rule can
make safe, and it keeps working as both pins advance. That is the real remedy
for an API rename, and it is already in the recipe.

## What the measurements say to build

Three defects were found that are worth fixing; none is "span the week".

### D1 — the pin selector is not first-parent (real, chronic)

`snapshot_commit_before` runs `git rev-list -1 --before=<boundary> <tip>`
(`crates/gsa-recipe/src/sync.rs:2000-2005`) with **no `--first-parent`**. On a
merge-heavy upstream that returns the newest commit *anywhere* in the merged
topology, which can be a commit from an unrelated merged history.

Measured on the live `rust` mirror over 30 boundaries: **25 of 30** picks were
off the mainline, and **1** picked a tree with no `compiler/` at all — a clippy
tree (`4c7bab2be05d`, "fix(map_clone)" S19). A pin that lands there is not a `rust`
snapshot; `pkgver()` and the build would fail on a tree that has no such file.
`llvm` is unaffected (8/8 identical) because it does not merge foreign roots.

This is a **correctness bug with a silent failure mode**, and it is the one
finding here that a date scheme cannot even express. It is also cheap:
`--first-parent` makes the pick "the newest mainline commit at or before the
boundary", which is what "a Monday snapshot of this project" means.

Falsification already in hand: the 09-02 boundary picks `4c7bab2b` (clippy tree,
no `compiler/`); `--first-parent` picks `5db7f4be` (a rust tree).

### D2 — `same-instant` is the safest default, and it is already the default

9/10 weeks pass at the same instant. No change is proposed to the cadence; the
default stays Monday-same-instant for every recipe, which is today's behaviour.
This is the one finding that *confirms* the current design rather than changing
it, and it retires the "one global instant is the defect" framing.

### D3 — a pair-compatibility gate is possible, but must be a compile, not a name check

I tried the cheap version first: extract the `codegen::` names the consumer's
`PassWrapper.cpp` calls and check each is declared in the provider's
`llvm/include/llvm/CodeGen`. It is **unsound in both directions**:

- `llvm@11-12 + rust@11-12` reports `InitTargetOptionsFromCodeGenFlags` missing
  (it is, but the consumer is `#if`-guarded and does not call it) — false BROKEN.
- `llvm@11-02 + rust@11-09` reports nothing missing — but the pair genuinely
  fails on a *different* name (`LLVMParseCommandLineOptionsWith*`).

So a static name check is not a gate. The only sound probe found is the compile
itself: `git archive <llvm-sha> llvm/include` (measured **1745 ms / 34 MiB /
2238 headers**), plus `g++ -fsyntax-only` on the consumer's wrapper. That is
affordable *per pair* but not per recipe, and it needs a C++ toolchain and the
generated `llvm/Config/*.h`, which I had to synthesize. **Recommended: not an
engine gate.** It belongs in the recipe's `check()`/CI as a targeted probe if
the owner wants one, because the recipe owns the API risk and the patch.

## Proposed work (ranked; D1 only by default)

### Task 1 (RECOMMENDED, ship it): `--first-parent` on the pin selector

- `crates/gsa-recipe/src/sync.rs`: add `--first-parent` to the `rev-list`
  invocation in `snapshot_commit_before`, with a comment on *why* (a merged
  foreign history is not a snapshot of this project).
- Contract §B.4: amend the "Evidence, not a query" bullet to say the operand is
  the newest **mainline** commit at or before the boundary, and name
  `--first-parent`.
- Unit test: a synthetic mirror with a side branch whose tip is newer but off
  mainline; assert the pick is the mainline commit.
- Fixture: `tests/sync-snapshot.sh` new section pointing a merge-heavy stub
  mirror at the boundary; assert the rewritten `#commit=` equals the mainline
  commit, and that reverting `--first-parent` fails it (red-first, recorded).
- **STOP WHEN:** the new unit + fixture arm pass, the arm fails when
  `--first-parent` is removed, and `cargo test -p gsa-recipe sync::` is green.

### Task 2 (RECOMMENDED, docs only): retire the weekday remedy

- `docs/plans/2026-11-12-per-recipe-snapshot-boundary.md`: amend the Status to
  point at this plan and record that the weekday span was **measured and
  rejected** (+2d is break-even at 9/10 with the same single failure; +4d is
  8/10 and breaks 09-14 and 09-28, which the same instant gets right), with the
  sweep table.
- `docs/JOURNAL.md`: one dated line.
- No engine change. No `_snapshot_boundary=` variable, no `abi-rev` cadence
  rule, no contract amendment for a per-recipe date.
- **STOP WHEN:** the plan's Status section names this plan and the sweep, and
  the journal has its one line.

### Task 3 (OPTIONAL, owner's call): a `-Ma` report lint for ABI-copying pairs

Only if the owner still wants an engine-side early warning. A `report`-scope
lint over recorded edges: for a consumer whose `source=()` reads a provider's
headers and that has no `abi=must`/`abi=should` tag and no rebuild edge, report
the pair so a campaign can review it. Report-only, no gate, no new vocabulary.
**Recommend deferring:** measured 9/10 same-instant weeks are safe, the one
failure was fixed by a patch, and the lint cannot tell a compatible cross-instant
pair from an incompatible one (D3). This is the option to take only if the owner
wants a paper trail rather than a mechanism.

### Explicitly NOT proposed (each measured, not asserted)

- **A weekday span** — increases breakage; refuted by the 10-week sweep.
- **A per-recipe `_snapshot_boundary=` date** — the earlier plan's Stage 2; the
  premise (skew) is gone, and dates are not the safety axis.
- **A static API-name compatibility gate** — unsound both ways (D3).
- **A compile probe in the engine** — sound but needs a C++ toolchain, the
  generated LLVM config headers, and ~1.7 s/pair; the recipe owns this risk.
- **Bumping `store_format` / adding a tag** — nothing needs new vocabulary.

## Open questions for the owner

1. **Ship D1 (`--first-parent`) alone?** It is a real correctness bug, found
   while measuring the ask, independent of the span question. Recommended yes.
2. **Does the incident's remedy belong to the recipe repo?** Measured: patch
   `0009` alone fixes the broken instant, and `rust-git` already has it. If the
   owner agrees, the engine side is D1 plus documentation.
3. **Any appetite for Task 3** (the report lint), given it cannot be a gate?
4. **Should `rust-git` pin `llvm` explicitly?** `rust` carries
   `src/llvm-project` as a submodule (`0a5579eb…`), but that is the
   **`rust-lang/llvm-project` fork** (`branch = rustc/23.1-2026-07-22`), absent
   from the `llvm/llvm-project` mirror (`cat-file` → not present). It is not
   usable as a pin against our provider, so the honest coupling is the existing
   `abi=must` tag plus the patch.

## Notes

- Harness validity: the compile grid reproduces the recorded B10 table exactly
  (11-02…11-07 FINE, 11-08…11-11 BROKEN, 11-12 FINE), which is why its verdicts
  are trusted elsewhere.
- One skew source I did **not** change and the plan does not touch: a plain `-S`
  also runs the sync pass (A9), so a campaign must pass `--no-sync`.
- The harness scripts and the raw grid live in the evidence record's appendix;
  the session scratch directory they ran in is gone.
