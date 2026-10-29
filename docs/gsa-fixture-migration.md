# `gsa` fixture re-contract — per-fixture migration inventory and staging plan

Date: 2026-10-12. Status: staging plan for the clean-slate fixture re-contract
(docs/gsa-contract.md §L, owner decision). This document is the inventory the
fixture rewrite works from: one row per existing fixture, what it pins, which
assertions are behaviour (KEEP) versus engine-coupled (REWRITE), what replaces
each engine-coupled spelling in the `gsa` contract, and the phase in which the
fixture flips. It ends with the staging rules, the assertions retired without
replacement, the DESIGN-ONLY semantic-equivalence harness, and the contract
gaps found while building the inventory.

Nothing here changes the battery in this wave except the three files named in
"Staging mechanics": every existing fixture file stays byte-identical until
its flip phase (and the old assertions retire in one deliberate pass at
cutover).

## 0. Enumeration

`tests/run-all.sh` discovers fixtures with

```
find . -name '*.sh' ! -name 'run-all.sh' ! -path './assets/*' ! -path './lib/*'
```

(`tests/run-all.sh:58-60`), which yields **56** pre-existing fixtures on
2026-10-12 — one more than the "55" quoted in the task brief and in
`docs/gsa-contract.md`'s preamble; enumeration is authoritative and all 56 are
inventoried below. This wave adds one more discovered member,
`tests/gsa-v2-lib.sh` (the v2 library self-test), for 57 total in the battery
after this wave; it is not an inventory row because it is new.

## 1. Phase vocabulary

The flip phase of a fixture is one of (the owner's five phases; note that
`docs/gsa-contract.md` itself assigns no phases — see gap G7):

| Phase | Name | Surfaces that land |
| --- | --- | --- |
| 1 | read-only core | `gsa -Q*`, `-Sl`/`-Bl`, `--dry-run`, `-Qt`, the strict loader, target/range resolution (§B.3–B.4, §B.8, §C) |
| 2 | scheduler | lanes, run record `format: 2`, cone-stop/parked, deferral, signals, intensity, core-solo, `build-tools` band (§F, §H, §I, §K) |
| 3 | install | install pipeline, decision rows, `--install-decide`, IgnorePkg registration, pacman transactions (§B.6, §D.1, §E) |
| 4 | PM features | `-M` band (`-Ma`, `--qa-check`, `-Md`, `-Mi`, `-Ml`, `-Mm`, `-Mc/-Mcc/-Mccc`), `-Sw`/`-Sy`/`-Su`/`-Qu`, binpkg index, side-car DB (§B.4, §B.7, §J) |
| 5 | cutover | the single deliberate pass that retires the old assertions and deletes the fish-era harness content |
| — | no-flip | fixture pins engine-independent content only (PKGBUILD/.SRCINFO/local assets/repo policy/host tools) |

Fixtures with surfaces in several phases list the primary flip phase and name
the split in the row; every engine-coupled assertion must be flipped by the
end of the named phase.

## 2. Column legend

- **pins** — the scenario and invariant, one line.
- **KEEP / REWRITE** — `KEEP` is behaviour: scheduler invariants,
  install-before-dependents, cone-stop/deferral semantics, exit-code
  behaviour, decision-row *meanings*, loader validation, recipe/package
  content, non-mutation and child-cleanup. `REWRITE` is engine-coupled, in
  four classes:
  - `argv` — a literal fish-engine spelling (`fish build-all.fish --no-deps`,
    `-g git`, `-n`, `-i`, `-fi`, `-ia`, `-s`, `--install-decide`,
    `--audit-lint`, `--register-ignorepkg`, `--topology`, `-ln`, wipe flags).
  - `prose` — a byte-pinned output string (listing footers, summary text,
    diagnostics wording).
  - `rr-format1` — anything parsed through `rr_*` (`tests/lib/fixture-lib.bash`)
    from the `format: 1` block: scalars, `pkg status rc dur reason` rows, the
    `blocked` status.
  - `row-framing` — tab-framed `plan_row`/old `--install-decide` row codec.
- **new-contract target** — the exact `docs/gsa-contract.md` spelling, row or
  field that replaces the engine-coupled assertions (§B.9 is the disposition
  table for every old spelling).
- **phase** — the flip phase from §1.

Counts in the REWRITE cells are per-assertion-site estimates from the
inventory pass; "≈" marks a class where a fixture repeats one shape many
times.

## 3. Staging rules

1. **Existing fixture files stay byte-identical in this wave.** The rewrite
   flips per this inventory as each engine phase lands; the old assertions are
   retired in ONE deliberate pass at cutover (Phase 5), never piecemeal before
   it. The battery must be green at every wave boundary.
2. **Behaviour is kept; only engine-coupled spellings change.** Scheduler
   invariants, install-before-dependents, cone-stop semantics, exit codes
   (with the §G.1 value remaps noted in the rows) and decision-row meanings
   survive the flip; argv shapes, byte-pinned prose and `format: 1` parsing do
   not. Exit-code expectations remap per §G.1 where the row says so (e.g.
   deferral-only `1`→`5`, cone-stop-with-failure `1`→`4`, refusals→`3`).
3. **The semantic-equivalence harness is DESIGN ONLY** (§7): its shape is
   specified here so the flips can collect scenario data for it, but it is not
   implemented in this wave.
4. **Every flag, row name and field referenced here exists in
   `docs/gsa-contract.md`.** Where the contract is silent on something a
   fixture needs, the silence is recorded in §8 ("Contract gaps found") and no
   semantics are invented for it.

Staging mechanics introduced by this wave (the only files it adds):

- `tests/lib/rr-v2.bash` — the v2 fixture library: strict `format: 2` parser
  (`rr2_*`), the engine runner `run_engine` (fish builder today, `gsa` at
  cutover, selected by `GSA_TEST_ENGINE`), and the v2 `GSA_FAKE_*` stub-knob
  vocabulary (§D.2). It is sourced, never executed: the `.bash` extension and
  the `lib/` exclusion in `tests/run-all.sh` keep it out of discovery — both
  load-bearing.
- `tests/gsa-v2-lib.sh` — a discovered fixture that self-tests the v2 library
  against the `format: 2` annotated example (§H.4) and a malformed-block
  battery. This is the parser fixture §L.2 requires every grammar change to
  update in the same change.
- `tests/lib/fixture-lib.bash` stays **byte-identical** (single-writer
  discipline); its `make_workspace`/`stub_*`/`run_builder` synthesis helpers
  and its `format: 1` `rr_*` parser serve the fish-era fixtures until their
  flips. A flipped fixture sources `rr-v2.bash` (and keeps using the synthesis
  helpers until Phase 5 consolidates them — see §8 G-note on the two-table
  window).

Flip procedure per fixture, at its phase: rewrite the argv sites to the §B
grammar through `run_engine`; replace `rr_*`/`format: 1` expectations with
`rr2_*`/`format: 2` field expectations; replace byte-pinned prose with
record-derived expectations (§L.3: expectations derive from records, never
pinned counts) except in the single rendering test §L.5 allows; keep every
KEEP assertion as-is. Phase 5 then deletes the retired list (§6) and the
fish-era parser.

## 4. Inventory (56 fixtures)

Spelling note (2026-10-14): the Replacement column's spellings are
family-first — `gsa` rejects a modifier before its family (`gsa --dry-run -S
@git` is rc 2 "unknown flag"; the working spelling is `gsa -S --dry-run
@git`, §B.1). Where a row writes `gsa --dry-run` standalone, read it as the
family-qualified form the fixture's action needs.

| fixture | pins | KEEP / REWRITE | new-contract target | phase |
| --- | --- | --- | --- | --- |
| `tests/abi-batch-policy.sh` | ABI-batch/soname-drift gate: omitted batch members and surface consumers refuse BEFORE dispatch; complete batches build; rustc probe stops dispatch and drains; gate probes memoised | KEEP: refusal-before-dispatch (:242-244, :850-852), probe-stop-drain (:356-361), gate boundary + negatives (:872-941), topology-data grouping (:531-645), gate cost (:1186-1245); REWRITE: argv ≈18 (`--audit`, `--topology`, `-i`, `-n`, `-l`, `--no-deps`; :122, :226, :350, :388), prose ≈13 (refusal/probe text :232-236, :368-370, :842-844), rr-format1 2 (:501, :506) | `gsa -S`/`-B`/`--dry-run`/`--leaf` (§B.4–B.8), `gsa -Ma` (§B.7), `gsa -Qt` (§B.3); refusals → `refuse` rows `abi-soname`/`abi-consumer-uncovered` (§E.2–E.3); `format: 2` scalars `outcome`/`rc` + outcome rows (§H.2); rc 3 (§G.1) | 3 (build+install gates); `-Qt` at 1, `-Ma` at 4 |
| `tests/abi-closure-lint.sh` | `--audit-lint abi-closure` over synthesized ELF archives: verdicts, findings naming both sides, exclusions wiring, report-only | KEEP: report-only rc 0 (:125, :145-146, :216-217, §E.4), finding meanings (:149-181), exclusions + loader rejection (:186-211), skipped≠clean (:123-127); REWRITE: argv 8 (`--audit-lint` :92, `--list` :205, `--audit` :215), prose ≈14 (:126, :147, :151, :218) | hidden `gsa --qa-check abi-closure` (§D.1), `gsa -Ma` (§B.7), `gsa -Sl` (§B.4); findings → §E.4 QA rows (refuse-severity as §E.2 rows) | 4 |
| `tests/abi-drift-install.sh` | `--install-decide <checked\|force>` provide-diff gate: moving/removed soname provide refuses, clean plans, in-run repair coverage, stock-pinner refusal | KEEP: decision meanings + rc 0/1 both modes (:290-311, :381-421, §E.5), gate semantics (:288-378), repair coverage (:542-663), stock-pinner refusal before any `pacman -U` (:667-727), seam non-mutation (:275-302); REWRITE: row-framing ≈13 (tab `plan_row` rows :293, :564, :691), argv 4 (:266, :410, :651, :719), prose 4 (:416, :723) | `gsa --install-decide <checked\|force> <archive…>` (§D.1); rows → `<pkgbase> <decision> <reason…>` (§E.2) `refuse abi-soname` / `refuse abi-consumer-uncovered` / `install` (§E.3); rc §E.5 unchanged | 3 |
| `tests/abi-exposure-audit.sh` | `--audit-lint abi-exposure` over a fabricated installed DB: provider→exposed-consumer rows, clean/skipped verdicts, report-only `--audit` | KEEP: report-only (:113-116, :164-166), finding meanings + bystander exclusion (:118-128), clean/skipped semantics (:138-150); REWRITE: argv 3 (:83, :164), prose 6 (:118-122, :141, :148, :167 incl. full-output equality) | `gsa --qa-check abi-exposure` (§D.1), `gsa -Ma` (§B.7); rows → §E.4 findings (refuse-severity → §E.2 rows) | 4 |
| `tests/abi-postinstall-probe.sh` | `-ia` pipeline post-install NEEDED probe: resolution semantics, loud abort on unresolved sonames, non-fatal skip, readelf preflight refusal | KEEP: probe runs post-transaction (:199-215, :321-322), unresolved aborts rc≠0 (:211-223 → §G.1 3), resolution semantics (:228-294, :365-393), skipped probe warning (:301-325), preflight refusal (:327-361); REWRITE: argv 4 (`-ia` :176, :351; `_IGNOREPKG_CONF` :169, :345), prose ≈13 (:216, :219, :317, :355) | `gsa -Ua` (§B.6), `--leaf` (§B.8); abort wording → `refuse` rows (§E.2–E.3) + rc 3 (§G.1); registration target gap G6 | 3 |
| `tests/anchor-defer.sh` | Anchoring failure (rc 99) defers one recipe: dependent parks, unrelated work builds, resume set = non-succeeded rows | KEEP: deferral≠failure (:144-148), parked never dispatched (:163-186), dispatch continues (:172-178), resume set (:204-206), named anchoring refusals (:296-308, :405-417); REWRITE: rr-format1 7 (:131, :135, :188, :204), prose ≈12 (:141, :159, :196, :208), argv 3 (:116, :287, :395) | outcome rows `deferred 99 anchoring-refused` / `parked - - waits-on-deferred` (§H.2–H.3), continuation `remaining:`/`command:` (§H.2), `--leaf` (§B.8), rc 5 (§G.1) | 2 |
| `tests/app-group.sh` | PTY `app` multi-select prompt: group selection, consumer expansion, unfiltered anchor indices, `app-cluster` rows, recorded selections | KEEP: loader errors (:143-157), non-TTY whole group + no upstream pull (:178-193), `-l` never prompts (:196-209), toggle semantics (:212-251), anchor positions (:240-280), `q` aborts (:255-258), mixed groups (:262-280), build subset+consumers (:305-313), cluster row behaviour (:324-383); REWRITE: rr-format1 ≈16 (:293-302, :349, :366), prose ≈18 (row parsers :99-137, :180, :337, :343), argv ≈15 (`--list`, `-l`, `-n`, `-g app`) | `gsa -Sl @app` (§B.4), `gsa -S @app --dry-run` (§B.8), `@`-namespace (§C.2), prompt + cluster carried (§C.4); `format: 2` scalars/rows (§H.2) | 2 (listing/prompt at 1) |
| `tests/bpftune-tuners-hook.sh` | bpftune-git libalpm hooks + restart script under stub systemctl: assets, checksums, phase decisions | KEEP: all (:31-89, :118-172) | n/a — no engine surface | no-flip |
| `tests/cleanup-extensions.sh` | `-ccc` deletion set vs root `.gitignore` pairing: downloads deleted, local assets/symlinks survive, report pipe-visible | KEEP: deletion/survival semantics (:85-100), report naming (:102-110), pairing invariant (:124-140); REWRITE: argv 2 (:80 `-ccc`; :122 fish-source grep of `_DOWNLOAD_ARCHIVE_EXTS`), prose 4 (:100, :108, :110) | `gsa -Mccc` (§B.7; prints targets, asks first, `--dry-run` rendering) with the extension set asserted from its target list, not fish source | 4 (source grep retires at 5, §6 R-2) |
| `tests/config-diagnostics.sh` | One broken loader input at a time: `--list` must reject naming the offending record/key/line | KEEP: all loader-validation behaviour (:48-181), helper smoke (:185-212); REWRITE: prose ≈13 (pinned error substrings :61, :85, :136, :170), argv 3 (`--list` :29/:199, `--audit` :206) | `gsa -Sl` (§B.4) as the loader driver, `gsa -Ma` (§B.7); rc 2 usage/malformed-config (§G.1) | 1 |
| `tests/cups-config-shim.sh` | `lib/cups-config` upstream-2.4 option semantics | KEEP: all (:23-40) | n/a | no-flip |
| `tests/dashboard.sh` | PTY dashboard: row fitting at 40/100 cols, cursor balance, prompt interrupt (exit 130 + SIGKILL escalation + child cleanup); plus the battery's single prose-rendering section | KEEP: width fitting (:133-173), cursor balance (:177-190), interrupt 130 + drain (:225-292, §G.1/§K.3); REWRITE: argv ≈12 (:89, :228, :373; incl. `_LANE_STOP_GRACE_S` :226 — gap G5), prose ≈15 (rendering section :356, :379, :384, :396, :414) | `--leaf` (§B.8), `gsa -Sl` (§B.4); counts/labels from `format: 2` vocabularies (`parked` §H.3, `remaining:` §H.2); tips name `--skip` (§B.9); rc 130 (§G.1); prose spec gap G9 | 2 |
| `tests/dbus-broker-meson.sh` | dbus-broker-git `build()` under stub meson: `meson setup --wipe` clears stale option state | KEEP: all (:58-68) | n/a (`GSA_FAKE_MESON_*` stubs are §D.2 fixture-side) | no-flip |
| `tests/fzf-pgo.sh` | fzf Go-PGO contract: training, profile wiring, floor/fallback, gate-last, release flags | KEEP: all (:50-95) | n/a | no-flip |
| `tests/glibc-package.sh` | glibc-git `.SRCINFO` content (splits/provides/deps), topology record content, `--topology`/`--dry-run` channels pinning linux-api-headers → glibc-git → gcc-snapshot order | KEEP: content pins (:21-48), topology row content (:46-48), split-output resolution + order (:55-68); REWRITE: argv 3 (`--topology` :45, `--dry-run` :52, :59), prose 2 (numbered-listing parsing :54, :61) | `gsa -Qt` (§B.3), `gsa -S --dry-run --leaf` / `gsa -Sl` (§B.8/§B.4); order from `format: 2` scalar `order` (§H.2) | 1 |
| `tests/gtk4-recipe-assets.sh` | GTK4 hook/script assets exist, tracked, not gitignore-hidden | KEEP: all (:10-28) | n/a | no-flip |
| `tests/ignorepkg-register.sh` | Dynamic IgnorePkg registration + hidden backfill seam: `[options]`-only closure, dated pre-image, idempotence, bounded db.lck wait, acceptance-time registration for builds/skip claims | KEEP: conf-mutation semantics (:503-671), N1–N8 ordering/idempotence/lock/refusal behaviours (:677-938); REWRITE: argv ≈7 (:195 `--register-ignorepkg`; run shapes :310-311, :877 `-s`, :903, :927 `-s -fi`), prose ≈18 (:522, :546, :598, :639, :709, :746-772, :904) | `gsa -Mi --backfill` (§B.7), hidden `gsa --install-register <conf> <subject> <names…>` (§D.1), `--no-register-ignorepkg` (§B.8); runs `gsa -S`/`-Sf`/`--skip` (§B.4/§B.8); target-conf gap G6 | 3 |
| `tests/install-archive-guard.sh` | Install pipeline discovery + skip semantics + decision sets via `--install-decide`: evaluated pkgver, same-version skip, split-set completeness, freshness compare | KEEP: discovery semantics (:117-178), missing-archive failure (:195-212), skip meanings (:263-323), `-s` build-skip (:325-373), unknown-version refusal (:375-418), split-set completeness (:557-622), ns freshness (:633-657), spaced paths (:659-672), refusal classes (:675-726), emit seam (:728-800); REWRITE: argv ≈20 (:93, :308, :334, :360, :379, :454), prose ≈16 (:124, :318, :390, :592, :690, :739-789), row-framing ≈12 (tab codec :431-438 + exact-plan asserts :496-534, :668) | `gsa --install-decide` (§D.1); rows → §E.2 grammar with `install` / `skip already-current` / `refuse empty-list` / `noop empty-list` / `refuse partial-set` / `refuse discover-failed` (§E.3); runs `gsa -S`, `-Uf`, `-Ua`, `--skip`, `--leaf` (§B.4–B.8) | 3 |
| `tests/install-conflict-ask.sh` | ONE `pacman -U --noconfirm --ask 4` transaction; `--overwrite` passthrough position; refusal rows stay pacman-free; spaced-archive argv integrity | KEEP: transaction shape (:105-111), passthrough (:118-123, §B.1 `--`), refusal-before-pacman (:148-195, §E.1), alpm.h pin (:200-208), argv integrity (:220-245); REWRITE: argv 7 (:88, :105, :118, :150, :175, :185, :235), row-framing 2 (:151-152, :176-177), prose 1 (:188) | `gsa --install-decide` (§D.1) rows (§E.2) `refuse empty-list` / `refuse pgo-*` (§E.3), rc 0/1/2 (§E.5); installs `gsa -U` / `gsa -Ua -- --overwrite '*'` (§B.6) | 3 |
| `tests/kernel-recipes.sh` | RETIRED 2026-10-29 (owner: recipe `misc/linux-cachyos` + the whole `misc` group removed from the tree) — was: verify-config expectation engine, linux-cachyos source/b2sums parse-time guard, pkgver↔tag scoping | n/a | n/a | n/a |
| `tests/local-db-repair.sh` | Hidden `--local-db-check` probe: report-only broken-entry semantics (never delete), holder identification, rc contract; plus fish source-wiring greps | KEEP: report-only never-delete (:95-177), holder identification (:117-137), no-deletion probe (:199-203); REWRITE: argv 2 (:89 seam invocation; :181-182 source grep), prose ≈12 (:104-112, :128, :132, :164, :174; :108 pins dropped `-s -i`/`-ia` spellings) | `gsa --local-db-check` (§D.1), `gsa -Md` local-DB report (§B.7); hints spell `gsa -U`/`gsa -S` (§B.6/§B.4) | 4 |
| `tests/log-ownership.sh` | Poisoned 0444 logs: quarantine-and-rebuild, dispatcher forensics across SIGINT, run-start stale-artifact sweep (staging exclusion), root-mode chown repair | KEEP: quarantine preservation (:83-122), dispatcher forensics (:140-183), sweep semantics + exclusion (:197-276), unremovable naming (:280-310), root repair (:487-536); REWRITE: argv 7 (:81, :146, :215, :259, :292, :487; :153 `--lane-job` pgrep argv), prose ≈11 (:90, :93, :120, :170, :303-307, :505-512) | `gsa -S --leaf` (§B.8), `gsa --lane-job <pkg> <result-path> <jobs> <flags…>` (§D.1), `-Ma`/`-Md` listings (§B.7), `format: 2` rows + reasons `log-unwritable`/`interrupted-mid-build` (§H.2–H.3), rc 130 (§G.1), ownership (§J.5) | 2 |
| `tests/logseq-desktop-recipe.sh` | logseq-desktop-git recipe contract + topology record via the engine channel | KEEP: all content (:12-117, :123-127); REWRITE: argv 1 (:122 `--topology`) | `gsa -Qt` (§B.3) | 1 |
| `tests/mkinitcpio-nvpcr.sh` | nvpcr patch applies; hooks tolerate absent optional files | KEEP: all (:31-58) | n/a | no-flip |
| `tests/modcache-check.sh` | `tools/go-modcache-check.sh`: damage classes, `--purge`, decoy survival | KEEP: all (:26-107) | n/a (host-side tool) | no-flip |
| `tests/noctalia-pgo.sh` | noctalia-git PGO fallback + training hygiene (process group, bounded teardown) | KEEP: all (:30-142) | n/a | no-flip |
| `tests/nvcheck-aggregator.sh` | `tools/nvcheck.sh` offline contract: config merge, resolvers, providers, digests, aggregate modes | KEEP: all (:23-412) | n/a today; if gsa absorbs version-sync these move to `gsa -Sy`/`-Sw` verdict rows (§B.4) — not flipped | no-flip |
| `tests/onlyoffice-recipe.sh` | onlyoffice-git recipe contract (namespaces, pins, assets, virtuals) + topology record/edges | KEEP: all content (:21-252); REWRITE: argv 1 (:227 `--topology`) | `gsa -Qt` (§B.3; row grammar `id\|path\|groups\|edges\|tags` unchanged) | 1 |
| `tests/pacman-mutex-shim.sh` | makepkg dep-pacman and `pacman -U` serialise on one mutex; argv passthrough; mutex timeout lands as a named failure | KEEP: serialisation (:147-156, §K.3), verbatim argv + read-only bypass (:176-210), timeout semantics (:211-278), child cleanup (:280-283); REWRITE: argv 2 (:122-127, :254-258), prose ≈9 (:130, :140-154, :218, :261), rr-format1 1 (:264 row regex — reason `mutex-timeout`, gap G3) | `gsa -S --leaf --no-sync …` (§B.4/§B.8); outcome row `pkg status rc dur reason…` (§H.2) reason `mutex-timeout`; mutex under `locks/` (§J.1), PACMAN shim kept (§K.3) | 3 |
| `tests/pgo-lib.sh` | `lib/pgo.sh` gate predicates + fatal semantics + bounded training | KEEP: all (:55-296) | n/a (sourced recipe module) | no-flip |
| `tests/pgo-payload-guard.sh` | Instrumented PGO payloads refused at install; clean payloads install; check read-only | KEEP: refuse semantics (:147-188), clean installs (:197-210); REWRITE: argv 1 (:144 `--installall`), prose 2 (:157, :161) | `gsa -Ua` (§B.6); row `<pkgbase> refuse pgo-* <detail…>` (§E.2–E.3); rc 1 seam / 3 run (§E.5/§G.1) | 3 |
| `tests/pgo-transition.sh` | PGO transition phases under stub build systems: instrument→profile-use, floor guard, LTO policy, gate-last | KEEP: all (:281-470) | n/a | no-flip |
| `tests/project.sh` | Reference resolution (typo/case/pkgname/split), range semantics, consumer expansion, strict loader errors, one failing run's continuation idempotence | KEEP: resolution semantics (:132-197), ranges (:258-344), expansion (:356-378, :553-694), loader validation (:437-478), topology channel shape (:486-499); REWRITE: argv ≈41 (:132, :186, :208, :270, :417), prose ≈17 (:135, :188-192, :328-329, :441-445, :548, :665), rr-format1 6 (:599-626) | `gsa -Sl @git`, `gsa --dry-run`, `gsa -Qt` (§B.3–B.4, §B.8); refs/ranges verbatim (§C.1/§C.3), typo rc 2 with candidates (§C.1); `format: 2` scalars + continuation `command:`/`remaining:` (§H.2) | 1 (continuation half at 2) |
| `tests/provides-audit.sh` | `tools/provides-audit.sh`: presence-only soname-provides rule, exit contract, non-mutation | KEEP: all (:61-138) | n/a | no-flip |
| `tests/recipe-contract.sh` | QA lints red/green per rule + real-repo debt ratchet + pkgbase/pkgname resolution via `--dry-run` | KEEP: lint meanings (:60-196), report-only (§E.4, :79-211), debt ratchet (:224-345), name surface (:390-441); REWRITE: argv ≈15 (:40 `--audit-lint`, :209 `--audit`, :414 `--dry-run`), prose ≈19 (:81, :98, :108, :146, :213, :346, :403) | hidden `gsa --qa-check <name> …` (§D.1), `gsa -Ma` (§B.7, report-only §E.4), §E.4 keyword rows; `gsa --dry-run <ref>` name surface (§C.1), unknown ref rc 2 (§G.1) | 4 (name-surface half at 1) |
| `tests/recipe-sources.sh` | Repo-wide local-source walk: exist+committed, FETCHED-ONLY semantics, ignore hygiene | KEEP: all (:47-230) | n/a | no-flip |
| `tests/resume-command.sh` | Failure summary's resume command preserves semantics flags, includes the failed package, records plan refusals, warns about ambient env | KEEP: resume-set behaviour (:56-73, :141-172), install/force semantics preserved (:78-128), partial-set refusal (:176-246), env warning (:248-261); REWRITE: argv 7 (:48, :208 + flag-spelling pins :83, :101, :106, :121, :227), prose 5 (:56, :60, :237, :242, :257), rr-format1 8 (:64, :69, :153-168, :216-221) | continuation `command:`/`remaining:`/`not-mirrored:`/`env-required:` (§H.2) with the §H.2 mirrored-flag list; install semantics carried by `gsa -S`/`-Sf` (§B.4); row `refuse partial-set` (§E.3); rc §G.1 | 3 |
| `tests/ripgrep-pgo.sh` | ripgrep PGO PKGBUILD: phase flags, floor guard, gate-last | KEEP: all (:44-113) | n/a | no-flip |
| `tests/run-record.sh` | Run-record machine block across success/failure/preflight/deferral/interrupt: block shape, scalars, row grammar, status enum, continuation | KEEP: one record on every exit path (:123-125), row order + rc semantics (:146-187), resume set (:190-192), preflight rows (:196-213), deferral semantics (:286-303), interrupt 130 + full record (:330-380); REWRITE: argv 6 (:113, :120, :166, :204, :282, :330), prose 2 (:81, :374), rr-format1 ≈38 (:127 `format == 1`, :129-144 scalars, :154-187 rows, :286-303, :357-367) | `format: 2` scalars (§H.2), outcome rows `pkg status rc dur reason…` (§H.2), `parked` + `waits-on-deferred` (§H.3), continuation (§H.2); exit codes §G.1 (cone-stop+failure → 4, deferral-only → 5, preflight → 3); fail-fast scenarios now pass `--fail-fast` (§I.3) | 2 |
| `tests/rust-recipe.sh` | rust-git recipe pins (`!lto`, rust-src, template, DESTDIR wipe) | KEEP: all (:19-72) | n/a | no-flip |
| `tests/scheduler-core-solo.sh` | Core member runs alone with the core job budget; normals overlap on the normal budget | KEEP: all scheduling invariants + budgets (:175-273, §K.2), MAKEFLAGS/`GSA_BUILD_JOBS` (:204-221); REWRITE: argv 2 (:141-146, :245-249), rr-format1 2 (:152-153 scalars) | `gsa -S --leaf …` (§B.8); scalars `normal-jobs`/`core-jobs` (§H.2); lane budget (§K.1) | 2 |
| `tests/scheduler-dispatch-order.sh` | `build-tools` dispatch band + closed six-name roster: band-first, edges win, plain plan order | KEEP: band semantics (:173-185), edges win (:215-233), plan order (:256-278), closed roster + dual-count (:117-148), cleanup (:95-104); REWRITE: argv 8 (:116, :125, :130, :256), prose 6 (:74, :79, :121-124, :145-147), rr-format1 6 (:183-188, :267, :276) | `gsa -Sl @build-tools` / `@build-tools @core` (§B.4/§C.2), `gsa --dry-run` (§B.8); scalar `order` + outcome rows (§H.2); loader errors rc 2 (§C.2/§G.1) | 2 (roster half at 1) |
| `tests/scheduler-intensity.sh` | Each `--intensity` level's lanes/normal-jobs/core-jobs plan, per-lane `-j` export, failing run's drain/resume invariants | KEEP: job export (:67-69, §B.8 `GSA_BUILD_JOBS` output), artifact cleanup (:77, :135), drain + resume set (:88-121), continuation intensity (:123-128), child cleanup (:130); REWRITE: argv 3 (:48, :125), rr-format1 7 (:53, :60, :97, :102, :111) | `gsa -S --leaf --no-sync --intensity <lvl> …` (§B.4/§B.8); scalars `lanes`/`normal-jobs`/`core-jobs`/`intensity`/`outcome`/`rc` (§H.2); continuation (§H.2) | 2 |
| `tests/signal-abort-lock.sh` | 17 sub-tests: stale-lock probe, `--lane-job` signal honesty, dispatcher INT/TERM/HUP forensics, busy-lock preflight, run lock/orphans/watchdog, second-signal escalation, result-wire gates, pre-dispatch abort | KEEP: probe never-deletes + classifications (:403-478, §D.1), signal honesty (:487-525, §F.2), ONE TERM + grace + SIGKILL (:376-393, :577-603, §K.3), busy-lock refusal (:605-644, → §G.1 3), run lock (:690-793), watchdogs (:794-880), second-signal sweep (:882-937), result-wire gates (:658-688, :939-1033), pre-dispatch abort (:1064-1155); REWRITE: argv ≈30 (:275, :403, :487, :614), rr-format1 8 (:499 wire regex → §F.2 `v2 <pkg> <code> <dur> <reason…>`; :527-530, :566, :953-985, :1104-1121), prose ≈45 (:410-412, :519, :572, :620, :703, :864, :910, :1006) | `gsa --stale-lock-check`, `gsa --lane-job <pkg> <result-path> <jobs> <flags…>` (§D.1; flag grammar gap G10), lane codec (§F.2), `format: 2` rows (§H.2) with `signal-term`→status `interrupted` (§H.3), run rc 130 for interrupts (§G.1 — today's 130/143/129 signal-carried statuses remap) | 2 |
| `tests/skip-upstream.sh` | Upstream-aware `--skip`/`--skip-built`/`--vcs-skip-tolerance`: freshness tolerance, ABI-provider waivers, VCS baseline/manifest integrity, transport deferral/park | KEEP: skip semantics (:422-446), skipped-build still installs (:428-433), baseline integrity (:452-496), transport deferral + park (:609-648), fallback chain (:674-700), tolerance gates (:730-830, :1444-1487), ABI-provider waivers (:832-900), `--skip-built` semantics (:1056-1443, :1530-1590); REWRITE: argv ≈45 (:269-270, :428, :941, :947, :1461), rr-format1 ≈20 (:396, :630, :755, :857, :1265), prose ≈10 (:415, :622, :680, :825, :1567) | `gsa -S --skip`/`--leaf` (§B.8), `gsa -Mc`/`-Mcc` (§B.7), `--skip-built`/`--vcs-skip-tolerance` (§B.8), `gsa --help` roster (§B.8); rows `deferred`/`parked`/`succeeded` + reasons `upstream-unverified`/`skip-built`/`freshness-waived`/`abi-provider-waived` (§H.3); rc 5/4 (§G.1) | 2 |
| `tests/srcinfo-freshness.sh` | `.SRCINFO` staleness sweep over the topology channel; synced build whose `--printsrcinfo` fails surfaces the refresh failure twice, non-mutating | KEEP: staleness detection (:31-63), sync+refresh attempt (:143-146), failed-refresh non-mutation (:141, :155-160); REWRITE: argv 2 (:53 `--topology`; :135-137), prose 3 (:148, :151, :153) | `gsa -Qt` (§B.3), `gsa -B --leaf --intensity low s1` (§B.5/§B.8); wording under §H.1 renderings / §I.4 loud reporting (gap G9) | 2 (topology argv at 1) |
| `tests/stable-sync-checksums.sh` | Version-sync + checksum-anchoring build across stubbed providers: anchoring, refusals, rollbacks, deferrals | KEEP: anchoring (:529-560), refusal-before-makepkg + restore (:561-623), refresh-failure deferral (:624-692), no-rewrite guards (:693-734, :883-914), provider semantics (:735-1012, :1300-1696), rc behaviour (:407-412 → §G.1 3/5); REWRITE: argv 4 (:396-397, :690, :1616 `-ccc`, :1628 `-ln`), rr-format1 8 (:1034, :1058, :1287), prose ≈60 (:553-688) | `gsa -S --leaf --intensity low` (§B.4/§B.8), `gsa -Mccc`/`gsa -Mm` (§B.7), continuation (§H.2), outcome rows `failed`/`deferred` (§H.2–H.3), rc 3 integrity / 5 deferral (§G.1) | 2 (`-ccc`/`-ln` sites at 4) |
| `tests/sudo-keepalive.sh` | Four sudoers shapes on a virtual clock: nopasswd keeps building, cold refuses pre-build, expiry stops once and drains, TTY changes nothing | KEEP: all four behaviours (:156-280, §K.3 "never prompts"), resume set, drain (:282); REWRITE: argv 2 (:132-134, :248-249), rr-format1 8 (:168, :190, :194, :213-223, :273-278), prose 6 (:152-153 used at :162-260) | `gsa -S --leaf …` (§B.4/§B.8; `--install` retires into `-S`); preflight `sudo cannot install non-interactively` (§G.1 rc 3); rows + `remaining:` (§H.2); `never-started preflight-refused` (§H.3) | 3 |
| `tests/swap-completeness.sh` | Swap QA lint over fabricated `pacman -Qi` DB: counterpart completeness, suffix/soname guards, pkgbase inheritance, report-only verdicts, debt ratchet | KEEP: lint semantics (:89-357), report-only rc 0 (§E.4, :87-313), debt ratchet (:262-292); REWRITE: argv 3 (:86, :251, :269), prose ≈28 (:104, :113, :123, :254, :318-321) | `gsa --qa-check swap` (§D.1), `gsa -Ma` (§B.7, report-only §E.4); finding strings re-pin to gsa output (clean-slate §B.9, gap G9) | 4 |
| `tests/texlive-recipe.sh` | texlive-texmf recipe assets/metadata/splits/hooks + topology record; builder cleanup-ext coverage for svn clones and `.whl` | KEEP: content clusters (:33-167), topology record content (:170-174); REWRITE: argv 1 (:169 `--topology`), prose 2 (:176-177, :182-183 fish-source greps) | `gsa -Qt` (§B.3); svn/`.whl` coverage asserted from `gsa -Mccc` target rendering/`--dry-run` (§B.7) | 1 (cleanup-ext greps retire at 5 / re-pin at 4) |
| `tests/texlive-split.sh` | Frozen-legacy vs live `prepare()` split loop: identical trees, spawn budget, batched renames, depletion refusal | KEEP: all (:213-295) | n/a | no-flip |
| `tests/toolchain-drift.sh` | Compiler-identity drift overrides `-s` and cleans stale LTO objects; unchanged identity skips and preserves | KEEP: all (:80-125); REWRITE: argv 2 (:64-68, :80) | `gsa -S --leaf --no-sync …` + `--skip` (§B.8) | 2 |
| `tests/toolchain-remediation.sh` | Failing rustc sanity probe force-builds the at-risk chain (narrow → core escalation), holds consumers, refuses only when remediation fails | KEEP: force-build ordering (:218-352), escalation policy (:266-278), loud probe (:199-216), refusal-on-remediation-failure (:329-355, → §G.1 3); REWRITE: argv 5 (:154, :185, :245, :295, :326), rr-format1 2 (:219, :223), prose ≈23 (:193, :199-212, :256, :333) | `gsa -S --leaf --no-sync llvm-git p2` (§B.4/§B.8; `-i`→`-S`); `format: 2` scalars/rows (§H.2–H.3); messaging (§I.4); rc §G.1 | 2 |
| `tests/vencord.sh` | vencord-git recipe + inject scriptlet + topology record + `.SRCINFO` freshness | KEEP: all content (:17-322); REWRITE: argv 1 (:165 `--topology`) | `gsa -Qt` (§B.3) | 1 |
| `tests/vulkan-pair.sh` | vulkan-headers version-pin derivation and `.SRCINFO` agreement | KEEP: all (:32-50) | n/a | no-flip |
| `tests/zen-pgo.sh` | zen-browser-pgo workload patch + recipe hygiene | KEEP: all (:20-163) | n/a | no-flip |

## 5. Counts

- **Fixtures inventoried: 56** (discovery, §0). Phase tally: no-flip 19,
  Phase 1: 6, Phase 2: 15, Phase 3: 10, Phase 4: 6; Phase 5 retires across
  all.
- **Engine-coupled assertion sites to rewrite: ≈874** — argv 299, prose 409,
  `rr-format1` 139, row-framing 27 (per-site estimates from the four
  inventory passes; "≈" where a fixture repeats one shape). All 409 prose
  sites stop being byte-equality pins: under §L.3/§L.5 their meanings re-pin
  as record-derived assertions, with prose byte-pinned in exactly one
  rendering test (gap G9).
- **Assertions retired without replacement: 13 sites in 3 classes** (§6 R-1
  … R-3), plus the retired-as-spelling set (§6 R-4/R-5) whose behaviour
  re-pins.

## 6. Retired without replacement (Phase 5)

These assertions are deleted at cutover with **no v2 assertion of any kind**
checking the same thing:

- **R-1. Fish-implementation source-shape greps (9 sites).** gsa is a shipped
  binary; there is no engine source to grep and no find(1)-shaped walk to
  pin. The behaviour each guarded is separately kept (cited) and re-pins
  behaviourally at its flip:
  - `tests/local-db-repair.sh:181-196` — `--local-db-check` existence and
    `check_pacman_db_health`/`pacman_db_local_path` wiring greps (probe
    behaviour keeps at :95-203).
  - `tests/log-ownership.sh:338-350` — `find -prune` vs `-not -path`
    sweep-implementation greps (staging-exclusion behaviour keeps at
    :235-276).
  - `tests/signal-abort-lock.sh:367-393` (`stop_lane_process` /
    `_LANE_STOP_GRACE_S` shape), `:533-547` and `:646-652` (`.pacman-shim`
    artefact shape / `"$@"` passthrough — the PACMAN shim itself is carried
    by §K.3 and keeps, only the fish artefact pins go), `:686`
    (`write_lane_result … unknown` source grep).
  - `tests/cleanup-extensions.sh:122` and `tests/texlive-recipe.sh:176-183` —
    `_DOWNLOAD_ARCHIVE_EXTS` / svn-regex source pins (coverage re-pins from
    `gsa -Mccc` target rendering).
- **R-2. format:1-only row grammar (1 site).**
  `tests/run-record.sh:60-62` — the single-token reason rule of the
  `format: 1` row codec; §H.2 makes the reason the remainder of the line and
  `rr2_body` enforces the v2 shape.
- **R-3. Flag-existence pins for flags the contract drops (3 sites).**
  `tests/resume-command.sh:82-86`, `:100-108`, `:227-228` — existence of
  `--install`/`--forceinstall` spellings inside the resume command. §B.9
  drops both flags (install-before-dependents is `-S`'s semantics); the kept
  behaviour (a resume preserves install/force semantics) re-pins as the
  `command:` line restating `-S`/`-Sf` (§H.2).

Retired **as a spelling** (behaviour re-pins; listed for the Phase 5 pass):

- **R-4. `blocked` status-name pins (4 sites):**
  `tests/anchor-defer.sh:188`, `tests/run-record.sh:48`, `:293`,
  `tests/skip-upstream.sh:630`. §H.3 supersedes `blocked` with `parked`
  (reason `waits-on-deferred`); the rows re-pin via `rr2_outcome`.
- **R-5. Tab-framed row equalities (row-framing class, 27 sites):** e.g.
  `tests/abi-drift-install.sh:89-94` (the `planrow` codec),
  `tests/install-archive-guard.sh:431-438`, `tests/install-conflict-ask.sh:151-152`,
  `:176-177`. §E.2 replaces tab framing with positional `<pkgbase> <decision>
  <reason…>` rows; the row *meanings* keep and re-pin through the §E.2
  parser, and the tab codec has no v2 form.

## 7. Semantic-equivalence harness — DESIGN ONLY (not implemented)

Purpose: prove that for the same scenario the fish engine and `gsa` produce
the same *normalized outcome*, so a per-fixture flip can be validated against
the engine it replaces. This wave specifies the shape only; no harness file
is written.

- **Scenario input** (one declarative record per scenario):
  - workspace: synthetic topology records + one-line PKGBUILDs (+ staged
    archives/conf where the scenario installs), built with
    `make_workspace`/`add_package` (tests/lib/fixture-lib.bash);
  - stub set: which `bin/` stubs are installed (makepkg/sudo/pacman/date/…)
    and their `GSA_FAKE_*` knob values (declared in tests/lib/rr-v2.bash);
  - selection: targets / `@set` / ranges / `--leaf`, and the action
    (build-only / build+install / install-only / listing), modifiers
    (`--skip`, `--skip-built`, force, prune strength) as neutral intent;
  - per-engine argv maps: fish = today's spellings (the fixtures' current
    call sites), gsa = §B grammar; the map itself is the §B.9 disposition
    table.
- **Runner shape:** `tests/engine-equivalence.sh` (discovered) sourcing
  `tests/lib/equiv-lib.bash` (sourced-only), driving `run_engine` twice per
  scenario (`GSA_TEST_ENGINE=fish` and `=gsa`) over two independent
  `$TMPDIR` workspace clones with identical stubs.
- **Normalized outcome tuple** (what must be equal):
  1. exit class ∈ {success, usage(2), refusal(3), failure-cone(4),
     failure-fast(1), deferral-only(5), interrupted(130)} — gsa via §G.1;
     fish mapped through the documented remap (its rc classes are
     engine-coupled, the class is behaviour);
  2. decision rows: ordered `(pkgbase, decision, reason-key)` triples,
     decision ∈ §E.3 {install, skip, refuse, noop, parked}, detail after the
     reason key stripped;
  3. outcome rows: ordered `(pkg, status, rc-class, reason-key)` tuples —
     `dur` dropped, fish's `blocked` normalized to `parked`, statuses per
     §H.3, rc normalized to the §F.1 lane code;
  4. `remaining`: the ordered non-succeeded pkg list (both engines' own
     declaration vs the rows-derived set must agree first —
     `rr2_remaining` vs `rr2_continuation remaining`).
- **Equivalence rule:** tuples equal after the remap table (§B.9 + §G.1 +
  §H.3); any other divergence fails naming the scenario and the tuple field.
- **Phasing:** the harness lands with Phase 2 (the first phase where both
  engines run full scenarios); the fish side freezes at cutover and the
  harness retires with the fish engine in Phase 5.

## 8. Contract gaps found

Dispositions for every numbered item below (fixed / fixed-by-amendment /
closed-by-documentation / deferred-with-rationale) live in
`docs/gsa-contract.md` §M (2026-10-14) — this section stays the gap
inventory only, so the two never drift apart.

Each item names the `docs/gsa-contract.md` section that is silent. No
semantics were invented for these; where a fixture must pin something
affected, the inventory says so and `tests/lib/rr-v2.bash` records the strict
reading it takes.

1. **§E.3 (decision row vocabulary) — silent on the in-run ABI repair row and
   the stock-pinner refusal.** `tests/abi-drift-install.sh:564` pins a
   `repair <arch> …` row and `:691-692` a `refuse abi-stock-pinner …` reason;
   §E.3 lists `abi-soname`, `abi-consumer`, `abi-consumer-uncovered` but
   neither of these.
2. **§H.2 (scalars) — no value vocabulary for the run-level `outcome`
   scalar** (the `format: 1` set was success|failed|interrupted; §H.4 shows
   only `failed`), and no grammar for the `selection-source` value
   (`sets=@git leaf=no range=-` is example-only). The parser treats both as
   opaque scalars.
3. **§H.3 (reason keys) — silent on reasons fixtures pin:** `mutex-timeout`
   (tests/pacman-mutex-shim.sh:264), `result-clear-failed`
   (tests/signal-abort-lock.sh:982-985), and the signal reason keys
   `signal-term`/`signal-hup`/`signal-int`
   (tests/signal-abort-lock.sh:527-530) versus §H.3's single
   `interrupted-mid-build`. §L.2 allows additive reason keys, so these parse
   today; the contract simply never names them.
4. **§B.8 vs §H.4 — `--leaf=no` is not a defined spelling.** The annotated
   continuation (`command: gsa -S --leaf=no …`, `selection-source: … leaf=no
   …`) uses a negated `--leaf` form that §B.8 does not define, and §H.2's
   flag-rule table never says how a negated boolean is mirrored in
   `command:`.
5. **§K.3 — the teardown grace window has no knob.** "starts a shared grace
   window" with no flag, seam or env name; `tests/dashboard.sh:226` and
   `tests/signal-abort-lock.sh` tune today's `_LANE_STOP_GRACE_S`, which has
   no §D.1/§B.8 successor.
6. **§B.8/§D.1 — the IgnorePkg registration target conf is unnamed.**
   Nothing says which `pacman.conf` an `-S`/`-U` run's dynamic registration
   rewrites (today the `_IGNOREPKG_CONF` fixture seam,
   tests/lib/fixture-lib.bash `make_install_conf`). `--config PATH` (§B.8) is
   defined as a pacman global, never as the registration target;
   `--install-register <conf> …` (§D.1) names its conf only for the isolated
   seam.
7. **Phase mapping — the contract assigns none.** The five phases come from
   `plan-native-pm.md` §7 via the owner's brief; in particular the `-M` band
   (`-Ma`, `--qa-check`, `-Md`, `-Mi`, `-Ml`, `-Mm`, `-Mc/-Mcc/-Mccc`) and
   the QA severity seam (§E.4) have no contract-stated phase. This inventory
   assigns them Phase 4.
8. **§H.1/§H.2 — preflight-refusal block shape.** §H.1 emits the block on the
   preflight-refusal path; §H.2 never says whether that block carries plan
   rows. The strict parser requires the §H.2 full shape (one row per selected
   package, matching `order`) on every path.
9. **§L.5 — no v2 prose spec.** Prose is "pinned in exactly one rendering
   test", but the contract defines no summary/dashboard wording (§I.4 lists
   what must be NAMED, not how). The single rendering test cannot be written
   from the contract alone; all other prose sites retire as byte-pins (§6).
10. **§D.1 — `--lane-job`'s `flags…` payload grammar is undefined.** The
    shape `<pkg> <result-path> <jobs> <flags…>` is given, but not the flag
    tokens; `tests/signal-abort-lock.sh:487` pins today's 8-positional fish
    payload and `:994-1062` its validation (`-j N` re-export, control-char
    rejection).
11. **§B — workspace discovery is unstated.** Nothing says how `gsa` locates
    the workspace (cwd vs. config-relative). `run_engine`
    (tests/lib/rr-v2.bash) runs gsa with the workspace as cwd until the
    contract says otherwise.
12. **§H strictness decisions taken where the contract is silent** (recorded,
    not invented; each is loud, never silent): blank lines and control
    characters inside the block are rejected; duplicate scalars, plan rows,
    outcome rows and continuation keys are rejected; plan and outcome rows
    must agree with the `order` scalar (§C.5 grounds one topological order
    but §H.2 does not state the cross-check); `rc` must be the row status's
    §F.1 lane code or `-` (§H.3/§G.2 ground the code sets); all four sections
    are required (the §H.2 grammar shows them unconditionally). An unknown
    continuation key is rejected (the §H.2 continuation key set is closed);
    extension scalars after the fixed set are accepted (§H.2 says so).

Two inventory notes that are not contract gaps: the fixture count "55" in the
contract preamble is stale (56, §0), and the `GSA_FAKE_*` vocabulary table
exists twice during staging (fixture-lib.bash for fish-era fixtures,
rr-v2.bash for v2 fixtures) — the two-table window closes at Phase 5 when
fixture-lib.bash's engine-era content retires (§3).
