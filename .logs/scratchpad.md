# scratchpad — review fix phase

Last action: **R2-juno-6 fixed** — the disk floor is one decision in
`gsa-fetch::engine` read by the plan row (`skip disk-floor`), the outcome row
(`deferred`, never `succeeded`) and the tally (`deferred=N`, absent when
zero); a paused fetch run is a deferral (rc 5) and stays in `remaining:`.

Unpushed: R2-juno-4, I1-sol-4, R2-juno-3, I1-ivy-3, R2-juno-5, R2-juno-6.

Ledger `fixed`: I1-ivy-1, I1-sol-1, I1-sol-4, I1-ren-1, I1-ren-2, I1-ren-4,
I1-ren-5, I1-ren-6, I1-ivy-2, R2-juno-4, R2-juno-3, I1-ivy-3, R2-juno-5,
R2-juno-6.

Next: the remaining round-2 majors — R2-maya-2/3/7, R2-vera-1/3/8/11.
