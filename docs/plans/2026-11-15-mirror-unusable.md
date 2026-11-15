# A source mirror that is present but unusable

**Date** 2026-11-15 · **Status** ready for `/implement` · **Owner decision**
recorded 2026-11-15 (see § Decisions).

## 1 Background

`sudo gsa -Sy` reported three recipes deferred with a message that names a *ref*:

```
gsa: note: acl-git: cannot resolve ref 'HEAD' in the source mirror
gsa: note: ref-unresolvable — cannot resolve ref 'HEAD' in the source mirror
gsa: note: acl-git: deferred (source-unfetchable) — no recipe was rewritten;
           retry when provider metadata is available, or use '--no-sync' ...
```

The owner suspected a regression in the `-git` → snapshot (Monday-pin) `-Sy`
anchoring landed by W5 (`055e4c5`).

**Research verdict: the suspicion is half right, and the half that is wrong
matters.** The snapshot pass did not corrupt anything; it is the first code
that *opens every mirrored repo during `-Sy`*, so it is the surface where
pre-existing corruption became visible. Measured, not theorised:

| Fact | Evidence |
| --- | --- |
| The message comes from `SnapshotRefusal::RefUnresolvable` | `crates/gsa-recipe/src/sync.rs:1857`, message at `:1689` |
| Its cause is **no `refs/` directory in the bare mirror** | `git --git-dir=<mirror> rev-parse HEAD` → `fatal: not a git repository`; `mkdir -p <mirror>/refs` → resolves again |
| 208 of 505 mirrors under `~/.gsa-src` are in this state | census of the live tree; all 208 keep `packed-refs`, none keep `refs/` |
| git never removes `refs/` | verified against git 2.56.1 for `pack-refs --all --prune`, `gc --prune=now`, `fetch --all -p`, `fetch --prune --all`, `clone --mirror`, `init --bare` |
| An external empty-directory sweep did it | 241 `refs/` dirs and 210 mirror dirs share mtime `2026-11-14 19:33:54`; the owner has confirmed an accidental blind cleanup |
| **Builds break too, so the printed remedy is false** | makepkg `extract_git` → `git clone -s` → `fatal: repository '<mirror>' does not exist`; makepkg's up-to-date check reads an empty `remote.origin.url` → `'<mirror>' is not a clone of '<url>'` → abort `E_NOT_A_CLONE_OF`. A refs-less mirror is **not** `dir_is_empty`, so makepkg never re-clones. |
| 40 of 107 `#commit=`-pinned recipes are affected | join of the recipe tree against the broken mirrors; includes `llvm-git`, `rust-git`, `glibc-git`, `babl-git`, `autofdo-git` |

So two defects are real and independent of who deleted the directories:

1. **A corrupt mirror is reported as a bad ref spelling**, and the remedy line
   sends the operator hunting a ref name that is not the problem. `MirrorMissing`
   (directory absent) and *directory present but not a git repository* are two
   different evidence gaps that the pass collapses into one keyword.
2. **Nothing can repair it and nothing can even see it.** `gsa -Md` emits 1403
   findings on this host and not one of them is a mirror-health row.

## 2 What this changes

Three deliverables, one seam each:

- **A distinct refusal class** for a mirror that exists but is not a usable git
  repository, so `-Sy` says what is wrong instead of naming a ref.
- **Self-heal in the snapshot pass**: when the mirror is a directory but has no
  `refs/`, recreate it and hand it back to the build user, then continue. This
  is the fix the owner chose, and it is the correct one because `mkdir refs` is
  a *verified complete* repair — the objects, `packed-refs`, `HEAD` and `config`
  are all intact, so nothing is lost and nothing is re-fetched.
- **A `-Md` mirror-health row plus `-Md --fix` repair**, so the operator can
  see and repair every mirror, including ones no snapshot recipe references.

Build-side surfacing is in scope: a lane that dies on an unusable mirror must
name it as a mirror fault, not leave makepkg's `is not a clone of` as the only
evidence.

## 3 Decisions (owner, 2026-11-15)

| Question | Decision |
| --- | --- |
| Repair surface | **Both**: self-heal in `-Sy`, *and* a manual `-Md --fix` verb repair |
| Scope | **Both halves**: the sync refusal class and the build-side surfacing |
| The external deletion | Out of scope: the owner has acknowledged it; no pitfall entry, no queued hunt |

## 4 Global constraints

Copied verbatim from the documents that own them. These are the reviewer's lens.

- **A behavioural change to scheduling, install, state, fetch or signals ships
  with a fixture in the same change**, and retires its dead code and config in
  the same pass. (`AGENTS.md` §4; `CONTRIBUTING.md`)
- **Every new flag lands in three places in one change**: `gsa --help`, the
  continuation flag-rule table as `mirrored` or `not-mirrored`, and at least one
  fixture. A flag absent from `--help` does not exist. (contract §L.1)
- **Two arms, never mixed.** A missing/unsatisfiable mirror (defective
  evidence) is a DEFERRAL — `source-unfetchable`, rc 5, recipe unchanged —
  because one un-fetched mirror must not abort a full-set `-Sy`. A defective
  RECIPE refuses (rc 3). (contract §B.4)
- **`-Md` is report-only; findings never change rc.** (§E.4) `--fix` applies
  the named side-car repairs.
- **Runtime state is owned at WRITE time.** The state root is root-owned; the
  build cache and the recipe store are build-user working data. The engine
  chowns only the levels it creates. (`AGENTS.md` rule 19, rule 60)
- **An unreadable file is not an absent one.** Never collapse the two with
  `if let Ok` or `unwrap_or_default`. (rule 71) This bug is that rule's exact
  shape one level down: *not-a-repository* is not *missing*.
- **Falsify every new check red-first**; a check that cannot fail is deleted,
  not kept green. (contract §L.4)
- **Fixtures**: non-mutating, `$TMPDIR`-scoped, parallel-safe, `( subshell )`
  sections, assertions via `vgrep`/`grep … < <(PRODUCER)`, never a `| grep -q`
  pipe. (contract §L.5, §L.3)

## 5 File map

| File | Responsibility | Change |
| --- | --- | --- |
| `crates/gsa-recipe/src/sync.rs` | The snapshot pass: refusal vocabulary, mirror open, self-heal | Add `SnapshotRefusal::MirrorUnusable`; add `mirror_is_usable`/`ensure_mirror_refs`; insert the self-heal before `snapshot_commit_before` |
| `crates/gsa-maint/src/doctor.rs` | The `-Md` report and `--fix` repair | Add a `mirror-health` finding family and its repair row |
| `crates/gsa-maint/src/mirrors.rs` | `gsa -Mm`: shared-mirror validation and repair | Reuse the new probe in `valid_source_mirror`; add the `refs/` restore to `--fix` |
| `crates/gsa-build/src/makepkg.rs` | makepkg orchestration, failure attribution | Attribute an unusable-mirror failure to the mirror, naming it |
| `crates/gsa-cli/src/help.rs` | The environment/command roster | Only if a flag spelling changes (it does not: `--fix` exists) |
| `tests/sync-snapshot.sh` | The `-Sy` snapshot-pin battery | New section §5: the unusable-mirror self-heal, both directions |
| `tests/gsa-maint-v2.sh` | The `-M` surface battery | New section: `-Md` mirror-health rows and `-Md --fix` repair |
| `docs/gsa-contract.md` | **Authoritative** interface | §B.4: the new refusal keyword, dated amendment; §B.7: the `-Md` row |
| `AGENTS.md` | Rule text, one line per pitfall | §5 pitfall: a mirror without `refs/` is not a git repository |

Files that change together stay together: the refusal vocabulary and its
self-heal are one change in one file, because a class that is never produced by
a repair path is a half-feature (ADR 0006's rule, one level in).

## 6 Tasks

Each task ends in an independently checkable deliverable. Model tier in
brackets: **cheap** (mechanical, fully specified), **standard** (integration),
**capable** (design or judgment).

---

### Task 1 — Name the fault: distinct refusal class for an unusable mirror
*[cheap]*

**Seam.** `SnapshotRefusal` (`sync.rs:1628`) is the public vocabulary; its
`keyword()`/`message()` are what the run record and fixtures assert on.

**Steps.**

1. In `sync.rs`, add to `SnapshotRefusal`:
   ```rust
   /// The mirror directory exists but is not a usable git repository
   /// (no `refs/`, so git answers "not a git repository").
   MirrorUnusable {
       /// The mirror path.
       path: String,
       /// What git said, verbatim, so the operator sees the real evidence.
       detail: String,
   },
   ```
2. In `keyword()`, map it to `"mirror-unusable"`.
3. In `message()`, produce exactly:
   `"the source mirror '<path>' exists but is not a usable git repository (<detail>) — repair it with 'gsa -Md --fix', or delete it to re-fetch"`
4. Register the keyword in the same change wherever the other seven are
   registered — grep `"mirror-missing"` across `crates/` and mirror every hit
   (this is contract §L.1's three-places rule applied to a keyword).
5. Add a unit test in `sync.rs`'s `mod tests`:
   ```rust
   #[test]
   fn mirror_unusable_names_the_keyword_and_the_repair() {
       let r = super::SnapshotRefusal::MirrorUnusable {
           path: "/src/acl".into(),
           detail: "fatal: not a git repository".into(),
       };
       assert_eq!(r.keyword(), "mirror-unusable");
       let m = r.message();
       assert!(m.contains("/src/acl"), "{m}");
       assert!(m.contains("gsa -Md --fix"), "{m}");
       assert!(m.contains("not a git repository"), "{m}");
   }
   ```

**Stopping criterion.** `cargo test -p gsa-recipe mirror_unusable` passes, and
`grep -rn '"mirror-missing"' crates/` and `grep -rn '"mirror-unusable"' crates/`
report the same file set.

**Failure modes this task owns.** A keyword added to `keyword()` but not to the
record's reason registry (silent vocabulary drift).

---

### Task 2 — Probe: distinguish absent, unusable, and healthy
*[standard]*

**Seam.** A pure predicate, so both `sync.rs` and `doctor.rs` share one
definition instead of drifting (`AGENTS.md` §5's "a gate in one language drifts
from the gate in the other").

**Steps.**

1. In `gsa-model` (the base crate: `gsa-recipe`, `gsa-maint` and `gsa-build`
   all depend on it, so no new edge is created), add a module or extend an
   existing one with:
   ```rust
   /// The three states a mirror directory can be in.
   pub enum MirrorState {
       /// No such directory.
       Absent,
       /// A directory git refuses to read as a repository.
       Unusable { detail: String },
       /// A readable repository.
       Usable,
   }

   /// Classify `path` by asking git the same question every consumer asks.
   pub fn mirror_state(path: &Path) -> MirrorState;
   ```
2. Implementation contract, decided here so the implementer does not have to
   guess:
   - `!path.is_dir()` → `Absent`.
   - Else run `git -c safe.bareRepository=all -C <path> rev-parse --absolute-git-dir`
     with `GIT_CONFIG_COUNT=0` and `GIT_TERMINAL_PROMPT=0` (reuse `sync.rs::snapshot_git`'s
     env discipline; that exact env is load-bearing — agent and root shells
     inject `safe.bareRepository=explicit`, which alone makes a bare mirror
     unreadable, and a prefix that drops it would report every healthy mirror
     as broken).
   - Non-zero exit → `Unusable { detail: <last line of stderr> }`.
   - Success → `Usable`.
3. Unit tests, one per arm, in the new module:
   - `mirror_state_absent_for_a_missing_dir`
   - `mirror_state_usable_for_a_real_bare_repo` (build one with `git init --bare` in a `$TMPDIR` scratch)
   - `mirror_state_unusable_when_refs_is_swept` — `git init --bare`, then
     `remove_dir_all(<repo>/refs)`, then assert `Unusable` and that
     `detail` contains `not a git repository`.
4. Make `sync.rs` use `mirror_state` at its existing guard (`sync.rs:2140`),
   replacing the bare `!mirror.is_dir()` check: `Absent` → the existing
   `MirrorMissing` deferral; `Unusable` → `MirrorUnusable`; `Usable` → continue.

**Stopping criterion.**
`cargo test -p gsa-model mirror_state` passes three tests, and
`cargo test -p gsa-recipe sync::` still passes (the `Usable` path is unchanged).

**Failure modes this task owns.** Dropping `safe.bareRepository=all` from the
probe (every mirror reads as `Unusable`, a total false positive); and treating
a permission error as `Unusable` when it is really unreadable-as-unknown.

---

### Task 3 — Self-heal in the snapshot pass
*[standard]*

**Seam.** `sync.rs`'s snapshot pass, immediately after the `mirror_state`
classification. This is the one place that may write into the source cache
during `-Sy`.

**Steps.**

1. Add to `sync.rs`:
   ```rust
   /// Recreate the `refs/` directory a bare mirror is required to have.
   ///
   /// Safe by construction: only `refs/` is touched. Every loose ref is
   /// already packed (`packed-refs` is intact), so an empty `refs/` tree
   /// restores the repository without losing or re-fetching anything.
   /// Returns the detail string on failure, for the refusal message.
   fn ensure_mirror_refs(path: &Path) -> Result<(), String>;
   ```
   Implementation contract: `create_dir_all(<path>/refs)`; on success call
   `gsa_model::privilege::own_to_build_user(&<path>/refs)` (the pass runs as
   root under `sudo gsa -Sy`, and the mirror is build-user working data — rule
   60; a root-owned `refs/` would make the next build-user `git fetch` fail);
   `own_to_build_user` is already a no-op when not root, so no uid branch here.
2. In the pass, extend the `Unusable` arm: attempt `ensure_mirror_refs`; on
   `Ok` re-classify with `mirror_state` and continue on `Usable` (one line
   logged to the report's `log` naming the heal); on `Err(detail)` fall through
   to the `MirrorUnusable` deferral.
3. The heal must log exactly one line per healed mirror, of the form
   `<pkg>: mirrored repository repaired (refs/ restored)` — the fixture asserts
   on it, and it is the operator's only evidence that a write happened.
4. Unit test in `sync.rs`'s `mod tests`, red-first:
   ```rust
   #[test]
   fn ensure_mirror_refs_restores_a_swept_bare_mirror() {
       // git init --bare, commit one object, remove refs/, assert
       // mirror_state == Unusable, call ensure_mirror_refs, assert
       // mirror_state == Usable and HEAD still resolves to the same sha.
   }
   ```

**Stopping criterion.** `cargo test -p gsa-recipe ensure_mirror_refs` passes,
and re-running the test with the `ensure_mirror_refs` call commented out makes
it fail on the `Usable` assertion — recorded in the change description.

**Failure modes this task owns.** Creating `refs/` as root and leaving it
root-owned (the next build-user fetch fails); healing a mirror that is broken
for another reason (e.g. corrupt `objects/`) and reporting success.

---

### Task 4 — `-Md` mirror-health row and `-Md --fix` repair
*[capable]*

**Seam.** `doctor.rs::findings` + `report` + `fix`. `-Md --fix` already exists
(`gsa --help`: "`gsa -Md [--fix]`"), so **no flag is added** and contract §L.1's
three-places rule is satisfied by the existing roster.

**Steps.**

1. Extend `Findings` with `mirrors: Vec<(PathBuf, String)>` — one entry per
   non-`Absent`, non-`Usable` mirror found under the resolved `SRCDEST`.
2. Populate it in `findings` by iterating the `srcdest` root's immediate
   entries and classifying each with `mirror_state`. Iterate **immediate
   children only** — the root also holds 607 loose downloads, so a recursive
   walk is both wrong and slow (a measured ~29 s hazard in this repo's history).
3. In `report`, emit one row per finding with the subject form
   `mirror:<path>`, action `unusable`, reason `<detail>` — the same subject-shape
   convention as `run-lock:<path>` (doctor.rs:258), so a reader splitting the
   row sees the action where it expects it.
4. In `fix`, when `apply`, call the same `ensure_mirror_refs` seam from Task 3
   (import it; do not copy it) and emit `Row::new(<path>, "repaired", "refs-restored")`
   on success or `Row::new(<path>, "failed", <detail>)` on failure. In
   `--fix` dry-run mode, emit `Row::new(<path>, "repair", "refs-restore")`.
5. A repair failure must not abort the other repairs; count failures and let
   the existing exit adapter classify rc.
6. Fixture: new section in `tests/gsa-maint-v2.sh`, in the house style:
   - Build a `GSA_BUILD_DIR`-scoped `srcdest` with one healthy `git init --bare`
     mirror and one swept (`remove_dir_all refs`) mirror.
   - `-Md` reports `mirror:<swept>` `unusable` and **no** row for the healthy
     one; rc unchanged (§E.4).
   - `-Md --fix` (dry run) plans `repair refs-restore`; `-Md --fix` applies it,
     the swept mirror classifies `Usable` afterwards, and a second `-Md` shows
     no finding.

**Stopping criterion.** `bash tests/gsa-maint-v2.sh` passes; reverting the
`fix` arm to a no-op makes its new assertions fail (red-first, recorded).

**Failure modes this task owns.** Recursing into loose downloads; treating a
symlinked mirror (`gsa -Mm` creates those) as unusable; repairing without
handing ownership back.

---

### Task 5 — Build-side attribution
*[standard]*

**Seam.** `gsa-build/src/makepkg.rs`'. A lane that fails because a mirror is
unusable must name the mirror, so the operator is not left with makepkg's
`'<mirror>' is not a clone of '<url>'` as the only evidence.

**Steps.**

1. Before the lane spawns makepkg, classify **every** mirror the recipe's
   sources will read with `mirror_state`; a recipe whose mirror is `Unusable`
   fails the lane early with a lane outcome naming `mirror-unusable` and the
   path, rather than spawning a makepkg that will die with its own wording
   (and, for `-S`, abort after a build that could never have succeeded).
2. The heal from Task 3 already runs on `-Sy`; do **not** heal from the build
   path — a build must not write into a shared cache another lane may be
   reading (`AGENTS.md` §5's swap-window pitfall is the same class). The build
   path reports and refuses; repairing is `-Sy`'s or `-Md --fix`'s job.
3. Fixture: extend `tests/anchor-defer.sh` — the fixture that already pins
   "one unanchorable recipe defers, its dependent parks, unrelated work still
   builds" — with a swept-mirror arm. This fixture is the right home because
   the new behaviour is the same subject (one unusable recipe must not abort
   the run) and it already carries an inline `makepkg` stub with a per-recipe
   invocation log. Assert the affected recipe's row names `mirror-unusable` and
   the mirror path, unrelated recipes still succeed, and **no** `makepkg` spawn
   was logged for the affected recipe.

**Stopping criterion.** The new fixture arm passes, and with the pre-spawn
probe removed it fails on "makepkg was spawned" — both recorded.

**Failure modes this task owns.** Probing a mirror path the recipe does not
actually use (false refusal); writing into `SRCDEST` from the build path.

---

### Task 6 — Contract, memory, and the documentation trail
*[cheap]*

**Steps.**

1. `docs/gsa-contract.md` §B.4: add `mirror-unusable` to the refusal-keyword
   list with the same dated-amendment style the section already uses, and state
   the heal: a mirror that is a directory but has no `refs/` is repaired in
   place and the pass continues; a failure defers with `mirror-unusable`.
2. `docs/gsa-contract.md` §B.7: add the `-Md` `mirror:<path>` row to the doctor's
   documented row set.
3. `AGENTS.md` §5 (Sources, refs and freshness), one line, mechanism only:
   *a bare mirror without `refs/` is not "empty" to makepkg and not a
   repository to git — it fails `clone -s` and reads as `is not a clone of`, so
   report it as `mirror-unusable` and repair only `refs/`*. No incident
   narrative, no dates (those go to the journal).
4. `docs/build-guide.md` § troubleshooting: the operator-facing remedy —
   `gsa -Md` shows it, `gsa -Md --fix` repairs it, deleting the directory
   re-fetches.
5. `docs/gsa-fixture-migration.md`: one line for the new fixture sections.

**Stopping criterion.** `grep -rn 'mirror-unusable' docs/ AGENTS.md` finds the
contract, the build guide and the pitfall; no doc restates the rule text from
another.

## 7 Self-review

**Spec coverage.** Every requirement has an owning task: the wrong class (1),
the shared probe (2), the self-heal (3), the manual repair (4), the build half
(5), the durable record (6). The owner's three decisions are all reflected in
§3.

**Step scan.** No step is a gap and none is a transcript: each names a file, an
exact signature or an exact string, and a command whose output decides it.

**Interface consistency.** One name throughout: `mirror_state` /
`MirrorState` / `MirrorUnusable` / `ensure_mirror_refs`. Task 4 and Task 5 both
*import* `ensure_mirror_refs` and `mirror_state` rather than defining their own
(the drift this repo has already paid for once). The keyword is `mirror-unusable`
everywhere, matching the existing hyphenated `mirror-missing`.

**Failure modes, the five most likely to bite:**
1. Dropping `safe.bareRepository=all` from the git invocation → every mirror
   reads broken. Owned by Task 2.
2. Creating `refs/` as root → the next build-user fetch fails. Owned by Task 3.
3. Recursing into 607 loose downloads → a slow doctor. Owned by Task 4.
4. Healing from the build path → a write racing a live lane. Owned by Task 5.
5. Reporting `Unusable` for a permission error (unreadable ≠ unusable). Owned
   by Task 2's third arm and Task 1's detail passthrough.

**Proportion.** Six tasks, no code bodies beyond the signatures and strings the
tests pin. The plan is longer than the diff it describes, as it should be.

## 8 Out of scope

- Identifying the external sweep that deleted `refs/` (owner decision).
- Re-fetching a genuinely absent mirror from the network (§B.4 keeps that a
  deferral).
- Repairing a mirror broken for a reason other than `refs/` (corrupt
  `objects/`): classified, reported, not repaired.
