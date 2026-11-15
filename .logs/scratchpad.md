# scratchpad — review fix phase

Last action: **R2-maya-2 fixed** — a build that never started
(missing `fakeroot`) now refuses pre-dispatch naming the tool
(`never-started host-prerequisite-missing`, rc 3) and a lane that still reaches
makepkg's own gate carries `host-prerequisite-missing` (rc 15) /
`dependency-install-failed` (rc 8) instead of `build-failed`. Contract §G.1 +
§H.3, build-guide troubleshooting, fixture `tests/host-prerequisite.sh`,
red-first both halves.

Ledger `fixed`: I1-ivy-1, I1-sol-1, I1-sol-4, I1-ren-1, I1-ren-2, I1-ren-4,
I1-ren-5, I1-ren-6, I1-ivy-2, R2-juno-4, R2-juno-3, I1-ivy-3, R2-juno-5,
R2-juno-6, R2-vera-11, R2-vera-3, R2-maya-2.

Next: the remaining round-2 majors — R2-maya-3, R2-maya-7, R2-vera-1,
R2-vera-8.
