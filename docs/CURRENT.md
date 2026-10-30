# Current state — 2026-10-29 01:0x (live snapshot; overwrite, do not append)

## umbriel: 0013 current (5297413e…) + STACK-WIDE REFACOR DRIFT (2026-10-30)
- 0013 = sha256 5297413e… (gsa 3673351, pushed): the twelve first-parent feature commits
  76477c29..275e323a. The branch later merged upstream main (ae14b793) to clear PR #585
  conflicts — merges are excluded from the slice by design, so 0013 stays current and the
  PKGBUILD range note stays accurate. No re-cut until the stack-wide wave below.
- **STACK-WIDE DRIFT — every owner action needed:** on main@1ecefc2e (2026-10-30) only 0008
  of the 9 patches still applies (`git apply -3`, prepare() order): 0009, 0011, 0012, 0013,
  0014, 0015, 0016, 0017 ALL FAIL — upstream's refactor(ipc) name:arg->word-args + typed IPC
  requests (e8ab5b00), layout floating->stacking rename (b95c1ae5), and capture exclusions
  (#616) moved the patches' regions. A gsa build against head-of-main is broken until each
  patch owner re-cuts on a refreshed stack base. 0013's re-cut input is ready: the 12 slice
  commits + the ae14b793 conflict resolutions re-derived on the new base.
- PR noctalia-dev/umbriel#585 (Closes #574): head ae14b793 = merge of main into the feature
  branch, PR MERGEABLE, Talia findings fixed and answered; CI on the merge head in flight
  at write time.
