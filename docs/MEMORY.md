# MEMORY — Gentoo_Style_Arch (self-built -git package stack)

> Maintainer memory for this public project. Read this file + NOTE.md (chronological
> incident journal, one `##` section per incident) before working. Keep this
> file to rules + current state; log every non-trivial change in NOTE.md.
> NOTE.md opens with a **naming-history table** — entries written before
> 2026-09-15 use the old `.Static/.Heavy/.Heavyweight/.3rdP` paths and the
> `static/heavy/critical/rocm` group names, which map onto today's
> `packages/{git,stable,core,misc}` layout (`packages/third-party/` was
> retired 2026-09-27).
> Host-specific and private details — home directories, machine names,
> credentials, downloaded sources, build artifacts — are intentionally
> excluded. Standard system paths that the workflow depends on
> (`/etc/pacman.conf`, `/usr/lib/llvm*`) are part of the contract, not host
> state. Current layout and public workflows are documented in the files
> beside this one.

## 1. Golden rules (violations caused real breakage)

1. **fish shell**: wrap EVERY terminal command in `bash -c '...'`. No `export`,
   no `[[ ]]`; arrays are 1-indexed; an UNMATCHED glob is a fatal fish error
   that `2>/dev/null` does NOT suppress — use `find -name`. The host's login
   shell is fish 4.9.3, so this applies to anything routed through `$SHELL`
   (commands handed to the user, `!cmd`, pasted snippets), not just to scripts.
   Tool-call shells here are bash (`$0` = `/bin/bash`), so bash syntax is fine
   *inside* a tool call — the hazard is crossing a shell boundary.
   CachyOS additionally ships aliases that change what a name does
   (`/usr/share/cachyos-fish-config/cachyos-config.fish`): `ls` → `eza -al`,
   `grep` → `grep --color=auto`, plus `la/ll/lt/l.`, `update`, `big`, `rip`.
   GNU coreutils *is* installed — `ls` 9.11 — so the flag hazard comes from the
   `eza` alias (and from `eza`'s different flag set), never from a non-GNU
   `ls`. Never assume a bare `ls`/`grep` flag works in a fish context.
2. **Agent-shell git hardening**: agent shells inject GIT_CONFIG_PARAMETERS
   (`safe.bareRepository=explicit`) → EVERY makepkg/git-bare-repo op from an
   agent shell needs `GIT_CONFIG_COUNT=0` (user fish shell unaffected).
   Manifestations when forgotten: `?signed` tag verify → "SIGNATURE NOT
   FOUND"; git-lfs fetch in the bare mirror exits 128 (handler tolerates it)
   → empty LFS store → N × "remote missing object" at extract.
3. **Validate PKGBUILD edits**: `bash -n PKGBUILD && makepkg --printsrcinfo
   >/dev/null`before considering anything done. (`!check` and `autodeps`
   are INVALID in the options array — pacman 7.x lint rejects them.)
4. **Provides discipline** (mechanism in pitfall digest §6):
   - toolchain -git packages need VERSIONED provides
     (`provides=("meson=${pkgver}")`) — unversioned provides cannot satisfy
     `>=N` makedeps; pacman falls back to the conflicting repo package.
   - every lib-shipping package declares BARE soname provides (`libfoo.so`) —
     undeclared = repo consumers break on the stock→house swap.
   - provides live in .PKGINFO: any provides change needs a real rebuild
     (`makepkg -Rf` repackages without rebuilding).
   - verify artifacts: `tar -xOf pkg.tar.zst .PKGINFO | grep provides`.
   - the mirror image applies to dependencies: request a capability through
     its VIRTUAL, never through one concrete provider. `jre-openjdk` conflicts
     with `jdk-openjdk` (and both conflict with a headless JRE), so naming one
     can make pacman demand the removal of a package the dependency graph
     needs; `java-runtime` is provided by every JDK and every full JRE. Same
     rule for `java-environment` (JDK), `libgl` (libglvnd), `cron`, etc.
     The 2026-09-18 logseq incident is the worked example.
5. **Qt private-API coupling**: qt6/qt5-base-git update ⇒ rebuild ALL coupled
   all coupled Qt modules in the SAME pass; verify private tags
   (`nm -D --undefined-only | grep QtPrivate_`); never `-Syu` fresh base-git
   while stock modules remain.
6. **Configure-cache staleness**: re-running a configure step over an existing
   build dir keeps stale argument values — Meson's `meson setup` options, and
   CMake's `CMakeCache.txt`, which is stronger: the `CFLAGS`/`CXXFLAGS`/
   `LDFLAGS` *environment* is read only while the cache is initialised, so a
   later change to them is ignored even by a fresh configure. `make clean`
   touches neither. After ANY meson-git upgrade run the stale-meson
   audit: `find . -name meson-info.json`, purge build dirs whose version
   differs (build dirs live at arbitrary depths — a maxdepth sweep misses
   them), rebuild a canary. A PGO phase 2 therefore replaces the cached
   arguments and lets the build system reconfigure itself rather than only
   rebuilding: `cmake-git` shipped phase-1 payloads for months because
   `${CFLAGS/-fprofile-generate/-fprofile-use}` plus `make clean; make` left the
   phase-1 flags in the cache (2026-09-20). Replace the values *inside* the
   cache — `sed` the flag strings, then `touch CMakeLists.txt` so the generated
   `Makefile` re-checks and regenerates — and do not delete the file to force
   it: the cache also holds the install prefix the configure was given,
   `--mandir`/`--docdir`/`--datadir`, `CMAKE_USE_SYSTEM_*` and `-fuse-ld=mold`,
   and deleting it silently reprefixed one payload to `/usr/local` with bundled
   dependencies.
7. **Don't touch in-progress builds**: check running makepkg processes and
   runtime log mtimes before rebuilding a package someone else is on.
   Never run two heavy builds concurrently (OOM).
8. **Purged tools stay purged** (system-wide): po4a, python-sphinx,
   python-myst-parser, lvm2, libblockdev-lvm, systemd-tests, cuda, gcc15.
   Never reintroduce via makedepends — makepkg reinstalls them silently;
   grep remaining makedeps after every trim. Since 2026-09-26 `--audit`
   enforces this with an exact-name lint over makedepends/checkdepends of
   every committed `.SRCINFO` (seam: `--audit-lint purged`).
9. **IgnorePkg closure**: every workspace pkgname must be in /etc/pacman.conf
   IgnorePkg (cumulative repeated `IgnorePkg =` lines, all inside
   `[options]` — a line in a repo section is silently dropped). Verify by
   unioning pkgbase+pkgname[] from each committed `.SRCINFO` — the audit must
   read `.SRCINFO`, never grep the PKGBUILD (the kernel's
   `pkgbase="linux-$_pkgsuffix"` hides the real names) — and diffing with
   `comm -23` against `pacman-conf IgnorePkg | sort -u` (empty = covered;
   `pacman-conf` reads the file directly and needs no database lock). Since
   2026-09-26 `--audit` carries a report-only closure gate that reads
   /etc/pacman.conf directly with the same [options]-cumulative semantics
   and skips only when the conf is unreadable (seam: `--audit-lint ignorepkg
   [conf]`; it informs, never blocks a build).
10. **Logs**: append one `## YYYY-MM-DD — topic` section per incident to
    NOTE.md: symptom → root cause → fix → rule.
11. **Install-before-dependents-compile**: never build-then-install-collectively.
    `build-all.fish -i` installs each package IMMEDIATELY after its build, in
    topo order, via `install_pkgs_now` (pacman -U --noconfirm --ask 4, rc
    checked — install failure aborts the run). The old end-of-run collective
    install compiled mid-run packages against OLD installed deps (09-06
    rust-git vs minimal llvm-git bricking). `-si/--sepinstall` — the old
    spelling of that behaviour — was removed 2026-09-17; `-i` is the only
    immediate-install flag. `-ia/--installall` is the one-transaction escape
    hatch and deliberately bypasses this rule; never use it for a set whose
    members depend on each other.
    Since 2026-09-25 `-i` first checks each archive against the installed
    database: exact version match AND an install date not older than the
    archive → the transaction is skipped (a same-version rebuild still
    installs); any doubt — failed query, unparseable date — installs.
    `-fi/--forceinstall` implies `-i` and bypasses the check (always runs
    `pacman -U`); `-ia` remains unaffected. Pinned by
    `tests/install-archive-guard.sh` cases C–H.
    Those installs are background jobs with no tty, so the dispatcher owns
    sudo liveness (see build-guide.md "sudo during --install"): it must never
    infer "installs are impossible" from `sudo -v` alone — a `NOPASSWD`
    sudoers entry makes `-v` fail forever while every install succeeds — and a
    run whose dispatch stopped early must exit non-zero instead of reporting
    success (2026-09-17).
12. **Mandatory selection + keystone discipline** (2026-09-07): build-all.fish
    has NO default action — always pass `-g` and/or package names. For
    ABI-coupled core updates use `-g core` (auto-installs the merged core set);
    for leaf rebuilds use `--no-deps`. New `_DEPS` edges are
    added ONLY after verification against `pacman -Qi Depends` (noctalia has
    NO qt6-declarative dep; NM-openvpn reaches ssl only via libnm).
13. **llvm-libs-git never moves alone** (2026-09-07 incident): LLVM snapshots
    have no stable C++ ABI — after any llvm-git/llvm-libs-git bump, rebuild
    rust-git + mesa-git + spirv-llvm-translator-git + openshadinglanguage IN
    THE SAME PASS (scan victims: /tmp/llvmvictims.sh pattern — grep /usr/lib
    for libLLVM links → pacman -Qo). rustc hits heap corruption/segfault on
    ANY compile otherwise, and rust-git cannot rebuild itself (bootstrap IS
    the broken rustc). Recovery when it happens: downgrade-rebuild llvm-libs
    at the rust-compatible snapshot (old version from /var/log/pacman.log,
    pin `#commit=` in PKGBUILD source, unpin after install — BPF target is
    build config, survives the snapshot change). Enforced by the builder since
    2026-09-25: `--audit` lints every cargo/rustc recipe for a `rust-git` edge
    in its topology record; the generic abi-batch gate refuses a real build
    whose selection omits an installed `abi=must` batch member (llvm-git
    without rust-git is the canonical case; the tag data drives it); and an
    `-i` run re-runs `check_rustc_sanity` right after its own
    llvm-git/llvm-libs-git install and stops dispatch on failure (the
    `--allow-broken-rustc` escape hatch does not cover that mid-run probe).
14. **Qt -git private-API coupling** (2026-09-08 incident): a Qt module that
    regenerates generated headers breaks consumers built against the OLD
    headers. qtlanguageserver r650 renamed `TextDocumentContentChangeEvent
    Variant{1,2}` → `TextDocumentContentChange{Partial,WholeDocument}`,
    breaking qt6-declarative's qmlls. Rebuild coupled modules IN THE SAME
    PASS (qt6-languageserver → qt6-declarative); when upstream dev lags,
    adapt via sed in prepare() (house style — re-applies over every git
    pull). "Unhandled python OSError" from meson = masked environment error:
    force the traceback with MESON_FORCE_BACKTRACE=1 from INSIDE the
    failing context (e.g. exported in the PKGBUILD), never interactively.
15. **Never bypass source verification** (09-17 mkinitcpio incident): a signed
    tag may be signed by a SUBKEY while upstream `validpgpkeys` lists only the
    primary key. `git verify-tag <tag>` names the actual signer; confirm that
    fingerprint against the maintainer's published key, add it to
    `validpgpkeys` with a role comment, and import the key. Never pass
    `--skippgpcheck` or drop `#signed`.

16. **Bulk `prepare()` loops: batch them, and refuse incomplete inputs**
    (09-18 texlive incident): a loop that shells out per file costs process
    spawns, not bytes — the texlive split was 301k spawns and 4,115 full rescans
    of an 18.7 MB tlpdb. Cut the input once, do the work with builtins, and
    batch the syscalls per destination (`mv -t`, 500 files per call); the same
    loop then costs ~10k spawns and the recipe's total exposure drops from ~8
    minutes to under one. And a loop that *moves* its inputs must count what was
    already consumed and stop, because the alternative is a package that is
    quietly missing files. Pin both with a fixture that diffs the old and new
    implementations (`tests/texlive-split.sh`, oracle in `tests/assets/`).

17. **Recipes are public surface** (09-19 incident): a recipe comment explains
    the code, the kernel option, or the trim decision — it does not inventory
    the machine it was written on. Kernel versions, installed package versions,
    CPU thread counts, bootloader command lines and incident narratives belong
    in NOTE.md. The set is maintained for **AMD laptops** (AMD CPUs with
    amdgpu/radeon graphics): a trim that follows from that target should name
    the platform, while one that follows from a single author's environment is
    a capability absence and should say so. A recipe is portable — ISA settings
    come from the environment — but the artifact is not, because
    `makepkg.conf` supplies `-march=native`. See `portability.md`,
    `CONTRIBUTING.md` and the 2026-09-19 NOTE section.

18. **An auto-update must be anchored to the authority the value came from**
    (09-20 audit): the stable version sync rewrites `pkgver`/`pkgrel` in place
    and leaves the committed sums describing the previous version. The builder
    used to paper over that with `--skipchecksums` — silently building sources
    nobody had verified — and the first fix was merely to disclose it. That
    disclosure was itself the wrong fix, because it left the guard lowered: the
    refusal message told the maintainer to run `updpkgsums`, which rewrites the
    sums **from whatever arrived** and therefore agrees with any tarball,
    including a substituted one. A verification-shaped no-op is not a check.
    The version comes from `pacman -Si` (Arch), but the bytes come from upstream
    (`ftp.gnu.org`, `github.com`, `cdn.kernel.org`), so "the official repo" never
    covered the fetch. The builder now anchors: it fetches the official
    packaging repo's `.SRCINFO` at the version it just synced to, matches every
    *moved* source against the checksums published there, writes with
    `updpkgsums`, and verifies the fetched source against Arch's published
    checksum (algorithms need not match — the artifact mediates). The stance
    split on 09-24: an entry Arch publishes a value for is still
    anchor-or-refuse (a disagreement refuses, restores, and *stops* the
    dispatch — an integrity signal, like a failed build); an entry Arch
    publishes NO checksum for (SKIP or absent) is refreshed by that same
    `updpkgsums` run and recorded per entry as fetch-only — the documented
    manual remedy, automated and loud; with no official document at that
    version the recipe still refuses and restores, but is now DEFERRED
    (parked via `_ANCHOR_DEFER_RC` with its recovery lines in the run
    summary) instead of draining the whole dispatch — one unanchorable recipe
    once cost ~120 packages their run.
    Three measurements shaped it, and each contradicted a first assumption:
    (a) **staleness is a moved source, not a moved version** — 26 of the 28
    `packages/stable` recipes pin a literal version inside their `source=()`
    URLs, so a pkgver rewrite usually leaves the sums valid and anchoring them
    would be a false alarm; the builder diffs the expanded array instead.
    (b) **a VCS `#tag=` source is anchorable** — makepkg's `calc_checksum_git`
    hashes `git archive --format tar <tag>`, which is reproducible across
    machines. Measured against fish 4.9.3: the local value matched Arch's byte
    for byte, which also proved our committed sum was simply wrong. (c) **the
    packaging repo's `main` can be ahead of the repos** (bash 5.3.20 vs the
    5.3.15 the repos serve), so the version's own tag is fetched as a fallback.
    `build_package` is called from exactly one place (`lane_job`, always
    `quiet_flag=1`) and every lane redirects its stdout/stderr into the
    per-package log, so that log is the only record that exists — accounting for
    why the original silence was invisible. Signature checks are unaffected and
    independent; 13 of the 28 `packages/stable` recipes anchor authenticity with
    `validpgpkeys` rather than with a checksum.
    **If the builder lowers a guard for a build, the log and the artifact must
    say so** — a weakening that leaves no record is indistinguishable from a
    bug (a refresh-only sum is exactly such a disclosed lowering: named in the
    package log and in the run-level `Synced with the repo this run` summary,
    never silent). **And if the builder auto-updates a value, the new value must be checked
    against a source the builder did not itself produce** — self-consistent is
    not verified.
19. **Runtime state is owned at WRITE time** (09-23 log-ownership incident):
    root mode's logs/locks/dirs are opened by the SUPERVISOR's shell, so
    repair-at-package-exit had a crash window: a killed root run left its
    in-flight logs root-owned (and `.state/` itself, which no chown ever
    named), and the next unprivileged run died at the lane-spawn redirect
    with `rc=125, 0m00s` before any build started. The contract now lives in
    `ensure_state_dirs` (startup: root sweeps `chown -R` over
    `$_STATE_DIR`; unprivileged refuses when `LOG_DIR` is unwritable, naming
    the remedy) and `ensure_log_writable` (before EVERY state-file open:
    root repairs wrong owners loudly and creates missing files via
    `sudo -u touch` — never as root, no root fallback; unprivileged
    QUARANTINES an unopenable file to `<path>.stale.<epoch>.<pid>` with a
    `preserved` announcement — forensics are renamed aside, never truncated —
    or fails named through `log_ownership_hint`). Any new `$LOG_DIR` open
    site must call `ensure_log_writable` first; forensics appends guard it
    best-effort (report, don't break, the run being recorded). The pacman
    mutex is the exception that proves the rule: never rename a
    possibly-held lock inode — root pre-creates it as the build user and
    unprivileged runs only verify readable (flock(1) opens read-only;
    measured: `flock -x` succeeds on root-owned 0644 and 0444 files). Pinned by
    `tests/log-ownership.sh` (both halves — the unprivileged quarantine and
    the root-repair section).

## 2. Workspace overview

- The public tree is `Gentoo_Style_Arch/`; recipes live under
  `packages/{git,stable,core,misc}/` (the `packages/third-party/` category
  was retired 2026-09-27; `zen-browser-pgo` and `bettbox` relocated to
  `packages/stable/` as pure renames).
- `config/topology.conf` is the ONE topology source: one record per package,
  `id|path|groups|edges[|tags]` — the only id→path binding, group membership
  (comma list ⊂ the five names `git,stable,core,misc,app`, roster stated once
  in `_GROUP_NAMES`), local
  build-order edges (a trailing empty `edges` field is the deliberate no-edge
  statement; records ALWAYS exist, so the old map⊆deps asymmetry is gone),
  and optional `abi=must`/`abi=should` coupled-batch tags plus at most one
  `app-cluster=<name>` prompt-cluster tag (charset `[A-Za-z0-9._+-]+`,
  comma-joined with `abi=` tags). The loader rejects
  malformed records by naming the offender and line (duplicate ids included)
  and validates records, roster, graph and a full topological sort on EVERY
  invocation. Tooling reads topology through the `--topology` data channel,
  never by parsing `config/` directly.
- `.state/` (or `GSA_STATE_DIR`) holds builder-owned state only: `logs/`, the
  per-package logs inside it, the pacman mutex, the lane result files, and —
  since 2026-09-23 — `dispatcher.log` (timestamped `[DEBUG-gsa-term]` signal
  receipts, lane-stop escalations, reap anomalies) plus the generated
  `.pacman-shim`. `LOG_DIR` is the only path derived from `_STATE_DIR` —
  there are no builder caches there. makepkg's own source trees and archives
  land **beside each
  recipe** (`SRCDEST`/`PKGDEST` default to `$startdir`), which is why the
  recipe directories carry ignore rules; both classes are ignored runtime
  state.
- The logical groups are `git`, `stable`, `core`, `misc` and `app` (the
  optional-applications group: on a TTY a build/`-n` run prompts to
  multi-select them, non-TTY runs take the whole list, and app members are
  leaf builds whose dependency chain is never expanded). `app` membership is
  EXCLUSIVE — wiring a record into `app` replaces its previous group (22
  members as of the 2026-09-27 wiring; `qt5ct`/`qt6ct` thereby left `core`,
  while their `abi=must` tags are untouched — a Qt ABI batch must name them
  explicitly, since `-g core`'s solo dispatch no longer rebuilds them). A
  record's `app-cluster=<name>` tag collapses members into ONE prompt row
  (six fcitx-family records show as `fcitx5 [member ids]`, toggled together;
  "N checked" counts rows) and is presentation only — packages stay separate
  in `-l`, the run record, ranges and lanes, and the tag is inert outside the
  app prompt. The `third-party` group was retired 2026-09-27 (`-g
  third-party`/`third_party`/`3rdp` now fail the unknown-group path); the
  audit's legacy `.3rdP/` path-drift regex intentionally remains — it scans
  for pre-Git filesystem paths, not group names. Membership counts are
  deliberately not recorded here (the 22 above is dated history, not a
  maintained figure) — they are hand-maintained and the first
  thing a batch invalidates — so `fish build-all.fish --list` is the source
  of truth. `core` intentionally overlaps stable
  packages whose ABI must be rebuilt and installed as one batch.
- No upstream checkout, package archive, downloaded signature, PGP cache,
  encrypted CI artifact, or host profile belongs in the public tree.

### build-all.fish

Selection is mandatory. The builder loads and validates the declarative
package map, groups, and dependency graph before handling command-line
arguments. It accepts package IDs, expands local dependencies, sorts them
topologically, and rejects cycles or missing records.

`--intensity xhigh` is the default automatic plan. It derives bounded lanes
and a global normal-lane job budget from CPU threads and available memory;
`low`, `medium`, `high`, `xhigh`, and `max` trade utilization against
headroom. Explicit `--lanes`/`--jobs` values override the profile. Core
packages run alone with a separate memory-aware job limit. Every lane is an
external Fish child with isolated output, atomic
validated results, and a log tail owned by the parent dashboard. Plain output
is append-only; interactive output is width-safe and sanitized. `-i` installs
each package before its dependents compile, under a builder-owned pacman
mutex. Install decisions are computed ONCE, silently, as plan rows
(`install`/`skip`/`refuse`/`noop`) by `install_plan`, and only the executor
(`install_execute`) renders and runs the single `pacman -U` transaction —
`-ia` shares that pipeline in force mode (no same-version skip; force
bypasses `install_skip_reason` entirely), and the hidden
`--install-decide <checked|force>` seam prints the plan rows for fixtures
without touching pacman transactions, sudo, flock or makepkg (rc 0 plan / 1
refusal / 2 bad usage). ALL privilege escalation is `sudo -n` and the builder
NEVER prompts (2026-09-26): the preflight probe refuses to start an `-i` run
when installs cannot succeed (`sudo cannot install non-interactively`), and a
credential lost mid-run stops dispatch exactly once (`sudo credential expired
and cannot be refreshed`) with a non-zero exit — a TTY changes nothing, and
`-ia` under a cold credential fails fast too. A system pacman database lock
is never deleted automatically. Lane results carry a named vocabulary:
`lane_outcome_{ok 0, failed 1, defer 99, lost 125, hup 129, int 130, term
143}` classified by `lane_outcome_name`, crossing the process boundary only
through the `lane_result_encode`/`decode` codec pair (lane argv stays
positional behind `lane_argv`/`lane_argv_check`). The dispatch invariant is
failure-shaped with one amendment
(2026-09-24): a failure stops new dispatches and drains in-flight lanes,
while a *deferral* (lane exit 99, `lane_outcome_defer`, aliased as
`_ANCHOR_DEFER_RC` for older docs) is not a failure — the
reap parks the package instead of calling `stop_starting`, its dependents
wait (`waits on a deferred package`), dispatch continues, and the run still
exits non-zero.

`--no-deps` is a deliberate leaf rebuild. `--audit` checks active topology and
runtime drift, including cargo/rustc recipes that declare no `rust-git` edge.
`--link-sources` deduplicates compatible VCS mirrors without
publishing them. `--nuclear` removes fetched sources only after an explicit
confirmation and preserves recipe-local inputs.

### Key dependency edges

glib2 -> pango -> cairo -> gtk3/gtk4 -> libadwaita; liburing -> libdex ->
xdg-desktop-portal; qt6-base -> pyside6 and the Qt6 modules; qt5-base ->
the Qt5 modules; ninja -> meson; rocm-core -> rocm-llvm -> hsa-rocr ->
hip-runtime; llvm -> SPIR-V/libclc/rust; rust -> rust-bindgen; babl -> gegl
-> gimp; openssl -> openssh/openvpn/git/LibreOffice; LLVM ->
OpenShadingLanguage -> blender.

### Landmines / one-offs

- `libisl-git` tracks a package whose repository name differs; do not let
  automatic stable synchronization rewrite it blindly.
- Qt private APIs and LLVM snapshots require consumer rebuild batches.
- Shared mirrors must have the exact origin URL and a usable fetch refspec.
- A populated non-Git source path is never replaced automatically.
- Build in the runtime clone, never in this repository. A run started here left
  24 GB of SVN checkout, split tree and packaging state inside the published
  repository's directory (recovered by `rm -rf` on the four ignored paths). The
  recipes are ignored-safe, but nothing about a build belongs here — and
  `.state/` logs are Git-ignored too, so a run's forensics die with the clone
  unless `GSA_STATE_DIR` points somewhere durable.
- `texlive-texmf`'s `prepare()` MOVES ~150k files out of `$srcdir/texmf-dist`,
  so that tree is single-use: a resume over an already-split checkout fails on
  purpose (13,870 of 150,746 runfiles were gone in this one) and needs
  `rm -rf src`. It also needs ~38 GB on disk, not the ~3.5 GB of data, because
  each SVN working copy keeps a 9.1 GB `.svn/pristine` shadow.

### Fixture conventions

- `tests/lib/fixture-lib.bash` is the ONE synthesis/interface helper —
  sourced, never executed. `make_workspace DIR [lanes [jobs [intensity]]]`
  builds the complete workspace skeleton (the loader validates records, the
  roster, the graph and a full topological sort on EVERY invocation, so a
  fixture workspace must be complete or every run dies in the loader);
  `add_package DIR ID [extra-pkglines [group]]` adds one synthetic package
  (one-line PKGBUILD + its topology record `ID|packages/ID|GROUP|`; extra
  PKGBUILD lines are passed verbatim, never guessed); `set_topology_record DIR
  ID GROUPS [EDGES [TAGS]]` is the single writer for records that need
  multiple groups, edges or tags (replace-or-append); `stub_sudo`/`stub_pacman`/`stub_makepkg` write the trivial
  byte-identical PATH stubs. `stub_sudo` is a passthrough that strips the
  builder's non-interactive flags (`-n`, `-v`, `--`) **and `--preserve-env`** —
  some hosts wrap `sudo` in a fish function that re-execs it as `command sudo
  --preserve-env …`, and a stub that chokes on that flag would fail every `-i`
  fixture in the preflight probe. Oracle-shaped stubs (fake `date`, marker
  flipping, `-Qp`/`-Qi` answers, signal loggers) stay inline in the fixture
  that gives them meaning, as do assertions, `fail()` prefixes and the
  `( subshell )` section structure of multi-subject fixtures.
- `run_builder CMD…` is the capture helper: combined stdout+stderr in
  `FIXTURE_OUTPUT`, exit status in `FIXTURE_RC`, and it ALWAYS returns 0 — a
  failing builder is the fixture's data, not a reason to trip the fixture's
  own `set -e` — so assert on `$FIXTURE_RC` explicitly.
  `makepkg_printsrcinfo DIR` is `makepkg --printsrcinfo --dir` carrying
  `GIT_CONFIG_COUNT=0` (agent shells inject git config that breaks makepkg VCS
  operations). Both are plain bash functions and do not cross a process
  boundary on their own: a fixture running them inside `bash -c` workers must
  `export -f` them (`tests/srcinfo-freshness.sh` exports `check_recipe` and
  `makepkg_printsrcinfo` for exactly that reason).
- Every stub knob is named `GSA_FAKE_*` and is fixture-side only: read by the
  stub script, never by the builder, which honours exactly the seven `GSA_*`
  inputs `--help` lists — `GSA_LANES`, `GSA_JOBS`, `GSA_INTENSITY`,
  `GSA_CPU_THREADS`, `GSA_MEMORY_GIB`, `GSA_STATE_DIR`, `GSA_TARGET_CPU`.
  `GSA_BUILD_JOBS` is the builder's OUTPUT to recipes, not an input. A new
  fixture knob keeps the `GSA_FAKE_*` prefix (full table in the helper's
  header).
- `tests/run-all.sh` discovers fixtures recursively (`find . -name '*.sh'`)
  and excludes `tests/assets/` (frozen reference material, never runs
  standalone) and `./lib/*`; the helper is `fixture-lib.bash` (`.bash`, not
  `.sh`) so discovery can never match it, and the `lib/` exclusion is defence
  in depth against a future `tests/lib/anything.sh` becoming a phantom
  fixture. Sibling subjects merge into ONE file as `( subshell )` sections
  rather than growing another top-level script.
- The run-record machine block is the assertion surface: the `rr_*` family in
  `tests/lib/fixture-lib.bash` (`rr_extract`/`rr_scalar`/`rr_rows`/`rr_row`/
  `rr_remaining`) parses it from stdin — exactly-one-block guard, `\r`
  stripping for PTY captures, loud failure on a missing/duplicate block or an
  unknown field. The parser is the interface under test. Prose output is
  pinned in exactly ONE place, the rendering section of `tests/dashboard.sh`;
  scenario-bound rendering pins (prompt layout, deferral label, sudo message
  frequency) stay co-located with the scenario they describe.
- `tests/project.sh` pins its own topology-command inventory:
  `expected_invocations=20` is the count of column-0 `run`/`run_split` calls
  the fixture scrapes out of itself and pre-executes (the call syntax is
  load-bearing — a call indented off column 0 is never pre-executed and its
  replay fails). A change to the topology commands the fixture drives must
  update the pin in the same change, or the self-scan fails.

## 3. Stack facts

Durable shape of the stack, re-verified 2026-09-17. Deliberately no version
numbers: they rot within days and `pacman -Q <pkg>` is authoritative. Dated
install history lives in `NOTE.md`.

- **llvm-git is DELIBERATELY MINIMAL**: `-D LLVM_TARGETS_TO_BUILD="X86;AMDGPU;BPF"`
  — the BPF backend exists so `scx-scheds-git` can build its BPF skeletons with
  `clang -target bpf`. `rust-git` is built against this llvm-git, so both move
  together (golden rule 13, §6).
- **Qt dev stack**: every Qt6/Qt5 private-API-coupled module is house-built;
  `qt5-base-git` carries `-ffat-lto-objects` for the LTO-strip hazard (§6).
  `pyside6-git` is scoped with `-DMODULES='Core;Gui;Widgets'` because the rest
  of Qt is still stock. Stock-only by design: qt6-translations, qt5ct, qt6ct.
- **Toolchain `-git` packages carry VERSIONED provides** (`meson-git` →
  `meson=<ver>`, likewise ninja-git, cmake-git, doxygen-git) — unversioned
  provides cannot satisfy `>=N` makedepends (golden rule 4).
- **GIMP/Krita chain**: `gimp-git` ships upstream's dev naming — the binary is
  `gimp-3.3`, there is no `/usr/bin/gimp` — and declares only a bare `gimp`
  provide. `krita-git` and `cairo-git` declare versioned provides
  (`krita=…`, `cairo=…`) plus bare soname provides; `babl-git`/`gegl-git`
  ship soname provides. `pacman -Dk` must stay free of chain errors and `ldd`
  must resolve babl/gegl from the house packages.
- **util-linux**: built with `-Dbuild-python=disabled` and
  `-Dtranslate-docs=disabled` (po4a was purged; the feature HARD-FAILS rather
  than skipping, §6). Its `libuuid`/`libblkid` verdefs need mold's
  `-Wl,--undefined-version` (§6).
- **linux-firmware** is trimmed to the maintained hardware set (AMD Strix Halo
  + MediaTek MT7925 + Cirrus amps). In `pipewire`, the `pipewire-jack` split is
  NOT built because it conflicts with the system's `jack2`, while
  `pipewire-jack-client` is kept. `easyeffects-git` replaced `jamesdsp-git`.
- **blender-git** pairs with house `openshadinglanguage` (same LLVM coupling as
  §6 describes).

## 4. Optimization playbook

- **mold linker**: `-fuse-ld=mold` in LDFLAGS/QMAKE_LFLAGS/meson linker args;
  mold-git does NOT provide `mold` for makedepends resolution — runtime
  `command -v mold` check instead (house guarded idiom).
- **CachyOS makepkg.conf** gives -O3/-march=native implicitly; meson packages
  use `arch-meson` (buildtype=release — upstream `if buildtype=='release'`
  blocks DO apply). Rust: append `-C target-cpu=native` ONLY if RUSTFLAGS
  lacks 'target-cpu'. ISA tuning is host-derived or explicitly configured.
- **LTO**: meson-controlled `-Db_lto=true` (mesa +allow-broken-lto,
  libadwaita, util-linux, systemd, dbus-broker, noctalia); PGO phase-1 always
  `-Db_lto=false` → flip true in phase 2 (glib2, gtk3, gtk4, wayland, cairo,
  xwayland, libinput, pixman, noctalia); manual via make/CMake (jemalloc,
  zlib-ng-compat); zstd phase-2 only; `options=(!lto)` where LTO breaks
  (llvm-git, rocm-llvm, hip-runtime, gcc-snapshot, niri-spicy-git,
  blender-git); Zen uses mozconfig thin LTO instead.
- **PGO phase-2 reconfigure**: a phase-2 pass must re-run the *configure* step,
  not only the build — the argument cache survives `make clean`. Meson:
  `meson setup --reconfigure` with both compiler and linker caches replaced
  (§1 rule 6, `docs/build-guide.md`). CMake: `cmake-git` reads
  `CFLAGS`/`CXXFLAGS`/`LDFLAGS` only while initialising `CMakeCache.txt`, so
  phase 2 rewrites the flag strings **inside** that file and touches a tracked
  input (`CMakeLists.txt`) so the generated `Makefile` regenerates — without it
  the link line keeps `-fprofile-generate` and `package()`'s instrumentation
  guard aborts (2026-09-20). Rewrite the cache rather than delete it: it also
  holds the install prefix, `--mandir`/`--docdir`/`--datadir`,
  `CMAKE_USE_SYSTEM_*` and mold's `-fuse-ld=mold`, so a deletion re-prefixes the
  payload to `pkg/usr/local` and swaps system libraries back to bundled ones.
  Never re-run `./bootstrap` either: that is a *build of a compiler*, and its
  objects are compiled from the same sources as phase 1, so `-fprofile-use`
  there hits the phase-1 generate-mode profiles and make dies on
  `-Werror=coverage-mismatch`.
- **PGO training workloads**: mesa (vkcube on lavapipe + glxinfo/eglinfo,
  gcda in srcdir/mesa-pgo-profile, ON by default); glib2/gtk/cairo (`meson
  test`, timeouts + `|| true`); bash/zsh (`make check` timeout 900 + `|| true`
  - binary smoke test); easyeffects (private pipewire+wireplumber in
  dbus-run-session, sandboxed XDG dirs, quits via `easyeffects --quit` —
  never terminate daemon processes by name, PID-scoped cleanup only);
  wayland/libinput/util-linux/systemd OPT-IN via env vars; noctalia (headless
  sway); lz4/zstd CLI (profiles OUTSIDE build dir); mimalloc (test suite +
  `-fprofile-update=atomic`); mold (links itself); rust/niri LLVM-style
  (LLVM_PROFILE_FILE + llvm-profdata, unset sccache). Verify:
  `find <profile-dir> -name '*.gcda'` count > threshold. The threshold is a
  per-recipe `local` — `pgo_min_gcda`, or `pgo_min_profraw` for mold-git's
  Rust `.profraw` profiles; it is NOT a `lib/pgo.sh` knob — and its comment
  contract is "≈ the minimum distinct translation units the training must
  touch before a profile is worth trusting": at or below it the profile is too
  thin and the recipe falls back to a non-PGO (LTO-only) build rather than
  shipping one. Values today: 0 (`cmake-git`, `mold-git` — any profile data at
  all suffices; zero files means training never ran and phase 2 is skipped),
  50 (`glib2-git`, `cairo-git`, `xorg-xwayland-git`), 100 (`gtk3-git`,
  `gtk4-git`). A threshold change is a behavioural change — it decides whether
  the recipe ships a profile-used build at all — and belongs in a NOTE.md
  entry with the reason; if the thresholds are ever lifted into `lib/pgo.sh`,
  a change there is a behavioural change to every consuming recipe at once.
- **Autotools PGO**: CFLAGS bake at ./configure time — every phase must
  re-run ./configure; `make clean` is NOT enough.
- **Special cases**: rust-git (bootstrap.toml flags, 5 patches, and
  `options` must keep `!lto`: makepkg's `-flto=auto` makes the C++
  llvm-wrapper GCC-LTO, which lld — rustc's `gnu-lld-cc` default linker —
  cannot link; see §6. Also: `build()` must invoke
  `x.py install rust-src` explicitly — upstream abcb9780d6d4 renamed the
  step `src`→`rust-src` and its default run needs `[build] extended`,
  which we never set; also `build()` must wipe dest-rust/dest-src first —
  a failed run's half-mutated DESTDIR makes the next install.sh die on a
  dangling-symlink `cp`; see §6); Zen browser
  (fortify 3→2, HOST_CFLAGS unset — cc-rs re-export hazard, 3-tier mozconfig
  PGO); gcc-snapshot (-O2 stage2–4, format-security stripped); qt5-base-git
  (cflags + nostrip patches — qmake consumes system CFLAGS); libadwaita/
  xdg-portal-gnome `--wrap-mode=default`; dbus-broker units patch; glib2
  schema/terminals patches; `options=(staticlibs)` on lz4/pixman/mimalloc/
  libunwind. Deliberate no-ops: libreoffice-fresh (already `!lto` +
  `--enable-lto` + fortify 3→2 + -g1); blender-git (mold + ccache + !lto).
- **Electron/JavaScript packages** (vscodium-insiders-git, logseq-desktop-git,
  vencord-git):
  nothing is compiler-built except the native Node addons, so the recipes are
  `!strip !debug !lto` and apply only ccache + the mold probe to those addons.
  vencord-git carries an extra operational contract: the `/usr/lib/vencord`
  payload is **inert until injected**, so the recipe also ships
  `discord-vencord` (re-asserts the patch on every launch — the only thing
  that survives Discord self-updates), `vencord-inject` (official-compatible
  asar shim; the official installer cannot be repointed at a pacman payload)
  and a libalpm hook re-wrapping the stock `discord.desktop` — and its
  scriptlets define `post_upgrade` because pacman has **no fallback** to
  `post_install` on upgrades.
  logseq-desktop-git additionally bundles `master` (2.x) which embeds an
  OCaml/Melange CLI runtime — the opam switch lives under `$srcdir` and pins
  OCaml 5.1.1 to match upstream CI.
  Its `cli/` and `static/` installs MUST pass `--ignore-workspace`: the tree's
  root `pnpm-workspace.yaml` has no `packages:` field, so a bare `pnpm install`
  from a subdirectory resolves the ROOT project, exits 0 and creates no
  `node_modules` — `static/` then failed with
  `Command "electron-builder" not found` (2026-09-18, NOTE.md). Related: with
  the flag, pnpm also skips the allowlisted dependency build scripts and
  `shamefully-hoist`, which is harmless here only because electron-builder
  fetches the Electron distribution itself and the static `postinstall`
  rebuilds `keytar`.
  Its opam switch is created only when absent: `build()` restarts from the top
  while `$srcdir` persists, and `opam switch create` exits 2 on an installed
  switch, which errexit turns into an abort before the first bundle (same date,
  NOTE.md).
- **TeX Live data packages** (texlive-texmf): `arch=(any)`, so there is no
  compiler and no ISA/LTO/PGO phase at all. The recipe keeps upstream's
  `!strip`, which also skips the strip/debug tidy pass, and optimises by scope
  only (whole splits dropped with their depends/provides/paths). It is the only
  recipe using SVN sources; `nuclear_cleanup` treats `svn://`/`svn+` like
  `git+` and also removes downloaded `*.whl` files.

## 5. Pending tasks

Re-verified against the host on 2026-09-26. Completed items were deleted
rather than left in place — an unchecked task list reads as authority while
going stale.

### Queued (claim by editing this section)

- **ROCm is half-removed**: `hsa-rocr` 7.2.4-1.1, `rocm-llvm` 2:7.2.4-2.1 and
  `comgr` 2:7.2.4-2.1 are installed again (the 2026-09-06 collective removal was
  reversed), while `hip-runtime` is absent — so HIP compute/Blender-HIP is still
  gone. Either rebuild `hip-runtime` in the same `-g core` pass as its
  dependencies, or prune the ROCm recipe dirs, their group membership, and
  `rocm-core`.
- **dbus-broker redundancy**: `stable/dbus-broker` and `git/dbus-broker-git`
  build the same packages — pick one before expanding the public set. The
  installed system package is stock `dbus-broker` 37-3.1.
- **doxygen-git purge** (user decision): no workspace consumer left. Its other
  half, `xapian-core`, is already gone.
- **gtk4-git demo trim**: `_package_gtk4-demos` plus its `_pick demo` lines
  still ship gtk4-demo, -widget-factory, -node-editor and -print-editor.
- **libadwaita-git**: the optional `check()` and `checkdepends=(weston)` are
  still present, so building it needs weston installed. Keep, or drop both.
- **linux-firmware**: the 2026-09-04 audit deferred an extra legacy-firmware
  `rm` line and never recorded what it targeted. The current trim already drops
  pre-amdgpu `radeon` and the unused vendor directories, and upstream has no
  `legacy/` tree, so the item is either redundant or needs re-specifying.
- **Build freezes: root cause identified — CVE-2026-90432, carried by our
  own kernel recipe (2026-09-19; fix built and running).** `scx_hardlockup()`
  deferred the sched_ext abort to `irq_work` that never runs on a hard-locked
  CPU, and returned `%true` whenever sched_ext was loaded, suppressing the
  kernel's own hardlockup report — which is why no journal ever held a trace.
  Affected 7.1 ≤ v < 7.2.6; fixed in 7.2.6+ and 7.3-rc1+. The trigger is a
  fork/exec + I/O storm (i.e. any build), which is why build weight never
  mattered (upstream `sched-ext/scx#3687`). The recipe moved to the CachyOS
  RC channel (`cachyos-7.3-rc3-4`) and the running kernel is
  `linux-cachyos-cachyos-lto` **7.3.0-rc4-1** (`uname -r` =
  `7.3.0-rc4-1-cachyos-cachyos-lto`), built with `_cpusched=cachyos`:
  `PREEMPT_DYNAMIC`, `CONFIG_HZ=600`, ThinLTO Clang, **no PREEMPT_RT and no
  `SCHED_BORE`** — the recipe default is still `rt-bore`, so a default
  rebuild deliberately swaps the machine back to rt-bore; re-read before
  doing that. `linux-cachyos-rt-bore-lto` 7.2.5-1 and `linux-cachyos-lts`
  6.18.52-1 remain installed as fallbacks. Evidence is upstream-documented
  plus circumstantial (the confirming A/B was skipped by decision): read
  "identified" as strong, not proven. The freeze-forensics rules that outlive
  the incident (pstore, config-only knobs, the stood-down capture chain and
  its re-arm backups) are in §6.
- **Decision needed at the next `linux-cachyos` rebuild: AutoFDO + Propeller
  (2026-09-19).** The installed 7.2.5 kernel was built with `AUTOFDO_CLANG=y`
  and `PROPELLER_CLANG=y`; the recipe defaults `_autofdo` and `_propeller` to
  `no`, so the first default rebuild replaces an AutoFDO+Propeller-optimised
  kernel with a plain one — a real optimisation loss that warns nowhere. Either
  put `afdo.prof` and the two `propeller_*.txt` profiles beside the PKGBUILD and
  set both knobs, or accept the plain kernel deliberately. `prepare()` asserts
  the off state either way, so the swap shows up in the log rather than passing
  unnoticed.
- **Still open: the 2026-09-01 cluster.** `last -x` over the whole wtmp (machine
  installed 2026-08-31 15:20) shows ~23 unclean shutdowns, but the first four
  are a separate event: inside 27 minutes, the first ten minutes after
  `ryzenadj` + `ryzen_smu-dkms-git` were installed, and **before
  `scx-scheds-git` existed** (first installed 2026-09-03 17:52) — so the CVE
  above cannot explain them. Prime suspect is the `ryzenadj` undervolt applied
  at every login: its per-core `--set-coper` half is unverifiable, because CO
  cannot be read back and the script discards `ryzenadj`'s exit status. All AER
  counters are zero on both the NVMe device and its root port, so the link-fault
  lead is still absence of evidence. One full-length 6-minute rebuild (Tctl
  91 °C) passed with no freeze — with sched_ext unloaded, so it is not a control.
- systemd is a separately coupled effort whenever its recipe changes.

Queue items deleted as done in earlier passes (each verified, not assumed):
the `-Rns hyperv intel-speed-select x86_energy_perf_policy` batch and
`llvm-ocaml-git` (none remain installed); seatd-git's `libseat.so=1-64`
provide (the installed `.PKGINFO` carries it); llvm-git's
`X86;AMDGPU;BPF` rebuild and the dependent scx-scheds-git rebuild; the stale
`gcc-*-snapshot` language splits; mesa-git's PGO zero-gcda abort; and the
cmake-git / xorg-xwayland-git PGO-payload rebuilds (checked 2026-09-26:
`strings -a` over the installed `cmake`/`ccmake`/`cpack`/`Xwayland` reports
zero baked `.gcda` destinations — `ctest`'s single hit is the `/*.gcda` glob
constant, not a baked path).

## 6. Pitfall digest (full details: NOTE.md sections of same dates)

- **fish autoloaded a user-level `rm` wrapper and hung every run** (2026-09-27,
  host state, not repo code): fixture and builder runs hung at ~100 % CPU
  before doing any work; pristine HEAD hung identically, exonerating the repo —
  the user-level fish config autoloaded a trash-cli-backed `rm` wrapper that
  spun on any invocation, and both the builder and the fixtures call `rm`
  early. When a run hangs with no output, suspect the shell environment first
  and re-test at HEAD before debugging repo code; reproduce with
  `XDG_CONFIG_HOME=$(mktemp -d)` so fish falls back to the system `rm`. Keep
  host specifics out of the repo docs.

- **A quoted fish array slice collapses to ONE argument** (2026-09-26,
  install/lane refactor): `"$argv[2..-1]"` joins the slice into a single
  string; a lane handler built its argv that way and every lane died with
  `--lane-job expects …` / rc 125. Use the unquoted slice `$argv[2..-1]` —
  fish preserves elements and performs no word splitting. Quote scalars, not
  slices.

- **The resume suggestion must include the failed package** (2026-09-26,
  full-rebuild campaign): the failure summary's "To resume, run:" line AND
  its "Remaining" count both EXCLUDED the failed package itself (near-miss
  confirmed twice — cycle-1 libreoffice, cycle-10 qt5-base-git), so copying
  the suggested command left the failed package stale while its dependents
  built against stale *installed* copies. The builder now includes the
  failed package in both; `tests/resume-command.sh` pins it — if a future
  change regresses the list, that fixture is the tripwire. Never hand-trim a
  failed package out of a resume command either.

- **mtime alone over-reports recipe staleness** (2026-09-26, freshness
  audit): a raw PKGBUILD-vs-archive mtime comparison flagged much of the
  tree after a bulk content-identical rewrite touched 36 PKGBUILDs at 06:25
  and version-line bookkeeping commits post-dated their builds. The
  content-aware audit — last commit touching the PKGBUILD vs the newest
  archive's build time, plus pkgver-vs-archive-name — showed **0 genuinely
  stale recipes** (every "stale" recipe's newest archive name matched its
  current pkgver exactly). Judge freshness by content/commit time and
  version lines, never by mtime; `linux-cachyos` is the single documented
  rebuild exclusion (user decision, 2026-09-26).

- **A run can create the skew its own preflight just cleared** (2026-09-25,
  llvm/rust ABI skew): `check_rustc_sanity` passed at 19:31; the run's own
  `llvm-git` install at 20:50:26 broke system rustc 3 s later — LLVM trunk
  dropped the trailing `bool` of `cl::ParseCommandLineOptions` while keeping
  the `LLVM_24.0` version node, so `librustc_driver` needed
  `…vfs10FileSystemES2_b` and the new `libLLVM` exported `…vfs10FileSystemES2_`
  (rust-git, built against the previous snapshot, was not in the batch). A run
  whose selection installs llvm-git MUST rebuild rust-git in the same
  selection — a start-of-run probe cannot see a skew the run itself creates
  mid-run (enforcement in rule 13). Companion rule: every recipe invoking
  `cargo`/`rustc` in ANY phase needs a `rust-git` edge in its topology
  record — `mold-git`'s deliberate empty-edges record
  was valid syntax but a wrong declaration once its cargo-based
  Rust-PGO rework made it a system rustc consumer, so the scheduler dispatched
  mold before rust-git exactly as declared and mold died on the skewed `rustc`
  one llvm-snapshot bump later. `--audit`'s toolchain lint now flags
  violations; re-verify a `pkg:` no-edge record against the recipe's real
  toolchain usage, not its history.

- **DESTDIR survives a failed build(); the next install won't forgive it**
  (2026-09-25, rust-src chain): makepkg wipes `$pkgdir` before
  `package()` but keeps `$srcdir`, so a `build()` that fails *after*
  mutating dest-rust (manifests deleted, relative tool symlinks created,
  licenses moved) leaves the next run's `install.sh` to die on `cp: not
  writing through dangling symlink` and to leak `.old` backups into the
  package. Wipe `dest-rust`/`dest-src` at the top of `build()`; the
  recipe fixture pins the line.

- **Upstream renames make implicit install sets unstable** (2026-09-25,
  rust-src rename): rust-lang/rust@abcb9780d6d4 renamed x.py's `src`
  install step to `rust-src`, and its default run also gates on
  `[build] extended` — which rust-git's bootstrap.toml never set. Bare
  `x.py install` then silently skipped `rust-src`, and `_pick dest-src`
  aborted the build *after* a 35-minute compile. A recipe that packages a
  component split must invoke that component's install step explicitly;
  a `tools` entry rename means refreshing the `source=` checksum in the
  same edit (makepkg refuses a stale b2sum before compiling — cheap when
  you touch the file, ruinous when you forget). Judge builds by the log
  and the artifacts, never by a piped shell's rc: `cmd | tail` reported
  rc=0 over a failed makepkg. `tests/rust-recipe.sh` pins the step, the
  tools entry, and the checksum.

- **lld does not run GCC's LTO plugin; mold and bfd do** (2026-09-25,
  rust-git `!lto`): makepkg's `lto` option appends `LTOFLAGS=-flto=auto`
  to CFLAGS/CXXFLAGS/LDFLAGS, and anything that compiles C/C++ from those
  flags under `lto` produces GCC-LTO GIMPLE objects — invisible to `file`
  (still "ELF relocatable"), readable by `nm`, but with the real code only
  in `.gnu.lto_*` sections. rustc's default linker is `gnu-lld-cc`
  (`cc -fuse-ld=lld`), and lld accepts `-plugin` silently yet never
  materialises the symbols: rust stage1 shipped a `librustc_driver.so`
  with 140 undefined `LLVMRust*` and died on `--no-allow-shlib-undefined`
  (repro: plain `.o` + wrapper archive, rc=0, still `U` — on LLD 23.1 and
  24, with and without gcc's full plugin chain; mold and bfd both define
  it). A recipe linking C/C++ through rustc/ld.lld must carry `!lto`
  (deleting the line does nothing — global OPTIONS enables it);
  Rust-side fat LTO in bootstrap.toml is unrelated and stays.
  `tests/rust-recipe.sh` pins the option in PKGBUILD and .SRCINFO.

- **`-s` on a VCS recipe cannot see upstream movement** (2026-09-25,
  vulkan-pair): the skip predicate is archive-mtime ≥ PKGBUILD-mtime, and a
  PKGBUILD does not change when upstream does — a `-s -i` batch skipped
  `vulkan-headers-git` at 1.4.363 while `vulkan-icd-loader-git` fetched
  v1.4.364, whose CMake requires VulkanHeaders ≥ `${PROJECT_VERSION}`
  ("not compatible with the version requested"). Rebuild coupled VCS pairs
  together with `-i` and without `-s`; the loader now carries
  `vulkan-headers>=1:${pkgver%%.r*}` so a stale provider fails at the
  dependency check instead (fixture `tests/vulkan-pair.sh`).
- **Self-consistent is not verified** (2026-09-20, audit): `sync_stable_version`
  bumps a `packages/stable` recipe to the repo's `pkgver`/`pkgrel` and
  deliberately does not refresh `sha256sums`, so `build_package` added
  `--skipchecksums` to `makepkg` for that build. Nothing said so. The audit
  found it by grepping for the string across the whole repository: it appeared
  **once**, in the builder, and in **no** document — the argv echo that would
  have shown it sits behind `_BUILD_QUIET`, and `build_package` is reached from
  exactly one call site, which always passes `quiet_flag=1`. So in the shipped
  flow the flag reached neither the terminal nor any log, and `--help` described
  `--no-sync` only as "don't auto-update stable package versions". Grep a
  security-relevant flag for its documentation, in both directions: a flag with
  one mention and no doc is a finding.
  The first fix was disclosure, and it was wrong. Disclosing a lowered guard
  does not raise it, and the refusal it replaced told the maintainer to run
  `updpkgsums` — which hashes whatever arrived, so it agrees with a substituted
  tarball and verifies nothing. The version came from Arch; the bytes come from
  upstream; the anchoring has to come from the same place as the version. The
  builder now fetches the official `.SRCINFO` for the version it synced to,
  matches every *moved* source against Arch's published sums, writes with
  `updpkgsums`, and verifies the fetched source against Arch's checksum.
  Anything it cannot anchor used to refuse the build outright — and one
  unanchorable entry cost a 126-package run ~120 undispatched packages. The
  stance split on 09-24: an entry Arch publishes a value for is
  anchor-or-refuse (mismatch refuses, restores, and stops the dispatch); an
  entry Arch publishes NO checksum for is refreshed by that same `updpkgsums`
  run and recorded LOUDLY as fetch-only — the manual remedy it used to
  prescribe, automated, with the review/commit instruction in the run-level
  `Synced with the repo this run` summary; with no official document the
  recipe refuses, restores, and is DEFERRED — parked with a named marker and
  its recovery lines while the dispatch continues, its dependents held back
  and labelled `waits on a deferred package`.
  `tests/stable-sync-checksums.sh` pins every scenario in its header and
  `tests/anchor-defer.sh` pins the deferral end to end; each was falsified
  before being trusted — reverting the sum map, the `name::` rule, the source
  diff, the VCS branch, the tag fallback, the refresh-only branch or the
  defer switch each makes scenarios fail exactly where they should.
  The same sync OWNS `pkgver`/`pkgrel` on `packages/stable` recipes: it
  rewrites them to the repo's values EXACTLY and in BOTH directions on every
  loader run (2026-09-26 campaign: `openshadinglanguage` was rewritten
  1.2→1.1 *down* to the repo's 1.15.3.0-1.1, `wireplumber` 0.5.17-1.1→2.1),
  so a local `pkgrel` bump on a stable recipe is clobbered before it can
  even be built. The standing convention is to align committed values to the
  repo (campaign decision: OSL `pkgrel=1.1`, wireplumber `0.5.17-2.1`)
  rather than fight the sync; a deliberate local bump needs `--no-sync` and
  should expect the mismatch to stay visible until the repo catches up.

- **Sources and checksums in a .SRCINFO line up only within one algorithm**
  (2026-09-20, same work): Arch publishes the same file list once *per*
  algorithm, concatenated (`sha256sums =` ×N followed by `b2sums =` ×N), so
  reading all checksum lines as one flat list cannot be indexed by source. With
  one source and two algorithms the counts never matched, and eight of the 28
  `packages/stable` recipes refused the build with "does not line its sources up
  with its checksums" — a misleading message for a file that was perfectly
  parseable. Take the first *contiguous* run of one algorithm and require it to
  be exactly as long as the source list; anything else must fail closed rather
  than anchor to half a list.

- **The name makepkg fetches under is not the URL's basename** (2026-09-20,
  same work): a `name::url` override (`udisks2::git+…`,
  `openshadinglanguage-1.15.3.0.tar.gz::https://…/v1.15.3.0.tar.gz`) downloads
  to `name`, while the basename of the URL is something else entirely. Looking
  the file up by basename found nothing — and for `util-linux`'s renamed
  `LICENSE` it found a *different* file with the same name, which produced a
  false mismatch. The same error in the other direction would have verified the
  wrong file while reporting success, so resolve a source's filename the way
  makepkg resolves it, override first, and treat a VCS prefix as "inspect the
  URL part after the override" — `fish::git+https://…` is a checkout, and a
  check on the raw entry reads it as a tarball.

- **A VCS source's checksum is a git-archive hash, so verify it as one**
  (2026-09-20, same work): for `git+…#tag=v`, makepkg's `calc_checksum_git`
  hashes `git archive --format tar v`, and that value is reproducible across
  machines — Arch's published sum for `fish` 4.9.3 matched ours byte for byte,
  and our recipe's committed sum was simply wrong (it failed makepkg's own
  integrity check, which a build only escapes by disabling checksums). So
  anchoring a VCS entry is real cross-checking, and the verification must
  re-derive the archive hash; hashing the checkout directory cannot work and
  reporting "not fetched" would refuse a buildable recipe.
  The check is only reproducible off a **full** mirror: a
  `git clone --filter=blob:none` renders an `export-subst` file differently
  (`cmake/CcacheVersion.cmake`, 3350 vs 3313 bytes) and produced a false
  mismatch, so mirror with a plain `git clone --bare` and never a filter.
  Sweeping every `packages/stable` recipe against Arch the same day found
  **four whose committed sums were wrong** — fish 4.9.3, upower 1.91.4,
  ccache 4.14 and systemd 261.3, all VCS `#tag=` sources, all at the same
  version as Arch's own packaging. Each was confirmed independently (a fresh
  mirror plus `makepkg --verifysource` / `updpkgsums`) before being written,
  and each had been shipping a sum that only a build with checksum
  verification disabled could survive. A recipe that has never been built with
  verification on is not evidence that its sum is right.

- **A deny-list and a delete-list are the same list** (2026-09-20, tree cleanup):
  the root `.gitignore`'s downloaded-archive set and `nuclear_cleanup()`'s match
  test were written twice and had already drifted twice (first `svn://`/`*.whl`,
  then `.zip`/`.jar`/`.tgz`/`.ttf`), each time repaired by appending one more
  pattern to one of them. The visible cost was 36 MB of upstream archives
  committed and pushed. They are now one list, `_DOWNLOAD_ARCHIVE_EXTS` in
  `build-all.fish`, and `tests/cleanup-extensions.sh` cross-checks it against
  `.gitignore` **in both directions** so a third drift fails a fixture rather
  than a sweep. Its wildcard member is quoted for a second reason: fish
  glob-expands an unquoted `tar.*` and silently drops it when nothing matches.
- **Text wrapped in a colour escape is text lost off a terminal** (2026-09-20,
  same fixture): the builder shadows `set_color` with a wrapper that emits
  nothing when stdout is not a tty, and fish drops an *entire word* like
  `(set_color cyan)"text"(set_color normal)` when the substitution yields
  nothing. `echo` therefore printed a blank line, and `-ccc`'s "will delete N
  targets" banner — the last thing a maintainer sees before agreeing — was
  invisible in exactly the piped mode the docs say to parse. Write such lines as
  `printf '%s%s%s\n' (set_color cyan) "text" (set_color normal)`; the text is its
  own argument and survives either way.
- **A comment in a tracked file is public surface** (2026-09-19, linux-cachyos):
  the debugging facts that justify a knob — the running kernel version, the CPU
  thread count, the bootloader command line, the incident that motivated it —
  are exactly what `CONTRIBUTING.md` excludes as "host-specific logs and
  profiles", and they had leaked into 16 comment sites across two commits.
  Rewriting them forced the *claim* to move, not only the wording: the AutoFDO
  drift note had rested on host state the committed `config` does not contain
  (it carries no `AUTOFDO_CLANG`/`PROPELLER_CLANG` line), and `_host_tune` had
  rested on a thread count where the committed `config` already carried
  `MAXSMP=y`, `NR_CPUS=8192` and `CPUMASK_OFFSTACK=y` server defaults. A
  claim grounded in committed files survives de-hosting; one grounded in the
  machine does not — which is the signal that it was never a recipe fact.
- **An unclean shutdown zeroes freshly written files** (2026-09-19, bettbox):
  XFS log recovery restores metadata without the data of the last seconds, so a
  file keeps its size and mtime with zeroed content — undetectable by any size
  check. It broke `go mod tidy` (`zip: not a valid zip file`) while the recipe
  was correct, and it zeroed the agent's own session `plan.md` mid-write. For a
  Go recipe the red signal is `go mod verify` in the module's directory, and the
  repair after a hard freeze is `go clean -modcache` (a targeted purge cannot see
  the size-preserving class). `tools/go-modcache-check.sh` detects the four
  detectable classes read-only; `tests/modcache-check.sh` pins it. Generally:
  after any hard power-off, verify the *consumer* of the file before blaming the
  recipe or the tool.
- **Freeze forensics: pstore is the channel, not the journal** (2026-09-19
  armed, 2026-09-20 stood down): `efi_pstore` is disabled by default
  (`pstore_disable=Y`), so `/sys/fs/pstore` receives nothing until it is set
  to `N` — validated with a deliberate `Alt+SysRq+c`, where the panic landed
  in pstore (17 compressed records, self-reboot in 27 s) and **never reached
  the journal**: an empty journal is not evidence that nothing happened.
  `WQ_WATCHDOG` and `PSTORE_CONSOLE` are **config-only** — they need
  `_capture_chain=yes` in the environment for that kernel build (the knob
  survives, default `no`). The 2026-09-19 capture chain (heartbeat witness,
  sysctl/journald drop-ins, panic parameters) was removed on 2026-09-20
  because a diagnostic left running past its question is unmeasured
  overhead. Everything needed to re-arm it is preserved:
  `/root/freeze-diag-backup-20260920/` holds the backed-up files and is the
  re-arm recipe; the pre-cleanup command lines are in
  `/etc/default/limine.bak-20260920-pre-diag-cleanup` (the earlier
  `/etc/default/limine.bak-20260919-freeze-diag` carries `nowatchdog`).
- **A version bump must regenerate `.SRCINFO`** (2026-09-19, bettbox): it pins
  pkgver, provides, the source URL and sha256sums, so a stale copy makes anything
  consuming the recipe build the wrong sources against the wrong sums —
  silently. bettbox's PKGBUILD was 1.19.2 while `.SRCINFO` was 1.19.1 with the
  previous hash. Several per-recipe fixtures used to re-check their own copy;
  `tests/srcinfo-freshness.sh` is now the single owner: it regenerates and diffs
  every recipe the `--topology` channel lists (one job per hardware thread,
  `GSA_SRCINFO_JOBS` to override).
- **The kernel patch set is version-scoped, and `updpkgsums` prefers a cached
  copy over the URL** (2026-09-19, `linux-cachyos`): `_patchsource` is
  `.../kernel-patches/master/${_major}`, so one version bump invalidates *every*
  patch filename at once. The 7.3 set carries only `sched/0001-bore-cachy.patch`,
  `misc/dkms-clang.patch` and `misc/nvidia/`: `misc/0001-rt-i915.patch`,
  `sched/0001-prjc-cachy.patch` and `misc/0001-hardened.patch` no longer exist,
  and the nvidia patches renumber (`0002`/`0003` → `0001`/`0002`). Worse, the
  recipe's startdir *is* `SRCDEST`, and the tracked patch files sitting there are
  the ones makepkg actually uses — so `updpkgsums` prints "Found <file>" and
  re-sums the stale local copy rather than fetching the new one. The sums stay
  green while the build applies the previous kernel's patch (7.3's
  `0001-bore-cachy.patch` is 42,503 B against 7.2's 40,750 B). Refresh the
  tracked copies by hand (or delete them) before trusting the sums, then prove
  each one with `patch -Np1 --dry-run` against the extracted tarball. Related:
  `scripts/config` sets symbols blindly and `olddefconfig` then drops the
  unknown ones, so a symbol that vanished upstream is a **silent** feature loss —
  check the ones that carry the variant's identity (`PREEMPT_RT`, `SCHED_BORE`)
  still exist in the new tree. `tests/kernel-recipes.sh` now pins the part
  that is checkable offline: the tarball URL must name `pkgver`, and every
  `_patchsource` URL must sit under the `pkgver`'s major.
- **A `b2sums` literal serves one knob combination, and makepkg's error for the
  rest names nothing** (2026-09-19, `linux-cachyos`): `source[]` is assembled
  from `_cpusched`, `_build_zfs`, `_build_nvidia_open` and `_build_r8125`
  (measured — `_use_llvm_lto`, `_build_debug`, `_autofdo`, `_propeller`,
  `_capture_chain`, `_hardened` and `_host_tune` change nothing), while
  `b2sums` is one flat literal sized for the defaults. Switching a
  source-affecting knob therefore aborted *after* "Retrieving sources" with
  "Integrity checks (b2) differ in size from the source array" — naming neither
  the knob nor the remedy, and reading like a bad download. The recipe now
  checks the pair at parse time, names both counts and the knob values, and
  exempts `makepkg -g` (`GENINTEG=1`): without that exemption `updpkgsums` —
  the remedy itself — could not run. Do **not** "fix" it with per-knob
  `b2sums+=(…)` next to each `source+=(…)`; `updpkgsums` rewrites the whole
  assignment on every version bump, so the appends double-count. Upstream
  sidesteps this by shipping one PKGBUILD per scheduler; a merged recipe cannot.
  `tests/kernel-recipes.sh` pins the guard, its exactness and the
  exemption.
- **A diagnostic on a captured stdout is swallowed, and a range indexes the
  selection, not the whole set** (2026-09-19, `build-all.fish`): `resolve_group`
  wrote "unknown group 'gti'" to stdout while `main` read the group with a
  command substitution, so `-g gti` exited 1 having printed nothing — the exit
  status was the only evidence. Put diagnostics on stderr. The same change
  added the reference forms a user actually has in hand: recipe ID and recipe
  path always worked, and now so do a case-variant ID (`MESA-GIT`) and a pacman
  `pkgname` including a split output (`zen-browser` → `zen-browser-pgo`,
  `libstdc++-snapshot` → `gcc-snapshot`), each announced by `_ref_form_note`.
  The index comes from the committed `.SRCINFO` files (218 names, none shared by
  two recipes, no unexpanded variables), never from PKGBUILD evaluation. A
  **typo is never auto-corrected** — a wrong guess builds a whole dependency
  chain — it is reported with up to three candidates, ranked by an awk
  Levenshtein sweep (fish costs ~0.4 s per token for the same answer).
  Separately: a **range indexes the selection**, so read `-l -g GROUP` before
  choosing one — `-l` now honours the selection and `-n` with none covers the
  whole set. Out-of-bounds ranges name the selection size, clamped bounds warn,
  and `..` is refused. `tests/project.sh` pins all of it (red on five
  mutations, including one that reverted the `>&2` and was only caught because
  the assertion checks the *channel* rather than the merged text).
- **A `scripts/config` write is not evidence, and `!SYM` ≠ `SYM=n`**
  (2026-09-19, `linux-cachyos`): the recipe's `_hugepage` knob had never worked
  — `mm/Kconfig` gates the THP menu on `!PREEMPT_RT` and `_cpusched=rt-bore`
  sets `PREEMPT_RT=y`, so `scripts/config` wrote the symbol and the next
  `olddefconfig` deleted it without a word. Two more knobs were dead the same
  way (`_use_kcfi` wrote two names that no longer exist; `cachyos`/`eevdf` wrote
  `SCHED_BORE`, which only the BORE patch adds). The recipe now builds an
  expectation list beside each write and `prepare()` verifies the *resolved*
  `.config` against it via `packages/misc/linux-cachyos/verify-config.sh`,
  aborting with a named reason (`tests/kernel-recipes.sh` pins it). Two
  rules fall out. (a) Only the post-`make prepare` file is evidence. (b) `!SYM`
  and `SYM=n` are different claims: a `choice` member whose prompt is hidden by
  a false `if` (`bool "Cubic" if TCP_CONG_CUBIC=y`) vanishes from `.config`
  entirely, while a merely unselected member is written `# CONFIG_X is not set`
  — in the same choice, `DEFAULT_RENO` is `n` and `DEFAULT_CUBIC` is absent, so
  assert `!SYM` for these. Related trap, found by the new fixture: an
  unconditional `!SYM` in an invariants list must not contradict a toggle's
  `-e SYM` — `!AUTOFDO_CLANG` alongside `_autofdo=yes` made the AutoFDO path
  unbuildable.
- **Soname provides — the full mechanism** (libunwind/wireplumber/gegl/babl):
  pacman 7.1 does NOT derive soname provides at `-U` time and makepkg does
  NOT synthesize them for undeclared libs (`autodeps` is config-only and
  rejected by lint). But makepkg `find_libprovides` DOES auto-version any
  `*.so`-suffixed provide entry from the packaged lib's ELF soname:
  declare the BARE `libfoo.so` in provides= → packaging emits
  `libfoo.so=<soversion>-<arch>`. Versioned sonames give `0-64`; unversioned
  sonames give `libfoo.so=libfoo.so-64` — which CANNOT be written literally
  (check_fullpkgver lint splits at the last hyphen and rejects the hyphen
  left in the ver part). Declare bare sonames; verify .PKGINFO.
- **Meson options**: (a) `--auto-features enabled` (arch-meson) turns
  missing auto deps into fatal configure errors — probe with a throwaway
  `arch-meson <src> /tmp/probe` to enumerate ALL missing deps in one pass,
  then disable explicitly (util-linux translate-docs, gegl mrg/maxflow).
  (b) `Unknown option` at setup = upstream RENAMED an option — check the
  tree's meson.options (xdg-desktop-portal: docs→documentation, man→man-pages).
  (c) Option TYPES matter: `feature` takes enabled/disabled/auto, `string`
  takes a value (util-linux `python` vs `build-python`).
- **Docs-only makedep removals have blast radius**: autogen.sh may hard-fail
  (xz → `--no-po4a`); meson `.require(tool.found())` chains hard-fail; a hard
  `install` of an artifact nothing builds anymore aborts packaging (zsh-doc
  PDF); makepkg silently reinstalls purged tools if a makedep remains.
- **LLVM coupling — two failure modes**: (1) TARGET-SET skew: rustc's driver
  links `LLVMInitialize*Target*` for targets present at BUILD time — a
  minimal-target llvm-git installed over a rust-git built against full llvm
  bricks rustc (single version node LLVM_24.0 makes ANY missing sym report
  LLVM_24.0 — diff `readelf -W --dyn-syms` sets, don't trust the version
  string). Rebuild rust-git; bootstrap is immune (bootstrap.toml sed-deletes
  rustc/cargo/rustfmt lines — keep the rustfmt deletion). (2) VERSION-NODE
  skew: llvm-git exports ONLY `LLVM_24.0`; SONAME shims satisfy linking but
  not versioned lookups → everything linking libLLVM must be rebuilt per
  major bump (scan `readelf -V` over consumers; OSL fixed via house
  1.15.3.0-1.2 + osl-llvm-compat.patch — expect re-patching when upstream
  still caps below installed llvm-git).
- **mold false-negatives `has_link_argument(-Wl,--version-script=…)` → zero
  verdefs** (util-linux libuuid/libblkid): meson probes link a trivial
  conftest with `--fatal-warnings`; mold hard-errors on version-script
  symbols absent from the conftest where GNU ld tolerates → check NO → link
  arg dropped → zero `.gnu.version_d` nodes (link-time `undefined reference
  to uuid_unparse_lower@UUID_1.0` in stock consumers). Fix: `LDFLAGS+=`
  `-fuse-ld=mold -Wl,--undefined-version`. Any has_link_argument probe whose
  flag touches symbol/version semantics is suspect under mold; re-verify
  `readelf -V | grep -c VER_` after mold bumps/linker flips. (An earlier
  meson-r175 attribution was DISPROVEN.)
- **makepkg LTO-strip hook hollows slim-LTO static archives** (qt5-base-git):
  tidy `safe_strip_lto` strips `.gnu.lto_*` from EVERY packaged `.a`; slim-LTO
  members (GCC ≥12 default) are pure IR → symbol-less stubs. Fix: force
  `-ffat-lto-objects` (removing `-fno-fat-lto-objects` is NOT enough); full
  clean rebuild after any mkspec/flag change. Verify:
  `ar p <a> <member> > f.o && gcc-nm f.o | grep -v gnu_lto | wc -l` —
  gcc-nm needs a REAL FILE (stdin pipe silently returns nothing) and never
  `|| fallback` onto `grep -c` (exit 1 on zero makes hollow look like -1).
  `-Rf` can never fix tidy-mutated content (it reproduces it byte-for-byte).
- **makepkg packaging traps**: stale `$srcdir/<dir>` + a parent AUR-mirror
  `.git` → wrong pkgver/tree (wipe `src/ pkg/`); split STAGING dirs live
  under `$srcdir` (clean `src/<pkgbase>-libs`, never the PKGBUILD root; audit
  `install -d` lines that only "happen" to create later mv targets); when
  disabling a meson feature remove EVERY `_pick` path it installed (dirs AND
  globs — a dir-only pick survives content-pick removal and aborts under
  set -e); package()-scoped provides/conflicts OVERRIDE globals in split
  PKGBUILDs (global-only edits silently do nothing).
- **glog/gflags double registration**: abort names two flag-definition files
  — one under `/usr/src/debug/<system-pkg>` = system lib's static init, one
  `extern/…` = vendored copy compiled in; find who pulls the system copy via
  per-lib `readelf -d`/ldd (blender: libceres); prefer
  `-DWITH_SYSTEM_GLOG=ON -DWITH_SYSTEM_GFLAGS=ON`-style CMake options.
- **IgnorePkg**: 62 names were once unprotected (2026-09-06) and the closure
  drifted **32 names short** again (2026-09-19: the three
  `linux-cachyos-rt-bore-lto*` outputs, all 30 `texlive-*` splits, and more —
  221 → 253 entries, fixed same day). Keep the closure diff empty after
  adding any package (audit method in golden rule 9). Back up
  `/etc/pacman.conf` before editing it — the file accumulates repeated
  `IgnorePkg =` lines and a mistake is silent until `-Syu` replaces a house
  package.
- **Qt pkgver()**: MUST grep `QT_REPO_MODULE_VERSION` from `.cmake.conf` —
  git describe is unusable on Qt dev branches; pacman 7 makepkg needs a
  non-empty static pkgver= placeholder. qt6-speech packages EMPTY without
  Multimedia — rebuild it AFTER multimedia.
- **PGO operational**: root-owned gcda appears if instrumented daemons are
  installed mid-iteration (→ sudo rm -rf src, avoid installing); gcda
  verification via `find <dir>`; MT trainers need `-fprofile-update=atomic`;
  an instrumented **installed** binary bakes absolute `.gcda` destinations into
  itself and re-creates the whole tree on every run, so check a shipped binary
  with `strings -a <bin> | grep -c '\.gcda'` — `readelf -sW` alone is a **false
  negative** on anything makepkg has stripped (2026-09-19);
  the payload gate lives in `build-all.fish` (`verify_pgo_payload`, the
  fail-closed whole-set backstop: strings-only, post-strip, whole-archive,
  gated on the sibling PKGBUILD matching `-fprofile-generate|-C
  ?profile-generate`) because per-recipe verification produced two separate
  recurrences and is the wrong seam for a whole-set invariant;
  the per-recipe check is ONE shared fatal gate: a PGO recipe sources
  `lib/pgo.sh` via `$startdir` (`source "$startdir/../../../lib/pgo.sh"`) and
  calls `verify_no_profile_instrumentation "$pkgdir"` as the LAST statement of
  `package()` — of each `package_*` split function, against that function's own
  `$pkgdir`. The gate is fatal (`exit 1` kills makepkg's function subshell)
  precisely because bash returns a function's LAST command status, so a
  mid-function call's failure was silently discarded — the mechanism that left
  four guard call sites **decorative** and silently packaged instrumented
  payloads until 2026-09-20. The `|| return 1` convention is dead (its lint is
  deleted): never reintroduce it for a check that must stop a build. Recipes
  call the gate and never copy its implementation (the per-recipe copies had
  drifted — mold-git's predicates were stricter than the rest);
  counts (2026-09-26, two different predicates on purpose — do not conflate
  them): **23** recipes are PGO-instrumenting (predicate: a
  `packages/*/*/PKGBUILD` containing `profile-generate` in any spelling —
  `-fprofile-generate`, `-Cprofile-generate`, `--enable-profile-generate` —
  or `profiler=true`; the last matches zero recipes today) versus **7**
  recipes calling the shared gate (`grep -l 'lib/pgo\.sh'
  packages/*/*/PKGBUILD`). The builder's own gate predicate covers 22 of the
  23; the earlier "21 instrument / 6 guard" figures are superseded by the two
  predicates above (re-measured 2026-09-26);
  that scan is **whole-archive** (subtree scoping embeds an install-location
  assumption and misses a `usr/libexec` leak, while `.PKGINFO`/`.BUILDINFO`/
  prose each pass the standalone-path predicate) and
  **fails closed** (a `tar` extraction that yields nothing is an error, not a
  clean result) (2026-09-20);
  a Meson PGO reconfigure must replace `c_args`, `cpp_args`, `c_link_args`,
  and `cpp_link_args` together so phase-1 `-fprofile-generate` cannot remain;
  profile-use configure probes need `-Wno-error=missing-profile`; verify the
  staged package payload rather than temporary `build/meson-private` helpers;
  GCC `-fprofile-use` may also need `-Wno-error=format-overflow
  -Wno-error=coverage-mismatch`; GCC 17 experimental ICEs on -fprofile-use
  are sometimes TRANSIENT (retry once when the box was OOM-stressed;
  systemd's was deterministic).
- **Operational**: never append commands behind a live async terminal;
  `pacman -Qdt` empty ≠ no cruft; `pacman -U --noconfirm --ask 4` for
  conflict-replace installs; transcript jsonl is a reliable crash-recovery
  source; transient `curl 56 SSL_read` on huge fetches → resume with
  `git -C src/<repo> submodule update <path>`. Fetch flakes are usually
  transient (2026-09-26 campaign): TLS `unexpected eof` hit four hosts
  (documentfoundation, its mirror — which also 404'd —, code.qt.io,
  invent.kde.org) and plain retry worked every time, and a failed `git
  clone` self-cleans its partial directory. But a REPO package 404ing on
  ALL mirrors means a stale local pacman db, not a vanished upstream —
  `sudo pacman -Sy`, then retry (plasma-wayland-protocols, 2026-09-26).
- **A signal storm corrupts what it kills** (2026-09-23): `stop_lane_process`
  used to TERMed every lane PID every 50 ms with SIGKILL at 0.5 s; a pacman
  caught mid-unlock never removed `db.lck`, so every later install hard-failed
  (`could not lock database: File exists`) and runs died seconds after start.
  Now: **one** TERM, a deadline-based 30 s grace (`_LANE_STOP_GRACE_S`), one
  logged SIGKILL of survivors. Two standing contracts came with it: a stale
  `db.lck` is removed only after two idle holder-probes 1 s apart (busy →
  report + recovery text, refuse `-i`/`-ia`, never remove) with the path from
  `pacman-conf DBPath`; and **every pacman a lane can reach goes through the
  one flock** — `lane_job` exports `PACMAN=$LOG_DIR/.pacman-shim`
  (`flock -x -w 300 … pacman "$@"`) because makepkg's own `-s` dep installs
  otherwise race the builder's `pacman -U` (makepkg honours `PACMAN=`, verified
  `/usr/bin/makepkg:1203`). Deadlock-free: `run_pacman_locked` is a leaf.
- **Closing the terminal window SIGTERMs the whole run, and half-commits
  pacman's local db** (2026-09-24, vscodium-insiders): dispatcher.log's first
  real capture named the sender — `TERM … chain=fish ← sudo ← systemd --user
  ← init`: the launching shell died, systemd user-scope teardown TERMed
  everything, and 3 s later its in-flight `pacman -U` was a corpse mid-commit.
  Long builds belong in a terminal you keep open (tmux); a dead run is
  diagnosed from dispatcher.log first. The corpse signature is a
  `local/<pkg>-<ver>/` dir **missing `desc`/`files`** (only `mtree`), and its
  headline symptom is pacman's misleading `invalid or corrupted package` —
  that error indicts the LOCAL db, never the archive (makepkg's `.BUILDINFO`
  additionally prints the raw `desc` open error). The entry is unusable in
  every direction (`-U`/`-R`/`-Ql` all hard-fail), so the only repair is
  entry removal + `pacman -U` (with `--overwrite '*'` for the half-removed
  package's now-orphaned files). `check_pacman_db_health` performs that repair
  at the same four sites as the lock probe — busy holder → report-only,
  provably idle (two probes 1 s apart) → remove loudly and tell you to
  reinstall with `-s -i`/`-ia`; fixture `tests/local-db-repair.sh`, hidden
  seam `--local-db-check <path>`.
- **A lane must record its own death, and the run must name its signal**
  (2026-09-23): a 19:34:01 event killed dispatcher+lanes simultaneously and
  nothing on disk said who — in code lanes are only TERMed by the interrupt
  path, but post-hoc that was unprovable. Lane children used to *swallow*
  INT/TERM via the dispatcher's handler, so a signalled child produced the
  clueless `lane supervisor produced no valid result` (rc=125). Now the
  handlers are split: dispatcher mode logs `[DEBUG-gsa-term] signal: …` to
  `$LOG_DIR/dispatcher.log` (INT/TERM/**HUP** — HUP used to orphan lanes
  silently) and lane mode writes an honest result (129/130/143) before
  re-raising. Fish trap: `exit` inside a handler always yields rc 0 — erase
  the handler and re-raise; the result *file* is the channel that matters
  (fish exits 0 on INT even handler-less). rc=125 without forensics = bug;
  rc=125 WITH `(no bytes)` forensics can still be a lost race — result reads
  and liveness checks are not one atomic observation, so the reap re-reads
  the file once after the child is observed dead (publication happens-before
  death; 2026-09-24 lane-reap flake).
- **Sandbox paths have a length budget** (2026-09-23, noctalia): anything a
  compositor/socket writes under `XDG_RUNTIME_DIR` must fit the 108-byte Unix
  `sun_path`; sandboxing it under a deep `$srcdir/pgo-work` made sway die at
  startup (`Socket path won't fit into ipc_sockaddr->sun_path`, SEGV in
  journal), the GUI training never ran (1 `.gcda`), and the build failed. Put
  runtime dirs for sockets in a short `mktemp -d /tmp/…` (700, removed on
  exit), tear the training tree down as a **group** (`setsid` + TERM → bounded
  grace → KILL) so no stray sway survives, and run CLI-only training with
  `WAYLAND_DISPLAY` unset.
- **meson's `b_pgo` enum is off/generate/use — there is no `none`**, and a
  `-git` `pkgrel` bump does not survive its own acceptance build
  (2026-09-23, noctalia): the incomplete-profile fallback `-Db_pgo=none`
  hard-failed `build()` exactly when training had already degraded (the
  fallback path runs least often and was never exercised). Use `-Db_pgo=off`.
  Separately, stock `update_pkgver()` rewrites the PKGBUILD and resets
  `pkgrel=1` whenever `pkgver()` moves — bump `pkgrel` **after** the first
  post-sync build of a `-git` recipe, and regenerate `.SRCINFO` last.
- **An upstream-track bump must re-pin version-spelled sums; a benchmark swap
  must check root-path requirements** (2026-09-23, zen): `5f4078b` bumped
  `pkgver` to 1.22.3b while `sha256sums[0]` still held the 1.22.1b digest —
  the recipe could not fetch at all; re-pinned against **GitHub's server-side
  asset digest** (hash + exact size, anchored not TOFU). Speedometer 3
  *requires a root path* (`sp3_httpd` on port 8000 exists for exactly this),
  so the fix for the deprecated SP2 workload was a **deletion-only** patch
  (`0007-pgo-speedometer3.patch`), never a relative `webkit/…` entry.
- **The battery runs in parallel now, so two things became contractual**
  (2026-09-24, harness): `tests/run-all.sh` executes fixtures concurrently by
  default (`-j`/`RUN_ALL_JOBS` to cap, `--serial` to debug; 45 scripts and
  ~4 min serial → 33 files and ~29 s). (a) A fixture must be parallel-safe:
  non-mutating, `$TMPDIR`-scoped, and every process assertion scoped to its own
  `$fixture` path — `signal-abort-lock.sh`'s global `--lane-job` scan was the
  documented "never run two batteries at once" tripwire and would have
  self-inflicted on every run, so it is path-scoped now. (b) Sibling subjects
  merge into ONE fixture file as `( subshell )` sections (own variables, traps,
  `fail()` prefix) instead of growing another top-level script; the five
  `*-pgo-transition.sh` wrappers folded into `pgo-transition.sh` (no args = all
  five pairs). `dashboard.sh` case C no longer waits out a real 30 s window:
  `_LANE_STOP_GRACE_S` is an env-overridable *internal* seam (default stays 30,
  pinned by `signal-abort-lock.sh`; not an eighth public `GSA_*` input), and
  `.SRCINFO` freshness has exactly one owner, `tests/srcinfo-freshness.sh`.
- **User-level fish wrapper functions intercept the battery's PATH stubs**
  (2026-09-26, harness): the builder runs under fish, and fish autoloads
  functions from `$fish_function_path` before any PATH lookup — so a
  user-level `sudo` wrapper shadows the `sudo` stub a fixture placed in front
  of `$PATH`, and that wrapper re-execs the real sudo with `--preserve-env`
  added (a flag the builder never passed; this is why `stub_sudo` in
  `tests/lib/fixture-lib.bash` strips it). Run the battery as
  `fish_function_path=/nonexistent-fp bash tests/run-all.sh` so no fish
  function can intercept a stub. A fixture failure that disappears under that
  prefix is a host-shell artefact, not a builder regression.
