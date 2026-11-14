# scratchpad — review fix phase

Last action: **I1-ren-1 fixed** (announced expansion now describes the rows the
selection carries, not the pre-range closure; §C.3 amendment; `tests/dashboard.sh`
§P8 red-first both ways; also repaired the stale `tests/gsa-maint-v2.sh` §g pin
that still expected a read-only `-Mh` to create the state root).

Unpushed: `8ebc1f6` (I1-ivy-2) + the I1-ren-1 commit.

Ledger: `fixed` = I1-ivy-1, I1-sol-1, I1-ren-4, I1-ren-5, I1-ren-6, I1-ivy-2,
I1-ren-1. Remaining `reproduced` (11): I1-ivy-3, I1-ivy-4, I1-ivy-5, I1-kaz-1,
I1-kaz-5, I1-kaz-6, I1-ren-2, I1-ren-8, I1-sol-3, I1-sol-4; decision I1-sol-5.

Next: I1-ren-2 (`-Sw` refuses documented build-run modifiers — a DOC row).
