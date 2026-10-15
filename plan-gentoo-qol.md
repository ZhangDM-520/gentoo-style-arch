# plan-gentoo-qol.md — Gentoo build-QoL mechanisms: research report + adoption plan

**Question answered:** how does Gentoo (Portage / eclasses / infrastructure) improve
build QoL, and which of those mechanisms should gentoo-style-arch adopt?
**Status:** research + plan only. No implementation. Nothing in this file changes
any recipe, topology record, or builder code.

**Scope note:** fetch-ahead / prefetch-while-compiling is deliberately excluded —
it is owned by the sibling `plan.md` (repo root); this document mentions Portage's
`FEATURES=parallel-fetch` only in passing and plans nothing around it.

**Source conventions.** Gentoo claims cite primary material inline (PMS, GLEPs,
Portage man pages and source). Wiki-only facts are marked *(secondary)*. Our own
claims cite `docs/NOTE.md` / `docs/MEMORY.md` by date/section. Two corrections to
the brief's source list are in "Source corrections" below — read them before
trusting any GLEP number by heart.

---

## 1. TL;DR

Gentoo's build QoL comes from a handful of *data* mechanisms, not from flags:
(1) **sub-slots + `:=` + `@preserved-rebuild`/`preserve-libs`** make ABI moves a
package-manager-managed, atomic, self-healing event instead of a hand-assembled
surgery; (2) **binary packages as first-class artifacts** (buildpkg/usepkg/getbinpkg,
the `Packages` index, `binpkg-multi-instance`, signed gpkg containers) mean an
unchanged package is never rebuilt and a network outage is a cache miss, not a
wall; (3) **failure-shaped scheduling** (`--keep-going`, `--resume` history,
per-package logs) turns partial failure into a resumable state; (4) **drop-in QA
at the install seam** (`install-qa-check.d`, `strict`/`stricter`) and a **check
registry** (pkgcheck) keep recurring breakage classes out permanently; (5) **live
package sets** (`@live-rebuild`) and version-bump tooling make "what moved?"
a cheap query instead of a run.

We already invented several of these by hand (our `abi=must` tags and heal-set
transactions are a hand-rolled `:=`/`@preserved-rebuild`; our `-s` baselines are a
hand-rolled binpkg index). The plan below adopts the *shapes* Portage gives them,
without importing Portage's dependency resolver — which we deliberately do not have.

### Ranked shortlist

| # | Mechanism (Gentoo source) | One-line value for us | Verdict |
|---|---|---|---|
| 1 | **ABI token + `:=`-style subscriptions + heal-set wave** (sub-slot, `:=`, `@preserved-rebuild`) | A soname/ABI move auto-expands and composes the exact rebuild wave — no more hand-built ICU/tcl/LLVM surgeries | adopt (adapt) |
| 2 | **Staged atomic swap + last-known-good retention** (`preserve-libs` analogue) | The running system is never mid-broken: old provider survives until the whole wave lands in one `pacman -U`, and rollback is an archive, not a rebuild | adopt |
| 3 | **Archive index + install-from-archives mode** (`Packages` index, `usepkgonly`, `binpkg-multi-instance`) | `-s` currency, install discovery and provenance read one build-time index (epoch bugs die), and N previous builds stay usable without rebuilding | adopt (adapt) |
| 4 | **Cone-stop failure mode + resume-list hygiene** (`--keep-going`, `--resume`, `emaint cleanresume`) | One failed package parks its dependent cone and the run continues and reports — without weakening today's fail-fast default | adopt (opt-in) |
| 5 | **Pluggable install-seam QA + check registry** (`install-qa-check.d`, `strict`/`stricter`, pkgcheck keywords) | Every recurring breakage class gets one named, reusable check instead of another one-off lint | adopt |
| 6 | **Stale-set query + version-sync skew lint** (`@live-rebuild`, euscan/pkgcheck git checks) | "What moved upstream since the last build?" becomes a cheap read-only answer before committing hours of building | adopt (small) |
| 7 | **Host-state hygiene verbs** (`emaint logs/cleanconfmem/merges`) | Log retention and stale IgnorePkg pruning stop being manual archaeology | adapt (small) |
| 8 | **Admission guards: disk + load** (`--jobs-tmpdir-require-free-gb`, `--load-average`) | A 652-package run fails at dispatch time instead of filling the disk or melting an undervolted laptop mid-wave | adopt (tiny) |

### Open questions for the owner (answer these first)

1. **ABI token source of truth.** Should the rebuild trigger token be *derived*
   (the shipped bare-soname provide set, hashed — `makepkg` already auto-versions
   provides) or *declared* (an explicit `abi-rev=` tag on topology records, bumped
   by hand like `SLOT`/sub-slot)? Derived is drift-free but noisy (rule 30: "soname
   beats pkgver", `docs/MEMORY.md:603`); declared is precise but is exactly the
   hand-work we are trying to remove. My lean: derived token *plus* an optional
   declared override for cases like LLVM snapshots where no soname moves but the
   C++ ABI does (`docs/MEMORY.md:234`).
2. **Failure default.** Should the cone-stop `--keep-going` mode become the
   default for long unattended runs, or stay opt-in? Today's fail-fast default is
   load-bearing: it stopped the 09-06 rust-git-against-old-llvm class from
   compounding (`docs/MEMORY.md:185`, rule 11). The plan proposes opt-in; say so
   if you want it default for `-g core` waves.
3. **Archive retention budget.** `binpkg-multi-instance` implies keeping several
   builds per recipe. How much disk? (The laptop already has a 38 GB single
   package landmine, `docs/MEMORY.md` §2 "Landmines" texlive entry.) Keep last
   N=2 instances? Keep only provider/hub recipes multi-instance?
4. **Where the QA gate line sits.** `Audit lint` is report-only *by contract*
   (`CONTEXT.md`), while the PGO/ABI install gates are fail-closed. For the new
   install-qa-check.d-shaped seam: is one class of checks allowed to refuse an
   install (like `refuse abi-soname` today), and if so, is that decided per check
   or by a severity attribute?
5. **Index integrity level.** Is a hash-bound archive index (manifest-v2-style
   sha256+size, written by the builder) enough, or do you want a GLEP-78-shaped
   signed index/manifest so an index swap is detectable? (We are single-host;
   signing mainly buys tamper-evidence of runtime state.)

---

## 2. Per-mechanism sections

### M1. Sub-slots, `:=` subscriptions, `@preserved-rebuild` — ABI moves as data

**What Gentoo does.** `SLOT` may carry a sub-slot, `slot/subslot`; PMS: "The
sub-slot is used to represent cases in which an upgrade to a new version of a
package with a different sub-slot may require dependent packages to be rebuilt"
(PMS §7.2, https://projects.gentoo.org/pms/9/pms.html). Consumers *subscribe* to
that with slot operators (PMS §8.3.3, same URL): `:=` means "any slot is fine, but
the package will break unless a matching package with slot *and sub-slot* equal to
the best installed version's slot/sub-slot is available"; `:*` means "will not
break if replaced in a different slot". When a package with `:=` subscribers is
upgraded to a different sub-slot, the package manager records the slot/sub-slot
pair at build time (PMS §8.3.3: "the package manager will need to store the
slot/sub-slot pair of the best installed version") and schedules those consumers
for rebuild — `emerge --verbose-slot-rebuilds` "list[s] which packages are causing
rebuilds" (emerge(1), https://manpages.gentoo.org/emerge.1). The devmanual makes
the practice explicit: "When made aware of ABI breakage, change the subslot …
consumers which link against a library possessing a subslot that represents SONAME
or binary compatibility should subscribe to it … with `:=`", and recommends
libabigail/abi-compliance-checker to *detect* breaks
(https://devmanual.gentoo.org/general-concepts/slotting/, "Sub-slots" and
"ABI breakage"). Note the origin story: slot operators and sub-slots are an
**EAPI 5** feature ("Slot operator dependencies, slot-operator-deps", "SLOT now
supports an optional sub-slot part", PMS EAPI 5 changelog) — the design record is
PMS + the devmanual, not a GLEP (see "Source corrections").

**Which of our pains it addresses.**
- The soname-swap class: `spandsp-git`'s `libspandsp.so.2→4` mid-run refusal
  (`docs/NOTE.md:665-691`, 2026-10-06) and the `icu` 78→79 wave where pacman
  correctly refused `libicuuc.so=78-64` consumers (`docs/NOTE.md:852-887`) are
  exactly `:=`-subscription rebuilds that Portage computes and we assemble by hand.
- pkgver lying about ABI: "Soname beats pkgver in ABI bookkeeping"
  (`docs/MEMORY.md:603-620`, rule 30) is the same lesson the devmanual states
  ("the sub-slot does not have to strictly be the SONAME") — the token must be
  ABI truth, not version truth.
- Hand-maintained coupled batches: LLVM waves (rule 13, `docs/MEMORY.md:234-252`),
  Qt private-API passes (rule 5, `docs/MEMORY.md:82-85`), the tcl 8.6→9 victim
  wave (`docs/NOTE.md:190-226`) are `abi=must` tags + human memory.
- The 23 missing `icu` build-order edges found only after the incident
  (`docs/NOTE.md:852-887`, "Topology") and the four missing compiler edges
  (`docs/NOTE.md:369-408`) are the "record the dependency at build time" half.

**Concrete mapping.**
- *Token:* each built archive already records its provides; extend the
  per-archive manifest-v2 baseline (sha256+size, `docs/build-guide.md`
  "Skip and resume") with a **`abi-token`** = hash of the sorted bare-soname
  provide set actually shipped (read from `.PKGINFO` + `readelf -d` payload
  scan — the machinery exists in `abi_provide_refusals` /
  `audit_lint_abi_closure`, `docs/MEMORY.md:483-520`, rule 25). Optional
  topology override `abi-rev=<n>` on the provider record for non-soname ABI
  moves (LLVM C++ ABI, Qt private tags).
- *Subscription:* topology edges already say "A consumes B"
  (`CONTEXT.md`, "Build-order edge"). Add nothing to the graph; instead, when
  provider P's abi-token changes vs the installed/baseline token, **auto-expand
  the wave** = P's transitive consumers (existing consumer expansion) ∪
  {installed packages pinning P's moving provides} — the second half is the queued
  blind-spot fix "the guard should consult the local DB's reverse deps of the
  moving provide and name the stock-side consumers"
  (`docs/MEMORY.md:1203-1212`, §5 "ABI provide-refusal blind spot").
- *Scheduling:* the wave is dispatched as today's `abi=must` batch — same
  selection semantics, but derived, and the existing generic gate ("refuses a real
  build whose selection omits an installed `abi=must` batch member",
  `docs/MEMORY.md:234-252`) then fires on *derived* membership too.
- *Reporting:* a `--verbose-slot-rebuilds`-style plan line: "libicu-git 78→79
  forces rebuild of {libxml2-git, raptor, …}" in the run record before dispatch.

**Effort / risk.** M (the ABI seams exist; derivation + wave planner + fixtures
are the work). Risks: over-expansion (a hash over the whole provide set churns on
unrelated changes — hash only bare-soname stems), and fixture blast radius at the
install-plan seams (the queue entry itself warns, `docs/MEMORY.md:1203`).
**Verdict: adopt (adapt).** This is the single highest-value mechanism; it
automates the exact class of four incidents from 2026-10-06 alone.

### M2. `preserve-libs`, `@preserved-rebuild` — protecting the running system mid-upgrade

**What Gentoo does.** `FEATURES=preserve-libs`: "Preserve libraries when the
sonames change during upgrade or downgrade. Libraries are preserved only if
consumers of those libraries are detected. Preserved libraries are automatically
removed when there are no remaining consumers. Run `emerge @preserved-rebuild` in
order to rebuild all consumers of preserved libraries"
(https://manpages.gentoo.org/make.conf.5, FEATURES). `@preserved-rebuild` is a
shipped set driven by `PreservedLibraryConsumerSet`
(https://github.com/gentoo/portage/blob/master/doc/config/sets.docbook). Removal
safety is mirrored in `--depclean-lib-check` ("Account for library link-level
dependencies during --depclean and --prune … if preserve-libs is enabled … any
libraries that have consumers will simply be preserved", emerge(1)). Net effect:
an ABI swap never breaks a *running* system mid-transaction; the old soname file
survives until every consumer is rebuilt, then disappears automatically.

**Which of our pains it addresses.** The ICU wave's asymmetry — "long-running
processes keep running on deleted inodes while every NEW exec dies at the loader"
(`docs/MEMORY.md:603-620`, rule 30(b); `docs/NOTE.md:480-512` noctalia
"PAM start failed") — is precisely what preserve-libs prevents. Our current
defence is procedural: stage the new provider, heal-build consumers against the
stage, retire leftovers, one `pacman -U` of the whole set (`docs/NOTE.md:852-887`,
`docs/NOTE.md:665-691`; rule 25(d) "never install a moving/removed soname provide
with part of its consumer closure outside the transaction",
`docs/MEMORY.md:483-520`). It works and is done by hand.

**Concrete mapping.** pacman/ALPM has no preserve-libs; emulate its *contract*:
1. **Staged provider becomes a builder verb**, not an ad-hoc `/tmp` ritual:
   `install_plan` gains a `wave` shape — "build consumer cone against staged
   provider (its `.pc` prefix/libdir rewritten), then one `pacman -U` of
   provider+cone" — turning the ICU/spandsp playbook into the install plan
   (`CONTEXT.md`, "Install plan": decide once, execute separately).
2. **Last-known-good retention**: before an ABI-token change is installed, keep
   the previous archive instance (see M3 retention) as the rollback artifact —
   the ICU recovery path required rebuilding/downgrading from `/var/log/pacman.log`
   archaeology (`docs/MEMORY.md:234-252`, rule 13 recovery paragraph).
3. **`@preserved-rebuild` analogue**: the wave's pending consumer set is already
   in the run record as `blocked`/`waits-on-deferred`; give ABI-waiters the same
   named treatment (`waits-on-abi-wave`) so the continuation command lists them.

**Effort / risk.** M. Risk: staging `.pc` rewrites are recipe-family-specific
(the spandsp `libdir` trap, `docs/NOTE.md:665-691`) — the verb must fail closed
when it cannot rewrite a provider's link metadata. **Verdict: adopt.** Cheap
because the procedure exists and is tested by scars; the value is that it stops
being tribal knowledge.

### M3. Binary packages: buildpkg / usepkg / getbinpkg / `Packages` / binpkg-multi-instance / quickpkg

**What Gentoo does.**
- `FEATURES=buildpkg` ("Binary packages will be created for all packages that are
  merged"), `buildpkg-live` (skip binpkgs for live ebuilds unless enabled),
  `buildpkg-proactive` (make.conf(5), https://manpages.gentoo.org/make.conf.5);
  `quickpkg` builds a binpkg from *installed files* without rebuilding
  (https://manpages.gentoo.org/quickpkg.1).
- Consumption: `emerge --usepkg/-k`, `--usepkgonly/-K`, `--getbinpkg/-g`,
  `--getbinpkgonly/-G` against `binrepos.conf` or `PORTAGE_BINHOST`
  (emerge(1); portage(5) documents `binrepos.conf` with `sync-uri`, `priority`,
  `frozen = yes` ("use the most recently cached copy of the remote index … to
  guarantee consistent and reproducible dependency calculations"), per-repo
  `verify-signature`, per-repo `location`).
- Staleness control: `--binpkg-respect-use` and `--binpkg-changed-deps` are
  auto-enabled unless `--usepkgonly`, so a binpkg built with different USE flags
  or stale deps is not silently reused (emerge(1)).
- Index: `emaint binhost` "Generate a metadata index for binary packages located
  in PKGDIR (for download by remote clients)"
  (https://manpages.gentoo.org/emaint.1) — the `Packages` index clients fetch
  instead of probing files.
- Multi-instance: `FEATURES=binpkg-multi-instance` — "support for multiple binary
  package instances per ebuild … retaining builds that were built with different
  USE flags or linked against different versions of libraries" (make.conf(5));
  GLEP 78 documents it as an xpak-era extension now carried into gpkg
  (https://www.gentoo.org/glep/glep-0078.html, "Motivation").
- Verification: GLEP 78 defines the `gpkg` container: uncompressed `.tar`
  containing `gpkg-1` magic, `metadata.tar*` (first, so metadata is
  *partially fetchable*), `image.tar*`, and a `Manifest` covering every member,
  OpenPGP-signable ("For a binary package to be considered signed and suitable for
  authenticity verification, the Manifest file must be present and contain a valid
  signature"), plus self-checksumming ("able to detect its own data corruption").
  GLEP 74 (https://www.gentoo.org/glep/glep-0074.html) is the full-tree Manifest
  format reused for this ("This GLEP extends the Manifest file format to cover
  full-tree file integrity and authenticity checks"). `BINPKG_GPG_SIGNING_*` /
  `BINPKG_GPG_VERIFY_*` knobs exist in make.conf(5).

**Which of our pains it addresses.**
- `-s` skip of fresh archives is "our crude `--usepkgonly`" and its discovery is
  brittle: the epoch drop (`docs/NOTE.md:889-907`) — a perfectly good
  `ninja-git-2:1.13.2…` archive unmatched because filename matching re-derived
  the version from PKGBUILD evaluation instead of reading a record of the build.
- Partial split sets skipping (manifest-v2 currency, `docs/build-guide.md`
  "Skip and resume"; `docs/MEMORY.md` rule 11's `list_split_pkgs` refusal) is our
  hand-rolled "binpkg completeness" check.
- Upstream outages walling runs (`docs/NOTE.md:2056-2090`, 2026-10-02; and the
  excluded fetch wall in `docs/NOTE.md:266-296`) — with a usable local archive
  set + index, `-s` runs mostly need *verification*, not network.
- Provides drift against archives: "provides live in .PKGINFO … verify artifacts"
  (`docs/MEMORY.md:42-81`, rule 4) is our weak analogue of a binpkg metadata
  header; GLEP 78's point is that this metadata is a *first-class, readable,
  updatable member* of the artifact.

**Concrete mapping.**
1. **Archive index** (runtime state beside archives, like VCS baselines): one
   row per built instance: `pkgbase|pkgname…|full-version(epoch:pkgver-pkgrel)|archive-sha256|abi-token|provides|vcs-baseline|built-at`. Written by the builder at
   successful build; read by `-s`, install discovery (`current_archives`),
   `--audit`. The epoch class of bug becomes "index row is authoritative" —
   discovery no longer re-evaluates `pkgver()` to guess filenames.
2. **Retention (binpkg-multi-instance-lite)**: keep the previous instance of
   provider/hub recipes (the ones with `core` membership or ≥2 consumers,
   `docs/MEMORY.md:420-452` rule 21) instead of deleting archives on rebuild;
   cap by count (owner Q3), not by disk guess.
3. **Install-from-archives mode** (`--usepkgonly` analogue): install exactly the
   index-complete set without building — the escape hatch for a host with a walled
   upstream and a full local cache (our `-s -i` nearly is this; make it a
   first-class mode that refuses if any selected package lacks a current instance).
4. **quickpkg analogue — skip.** Our archives are built, not repacked from the
   live root; repacking installed files would break payload verification (PGO
   gate sits before makepkg strips, `CONTEXT.md` "PGO gate").

**Effort / risk.** Index: M. Retention: S. Install-from-archives: S (reuses
`install_plan`). Risk: index/archive divergence (index must be written only after
manifest-v2 baselines land; treat a missing row as "not built", fail closed like
today). **Verdict: adopt (adapt).** Signature on the index (GLEP 78 style) is the
owner's Q5 — skip it by default (single-host runtime state).

### M4. Build QoL flags & scheduling: keep-going, jobs, load-average, logs, niceness, ccache/distcc

**What Gentoo does.**
- `--jobs=N` builds N packages concurrently; with >1 job, "all build output [is]
  redirected to logs"; `--load-average=LOAD` starts no new builds above LOAD;
  `--jobs-tmpdir-require-free-gb` (default 18 GiB) refuses new jobs when
  PORTAGE_TMPDIR is low (emerge(1), https://manpages.gentoo.org/emerge.1).
- `--keep-going`: "Continue as much as possible after an error. When an error
  occurs, dependencies are recalculated for remaining packages and any with
  unsatisfied dependencies are automatically dropped" (+ `--skipfirst`).
- `--quiet-build`/`--quiet-fail`: hide build output; on failure echo the log
  (path + die message when multiple failures) (emerge(1)).
- `--resume`/"-r": reuses the aborted merge list's arguments; "resume history is
  capable of storing two merge lists"; lists live in `/var/cache/edb/mtimedb`;
  `emaint --fix cleanresume` discards them (emerge(1)).
- `--fetchonly/-f` / `--fetch-all-uri/-F`: fetch without building (emerge(1)).
- `FEATURES=keepwork` keeps `${WORKDIR}` but the man page itself warns "Due to
  lack of proper cleanup, this feature can interfere with normal emerge operation
  and therefore it should not be left enabled for more than a short period of
  time" (make.conf(5)) — an upstream-endorsed statement of our stale-tree pain.
- `nostrip`/`splitdebug`/`installsources` (debug info handling),
  `PORTAGE_NICENESS` ("added to the current nice level"), `CCACHE_DIR`/
  `CCACHE_SIZE` + `FEATURES=ccache` (with the caveat "ccache will retain stale
  code objects … Unless you are doing development work, do not enable ccache"),
  `FEATURES=distcc` (make.conf(5)). Icecream is not a Portage feature; it is
  distcc-shaped tooling configured outside Portage *(secondary: wiki "Icecream")*.

**Which of our pains it addresses.**
- Dispatch-stop-on-failure is deliberately fail-fast ("failures stop new
  dispatches while draining existing lanes", `docs/architecture.md`) — correct
  for interactive waves but expensive in unattended 652-package runs: one defect
  (`docs/NOTE.md:889-907` epoch) stranded everything behind it (run rc 1,
  dispatch stopped at package 1).
- Deferral already implements the *good* half of `--keep-going` for non-failures
  (`docs/NOTE.md:2056-2090`; `CONTEXT.md`, "Deferral": dependents wait, dispatch
  continues, run exits non-zero).
- Stale build trees are a documented pain class (rules 6 and 33,
  `docs/MEMORY.md:86-128`, `:625-668`) — the `keepwork` warning validates that
  our aggressive-clean default is the right side of the trade.
- ccache: our LTO/GCC-identity invalidation already exists because stale objects
  poison builds (`.state/toolchains/` identity markers, `docs/architecture.md`
  §4); ccache would add a second, larger stale-object cache. Skip.

**Concrete mapping.**
1. **Cone-stop mode (opt-in `--keep-going`)**: on a *failed* package, mark its
   consumer cone `blocked(reason=waits-on-failed)` — the deferral vocabulary
   already exists — stop only that cone, keep dispatching independent work, and
   put the whole blocked set in the continuation command. Same run-record rows,
   one new reason class. Default stays fail-fast (owner Q2).
2. **Admission guards (shortlist #8)**: before first dispatch, compute free disk
   at the recipe-local PKGDEST/SRCDEST roots and refuse/`--intensity`-down when
   below a `config/build-defaults.conf` threshold; expose a load-average ceiling
   knob the lane scheduler honours (today: lanes+jobs+memory budgets only).
3. **Resume-list hygiene (shortlist #4, second half)**: run records already
   survive; add a bounded history (two-deep, like mtimedb) and a
   `cleanresume`-shaped housekeeping verb (see M6).
4. **Skip:** `nostrip`/`splitdebug`/`installsources` (they fight makepkg's strip
   point and our pre-strip PGO gate), `ccache`/`distcc`/icecream (second stale
   object cache; distcc on an undervolted laptop is anti-QoL), `--fetchonly`
   (fetch half is the sibling `plan.md`'s territory).
   `PORTAGE_NICENESS`-equivalent is one scheduler line if the host needs it (S).

**Effort / risk.** Cone-stop M (dispatch invariant + fixtures pin failure shapes);
guards S; resume history S. Risk: cone-stop masks systemic breakage if made
default (see 09-06 history). **Verdict: cone-stop adopt opt-in; guards adopt;
niceness adopt as a knob; the rest skip.**

### M5. QA & maintenance tooling: pkgcheck, repoman history, install-qa-check.d, revdep-rebuild, etc-update/dispatch-conf, emaint, glsa-check

**What Gentoo does.**
- **Install-time QA as drop-ins:** Portage ships `bin/install-qa-check.d/` scripts
  (`10executable-issues`, `10ignored-flags`, `80libraries`, `80multilib-strict`,
  `90world-writable`, `95empty-dirs`, … — file list from
  https://github.com/gentoo/portage/tree/master/bin/install-qa-check.d) run at
  merge time; `FEATURES=strict` "react[s] strongly to conditions that have the
  potential to be dangerous (like missing or incorrect digests)" and `stricter`
  to "conditions that may conflict with system security provisions (for example
  textrels, executable stack)", each overridable per-class via `QA_STRICT_*`
  variables (make.conf(5)). `FEATURES=qa-unresolved-soname-deps` warns when a
  package installs files with unresolved sonames (make.conf(5)).
- **pkgcheck** is the current check engine (repoman's successor): `pkgcheck scan`
  over a repo, checks as a registry with named result keywords, extendable by
  optional deps (git for commit-history checks, requests for network checks) —
  https://github.com/pkgcore/pkgcheck (README, `src/pkgcheck/checks/` modules:
  `git.py`, `metadata.py`, `metadata_xml.py`, `profiles.py`, `stablereq.py`,
  `visibility.py`, `cleanup.py`, `glsa.py`, `network.py`, …). Checks include
  commit-vs-version-bump checks and stablereq tracking. Repoman is legacy (still
  named in emerge(1)'s `--digest` text) and has been retired from current
  workflows in favour of pkgcheck/pkgdev.
- **Runtime health:** `emaint` (https://manpages.gentoo.org/emaint.1): `binhost`
  (regenerate the binary package index), `cleanresume` (discard `--resume` lists),
  `logs` (apply `PORTAGE_LOGDIR_CLEAN`), `merges` ("Scan for failed package merges
  and attempt to fix those failed packages"), `moveinst`/`movebin` (package moves),
  `cleanconfmem` ("Discard no longer installed config tracker entries"), `world`.
- **Config files:** `dispatch-conf` and `etc-update` handle `CONFIG_PROTECT`ed
  files at upgrade: prompt/update/zap/merge with rollback archives ("changes to
  config files are stored either using patches or rcs",
  https://manpages.gentoo.org/dispatch-conf.1); etc-update even supports
  pacman-family hosts (https://manpages.gentoo.org/etc-update.1).
- **Removal safety:** `revdep-rebuild` (gentoolkit) is recommended by emerge(1)
  after `--depclean` for link-level breakage; `--depclean-lib-check` covers
  library link deps at removal.
- **Security stream:** GLEP 57 defines the security-distribution model
  (https://www.gentoo.org/glep/glep-0057.html); `@security` is a shipped set
  ("uses NewAffectedSet", i.e. GLSA-affected installed packages —
  `doc/config/sets.docbook`); `glsa-check` (gentoolkit) drives it.
- **Tinderbox-style CI:** continuous full-tree rebuild farms *(secondary: wiki
  "Project:Gentoo tinderbox"/QA herd pages)* — the practice is "always be
  rebuilding the world in a disposable environment and triaging failures".

**Which of our pains it addresses.**
- Recurring breakage classes keep needing *new* lints: provides-versioning,
  purged tools, provides swaps, ABI closure/exposure (the report-only audit
  lints, `docs/MEMORY.md:149-184` rule 9 end + `:483-520` rule 25), plus
  post-install NEEDED probes (`docs/NOTE.md:822-850`). Each was added after an
  incident; nothing ensures the next class lands as a *check* rather than a
  one-off.
- The IgnorePkg registration dance (`docs/NOTE.md:932-1011`;
  `docs/MEMORY.md:149-184` rule 9) is our CONFIG_PROTECT story, already solved
  transactionally — but stale entries accumulate when packages are retired (the
  `gst-plugin-pipewire` retirement, `docs/NOTE.md:665-691`, left nothing to prune
  it).
- Retiring trimmed outputs needs link-level awareness ("retire, never rebuild;
  sweep `expac -Q '%n\t%D'`", rule 29, `docs/MEMORY.md:593-602`) — the
  `--depclean-lib-check`/revdep-rebuild question in tool form.
- Full builds *are* our tinderbox: runs #3–#30 on 2026-10-06
  (`docs/NOTE.md:40-1011`) are exactly triage-from-world-rebuild.

**Concrete mapping.**
1. **Check registry (shortlist #5):** give audit lints and install-gate checks a
   shared declaration surface — name, scope (recipe/topology/host/install),
   severity (`report` | `refuse`), and stable keyword for fixture pinning — the
   `install-qa-check.d` shape: drop a script into `lib/checks/`, it is discovered,
   and the seam runs it at the right point (pre-dispatch, post-build payload,
   pre-install plan). Existing code (`lib/audit.fish`, `pgo_payload_refusals`,
   `abi_provide_refusals`) migrates behind declarations without behaviour change.
2. **`qa-unresolved-soname-deps` analogue** already exists (`install_needed_probe`
   + `audit_lint_abi_exposure`); port its *report* into the registry so it runs
   at both audit and install time (rule 25(b)/(e) semantics preserved,
   including the "file truth beats provide set" fallback,
   `docs/NOTE.md:822-850`).
3. **Hygiene verbs (shortlist #7):** `emaint logs` = retention policy for
   `.state/logs/` (age-based, named, opt-out); `cleanconfmem` analogue =
   `--prune-ignorepkg` that removes IgnorePkg names no archive/recipe claims any
   more (with the dated pre-image discipline of rule 9); `merges` analogue =
   a `--doctor` that reconciles lane results, run-record continuity and quarantined
   logs (`docs/MEMORY.md` rule 19 quarantine semantics).
4. **Retire-audit:** before a trim/retirement, a read-only revdep scan of the
   local DB (like `--depclean-lib-check`) naming exact-pin leftovers — codifies
   the `expac` sweep of rule 29.
5. **Skip:** glsa-check/@security (we track upstream movement through
   version-sync, not advisories; a GLSA pipeline needs an advisory feed we do not
   have), repoman (superseded), dispatch-conf (ALPM has no CONFIG_PROTECT file
   class to dispatch; our problem was package *clobbering*, already solved by
   dynamic IgnorePkg).

**Effort / risk.** Registry M (seams are fixture-pinned — argv shapes "ARE the
contract", `docs/MEMORY.md` §6 pitfall digest, 2026-10-05 entry); hygiene verbs S; retire-audit
S. Risk: severity creep toward gating (owner Q4). **Verdict: registry adopt;
hygiene verbs adopt; retire-audit adopt; rest skip.**

### M6. Live packages & version tracking: `@live-rebuild`, PROPERTIES=live, bump tooling

**What Gentoo does.** PMS defines `PROPERTIES`: "`live` — The package uses 'live'
source code that may vary each time that the package is installed"
(PMS §7.3.5, https://projects.gentoo.org/pms/9/pms.html). Portage ships
`@live-rebuild` — "Installed ebuilds with 'live' property" (a `VariableSet` over
`PROPERTIES`) — plus `@deprecated-live-rebuild` (old eclass-based heuristic):
https://github.com/gentoo/portage/blob/master/cnf/sets/portage.conf and
`lib/portage/_sets/__init__.py`; the NEWS entry records the switch
("The @live-rebuild package set now searches for PROPERTIES=live … bug 233589",
https://github.com/gentoo/portage/blob/master/NEWS, portage-2.3.70). So "which of
my installed packages are inherently volatile?" is one set query, and rebuilds are
`emerge @live-rebuild`. `buildpkg-live` keeps live ebuilds out of the binpkg cache
by default (make.conf(5)) — live builds are explicitly *not* reusable artifacts.
For version bumps of non-live packages, the ecosystem uses pkgcheck
(commit-vs-bump checks, stablereq) and euscan (upstream version scanning — a
separate tool, https://github.com/euscan/euscan *(secondary: tool's own site)*).

**Which of our pains it addresses.**
- "What is stale?" is currently answered only by *doing* the run: `-s` resolves
  refs mid-build and defers on outage (`docs/build-guide.md` "Skip and resume";
  `docs/NOTE.md:2056-2090`). There is no cheap pre-run answer for "which of the
  653 recipes moved since their archive".
- Version-sync skew: "the set's version-sync tracks gitlab.archlinux.org packaging
  *main* … while released `extra` still ships 8.6.16" — half-migrated tcl/tk walled
  run #23 (`docs/NOTE.md:190-226`). That is "testing vs stable channel drift", the
  exact thing Gentoo's keywording + stablereq machinery tracks.
- The `-git` recipes are all "live" in PMS terms; our `git` group is our
  `@live-rebuild` already (`CONTEXT.md`, "Group").

**Concrete mapping.**
1. **`--stale` query (shortlist #6):** read-only pass that, for each selected
   record, resolves declared VCS refs / nvchecker provider and prints
   `id|recorded-baseline|current-ref|stale?` — the `@live-rebuild` set as a report,
   without building. It reuses `lib/sources.fish`'s `vcs_remote_revision` with
   today's transport-retry/defer classification, so an outage answers
   "unknown", never "stale".
2. **Skew lint:** extend `--audit` with a `version-sync-skew` check comparing the
   synced source (gitlab packaging main) against the *released* repo state when
   both are known — flag "tk 9.0.1 but no tcl 9 provider in set/released"
   as a named finding before a run does.
3. **Skip:** `@deprecated-live-rebuild`-style heuristics, `buildpkg-live`
   semantics (our `-s` baseline/VCS-revision binding is stricter and better).

**Effort / risk.** S–M (mostly plumbing existing functions into a query). Risk:
network cost of a 653-record sweep (batch like the `--audit` batching precedent,
`docs/NOTE.md:1149-1174`). **Verdict: adopt (small).**

### M7. Configuration model: USE, package.env, EMERGE_DEFAULT_OPTS, licenses, keywords, world

**What Gentoo does.** USE flags are dependency-style, per-package feature
declarations consumed at build time, with profile
use.mask/use.force and per-package `package.use` overrides; per-package *env*
overrides live in `/etc/portage/package.env` → `/etc/portage/env/` files with
make.conf syntax ("When environment variable settings are all that's needed,
package.env is the recommended approach", portage(5),
https://manpages.gentoo.org/portage.5). `EMERGE_DEFAULT_OPTS` bakes defaults into
every invocation (make.conf(5)). Licenses: `LICENSE` uses DEPEND-style syntax,
license groups (`@FSF-APPROVED` etc.), `ACCEPT_LICENSE`, per-package
`package.license`; unaccepted licenses behave like masks (GLEP 23,
https://www.gentoo.org/glep/glep-0023.html). Keywords: `ACCEPT_KEYWORDS` +
`package.accept_keywords` gate testing/stable per package (portage(5)); the world
file (`/var/lib/portage/world`) records wanted atoms; `--depclean` removes
installed packages outside `@world`'s dependency tree (emerge(1)).

**Which of our pains it addresses (and mostly does not).** We have no resolver,
no channel mask, and our feature decisions are recipe-local trims with `# trim:`
annotations (rule 8, `docs/MEMORY.md:129-148`) — a poor man's USE, deliberately
visible in the recipe. The one real overlap: per-recipe flag surgery that is host
policy, e.g. glibc's `-fuse-ld=bfd` which "is a per-recipe decision (never
`/etc/makepkg.conf`)" (rule in the mold pitfall,
`docs/MEMORY.md` §6 2026-10-03 entry) — package.env exists precisely to hold such
knobs out of recipes.

**Concrete mapping.** Minimal, by choice:
1. *Adapt (S):* if per-recipe host knobs multiply, add a `config/package.env`-ish
   override table the builder exports to makepkg per recipe ID — a home for
   toolchain/flag exceptions separate from recipes. Today's count (one: bfd-for-
   glibc) does not justify it; record as a trigger-based decision.
2. *Skip:* USE machinery, keyword masking, world-set semantics (our topology *is*
   the world), license acceptance gating (our LICENSE/LICENSES/REUSE material is
   attribution, `docs/architecture.md` §1, and nothing here is redistributable —
   README: "not redistributable binaries").

**Effort / risk.** S if triggered. **Verdict: skip now (trigger: third per-recipe
host knob).**

### M8. Failure reporting & observability

**What Gentoo does.** Per-ebuild logs in `PORTAGE_LOGDIR` with timestamped names
`${CATEGORY}<sep>${PF}<sep>YYYYMMDD-HHMMSS.log`, retained/cleaned by
`FEATURES=clean-logs` + `PORTAGE_LOGDIR_CLEAN` (default: drop logs ≥7 days old),
`binpkg-logs`/`unmerge-logs` extend coverage, `compress-build-logs` compresses
while writing (make.conf(5)). With `--jobs`/`--quiet-build`, failures print "the
paths of the log files … together with the corresponding die messages" instead of
dumping every log (emerge(1)). `--fail-clean` removes temp files after failure
(recommended together with PORTAGE_LOGDIR). `emerges --merges` repairs failed
merges; `--resume` continues aborted runs (above).

**Which of our pains it addresses.** Our run record is already the "one seam,
three renderings" answer (`docs/architecture.md`, `CONTEXT.md` "Run record") and
per-package logs exist (`.state/logs/`, ownership rules in `docs/MEMORY.md` rule
19). The gaps are small: unbounded log retention; and the "n failed, N
never-started" outcome shape of the epoch wall (`docs/NOTE.md:889-907`) where the
run record correctly said what happened but nothing could cheaply continue
independent work (M4 cone-stop) or reuse built archives (M3).

**Concrete mapping.** Log retention (in M5 hygiene verbs). Everything else is
covered by M3/M4. **Verdict: adopt retention only; skip the rest as already
solved or owned by M3/M4.**

---

## 3. What we deliberately do NOT copy

- **The dependency resolver.** emerge's depgraph (dynamic deps, slot solving,
  blockers, `--complete-graph`, USE-dep evaluation) is the one mechanism we have
  explicitly replaced with a hand-wired build-order graph over assumed-installed
  prerequisites (`CONTEXT.md`, "Build-order edge"/"Consumer expansion"). Nothing
  in this plan requires slot solving; the M1 wave planner reads *records and the
  local DB*, never re-derives a solvable graph.
- **Slotting / parallel-install of multiple versions** (devmanual "Slotting") —
  pacman installs one version per name; `binpkg-multi-instance` is adopted only
  as artifact retention, never as concurrent installs.
- **USE flags, profiles, keyword masking, package.mask/unmask** — configuration
  state we would have to invent a resolver for. Trims stay as annotated recipe
  code (rule 8).
- **A signed repository/Manifest tree (GLEP 74/57/58)** — we are one maintainer's
  checkout, not a distribution channel; source authenticity is per-artifact
  (`validpgpkeys`, checksum anchoring — rules 15/28), which is the layer the
  GLEPs themselves put under the tree layer.
- **Binary package *distribution* (binhost hosting, gpkg signing, partial
  fetch).** Packages here are host-tuned and not redistributable (README); we
  adopt the index/retention shape, not the transport/signing layer (owner Q5 may
  revisit).
- **glsa-check/@security, news items (GLEP 42), dispatch-conf CONFIG_PROTECT
  menus** — no advisory stream, no user-facing config-file class, no users.
- **`FEATURES=keepwork` as a mode** — the man page's own warning matches our
  stale-tree scars (rules 6/33); we keep aggressive clean-on-drift.
- **ccache/distcc/icecream** — see M4: a second stale-object cache next to our
  GCC-identity markers is risk, not QoL.
- **fetch-ahead/prefetch-while-compiling** (`FEATURES=parallel-fetch` shape) —
  owned by sibling `plan.md`, not researched here.

## 4. Source corrections (the brief's GLEP numbers were wrong)

- **GLEP 55 is not slot operators.** GLEP 55 is "Use EAPI-suffixed ebuilds
  (.ebuild-EAPI)" and is **Rejected** (Council 2010-08-23 / 2012-05-08;
  https://www.gentoo.org/glep/glep-0055.html). Slot operators + sub-slots are
  **EAPI 5 PMS features** (PMS §7.2/§8.3.3 + PMS EAPI-5 changelog,
  https://projects.gentoo.org/pms/9/pms.html) with practice guidance in the
  devmanual's Slotting page. Cite those, not GLEP 55.
- **Licenses are GLEP 23** ("Handling of ACCEPT_LICENSE",
  https://www.gentoo.org/glep/glep-0023.html), not GLEP 61/75. GLEP 61 is
  "Manifest2 compression"; GLEP 75 is "Split distfile mirror directory
  structure". (GLEP 57 "security" and GLEP 68 "Package and category metadata"
  and GLEP 74 "Full-tree verification using Manifest files" and GLEP 78 "binary
  package container format" were correct.)
- **`FEATURES=preserve-logs` does not exist** in Portage (absent from make.conf(5)
  and zero hits in the gentoo/portage source tree). The real log features are
  `binpkg-logs`, `unmerge-logs`, `compress-build-logs`, `clean-logs` +
  `PORTAGE_LOGDIR(_CLEAN)`. Likewise there is no `FEATURES=qa`; QA checks run at
  merge time and `strict`/`stricter`/`QA_STRICT_*` govern their severity.

## 5. Out of scope and unknowns

- **Out of scope:** anything fetch/prefetch-related (sibling `plan.md`);
  pacman/ALPM changes (we can only orchestrate around it); making packages
  redistributable; a real resolver; multi-host builds; signing infrastructure.
- **Unknowns / follow-up research if an owner question demands it:**
  - Whether `expac` can enumerate soname-level reverse deps cheaply enough for
    the M1 wave planner at 1748-package scale (the 2026-10-03 audit worked, but
    was batched by hand — `docs/NOTE.md:1991-2054`).
  - How often a *derived* abi-token would fire on rolling `-git` providers where
    the soname is stable but headers move (Qt private API, `docs/MEMORY.md:82-85`)
    — likely needs the declared `abi-rev=` override; measure on one LLVM wave
    before committing.
  - Whether the fixture battery can absorb cone-stop without re-pinning every
    failure-shape scenario (the battery has been performance-tuned recently,
    `docs/NOTE.md:40-88`); spike one scenario first.
  - gpkg/OpenPGP index signing (owner Q5): if chosen, GLEP 78's Manifest-member
    model is the shape; effort is L and mostly key management.
- **Assumptions made:** the plan treats `docs/MEMORY.md` + `docs/NOTE.md` as
  ground truth for pain; "adopt" never means "change pacman behaviour"; all
  proposed seams are builder-side (build-all.fish / lib/ / config/ / docs/).
