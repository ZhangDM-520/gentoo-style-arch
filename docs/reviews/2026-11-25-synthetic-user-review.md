# Synthetic user review — round 1 (2026-11-25)

One round, six personas: five outside users and one source-aware auditor, on
one disposable Arch machine each. The question is not "does it work" but
"what does a competent stranger hit first".

- **Pinned engine**: `90f9a8b493579af92e2a48f16194158bcc83d364`
- **Pinned recipes**: `0fa56f745c0f3bc969187c6d845457d7ce7ae742`
- **Payload**: `gsa-pm 0.1.0+r778+g90f9a8b49357-1` and the recipe snapshot,
  both hashed in the run's `MANIFEST.txt`. The package was built with the
  recipe's own PKGBUILD against a local `file://` clone of the pin (a reported
  deviation from the GitHub float).
- **Machines**: Arch 7.3.5, 2 vCPU / 2 GB, `base-devel` + `git` + `gsa-pm`,
  the recipe snapshot in `~/payload`. Each persona got a fresh overlay and 40
  minutes.
- **Baseline**: `cargo test --workspace -- --test-threads=1` PASS;
  `GSA_TEST_GSA_BIN=target/release/gsa bash tests/run-all.sh` PASS (60
  fixtures). `GSA_TEST_GSA_BIN` is the documented pre-install deviation.

Personas: mira (first hour), tomas (build + install + record), priya
(inventory and selection), ken (unhappy paths), ana (fetch and sources), sasha
(source-aware audit).

## Metrics

Computed from the issue ledger, not narrated:

| track | rows | bugs | docs | enhancements | decisions | digest |
| --- | --- | --- | --- | --- | --- | --- |
| outside | 24 | 15 | 4 | 5 | 3 | 3 |
| audit | 5 | 4 | 1 | 0 | 1 | 0 |

Every row carries a CLI reproduction in its evidence file. Fixes were verified
against the **installed** payload in a spare machine, not a `*_TEST_BIN`.

## The one root cause worth a paragraph

`-Sl` and `--dry-run` walked *through* installed, current prerequisites. A
single edge to an installed `systemd` planned its entire uninstalled dependency
cone: `gsa -Sl udftools` said 55 "missing build-order prerequisites" and
`--dry-run` planned 56 packages for a one-edge, one-package selection. The
contract is explicit: an installed prerequisite is never added, never rebuilt,
and its own prerequisites are not installed on the strength of the expansion
(§C.3). The walk now stops at the installed boundary.

This was the highest-impact defect in the round: it inflated every plan, made
`-Sl` disagree with the plan by 79 % on `@git`, and put 132 packages in both
"Also fetches/builds on a run" and "Not expanded on a run".

## Fixed (worktree; verified on the installed payload)

| # | Defect | Verification |
| --- | --- | --- |
| I1-priya-1 | Prerequisite closure descended through installed recipes | `gsa -S --dry-run udftools` → `packages=1` (was 56); new case `i` in `tests/project.sh` |
| I1-ken-1 | The shipped PreTransaction hook aborted ordinary `pacman -S` on optdep-only binaries | `pacman -S hwloc` → rc 0, `hwloc: clean` (was `AbortOnFail` on cairo/X11); `tests/abi-need-check.sh` green, explicit scans stay strict |
| I1-tomas-1 | Every first build died in `cannot find 'ld'` because the config's `-fuse-ld=mold` was never probed | `gsa -B --leaf brightnessctl` → rc 3 naming `mold` and `pacman -S mold`; new section E in `tests/host-prerequisite.sh` |
| I1-mira-7 | `--vcs-skip-tolerance` accepted `0`, `-1`, `1.5`, `abc` | rc 2 `must be a positive integer`; unit test in `args.rs` |
| I1-sasha-2 | `--complete` answered nothing for the `-Qp`/`-Qo` path positions | `gsa --complete -Qp /et` → `#mode files`; unit test in `complete.rs` |

Fixtures that already owned the surface were extended; each fix was falsified
by removing its guard and watching the targeted check fail.

## Decisions (intended, not defects)

- **I1-tomas-2** — `-Sc` in `not-mirrored` is the argv-scoped spelling §H.2
  says the record must list when the composed command does not restate it.
- **I1-tomas-5** — plain `-S` installs what it just built; `-U` owns the
  already-current check. `-Sf`'s wording is the only thing that reads oddly.
- **I1-mira-3** — `-Sl` keeps the selection as given and names additions in a
  footer (§C.3). The header count understating the run is a UX digest item.
- **I1-sasha-1** — `-Qs` diverges from "pacman `-Qs` semantics": it is literal
  substring OR, not POSIX-ERE AND. Fixing it means a regex engine (the
  workspace has no external dependencies by design) or an amendment to §B.3.
  Owner decision, recorded here rather than smuggled into a patch.

## Open, highest first

- **I1-sasha-5** — `-Ua` installs an archive the binpkg index does not know,
  while `-Qp` calls the same file `unindexed`. The index-complete gate does
  not gate.
- **I1-ana-1** — `-Sw` skips every VCS-only recipe and records it `succeeded`.
- **I1-ana-2** — a standalone PKGBUILD fetch is a silent no-op success.
- **I1-ana-5** — a killed fetch orphans `makepkg`/`git clone`.
- **I1-ana-3** — SIGTERM to a fetch exits 143 with no run record.
- **I1-mira-1** — `--machine` changes no rendering; captured stdout still
  prints the prose plan, against §D.2/§H.
- **I1-mira-6** — a standalone PKGBUILD takes its id from the directory
  basename, so `~/bash/PKGBUILD` records the house `bash` recipe.
- **I1-mira-2** — a range listing reports the parent selection's skipped
  consumers.
- **I1-priya-2** — `-Qi` repeats `.SRCINFO` fields listed in both `pkgbase`
  and `pkgname`.
- **I1-priya-3** — `-Qp` on an unindexed archive exits 1, the fail-fast build
  class.
- **I1-sasha-3** — one corrupt-store refusal answers rc 2 on readers and rc 3
  on `-Mh --prune`.

## Digest (enhancements, no fix this round)

I1-tomas-3 (failure log rotated away while the record still points at it);
I1-priya-5 (`-Ms` invents empty sets, `-Mw` ignores a positional);
I1-ana-4 (continuation after `sig-key-unknown` repeats the fetch);
I1-mira-3/5 footer wording.

## Documentation

I1-tomas-4 (`-B`'s help line says dependencies must already be installed while
§C.3 makes `-B` expand missing prerequisites), I1-mira-4 (`gsa.conf` promises
provenance labels neither `-Q` nor `--help` shows), I1-priya-4 (`Version`
means two different things), I1-priya-6 (`-Ms` and `-Qu` disagree on "stale"),
I1-sasha-4 (the documented `-Ms --add <ref>` spelling needs the set name
first).

## Deviations and limitations

- **One round only**, by owner instruction. There was no blind retest round:
  the five fixes were verified by the reviewer on the installed payload, not
  by a persona who had not been told what changed.
- **Personas ran as subagents** in the session that owns the repository, so
  they inherited its project instructions. Their cards forbade reading the
  host tree and their run directories were outside it; a leak scan of all
  outside-track artifacts found **zero** occurrences of the repository path,
  `AGENTS.md`, the journal, or the warehouse name. Context contamination
  cannot be grepped from files and is recorded as a limitation.
- **Real-recipe-tree battery sections** (`GSA_RECIPE_CHECKOUT`) report three
  pre-existing recipe-checkout drifts, unrelated to this round: two
  `deprecated/` recipe dirs absent from the topology, two stale `.SRCINFO`
  files, and one topology group assertion. The same fixtures pass without the
  checkout; 57/60 pass with it.
- `gsa -Ma` is report-only and reported 60 findings on the disposable machine
  (partial state, no builds); read as expected, not as a regression.
