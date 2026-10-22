# Current state — 2026-10-22 15:00 (live snapshot; overwrite, do not append)

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

## Still deferred (owner)
- 35-pkg ABI wave re-bless queue; poppler 26.10 landing path.

## Next action
Owner: recover the offline drive (re-plug/remount, f2fs fsck, SMART).
Nothing else pending.
