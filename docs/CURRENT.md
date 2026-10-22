# Current state — 2026-10-23 00:50 (live snapshot; overwrite, do not append)

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

## Still deferred (owner)
- 35-pkg ABI wave re-bless queue; poppler 26.10 landing path.

## Next action
Owner: (1) aranicy cutover — install the built 0.1.0-1, retire
ananicy-cpp; (2) recover the offline drive (re-plug/remount, f2fs fsck,
SMART).
Nothing else pending.
