# scratchpad — review fix phase

Last action: **I1-sol-4 fixed** — the PACMAN shim now carries the run's
`--config` on both the query (`-T`) and transaction (`-S --asdeps`) paths, and
its idempotency compares the body instead of the file size.

Unpushed: R2-juno-4 (`fix(fetch): a signature failure is never read as a
checksum failure`) and I1-sol-4 (the commit this action writes).

Ledger `fixed`: I1-ivy-1, I1-sol-1, I1-sol-4, I1-ren-1, I1-ren-2, I1-ren-4,
I1-ren-5, I1-ren-6, I1-ivy-2, R2-juno-4.

Next: **R2-juno-3** (the audit calls 115 GPG-verified signature files
"unverified-sums", so the one report that says which checksums cannot be
trusted is drowned).

Environment note: the owner's interactive `makepkg -sif` holds the REAL
`/var/lib/pacman/db.lck`; unit tests and the battery must be re-run between
builds before any claim of a clean suite.
