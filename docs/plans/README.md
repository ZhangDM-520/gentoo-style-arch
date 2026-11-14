# Design plans — archive-class design records

Design records that `crates/` and `docs/gsa-contract.md` cite **by
section** (for example `docs/plans/plan-native-pm.md` §4.3). They are
provenance, not specification: the authoritative interface is
[`../gsa-contract.md`](../gsa-contract.md), the operating docs are
[`../build-guide.md`](../build-guide.md) and
[`../architecture.md`](../architecture.md), and the project memory is
`AGENTS.md` plus [`../JOURNAL.md`](../JOURNAL.md).

| Record | What it designed |
| --- | --- |
| `plan.md` | Fetch-ahead while compiling — the prefetch window, flaky-host advisory, run-record inputs |
| `plan-native-pm.md` | The native, Portage-class package manager: state layout, install decision seam, ABI view |
| `plan-gsa-isolation.md` | pacman-class isolation: directories, privilege split, the standalone/distribution unit, the canonical recipe store |
| `plan-gentoo-qol.md` | Build-QoL mechanisms carried over from Gentoo (march/mtune policy, PGO discipline, trimming) |
| `2026-11-12-host-critical-abi.md` | Host-critical ABI swaps: classifying a stranded install consumer apart from an inert one, and naming the remedy (companion facts: `2026-11-12-host-critical-abi-research.md`) |
| `2026-11-12-per-recipe-snapshot-boundary.md` | **QUEUED enhancement.** A per-recipe snapshot cutoff checked as a provider/consumer *relationship* instead of one global Monday instant; companion evidence and the measured boundary table in `2026-11-12-per-recipe-snapshot-boundary-research.md` |
| `2026-11-13-consumer-expansion-install-aware-research.md` | Whether consumer auto-expansion should skip roster packages that are installed nowhere: `linked_consumers` iterates the installed view only, so the ABI guarantee is vacuous for an absent package — but both such recipes today are terminal leaves, so a shipped filter must be consumer-aware and must run *after* the ABI wave |

Rules for these files:

- **Cite them by path and section.** A code comment or contract paragraph names
  `docs/plans/<file> §<section>`; a bare filename no longer resolves, because
  the records are not in the repository root.
- **They are frozen.** A decision that changes behaviour lands in the contract
  (and, if it needs the why, a new ADR in `../adr/`) — not as an edit to a plan.
  Each record's header is the only mutable part: it carries the archive note,
  the `pre-split-2026-11` tag that holds the pre-retirement text, and the
  location.
- **Do not delete one to "clean up".** Measured 2026-11-14 over the tracked
  tree, the four records carry **148 citation lines** — 46/47/25/30 for
  `plan.md`, `plan-native-pm.md`, `plan-gsa-isolation.md` and
  `plan-gentoo-qol.md` — of which **75** come from `crates/` and many name a
  section designator for that record (`§N`, or a `W#`/`M#` work item), so a
  deletion breaks compilation comments and contract paragraphs rather than
  moving the rationale somewhere. Every cited anchor currently resolves; none
  dangles. Re-measure rather than trust the number (each record's own body and
  this index are excluded; sibling cross-citations are counted):

  ```sh
  for p in plan plan-native-pm plan-gsa-isolation plan-gentoo-qol; do
      git grep -In -E "(^|[^A-Za-z0-9_-])(docs/plans/)?$p\.md" \
          -- '*.rs' '*.sh' '*.md' ":!docs/plans/$p.md" ':!docs/plans/README.md'
  done | wc -l                                  # 148; pipe to `grep -c '^crates/'` for 75
  ```

`tests/memory-layout.sh` gates the layout: the memory files must exist, the
retired docs must stay retired, and a live citation of a retired path fails the
battery. These records are excluded from that citation scan on purpose — their
`docs/MEMORY.md` / `docs/NOTE.md` mentions are dated provenance, annotated in
their own headers.
