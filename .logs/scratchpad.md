# scratchpad — review fix phase

Last action: **R2-vera-11 fixed** — `gsa_model::RECORD_FORMAT` is the one
literal; `gsa_state::runs::StoredFormat` marks every stored row and fails
closed on a grammar this build does not render, so the list names it and
`--show`/`--prune` refuse (rule 71); an absent marker reads as the current
grammar (§M gap 4). Contract §H.1 + ADR 0003 amended.

Unpushed: R2-juno-4, I1-sol-4, R2-juno-3, I1-ivy-3, R2-juno-5, R2-juno-6,
R2-vera-11.

Ledger `fixed`: I1-ivy-1, I1-sol-1, I1-sol-4, I1-ren-1, I1-ren-2, I1-ren-4,
I1-ren-5, I1-ren-6, I1-ivy-2, R2-juno-4, R2-juno-3, I1-ivy-3, R2-juno-5,
R2-juno-6, R2-vera-11.

Next: the remaining round-2 majors — R2-maya-2/3/7, R2-vera-1/3/8.
