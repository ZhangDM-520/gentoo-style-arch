# Current maintainer state

Dated snapshots of live state. Rules and lessons live in `MEMORY.md`;
history lives in `NOTE.md`. This file is overwritten, not accumulated.

## 2026-10-21 08:45 CST — umbriel #504 review round 2 landed (workstream A)

**Machine state.** HEAD `278eb59` (= `origin/main`). This session ran exactly
one build (`gsa -B --leaf umbriel-git`, recipe validation); no marathon
activity. The working tree carries the owner-side fetch-churn `pkgver` sweep
(~527 files, makepkg `update_pkgver` byproduct of the resume13/14 builds) —
deliberately left uncommitted here; the `git checkout -- .` cleanup from the
previous snapshot's plan still applies once everything else is committed.

### Workstream A — umbriel patch series

PR **noctalia-dev/umbriel#504**, review round 2 (ItsLemmy, blocking finding
hand-verified by the owner) is fixed in one amended commit
(`6f56d54`) on `fork/mod-right-double-click-maximize`, **rebased onto current
upstream main `b93ed3d`** — upstream drifted through the input layer
(`tap_and_drag`/`drag_lock`, #500), so the round was revalidated against it:
the deferred Mod+right press is now a grab state (`PendingResizeGrab` in
`GrabState`), the gesture is opt-in (`[input] mod_right_double_click =
"none"` default / `"maximize"`), plus the review's maximize-capture removal,
client-maximize policy dedup, IPC-close teardown check and docs thresholds.
Red-first + two mutation proofs; `input/`+`drag/` harness 45/45 and meson
units 129/129 on the rebased tree. Six full-suite harness failures
(`animation/drag_toggle`, `effect/registry`, `effect/selection`,
`output/two_output_containment`, `render/renderer_recovery`,
`rule/only_window`) reproduce on a stashed base build — pre-existing, owned by
nobody here. Recipe patch `0001` refreshed from the rebased commit with
`sha256sums` + `.SRCINFO` in the same change (pkgver bump rides along per
convention); `gsa -B --leaf umbriel-git` ok. PR **#508** unchanged (open, no
review yet); its patch `0002` still applies on current main (same build).
Details: `NOTE.md` 2026-10-21, "umbriel-git review round 2".

### Workstream B — gsa-smoke2 marathon (parallel session's)

Resume13 wall fixes `7d8a4cc`, subversion `-fno-tree-vectorize` `bcfd364`,
resume14 wall fixes `278eb59` — all pushed. Pending build proofs and churn
cleanup per the 2026-10-20 23:55 snapshot and the NOTE.md 2026-10-21/2026-10-20
sections; this session did not touch the marathon.

**Unpushed intent.** The umbriel-git recipe refresh + this docs snapshot (one
commit, scoped to workstream A files; the fetch-churn sweep stays uncommitted).
