# scratchpad — review fix phase

Last action: **I1-ivy-3 fixed** — `-Sy` now emits the `format: 2` run record
from the same typed per-recipe verdicts that drive its rc, so a deferral-only
pass leaves a record and an `-Mh` history row instead of nothing; the summary
counts deferrals rather than saying "nothing to do".

Unpushed: R2-juno-4, I1-sol-4, R2-juno-3, I1-ivy-3 (the commit this action
writes).

Ledger `fixed`: I1-ivy-1, I1-sol-1, I1-sol-4, I1-ren-1, I1-ren-2, I1-ren-4,
I1-ren-5, I1-ren-6, I1-ivy-2, R2-juno-4, R2-juno-3, I1-ivy-3.

Environment note: the owner's interactive `makepkg -sif` (PID 2574812) holds
the REAL `/var/lib/pacman/db.lck`; the only red in the suite is
`gsa-maint --test pruning_safety` (2 tests) and 5 battery fixtures, each naming
that lock. Re-run between builds before claiming a clean suite.
