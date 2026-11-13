# Research — per-recipe snapshot boundary (2026-11-12)

Evidence ledger for `2026-11-12-per-recipe-snapshot-boundary.md`. Every claim
carries the handle that re-confirms it, the version it is true for, and the
date it must be looked at again.

**Status: QUEUED. No engine change has been made.** Research only.

Ask: "could we modify per-recipe snapshot checkout snapshot date? llvm should
use a Friday checkout instead of our bulk Monday checkout — llvm upstream
moving kills the downstream consumer that checked out the same date."

Recheck the whole record with the `Recheck` commands at the bottom before
relying on it.

## Answer

**On the observable fact, the hypothesis holds: a Friday cut would have avoided
this incident** (B10 — the 11-06 and 11-07 cuts are FINE, the 11-08 through
11-11 cuts are BROKEN).

**On the mechanism it does not hold.** The failure window is not weekday-aligned;
it is bounded by one LLVM rename at 2026-11-07T18:19Z and one upstream rust fix
that reached `main` only at 2026-11-11T11:06Z (B5, B9). Three consecutive
Mondays fall inside that window, so "Monday is unsafe" and "Friday is safe" are
both four-day coincidences. Encoding either as policy displaces the invariant
that actually matters: **a provider and its consumer must be cut from a
mutually compatible pair, which is a relationship between the two recipes and
not a date** (B1, B2, B11).

**And the change is cheaper than expected, but it must be paired, not merely
per-recipe.** The plumbing is already per-recipe — `monday_boundary` has one
production call site inside a per-recipe loop (A1, A2) — and the pass already
reads an arbitrary PKGBUILD scalar via `pkgbuild_var` (A13), so a sibling
`_snapshot_boundary=` needs no grammar change at all (A16). A per-recipe value
*without* a pairing rule would widen the failure surface (P2, rejected in the
plan).

## Claims

Statuses: `verified` = observed by running something; `cited` = read from code,
a log or a commit; `inferred`/`unknown` support nothing.

### Q1 — the boundary spine (where a per-recipe override would enter)

| id | claim | status | source | handle | version | recheck |
| --- | --- | --- | --- | --- | --- | --- |
| A1 | `monday_boundary(now_unix) -> String` is the sole producer: floors `now` to the most recent Monday 00:00:00Z via `(days+3).rem_euclid(7)+1` and Hinnant `civil_from_days`. A Monday resolves to *that* Monday, not the previous week's. | cited | code | `crates/gsa-recipe/src/sync.rs:1600-1634`, blob `a9592d45f03b42a574d29682efe5271ece7cae26` | 055e4c5 | 2026-12-12 |
| A2 | Exactly **one** production call site: `crates/gsa-cli/src/prepare.rs:330` in `sync_one`, passing to `sync::sync_snapshot` at `:331`. Repo-wide grep returns only `sync.rs:1606,2408,2506-2527` and `prepare.rs:330`. | cited | code | `crates/gsa-cli/src/prepare.rs:326-331`, blob `b6d88af20fc32e19701c1582a5eb90adad072ab1` | 055e4c5 | 2026-12-12 |
| A3 | The boundary threads as a plain `&str`: `sync_snapshot(..., boundary: &str)` at `sync.rs:2091/2095` → `snapshot_commit_before` at `:2151` → `git rev-list -1 --before={boundary}` at `:1874`. No context struct. | cited | code | `crates/gsa-recipe/src/sync.rs:2091,2095,2151,1874` | 055e4c5 | 2026-12-12 |
| A4 | **No** context struct carries the boundary: `SyncPolicy` holds only `repo_root`; `PassConfig` holds `skip_mode/tolerance/no_sync/notes/srcdest`. The boundary is **recomputed per recipe** inside `sync_one`. | cited | code | `crates/gsa-recipe/src/sync.rs:4229`; `crates/gsa-cli/src/prepare.rs:124-140,326-330` | 055e4c5 | 2026-12-12 |
| A5 | Read at 4 places: the `--before=` operand (`:1874`), `NoCommitBeforeBoundary{boundary}` (`:1882`), and two report strings (`:2318`, `:2333`). Refusal keyword `no-commit-before-boundary` (`:1681`). The provider label is the **literal** `"Monday snapshot"` (`:2342`). | cited | code | `crates/gsa-recipe/src/sync.rs:1681,1698-1699,1874,1882,2318,2333,2342` | 055e4c5 | 2026-12-12 |
| A6 | `monday_boundary_is_the_most_recent_monday_midnight_utc` **passes**: Thu 2026-11-12 → `2026-11-09T00:00:00Z`; the Monday itself → same; `-1s` → `2026-11-02`; `+7d` → `2026-11-16`; epoch 0 → `1969-12-29`. | verified | experiment | `cargo test -p gsa-recipe --lib monday_boundary` → `test result: ok. 1 passed; 0 failed; 43 filtered out` | 055e4c5 | 2026-12-12 |
| A7 | The fixture derives its own boundary from `date -u` and asserts the rewritten `#commit=` equals the boundary commit, the old pin is gone, `pkgver` came from `pkgver()` at the new pin, and a second pass is no-change. | cited | code | `tests/sync-snapshot.sh:100-109,233,236,243-256,270`, blob `48763bfc29a7e18a8024e7bff0d6917345ccc24c` | 055e4c5 | 2026-12-12 |
| A8 | `-Sy` path: `run_sync_pass` → `run_sync_pass_inner` → `sync_phase` → per-recipe `sync_one`; the snapshot branch gates on NOT under `packages/stable` **and** `snapshot_source()` answering Ok. No targets = every recipe in canonical order. | cited | code | `crates/gsa-cli/src/prepare.rs:1155,1229,1092,1103-1106,280-331` | 055e4c5 | 2026-12-12 |
| A9 | **A plain `-S` also runs the sync pass.** `build.rs:397-401` calls `prepare_all`; `prepare_one` runs `sync_one` at `prepare.rs:851-852`; only `--no-sync` suppresses it, and `-Su` sets `no_sync=true`. `-Syu` syncs twice. | cited | code | `crates/gsa-cli/src/build.rs:396-401,1171-1173,1234-1238`; `crates/gsa-cli/src/prepare.rs:851-852` | 055e4c5 | 2026-12-12 |
| A10 | Neither `monday_boundary` nor `sync_snapshot` is dead or test-only: the fixture drives the whole path and exits 0 with a moved pin. | verified | experiment | `GSA_TEST_GSA_BIN=$PWD/target/release/gsa timeout 300 bash tests/sync-snapshot.sh` → `RC=0` | 055e4c5 | 2026-12-12 |
| A11 | No per-recipe boundary override exists anywhere: no `--before`/`--boundary` flag, no `GSA_*SNAP*` in `ENV_INPUTS`, no snapshot key in `gsa.conf`'s closed 8-key roster, no `boundary` key in `build-defaults.conf`. `_snapshot_ref=` selects the **ref**, not the date. | cited | code | `crates/gsa-model/src/config.rs:308-318`; `crates/gsa-cli/src/help.rs`; `crates/gsa-topo/src/lib.rs:438-443` | 055e4c5 | 2026-12-12 |
| A17 | Because `now` is read **per recipe**, a run straddling Monday 00:00Z could apply two different boundaries in one run. Not executed. | inferred | code | `crates/gsa-cli/src/prepare.rs:326-330`; `prepare.rs:758,1103-1106` | 055e4c5 | 2026-12-12 |

**A9 was confirmed operationally this session, not just read:** two
`gsa -S --leaf` invocations re-advanced the `rust-git` pin to the Monday
boundary before `--no-sync` was passed. That is why the campaign now runs with
`--no-sync`.

### Q4 — cost and the available channel

| id | claim | status | source | handle | version | recheck |
| --- | --- | --- | --- | --- | --- | --- |
| A12 | `Tag` is a **closed** vocabulary (`Tag::from_wire` returns `None`; the loader refuses with the allowed list). A new tag needs variant + `from_wire` + `to_wire` + loader error text + contract roster, but does **not** bump `store_format` by precedent (`toolchain=gcc\|clang` landed 2026-11-10 with `STORE_FORMAT_MAX` still 1). | cited | code | `crates/gsa-model/src/lib.rs:136-198`; `crates/gsa-topo/src/lib.rs:247-255,252,385`; `git log -1 -S STORE_FORMAT_MAX` → `24128da` | 055e4c5 | 2026-12-12 |
| A13 | **The per-recipe channel already read by this pass** is the PKGBUILD variable `_snapshot_ref=`, via `pkgbuild_var(recipe_dir, "_snapshot_ref")` at `sync.rs:1806-1815`. `pkgbuild_var` sources the PKGBUILD under `build_command(bash)`, validates the identifier, and returns any declared scalar with **no allow-list of names**. | cited | code | `crates/gsa-recipe/src/sync.rs:349-366,1806-1815,1727-1729,1828-1836`; recipe use `packages/core/qt6-graphs/PKGBUILD:26` | feb5d0c | 2026-12-12 |
| A14 | A `config/*.conf` costs more: `abi-exclusions.conf` has a strict parser in `gsa-topo`, a `ProjectConfig` field, **and a second independent parse site** (`gsa-install::AbiExclusions::load` by path). A new conf file inherits that duplication risk. | cited | code | `crates/gsa-topo/src/lib.rs:511-585,633-639,701-705`; `crates/gsa-install/src/gates.rs:35-90`; `crates/gsa-install/src/lib.rs:616-627` | 055e4c5 | 2026-12-12 |
| A15 | Cost of a per-recipe boundary: one producer site (`prepare.rs:330`) and one consumer graph; **no signature change** (`sync_one` already has `recipe_dir`; `sync_snapshot` already takes `&str`). A declared **pair** has no existing channel — `abi=must` couples rebuild/install only. | cited | code | `crates/gsa-cli/src/prepare.rs:280-331`; `crates/gsa-recipe/src/sync.rs:2091-2151` | 055e4c5 | 2026-12-12 |
| A16 | Not possible without a grammar change: topology tag, CLI flag (contract §L.1), new `config/*.conf`, `gsa.conf` key. A PKGBUILD-adjacent `_snapshot_*=` variable is the **only** option needing none, though it owes a contract §B.4 amendment. | cited | code | `docs/gsa-contract.md:1728-1736`; `crates/gsa-model/src/config.rs:308-318` | 055e4c5 | 2026-12-12 |
| A18 | Blast radius in the real tree: 213 files carry `#commit=`, 23 carry `_commit=`, 12 carry `_snapshot_ref=`, 46 pinned recipes sit under `packages/stable/`. | verified | experiment | `grep -rl "#commit=" packages/ \| wc -l` → 213; `grep -rl "^_commit=" packages/ \| wc -l` → 23; `grep -rn "_snapshot_ref" packages/ \| wc -l` → 12; `grep -rl "#commit=" packages/stable/ \| wc -l` → 46 | feb5d0c | 2026-12-12 |

### Q2 — what rustc actually requires of llvm, observably

| id | claim | status | source | handle | version | recheck |
| --- | --- | --- | --- | --- | --- | --- |
| B1 | rustc links libLLVM through two surfaces that must match **exactly**: a C++ symbol surface (251 undefined mangled `_ZN4llvm*` plus 305 C-API and 15 `LLVMInitialize`, all `@LLVM_24.0`) and `llvm-wrapper/*.cpp` compiled against the **build-time** LLVM headers. | verified | experiment | `nm -D --undefined-only /usr/lib/librustc_driver-82b1992ba740d17a.so \| grep -c _ZN4llvm` → 251; `\| grep -c 'LLVM[A-Z]'` → 305; `\| grep -c LLVMInitialize` → 15 | rust-git 1:1.101.0.r344576.g4a7cdf-1 + libLLVM 24.0.0_r607209 | 2026-11-19 |
| B2 | The wrapper compiles at rust-build time as C++ against the target LLVM's own headers, so an API rename is a hard compile error. | cited | code | `compiler/rustc_llvm/build.rs:246-250@48dfc3a4`; log `/var/lib/gsa/logs/rust-git.log.1:1978` | rust 48dfc3a4 | 2026-11-19 |
| B3 | Verbatim build failure: `llvm-wrapper/PassWrapper.cpp:374:36: error: 'InitTargetOptionsFromCodeGenFlags' is not a member of 'llvm::codegen'`, then `error: failed to run custom build command for rustc_llvm`. | verified | experiment | `sudo grep -n "is not a member of 'llvm::codegen'" /var/lib/gsa/logs/rust-git.log.1` → `1978`, `2099` | rust pin 48dfc3a4 vs llvm 24.0.0_r607209 | 2026-11-19 |
| B4 | The only **version** gate is a runtime major-equality check, not a range: `if llvm_major != expected_version { fatal(LlvmVersionMismatch) }`, `expected` compiled in from `LLVM_VERSION_MAJOR`. Any 24.x passes. | cited | code | `compiler/rustc_codegen_llvm/src/llvm_util.rs:56-58@48dfc3a4`; `src/diagnostics.rs:268-272@48dfc3a4` | rust 48dfc3a4 | 2026-11-19 |
| B12 | No minimum-LLVM `#error` or `build.rs` gate; the window is only `LLVM_VERSION_GE(23,0)`×12, `GE(24,0)`×12, `LT(24,0)`×3 plus a CI lane `test-x86_64-gnu-llvm-22`. Empirically the pin's wrapper compiles clean against LLVM 23.0 headers. | verified | experiment | `git -C rust grep -ohE 'LLVM_VERSION_(GE\|LT)\([0-9]+, *[0-9]+\)' 48dfc3a4 -- compiler/ \| sort \| uniq -c`; `git archive c47d7823685a llvm/include` + g++ with a synthesized `llvm-config.h` (MAJOR 23) → `errors=0` | rust 48dfc3a4, llvm release/23.x | 2026-11-19 |
| B14 | The recipe already carries upstream's fix verbatim as `0009-compiler-Update-LLVM-24-targetoptions-call.patch`, and it is correct: applies with `Hunk #1 succeeded at 371 (offset -1)`; patched file compiles clean while unpatched fails; patch blob index `53b77729a742..8041ffda9f49` matches `ec4acfa^`/`ec4acfa` exactly. | verified | experiment | `patch -Np1 < .../0009-*.patch` → `succeeded at 371`; `g++ -fsyntax-only …` → `RC=0` | rust 0a2fb9c3 + patch 0009 | 2026-11-19 |

### Q3 — is the weekday cut the wrong default? (the centrepiece)

| id | claim | status | source | handle | version | recheck |
| --- | --- | --- | --- | --- | --- | --- |
| B5 | The break is a **rename** from LLVM PR #239919, `7b6cf9d3de9c` (2026-11-07T18:19Z): `InitTargetOptionsFromCodeGenFlags(const Triple&)` → `getTargetOptions(const cl::LibraryOptionsContext&, const Triple&)`. The commit message says "NFC". | cited | code | `git -C ~/.gsa-src/llvm-project log -1 7b6cf9d3de9c`; `git show 7b6cf9d3de9c -- llvm/include/llvm/CodeGen/CommandFlags.h` | llvm 7b6cf9d3de9c | 2026-11-19 |
| B6 | The rename did **not** move the soname or the symbol-version node: `SOVERSION ${MAJOR}.${MINOR}` and `LLVM_24.0` on both sides; the installed lib is `libLLVM.so.24.0` in both states. | cited | code | `git show 319bd32d:llvm/cmake/modules/AddLLVM.cmake \| grep SOVERSION`; `git show 319bd32d:llvm/CMakeLists.txt \| grep -A2 LLVM_SHLIB_SYMBOL_VERSION`; `ls -l /usr/lib/libLLVM.so.24.0` | llvm 319bd32d / 2d12c0df | 2026-11-19 |
| B7 | The call site at the recipe's rust pin is `PassWrapper.cpp:374`, unguarded; the surrounding `#if LLVM_VERSION_LT(24,0)` guards only `Options.FloatABIType`. | cited | code | `git -C ~/.gsa-src/rust show 48dfc3a4:compiler/rustc_llvm/llvm-wrapper/PassWrapper.cpp \| sed -n '370,380p'` | rust 48dfc3a4 | 2026-11-19 |
| B8 | Nothing else collides: a **declaration-level** diff of every API name removed from `llvm/include/llvm{,‑c}` between `a63bd4e1` and `319bd32d`, intersected with the names the wrapper calls, yields **exactly** `{InitTargetOptionsFromCodeGenFlags}`; three other ranges yield nothing. | verified | experiment | narrowed scan: `git diff <A> <B> -- llvm/include/llvm llvm/include/llvm-c \| grep '^-' \| grep -E 'LLVM_ABI\|LLVM_C_ABI'` ∩ wrapper call names. Fixed-rust control (`b4fe65c1`) returns **empty** over the broken window. | seen: `a63bd4e1..319bd32d` vs rust `b5fc745f` | 2026-11-19 |
| B9 | Upstream rust's fix `ec4acfa0c08e` is **authored** 2026-11-09T10:57+01:00 but reached `main` only via rollup `2caad465a269` at 2026-11-11T12:06+01:00; absent from `main` at boundaries 11-08…11-11, present from 11-12. | cited | code | `git -C ~/.gsa-src/rust log -1 --format='%H %ad %cd' --date=iso-strict ec4acfa0c08e`; `merge-base --is-ancestor ec4acfa0c08e <boundary>` false for `0a2fb9c3`/`b5fc745f`/`8d316013`/`234c935d`, true for `ee8268e2` | rust ec4acfa0c08e | 2026-11-19 |
| B10 | **Boundary verdicts**, each by compiling that boundary's `PassWrapper.cpp` against that boundary's `llvm/include` with `g++ -fsyntax-only`: **11-05 FINE, 11-06 FINE, 11-07 FINE, 11-08 BROKEN, 11-09 BROKEN, 11-10 BROKEN, 11-11 BROKEN, 11-12 FINE**; control 11-02 FINE. Not weekday-driven. | verified | experiment | per row: `git rev-list --before=<T> -1 main` in both mirrors, then `g++ -fsyntax-only -std=c++17 -I<that llvm commit's include> PassWrapper.cpp`; failing rows emit the verbatim not-a-member error | boundaries 11-02…11-12 | 2026-11-19 |
| B11 | The recipe's live pin pair is broken: `llvm-git` pin `2d12c0df` (Monday 11-09 cut) + `rust-git` pin `48dfc3a4` (Monday **11-02** cut) — from **different Mondays** — and `rustc --version` dies on `undefined symbol _ZN4llvm7codegen33InitTargetOptionsFromCodeGenFlagsERKNS_6TripleE, version LLVM_24.0`. | verified | experiment | `rustc --version` (verbatim); `pacman -Q rust-git llvm-git`; PKGBUILD `#commit=` lines | live host 2026-11-12 | 2026-11-19 |
| B13 | A presence matrix over 5 llvm boundaries shows **exactly one** cell flips across the wrapper's prerequisite set: `InitTargetOptionsFromCodeGenFlags` 1,1,1,0,0 at `104238fb`/`24a37c25`/`a63bd4e1`/`319bd32d`/`2d12c0df`. All nine other names stay 1. | cited | code | matrix over `git show <sha>:<path>` for 10 names × 5 boundaries | llvm `104238fb..2d12c0df` | 2026-11-19 |

## The boundary table (the centrepiece)

Both mirrors resolved with `git rev-list --before=<T> -1 main`.

| cut (UTC) | day | llvm sha | rust sha | llvm has old API | rust calls old API | verdict |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-11-02 | Mon | `75f7ac6e3cf9` | `48dfc3a4e0e5` | 1 | 1 | **FINE** (the rust pin today) |
| 2026-11-05 | Thu | `104238fbb1b3` | `a19d427d0da3` | 1 | 1 | **FINE** |
| 2026-11-06 | Fri | `24a37c25603c` | `db777f224bd5` | 1 | 1 | **FINE** |
| 2026-11-07 | Sat | `a63bd4e11dd0` | `940c91f57bf4` | 1 | 1 | **FINE** (rename lands 18:19Z, after the cut) |
| 2026-11-08 | Sun | `319bd32d5276` | `0a2fb9c3416e` | **0** | 1 | **BROKEN** |
| 2026-11-09 | Mon | `2d12c0df533b` | `b5fc745fd7cc` | **0** | 1 | **BROKEN** (llvm pin today) |
| 2026-11-10 | Tue | `78873315ec35` | `8d316013429d` | **0** | 1 | **BROKEN** |
| 2026-11-11 | Wed | `f5f531b52531` | `234c935d00a7` | **0** | 1 | **BROKEN** |
| 2026-11-12 | Thu | `24e0f7a987e9` | `ee8268e23d0e` | 0 | 0 (uses `getTargetOptions`) | **FINE** (first cut after the fix merged) |

The window is `rename 11-07T18:19Z … fix-merge 11-11T11:06Z`. It contains
**three consecutive Mondays** and no Friday. That is the whole of the owner's
observation, and also why it must not be generalised into a weekday rule.

## Q5 — failure modes of a per-recipe cut (and what already guards them)

The agent's own framing: today every snapshot fact is *derived* (the commit from
the recipe's mirror, the version from its `pkgver()`), so a per-recipe cutoff
would be the **first snapshot value the builder cannot re-derive**.

| id | claim | status | source | handle | recheck |
| --- | --- | --- | --- | --- | --- |
| C1 | The only cutoff is a single global boundary; the engine has **no** `cutoff` identifier anywhere (`grep -rn cutoff --include=*.rs crates/` → 0). | verified | experiment | `sync.rs:1606`; the grep above returns 0 | 2026-12-12 |
| C2 | Pin evidence is the recipe's own `SRCDEST/<makepkg name>` bare mirror; no pin is placed from the network. | cited | spec | `docs/gsa-contract.md:220-224`; `sync.rs:2143` | 2026-12-12 |
| C3 | The version is the recipe's own `pkgver()` at the new commit; pin and version move in **one** transaction. | cited | spec | `docs/gsa-contract.md:225-230`; `sync.rs:2178` | 2026-12-12 |
| C4 | Two arms: mirror defect **defers** (`source-unfetchable`, rc 5), recipe defect **refuses** (rc 3). | cited | spec | `docs/gsa-contract.md:235-242`; `sync.rs:2117-2126` | 2026-12-12 |
| C5 | Forward-only: a boundary commit that is not a descendant of the recorded pin is left alone as `Current`, so a pin never rewinds. | cited | spec | `docs/gsa-contract.md:248-250`; `sync.rs:2165-2176` | 2026-12-12 |
| C9 | Consumer expansion and the sort are **cutoff-blind**: no crate outside `gsa-recipe` reads a `#commit=` pin. | verified | experiment | `grep -rn "#commit=" crates/gsa-graph/src crates/gsa-abi/src crates/gsa-sched/src` → no matches | 2026-12-12 |
| C10 | The ABI wave fires only on a **real** token move, derived from the bare-soname provide set — so a pin-only move engages **no** wave. | cited | spec | `docs/gsa-contract.md:848-851`; `crates/gsa-abi/src/token.rs:4-9,94` | 2026-12-12 |
| C11 | `vcs_baseline` is never written: every index row carries `-`. | verified | experiment | `crates/gsa-state/src/index.rs:71,462,552`; only reader `crates/gsa-cli/src/query.rs:938` | 2026-12-12 |
| C12 | Stale detection compares **version keys only**, never a pin. | verified | experiment | `crates/gsa-cli/src/prepare.rs:1268-1339` (`stale_set`, `vercmp`) | 2026-12-12 |
| C14 | The `-Sy` sync phase runs **before** the run lock is taken. | verified | experiment | `build.rs:1173` vs `:291` (`lock::acquire_run_lock`, called `:1248`) | 2026-12-12 |
| C15 | The sync rewrite is volatile store state; a re-run does **not** repair a sticky mixed PKGBUILD/`.SRCINFO`, and success leaves the recipe rewritten and **uncommitted**. | cited | docs | `AGENTS.md:448-455` (rule 63); `docs/gsa-contract.md:196-200`; `sync.rs:2089-2091` | 2026-12-12 |
| C16 | The refusal set is a 7-variant enum with stable keywords; `NoCommitBeforeBoundary` prints the boundary verbatim. | verified | experiment | `sync.rs:1638-1685` | 2026-12-12 |
| C17 | Fixture coverage: move, uncommitted, no-rewind, skew, non-pin, absent mirror, multi-source. **Not** covered: unreadable `_snapshot_ref`, empty `rev-list`, same-sha two-source rewrite. | cited | spec | `docs/gsa-contract.md:252-254`; `tests/sync-snapshot.sh:17-39` | 2026-12-12 |
| C18 | Every QA check declares `scope`+`severity`; `report` is default and `-Ma` is report-only — the **only** seam that can express a cross-recipe fact. | cited | spec | `docs/gsa-contract.md:1041-1045` | 2026-12-12 |
| C21 | `vcs-ref-pinned-mismatch` is the only per-recipe pin-disagreement signal, and it is a **build reason** for the recipe itself, never a consumer-side signal. | verified | experiment | `crates/gsa-recipe/src/freshness.rs:92,613-617` | 2026-12-12 |
| C22 | The ancestry check collapses a spawn error into "not an ancestor" (`unwrap_or(false)`), so an unanswerable probe reads as `Current`. | verified | experiment | `sync.rs:2173-2176` | 2026-12-12 |

### Failure-mode table (the plan's rejection criteria)

| # | mechanism | rule strained | already guarded by | cheapest check | kind |
| --- | --- | --- | --- | --- | --- |
| F1 | Two coupled recipes declare **different** cutoffs. | contract 813-817 (selection expands to consumers); rule 13 | **nothing** — graph carries no pin (C9) | lint walking recorded edges, comparing pair cutoffs, naming both | **report lint** |
| F2 | A provider's pin moves but its sonames do not → no wave → consumers build against old provider bytes silently. | contract 848-851 (real token move only) | `vcs-ref-pinned-mismatch`, but only as the provider's own build reason (C21) | fixture: pinned provider whose new pin changes no provide | **fixture** |
| F3 | A per-recipe cutoff is a value the builder cannot re-derive. | rule 18 (anchored authority); rule 73 (one ladder) | nothing; `gsa.conf` refuses an unknown key (rc 2) | unit test: one rung list with a provenance label | **unit test** |
| F4 | A cutoff that no longer resolves (empty or truncated history). | contract 248-250; rule 71 | empty `rev-list` → `NoCommitBeforeBoundary` → **defer**; absent mirror defers (fixture §3) | fixture: mirror whose commits are all *after* the cutoff → rc 5 and byte-identical recipe | **fixture** |
| F4b | The ancestry probe fails to run and is read as "not a descendant" → a real forward move is silently skipped. | rule 71 | nothing — `unwrap_or(false)` (C22) | unit test with a failing stub; assert **not** `Current` | **unit test** |
| F5 | `_snapshot_ref` unreadable/invalid collapses to `None` → wrong ref family searched. | rule 71 | nothing; no fixture section (C17) | unit test on the read; then a fixture with a malformed value | **unit+fixture** |
| F6 | Two writers on one recipe: the `-Sy` rewrite vs a hand edit; a cutoff in topology/config has no transaction. | rule 63; contract 196-200 | PKGBUILD placement leaves the rewrite **uncommitted**; config placement is refused by the closed roster | fixture: cutoff preserved byte-for-byte through a rewrite | **fixture** |
| F7 | The sync phase runs **before** the run lock, so concurrent runs interleave rewrites. | rule 65 (one writer per tree) | **unguarded at HEAD** (C14) — an amplifier, not introduced debt | fixture with a held lock, or record as pre-existing | **fixture** |
| F8 | Rule-63 loss becomes **asymmetric**: one recipe loses its pin edit while its pair keeps it. | rule 63 | forward-only prevents a rewind, but nothing detects asymmetry | overlaps F1's lint | **report lint** |
| F9 | `rewrite_snapshot_pin` replaces **every** `#commit=<old>`, so two same-sha sources cannot be held apart. | contract 225-230 | nothing (the unit test covers only single-occurrence) | unit test: two-source same-sha PKGBUILD | **unit test** |
| F10 | A cutoff is unauditable: no index row records the pin an archive was built under. | contract 855 (`-` = record-less) | nothing; the placeholder is deliberate and must not grow a writer without a format decision | reader-side report lint (or an additive field, §L.2) | **report lint** |
| F11 | A cutoff that moves the pin **without** moving `pkgver` is invisible to `-Su`. | rule 12 with `stale_set` (C12) | the automatic path writes pin+version together, so only a hand-declared cutoff can diverge | fixture: pin move at constant `pkgver` | **fixture** |
| F12 | Refusal keywords name the boundary, so a per-recipe cutoff changes `no-commit-before-boundary`'s named value **and its routing** (X1). | contract 235-242 | the keyword already carries the failing value; only the routing changes | unit test pinning the classification of a declared cutoff | **unit test** |

Caveat on C7/C8/C13/C19/C20/C23 (also reported by the agent): `rewrite_snapshot_pin`
replaces every occurrence (C7 → F9); `_snapshot_ref` collapses unreadable to
`None` (C8 → F5); `gsa.conf`'s roster is closed (C13); rule 73's ladder applies
(C19 → F3); rule 18's anchoring applies (C20 → F3); and the installed engine
equals HEAD at `055e4c5`, so installed behaviour may be cited as HEAD behaviour
(C23 — verified, `pacman -Q gsa-pm` → `0.1.0+r717+g055e4c564c7a-1`).

## Contradictions (both sides recorded, not averaged)

1. **"NFC" vs. an ABI break.** `7b6cf9d3de9c` is titled `… NFC (#239919)` yet it
   removes an exported `@LLVM_24.0` symbol and is a hard build stop for external
   consumers. Both are true: "NFC" describes LLVM-internal semantics, not the
   exported name set (B5, B6). **The answer rests on B6 + B10**: the name set
   changed while the soname did not.
2. **Author date vs. merge date.** `ec4acfa0c08e` is authored 11-09, which would
   put the 11-10 cut on the fixed side; it reached `main` on 11-11. The 11-10
   and 11-11 rows are BROKEN *by compile*, so the **merge date** is the truth
   (B9, B10).
3. **`AGENTS.md` cadence text vs. the measured pair.** The recipe comment says
   both pins advance on the Monday cadence, and each does — but the two pins are
   from *different Mondays* (11-09 and 11-02). Nothing in the comment says the
   two Mondays differ, which is exactly the unstated assumption that broke
   (B11).
4. **X1 — the defer/refuse split cannot classify a declared cutoff.**
   `docs/gsa-contract.md:235-242` says a defective *recipe* refuses (rc 3) and
   defective *evidence* defers (rc 5), but an empty `rev-list` result
   (`NoCommitBeforeBoundary`) is routed through **defer** (`sync.rs:2145-2155`).
   The code's own comment — that this is a property of the mirror — is true only
   while the boundary is clock-derived; under a declared cutoff the same value is
   an authoring defect. **Unresolved: the design must rule on it.**
5. **X2 — forward-only is the wrong predicate for a pair-hold.** "Not a
   descendant of the recorded pin" is a *silent* `Current` (`sync.rs:2165-2176`),
   and a spawn failure collapses into the same answer (C22). A pair cutoff exists
   to hold one member behind another — exactly that case — so wiring it through
   this check converts an intended hold into an indistinguishable no-op.
6. **X3 — the contract says this surface has no per-recipe opt-in.**
   `docs/gsa-contract.md:759-762`: the snapshot surface "needs no topology
   vocabulary and no per-recipe opt-in". A per-recipe or per-pair cutoff is
   definitionally per-recipe vocabulary, so the change is a **contract
   amendment**, not an implementation detail.

## What was NOT established

- **U1 — whether a semantic (non-name) break could slip through.** The probes
  are `-fsyntax-only`, which sees declarations and inline bodies only. Cheapest
  next probe: compile the wrapper to an object per boundary and diff
  `nm -D --undefined-only` against each boundary's `nm -D --defined-only
  libLLVM.so`.
- **U2 — whether the recipe repository would accept a per-recipe date as
  policy.** Rule 64 mandates one Monday cadence for the toolchain family; it
  does not forbid a per-recipe *date*. Cheapest probe: read
  `gsa-recipe/docs/snapshot-expansion.md` §8 for a stated cadence invariant.
- **U3 — no LLVM-22 compile.** Only 23 and 24 were probed.
- **U4 — the engine's mid-run trigger path** for a broken `rustc` was not read,
  only observed firing.
- **U5 — resolved.** Q5 landed; see the Q5 claims, the failure-mode table and
  contradictions X1–X3. The plan's rejection criteria now rest on it.
- **U6 — whether a shallow mirror yields rc 1 (not-ancestor) or rc 128 (error)**
  from `merge-base --is-ancestor` — decides whether F4b is silent data loss or a
  robustness gap. Probe: `GIT_CONFIG_COUNT=0 git clone --bare --depth 1 <local> m
  && GIT_CONFIG_COUNT=0 git -C m merge-base --is-ancestor <old> <new>; echo $?`.
- **U7 — whether any real recipe pairs two `#commit=` sources at the same sha**,
  which decides whether F9 is theoretical.

## Recheck (run in this order when the pins or the provider move)

```sh
# 1 the spine is unchanged
grep -rn 'fn monday_boundary' crates/gsa-recipe/src/sync.rs
grep -rn 'monday_boundary(' crates/gsa-cli/src/prepare.rs
cargo test -p gsa-recipe --lib monday_boundary

# 2 the pass still fires on a plain -S (A9)
grep -n 'no_sync' crates/gsa-cli/src/build.rs | head

# 3 the channel still exists (A13)
grep -n '_snapshot_ref' crates/gsa-recipe/src/sync.rs | head

# 4 the incident did not recur: current pins and a live rustc
grep -o 'commit=[0-9a-f]*' ~/.local/share/gsa/recipes/packages/core/{llvm-git,rust-git}/PKGBUILD
rustc --version

# 5 re-run the boundary probe for the next candidate cut
B=<YYYY-MM-DD>T00:00:00Z
L=$(git -C ~/.gsa-src/llvm-project rev-list --before=$B -1 main)
R=$(git -C ~/.gsa-src/rust rev-list --before=$B -1 main)
echo "llvm=$L rust=$R"
```

Gate output at time of writing: **A6 → 1 passed; A10 → RC=0; B3 → lines 1978,
2099; B10 → the table above; B11 → the verbatim symbol error.**
