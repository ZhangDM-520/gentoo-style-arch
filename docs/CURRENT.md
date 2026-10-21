# Current maintainer state

Dated snapshots of live state. Rules and lessons live in `MEMORY.md`;
history lives in `NOTE.md`. This file is overwritten, not accumulated.

## 2026-10-22 02:30 CST — vtk + python-opencv included and installed; ABI status validated

**Machine state (probed 02:25).** HEAD `8e9a622` == `origin/main` + one
UNCOMMITTED worktree carrying this task (see below). Build drive `/dev/sda`
(f2fs, kernel-mounted at the gsa-build path — the automount that dropped it
mid-build on 2026-10-22 is superseded; MEMORY §6 carries the lesson):
~60G free after the vtk build. `/run` tmpfs healthy (1%). Installed and
verified: **vtk 9.7.1-1.2**, **python-opencv 5.0.0-13.2**, **opencv
5.0.0-13.2** (all tree-built; the broken CachyOS installs are replaced),
jsoncpp-git 1.9.8.r14 unchanged. IgnorePkg registers opencv/vtk/python-opencv
so stock cannot reinstall over them.

**The task (owner ask).** Stock vtk/python-opencv broke on this host
(stock links `libjsoncpp.so.27`; the tree's jsoncpp-git ships `.28` — 76 vtk
libs had `libjsoncpp.so.27 => not found`). Both are now tree recipes:
`packages/stable/vtk` (full optimisation stack: mold + LTO + cmake-tier
two-phase PGO, trained 4996 gcda vs floor 100, `lib/pgo.sh` gate; 413 bare-
soname provides) and `python-opencv` restored as a split output of
`packages/stable/opencv` (rule 24 sibling pins). Wired in `config/topology.conf`
(vtk record with 34 edges; opencv record +python,+vtk). Validated by
`sudo gsa -S --leaf --no-sync` of exactly the two + `gsa -Qa`: vtk token
`f2f111c1…` self-consistent; the opencv set's subscribers hold `d4e316cc…`
which matches an independent recomputation of the built payload exactly;
`tools/provides-audit.sh` rc=0 (413/413). Six walls (3 code patches, 1 infra,
1 build-system) are narrated in NOTE.md 2026-10-22.

**Uncommitted worktree (commit disposition ASKED, awaiting owner).**
`packages/stable/vtk/**` (new recipe + 3 patches), `packages/stable/opencv/*`
(python-opencv output, pkgrel 13.2), `config/topology.conf`, `docs/{NOTE,
MEMORY,CURRENT}.md` (including the 2026-10-21 marathon-close snapshot).

**Remaining owner follow-ups.**
- colord-git split decision (stock `colord` exact-locks `libcolord=1.4.8-2`
  vs stack `libcolord-git` 1.4.8.r16.g56ccc23-1) — untouched since 10-21.
- QA provides-versioning class (6-8 findings/run) — report-only.
- NEW: stock optdepend providers `gdal`, `liblas`, `pdal` link icu .78 and
  `openvr` links jsoncpp .27 — the same skew class one level down; 5 vtk
  optional-module libs carry their unresolved sonames. Tree recipes for the
  four (or trimming those modules) is the stack-consistent remedy.
- NEW (engine): `gsa -Qa` shows the last output's derived token under a
  split recipe's row set (subscriptions carry the true token) — cosmetic/
  report-only candidate.
