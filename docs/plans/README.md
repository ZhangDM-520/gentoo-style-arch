# Design plans — archive-class design records

Four design records that `crates/` and `docs/gsa-contract.md` cite **by
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

Rules for these files:

- **Cite them by path and section.** A code comment or contract paragraph names
  `docs/plans/<file> §<section>`; a bare filename no longer resolves, because
  the records are not in the repository root.
- **They are frozen.** A decision that changes behaviour lands in the contract
  (and, if it needs the why, a new ADR in `../adr/`) — not as an edit to a plan.
  Each record's header is the only mutable part: it carries the archive note,
  the `pre-split-2026-11` tag that holds the pre-retirement text, and the
  location.
- **Do not delete one to "clean up".** The deletion test: removing a record
  would leave ~100 citations pointing at nothing and move the design rationale
  nowhere, so it earns its place in the tree.

`tests/memory-layout.sh` gates the layout: the memory files must exist, the
retired docs must stay retired, and a live citation of a retired path fails the
battery. These records are excluded from that citation scan on purpose — their
`docs/MEMORY.md` / `docs/NOTE.md` mentions are dated provenance, annotated in
their own headers.
