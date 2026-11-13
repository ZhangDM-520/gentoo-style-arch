# Plan — host-critical ABI swaps (2026-11-12)

Follow-up to the 2026-11-12 full-rebuild campaign. Engine repository only; the
recipe half is one config file and one fixture.

Research record (facts, handles, recheck log):
`2026-11-12-host-critical-abi-research.md` (same directory).

## Problem

The full rebuild refuses at `openssl`. The refusal is **correct**: `openssl`
3.6.5 → 4.1.0 moves `libcrypto.so.3` → `.so.4` and ships no compat name, so 34
installed packages that link `.so.3` would break. Two of them are load-bearing:
`sudo` and `cryptsetup` (LUKS). None of the 34 is a workspace recipe, so the
campaign can never rebuild them.

The engine already refuses — but the operator cannot tell this refusal from an
inert one: it is one `abi-soname` line among many, it does not name `sudo`, and
it does not say the resolution belongs to a distro transaction rather than to
this run. The gap is therefore **classification and remedy**, not detection.

## Scope

In: distinguishing a host-critical stranded consumer from an inert one; naming
the remedy; making the danger visible at plan time.

Out: implementing the heal batch (rule 69's unbuilt gap, contract §M); performing
the openssl swap; any change to `config/abi-exclusions.conf` semantics.

## Global constraints (verbatim, from the contract and AGENTS.md)

- Rule 20: one install decision, one seam — `gsa-install::decide` computes rows
  once; rendering and execution never re-decide. A second decision site or a
  second counter is the change to reject in review.
- Rule 71: an unreadable file is not an absent one. Use
  `gsa_model::read::{required,optional}`; refuse on `Broken`.
- Rule 74: one renderer owns the exit code; steps return typed `Exit`.
- §L.1: a new flag lands in three places in one change (`gsa --help`, the
  continuation flag-rule table, a fixture). **No new flag is introduced here.**
- §L.2: a row/record grammar change bumps `format` and updates the parser
  fixture in the same change. The new refusal row is a new **reason value**, not
  a new decision or shape — verify that against §H.2 before implementing, and
  bump only if the parser actually rejects it.
- `tests/abi-exclusions.conf`'s registry is for names that can *never* resolve.
  A resolvable name (like `libcrypto.so.3`) must never enter it.

## Agreed seams (tests live at these; confirm before `tdd`)

| Seam | Shape |
| --- | --- |
| `gsa_abi::abi_refusal_rows` | existing signature; the new class is computed inside it |
| roster loader | `gsa_topo::parse_host_critical(content, file) -> Result<Vec<HostCriticalEntry>, TopologyError>`, mirroring `parse_abi_exclusions` |
| plan-time census | a read-only function returning rows; no pacman call |

## Task 1 — the roster and its loader

**Why a task**: everything else needs a roster to consult. Independently
testable at the parser boundary.

Files:

- `crates/gsa-recipe`/`config` boundary is the recipe repository — this task
  only defines the *engine-side* type and loader. New file
  `crates/gsa-topo/src/host_critical.rs`:
  - `pub struct HostCriticalEntry { pub name: String, pub why: String, pub line: usize }`
  - `pub fn parse_host_critical(content: &str, file: &str) -> Result<Vec<HostCriticalEntry>, TopologyError>`
    — strict: one entry per line, `name|why`, `#` comments and blank lines
    skipped, duplicate name refused, invalid chars refused, malformed line
    refused with `file:line` (the `parse_abi_exclusions` error shape verbatim).
- `crates/gsa-topo/src/lib.rs`: `pub use host_critical::{parse_host_critical, HostCriticalEntry};`
- `crates/gsa-model/src/config.rs`: `pub const BUILTIN_HOST_CRITICAL: &str` — the
  fallback body when no file is present. Initial contents exactly:
  `sudo`, `cryptsetup`, `glibc`, `systemd`, `pam`, `util-linux`, `shadow`,
  `pacman`, `gcc-libs`, `bash`, `e2fsprogs`, `util-linux-libs`. Each with a
  one-line `why`.

Steps:

1. Write `crates/gsa-topo/src/host_critical.rs` with the struct and loader
   signature above, body unimplemented (`unimplemented!()`).
2. Write the failing tests in the same file's `mod tests`:
   - `host_critical_parses_name_and_why` — input
     `"sudo|every escalation\n"` → one entry, `name == "sudo"`, `why == "every escalation"`.
   - `host_critical_refuses_a_malformed_line` — `"sudo\n"` → `Err`, message
     contains `expected 'name|why'` and `:1`.
   - `host_critical_refuses_a_duplicate` — `"sudo|a\nsudo|b\n"` → `Err` naming `sudo`.
   - `host_critical_skips_comments_and_blanks` — `"# c\n\nsudo|a\n"` → one entry, `line == 3`.
3. Run `cargo test -p gsa-topo host_critical` and watch all four fail.
4. Implement the loader to pass them. Do not add behaviour beyond the four tests.
5. `cargo test -p gsa-topo` green.

**Stopping criterion**: `cargo test -p gsa-topo host_critical` reports 4 passed,
and `parse_abi_exclusions`'s tests are still green (no shared-code regression).

## Task 2 — resolve the roster through the ladder

**Why a task**: the roster must come from the same two-rung shape as every
other setting (file, then built-in), and that is separately testable.

Files:

- `crates/gsa-model/src/config.rs`: `pub fn resolve_host_critical() -> (Vec<HostCriticalEntry>, &'static str)`
  modelled on `resolve_srcdest_with_source` — `config/host-critical.conf` when
  present and readable, else `BUILTIN_HOST_CRITICAL`; the second element names
  the rung (`"config/host-critical.conf"` / `"the built-in default"`).
- Unreadable file → `Err`-carrying variant, never an empty roster (rule 71).

Steps:

1. Test `host_critical_falls_back_to_the_builtin_body` — no file → roster
   contains `sudo` and `cryptsetup`, source `"the built-in default"`.
2. Test `host_critical_reads_the_config_file_when_present` — a temp dir with
   `config/host-critical.conf` containing `mypkg|why` → roster is exactly that
   entry, source `"config/host-critical.conf"`.
3. Test `host_critical_does_not_collapse_an_unreadable_file` — a `config/`
   directory where the file should be (ENOTDIR) → `Err`, not the built-in body.
4. Watch 1–3 fail; implement; `cargo test -p gsa-model host_critical` green.

**Stopping criterion**: `cargo test -p gsa-model host_critical` reports 3 passed;
the ENOTDIR test fails if the implementation uses `unwrap_or_default` (falsify
by making it do so, once).

## Task 3 — the `abi-host-critical` refusal class

**Why a task**: this is the deliverable. The fixture is `tests/abi-drift-install.sh`.

Files:

- `crates/gsa-abi/src/rows.rs`: in `abi_refusal_rows`, add a
  `host_critical: &BTreeSet<String>` parameter and a class computed from the
  EXISTING `uncovered` list:
  - `let critical: Vec<&String> = uncovered.iter().filter(|c| host_critical.contains(*c)).collect();`
  - emit `DecisionRow { decision: Refuse, reason: format!("abi-host-critical {archive} {consumer}") }`
    for each, **in addition to** the existing `abi-soname` row (the soname row
    is the evidence; the critical row is the consequence).
  - `critical` names are removed from the plain `abi-consumer` rows so one
    consumer is never double-reported under two classes.
- `crates/gsa-abi/src/lib.rs`: re-export nothing new; the class rides
  `abi_refusal_rows`.
- `crates/gsa-cli/src/install.rs` and `crates/gsa-cli/src/build.rs` (three call
  sites): thread `&host_critical` from `config::resolve_host_critical()`.
- `crates/gsa-install/src/lib.rs` (the `decide` call site): add the parameter to
  the context and pass it through — no new decision, the set is an input.

Steps:

1. Add the parameter and the class; do not implement the removal from
   `abi-consumer` yet.
2. Extend `tests/abi-drift-install.sh` with a section: a synthetic installed
   package `sudo` linking a moving soname, `sudo` present in the roster, an
   archive moving that provide → plan rows contain
   `refuse abi-host-critical <archive> sudo`; the same fixture with `sudo`
   ABSENT from the roster → `refuse abi-soname …` and no critical row.
3. Run `bash tests/abi-drift-install.sh` and watch the new section fail.
4. Implement to green. Then add the de-duplication (a critical consumer is not
   also reported as plain `abi-consumer`) and pin it in the same section.
5. Re-run `cargo test -p gsa-abi` and `bash tests/abi-drift-install.sh`.

**Stopping criterion**: `bash tests/abi-drift-install.sh` green, with a section
whose assertion is `vgrep 'refuse abi-host-critical' …` and a paired negative
case proving the class is roster-driven, not name-driven.

## Task 4 — name the remedy in the note lines

**Why a task**: a refusal that does not say what to do is half a finding.

Files:

- `crates/gsa-cli/src/install.rs`: when the plan carries `abi-host-critical`,
  the note lines name each critical package, its consequence (from the roster's
  `why`), and the remedy sentence: `run the distro transaction for <provider>
  (its stock consumers move with it); this run cannot rebuild them`.
- No new rendering seam: the notes go through the existing plan-note path.

Steps:

1. Fixture assertion first: the same section of `tests/abi-drift-install.sh`
   asserts `sudo` and its `why` text appear on stderr, and that the string
   `run the distro transaction` appears once.
2. Watch it fail; implement; green.
3. Falsify by blanking the roster's `why` for `sudo` and confirming the note
   degrades to the name only rather than printing an empty clause.

**Stopping criterion**: the fixture asserts the remedy sentence and the roster's
`why` text; both fail if either is removed.

## Task 5 — plan-time census (read-only)

**Why a task**: the danger must be visible before dispatch, and it is the only
proposal that changes what an operator sees before a run.

Files:

- `crates/gsa-cli/src/plan.rs` (or the listing path — confirm which owns
  selection-wide pre-dispatch reporting before implementing): a read-only pass
  that, for each soname move in the selection, lists out-of-tree consumers,
  marking host-critical ones. Emits rows on the plan channel; **runs no pacman**.
- Constraint: must not alter `-Sl` row shape (§B.3's row-only rule). If the
  census cannot fit the existing channel, it becomes `-M`-family output, not a
  new `-S` row — decide at implementation time and record which.

Steps:

1. Test at the seam: given a selection whose provider moves a soname and an
   installed out-of-tree critical consumer, the census returns one row naming
   both; with every consumer in-tree, it returns no row.
2. Watch both fail; implement; green.
3. Fixture: `tests/abi-exposure-audit.sh` gains a section asserting the census
   names `sudo` for a moving `libcrypto.so` and that no `pacman` invocation
   appears in the stub log during the census.

**Stopping criterion**: the fixture section passes and the stub `pacman` log is
empty for that section, proving read-only.

## Task 6 — contract, memory, and the recipe-side file

**Why a task**: boundaries belong to the change that establishes them.

Files:

- `docs/gsa-contract.md` §E.3: `abi-host-critical` added to the `refuse` reason
  list with its consequence sentence.
- `docs/gsa-contract.md` §M: record that P1–P3 landed and that the heal batch
  (rule 69) remains unbuilt — do not claim it is fixed.
- `AGENTS.md` §5 pitfall, one line: a stranded host-critical consumer is its own
  refusal class; the roster is config, never `abi-exclusions.conf`.
- Recipe repo: `config/host-critical.conf` seeded with the same names as
  `BUILTIN_HOST_CRITICAL`, plus one recipe-fixture asserting the shipped file
  parses (the `gsa-pm-shipped-files.sh` precedent for packaging obligations does
  not apply — this is engine-read config, not a shipped artifact).
- `docs/JOURNAL.md`: one dense line; `.logs/action-<date>-host-critical.md`
  export.

Steps:

1. Contract §E.3 + §M edits.
2. `AGENTS.md` pitfall line.
3. Recipe `config/host-critical.conf` + its parse fixture.
4. `tests/memory-layout.sh` green (it gates doc layout).

**Stopping criterion**: `bash tests/memory-layout.sh` green; the contract names
`abi-host-critical` and §M still records the heal batch as unbuilt.

## Final gate (one run, batched)

```sh
cargo build --release --locked
cargo test --workspace -- --test-threads=1
cargo clippy --workspace --all-targets      # no warning in a changed region
tools/fmt.sh
GSA_TEST_GSA_BIN=$PWD/target/release/gsa bash tests/run-all.sh
```

Report each with its result. Known noise, not regressions: the pre-existing
`crates/gsa-maint/tests/history_and_hygiene.rs` rustfmt drift (verified dirty at
HEAD), the two load-flaky supervisor tests under full parallelism, and the
recipe repo's three pre-existing fixture failures (logseq-desktop-recipe,
pgo-transition, vencord).

## Self-review against the research record

| Requirement | Task |
| --- | --- |
| Distinguish host-critical from inert stranded consumers | 1, 2, 3 |
| Name the stranded package and its consequence | 3, 4 |
| Name the remedy (distro transaction) | 4 |
| Surface the danger before dispatch | 5 |
| Never stand the gate down via `abi-exclusions.conf` | global constraint, P5 |
| Keep the heal batch honestly unbuilt | 6 (§M) |

**Step scan**: every step names one command or one file and says what finishing
it looks like. No step says "handle edge cases" or "add validation".

**Interface consistency**: `HostCriticalEntry { name, why, line }` in tasks 1, 2,
3, 4, 6; `parse_host_critical(content, file)` in 1 and 6;
`resolve_host_critical() -> (Vec<HostCriticalEntry>, &'static str)` in 2 and 3.

**Five most likely failure modes, attached to their owning task**:

1. **The roster rots into a duplicate of "everything I care about"** — task 1's
   `why` field is mandatory and task 4 renders it, so an unjustified entry is
   visible in output.
2. **An unreadable roster file silently empties the class** — task 2's ENOTDIR
   test, falsified against `unwrap_or_default`.
3. **A critical consumer double-reported** — task 3's de-duplication assertion.
4. **`-Sl` row shape broken by the census** — task 5's explicit constraint to
   use `-M`-family output if it does not fit.
5. **The gate weakened instead of classified** — the global constraint against
   `abi-exclusions.conf`, plus task 3's negative case (roster absent → the old
   `abi-soname` still refuses).

**Proportion**: six tasks, no code bodies beyond signatures and test names.

## Not in this plan

The openssl swap itself. Owner decision required: `sudo pacman -Syu` in a safe
window (core carries 4.1.0, so the transaction moves provider and stock
consumers atomically), or a later campaign phase implementing rule 69's heal
batch.
