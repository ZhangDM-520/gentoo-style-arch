# Current state — 2026-10-22 12:50 (live snapshot; overwrite, do not append)

## Session closed out (2026-10-22)
- ALL session work committed and pushed (65d70ed..91f6609, five logical
  commits + the two gsa-pm folding commits). Working tree clean except this
  docs commit.
- gsa-pm 0.1.0+r415+ge5322fb516ed-1 BUILT (plain makepkg, bootstrap rule) and
  INSTALLED. It owns the PreTransaction ABI gate end-to-end:
  `/usr/bin/gsa-abi-need-check` + `/usr/share/libalpm/hooks/10-gsa-abi-need-check.hook`
  (both `pacman -Qo` = gsa-pm). Admin fallback copies removed — one Action,
  one hook file. Live hook fire proven; fixture battery green vs the shipped
  checker.
- ghostty-git 1.3.1.r3172 built + installed. The predicted terminfo bite
  happened (upgrade deleted the ncurses-git-owned shared file) and was
  recovered via `pacman -U` of the indexed ncurses-git archive (sha256
  verified). `pacman -Qk` 0 missing files both packages; `pacman -Dk` clean.
- Deliverable status unchanged: vtk 9.7.1-1.2 + opencv/python-opencv
  5.0.0-13.3 installed and ABI-validated; provides-audit rc=0 (413/59/0).

## Owner decisions taken (2026-10-22)
1. Commit disposition = commit and push (done).
2. Removals: haskell cluster (214 pkgs, ghc kept), wpewebkit +
   gst-plugin-wpe2, python-pyqt6, qcoro, throne-bin, opencl-mesa +
   lib32-opencl-mesa, cachyos-kernel-manager — DONE. qt6-webengine KEPT
   (removal cost > harm). qt6-quicktimeline KEPT on the same principle
   (would cost easyeffects-git, qt6-quick3d, qt6-graphs).
3. ghostty_rebuild = true (done; terminfo recovered; -Dk clean).
4. ABI wave re-bless queue (35 GUI packages) = DEFER, recorded as follow-up.
5. poppler 26.10 = DEFER (installed 26.08 runtime-healthy; the soname move
   needs §M repair-write or a one-transaction -Ua per rule 25(d)).

## Follow-ups (deferred by owner)
- The 35-package wave re-bless queue (vtk/opencv token move). Wave mechanics
  measured: --leaf suppresses selection expansion but NOT record-mismatch
  wave closure; --skip-built claims archives but forces provider rebuilds.
- poppler 26.10 landing path (see §M / rule 25(d)).
- gsa-pm engine redeploy is DONE for this session's changes; /usr/bin/gsa is
  now the r415 binary carrying the hidden-skew fixes.

## Next action
None pending — session work complete. New work starts from the follow-ups.
