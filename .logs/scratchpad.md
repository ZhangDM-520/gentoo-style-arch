# scratchpad — review fix phase

Last action: **R2-vera-1 fixed** — `-Mi`'s report and `--backfill` share one
`WantedSplit` partition, the header counts the closure it introduces
(`entries=N in-use=N stale=N; <census> consulted for classification`), and one
`ignorepkg drift missing=N addable=N unbuilt=N` row reconciles with the
repair's plan (falsified RED three ways).

Ledger `fixed`: I1-ivy-1, I1-sol-1, I1-sol-4, I1-ren-1, I1-ren-2, I1-ren-4,
I1-ren-5, I1-ren-6, I1-ivy-2, R2-juno-4, R2-juno-3, I1-ivy-3, R2-juno-5,
R2-juno-6, R2-vera-11, R2-vera-3, R2-maya-2, R2-maya-3, R2-maya-7, R2-vera-1.

Next: R2-vera-8 — a held run lock refuses with no holder identity and no
remedy.
