# Decision records

The architecture decisions that outlive a single change, one file each, named
`NNNN-<slug>.md` and written as: context → decision → consequences. An ADR is
the place for the *why* behind a rule that a reader will otherwise have to
reverse-engineer from the code; the interfaces themselves are normative in
[`../gsa-contract.md`](../gsa-contract.md) and the contract wins on any
disagreement (contract §L.7).

| Record | Decided |
| --- | --- |
| [`0003-run-record.md`](0003-run-record.md) | One run record, three renderings, machine block default-on |
| [`0004-prefetch-advisory.md`](0004-prefetch-advisory.md) | Fetch-ahead is advisory; makepkg stays the build-time gate |
| [`0005-engine-owned-makepkg-conf.md`](0005-engine-owned-makepkg-conf.md) | The engine owns the makepkg configuration, its per-compiler bodies and the identity digest |
| [`0006-packaged-seams-owe-a-shipped-file.md`](0006-packaged-seams-owe-a-shipped-file.md) | A text seam is half a feature: the packaging asserts the shipped file equals the engine's output |

**Numbering starts at 0003 in this repository.** `0001-pgo-shared-gate.md` and
`0002-topology-one-record.md` were written before the 2026-11-09 split, when
one repository carried both halves; both are recipe-side decisions and moved
to [`ZhangDM-520/gsa-recipe`](https://github.com/ZhangDM-520/gsa-recipe) with
that half. The numbers are not reused here — a citation of 0001/0002 means the
recipe repository's record, and a new engine record takes the next free
number.
