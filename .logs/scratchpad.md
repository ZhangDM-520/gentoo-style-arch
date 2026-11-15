# scratchpad — review fix phase

Last action: **R2-maya-3 fixed** — a `--dry-run` plan names the sonames a
moved library provider ships TODAY and the gate that decides
(`prepare::stale_set`'s one comparison + the install gate's own soname
predicates); `tests/abi-drift-install.sh` §R falsified red.

Ledger `fixed`: I1-ivy-1, I1-sol-1, I1-sol-4, I1-ren-1, I1-ren-2, I1-ren-4,
I1-ren-5, I1-ren-6, I1-ivy-2, R2-juno-4, R2-juno-3, I1-ivy-3, R2-juno-5,
R2-juno-6, R2-vera-11, R2-vera-3, R2-maya-2, R2-maya-3.

Next: the remaining round-2 majors — R2-maya-7, R2-vera-1, R2-vera-8.
