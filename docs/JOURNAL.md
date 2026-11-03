# JOURNAL — chronological action log

One line per action, oldest first, appended at the bottom. High-level summary
plus a pointer only; incident detail lives in `docs/NOTE.md`, rules in
`docs/MEMORY.md`, and the atomic per-action write-up in `.logs/action-*.md`.
Format: `- YYYY-MM-DD — <summary> [<pointer>]`

History before the 2026-10-31 memory-architecture cutover is not repeated
here: it lives in `docs/NOTE.md` (dated `##` sections, newest first) and
`docs/MEMORY.md` §5/§6. Architecture: `AGENTS.md` §0.

---

- 2026-10-31 — memory-architecture cutover: `AGENTS.md` router, this journal, and the `.logs/` scratchpad/action-export layer created; `docs/MEMORY.md`/`docs/NOTE.md`/`docs/CURRENT.md` keep their SSOT roles [.logs/action-2026-10-31-memory-architecture.md]
- 2026-10-31 — gsa full-rebuild run-4 relaunched: 570 cherry-picked names (run-3 `continuation.remaining` + `glibc-git` clean-tree rebuild after the `-Ofast`→`-O2` fix), `opus-git` `-DFLOAT_APPROX` fix v2, watchdog on the USB build disk after the 2026-10-30 drop remediation [.logs/action-2026-10-31-run4-relaunch.md]
- 2026-10-31 — pandoc-cli custom-Setup way wall fixed (`ghc` shim forces the dynamic way onto cabal's setup compile, pkgrel 3) + NOTE.md incident entries (way wall, USB drop) + MEMORY.md rule 70 [.logs/action-2026-10-31-pandoc-ghc-way-fix.md]
- 2026-10-31 — drop-tainted warm trees produced a NaN jq binary; 16 crash-window trees wiped, corrupt lane killed, jq recipe gets per-phase `make clean` + attempt-pure profiles (pkgrel 1.2) [.logs/action-2026-10-31-tainted-tree-triage.md]
- 2026-10-31 — code-review findings fixed: `later_after_settled` closes the landed-consumer coverage hole (fail-closed), duplicate `#[test]` removed; llvm-git/fontconfig-git pkgver churn deferred to disposition [.logs/action-2026-10-31-review-findings.md]
- 2026-10-31 — four build walls fixed (OSL PassBuilder drift, nodejs LIEF patch refresh, texlive minilua→host-luajit routing, gstreamer WPE dead-keep trim) + python `-Ofast`→`-O2`; continuation relaunched with 516 merged names [.logs/action-2026-10-31-four-walls.md]
- 2026-10-31 — Monday-boundary snapshot pins for llvm-git/rust-git/mesa-git/libclc-git/spirv-llvm-translator-git + gcc-snapshot migrated off the AUR snapshot-tarball/version-sync mechanism onto git-tree checkout pins; llvm downstream ABI audit captured [.logs/action-2026-10-31-monday-snapshot-pins.md]
- 2026-11-01 — engine settle before the -O3 full-wave restart: strict downstream wave expansion (direction rule), epoch-stacking + skew-lint fixes, NINJAFLAGS lane-budget shim, topology review fixes (3 stale edges, 4 abi tags), python prepare() guard; battery 72/73; 660-roster restart armed behind the kernel build [.logs/action-2026-11-01-engine-settle.md]
- 2026-11-02 — topology build-order defect class traced (2 audits → 105 records/193 edges fixed + order-proofed), umbriel patch stack rebaselined (0017 retired), zen abort diagnosed to post-flag glib/ffi chain candidates; waves v13/v14 green-stacked, v15 paused mid-qtbase-clone for session restart [.logs/action-2026-11-02-wave-v15-pause.md]
- 2026-11-02 — dep-chain fix completed pre-restart: TIER C decided (tool edges universal, mold cycles named exceptions, icu/mesa/spirv/libclc/OSL → abi=must) + 144-pair appendix applied and battery-validated; 170 stale consumers computed → post-restart dispatch files (175-id clean pass + zen leaf) [.logs/action-2026-11-02-dep-chain-completion.md]
- 2026-11-03 — free(): invalid size load-abort class (blender/zen/electron) root-caused to glib free_sized vs malloc interposers; 0003-meson-no-free-sized.patch swaps in one atomic pacman -U; gsa --leaf dispatch hijack recorded + plain-makepkg directive [.logs/action-2026-11-03-glib-free-sized-fix.md]
- 2026-11-03 — throne-git recipe added and wired (Qt6 GUI + Go ThroneCore two-layer flag flow, app group, built+installed 1.4.0.beta.5.r2.ga76f33c-1) [.logs/action-2026-11-03-throne-git-recipe.md]
- 2026-11-03 — flag-audit 2026-11-01 TIER-1 adoption: 23 PKGBUILDs appended at row anchors (44 lines), rule-3 -fipa-pta drops in blender-git/rocm-llvm, samba/wine/libreoffice flag-flow verified from cached sources; bash -n 23/23 [.logs/action-2026-11-03-flag-audit-tier1.md]
- 2026-11-03 — per-recipe compile-flag revision applied: 133 PKGBUILDs (T1 23/T2 35/T3 75) + doxygen-git override bug fixed; battery 71/73 (2 known engine fixtures = job 3) [.logs/action-2026-11-03-flag-audit-apply.md]
- 2026-11-03 engine-inconsistency-fix (job 3): ABI-wave false-move class (index fold dropped split outputs; `-` placeholder records) root-caused and fixed + fixture walls g/h; battery 73/73; rule 21(a) hub fallout enforced — details: NOTE.md 2026-11-03 "engine job 3", export: .logs/action-2026-11-03-engine-inconsistency-fix.md
- 2026-11-03 — throne-git wired to carry the two upstream-pending throne-dev patches (domain-resolver import + UA preset dropdown) as 0001/0002 with git apply -3; makepkg artifact 1.4.0.beta.5.r6.g77aa05b-1 built and patch-application verified from binaries [.logs/action-2026-11-03-throne-git-pr-patches.md]
- 2026-11-03 release 1.0.1 (commit 012fd1c, tag 1.0.1): engine wave false-move fix shipped — gsa-pm 0.1.0+r530+g012fd1c11a7e-1 built via plain makepkg, installed (snapper 10269), battery 73/73 against the installed engine, package archive on the GitHub release; engine queue item closed — export: .logs/action-2026-11-03-release-1.0.1.md
- 2026-11-03 dashboard latent accounting: the box total counted the remediation latent pool (--leaf run showed 1/332) — fixed to count the run own packages with activated latents joining at dispatch; dashboard-pty.sh section D red-first-pinned — details: NOTE.md 2026-11-03 "dashboard progress total", export: .logs/action-2026-11-03-dashboard-latent-count.md
- 2026-11-03 — umbriel-git render-scale and dependent patch stack refreshed and rehearsed; details: NOTE.md 2026-11-03 "umbriel-git render-scale and dependent patch refresh", export: .logs/action-2026-11-03-pr573-patch-refresh.md
