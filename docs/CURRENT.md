# Current maintainer state

Dated snapshots of live state. Rules and lessons live in `MEMORY.md`;
history lives in `NOTE.md`. This file is overwritten, not accumulated.

## 2026-10-20 23:55 CST — resume13 wall fixes landed; smoke2 marathon resuming

**Machine state.** Resume13 of the gsa-smoke2 marathon launching (53-target
continuation from `~/Workspace/gsa-smoke2/resume13-cmd.txt`, run via the
durable wrapper `~/Workspace/gsa-smoke2/resume13-launch.sh`; logs at
`/tmp/gsa-smoke2-resume13.log` and `~/Workspace/gsa-smoke2/`, status in
`resume13-status.txt`). Build drive `/dev/sda` 135G free at launch.
`SRCDEST` is `/home/zhangdm/.gsa-src` (owner move, 2026-10-20).

**Wall fixes landed in this change (NOTE.md 2026-10-20, four sections):**

1. `noctalia-git` — the carried idle patch (PR #4002 snapshot) rebased 3-way
   onto upstream main `ee75f7adcc` over upstream's own `b0af9ffde` lock fix;
   one deliberate drop (`cancelActiveGrace` at lock — upstream's
   `checkLockDuringCancelledFade` test owns that behavior). Upstream PRs
   **noctalia-dev/umbriel#504** and **#508** remain open (no new review
   comments to answer); **noctalia-dev/noctalia#4002** now overlaps upstream
   #4843 and should say so in its conversation.
2. `texlive-texmf` — `prepare()` self-heals the tlpkg SVN husk (wipe +
   re-fetch the pinned revision from the recipe's own `source` entry, 3
   attempts) instead of dying with remediation text.
3. `vscodium-insiders-git` — `build()` generates a bounded npm retry shim
   (3 attempts on exactly the transient-network class; real rc otherwise).
   If this wall strikes a THIRD time, instrument the fetch target itself
   (`gulp-electron`'s `TRANSIENT_NETWORK_ERROR_CODES` / `@electron/get`) —
   that seam needs a recipe patch and is deferred by owner call.

Plus four pre-existing battery repairs (all pre-existed at HEAD; owner call:
fix all four): stale `.SRCINFO`s regenerated (`umbriel-git`,
`logseq-desktop-git`), `pgo-transition` harness now models makepkg's
`srcdir` contract and lands stub training gcda in the recipe's declared
`-fprofile-generate` dir, `pgo-lib` skips prose-only module mentions, and
three hub records carry `core` dual membership per rule 21(b)
(`libdisplay-info-git`, `tomlplusplus`, `xorg-xwayland-git`).

**Pending after resume13 (sequential — never two heavy builds):**
xorg-xwayland-git leaf build (PGO proof: `PGO profile: N gcda files —
rebuilding with profile`, N≥50 — MEMORY §5's owed row), pandoc-cli
(`readelf -d`/`ldd` must show `libicuuc.so.79`), ghostty-git. Then churn
cleanup (`git checkout -- .` for fetch-side pkgver rewrites when everything
is committed), full battery, final tally. `gsa-fetch-v2.sh` is the known
parallel-load timing pin (passes standalone) — the only tolerated red.

**Open threads (workstream A upkeep).** umbriel upstream main has drifted
(`2ed32c4c…` vs the built `5e5ae9d`): refresh the two carried patches from
`~/Workspace/umbriel-src` feature branches via `git format-patch` when the
next umbriel build is due (or when a PR merges — then drop its recipe
patch), `sha256sums` + `.SRCINFO` in the same change.

**Unpushed intent.** The batch commit of the fixes above is the current
disposition (owner: commit and push, one batch commit).
