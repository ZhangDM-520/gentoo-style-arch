# scratchpad — review fix phase

Last action: **R2-juno-4 fixed** (the last commit before this one, unpushed) — fetch attribution is
stage-aware; a signature failure never quarantines a checksum-clean payload,
trust failures are not retried, and the refusal names the class, the key and
the repair. Blocker closed, verified end-to-end on the real rsync recipe in the
r2-juno guest.

Unpushed: R2-juno-4 (`fix(fetch): a signature failure is never read as a checksum failure`).

Ledger `fixed`: I1-ivy-1, I1-sol-1, I1-ren-1, I1-ren-2, I1-ren-4, I1-ren-5,
I1-ren-6, I1-ivy-2, R2-juno-4.

Next: **R2-juno-3** (the audit calls 115 GPG-verified signature files
"unverified-sums", so the one report that says which checksums cannot be
trusted is drowned).
