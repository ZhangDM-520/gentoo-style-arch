# Current state — 2026-10-25 02:17 (live snapshot; overwrite, do not append)

## umbriel patch 0004 (PR #556): hover raises on click (2026-10-25)
- `[input.focus] hover_raises` (default true, inert without `follows_mouse`):
  false = hover focuses only, clicks/keybinds/activation raise; sweeping across
  a larger window underneath no longer buries the window above. Raise computed
  once in `FocusManager::focusView` → `applySeatFocus(.., raise)` +
  `setFocusedView(view, raise, settleLayers)`; `m_lastRaise` replayed by
  `retainCurrentKeyboardFocus`. Only `FocusReason::PointerHover` is special.
- Red-first `focus/floating_hover_no_raise.sh` (5 pins) + 2 mutation proofs;
  meson 140/140 (config_load pin), harness focus/ 34/34, full 373/378 (same
  pre-existing set on base; `drag_toggle` = environmental config leak).
- PR noctalia-dev/umbriel#556 (`eb8fb65`, base main@`679f4fb`): CI enforce /
  intake / Format / Build×2 green, Lint pending at snapshot.
- Recipe patch 0004 (sha256 `c6113bce…`) + pins (pkgver `0.1.0.r1368.679f4fb`)
  + .SRCINFO; prepare() rehearsal on main@`679f4fb` clean (0002+0003+0004).
  Installed `1:0.1.0.r1368.679f4fb-1` (02:16, gsa build 244s, qa findings=0).
  Drop patch 0004 from the recipe when #556 merges (as 0001/#504).

## umbriel patch 0003 (PR #548): abandoned drags settle like drops (2026-10-24)
- Talia review 5637877117 (P2) — the release settle was the only correction
  for where a drag parks a window; `resetMode()` endings (session lock
  mid-drag, toplevel-drag detach, `finishToplevelDrag(false)`) restored
  presentation but not position, so a float shoved out of frame stayed there
  with the arrange gate no longer re-clamping. Fixed in `1c151cf` (amend of
  `71dc363`, rebased onto main@`2c41d38`): `View::settleFloatingDrop` (shared
  with finishFloatMove) runs from resetMode for the abandoned float.
- Red-first: `drag/abandoned_float_settle.sh` (float at x=-393, 7px visible,
  abandoned by session lock; margin x >= -325) red on the old head, green
  after. Meson green; harness 375/380 (same 5 pre-existing).
- Recipe patch 0003 refreshed from `1c151cf` (sha256 `a70a3b64…`) + pins
  (pkgver `0.1.0.r1364.2c41d38` — main moved) + .SRCINFO; prepare() rehearsal
  on main@`2c41d38` (0002+0003 clean). CI on `1c151cf` pending at snapshot.

## umbriel patch 0003 (PR #548): settle invariant audited and closed (2026-10-24)
- PR noctalia-dev/umbriel#548 (draft, branch `floating-release-settle`, head
  `71dc363`): drop-settle + arrange gate PLUS the audit round — fractional
  restores (restoreFloatingPosition, displaced restore, snap restore) now
  place through `View::grabbableOrigin` (clamped, re-remembered clamped), and
  `clampFloatingPosition` retargets an in-flight tween instead of spending
  the usable-change check.
- Red-first pinned by `layout/floating_cross_output_clamp.sh` (cross-output
  restore lands 1883,323 vs margin 1845/285 before the fix) and
  `layout/floating_clamp_retarget.sh` (panel mid-tween settles y=-225 vs
  -185); each fix mutation-attributed to its check. Meson 139/139; harness
  374/379 (same 5 pre-existing failures). CI: Format green on `71dc363`,
  Build ×2 pending at snapshot time.
- Recipe patch 0003 regenerated from `71dc363` (sha256 `1a5b1ce8…`) with
  PKGBUILD pins + .SRCINFO; prepare() rehearsal on main@`54abe52` applies
  0002+0003 cleanly. pkgver `0.1.0.r1363.54abe52` unchanged (main unmoved).
- Build+install queued behind the owner's wave (existing waiter: `gsa -S
  --leaf --no-sync --lanes 1 --jobs 8 --intensity xhigh umbriel-git`);
  installed `1:0.1.0.r1363.54abe52-1` (13:47) predates these fixes.

## umbriel patch 0002 review round landed, CI green (2026-10-24)
- PR noctalia-dev/umbriel#508 Talia P2s fixed in `a12511c`: issue 1 =
  `stiffness`/`damping` floors 1.0 + released-sheet drained-quiet termination
  snap (no tuning can schedule frames forever); issue 2 =
  `settle_after_pause_s` floor 0.1 + cadence-aware stall guard (the gap must
  dwarf the tick cadence, so no in-range value disables physics at any refresh
  rate). Docs now describe the frame-stall semantics. Validated red-first + two
  mutation proofs; meson 129/129, harness `drag/` 21/21.
- CI round: both build jobs rejected `Tuning tuning = {}` (stock GCC ≤16
  enforces the NSDMI/enclosing-class rule the snapshot toolchains have
  relaxed). Fixed in `fe0a879` (default argument → inline overload); CI green
  (Build ×2, Format, Lint) before commenting. Branch pushed; comments posted
  via `gh` (review reply + CI note). MEMORY.md §6 carries the toolchain +
  PR-workflow lessons.
- Recipe patch 0002 refreshed at `fe0a879` (sha256 `3e3edebf…`, `.SRCINFO`);
  `gsa -S --leaf umbriel-git` build-install ok (pkgver `1:0.1.0.r1363.54abe52-1`
  unchanged — main unmoved; the patch content is what changed).
- PR #504's patch 0001 is gone from the recipe (merged upstream `3e95f6d`;
  cleanup landed in `65d70ed`). #508 awaits Talia's re-review/merge; drop
  patch 0002 from the recipe when it merges.
- Unpushed intent: the recipe + docs commit for this CI round.

## aranicy: packaged in the tree; live cutover is OWNER work (2026-10-23)
- `packages/stable/aranicy` v0.1.0 (clean-room MIT rewrite of ananicy-cpp;
  eBPF exec events, ananicy-compatible JSONL rules) + its single topology
  record (`stable` group; edges `gcc-snapshot,glibc-git,llvm-git,rust-git,
  zlib-ng-compat-git`) committed and pushed. Gate (owner's): 2.28%/4.10% of
  one core at 2000 execs/s vs ananicy-cpp 13.7%/16.2%; owner chose rewrite +
  push-all.
- Proven: leaf `makepkg -s --noconfirm` → aranicy 0.1.0-1 (payload = binary,
  `aranicy.service`, `/etc/ananicy.d/ananicy.conf`, license, README; NEEDED =
  libelf/libz/libgcc_s/libc). Recipe tarball sha256 pinned (no SKIP).
- NOT done here (owner's cutover): install aranicy and drop extra/ananicy-cpp
  1.2.0 — the package `conflicts=(ananicy-cpp)` with NO provide, the unit
  carries `Conflicts=ananicy-cpp.service`, and `cachyos-ananicy-rules` +
  `/etc/ananicy.d` stay installed (rules compatible; do not touch).

## ⚠ Host action needed: build scratch drive is DEVICE-OFFLINE
- `/dev/sda` (f2fs, /run/media/zhangdm/5cbd0046-e1d6-4737-a58b-ab040735ad9a)
  went offline mid-session (dmesg: `Stopped filesystem due to reason: 0`,
  `device offline error`, Synchronize Cache failed). Stale mount remains:
  reads serve from page cache, writes return EIO.
- Contained: ~/.makepkg.conf TMPDIR guard now probes a WRITE (backup
  ~/.makepkg.conf.bak-20261022) and falls back to tmpfs — makepkg works
  again (piglit-git rebuilt + installed to prove it). Still owed by the
  owner: re-plug/remount + f2fs fsck + SMART look; the gsa build tree and
  binpkg store live on that drive.

## ABI gate — robust + optimised + shipped (gsa-pm owns it)
- False alarm fixed: detached `.sig` files are never candidates (archive
  extension whitelist) and name resolution is EXACT (no `linux-cachyos` ↔
  `linux-cachyos-headers` prefix cross-resolution). Unextractable inputs
  warn + skip (fail-open); real findings stay fatal.
- Optimised (owner's pick: whitelist + batched readelf + phase merge +
  fact cache): kernel-class names skipped (carve-outs -headers/-src/-dkms
  stay scannable), chunked multi-file readelf, one acquisition + one
  resolution pass, per-archive sha256 fact cache (facts only, never
  verdicts).
- Measured: 159 MB kernel archive scan 207 s -> 0.65 s (0.39 s warm cache),
  whitelist path 0.003 s; the real 50-package `paru -Syu` gate cost 10 s
  total. Fixture cases 7–11 added, all new mechanisms mutation-probed
  red-first.
- Shipped: fix 7f52bde, gsa-pm re-pin 56aa0b0 -> 0.1.0+r418 built (plain
  makepkg) + installed; single hook under gsa-pm ownership.

## E2E verified (owner-approved `paru -Syu`)
- Repo phase: the exact 50-package transaction that failed landed at
  14:28 — linux-cachyos 7.3.0-2 installed, kernel-class skip hit in
  production, zero findings, zero false alarms.
- AUR phase: piglit-git r12470 built + installed (makepkg healthy again).

## pacman patch: warning flood muted (2026-10-22 15:20)
- `0002-libalpm-quiet-ignorepkg-local-newer.patch` in packages/stable/pacman
  demotes the IgnorePkg + local-newer notices to DEBUG (owner's style call);
  the real downgrade notice stays a WARNING. Measured 248 -> 0 warning
  lines on `pacman -Su`. Installed pacman 7.1.0.r9.g54d9411-6.
- Rollback: /root/pacman-rollback-20261022/ (raw cp restore of pacman +
  libalpm.so*). Rebuild recipe pkgrel 6 to reproduce.

## paru in the tree + both warning floods muted (2026-10-22 16:10)
- packages/git/paru-git (2.1.0.r68.g7830fac-1) imported with
  paru-verbose-ignored.patch (devel flood -> `paru -v` only); installed via
  gsa -U, IgnorePkg registered. Both layers measured 34/248 -> 0.
- Engine: GSA_TEST_PROBE_ROOT seam + LocalDb::load_at (fixture-only;
  production /usr/bin/gsa r418 unaffected — behavior identical when the
  env is unset). abi-postinstall-probe G/G2 pin both halves of rule 25(b).
- Topology: core added to gdal, xerces-c, jsoncpp-git, libharu (hub rule).

## ABI wave re-bless RUNNING (2026-10-23 00:30, run 1792687167-2428489)
- The deferred 35-pkg queue is being rebuilt: `sudo gsa -S --leaf --no-sync
  --skip-built vtk opencv` (tree workspace), DETACHED. First results:
  frei0r-plugins 0 207 ok; vtk + mlt lanes in flight; GUI closure
  prefetching (0ad, audacity, gstreamer, libreoffice-fresh, ...).
- Build root REDIRECTED: the f2fs build drive is gone (reboot + unplug);
  GSA_BUILD_DIR=/home/zhangdm/.cache/gsa + TMPDIR=/home/zhangdm/.gsa-tmp
  (both verified in lane process envs). 769G free on home.
- Monitor: `ls /var/lib/gsa/runs/1792687167-2428489/*.result` + `pgrep -a
  gsa`; the run record (full order) is written at run end.
- When the drive returns: remount + f2fs fsck + `sudo gsa -Md --fix`
  (binpkg index rows still point at the old drive paths).

## UX wave SHIPPED (2026-10-23, commit 0308687 on origin/main)
- Human-default readability + machine vocabulary (owner ask): `help.rs`,
  `output.rs`/`render.rs` catalog (unit-pinned both vocabularies), `write_notes`
  mode-split, lane state (`runs/current`, `<run>/<pkg>.started`
  pid/epoch/log-offset, `SupEvent::Tick`), live TTY dashboard (`dashboard.rs`:
  progress box, run-scoped tails, spinner + event footer, 10 s `STATUS:` pipe
  hint under `--human`). Battery 76/76 + `cargo test --workspace` green.

## gsa-pm git self-tracking + contract §L.10 (2026-10-23 night, uncommitted → asked)
- The r418 gap: the recipe's `#commit=` pin rebuilt the old engine forever
  while acceptance ran on `target/debug/gsa`. Both gaps closed:
  (1) gsa-pm source floats on the default branch (house -git idiom,
  `pkgver()` self-derives `0.1.0+rN+g<hash>`, makepkg rewrites the field);
  (2) contract §L.10 + MEMORY rule 61: smoke tests run the INSTALLED binary
  (`tests/run-all.sh` banner names it + its package), nested crate builds
  deleted from run-all and all 63 fixtures; `GSA_TEST_GSA_BIN` = explicit
  pre-install override only.
- Deploy loop (after commit lands): `sudo gsa -Sy` → `sudo gsa -S gsa-pm` →
  battery + smoke against `command -v gsa`.

## @git @stable update — waves 5..9 done, WAVE-9 IN FLIGHT (run 1792851662-883478)
- Marathon state: waves 1-8 landed ~250+ packages; wave 9 (38 rows) in flight with the fetch
  fixes proving out (qt6-5compat re-registered on its canonical-origin mirror).
- Fetch mechanics hardened (MEMORY trailing bullets): canonical mirror origins, .part hygiene,
  clean-room retries (makepkg keeps $srcdir), name::git+/git:// scanner forms.
- Owner threads CLOSED: scx merged (scx-scheds-git owns scxtui+scx_loader), shelly DEPRECATED
  (packages/deprecated/shelly, record commented), gdb 18.1-1.1 installed (layout bridge + bfd),
  ananicy-cpp retired (aranicy 0.1.0-1).
- Known stragglers (retry-class): libisl + mariadb mirrors (hosts unreachable at length), fish +
  python-matplotlib (cargo/pip at build), openjph + flatpak-git (configure-time downloads; trees
  cleaned).

## Wave 1 record (2026-10-24 00:04, run 1792771499-1387266)
- Wave 1 (1792771499-1387266) ended refused rc3 after ~9h: 92 ok / 9 failed / 67 parked / 329
  never-started. Stopper: icu-git soname 79->80 (install gate). Failures triaged + fixed:
  3 transient network, 2 KF 6.31 topology-edge races, 1 perl 5.42-vs-5.44 world skew (also broke
  libcdio via help2man/Locale::gettext), 1 transient pacman race, 1 = libcdio (same perl class).
- Resume wave (09:34, DETACHED): 404 = remaining - icu-git; staging chain green (perl 5.44,
  karchive, kdoctools, kwindowsystem, solid, kio, kio-extras, heaptrack). Monitor: `ls
  /var/lib/gsa/runs/1792805642-2753077/*.result | wc -l` vs 404; /tmp/gsa-resume-20261024.log.

## Wave 1 record (2026-10-24 00:04, run 1792771499-1387266)
- `sudo /usr/bin/gsa -S --leaf --no-sync --lanes 4 --jobs 3 --intensity xhigh <497>`
  from /tmp (canonical store root). 497 = @git @stable (551) − 53 ABI-wave
  triggers (/tmp/moved-53.txt) − binutils. Zero `abi-wave` rows, zero
  heavy toolchain (verified in /proc argv). Progress: `ls
  /var/lib/gsa/runs/1792771499-1387266/*.result | wc -l`; log
  /tmp/gsa-overnight-20261023.log. `--no-sync` = committed versions as-is
  (22:49 version-sync already refreshed tracked versions).
- The `-Su` ANSWER (owner ask): YES, `gsa -Su @git @stable` takes group
  selection (help.rs:86, 551 resolves); `--leaf` bounds the consumer
  growth. Its stale set is `noop empty-list` today and VCS drift is not its
  trigger — full analysis + wave scoping: NOTE.md 2026-10-23 late.
- Build drive WAS UNMOUNTED (path degraded to /run tmpfs — the "3 archives"
  blindness root cause). fsck.f2fs clean, mounted, 222G free, 7 tmpfs
  archives rescued into pkgs/, 105 stale build/ trees of the interrupted
  re-bless queue deleted. MEMORY rule 62 = the probe lesson.

## Still deferred (owner)
- **ABI wave re-bless queue (the 53 moved providers + their wave closure:
  curl, sqlite, util-linux, gstreamer, poppler, vtk, opencv, glycin, …).**
  Installing any of them lands the wave = llvm-git/rust-git/coupled-must +
  gcc-snapshot/rust-bindgen-git in ONE transaction — the banned heavy core,
  so it is an owner-approved run on its own. Facts to re-check first: run
  `gsa -Su --leaf --dry-run @git @stable` with the drive mounted (the
  stale-set measurement was taken blind), and note that removing wave
  members alone is useless (uncovered members refuse the run).
- poppler 26.10 landing path.

## Next action
- Monitor resume2 (1792815755-3972240): result count vs 313; on any further install-refused
  soname stop or failure park-cascade, triage the mover/failed rows and resume the remainder.
- When NO run is live: `sudo gsa -Md --fix` (binpkg index reconciliation).
  Store sync of the topology edges: done via `sudo gsa -Sy` (12:15, store at 7c325a7+0989f2f).
- aranicy cutover: TREE SIDE DONE (ananicy-cpp recipe + topology record removed, 2026-10-24).
  POST-WAVE steps: `sudo gsa -Sy` (store sync) then `sudo pacman -R ananicy-cpp` + install aranicy.
- Owner: the heavy-core ABI re-bless decision
  (53 moved providers + icu-git's consumer wave); poppler 26.10 landing path.

## 2026-10-25 live state (window v2:9 close)
- **Core regrouping DEPLOYED** (owner cutoff: 55 named + top-24 by consumer
  closure; 52 records gained `core`, commit ed1a137 + rule-21(a) hub
  promotion 2b9cc87). 320 core records; loader clean.
- **Retry rows GREEN:** zbar (0.23.95-1.1, meson port + legacy python-module
  artifact shape restored), xorg-xwayland-git (24.1.14.r1234, **real PGO:
  367 gcda from XTS under headless weston**), xwayland-satellite-git
  (132s). libcolord-git 1.4.8.r17-2 trimmed to stock libcolord's file set.
- Walls cleared this stretch (details in NOTE.md 2026-10-25 entries):
  makepkg find_libprovides artifact-shape (zbar), stock split-rel compat pin
  (libcolord-git), weston lazy-plugin Tier-2 gaps (5 sonames) + install-seam
  registry wiring (35bafcc), shelly dead-ABI-rows blocking every wave
  (removed shelly + 12 rows; backup subscriptions.bak-20261025-shelly),
  wpewebkit mirror 404 (pacman -Sy).
- **Deferred (OWNER-GATED): the 524-package heavy-core re-bless wave** —
  zbar's consumer wave (gstreamer + the 35 parked) plans 524 abi-wave rows
  incl. llvm-git/rust-git/gcc-snapshot/rust-bindgen-git (coupled-must) +
  libreoffice-fresh/onlyoffice-git/blender-git/vtk/opencv/jdk-openjdk. Its
  dry-run is refusal-free now (`gsa -S --leaf --dry-run <parked set>`).
  gstreamer's mirror issue is fixed; its build rides this wave.
- Owner questions open: (1) launch/defer the 524 wave; (2) should the
  pacman PreTransaction hook (tools/abi-need-check.sh) honor the Tier-2
  registry (it is exclusion-blind by design; weston UPGRADES via manual
  pacman -Syu will keep hitting it); (3) engine gap: no maintenance verb
  prunes abi/subscriptions rows for consumers neither installed nor in the
  topology (the shelly class).
- Deployed this turn: gsa-pm rebuild carrying 35bafcc (validate the
  INSTALLED engine after: `gsa --qa-check provides-versioning` + the abi
  fixture slice).
## Next action
- Confirm gsa-pm deploy landed (run `command -v gsa` battery banner + the
  abi fixture slice green against the INSTALLED engine).
- When no run is live: `sudo gsa -Md --fix` (binpkg index reconciliation).
- Owner: the three questions above; poppler 26.10 landing path.
