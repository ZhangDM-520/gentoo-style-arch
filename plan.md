# Plan — fetch-ahead while compiling (prefetch upcoming sources in the background)

**Status: PLAN ONLY — nothing below is implemented. No code changes accompany this document.**

## TL;DR

Today the scheduler fetches each package's sources only when its lane runs `makepkg`
at dispatch time; one flaky upstream wall (TLS `unexpected eof` from
`src.fedoraproject.org`, `www.apache.org`, `ftp.gnu.org`/pagure) kills the package,
stops dispatch, and drains the run — even though retries or a mirror would have
served the bytes minutes earlier. The plan: the dispatcher keeps a **bounded
lookahead window** over the plan (topological) order and, while lanes compile,
spawns **one-shot fetch children** (`--fetch-job`, same process-boundary house
pattern as `--lane-job`) that run `makepkg --verifysource` per upcoming recipe —
download + checksum + PGP verify into the shared SRCDEST cache, with zero pacman
or sudo involvement. A prefetch failure is **purely advisory**: it warns, logs, and
lets the lane's own fetch remain the authoritative gate at build time. One fetch in
flight at a time, niced, disk-floor-gated, and killed with the run on any signal —
the signal fixtures set that bar. No new verification code is written anywhere: the
worker reuses `makepkg --verifysource` and `lib/sources.fish` source classification;
checksums, `validpgpkeys`, `#signed` are never weakened.

---

## Open questions for the owner (decide these first)

1. **Opt-in or default-on?** Recommendation: **default-on** with a `--no-prefetch`
   opt-out (prefetch is advisory and cannot fail a run, so on-by-default is safe),
   plus an optional `--prefetch-ahead N` (default 8). Every new flag/env knob must
   land in `--help`, `docs/build-guide.md` "Environment surface", the continuation
   rule table (`build-all.fish:7039-7075`) and a fixture pin — so the *minimal*
   alternative is: default-on, no knob at all (window = documented constant). Which
   surface do you want? (`GSA_PREFETCH_AHEAD` env would also need the ambient-knob
   warning list in `print_run_summary`, `build-all.fish:7192-7206`.)
2. **PGP at fetch time or deferred to build time?** Recommendation: **verify at
   fetch time** — `makepkg --verifysource` runs `check_checksums` *and*
   `check_pgpsigs` (`/usr/share/makepkg/integrity.sh:32-50`), so a missing signing
   key or bad signature surfaces ~minutes before the lane needs the source instead
   of at the wall. Note this makes prefetch advisory results include PGP failures
   caused by the known keyring-gap class (MEMORY rule 15) — arguably *more* early
   warning. Deferring PGP is not free either: it would mean a different fetch path
   than `--verifysource`, i.e. reimplementing verification (forbidden).
3. **VCS sources in v1 or phase 2?** Recommendation: **phase 2** — v1 prefetches
   only recipes with ≥1 plain-URL source (per-source classification via
   `lib/sources.fish:1148-1237`, fixing `seed-ahead.sh`'s crude "any `git+` anywhere
   in the file" skip). Pure-`-git` recipes get their mirrors from the build itself /
   `--link-sources`, and prefetching into *shared canonical mirrors* (the
   `SHARED-SRCDEST` gnulib×7 cluster) can race a lane's own `download_git`
   (`git fetch --all -p` into a mirror another makepkg is reading). Mixed recipes
   (e.g. `apr-util`: tarball + `.asc` + local patch) are prefetched in v1 and may
   update their own VCS mirror as a side effect of `--verifysource` — acceptable,
   or do you want them excluded too?
4. **What may prefetch do when a cached file fails its pin?** Discovered hazard
   (see §3.5): makepkg keeps a bad file at its final name ("Found %s"
   `/usr/share/makepkg/source/file.sh:29-37`) and re-verifies it forever
   (`verify_checksum.sh:117-122` exits 1 without deleting) — one corrupt/tampered
   download walls *every* future attempt, lane build or prefetch. Options:
   (a) prefetch quarantines the named file (`.gsa-bad-<ts>` suffix) and retries once
   — still pin-anchored, the recipe's checksum/PGP remain the trust anchor; or
   (b) prefetch only warns and never moves cache bytes (strictest "never touch what
   you don't own", but leaves the wall standing). Recommendation: (a), loudly.
5. **Operator surface for prefetch warnings** — recommendation below (§3.4) is:
   prose summary section + `$LOG_DIR/prefetch.log` + an *additive* machine-block
   scalar `prefetch-warnings: N` (which the fixture grammar already tolerates as a
   `key: value` scalar — `tests/lib/fixture-lib.bash:374-389`). Adding real
   **run-record rows** would mean a `format: 2` bump and fixture migration; I advise
   against rows because a prefetch failure is not an outcome of the package build.
   ADR 0003 governs this call — if the scalar is adopted, record it in a short
   ADR 0004 (or a 0003 addendum).
6. **Window size default** — 8 upcoming recipes (constant `_PF_WINDOW`), 1 fetch in
   flight. With ~15–30 min builds and seconds-to-minutes fetches, 8 deep ≈ 1–2 h of
   runway. Bigger windows spend more disk before it is needed (linux-firmware-class
   sources are GB-scale). Do you want it adjustable (Q1) or fixed?

---

## 1. Problem statement + evidence

### 1.1 The wall

The scheduler dispatches ready packages to lanes; each lane's `build_package`
invokes `makepkg -sf --noconfirm` (`build-all.fish:3954`, `build-all.fish:4003-4035`),
and **makepkg's own download path** (`download_sources`) is the only place sources
get fetched. Fetch therefore happens *at the moment the source is needed*, with zero
runway: a network incident that lasts longer than makepkg's single attempt fails the
package, the dispatcher's failure contract stops new dispatches and drains the run
(`build-all.fish:6398-6470`, `docs/architecture.md:63-75`).

Real walls, 2026-10-06 (three runs died at the moment of fetch):

- **`unzip`** — `curl: (56) unexpected eof` fetching the recipe's patches from
  `src.fedoraproject.org` (`packages/stable/unzip/PKGBUILD:15-23`).
- **`apr-util`** — `curl: (35)/(56)` TLS failures on `www.apache.org` for the
  release tarball (`packages/stable/apr-util/PKGBUILD:43-52`); the same bytes
  served fine from `dlcdn.apache.org` moments later — the network is flaky
  *per destination*, not dead.
- **`man-db`** — the savannah/ftp.gnu.org (pagure-class) outage at fetch
  (`packages/stable/man-db/PKGBUILD:19-26`); same day's written sibling:
  `libnewt` walled on `pagure.io` 404s (docs/NOTE.md:266-297), and the campaign
  log records 4+ transient TLS `unexpected eof` fetch flakes
  (docs/NOTE.md:3171-3228).

The maintainer's proven workaround is `/tmp/seed-ahead.sh` (38 lines): walk a slice
of the build order and run `GIT_CONFIG_COUNT=0 makepkg --verifysource -f` per
non-VCS recipe into the shared cache while the build runs. It cleared `unzip` and
`apr-util` instantly afterwards — but it covers only the slice someone remembers to
seed, its VCS filter is a crude `grep -E '(git|svn|hg|bzr)\+'` over the whole
PKGBUILD (a mixed recipe with one git source gets skipped entirely), and it lives
outside the builder where nothing enforces the house verification rules.

### 1.2 What the builder already knows (and the plan must reuse)

- **Plan order**: the run's topological order is computed once in `main`
  (`topo_sort`, `build-all.fish:788-951`) and registered in the run record
  (`run_record_plan`, `build-all.fish:6898-6933`); the dispatcher holds it in
  `$_lane_sorted` (`build-all.fish:5952`). Toolchain remediation *appends* to it
  mid-run (`force_queue_packages`, `build-all.fish:5484-5494`) — a prefetch window
  computed from live dispatcher state sees that automatically.
- **Skip/defer/started state**: `$_lane_started`/`$_lane_done`/`$_lane_deferred`
  (`build-all.fish:5955-5957`), the `-s` verdict (`freshness_skip_decision`,
  `build-all.fish:1196-1268`), and the deferral vocabulary (rc 99,
  `build-all.fish:6828-6870`) — a skipped or deferred package must not be
  prefetched, and a package that waits on a deferred recipe never builds this run
  (`waits_on_deferred`, `build-all.fish:5613-5623`).
- **Source machinery**: `pkgbuild_array_checked`, `source_url`/`source_vcs`/
  `source_filename` (`lib/sources.fish:318-336`, `1148-1237`), SRCDEST lookup
  conventions (`lib/sources.fish:2505-2519`), and the transport-retry discipline
  (`git_ls_remote_quiet`, `lib/sources.fish:1297-1334`) — the prefetch worker must
  classify sources with these, never with grep.
- **Verification machinery**: `makepkg --verifysource` = download-if-needed +
  checksum + PGP + `verify()`, then exit before extract/prepare/build
  (`/usr/bin/makepkg:1154`, `1490-1495`; `/usr/share/makepkg/integrity.sh:32-50`,
  including `?signed` git-tag verification via `verify_git_signature`,
  `/usr/share/makepkg/integrity/verify_signature.sh:170-200`). Without `-s` it
  runs **no dependency checks** (`/usr/bin/makepkg:1449-1451`) — no pacman call
  exists in the path. Already-cached files short-circuit the network ("Found %s",
  `/usr/share/makepkg/source/file.sh:29-37`) and are merely re-hashed/re-verified —
  the cheap cache reuse we want. This is exactly `seed-ahead.sh`'s command and the
  reason to use makepkg as the fetch engine: **the prefetch and the lane enforce
  the identical checksum/`validpgpkeys`/`#signed` contract**, so prefetch can never
  be a back door (MEMORY rule 15, docs/MEMORY.md:261-300).

### 1.3 Constraints the design must respect

- **Host**: 24-thread undervolted laptop whose freeze history includes a
  fork/exec+I/O storm hardlockup class (docs/MEMORY.md:1127-1166); 2 lanes ×
  -j11/-j12 are the norm, and "never run two heavy builds concurrently"
  (docs/MEMORY.md:127-128). Prefetch must add **no compile load**: one fetch
  process, `nice`d/ionice'd, network-bound.
- **pacman mutex**: makepkg `-s` dep installs share the builder flock through the
  shim (`ensure_pacman_shim`, `build-all.fish:2395-2430`); prefetch must never
  touch pacman, sudo, or the mutex at all — `--verifysource` without `-s` gives
  that for free.
- **Disk**: SRCDEST (`~/.cache/gsa-src` on this host,
  `/home/zhangdm/.makepkg.conf:12`; the repo docs describe the `$startdir` default
  — both are supported by the lookup logic) already carries a shared multi-GB
  source cache; the SHARED-SRCDEST cluster alone is 15–30 GB
  (docs/MEMORY.md:466-478). The window must be bounded and pause when free space
  is low.
- **Signals**: a run killed mid-build must leave nothing running — lanes get one
  TERM each, a shared grace, then SIGKILL (`cleanup_active_lanes`,
  `build-all.fish:5166-5262`), a second signal escalates immediately
  (`build-all.fish:8407-8425`), a SIGKILLed dispatcher is chased by the lane
  watchdog (`build-all.fish:8483-8505`), and orphans of dead runs are swept at
  startup (`orphan_lane_sweep`, `build-all.fish:5335-5355`). `tests/signal-abort-lock.sh`
  pins all of it (sub-tests 3/4/11/13 at `tests/signal-abort-lock.sh:1-60`).
  Prefetch children must meet the same bar.

---

## 2. Design

### 2.1 Process model: dispatcher-owned one-shot fetch children (a hidden `--fetch-job` seam)

**Where it hooks.** Inside `run_lanes`' existing 0.5 s poll cycle
(`build-all.fish:6124-6865`): after the reap block and before the dispatch block,
call a new `prefetch_tick`. It (a) computes the lookahead window from live
dispatcher state, (b) keeps at most **one** fetch child in flight, and (c) reaps
finished children into advisory records. Nothing else in the loop changes.

**Why a child process, not a fish background function.** The dispatcher already
documents that fish executes a backgrounded function synchronously and therefore
spawns lanes as external processes (`build-all.fish:6627-6631`). Same constraint
applies. **Why not a standalone helper script:** the project is a four-module
split whose builder logic lives in `build-all.fish` + `lib/*.fish`
(`docs/architecture.md:30-40`), and every fixture copies exactly those files into
a synthetic workspace (`tests/lib/fixture-lib.bash:156-170`). A hidden seam on the
existing entry (`--lane-job`, `--stale-lock-check`, `--local-db-check`,
`--install-decide` — `build-all.fish:8448-8560`) is the established pattern and
keeps `fetch_job` in the same flat function namespace as `lib/sources.fish`.

**Process shape** (mirrors the lane spawn, `build-all.fish:6631-6641`):

```fish
nice -n 10 ionice -c3 setsid --wait fish "$SCRIPT_DIR/build-all.fish" --fetch-job \
    (fetch_argv "$next" "$fetch_result") >>"$LOG_DIR/prefetch.log" 2>&1 &
set _PF_PID $last_pid
```

- `fetch_argv` / `fetch_argv_check` mirror `lane_argv`/`lane_argv_check`
  (`build-all.fish:5785-5822`): a newline-framed, count-checked payload —
  `pkg_id`, `result path` — never argv archaeology.
- The child runs in its **own setsid process group** so teardown can sweep it
  exactly like a lane (`lane_processes` is pgid-based, `build-all.fish:5083-5089`).
- The child carries the **parent-liveness watchdog** (same tiny `sh` watcher as
  `--lane-job`, `build-all.fish:8483-8505`, with `--fetch-job` in the marker): if
  the dispatcher is SIGKILLed, the fetch dies within seconds.

**How it learns plan order and skip logic — the dispatcher is the only brain.**
The worker receives *one recipe per invocation*; all policy lives in
`prefetch_tick`:

- Window = first `W` (default 8) entries of `$_lane_sorted` in plan order that are
  not in `$_lane_started`, `$_lane_done`, `$_lane_deferred`, not `waits_on_deferred`,
  not already prefetched this run (`_PF_DONE_*` marks keyed by `_topo_key`, the
  `dispatch_state_refresh` pattern, `build-all.fish:5504-5575`), and passing the
  candidacy filter (§2.3). Priority is **plan (topological) order** — when a
  package will be needed is what matters; the `build-tools` pick band is a
  ready-set reorder and deliberately irrelevant here (`docs/architecture.md:62-67`).
- Mid-run plan changes need no channel: the window is recomputed every poll from
  `$_lane_sorted`, which `force_queue_packages` appends to during toolchain
  remediation (`build-all.fish:5484-5494`). A remediation package becomes
  prefetch-eligible the poll after it is queued; its `lane_skip=0`/force-build
  semantics (`build-all.fish:6632-6640`) stay the lane's concern.
- Under `-s`, a package whose **local** freshness gates already say "skip" is not
  prefetched (a skipped package must not consume network/disk). The child cannot
  see dispatcher state, so the filter runs at spawn time in `prefetch_tick`, using
  a new pure-local factor of `freshness_skip_decision` (§4, step 1). Residual gap:
  a package that passes local gates but whose `-s` verdict later lands on "skip"
  after VCS probes is prefetched unnecessarily — cheap, acceptable, documented.

### 2.2 Fetch/verify pipeline per recipe: `makepkg --verifysource`, per-recipe granularity

`fetch_job PKG RESULT` (new function in `build-all.fish`):

1. Re-check local candidacy (recipe exists; under `-s` the local freshness factor
   still says "build"). On drift, publish result `skipped` and exit 0.
2. Enumerate sources with `pkgbuild_array_checked "$pkg_path" source` and classify
   with `source_url`/`source_vcs`/`source_filename` (`lib/sources.fish:1148-1237`).
   Local files (no URL) are never fetched; signature companions are ordinary
   source entries and ride along in makepkg's own source list. A failure to even
   evaluate the PKGBUILD is a `failed` advisory (the lane will hit the same wall —
   `report_pkgbuild_eval_failures` precedent, `build-all.fish:1048-1068`).
3. Run the fetch+verify, in the recipe directory, as the build user, with
   transport retries:

   ```fish
   env GIT_CONFIG_COUNT=0 makepkg --verifysource
   ```

   - **Never** `-s`/`-r` (no pacman), never `--skipchecksums`, `--skipinteg`,
     `--skippgpcheck` (MEMORY rule 15 is absolute), never `-o` (extracts — pointless
     disk), never `--holdver` in v1 for mixed recipes (see Q3; a phase-2 VCS policy
     may choose `--holdver` to never move shared mirrors).
   - `GIT_CONFIG_COUNT=0` is mandatory (MEMORY rule 2; `seed-ahead.sh` does the same).
   - Root-supervisor runs (`_ROOT_MODE=1`): drop to the build user exactly like
     `build_package` does (`env HOME=$_BUILD_HOME … sudo -u "$_BUILD_USER"`
     — `build-all.fish:4012-4033`); this is uid-drop, not privilege escalation for
     transactions. Unprivileged runs need no sudo at all.
   - `nice -n 10 ionice -c3` at the spawn (dispatcher side), so hashing/GPG/clone
     work never competes with compiles on the undervolted host.
   - Retry: 2 attempts per recipe, 10 s apart (constant, documented). Keep it small
     — the lane remains authoritative; prefetch is not the place for long retry
     windows (contrast `git_ls_remote_quiet`'s 3-attempt, seconds-scale backoff,
     `lib/sources.fish:1297-1334`, whose window exists because *that* answer gates
     skip decisions).
4. Publish the outcome via the fetch result codec (§3) and exit 0 **always** —
   `failed` is data, not process failure.

**Granularity decision: per-recipe, not per-source.** `makepkg --verifysource`
operates on the whole recipe because `validpgpkeys`, `verify()`, and the
sum↔source pairing are recipe-scoped (`check_source_integrity`). Per-source
fetching would mean reimplementing `check_checksums`/`check_pgpsigs` filename
pairing — the exact fragile machinery rule 15 forbids touching. The "skip
already-cached sources cheaply" requirement is met by makepkg's own "Found %s"
short-circuit (no network for cached files) plus the recipe-level `_PF_DONE` mark;
the residual cost is re-hashing cached bytes, which is seconds and is itself the
corruption check. A future refinement (out of scope v1) may skip the makepkg call
when *every* source file is present and matches its pin, but only if signature
companions are covered too.

### 2.3 Lookahead window and its policy

| Knob (v1 constants, named for later surfacing) | Value | Rationale |
|---|---|---|
| `_PF_WINDOW` (upcoming recipes tracked) | 8 | ~1–2 h of runway at 15–30 min builds; bounded disk exposure |
| `_PF_MAX_ACTIVE` (concurrent fetches) | 1 | per-destination flakiness argues for serial fetch; no CPU contention; simpler mirror-race story |
| `_PF_RETRY` (attempts per recipe) | 2, 10 s apart | advisory path; the lane retries at build time regardless |
| `_PF_DISK_FREE_MIN_GIB` (pause floor) | 5 | `df` on the SRCDEST filesystem before each spawn; below floor → pause prefetch with an advisory, never fail |
| nice/ionice | 10 / class 3 | never compete with compiles |

Policy details:

- **`-s` skip**: never prefetch a package whose *local* freshness gates say skip
  (fresh complete output set, PKGBUILD not newer, payloads readable —
  `freshness_skip_decision`'s first three gate groups, `build-all.fish:1206-1222`).
  The VCS-ref probe stays lane-side (it is a skip decision, and skip decisions are
  the lane's to make).
- **Deferrals**: never prefetch `$_lane_deferred` entries nor anything
  `waits_on_deferred` on them — those packages do not build this run.
- **Already running/finished**: `_lane_started`/`_lane_done` exclude them; this
  also prevents prefetch racing a lane's own makepkg for the same recipe's files.
- **Mid-run plan changes**: handled by re-derivation each poll (§2.1).
- **Shared-source residual race** (named risk): two *lanes* can already download
  the same shared source file into SRCDEST concurrently today (same `<file>.part`
  temp name — `/usr/share/makepkg/source/file.sh:39-80`); prefetch raises the actor
  count. Mitigations in v1: single-flight prefetch + never prefetch a started
  recipe. A per-filename advisory lock across lanes *and* fetches is a possible
  follow-up (out of scope; would need a makepkg invocation seam).

### 2.4 Concurrency, resources, pacman

- Exactly one fetch child at a time; total added load ≈ one `curl`/`git fetch`
  stream + hashing, niced. No compile, no link, no install — the "never two heavy
  builds" rule and the core-solo rule (`build-all.fish:6548-6560`) are untouched.
- The fetch child never receives `PACMAN`; `--verifysource` skips dep resolution
  entirely (`/usr/bin/makepkg:1449-1451`), so no pacman call exists to race the
  mutex. Fixture-pinned (§4).
- Disk: window bound + 5 GiB free-space floor before every spawn; the floor check
  is `df --output=avail` on the SRCDEST filesystem (fall back to `$startdir`'s when
  `SRCDEST` is unset, mirroring the lookup precedence in
  `lib/sources.fish:2505-2519`).

### 2.5 Signals and cleanup — children die with the run

Extend the existing lifecycle machinery; no new teardown philosophy:

- Track fetch children in parallel globals `_ACTIVE_FETCH_PIDS` / `_ACTIVE_FETCH_PKGS`
  (the `forget_lane_pid` pairing discipline, `build-all.fish:5066-5081`).
- `cleanup_active_lanes` (`build-all.fish:5166-5262`) gets a fetch half (or a
  `cleanup_active_fetches` called from the same three sites): **one TERM per pid,
  one shared grace (`_LANE_STOP_GRACE_S`, 30 s), then a single SIGKILL sweep** —
  the exactly-one-TERM discipline the pacman db.lck incident mandated.
- `kill_active_lanes_immediate` (second-signal escalation,
  `build-all.fish:8407-8425`) sweeps fetch children too.
- `orphan_lane_sweep` (`build-all.fish:5335-5355`) matches `--fetch-job` command
  lines as well, so a fetch orphaned by a SIGKILLed dispatcher is stopped at the
  next run's startup (and the per-child watchdog makes that window seconds anyway).
- `sweep_stale_run_artifacts` (`build-all.fish:5357-5385`) collects leftover
  `.fetch.$_RUN_ID.*.result` slots; `prefetch.log` is run-scoped and truncated at
  run start like `synced.list` (`build-all.fish:6106-6108`).
- Interrupt rendering is unchanged: rows for started packages
  (`interrupted-mid-build`), `never-started` for the rest, continuation suggestion,
  signal-named exit code (`build-all.fish:6934-7011`, `8427-8436`).

---

## 3. Failure semantics

### 3.1 Prefetch failure is advisory; the lane is authoritative

A prefetch `failed` result never sets `stop_starting`, never writes a run-record
row, never changes the run exit code. At dispatch the lane runs its own `makepkg`,
which fetches whatever is still missing and enforces the recipe's checksums and
`validpgpkeys` exactly as today. A wall at the lane therefore still fails the
package and stops dispatch (current invariant, `docs/architecture.md:63-75`) — but
with prefetch, "the lane needed bytes the flaky host would not give" becomes the
*rare* case (the window tried minutes ago and the lane may now hit makepkg's
"Found %s" path), and when it does happen the operator already knows this host
misbehaves: the warning is on screen and in the log.

Retry policy at the lane is deliberately **not** changed here (that is a separate
2026-10-02 out-of-scope note — parsing makepkg's mixed download/integrity output,
docs/NOTE.md:3245-3260). Prefetch sidesteps output parsing entirely: it only needs
the exit status of `--verifysource`.

### 3.2 VCS vs plain URL sources

- **Plain URL sources** (the wall class: tarballs, patches, `.sig`/`.sign`
  companions): v1 prefetch target, fetched and verified by `--verifysource`.
- **VCS sources**: v1 excludes *pure-VCS* recipes (Q3). When phase 2 adds them, the
  same `--verifysource` call populates/updates the SRCDEST mirror through
  `download_git` (`git clone --mirror`, else `git fetch --all -p` unless
  `--holdver`; a fetch failure there is makepkg-warning-only,
  `/usr/share/makepkg/source/git.sh:33-79`) and verifies `?signed` tags via
  `check_pgpsigs`. The `--link-sources` canonical-mirror contract
  (`docs/source-sharing.md:1-25`, `build-all.fish:2675-2922`) applies unchanged
  because prefetch uses makepkg's own download path — "is not a clone of" mistakes
  surface exactly as they would at build time. Open risk to resolve in phase 2:
  concurrent `git fetch`/prune on a shared canonical mirror while a lane extracts
  from it.

### 3.3 What a failed prefetch means for the run record

Nothing. Run-record rows are the outcome of the *package build* (ADR 0003:
"plan + per-package outcome rows + continuation", `docs/adr/0003-run-record.md:1-15`).
If the lane later succeeds from cache, the row is `succeeded ok` — correct. If the
lane later fails its fetch, the row is `failed build-failed` as today, and the
package log tail the summary already prints (`build-all.fish:7165-7175`) is the
authoritative evidence; the prefetch history is one grep away in
`$LOG_DIR/prefetch.log`.

### 3.4 Operator visibility (three renderings, one record — the ADR 0003 pattern)

One advisory record per fetch outcome (`pkg|verdict|reason|ts`), rendered:

1. **Plain output / dashboard**: one warning line at failure time
   (`ui_warning "prefetch $pkg: … — the lane will retry at build time"`) and a
   dashboard `_DASHBOARD_LAST_EVENT` note (`build-all.fish:4978-5036` renderer);
2. **Prose summary**: a `Prefetch warnings (advisory — lanes retry at build time):`
   section via a new `print_prefetch_notes`, mirroring `print_synced_notes`
   (`build-all.fish:4327-4342`) — the established run-level-witness pattern;
3. **Machine block**: optional additive scalar `prefetch-warnings: N` (Q5). The
   fixture parser classifies `^[a-z0-9-]+: ` lines as scalars and everything else
   as rows (`tests/lib/fixture-lib.bash:374-389`), so an added scalar is
   backward-compatible with the `format: 1` grammar — unlike new rows, which would
   poison `rr_rows` and require a format bump. Detail lines stay in
   `$LOG_DIR/prefetch.log` (full makepkg output per recipe, timestamped).

### 3.5 Adjacent hazard found while researching (decision Q4)

`makepkg` renames a finished download to its final SRCDEST name **before**
verification (`file.sh:73-80`), and a checksum failure exits without removing the
file (`verify_checksum.sh:117-122`); the next attempt sees "Found %s" and re-fails
forever (`file.sh:29-37`). A truncated-or-substituted download therefore walls the
recipe across runs and across tools — this predates prefetch and also affects the
lane alone. Prefetch at least detects it early (its advisory names the recipe while
the build is still far from it). Whether prefetch may quarantine the bad file and
re-fetch (still pin-anchored) is Q4.

---

## 4. Concrete implementation steps (each with its validation)

All steps are sequential; each leaves the battery green. Fixture convention
compliance throughout: bash, non-mutating, `$TMPDIR`-scoped, parallel-safe,
discovered by `tests/run-all.sh` (`tests/run-all.sh:1-25`); sibling scenarios share
one fixture file as sequential `( subshell )` sections
(`tests/scheduler-dispatch-order.sh:5-40` explains the new-file-vs-section rule).
New stub knobs are `GSA_FAKE_*` and must be added to the table in
`tests/lib/fixture-lib.bash:28-130`; the builder's own env roster is only what
`--help` lists (`build-all.fish:7381-7385`).

**Step 1 — factor the local freshness gates.**
Extract the non-network part of `freshness_skip_decision`
(`build-all.fish:1196-1222`: `current_archives` completeness, PKGBUILD-mtime,
`archive_payload_ok`) into `freshness_skip_local PKG_PATH` returning
`skip|build`; `freshness_skip_decision` calls it and keeps its VCS-probe half
verbatim. Pure refactor.
*Validation*: `tests/skip-upstream.sh`, `tests/scheduler-core-solo.sh`,
`tests/resume-command.sh` unchanged and green (skip semantics must not move).

**Step 2 — fetch result codec + `--fetch-job` seam + `fetch_job`.**
- `fetch_result_encode/decode` + `write_fetch_result`, mirroring the lane codec and
  its atomic `mv` publication (`build-all.fish:4837-4925`); verdict vocabulary:
  `ok | failed | skipped` + kebab reason (`not-a-candidate`, `vcs-only`,
  `eval-failed`, `disk-floor`, `fetch-failed`, `verify-failed`). Own vocabulary on
  purpose — never reuse `lane_outcome_*` (that wire carries build outcomes).
- `fetch_argv`/`fetch_argv_check` (`build-all.fish:5785-5822` pattern) and the
  `--fetch-job` dispatch block next to `--lane-job` (`build-all.fish:8448-8510`),
  including the parent-liveness watchdog and marker globals set before any work.
- `fetch_job`: §2.2 body. Enforce `env GIT_CONFIG_COUNT=0`; never `-s`,
  `--skipchecksums`, `--skipinteg`, `--skippgpcheck`, `-o`, `--holdver`.
*Validation*: new `tests/prefetch-ahead.sh` sections (see Step 3 list) — stub
makepkg logs argv (`GSA_FAKE_FETCH_LOG`): the log shows `--verifysource` and
**never** `-s`/`--skip*`; stub pacman/sudo logs (`GSA_FAKE_PACMAN_LOG`,
`GSA_FAKE_SUDO_LOG`) stay empty for a prefetch invocation; codec round-trip +
malformed-line cases.

**Step 3 — `prefetch_tick` in the dispatcher.**
Window computation (§2.1/§2.3) with `_PF_*` keyed marks (`_topo_key` pattern,
`build-all.fish:5504-5575`), single-flight spawn into `$LOG_DIR/prefetch.log`,
reap via the result file (re-read-once-after-death lesson from the lane reap,
`build-all.fish:6157-6172`), disk floor, advisory recording.
*Validation* (`tests/prefetch-ahead.sh` sections, one `( subshell )` each):
1. **fetch-ahead-while-compiling**: two-package workspace; the stub makepkg for
   pkg-1 sleeps (`GSA_FAKE_BUILD_SECONDS`); assert pkg-2's `--verifysource` ran
   before pkg-1's build ended (spawn/interval log), and the run succeeds.
2. **flaky host**: a fetch stub fails the first (prefetch) attempt
   (`GSA_FAKE_FETCH_FLAKY=pkg`), the lane's own build fetch succeeds; assert run
   rc 0, warning line present, `prefetch.log` has the failure, run-record row is
   `succeeded ok` (advisory semantics pinned).
3. **window bound**: 10-package chain with `_PF_WINDOW` overridden to 2 via the
   fixture-only seam (`_GSA_PF_WINDOW`-style, same hidden-seam precedent as
   `_GSA_RUN_ID`, `build-all.fish:6063-6072`); assert no >2-ahead fetch ever runs.
4. **`-s` skips**: package with a fresh archive (local gates = skip) is never
   prefetched; a stale one is.
5. **deferred/never-ready**: a package parked by an earlier defer (or waiting on
   one) is never prefetched.
6. **pure-VCS excluded**: a `git+`-only recipe produces `skipped vcs-only`;
   a mixed recipe (tarball + git source) *is* prefetched.

**Step 4 — lifecycle and signal integration.**
`_ACTIVE_FETCH_*` tracking, fetch half of `cleanup_active_lanes` +
`kill_active_lanes_immediate`, `orphan_lane_sweep` `--fetch-job` match,
`sweep_stale_run_artifacts` result-slot pattern, run-start truncation of
`prefetch.log`.
*Validation*: add one section to `tests/signal-abort-lock.sh` (that file owns the
teardown contract): prefetch child in flight (stalled fetch stub) + SIGINT to the
dispatcher → assert exit 130, run record still renders, **exactly one TERM** per
fetch pid (signal-log stub), no surviving `--fetch-job` process after the grace,
and a SIGKILLed dispatcher's fetch self-terminates via the watchdog within seconds
(sub-test 11's shape, `tests/signal-abort-lock.sh:50-58`).

**Step 5 — visibility + knob + docs.**
- `print_prefetch_notes` (mirror `print_synced_notes`) + warning lines + dashboard
  event + (Q5) additive `prefetch-warnings: N` scalar in `print_run_record`.
- Flag/knob per Q1 (recommended: `--no-prefetch`, optional `--prefetch-ahead N`;
  add to `usage`, `build-all.fish:7273-7465`; to `_CONTINUATION_RULES` as
  `semantics` (resume-mirrored) or `not-mirrored` — decide with Q1,
  `build-all.fish:7039-7075`; fixture-pin via `tests/resume-command.sh`).
- Docs, all in the same change:
  - `docs/build-guide.md` — new "Prefetch-ahead" subsection near "Skip and resume"
    (line 81) + Environment-surface entry (lines 372-429) + output-contract note
    (lines 430-502) if the scalar lands;
  - `docs/portability.md` "Parallelism" (lines 6-70): prefetch adds one niced
    network worker, deliberately outside the lane/job budget;
  - `docs/MEMORY.md` golden-rule addendum under rule 15 (lines 261-300):
    prefetch is advisory, runs `makepkg --verifysource` only, never
    `--skippgpcheck`/`--skipchecksums`, never pacman/sudo;
  - `docs/architecture.md` (lines 55-75, scheduler invariants): one paragraph —
    prefetch is advisory, never gates dispatch, never changes row semantics;
  - `docs/NOTE.md`: the incident entry (three walls, the seed-ahead experiment,
    the decision record);
  - `docs/adr/0004-prefetch-advisory.md` (or a 0003 addendum) **if** the machine
    scalar is adopted — ADR 0003's pattern for "builder-internal data rendered
    several ways" (`docs/adr/0003-run-record.md:1-28`).
*Validation*: fixture for the flag/roster (`tests/project.sh`-style `--help`
assertion or wherever Q1's surface is pinned) + `tests/run-record.sh` for the
scalar; full battery `tests/run-all.sh` at `RUN_ALL_JOBS=6` (~55 fixtures).

**Step 6 — rollout.**
Land behind the default-on switch (or opt-in, per Q1); first live use on a small
`-g misc` slice with the prefetch log open; then a full multi-hour run. Watch: disk
floor hits, `.part` collisions (none expected with single-flight + started-filter),
and prefetch warning→lane outcome correlation in `prefetch.log` vs package logs.
No commit is made by this plan; implementation commits follow the repo's
one-change-per-commit discipline after the owner answers the open questions.

---

## 5. Secondary research — what other systems do (and what we take from each)

- **Gentoo / Portage** — fetch is a separate ebuild phase with its own entry point
  (`emerge --fetchonly`), sources land in `DISTDIR`, and Manifest hash verification
  gates everything downstream: nothing compiles before its sources are fetched
  *and* hash-verified (devmanual.gentoo.org ebuild phase functions; Gentoo
  `emerge`/`fetch` docs). *Take*: fetch-verify is separable from build and should
  run ahead of it; verification is a fetch-phase gate, not a build-phase one.
- **Nix** — fixed-output derivations make "download this, expect this hash" a
  first-class, cacheable build step; substitutes/`nix-store --realise` fill the
  store ahead of the builds that will consume it, and a prefetch miss only matters
  when the consumer is actually built (Nix manual: fixed-output derivations;
  `nix-store` realisation/substitution). *Take*: prefetch is cache filling with a
  pinned expectation (our pin = the recipe's sums/`validpgpkeys`), and a prefetch
  failure must not fail the run — only the consumer's own fetch matters.
- **Bazel** — the Remote Asset API's `FetchBlob`/`FetchDirectory` resolve a URI +
  qualifiers to content in a CAS during analysis ("fetch while analyzing"), with
  digest pinning and multi-URI failover (bazelbuild/remote-apis
  `remote_asset.proto`; Bazel remote downloader docs). *Take*: fetch scheduling
  belongs *ahead of* the consuming action and keyed on build order; failover
  across equivalent sources is fetch-layer policy — in our world that is recipe
  URL-fallbacks + the lane retry, not something the worker invents.
- **ccache/distcc pipelines** — bounded parallel front-ends feeding slower stages
  with admission control sized for the host. *Take*: cap the fetch pipeline
  explicitly (our `_PF_MAX_ACTIVE=1` + nice/ionice) instead of trusting the
  scheduler to arbitrate.
- **pacman/makepkg SRCDEST** — one shared download cache, `download_file`'s
  "Found" short-circuit, `download_git`'s mirror-in-SRCDEST (`/usr/share/makepkg/source/file.sh:29-37`,
  `git.sh:33-79`): the cache is exactly the sharing seam prefetch should populate,
  and makepkg's own behavior gives cache reuse for free. *Take*: prefetch through
  makepkg, never around it.
- **`makepkg --verifysource` / `--holdver` / `-o`** — `--verifysource`:
  download-if-needed + integrity (checksums **and** PGP) then exit, no dep checks
  (`/usr/bin/makepkg:1154`, `1449-1451`, `1490-1495`) — the perfect prefetch verb;
  `--holdver`: don't update VCS sources — relevant only to the phase-2 VCS/mirror
  policy; `-o` extracts needlessly. *Take*: `--verifysource` is the whole
  fetch/verify pipeline; verification timing = fetch-time *and* build-time (the
  lane re-verifies), never weakened at either point.

---

## 6. Explicitly OUT of scope

- Changing the lane's own fetch/failure contract (a lane fetch failure still fails
  the package and stops dispatch; no makepkg-output parsing, no lane retry loop —
  the 2026-10-02 deliberate punt stands, docs/NOTE.md:3245-3260).
- Any weakening of verification: `--skippgpcheck`, `--skipchecksums`,
  `--skipinteg`, dropping `#signed`/`?signed`/`validpgpkeys` — never, anywhere
  (docs/MEMORY.md:261-300).
- Per-source scheduling inside one recipe; a custom fetcher; alternate-mirror
  *rewriting* of recipes (URL fallbacks remain recipe authorship;
  `--link-sources` stays VCS-mirror-only).
- VCS-source prefetch policy beyond the v1 exclusion (phase 2, Q3), including
  shared-canonical-mirror locking and `--holdver` choices.
- Automatic repair of the bad-file-in-SRCDEST hazard (Q4 decides what v1 may do;
  fixing makepkg's keep-then-"Found" behavior is upstream's).
- Run-record format changes beyond the optional additive scalar (Q5); new row
  statuses/reasons for prefetch; persisting prefetch state under `.state/` across
  runs.
- Prefetch for one-shot actions (`-ia`, `-cc`, `-ccc`, `-ln`, `--audit`), for
  version-sync/provider metadata (nvchecker/AUR/Arch `.SRCINFO` fetches), and for
  `updpkgsums`-time anchoring fetches (`lib/sources.fish:2440-2620`) — that path
  has its own defer semantics (`source-unfetchable`).
- Network-level fixes (proxies, mirror selection, parallel downloads), and any
  change to lane/job budgets, intensity profiles, or the pacman mutex.

---

## Appendix A — key citations map

| Concern | Where |
|---|---|
| makepkg invocation in a lane | `build-all.fish:3954-4035` (`makepkg_args -sf --noconfirm`) |
| `-s` skip decision + freshness gates | `build-all.fish:1196-1268` |
| defer vocabulary / run-record reasons | `build-all.fish:6828-6870` |
| dispatcher poll cycle (0.5 s tracked sleep) | `build-all.fish:6124-6865` (sleep at 6847-6865) |
| lane spawn + external-process rationale | `build-all.fish:6626-6641` |
| pick/ready/state marks | `build-all.fish:5504-5757` |
| plan-order append (remediation) | `build-all.fish:5484-5494` |
| lane result codec + atomic publish | `build-all.fish:4837-4925` |
| teardown: TERM-once/grace/KILL | `build-all.fish:5066-5262` |
| signals, escalation, watchdog, seams | `build-all.fish:8281-8560` |
| orphan/stale sweep | `build-all.fish:5335-5385` |
| run-level note pattern (`synced.list`) | `build-all.fish:4327-4342` |
| run record + continuation rules | `build-all.fish:6828-7235`, `docs/adr/0003-run-record.md` |
| source classification helpers | `lib/sources.fish:1148-1237` |
| SRCDEST lookup precedence | `lib/sources.fish:2505-2519`, `2142-2170` |
| transport retry discipline | `lib/sources.fish:1297-1334` |
| anchor + `source-unfetchable` defer | `lib/sources.fish:2440-2620` |
| `--verifysource` semantics | `/usr/bin/makepkg:1154,1449-1451,1490-1495`; `/usr/share/makepkg/integrity.sh:32-50` |
| "Found" cache short-circuit / `.part` download | `/usr/share/makepkg/source/file.sh:29-80` |
| checksum failure keeps the file | `/usr/share/makepkg/integrity/verify_checksum.sh:117-122` |
| `download_git` mirror/fetch/`--holdver` | `/usr/share/makepkg/source/git.sh:33-79` |
| `?signed` git-tag verification | `/usr/share/makepkg/integrity/verify_signature.sh:170-200` |
| fixture conventions + stub vocabulary | `tests/lib/fixture-lib.bash:1-130,156-195,374-389` |
| battery discovery | `tests/run-all.sh:1-25` |
| signal bar | `tests/signal-abort-lock.sh:1-60` |
| current workaround | `/tmp/seed-ahead.sh:1-38` (outside the repo; not to be committed) |
