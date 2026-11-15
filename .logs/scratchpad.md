# scratchpad — review fix phase, batch closed; next row awaiting the owner

Last action: **R2-vera-8 fixed** (`cb96d0b`) — a held run lock names its holder
(fd-inode scan, then the recorded pid), states whether a live `gsa` holds it,
and prints the exact `rm` for a stale one; `-Md` carries a `run-lock:<path>`
row and `--stale-lock-check` reports both locks.

Owner decisions recorded this session:
- The stale-lock seam is NOT advertised in `--help`. §D.1 hides the seam set
  and three tests pin it (help_and_bare_invocation, tests/completion.sh §6,
  the gsa-sched-v2.sh header); `-Md` is the documented home. Leave §D.1 alone.
- The batch stops here. The next row is the owner's pick, to be discussed.

## OPEN ITEM (the owner will open the discussion)

21 rows remain in `su_issues`. Recommended order, by seam shared:

1. **The `-Ua` planning cluster** — `R2-theo-2` (`reproduced`) + `R2-vera-9`
   (`reproduced`): both plan `install ok` for an archive that should not land
   (an older-than-installed one; one the doctor calls orphan/no-index-row,
   including an older `gsa-pm`). Both are `-Ua` plan construction, so one seam
   likely answers both. Highest value: `-Ua` is the one-transaction hatch and
   its plan currently cannot be trusted.
2. **The `-U` aftermath pair** — `I1-kaz-1` (`retested-live`, a failed `-U`
   points at a log without the failure and never names the dependency) +
   `R2-theo-1` (duplicate of it) — the failure-reporting seam.
3. `I1-ivy-4` (`retested-live`, `--dry-run` says `planned`/rc 0 where the real
   run refuses rc 3) — plan/real divergence, and `I1-kaz-4` is its duplicate.
4. The minor `-Q`/`-M` tooling rows: `R2-maya-6`, `R2-vera-4`, `R2-vera-5`,
   `R2-vera-6`, `R2-theo-3`, `R2-vera-10`, `I1-kaz-5`.

Already ruled, do not reopen: `I1-sol-5` (`!check` is deliberate) and
`I1-ren-8` (IgnorePkg at acceptance is deliberate) — both `status='decision'`.

Ledger `fixed`: I1-ivy-1, I1-sol-1, I1-sol-4, I1-ren-1, I1-ren-2, I1-ren-4,
I1-ren-5, I1-ren-6, I1-ivy-2, R2-juno-4, R2-juno-3, I1-ivy-3, R2-juno-5,
R2-juno-6, R2-vera-11, R2-vera-3, R2-maya-2, R2-maya-3, R2-maya-7, R2-vera-1,
R2-vera-8.
