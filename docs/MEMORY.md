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
   - bare soname provides ONLY — never hand-version a soname: makepkg
     auto-versions a bare `provides=(libfoo.so)` from the package version, so
     a hand-spelled `libfoo.so=…` duplicates the derivation and drifts from
     it (2026-10-04 provides normalization: 15 hand-versioned soname provides
     across 10 recipes reduced to bare stems until `--audit-lint provides` was
     clean; the recipe-contract ratchet emptied and became a strict gate). A
     versioned provide is for a NAME capability whose consumers constrain it
     by version — `shelly=${pkgver}` and the toolchain `meson=${pkgver}`
     pattern. Rename-compat provides after an upstream rename
     (`tracker3=`, `totem-plparser=`, `geoclue2=`, `tracker3-miners=`) and
     capability virtuals (`java-runtime=`, `java-runtime-headless=`,
     `java-environment=`, …) are exactly that kind of NAME capability — keep
     them pinned at stock's value; the "bare soname only" half of this rule
     governs SONAME provides and never authorizes dropping them. Counter
     example: 2026-10-09 run #93, where five recipes trimmed those pins "per
     house standard" and the upgrades then broke installed dependents
     (gtk3-git→`tracker3`, localsearch→`totem-plparser`), plus the jdk
     virtuals every `java-runtime`/`java-environment` consumer resolves
     through. `conflicts`/`replaces` for the retired old name stay dropped —
     they matter only while an old-named package is installed.
   - the name side is SONAME + NAME with opposite forms (2026-10-04 Q8
     decision): wherever a recipe MAPS a stock name — swaps it (Class A
     `provides=(<stock>=$pkgver)` + `conflicts=(<stock>)`), is the VCS
     counterpart of one of its outputs, or compat-maps an output name
     (including a cross-recipe map like `wireplumber`→`pipewire-session-manager`)
     — it declares a VERSIONED name provide `provides=(<name>=$pkgver)`;
     same for every name some workspace consumer constrains by version. The
     reason is the meson-incident one: an unversioned provide cannot satisfy
     `>=N`. A capability virtual (`libgl`, `ladspa-host`) maps nothing and
     stays unversioned; a package providing its own output name maps nothing
     either. Check: `fish build-all.fish --audit-lint provides` +
     `tests/provides-audit.sh`. 59 recipes (113 name pairs) predate this rule
     and are debt-ratcheted in `tests/recipe-contract.sh` section E — new
     recipes must comply; the debt shrinks one recipe at a time, never grows.
     (last reviewed 2026-10-04)
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
   GCC LTO objects are tied to their producing compiler build. The builder
   records the GCC version line per recipe under `.state/toolchains/` (or
   `GSA_STATE_DIR`) and, on missing/drifted state, removes `src/`, `pkg/`,
   `build/`, and matching archives before the `-s` check. It advances the
   marker only after a successful build and VCS revision recording. This
   rebuilds selected recipes once on compiler drift without scanning or
   bulk-cleaning every package tree; preserve the state directory across
   resumes. With `-s`, resolve a current-mtime VCS archive's refs before the
   automatic clean so an unreachable ref still refuses before its archive and
   baseline are removed.
   Stale libtool outputs poison in-place rebuilds the same way: makepkg
   re-extracts over a reused `src/` tree, and a leftover `libfoo.la` makes
   libtool resolve `-lfoo` to that `.la`'s `.libs/libfoo.so` — including when
   `libfoo` is merely a *dependency* of a module that shares its name (libao's
   pulse plugin vs the PulseAudio `libpulse`, 2026-10-06). The resolved input
   is the link's own not-yet-built output, so bfd, lld and mold all fail
   opening it; fresh trees link fine. A recipe hit by the collision purges
   stale outputs in `prepare()` (`find . -name '*.la' -delete`); the trigger is
   any rebuild over a reused tree, spurious ones included — e.g. a `git pull`
   rewriting a PKGBUILD byte-identically bumps its mtime past the archive and
   defeats `-s`.
7. **Don't touch in-progress builds**: check running makepkg processes and
   runtime log mtimes before rebuilding a package someone else is on.
   Never run two heavy builds concurrently (OOM).
8. **Purged tools stay purged** (system-wide): po4a, python-sphinx,
   python-myst-parser, lvm2, libblockdev-lvm, systemd-tests, cuda, gcc15.
   Never reintroduce via makedepends — makepkg reinstalls them silently;
   grep remaining makedeps after every trim. Since 2026-09-26 `--audit`
   enforces this with an exact-name lint over makedepends/checkdepends of
   every committed `.SRCINFO` (seam: `--audit-lint purged`). Trim discipline
   (2026-10-04 libuv-git/man-db breakage): when a purged tool is a recipe's
   only route to a feature, trim the feature AND its output together,
   `# trim:`-annotated at each removal site — libuv-git dropped its
   python-sphinx man-page docs stage and the `man1/libuv.1` install path,
   man-db dropped po4a translations with the `usr/share/man/<lang>/` + NLS
   locale trees. Dropping only the tool leaves a build that dies looking for
   it; dropping only the output leaves the stage that produces it — on a
   meson recipe the trim must disable the FEATURE (`-D docs=disabled`,
   `-D <x>_doc=false`), because `arch-meson` runs `--auto-features enabled`
   and turns every optional tool into a hard `find_program` requirement
   (2026-10-06 lilv-git: output+tool trimmed, `doc/meson.build` stage left
   live). Check:
   `fish build-all.fish --audit-lint purged` + the `# trim:` annotations at
   every removal site. (last reviewed 2026-10-04)
9. **IgnorePkg registration is dynamic** — the static closure contract
   ("every workspace pkgname must appear in the host conf") is retired
   2026-10-05. An install run (`-i`/`-fi`/`-ia`) registers the
   pkgbase+pkgname of every ACCEPTED archive (install rows AND skip rows)
   into the `[options]` `IgnorePkg` closure of the target pacman.conf
   (`/etc/pacman.conf` by default, `_IGNOREPKG_CONF` seam) before
   `pacman -U` runs. Name sources per archive, in authority order: the
   archive's own `.PKGINFO` `pkgbase`/`pkgname` lines, else the recipe
   directory beside the archive (house layout PKGDEST=$startdir): the
   committed `.SRCINFO` pkgbase+pkgname, else the evaluated PKGBUILD. An
   archive whose names cannot be established REFUSES the install (fail-closed,
   never a silent skip). The conf rewrite is deferred until the pacman
   database lock clears (bounded wait, default 300 s, `_PACMAN_LOCK_WAIT_S`)
   and the lock is NEVER deleted; a wait timeout or registration failure
   refuses the install before any transaction runs. `--no-register-ignorepkg`
   skips the step loudly (deliberate escape hatch, mirrored into the resume
   continuation arguments). A dated pre-image backup `<conf>.bak-YYYYMMDD` is
   written before the first modification of the day, never rewritten
   afterwards, never blocking a later write.
   `fish build-all.fish --register-ignorepkg [pacman-conf]` remains a one-shot
   BACKFILL of an existing conf (it computes the pkgbase+pkgname universe
   from the committed `.SRCINFO`s — never a PKGBUILD grep: the kernel's
   `pkgbase="linux-$_pkgsuffix"` hides the real names — and writes the same
   closure); the write half lives in `lib/audit.fish`'s
   `register_ignorepkg_names`. The static lint is GONE: `--audit` no longer
   prints an "IgnorePkg closure:" section, and the hidden seam is
   `--audit-lint <provides|purged|swap|abi-closure|abi-exposure>`.
   Check the closure the way pacman READS it: repeated `IgnorePkg =` lines
   inside `[options]` are cumulative, a line inside a repo section is
   silently dropped — diff the pkgbase+pkgname universe against
   `pacman-conf IgnorePkg | sort -u` with `comm -23` (empty = covered;
   `pacman-conf` reads the file directly and needs no database lock). Pinned
   by `tests/ignorepkg-register.sh`.
   (last reviewed 2026-10-05)
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
    Archive discovery evaluates `pkgver` and `pkgrel` as PKGBUILD shell
    values, including makepkg's post-build VCS `pkgver()` result. Unknown
    version metadata makes no archive eligible: checked `-i` refuses and
    `-ia` warns/no-ops. Never restore the glob-all fallback. This uses the
    same executable-recipe trust model as the existing PKGBUILD array reader;
    `-ia` evaluates recipes that have package archives.
    A glibc replacement is not a live-root build/test: the test suite can use
    the installed C library, and package hooks rewrite locale, linker, and
    iconv caches. Build, test, and install it only in a disposable VM or
    chroot; verify both native and 32-bit loader behavior there.
    Those installs are background jobs with no tty, so the dispatcher owns
    sudo liveness (see build-guide.md "sudo during --install"): it must never
    infer "installs are impossible" from `sudo -v` alone — a `NOPASSWD`
    sudoers entry makes `-v` fail forever while every install succeeds — and a
    run whose dispatch stopped early must exit non-zero instead of reporting
    success (2026-09-17).
    Install-plan and probe rows are TAB-framed through the one
    `plan_row`/`plan_row_fields` codec (2026-10-05) — never hand-built rows.
    A discovery omission refuses the plan by name (`refuse partial-set`,
    `refuse discover-failed`) and blocks `-ia`'s single transaction (a
    shrunken set is never installed); a failed plan without a row renders
    `refuse plan-failed`; a probe that cannot run emits `probe-skipped` and is
    never "clean"; freshness compares are nanosecond (`find -newermt`) with
    doubt-installs; `readelf` is an install prereq alongside tar/strings.
12. **Mandatory selection + keystone discipline** (2026-09-07): build-all.fish
    has NO default action — always pass `-g` and/or package names. For
    ABI-coupled core updates use `-g core` (auto-installs the merged core set);
    for leaf rebuilds use `--no-deps` — a selection expands to the package's
    consumers, so a consumer-free name is already a leaf while `--no-deps` is
    what keeps a consumer-bearing name leaf. New `_DEPS` edges are
    added ONLY after verification against `pacman -Qi Depends` (noctalia has
    NO qt6-declarative dep; NM-openvpn reaches ssl only via libnm).
13. **llvm-libs-git never moves alone** (2026-09-07 incident): LLVM snapshots
    have no stable C++ ABI — after any llvm-git/llvm-libs-git bump, rebuild
    rust-git + mesa-git + spirv-llvm-translator-git + openshadinglanguage IN
    THE SAME PASS (scan victims: /tmp/llvmvictims.sh pattern — grep /usr/lib
    for libLLVM links → pacman -Qo). rustc hits heap corruption/segfault on
    ANY compile otherwise. (rust-git's stage0 is the DOWNLOADED official
    one — 2026-09-08 recovery stripped bootstrap.toml's `/usr/bin` pins —
    so a rebuild works even with a broken or absent system rustc; the old
    "bootstrap IS the broken rustc" wording no longer holds.) Recovery
    when it happens: downgrade-rebuild llvm-libs
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
    `--skippgpcheck` or drop `#signed`. A `validpgpkeys` pin is inert until the
    key is in the **build user's keyring** — makepkg verifies against the
    keyring, so an import gap fails every signed source with `unknown public
    key` no matter how correct the pin is (js140 2026-10-06, then libxau the
    same day with 146 of 179 pins unimported). Sweep the whole set at once:
    enumerate every pin **quote-agnostically** (a quoted-literal regex missed
    90 of 269 pins; webrtc-audio-processing-1's bare pin walled run #13),
    `gpg --list-keys <pin>` each, import missing keys by exact fingerprint (a
    fingerprint-matched fetch is self-verifying); retired or
    keyservers-hostile keys come from the publisher's own keyring (Linus' and
    Greg KH's keys from kernel.org's `pgpkeys.git`). A subkey signature
    verifies against the pinned **primary** once it is imported (the binding
    covers it — libxau's sig is Coopersmith's signing subkey); an explicit
    subkey entry in `validpgpkeys` is only needed to pin a rotated signer.
    A detached `.sig` may carry **several** signatures and makepkg rejects
    the file unless every signer is pinned (libgcrypt 2026-10-06: gnupg.org
    added Niibe Yutaka as co-signer next to Werner Koch), so for a
    co-signing publisher pin the full current release-key set from its own
    key page, and resolve a sig's subkey fingerprint to its primary before
    calling a pin missing.

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
    package log and in the run-level `Version and checksum sync this run` summary,
    never silent). **And if the builder auto-updates a value, the new value must be checked
    against a source the builder did not itself produce** — self-consistent is
    not verified.
    Since 2026-10-01, the Arch path remains the default for untagged recipes;
    only a validated `version-sync=nvchecker` topology tag selects an external
    provider (`.nvchecker.toml` presence alone is not opt-in). The resolver runs
    one config section with disposable state outside the repo and normal
    `NVCHECK_STATE_DIR`. AUR `.SRCINFO` must match provider pkgbase and
    resolved pkgver, and must COVER the recipe's expanded sources — every
    recipe source verbatim in the provider's list, while provider-only
    extras are reported in the package log and never anchored (2026-10-07
    gcc-snapshot: AUR carries `gcc-ada-repro.patch` for the ada frontend
    this recipe trims, and byte equality refused a checksum anchor that was
    correct for every source the recipe does build) — before it supplies
    pkgrel/epoch or checksums; the coverage direction is one-way, so a
    recipe-side patch or extra file is a **recipe-superset** that refuses
    (`anchoring-refused`, deferred, rewrite restored — 2026-10-09
    gcc-snapshot): local fixes on an anchored recipe are applied from
    PKGBUILD content inside `prepare()` (heredoc patch, sed, or staging
    moves, like the mutations that recipe already carries), never added to
    `source=()`. At equal pkgver, never lower a local pkgrel. For GitHub, bind
    an asset digest to the configured repository, release tag and remote URL
    basename (not a `name::url` local override);
    when no digest is published, label refreshed sums fetch-only. Provider
    outages and AUR metadata races defer and restore rewrites; a published
    checksum mismatch stops the run and restores the recipe. Unsupported
    version mappings refuse. `--no-sync` suppresses Arch and nvchecker lookups,
    rewrites and checksum refreshes. Open the package log before sync so
    provider errors and anchor decisions survive the build path.
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
20. **One install decision, one seam**: `install_plan` computes the
    transaction plan once as silent rows (`install`/`skip`/`refuse`/`noop`)
    and only `install_execute` renders and runs the single `pacman -U`
    transaction — deciding again inside a render or execution path is what
    produced five divergent decision sites (NOTE.md, feature record wave 2).
    Decisions are fail-closed: an empty archive list is `refuse empty-list`
    under `--install` (rc 1) and `noop empty-list` under `--installall`, and a
    `-fprofile-generate` archive still carrying a baked `.gcda`/`.profraw`
    destination is `refuse pgo-*` via `pgo_payload_refusals`. Assert install
    behaviour through the hidden `--install-decide <checked|force>` seam (the
    plan rows on stdout, rc 0 plan / 1 refusal / 2 bad usage — no pacman
    transaction, sudo, flock or makepkg), never by scraping rendered output.
    Pinned by `tests/install-archive-guard.sh`, `tests/pgo-payload-guard.sh`
    and `tests/run-record.sh`.

20. **Packaged venvs use runtime paths, never build or staging paths**
    (2026-10-02 hermes-agent-git): rewrite source-tree references in launchers
    and metadata to the final runtime prefix (not makepkg's temporary
    `$pkgdir`), and fail the package if a build-source reference remains
    anywhere in the venv. hermes installs EDITABLE — upstream's `setup.py`
    refuses wheels outside a Nix build — so the rewrite must cover the
    editable finder and `.pth`, with build-time `__pycache__` stripped first.

21. **Group membership has membership tests** (2026-10-04 build-tools
    migration): (a) a package consumed by multiple packages (≥2 build-order
    consumers) is an ABI-coupled hub and carries `core` — exception:
    `app-cluster` members like `fcitx5-git`, whose consumers are all their own
    cluster siblings, stay `app`; (b) compile toolchains carry
    `core,build-tools`; (c) `build-tools` is a dispatch-priority class only —
    within a run its members dispatch before all other ready packages but the
    band never overrides build-order edges, plan/`--list`/run-record/range
    order stays topological build order, membership is always dual
    `core,build-tools`, and `-g build-tools` does not auto-enable `-i`
    (auto-install still keys on `core`); (d) group moves never touch
    `abi=`/`app-cluster=` tags (`qt5ct`/`qt6ct` precedent: keep `abi=must`
    while leaving `core`); (e) a recipe invoking cargo/rustc must declare a
    `rust-git` build-order edge (ripgrep and fd gained theirs 2026-10-04) —
    `fish build-all.fish --audit` lints such gaps.
22. **Multi-agent fleet work is reconciled by artifacts** (2026-10-04 fleet
    incidents: duplicated record rows 91–120, empty-report agents, 28 recipe
    dirs without committed `.SRCINFO` after self-reported success, two total
    `/tmp` prep wipes): (a) mirror every artifact written under `/tmp` to
    session storage at the MOMENT it is written — "mirror before a suspected
    reboot" loses everything created after the last mirror; (b) reconcile
    completion by deliverable files that exist and verify, never by task
    result order (results do not return in call order and cap rejections hit
    the last submitted calls) or by `idle` status (an agent can end a turn
    with zero output or with complete artifacts and an empty report) — a cap
    rejection means "resend after artifact check", never "lost"; merge
    divergent record writes by edge-union after integrity re-check, never
    last-writer-wins; (c) never accept self-reported validation — a recipe is
    done only when its committed `.SRCINFO` regenerates clean
    (`makepkg --printsrcinfo` diff); (d) retry HTTP-killed agents only after
    inspecting and resuming their partial state. Check: `.SRCINFO`
    presence+freshness sweep over every recipe directory (653/653 after the
    2026-10-04 sweep).
23. **Swap/ABI install contract** (2026-10-03→04 ingestion hardening):
    `pacman -U --noconfirm --ask 4` auto-confirms
    `ALPM_QUESTION_CONFLICT_PKG` (1<<2) — treat `--ask 4` as *removal
    consent*, never as safety, and move consent into the plan instead of the
    flag. A Class A provider declares `provides=(<stock>=$pkgver)` +
    `conflicts=(<stock>)` so the stock package is satisfied and displaced
    atomically. The install plan refuses `.PKGINFO` provide-diff drift before
    the force branch, so `-fi`/`-ia` cannot route around it — against the
    installed provides of the same pkgname, or of its `abi_stock_name`
    counterpart when the pkgname is not installed (a Stock→house swap MOVES
    the surface to a new pkgname instead of vanishing it; run #31, bzip2-git).
    Tier-2 ABI
    exclusions live in `config/abi-exclusions.conf` (35, user-approved;
    Tier-1 exposure is never excludable). Breakage: the swap path silently
    confirmed removals and could ship provides drifting from the stock
    packages they replace. Check: `fish build-all.fish --audit-lint swap`,
    `bash tests/swap-completeness.sh`, `bash tests/abi-drift-install.sh`,
    `bash tests/install-conflict-ask.sh`.
    Swap-lint debt was cleared 2026-10-06 (`niri-spicy-git`,
    `vscodium-insiders-git` declare their counterpart now); the lint also
    reports soname-surface drift against the installed stock counterpart
    (bare-stem symmetric difference, both directions — see NOTE 2026-10-06).
24. **Source-merge and topology identity** (2026-10-04 source-merge +
    wiring campaigns): a same-upstream cluster merges only into ONE buildable
    recipe with ONE topology record — an alias record would make the
    scheduler rebuild a merged recipe once per alias, so old split-output
    names stay addressable through pkgname lookup only; supersession is
    expressed as X→X-git edges, never by deleting X's record. Merged split
    sets pin siblings `name=$pkgver-$pkgrel` (qemu precedent: outputs must
    move as one version or pacman sees unsatisfiable exact pins between
    siblings). Unreferenced stock splits are trimmed AND `# trim:`-annotated;
    a candidate whose tests pin a different commit than its source demotes to
    SHARED-SRCDEST rather than force-merges; shared unpinned HEADs (gnulib×7)
    are a documented reproducibility caveat, not free disk savings.
    Breakage: split sets drifted from their stock counterparts and sibling
    pins went unsatisfiable before the policy existed. Check:
    `fish build-all.fish --topology` (one record per merged id) +
    `bash tests/recipe-contract.sh`.
25. **ABI closure guard — ten quotable rules** (2026-10-03→04 guard, finished
    and independently re-run: abi fixtures 5/5, install fixtures 4/4; seams
    `audit_lint_abi_closure`, `abi_batch_dependents`,
    `abi_provide_refusals`, `install_needed_probe`,
    `audit_lint_abi_exposure`, `read_abi_exclusions`):
    (a) bare soname provides only — makepkg auto-versions them; hand-versioned
    soname provides are forbidden (breakage: 15 of them across 10 recipes,
    rule 4's normalization);
    (b) every DT_NEEDED of a workspace output resolves via a workspace
    provide, an expected base-system soname, or an exclusions entry —
    findings name the provider/consumer pair (breakage: the 2026-10-03 audit's
    53 host-only sonames and the ELF packages shipping without bare soname
    provides); the post-install probe adds one more resolution source —
    runtime file truth (the file the transaction ships or an installed
    package owns), because stock Arch providers like libx11/libxt/libxext
    declare NO soname provide and a provide-only probe false-aborts their
    consumers (2026-10-06 full build, `libxpm-git`);
    (c) a provider whose surface LOSES a soname vs installed stock rebuilds
    the installed consumers that LINK it in one selection — LINK TRUTH
    (installed DT_NEEDED ∩ disappearing sonames, `abi_at_risk_stems` +
    `abi_links_stems`), never name/graph reachability: naming a provider is
    not linking it (a build tool or a stable-soname user has nothing to
    break — measured 2026-10-07: across 183 candidate consumers / 12 237
    installed ELFs the only links to any changing soname were the changed
    family's own outputs), link-dependency transitivity is not ABI-surface
    transitivity, and transitive risk rides the `abi=` coupled tags instead
    (breakage: 09-06 rust-git compiled against a minimal llvm-git mid-run —
    layer 1's tags; 2026-10-07 the transitive gate degenerated to the whole
    set through boost-libs→gdb→python→glibc hub chains, and its one-hop
    repair still demanded tools through name edges (`python`→glibc-git) —
    both refused full runs);
    (d) never install a moving/removed soname provide while any LINKED
    consumer is UNCOVERED — covered means the consumer rides the same
    transaction (`-ia`), or the run itself rebuilds+reinstalls it later
    (in-run repair: the consumer sits strictly after the provider in the run
    order, and a forced-rebuild marker under `$STATE_DIR/abi-repair/` keeps
    `-s`/`--skip-built` from skipping that repair; only the consumer's own
    landed install clears the marker)
    (breakage: 2026-09-25, the run's own llvm-git install broke rustc after
    preflight had passed; 2026-10-07 run #48, the transaction-only reading
    dead-ended every soname move under `-i` — libdisplay-info 3-64→5-64 vs
    niri-spicy-git, which the same run was scheduled to rebuild anyway);
    (e) the post-install NEEDED probe aborts loudly naming member + soname
    (breakage: a landed transaction with unresolvable sonames used to let
    every later package compile against a broken system); its abort decision
    is file-backed (provide set ∪ shipped bytes ∪ installed files), so a
    vanished soname still aborts while a stock provider without provides
    does not (2026-10-06);
    (f) the exclusions registry is strict-loader `id|reason|review-by`
    (`config/abi-exclusions.conf`, 35 entries, loaded on every invocation)
    and entries are reviewed before their review-by (breakage: silent gaps
    are exactly what the guard exists to prevent);
    (g) the exposure audit maps provider → exposed installed consumers
    whenever the soname surface differs from stock (breakage: libmypaint
    shipped a soname no stock-provide consumer binds to, invisible until
    audited);
    (h) a refusing install plan (PGO/ABI/empty-list) is pacman-free end to
    end, and unreadable `.PKGINFO` archives are skipped, never probed
    (breakage: any early pacman call is a silent `--ask 4` consent path);
    (i) a package with ≥2 edge-consumers carries `core` (rule 21(a)) —
    enforced by promotion, not by a debt register: the 203-id Q2-open
    register was landed as `core` dual membership on 2026-10-04 and the
    register deleted (breakage: the hub pin caught `libdrm-git` dropped from
    the migration list mid-plan; a register let 203 known violators sit
    outside the rule);
    (j) fixture expectations about topology-derived sizes are computed from
    records, never pinned counts (breakage: the same hub pin worked only
    because it re-derived its expectation).
    Check: `fish build-all.fish --audit` (closure/provides/swap/exposure
    lints) + `bash tests/abi-closure-lint.sh tests/abi-batch-policy.sh
    tests/abi-drift-install.sh tests/abi-postinstall-probe.sh
    tests/abi-exposure-audit.sh`.
26. **Measure scale-sensitive validation after every roster-size jump**
    (2026-10-04 latency regression): the loader re-validates the whole
    record map, edge graph and sort on EVERY invocation and the fish list
    scans grow quadratically — at 653 records `--list`/`--audit` cost
    minutes where 148 records were instant. The roster grew ~4x between
    measurements and no validation path was re-measured across the jump.
    The hot paths were since rewritten (`topo_sort` is O(V+E); `--list`
    ~5 s at 653 records — see NOTE.md's same-dated latency entry), so the
    remaining risk is the *next* roster jump, not these loops. Re-time
    `fish build-all.fish --list` after any roster growth, and never pin
    wall-times in fixture
    expectations — timing assertions block the very perf work that removes
    the latency. Check: `time fish build-all.fish --list` at the current
    roster size.
27. **Two version surfaces, two rules** (2026-10-06 real full-build
    findings): (a) any version joined to a PACKAGE FILENAME must be
    makepkg's full version `epoch:pkgver` (`get_full_version`) — a bare
    `pkgver` never matches an epoch-bearing archive and discovery reports
    "no built package archive matched" for a perfectly good artifact
    (47 recipes carry `epoch=`; pinned by `tests/install-archive-guard.sh`
    case A4); (b) a strict `=` dependency pin cannot be satisfied by a
    rolling `-git` provider, and Arch's lib32 packages pin their 64-bit
    counterpart exactly — on a multilib host, swap targets with such a
    pin (`pacman -Qi | grep 'name=[0-9]'`) need the pinning lib32
    counterpart rebuilt with an unversioned dep in the same wave (local
    `.1` pkgrel; sources stay signature-verified). Never make a provider
    lie about its version to satisfy a pin.
28. **A VCS recipe must pin build inputs that git does not carry**
    (2026-10-06 opus-git): some projects generate or fetch build-time data
    (opus's `dnn/*_data.{c,h}` weight tables) outside git and only ship it
    in release tarballs; the upstream tree itself names the pin (opus:
    `autogen.sh` → `dnn/download_model.sh <sha256>`, archive named after its
    own digest on media.xiph.org). Declare that artifact as a checksummed
    `source=()` entry (makepkg verifies it — never an out-of-band download in
    `prepare()`), and add a `prepare()` guard that fails closed when the
    upstream pin drifts, printing both values and the exact update. Second
    half of the rule: a trim/disable comment must state WHICH fact forced it
    ("git has no model data") so it can be revisited when the fact changes —
    opus's disabled neural features were data-forced, not policy, and became
    stock-parity `-D deep-plc/dred/osce=enabled` once the data was pinned.
    Red-herring warning: a first mutation probe that changed the digest's
    LENGTH only proved the fail-closed path — probes must preserve the input
    shape (see NOTE.md same-dated entry). Checks: `bash -n`, the probe pair,
    `tests/recipe-sources.sh`. Mirror clause (2026-10-06 libldacdec/libldac):
    a VCS source must be cloneable AT the pinned ref from a clean checkout —
    if upstream's ref advertisement rots (AOSP's corrupt branch ref broke
    `makepkg`'s `--mirror` clone, git 2.56), move to a mirror carrying the
    SAME commit ids and state the mirror's provenance in the recipe
    (identical commit hash = identical content; pin makepkg's git-archive
    checksums). Two verifications to distrust: a regenerated archive
    (googlesource `+archive` re-encodes per request — pinning one download's
    bytes proves nothing) and a `SKIP` checksum ("never silence a checksum to
    make a build pass"). Also: real checksums on `#commit=` sources make
    makepkg run `git archive` against the bare SRCDEST mirror
    (`calc_checksum_git`), which the agent-shell `safe.bareRepository=explicit`
    hardening kills — invoke makepkg with `GIT_CONFIG_COUNT=0`.
29. **A swap wave retires exact-pin leftovers, never rebuilds them**
    (2026-10-06 spandsp-git): when a swap target bumps soname (stock so.2 →
    git so.4), the wave is (a) rebuild every installed pinner in the SAME
    `pacman -U --ask 4` transaction (ICU pattern), and (b) first clear stock
    leftovers that pin swap-set packages at exact versions — `gst-plugin-pipewire`
    pinned `pipewire=1:1.6.9-1`, making any pkgrel bump uninstallable. Such a
    leftover is trimmed from the set on purpose: rebuild it and it re-adds a
    trimmed output plus a permanent lockstep pin. Sweep before planning the
    wave: `expac -Q '%n\t%D' | grep '<pkgbase>='`. Rejected: faking a soname
    provide (rule 27's "never make a provider lie").
30. **Soname beats pkgver in ABI bookkeeping** (2026-10-06 icu incident): a
    VCS package's `pkgver` is a version surface, not an ABI statement —
    icu-git `78.3.r454…` built from post-release main ships `libicu*.so.79`,
    so the pkgver lied about the soname and a "same-version" swap was an ABI
    event. (a) When a soname swap heals a wave, the wave covers EVERY direct
    linker, found by content scan + confirm: `grep -l 'libicu\(uc\|i18n\|
    data\)\.so\.<old>' /usr/bin/* /usr/lib/*.so* /usr/lib32/*.so*` then
    `readelf -d <obj> | grep NEEDED`; consumers of the victims heal
    transitively, victims never do (the 02:07 icu79 wave rebuilt 3 of ~10
    and stranded Qt6Core — all Qt apps, node, nautilus, xfs_scrub,
    boost_locale/regex, libical, samba). (b) The failure mode is asymmetric
    and deceptive: long-running processes keep running on deleted inodes
    while every NEW exec dies at the loader (rc=127), so "the app runs but
    its spawned helper fails" (noctalia unlock's pam-helper self-exec showed
    as "PAM start failed") points at a soname swap, not the service the
    error names — check `ldd`/loader errors before touching any config.
    Rebuild+install the direct victims (all in the set's build order); never
    symlink old soname → new. (c) Installability of a bump is decided by
    EXACT pinners of the OLD provide, found in the LOCAL DB (`expac -Q
    '%n\t%D' | grep '<soname>='`), not only by the workspace closure: stock
    `wlroots0.20`'s `libdisplay-info.so=3-64` pin made master's so.5
    un-installable (run #49, 2026-10-07) however complete the in-run repair
    was — pacman refuses before repair runs. Disposition split: heal-set
    (icu) when the pinner must keep working and its local rebuild is
     acceptable; park the recipe at the last compatible generation when the
    only exact pinner is stock-side for a secondary stack and the primary
    consumers bind the bare name (libdisplay-info parked at tag 0.3.0 —
      NOTE 2026-10-07). Pin form follows the line's life: `#branch=<named
      maintenance branch>` while the line receives post-tag fixes (libpng16,
      run #52), verified `#tag=` once the line is finished (libdisplay-info
      0.3.0); both are one-line reversible.
31. **A `?signed` source must pin a signed ref, and pins must name the
    ACTUAL signer** (2026-10-06 freetype2-git): makepkg verifies the
    *resolved* ref — `#tag=...?signed` verifies the tag, while a floating
    `git+URL?signed` verifies the unsigned tip commit (SIGNATURE NOT FOUND).
    Upstream that signs only tags cannot back a floating source: per the
    owner trust ruling 2026-10-06, CONTRIBUTING #1 is scoped so that
    floating `-git` sources carry plain `git+URL` + `b2sums=('SKIP')` (the
    family norm), while every pinned release artifact and `#tag=` source
    keeps `#signed`/`?signed` always. Second half: `validpgpkeys` must name
    the key that actually signed — run `git verify-tag`/`gpg --verify`
    FIRST and compare against the pin; AUR-sourced pins can be plain wrong
    (freetype pinned E3067470…; the real signer of VER-2-13-3..VER-2-14-3
    is DSA 58E0C111…), and a new signer is confirmed against publisher
    material before pinning (CONTRIBUTING #2–4). Diagnosis nuance (libass
    0.17.5, 2026-10-07): makepkg matches `validpgpkeys` against the
    *primary* fingerprint (`VALIDSIG` arg10), so a subkey-signed tag passes
    with the primary pinned (list the subkey only as a role-commented
    documentation entry), while `unknown public key <id>` at verify time is
    a local-keyring gap — makepkg never fetches keys — not a pin mismatch;
    fix the keyring before touching the pin. Third half, same incident:
    `arch-meson` passes `--auto-features enabled`, so every meson *feature*
    option defaults ON — a platform-gated feature (freetype `hvf`) errors
    on Linux, and `-D tests=false` is invalid for a feature-type option
    (choices: enabled/disabled/auto). Validate `-D` values against
    `meson_options.txt` types before the first real build; red/green
    rehearsal at the configure seam (extract the pinned ref from SRCDEST,
    run the recipe's exact meson args) catches both in seconds.
32. **A patch dropped from a set must be checked for what it replaced; gate
    the SHIPPED symbols, not the build exit code** (2026-10-06 nspr-git):
    the recipe applied stock's `0002` (removing the atomic asm files from the
    build) but skipped stock's companion builtins patch, and hg tip's
    `_linux.h` had migrated every arch block to GCC builtins except
    `__x86_64__` — so `_MD_ATOMIC_*` still resolved to `_PR_x86_64_Atomic*`,
    defined only in the removed asm. makepkg succeeded and shipped a
    `libnspr4.so` with four undefined `U` symbols that broke every strict
    link. After any build-flag surgery (dropping a file from the build,
    disabling a feature), `nm -D` the shipped `.so` for the symbols the
    removed code used to define; when taking one patch from a multi-patch
    upstream set, diff the set as a whole and carry over whatever the taken
    patch depends on. See `docs/NOTE.md` 2026-10-06 nspr-git.
33. **A fix verified in a clean tree is not verified for the run path —
    re-verify over a dirty `$srcdir`** (2026-10-06 nspr-git, second wall):
    makepkg re-extraction resets tracked files but leaves untracked in-tree
    build outputs, and make-without-header-deps build systems never rebuild
    `.o` files when only a *header* the recipe patches changes — so the same
    verified recipe shipped the same broken library in the full run, whose
    rebuilds always land over persistent `src/` trees. (a) When changing a
    recipe's patches or flags, treat existing `src/` output as poison: the
    recipe should clean it itself (nspr `build()` now runs `make clean`
    after `configure`), else rebuild that package with `-c`. (b) Validate
    such a fix by building twice without cleaning — the second build over
    the first one's objects is the run path; `nm -D` the shipped `.so` (rule
    32) both times. See `docs/NOTE.md` 2026-10-06 nspr-git (stale in-tree
    objects).
34. **A file installed from `package()` may be tooling-materialized, not
    upstream-tracked — its path's truth is the tool's copy list** (2026-10-07
    run #55 libtool-git): upstream `3fc61c56` made `./bootstrap` copy
    gnulib's canonical GPL text to top-level `COPYING` (gitignored), killing
    the recipe's `install doc/COPYINGv2` at `package()` time while
    `bootstrap.conf` still listed the old name. When a recipe installs doc
    or license files produced by `./bootstrap`/`autogen`/gnulib, accept
    every known layout (or re-derive the path from the tool's copy list)
    instead of one hard-coded path, and re-check after any tooling bump —
    `git status` proves nothing for gitignored materialized files. The
    pre-slot look-ahead for this class is upstream-at-ref existence of the
    installed paths (and of upstream version stamps, for the rule-31
    placeholder class), not the wall loop; the 2026-10-07 pass over the
    516-window found zero surviving walls. The tooling-materialized flavor
    (2026-10-07 run #58 gcc-snapshot): a `package()` step installing
    *tool-generated* output (doxygen man pages, generated docs) must have
    its generating tool in `makedepends` — a removed/absent tool must not
    leave an install step expecting its output — and upstream
    `Error 1 (ignored)` + stamp-anyway sequences make warm-tree retries
    sticky, so delete the stamps before re-testing the failing step. See
    `docs/NOTE.md` 2026-10-07 run #55 and run #58.
36. **An in-set library that replaces stock *with a soname bump* breaks
    every stock binary linked against the old soname until each consumer's
    in-set replacement installs** (2026-10-07 run #58 rescue build):
    `jsoncpp-git` (floating git source) picked up upstream's soversion move
    `.so.27 → .so.28`, and stock `cmake` — the only installed linker of
    `.so.27` — broke mid-window, failing every later cmake-based build.
    When a rebuilt in-set library's auto-versioned `libfoo.so` provide
    moves generation, (a) sweep installed ELF consumers
    (`readelf -d` over `/usr/bin /usr/lib /usr/libexec /opt` for the old
    soname) and rebuild/install each in-set replacement in the same wave,
    and (b) treat a tool breaking at *launch* (`error while loading shared
    libraries`) as this class, not a corrupt-toolchain mystery. (c) the
    install gate is restoration-blind: a park that moves the surface
    *back* to the wanted generation (libsodium `.so.30 → .so.26`,
    2026-10-08) is still a "move" to it — land it with the heal batch
    `--no-deps -i <provider> <installed linking consumers>` (consumers
    must sort after the provider in `fish build-all.fish -l` order so
    in-run repair covers them), and never `-ia` for a surface move,
    because consumers would compile against the still-installed old
    generation and record its soname. See `docs/NOTE.md` 2026-10-07 run
    #58 and 2026-10-08 libsodium park.
37. **A toolchain bump in this set is a compile-compatibility transition,
    not just an ABI event** (2026-10-08 run #59 nodejs): installing
    `gcc-snapshot` replaces `/usr/bin/g++`, so every later build compiles
    against the new libstdc++ headers — whose include cleanup breaks
    vendored/third-party C++ that relied on transitive std includes
    (`std::ostringstream` without `<sstream>`). Fix with explicit-include
    patches against the pinned source (never by pinning an older
    toolchain), and when the first file walls, scan the whole vendored
    tree for the missing include and patch every occurrence in one patch —
    ninja stops at the first failure and the next one will wall the retry.
    Expect one such wall per include-family after a major toolchain move;
    see `docs/NOTE.md` 2026-10-08 run #59. When the new diagnostic fires
    in *generated* sources (flex/bison output) instead of code you can
    patch, drop the build system's `-Werror` promotion at the recipe seam
    (or use its opt-out variable) — keep the warning visible, never patch
    generator output (`docs/NOTE.md` 2026-10-08 runs #62–#64).
38. **`$W` sync must reset only what the incoming commits change — the
    builder's version-sync marks are runtime state** (2026-10-08): each
    run's sync phase rewrites recipe `pkgver`/`pkgrel` in `$W` to track
    what it built (e.g. gcc-snapshot's snapshot date); a mass
    `git checkout -- .` before `pull` resets those marks, updates PKGBUILD
    mtimes past the built archives, and the `-s` freshness check then
    forces a full redundant rebuild of every reset recipe next run (cost:
    one ~38 min gcc-snapshot per cycle). The same defect has a single-file
    variant: a blind `cp` of a canonical file over its `$W` twin clobbers
    the mark in that file (2026-10-08 run #67 sword, where it also
    desynced the file from the marked `.SRCINFO`) — reconcile instead:
    apply the incoming semantic change, leave `pkgver`/`pkgrel` alone.
    Sync procedure: leave the marks,
    `git checkout --` only the files the incoming commits touch (resolve
    those), then `pull --ff-only`. The marks converge — once the synced
    content is already in place the next sync writes nothing, mtimes stop
    moving, and `-s` skips correctly.
39. **The host's `-fuse-ld=mold` LDFLAGS default is strippable per recipe
    when the build needs a GNU-ld-only linker feature** (2026-10-08 run
    #65 libxdp): xdp-tools embeds its BPF blobs via
    `gcc -r -Wl,--format=binary`, which mold refuses (`-b binary`
    unsupported). The recipe strips `-fuse-ld=mold` from `LDFLAGS` so
    bfd links it — the same seam its `options=(!lto)` note documents.
    Never patch the build system around the embed, and scan build-rule
    files (not all sources — linker sources merely *mention* the flag)
    for other embedders before assuming the class is unique.
40. **Never double-wrap ccache (`ccache <ccache-farm-path> …`) — the cache
    key then pins the farm symlink, and toolchain updates never evict**
    (2026-10-08 run #68 doxygen-git): makepkg's ccache BUILDENV puts
    `/usr/lib/ccache/bin` first on `PATH`, so a CMake recipe whose
    `CMAKE_*_COMPILER` resolves to the farm *and* also sets
    `CMAKE_*_COMPILER_LAUNCHER=ccache` compiles as
    `ccache /usr/lib/ccache/bin/cc …`. In that shape ccache keys the entry
    on the farm symlink's frozen mtime (its `CCACHE_DEBUG` trace names
    `Compiler: /usr/lib/ccache/bin/cc`, "followed symlinks … to
    /usr/bin/ccache"), so `compiler_check = mtime` cannot see the real
    compiler change: after the 17.0.0-20261004 snapshot bump, pre-update
    entries replayed as hits into the freshly drift-cleaned tree and the
    slim-LTO objects (`-fno-fat-lto-objects`, no fallback ELF) died at
    link with `bytecode stream … LTO version 16.0 instead of the expected
    17.0`. Farm-as-argv[0] (`/usr/lib/ccache/bin/cc …`, no launcher)
    resolves the real `/usr/bin/cc` for the key and evicts correctly —
    the launcher line is redundant there and only poisons the key. The
    builder's toolchain-drift clean (rule from `docs/NOTE.md`
    2026-10-08 look-ahead) wipes trees but cannot see cache contents: the
    companion host rule is `ccache -C` after every toolchain package
    update (stale non-LTO codegen is the silent half of this class).
    Recipes keeping the wrap: none — doxygen-git, llvm-git and rocm-llvm
    dropped it 2026-10-08.
41. **An upstream with a sub-3.5 `cmake_minimum_required` gets the policy
    floor at the recipe seam** (2026-10-08 run #69 libebur128-git): CMake
    4 removed the pre-3.5 compatibility, so such a configure dies before
    any build work. Add `-DCMAKE_POLICY_VERSION_MINIMUM=3.5` to the
    recipe's cmake invocation (the seam the diagnostic itself names;
    sword already carries it). Confirm the upstream floor from its
    top-level `CMakeLists.txt` before bulk-adding — on modern projects
    the flag is no-op churn. A wall here is 1 s into the build, not a
    compile error: recognise the shape from the log's first lines.
42. **A tool run through a *found interpreter* binds whichever python
    leads `PATH` — pin it at the recipe seam** (2026-10-08 run #71/72
    libjxl-git): upstream's manpages rule runs `python3 a2x` via
    `find_package(Python3)` instead of a2x's own shebang, and
    `~/.local/bin` leads `PATH` on this host with uv/pyenv python shims —
    the bound interpreter's site-packages has no `asciidoc` (a makedepend
    installed for the SYSTEM python), so the import dies while every
    shebang-driven test of the same tool passes. The makedepend that
    supplies the tool's module defines which python must run it: pin
    `-D<Var>_EXECUTABLE=/usr/bin/python3` in the recipe's configure
    (libjxl-git carries it) whenever a build invokes a python module
    through a discovered interpreter. Diagnosis handle: the failing
    command line names a `~/.local/bin/python*`, or `CMakeCache.txt`
    `_Python3_EXECUTABLE`.
43. **A vendored, checksum-pinned tree is not freely editable — re-anchor the
    edited file's `.cargo-checksum.json` entry in the same `prepare()` step**
    (2026-10-09 run #74 libopenraw): cargo directory sources pin every file's
    sha256 in `.cargo-checksum.json`, so the sed that fixes vendored
    `ahash 0.7.6`'s build.rs was refused with `the listed checksum of
    …/build.rs has changed` — the fix moved the wall instead of removing it.
    Recipe pattern: `sed` the file, then rewrite exactly that file's entry
    (`"name":"<64 hex>"`) with `sha256sum` output; never touch the other
    entries or the package checksum. Corollary: build.rs channel probes
    (`version_check`/`autocfg`) are feature gates that stable toolchains never
    enable — a nightly-only cfg in vendored code is a rust-git landmine.
44. **An `upstream-unverified` deferral on a ref a previous run verified is
    transport noise until proven otherwise — classify before fixing**
    (2026-10-09 run #74 libxml2-legacy): the `-s` freshness query hit a
    transport burst that outlasted `git_ls_remote_quiet`'s 6-attempt/~93 s
    budget and parked the recipe (a deferral fails the run exactly like a build
    error). Classification handle: replay the builder's own query shape
    (`vcs_remote_revision`'s ref-kind case) by hand and recompute the archive's
    `.gsa-vcs-revisions` identity row offline; if both are healthy the resume
    re-queries and skips — never force a rebuild merely to "clear" a deferral,
    and never "fix" the recipe or the URL for one.
45. **A parallel-make failure naming a static archive is a writer/reader
    overlap until proven otherwise — find which make node mutates the
    archive** (2026-10-09 run #75 vamp-plugin-sdk): upstream ran `ranlib` as
    the recipe of the *phony* `sdkstatic` target while the `host`/`rdfgen`
    links depended only on the `ar` rule's file, so `-j` raced the links
    against the ranlib in-place rewrite (`lto1: … file too short`). Smell: a
    phony target whose recipe mutates an artifact its consumers read — it
    re-runs every invocation and breaks the "recipe finished" assumption. Fix
    at the seam that survives Makefile regeneration (there: `configure`
    rebuilds Makefile from Makefile.in, so `build()` phases `make sdk` then
    `make plugins host rdfgen test`), never by serializing the whole build.
46. **`git apply` against a non-repo source tree is repository-context
    sensitive — pin `GIT_DIR`/`GIT_WORK_TREE` or work inside the source's
    own clone** (2026-10-09 run #76 gd): under an enclosing git work tree
    (the build workspace is one) `git apply` resolves patch paths against
    the REPO ROOT and silently skips everything outside the current
    subdirectory — `Skipped patch` is `--verbose`-only and the exit code is
    0. makepkg's `prepare()` has no errexit, so the no-op sails through
    until a later step dies on the file the skipped patch should have
    created. Fix: `GIT_CONFIG_COUNT=0 GIT_DIR="$PWD/.gsa-nogit"
    GIT_WORK_TREE="$PWD" git apply -p1 …` (correct in and out of a repo).
    The `git apply` sites inside recipes' own clones (glib2-git,
    hermes-agent-git) are unaffected — cwd is their repo root.
47. **Trimming a split package must disable its *build*, not just its
    makedepends and packaging paths** (2026-10-09 run #78 volume_key): the
    python split was trimmed and its python/swig makedepends removed, but
    `configure` kept building the SWIG wrapper — its "Python 2" probe
    (`AC_PATH_PROGS` + `AM_PATH_PYTHON([2.4])`) matches any `python` ≥ 2.4
    and found 3.14, then compiled `volume_key_wrap.c` with empty
    `PYTHON_INCLUDES` (`Python.h` unresolved). The build system's own
    disable switch is the seam (`--without-python --without-python3`
    → HAVE_PYTHON/HAVE_PYTHON3 conditionals). Diagnostic: a trimmed feature
    that still compiles means the trim was incomplete — probes find
    substitute tools on PATH regardless of makedepends.
48. **`package()` starts in `$srcdir`, not the source root — qualify every
    relative path or `cd` first** (2026-10-09 run #85 pkgfile, run #91
    libnvme): a bare `install -Dm644 LICENSE`/`COPYING` reads
    `$srcdir/LICENSE` while the tarball extracts to
    `$srcdir/$pkgname-$pkgver/` (or a VCS clone subdir) — `install: cannot
    stat` kills `package()` after the whole compile is done. Qualify
    (`"$srcdir/$pkgname-$pkgver/COPYING"`) or `cd` into the source root
    before the install; a recipe already using `../something` in
    `package()` has cd'd and is fine. Scan:
    `grep -rnE '(install|cp) .*(LICENSE|COPYING)' packages/*/*/PKGBUILD |
    grep -vE '\$|/|\.\.'` flags offenders. A `package()`-only fix leaves
    `.SRCINFO` untouched.
35. **Never `cd` inside a fish command substitution — fish 4.9.3 runs the
    substitution in-process and the `cd` leaks to the caller**
    (2026-10-07 run #56 nodejs): `(cd "$x" && pwd -P)` silently moved the
    lane's own cwd into `$x`; the deleted version-sync temp dir then broke
    `build_package`'s closing `popd` — and because fish's `popd` still
    returns 0 after a failed `cd`, the `if not popd` guard never fired:
    every later relative operation ran from the wrong directory with only
    one `cd: … does not exist` line in the log as evidence. Resolve paths
    with `resolve_physical_dir` (`lib/sources.fish`: existence check +
    `realpath`, no `cd`), and scan trees via absolute `find` plus a literal
    prefix strip (`string replace`), never `cd`-and-`find .` inside `(
    )`. Any new `(cd …)` site in fish source is a defect by default;
    `tests/stable-sync-checksums.sh` Case 45 pins the version-sync/anchor
    family (both the success and failing-build log shapes). See
    `docs/NOTE.md` 2026-10-07 run #56.
49. **A `-git` recipe that follows upstream into a new build-system
    component vendors that component's subprojects exactly like the
    existing seeded set — a meson wrap fallback fetch at build time is a
    defect** (2026-10-10 run #100 dbus-broker-git): upstream added
    `dependency('libc-rs-0.2')`/`dependency('libosi-1')`, meson fell
    through to `git clone` from the wrap, and the build died on the
    network fetch. Fix shape: named `source=()` entries for the new
    subproject repos + `prepare()` symlinks into `subprojects/` (the
    `realpath --relative-to` idiom), and when the subproject comes via a
    wrap `patch_directory`, also copy the overlay files
    (`subprojects/packagefiles/…`) into the seeded tree like the wrap
    would. New tool makedepends the component needs (`rust`, `cargo`,
    `jq`) come with it. See `docs/NOTE.md` 2026-10-10 dbus-broker-git.
50. **A compatibility shim must replicate upstream's output *shape*, not
    just per-flag values — combined-flag invocations are part of the
    contract** (2026-10-10 run #102 libppd): `lib/cups-config` echoed `1`
    for `--image`, but upstream `cups-config.in` treats `--image` as "Do
    nothing" — so libppd's ``CUPS_LIBS=`cups-config --image --libs` ``
    captured `1\n-lcups`, planting an orphan make-syntax line that died
    much later as `missing separator` in the depfiles bootstrap. Read the
    real script when writing a shim (`git -C ~/.cache/gsa-src/cups show
    v2.4.11:cups-config.in`) and pin the shape with a fixture
    (`tests/cups-config-shim.sh`, mutation-probed). Symptom heuristic: a
    "missing separator" in a generated Makefile means look for a
    multi-line variable *value*, not for a make bug.
51. **Recipe outputs must be co-installable by construction — mutually
    exclusive full alternative builds are separate recipes, never split
    outputs** (2026-10-10 run #110 emacs): the builder installs every
    output of a recipe in ONE `pacman -U` transaction, so outputs that
    ship the same paths (emacs-nox/emacs-wayland each carried their own
    `/usr/bin/emacs` + elisp tree) are un-installable as splits by
    construction. A variant is a separate recipe with
    `provides=(<stock>)` + `conflicts=(<stock>)`, and that `conflicts`
    is *load-bearing* — never a `# trim:`-able stock leftover. Trim
    judgment test: would removing this field change installability
    semantics? If yes, it is not stock weight. (Tooling footnote from
    the same fix: programmatic excision must search anchors from the cut
    offset, never byte 0 — verify the function list after any scripted
    edit.)
52. **A consumer edge is required when a recipe consumes a set member a
    fresh host would not have installed — audit for "unmet-dep
    inversions"** (2026-10-10 run #111 evince): evince consumed
    gspell/libhandy/gnome-desktop with no consumer edges, so the sort
    built it first; makepkg reached for stock replacements and died in
    the icu soname drift (`libicuuc.so=78-64` wanted vs icu-git's
    `=79-64`). Scan recipe .SRCINFO depends+makedepends with `pacman -T`
    and flag any unmet dep whose provider member sorts later; fix by
    adding the consumer's edge (evince += gspell,libhandy,gnome-desktop;
    0ad += wxwidgets; kvantum-qt5 += kvantum). A cyclic unmet pair
    (libpulse-git ↔ gstreamer) is the "prerequisites assumed installed"
    boundary, not an edge to force: name it and accept the stock
    build-time prereq. Re-verify after every dep-set change — the
    topology-edge lint is still merge-gated. **Transitive variant**
    (2026-10-10 run #112 qemu): a REPO package in the dep closure can
    need an IgnorePkg-protected house name (`brltty` → `libspeechd`,
    provided by the house `speech-dispatcher` member) — the direct-dep
    scan cannot see through repo chains. Diagnostic signature in the
    makepkg log: `warning: ignoring package X` +
    `cannot resolve "X", a dependency of "Y"` → give X's provider
    member the consumer edge.

## 2. Workspace overview

- The public tree is `Gentoo_Style_Arch/`; recipes live under
  `packages/{git,stable,core,misc}/` (the `packages/third-party/` category
  was retired 2026-09-27; `zen-browser-pgo` and `bettbox` relocated to
  `packages/stable/` as pure renames).
- `config/topology.conf` is the ONE topology source: one record per package,
  `id|path|groups|edges[|tags]` — the only id→path binding, group membership
  (comma list ⊂ the six names `git`, `stable`, `core`, `misc`, `app`,
  `build-tools`, roster
  stated once
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
- The logical groups are `git`, `stable`, `core`, `misc`, `app` and
  `build-tools` (the dispatch-priority class — membership rules and dispatch
  semantics: rule 21; `app` is the
  optional-applications group: on a TTY a build/`-n` run prompts to
  multi-select them, non-TTY runs take the whole list, and app members are
  leaf builds — consumer expansion applies like everywhere else, but app
  packages typically have no consumers). `app` membership is
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
  of truth. (2026-09-28 batch: `stable` grew 27 → 44 and the set 128 → 145
  recipes — dated figures again.) `core` intentionally overlaps stable
  packages whose ABI must be rebuilt and installed as one batch.
- **Leaf-utility class** (2026-09-28, 17 recipes under `packages/stable/`):
  release-tracked utilities whose topology records are
  `id|packages/stable/<id>|stable|` — no tags and no incoming edges (edges
  empty except ripgrep and fd, which carry a `rust-git` build-order edge —
  rule 21): trash-cli (ships the 2026-09-27 hang fix, §6), desktop glue
  (xdg-utils, libnotify, wl-clipboard, shared-mime-info, desktop-file-utils,
  xdg-user-dirs, playerctl, brightnessctl, ffmpegthumbnailer), dev glue (jq,
  the curl/libcurl-compat/libcurl-gnutls three-way split, file, rsync) and
  Rust/Go CLIs (ripgrep, fd, fzf). This is the class to extend for further
  utility gaps (stretch: ghostscript/tesseract, §5) — one recipe plus one
  topology record per gap (edge-free unless the recipe invokes cargo/rustc —
  rule 21).
- No upstream checkout, package archive, downloaded signature, PGP cache,
  encrypted CI artifact, or host profile belongs in the public tree.

### build-all.fish

Selection is mandatory. The builder loads and validates the declarative
package map, groups, and build-order graph before handling command-line
arguments. It accepts package IDs, expands consumers (reverse build-order
edges: a record's `edges` field names what it consumes), sorts them in build
order, and rejects cycles or missing records. Prerequisites are assumed
installed and current — nothing upstream is pulled in; bootstrap and fresh
builds use `-g` group runs.

Builder code is split (Design C, 2026-10-05): entry `build-all.fish` plus two
sourced leaf modules, `lib/sources.fish` (PKGBUILD/.SRCINFO parsing, version
sync, VCS freshness, checksum anchoring) and `lib/audit.fish` (workspace audit
lints), cut out verbatim; function names and `lib/sources.fish`'s documented
out-param globals are the interface, and both are sourced before
`load_project_config` and the hidden seams. Synthetic-workspace fixtures copy
the modules beside the entry (`tests/lib/fixture-lib.bash`'s `make_workspace`
does).

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
`-ia` under a cold credential fails fast too. A system pacman database lock and broken local-db entries are NEVER
deleted automatically (2026-10-05): idleness is proven by scanning
`/proc/*/fd` for open handles on the lock inode — name-independent, so any
alpm client (e.g. `paru`) counts — and a killed/short/uncertain probe or
hidden handles classify `UNKNOWN`, never idle. The probes are report-only
(preflight, `run_pacman_locked` failure path, interrupt teardown) and print
the exact operator command (`sudo rm -f <db.lck>` / `sudo rm -rf <entry>`
then reinstall). makepkg dep installs share the builder mutex through the
generated pacman shim, but only for TRANSACTIONS: read-only queries run
unlocked, because queueing them manufactures rc-75 timeouts on a healthy
queue; flock rc 75 is named `builder pacman mutex timed out`, runs no
recovery probe, and records as row reason `mutex-timeout`, never
`build-failed`. Archive currency for `-s` (2026-10-05) = the complete
output set at the evaluated pkgver-pkgrel, every member payload-readable
(`pacman -Qp`, fail-closed) and bound to its VCS baseline by sha256+size
(manifest v2; v1 forces one rebuild) — a partial split set never skips and
never reaches install discovery (`list_split_pkgs` prints nothing and names
the missing outputs), and anomaly diagnostics print even in quiet output.
Skip modes (2026-10-07): `-s` is freshness-gated (mtime, VCS probes, waivers
— rows `freshness-waived`/`abi-provider-waived`); `--skip-built` claims the
newest complete payload-valid set at ANY version with freshness OFF (no VCS
probes or any network, no waivers — row `skip-built`), dying only on recipe
CHANGE evidence: a PKGBUILD commit newer than the set (file-mtime fallback
without git metadata; checkout/pull/pkgver() mtime churn never rebuilds). It
wins over `-s` in either order and still installs the CLAIMED set under `-i`.
The waive threshold
is `--vcs-skip-tolerance N` (positive integers only; overrides env
`GSA_VCS_SKIP_TOLERANCE`, the lane-child transport, whose garbage values
still fall back to 5 loudly).
Recipe-file rewrites are transactional (2026-10-05): one staged per-process
temp + one `mv` publish, snapshotted before the first write and rolled back
through a CHECKED restore whose failure is its own named error (anchor rc 5:
the recipe is dirty; nothing may build or park it); a version or query a run
could not verify suppresses the freshness claim instead of making it (sync
query failure → defer `upstream-unverified` or a loud as-is build), and a
failed committed `.SRCINFO` refresh surfaces in log AND run summary. One run
per workspace: `run_lock_acquire` refuses (never queues) and names the
holder; lane results are run-scoped and foreign lines are ignored, never
classified. Name surface and parse discipline (2026-10-05): one
pkgbase+pkgname lookup answers every name question (CLI references resolve
pkgbase-only names with an announced substitution); lint/audit I-O goes
through the shared tagged parses (`srcinfo_rows`, `pkgbuild_scan_rows`) —
never fork per recipe; keyed maps use `_topo_key` (the only key scheme), and
dispatch readiness is O(1) markers tail-synced from append-only lane-state
lists. Pre-dispatch phase boundaries honour the interrupt latch
(`abort_before_dispatch`, 2026-10-05): every phase before the first dispatch
must check it and abort into the interrupt run record, and the ABI gate +
install-ABI helpers must stay keyed/memoized — their per-name probe argv
shapes (`pacman -Q NAME` positionally for `abi_id_installed`) are
fixture-pinned contracts. Recipe evaluation failure is never "no sources": callers use
`pkgbuild_array_checked` (rc 2 = failure), which never licenses a freshness
claim. Lane results carry a named vocabulary:
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
  multiple groups, edges or tags (replace-or-append); `stub_sudo`/`stub_pacman`/`stub_makepkg`/`stub_sleep` write the trivial
  byte-identical PATH stubs. `stub_sudo` is a passthrough that strips the
  builder's non-interactive flags (`-n`, `-v`, `--`) **and `--preserve-env`** —
  some hosts wrap `sudo` in a fish function that re-execs it as `command sudo
  --preserve-env …`, and a stub that chokes on that flag would fail every `-i`
  fixture in the preflight probe. `stub_sleep` is the capped clock for
  SUT-side waits: numeric operands ≥ 0.4 s collapse to 0.05 s, shorter ones
  pass through untouched — install it only where no long sleep is a lease
  (`sleep 60 60<"$lock"`) or a measured duration (run-record's mid-build
  `sleep 3`, scheduler-core-solo's duration table). Oracle-shaped stubs (fake
  `date`, marker
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
  stub script, never by the builder. The builder's real environment surface —
  its `GSA_*` inputs, the inherited environment that silently changes
  behaviour, and its outputs to recipes — is one list in `docs/build-guide.md`
  § Environment surface; check the input roster with `fish build-all.fish
  --help` rather than counting names. A new fixture knob keeps the
  `GSA_FAKE_*` prefix (full table in the helper's header). (last reviewed
  2026-10-04)
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
- **gcc-snapshot carries a house compiler patch in `prepare()`** (2026-10-09):
  `verify_ctor_sanity` is made a no-op for PR c++/127395 (a r17-4199
  regression false-positiving on abseil/protobuf headers, §6). It is a
  heredoc patch, NOT a `source=()` entry, because the recipe is
  version-sync-anchored (golden rule 18). Drop-condition is recorded in the
  patch comment: remove the block once the upstream fix lands in a snapshot
  we build.

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
  Rust `.profraw` profiles (and ripgrep's), or `pgo_min_samples` for the Go
  flavor's pprof sample count; it is NOT a `lib/pgo.sh` knob — and its comment
  contract is "≈ the minimum distinct translation units the training must
  touch before a profile is worth trusting": at or below it the profile is too
  thin and the recipe falls back to a plain (non-PGO) build rather than
  shipping one. Values today — `pgo_min_gcda`: 0 (`cmake-git`, `mold-git` —
  any profile data at
  all suffices; zero files means training never ran and phase 2 is skipped),
  50 (`glib2-git`, `cairo-git`, `xorg-xwayland-git`), 100 (`gtk3-git`,
  `gtk4-git`), 15 (`jq`, `file`), 20 (`rsync`); `pgo_min_profraw`: 0
  (`ripgrep`); `pgo_min_samples`: 500 (`fzf`). The fallback is family-shaped —
  LTO-only for the meson/CMake recipes, fat-LTO plain for ripgrep,
  LTO-restored-without-use for the C-autotools trio, `-pgo=off` for fzf — and
  always plain, never half-trained. A threshold change is a behavioural change — it decides whether
  the recipe ships a profile-used build at all — and belongs in a NOTE.md
  entry with the reason; if the thresholds are ever lifted into `lib/pgo.sh`,
  a change there is a behavioural change to every consuming recipe at once.
- **C-autotools PGO family** (jq/file/rsync, 2026-09-28): CFLAGS bake at
  ./configure time — every phase must re-run ./configure; `make clean` is NOT
  enough. Phase 1 strips `-flto*` and instruments with
  `-fprofile-generate=<dir>`; the `=<dir>` spelling must be SYMMETRIC with
  `-fprofile-use=<dir>` on both sides — a bare `-fprofile-generate` plus
  `-fprofile-use=<dir>` silently misses every profile (GCC probe: the counters
  land where the use phase never looks). Training is `make check` plus
  workload loops (filter/sweep/tree-copy; gcda counts 23/25/119). Phase 2
  restores LTO plus `-fprofile-use=<dir> -Wno-error=missing-profile
  -Wno-error=coverage-mismatch`. rsync keeps Fedora's rhbz#1898912 LTO
  history as the escape-hatch comment (LTO+PGO builds fine on GCC 17).
- **Go-PGO flavor** (fzf, 2026-09-28, first Go member): training = upstream
  bench suite + `fzf --profile-cpu` filter runs, merged via
  `go tool pprof -proto` into `$srcdir/cpu.pprof`, wired as
  `GOFLAGS+=-pgo=$srcdir/cpu.pprof`; the floor `pgo_min_samples=500` is
  parsed from `go tool pprof -top` "Total samples" and below it the release
  build sets `-pgo=off`. The recipe keeps the honesty caveat: the profile
  over-represents micro-benchmarks versus interactive TUI use — it represents
  the batch-matching hot path. `lib/pgo.sh` is deliberately unchanged: Go
  leaks none of the `.gcda`/`.profraw` literals its predicates cover, so the
  gate trivially passes; the family still earns `tests/fzf-pgo.sh`.
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

- **Prune the startup stale-manifest sweep** (2026-10-09, campaign latency):
  the builder's `*.gsa-vcs-revisions.tmp.*` sweep uses `-not -path '*/src/*'`
  style filters, which *descend* every `src/`/`pkg/`/`build/` tree first — on
  the USB workspace that is 6–8 D-state minutes per builder invocation
  (probe, rehearsal, and run alike), and it grows as the heavy trees
  accumulate. Same result set at near-zero cost: `find packages \( -name src
  -o -name pkg -o -name build \) -prune -o -type f -name '*.gsa-vcs-revisions.tmp.*' -print`.
  Needs a fixture pinning the pruned and unpruned result sets as equal.
- **Pre-install package-internal NEEDED probe** (2026-10-07, from the run #53
  wall): the post-install NEEDED probe stops a run but cannot prevent the
  `pacman -U` landing — run #53 left `png2pnm`/`pnm2png` installed with a
  `libpng18.so.18` NEEDED nothing provides. Add a pre-install check in
  `install_plan`/`pgo_payload_refusals`' class: scan the staged archive's own
  executables/libs (`readelf -d` NEEDED) and refuse when a needed soname is
  provided neither by the archive's own provides nor by the installed DB —
  a package-internal inconsistency is a build defect, not a batch case. Fit
  alongside the existing silent `refuse pgo-*` rows; fixture via the
  `--install-decide` seam.
- **ABI-batch install deferral** (2026-10-07, from the libLLVM freeze): the
  coupled-batch gate (build-all.fish ~8145) protects selection completeness
  but never delays the anchor's `-i` install until its batch mates are built
  — the anchor lands at its lane position and leaves an ABI-stale live-stack
  window (black desktop + freeze, see Pitfall digest). Design: when `-i` is
  on and a package belongs to a multi-member ABI batch (anchor + abi
  batchmates incl. the soname-drift closure), `install_plan` emits a `defer`
  row until every batchmate has a built archive, then `install_execute`
  issues ONE `pacman -U` for the batch. Needs fixtures via the hidden
  `--install-decide` seam (plan rows: install/skip/refuse/noop/defer) plus a
  run-record rendering row. Owner decision: implement, or keep the
  operational rule (GUI stopped during batch installs).
- **Fixture-safe pacman lock preflight** (2026-10-06): give the fixtures a
  `pacman-conf` stub whose DBPath points inside the workspace, so the `-i`
  preflight's `db.lck` check reads a stub lock and batteries can run beside a
  live install run (see Pitfall digest). Owner-blessed idiom: a stub, not a
  builder test knob.
- **Swap-drift owner calls** (2026-10-06, from the swap-gate work): (1) keep
  the audit's soname-drift finding symmetric or narrow it to drop-only
  (≈8 findings vs 18); (2) disposition the 18 real host drift rows the lint
  now reports — fix recipes or consciously retire the debt entries.
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
  *Data point 2026-10-10 02:50* (full-build run #101): same no-trace hard
  freeze — journal stops dead mid post-transaction hooks, no OOM/MCE/thermal
  lines — but on `7.3.0-rc6-1-cachyos-rc`, i.e. **inside the fixed range**
  (`7.3-rc1+`), with rc6-2 installed but not yet booted. Load at the instant
  was light (small packages + a ccache-fast `mariadb-libs` reinstall,
  transaction 2348), so build weight again did not matter. Either the fix
  is incomplete for this signature, the CachyOS rc6 build lacks it, or this
  is the separate 2026-09-01 class; pstore empty because the capture chain
  is stood down. Judged NOT the build campaign's fault: 1 182 completed
  pacman transactions on this box, freeze predates the campaign.
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
- **Stretch backlog: ghostscript / tesseract recipes** (out of scope for the
  2026-09-28 utilities batch): leaf-utility recipes in the §2 class, claimed
  here only so the print/OCR gap is visible; drop this item if the gap stops
  mattering.
- **`keys/*.asc` gitignore gap** (2026-10-04 ingestion): key material for
  offline source verification is currently neither clearly tracked nor
  clearly ignored. Decide — a gitignore negation that keeps the keys tracked,
  or staying ignored with verification keys sourced elsewhere.
- **gst-libav `gst-ffmpeg=$pkgver` provide deviation** (2026-10-04
  source-merge): the merged gstreamer recipe maps the stock name with a
  deliberate-looking version mapping. Confirm it against stock, or align it.
- **gnulib unpinned HEAD** (2026-10-04 source-merge): the 7-recipe
  SHARED-SRCDEST gnulib cluster links a moving HEAD — pin to a commit, or
  keep the documented reproducibility caveat deliberately.
- **spandsp sign-off** (2026-10-03→04 ingestion): it resolves to the
  FreeSWITCH fork rather than the classic library; explicit sign-off wanted
  before it becomes the house provider.
- **Versioned name-provides debt** (2026-10-04 Q8 follow-up): 59 recipes /
  113 mapped-name pairs predate the soname+name rule (see §4 provides
  discipline) — each needs `provides=(<name>=$pkgver)` for its swapped,
  VCS-counterpart or compat-mapped stock names. The list is pinned as the
  ratchet in `tests/recipe-contract.sh` section E; shrink it recipe by
  recipe (a provides change needs a real rebuild — the archive's `.PKGINFO`
  is the deliverable), never grow it.
- **version-sync vs pkgrel rebuild triggers** (2026-10-04 merge): a
  version-sync wave resets `pkgrel=1` on a new pkgver while fixture pins like
  `tests/noctalia-pgo.sh`'s `pkgrel >= 2` (the 2026-09-23 PGO fix's rebuild
  trigger) demand the bump — the two conventions collide and re-break the
  battery on every sync wave. Decide: teach the sync machinery to preserve
  trigger bumps, or re-express the pins as "installed build is older than the
  fix" checks.
- **Residual ingestion debts** (2026-10-04 fleet): 3 stale `.SRCINFO`s —
  gcc-snapshot, hermes-agent-git, zen-browser-pgo — await their recipe owner
  (rule 22(c): no self-reported validation); recipe-sources untracked-asset
  noise resolves at commit, no action beyond the commit.
- **ABI provide-refusal blind spot: stock-side consumers of the moving
  provide** (2026-10-06 icu 78→79 diagnosis; the stock-predecessor half was
  closed later the same day — see NOTE 2026-10-06): `abi_provide_refusals`
  used to compare an archive's soname provides against the installed provides
  **of the same pkgname** only, so a stock predecessor under a different name
  was invisible (`icu` 78 vs the new `icu-git`; run #31's bzip2 wall). That
  half is FIXED: the gate now also resolves the `abi_stock_name` counterpart
  when the archive's pkgname is not installed. The stock-side CONSUMER half
  HIT FOR REAL in run #49 (2026-10-07): stock `wlroots0.20`'s
  `libdisplay-info.so=3-64` pin killed the install in raw pacman noise
  exactly as predicted — and is now FIXED too (2026-10-07 gate fix v3, NOTE
  same day): `abi_local_depend_rows` reads the LOCAL DB's reverse deps of the
  moving provide through the `pacman` seam and the plan refuses with
  `refuse abi-stock-pinner <archive> <pinner> <depstring>` naming each
  out-of-tree pinner (exact pins and bare links) before pacman runs; a pinner
  riding the transaction is covered, and workspace outputs stay with the
  surface-consumer logic. Still open (keeps this item queued): a
  **workspace** consumer whose *installed record* pins the moving provide
  exactly is gated only by link truth + in-run repair, and run-repair does
  not satisfy pacman's transaction-time dep check — a non-linking exact
  pinner (or an exact-pinned one repaired only later in the run) can still
  wall at `pacman -U` in raw noise. Decide whether the stock-pinner check
  should also name workspace exact pinners (transaction coverage only) or
  whether in-run repair should require the consumer's pin to be bare.
- **Swap-lint soname-drift findings need disposition** (2026-10-06, from the
  blind-spot fix's new lint half): `fish build-all.fish --audit-lint swap`
  reports 18 real drift rows against this host's installed stock — mostly
  house-only adds where stock ships no soname provides (Arch policy), plus
  genuine drops: `flatpak-git`/`libinput-git` declare no soname provides at
  all where stock carries `libflatpak.so`/`libinput.so`, and `harfbuzz-git` /
  `lib32-gcc-libs-snapshot` drop families stock carries. Report-only. Decide:
  fix the recipes (declare the dropped families) or narrow the lint to the
  drop direction.
- **rustc sanity probe misses non-Rust recipes that compile Rust**
  (2026-10-06 js140 diagnosis): the `--allow-broken-rustc` probe fires only
  for Rust-family recipes, so `js140` (a C++ recipe whose build invokes
  rustc) hit `rustc: symbol lookup error ... version LLVM_23.1` mid-compile
  as a confusing build failure instead of a named probe refusal. The probe
  should fire for any recipe that will invoke rustc (e.g. rustc in
  makedepends), or once per run before dispatch. Queued deliberately —
  probe-scope change touches the fixture-pinned probe seam.
- **libdisplay-info-git is parked at tag 0.3.0 (so.3) — owner decision on
  master (so.5)** (2026-10-07, run #49): the recipe no longer tracks master;
  the pin is the one-line disposition documented in NOTE 2026-10-07 (rule
  30(c)). Revisit with the owner: (A) the heal-set — scratch-test wlroots
  0.20.2 against libdisplay-info 0.4/0.5 headers in `~/Workspace`, and if it
  compiles+links so.5, rebuild wlroots0.20 locally and install
  {libdisplay-info-git, wlroots0.20-local} in ONE `pacman -U` (icu
  precedent), accepting the standing cost that every stock wlroots0.20
  update re-opens the wall; or (B) keep the park — stock wlroots0.20 then
  updates normally. Until decided, `--no-sync` or not, nothing breaks: the
  installed surface stays so.3 everywhere.
- **libpng-git is parked on `#branch=libpng16` (so.16) — so.18 is a
  coordinated batch** (2026-10-07, run #52): upstream's default branch is the
  `libpng18` dev line (SONAME 18) and the branch-less source followed it;
  the installed base pins `libpng16.so=16-64` (stock `harfbuzz`/`leptonica`
  are stock-side pinners; house `freetype2-git`/`libzmf`/`zint` are installed
  and not in the run window), so master is un-installable here (NOTE
  2026-10-07, rule 30(c)). The 1.6 line is alive (`v1.6.59-2-gd76d510`,
  1.6.60.git development), hence a branch pin rather than a frozen tag. The
  so.18 move needs: rebuild {freetype2-git, libzmf, zint, harfbuzz-git,
  leptonica, …every `libpng16.so` pinner} against staged so.18 and ONE
  `pacman -U` — schedule with the owner; until then the recipe tracks 1.6.
- **libseccomp-git is parked on `#branch=release-2.6` (so.2) — master is a
  placeholder build** (2026-10-07, run #54): upstream master carries
  `AC_INIT([libseccomp],[0.0.0])` (stamped only into tags/release branches),
  so a master build derives `-version-number 0:0:0` and ships
  `libseccomp.so.0` — an artifact, not an ABI era. release-2.6 is stamped
  2.6.1 and builds so.2 (zero provide move; man-db and `file` are the local
  pinners). Revisit tracking master only when upstream stamps master's
  version or a deliberate 3.x ABI lands (then it is a heal-set batch).
- **libgit2-git is parked at `#tag=v1.9.7` — `main` declares CMake 1.9.0**
  (2026-10-08, run #70): upstream `main` builds as `project(libgit2 VERSION
  "1.9.0")` and can never satisfy the pkg-config floors `-sys` consumers
  enforce at build time (libgit2-sys 0.18.7+1.9.6 probes `[1.9.6,1.10.0)` —
  rust-git stage2-tools; eza/bat set `LIBGIT2_NO_VENDOR=1` and hit the same
  probe). v1.9.7 declares 1.9.7 and keeps soname libgit2.so.1.9. The tag is
  lightweight/unannotated upstream, so no `?signed` pin is possible. Unpin
  when `main`'s declared version clears the consumers' ranges on both ends.
  NOTE 2026-10-08 (wall #70 part 2).
- **llvm-git ↔ rust-git coupled-batch procedure (stock-rust preemption checked
  out 2026-10-07)**: the predicted "stock `rust` pins `llvm-libs` exactly"
  refusal is void — `pacman -Q rust` reports not installed, so nothing outside
  the set pins llvm. (The once-"real" constraint is void too: bootstrap.toml's
  `/usr/bin/rustc` pins are stripped by the 2026-09-08 recovery, so x.py uses
  the DOWNLOADED official stage0 and `rust-git` rebuilds fine in any system
  rustc state — proven by the 2026-10-08 run #70 rehearsals. What still
  breaks at the swap is a rust-git built against stock llvm linking
  `libLLVM.so.23.1`.) On an llvm-git bump: sweep exact pinners
  (`expac -Q '%n\t%D' | grep 'llvm-libs='`); stage the built llvm-git; build
  `rust-git` against the stage **while the old rustc still runs**; one
  `pacman -U` of the llvm-git splits + rust-git splits.

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

- **A recipe asset that exists to satisfy an external tool probe must be
  wired by the recipe, not by an undocumented host-side placement**
  (2026-10-10 run #114 bettbox): Cargokit (vendored by the `code_forge`
  Flutter plugin) constructs `Rustup()` unconditionally and runs `rustup
  toolchain list` before any toolchain use, and with no `cargokit.yaml`
  precompiled escape a `rustup` binary is a hard build requirement — but
  the host ships only rust-git (`rustc`/`cargo`). The recipe already
  carried `rustup-shim` (a probe-subcommand translator onto the system
  toolchain) whose comment said "Place in `/usr/local/bin/rustup`" and
  which nothing referenced: builds passed while that host placement
  existed, then walled silently on the first rebuild after host drift
  (Cargokit swallows the child build output — the makepkg tail shows
  only Flutter's `Build process failed`). Wire such shims in `build()`
  (`install -Dm755` under the probed name + PATH prepend) and pin them
  in `source=()`. Scan shape: `grep -rln 'rustup\|flutter\|cargokit'
  packages/*/*/PKGBUILD` + `grep -rln shim packages/*/*/` for
  unreferenced assets.

- **A doc-tool feature that is `auto`/default-on runs whenever the tool is
  installed — and the tool's strictness becomes your build wall**
  (2026-10-09 run #92 libusb-git, v4l-utils): libusb's man-pages
  `default=auto` ran doxygen at `make install` under upstream's
  `WARN_AS_ERROR=FAIL_ON_WARNINGS` (doc `\ref`s to a `static inline`
  function doxygen never extracts = hard fail); v4l-utils' meson
  `doxygen-doc=auto` built HTML the recipe deleted immediately after. When
  the trim policy drops the output anyway, disable the feature at the build
  system's own seam (`--disable-man-pages`, `-Ddoxygen-doc=disabled`) and
  drop the tool from makedepends in the same change. Scan shape:
  `grep -rln doxygen packages/*/*/PKGBUILD`, then check whether the doc
  target is part of `all` — `add_custom_target`/`run_target` and
  `BUILD_QCH`-style gates are inert. Related: twin `pkgrel=N.N` marks are
  machine-written by `sync_stable_version` to mirror the Arch repo version
  at build dispatch; `cp` from canonical over a marked twin destroys the
  mark — edit in place or restore it after the copy (NOTE run #92).
- **An upstream that moves its header dir *and* deletes legacy compat
  `#define`s walls a consumer twice — configure probes first, then source
  spellings** (2026-10-09 hplip / cups 2.5): `AC_CHECK_HEADER([cups/cups.h])`
  compiles with the bare include path and dies
  (`cannot find cups-devel support`) although `cups.pc`'s `Cflags
  -I/usr/include/libcups2` resolves it — export
  `CPPFLAGS+=" $(pkg-config --cflags cups)"` in `build()` instead of
  patching configure or symlinking the old path. Then map every legacy
  `IPP_*`/`CUPS_*`/`HTTP_*` token mechanically against the new headers
  (and/or the cached previous version's header — deleted names leave no
  trace), because the renames are non-uniform (`IPP_ERROR`→`IPP_STATE_ERROR`,
  `CUPS_ADD_PRINTER`→`IPP_OP_CUPS_ADD_MODIFY_PRINTER`) and
  `CUPS_VERSION_MAJOR` still reports `2`. Patch-on-patch: generate the shim
  diff against the *fully patched* tree, apply it last in `prepare()`, and
  trim any foreign hunks out of it (a stray `hplip-hpaio-gcc14.patch` hunk
  in the first diff would have broken every rebuild).
- **A feature flag requesting compiled foreign-target code must be checked
  against the toolchain's capability roster** (2026-10-09 handbrake,
  ffmpeg-git): the house LLVM builds `X86;AMDGPU;BPF` only (no NVPTX) and
  `cuda` is purged, so `--enable-cuda-llvm` (PTX kernels via clang) makes
  ffmpeg's configure `die` — explicitly requested + unprobeable = fatal.
  Read the build system's flag *expansion* too (`--enable-nvdec` smuggled
  the CUDA filters in through its block). Drop the flag and its now-dead
  makedepends together; keep dynlink-based hwaccels (ffnvcodec headers).
  Ground truth: `clang --print-targets`; toolkit-free builds are the norm
  (gstreamer's `gst/cuda` builds via bundled `gstcudaloader`).
- **An upstream `-git` API rename with a stale version number breaks every
  consumer that version-gates compat shims — probe the header surface**
  (2026-10-09 cups 2.5 / gtk3): cups 2.5 renamed all legacy IPP/HTTP enums
  and deleted the old spellings while still reporting
  `CUPS_VERSION_MAJOR 2`, so gtk3's `#if CUPS_VERSION_MAJOR < 3` new→old
  shims expanded into deleted names. Check whether the old identifiers exist
  in the *installed* headers before writing a consumer patch, red/green a
  single ninja object target (seconds) instead of a full rebuild, and expect
  the same wall in every other consumer of that header.
- **A `_pick` split pins upstream install paths — the first missing path is
  never the only drift** (2026-10-09 cups-git): upstream moved headers to
  `usr/include/libcups2/` and dropped `cupsimage.pc`/`cups-config` entirely;
  the `mv` failure aborted the `_pick` loop at the first bad entry, hiding
  the rest. Enumerate the whole shipped tree against the `_pick` list, and
  when pruning upstream-created runtime dirs remove `var/run` explicitly —
  `filesystem` owns it.

- **A `$W` twin sync must cover `config/`, and a `--no-deps` selection must
  cover its members' unmet HOUSE prerequisites** (2026-10-09 Qt6 wall): an
  edge fix validated in the canonical tree sorted wrongly in the `$W` run
  because `config/topology.conf` was never copied across (validate ordering
  against the copy you run); and a hand-picked `--no-deps` set that omitted a
  makedepends (`qt6-quick3d`) made makepkg silently install **stock** repo
  replacements — stopped only by a mirror 404. Sync every changed file class,
  and include unmet house prereqs in the selection or use a group run.

- **A snapshot compiler is allowed to be the wall — reproduce the ICE with a
  standalone probe before touching recipes** (2026-10-09 opencv, run #87):
  the build died `internal compiler error: in verify_ctor_sanity` in
  abseil/protobuf headers at -O0 and -O3 — GCC PR c++/127395 (regression
  since r17-4199), a false-positive assert on valid C++. Both available
  snapshots were regressed (downgrade useless) and no upstream fix existed;
  the recipe-side system-protobuf detour could never help (system abseil
  ICEs too) and was reverted. Fix = scope the compiler recipe: make the
  verifier's asserts a no-op in `prepare()` (removing only the firing assert
  would segfault the compiler — the asserts below dereference the same null
  pointer), drop it when upstream lands a fix. A ~10-line TU against system
  headers reproduced the ICE in <5 s where a full build took 30+ min: red
  the probe on the broken compiler, green it on the rebuilt one, so the
  compiler change is falsifiable rather than assumed.

- **An `-i` install of an LLVM-ABI provider replaces the SONAMEs the LIVE
  mesa stack dlopens — black desktop + hard freeze** (2026-10-07): house
  `llvm-libs-git` swapped out stock `libLLVM.so.23.1` while stock mesa was
  live; niri lost all outputs (`MESA-LOADER: failed to open dri:
  libLLVM.so.23.1`) and the machine froze. The coupled-batch gate checks
  SELECTION completeness only — it never delays the anchor's INSTALL, so
  `-i` leaves an ABI-stale window mid-run. Until an install-deferral seam
  exists: run `-i` batch runs with the GUI stopped or accept a session
  restart at the batch; a black screen after a build run is first a
  `libLLVM*`-presence check, never a display bug.
- **`$srcdir` persists across makepkg runs — recipe-side state creation must
  be idempotent** (2026-10-07 sqlite, run #39): a bare `mkdir "$srcdir"/tcl`
  died on the empty dir left by run #36's failed attempt, and a clean-clone
  validation missed it. `rm -rf` before recreating staging dirs
  (deployments-delete-destination style), and validate packaging-layout fixes
  against a POLLUTED work dir — same family as Meson build-dir staleness.
- **A Stock→house swap must reproduce the stock pkg-config NAMES, not just
  the soname** (2026-10-07 bzip2-git): meson `pkg.generate(lib)` names the
  pc after the library target (`bz2.pc`, `Name: bz2`) while the ecosystem
  requires `bzip2` (`freetype2.pc` has `Requires.private: … bzip2 …`) —
  the swap deleted the name and fontconfig-git died in 4 s on a wrap
  fallback. Verify `pkg-config --exists <name>` for every pc name the stock
  package shipped; a pc file other packages `Require` is ABI-adjacent
  interface.
- **Never pin a tcl-versioned install path in `package()`** (2026-10-07
  sqlite; recurred 2026-10-10 graphviz): tcl 9's `TCL_LIBRARY` is the pseudo-path `zipfs:/lib/tcl/tcl_library`,
  so an upstream `install-tcl` wrote a literal `$pkgdir/zipfs:/…` tree and the
  recipe's `mv usr/lib/tcl8.6/*` glob found nothing — a tcl-wave wall in a
  PACKAGING step, not a compile. The graphviz recurrence pinned the dedup dir
  `usr/lib/tcl8.6` itself; after the Tcl 9 bump the bindings staged at
  `usr/lib/tcl9.0` and `cd` failed. Derive the location from `tclConfig.sh`/
  `TCL_PACKAGE_PATH` (tcl 9: `/usr/lib`), locate the payload by content
  (`find -name pkgIndex.tcl`), or match a `tcl*/` glob — never a literal
  versioned dir. On one such drift, sibling-scan every recipe touching the
  same versioned path in the same wave.
- **`makepkg` is a WRITER of the recipe it touches** (2026-10-06): `--nobuild`
  still runs `pkgver()` and rewrites `pkgver=` in place (`/usr/bin/makepkg:190`
  `update_pkgver`) — a "read-only" screening sweep dirtied 12 tracked
  PKGBUILDs and red-legged `srcinfo-freshness`. Any screening/linting that
  shells into makepkg runs in a recipe-dir COPY (global SRCDEST keeps the
  cache shared); dirty PKGBUILDs after any makepkg call are expected.
- **The fixture battery is unsafe beside a live `-i`/`-ia` run** (2026-10-06):
  fixtures' install preflights read the REAL `/var/lib/pacman/db.lck`; a live
  `sudo pacman -U` (root, fds hidden → "holder unknown") makes them refuse
  and random install fixtures go red. Run batteries in the gaps between
  builds; queued: a fixture-side `pacman-conf` stub pointing the lock check
  at a fixture-local DBPath.
- **A pkgrel floor is unsound on version-synced recipes** (2026-10-06): the
  github provider resets pkgrel=1 whenever it advances pkgver
  (`lib/sources.fish` `new_pkgrel`), so `pkgrel >= N` ratchets break on the
  next advance — pin the fix's content greps, never its release number.
- **A `[[ -f ]] && cmd` guard as a function's last command fails the function
  when the file is absent** (2026-10-06 mpg123): 16 recipes carried the
  license-loop idiom `[[ -f $_l ]] && install ...`; when the last candidate
  file is missing upstream (mpg123 1.33.7 ships only `COPYING`), the loop's
  short-circuit status 1 becomes `package()`'s return value and makepkg fails
  with no error text. Guards at function tail use `if ...; then ...; fi`
  (status 0 either way) — same family as the discarded-status rule the PGO
  gate exists for.
- **Fixture stub argv shapes ARE the contract** (2026-10-05): routing a raw
  probe through a helper is safe only when the forked argv is char-for-char
  identical — adding `--` to `pacman -Q NAME` silently disabled the ABI-batch
  refusal path, and only refusal-shaped scenarios (§B-style) could catch it.
  Probe-count oracles must therefore be separator-agnostic (`OP [--] NAME`),
  and a changed probe argv needs a fixture re-run, not just a green subset.
- **`count $list` in a hot loop head is O(list)** (2026-10-05): fish `count`
  is O(1) but its argv EXPANSION is not — a BFS `while test $qhead -le (count
  $queue)` head cost 38 s across 19 822 iterations. Cache the length and
  maintain it at the append sites.
- **Fixture scale pins are probe/CALL counts, never wall-clock** (2026-10-05):
  and any step that must follow a phase start waits on an EVENT (marker file,
  log line), never a sleep — `tests/run-record.sh` scenario 5's `sleep 1.5`
  raced the pre-dispatch phase under battery parallelism and flaked into the
  pre-dispatch-interrupt outcome (itself correct, pinned by signal-abort-lock).
- **`set -n` + `string match -r` name sweeps erase NOTHING unless the pattern
  matches the whole name and has no capture groups** (2026-10-05, one defect
  with two faces): `string match -r` prints only the matched *portion* (a
  `^_TID_` prefix yields `_TID_`, never `_TID_p1`, so `set -e` erases a
  non-existent var), and a `(…)` alternation is additionally printed as junk
  names (`TID`, `TCONS`). The stale-keyed-var sweeps of `read_topology_config`,
  `dispatch_state_refresh` and `_deferred_blocked_refresh` all carried it; the
  first flipped `unverifiable_defer_plan`'s topology re-read into "duplicate
  package id", silently turning every defer into a build (two fixtures
  regressed). Use `'^_PREFIX_[A-Za-z0-9_]*$'` with `(?:…)` alternation and
  verify the erase in isolation. Corollary: lane children redirect stderr into
  `state/logs/<pkg>.log`, so trace echoes there never reach `FIXTURE_OUTPUT` —
  route temporary instrumentation to a fixed scratch file.
- **fish 4.9.3 does not expand `(cmd)` inside double quotes; a bare `$$var`
  statement EXECUTES the list** (2026-10-05, two measured defects): an
  `awk -v x="(string join …)"` passed literal text and silently defeated a
  batch (per-name forks stayed); a `$$dep_var` statement ran the list as a
  command. Use `"(cmd)"` concatenation or a variable for the first; always
  `printf '%s\n' $list` for the second. Caught only by profiling/fixture —
  both fail silently.
- **Bare `rm` in fish-run builder code does not delete on this host**
  (2026-10-05): the login shell's fish `rm` is a fast-trash function (mv +
  `.trashinfo`), so `rm` inside `build-all.fish` and any fish context silently
  archives instead of deleting — cleanup flags and staged-rewrite discards
  "worked" while leaving everything behind. Use `command rm` or
  `find -delete` (verified 2026-10-05; the lane sweep/reap/result gate were
  fixed; a file-wide sweep of the remaining bare sites is queued).
- **Mold cannot build this glibc recipe — the recipe pins bfd, only for
  itself** (2026-10-03, glibc-git; three measured defects): (1) the
  `librtld.mk` member parse matches GNU-ld/lld map lines only; mold map lines
  (`0x…`) yield zero rows → empty `rtld-subdirs` → the opaque
  `rtld-Rules:40` "subroutine of elf/Makefile" stop. (2) mold's `-r`
  relocatable link drops symbol versions from the output symtab: glibc's
  compat/default pairs (`forkpty@GLIBC_2.2.5` + `forkpty@@GLIBC_2.34`)
  collapse into duplicate unversioned rows at the same offset, breaking every
  later link. (3) mold's `-shared` links drop map-assigned **default**
  versions: a version script splitting one unversioned input symbol across
  nodes must emit `sym@@old` + `sym@new` (Arch's installed lib32 oracle has
  `open64@@GLIBC_2.1` + `open64@GLIBC_2.2`); mold emitted only the compat
  row, an ABI defect that failed here merely because a later unversioned
  reference could not bind. The recipe therefore appends `-fuse-ld=bfd` to
  `LDFLAGS` in `build()` (appended last: gcc takes the last `-fuse-ld=`), and
  the patch guards the parse (named remediation), makes the map depend on its
  makefile, and pins the one `$(CC)`-direct link past LDFLAGS. Rules: a
  recipe parsing a tool-produced map/depfile owns the producing side of the
  seam — pin the format at the producer instead of extending a parse to
  private formats (mold's map format is undocumented); treat linker choice as
  a per-recipe decision (never `/etc/makepkg.conf`, shared system state, one
  line flips all 145 recipes), and verify artifact *symbol version tables*
  against an installed oracle, not just link success; makefile-generated
  artifacts depend on their defining makefile (and when a prerequisite joins
  `$^`, name the inputs explicitly); upstream-source patches apply with
  `--fuzz=0` plus verbatim greps; `prepare()` purges generated link
  intermediates after a rule change (make never revisits an up-to-date
  corrupt file). Related pitfall same day: a git-sourced glibc has no
  top-level `COPYING` (release tarballs add it) — the recipe's
  `_install_license` installs the tree's `COPYINGv2/COPYINGv3/
  COPYING.LESSERv2/COPYING.LIB` explicitly. Patch
  `packages/core/glibc-git/0001-bfd-relocatable-links-*.patch` needs
  refreshing if a `_commit` bump changes the glibc Makefiles — `prepare()`
  fails loudly, by design.

- **A VCS `pkgver()` that parses upstream build metadata is a silent-drift
  hazard** (2026-09-30, noctalia-git): upstream moved `version:` out of
  `meson.build` into a `VERSION` file (`version: files('VERSION')`), the
  recipe's `sed` matched nothing, and the build produced
  `noctalia-git-.r5671.g368755604-1` — an empty version prefix and zero build
  errors. The archive name and `pacman -Qi` are the only witnesses. `pkgver()`
  now falls back to the `VERSION` file. Rule: a `pkgver()` that greps upstream
  metadata is a parsing contract with upstream; when a rebuilt archive's name
  looks wrong, run `pkgver()` against the source tree before trusting anything
  downstream, and prefer an upstream version *file* over parsing build scripts.
  Related: when `pkgver()` moves the version, **makepkg** rewrites the static
  `pkgver=` line and resets `pkgrel=1` in the PKGBUILD itself (lane log
  `==> Updated version: …`) — so a committed `pkgver=`/`pkgrel=` pair is a
  record of the last build, not a hand-managed value.

- **openexr ≥ 3.5 resolves zstd via `find_dependency(zstd CONFIG)`**
  (2026-09-29, krita-git generate failure): zstd's Makefile install ships no
  CMake package config, so config-mode OpenEXR resolution fails and every
  bundled find-module falls into its fallback path — krita's fell over on an
  upstream `ImfConfig.h`/`ImathConfig.h` typo and leaked
  `Imath_INCLUDE_DIR-NOTFOUND` into an imported target. `zstd-git` `package()`
  now installs a hand-written `/usr/lib/cmake/zstd/` config
  (`zstd::libzstd_shared`) — keep it when touching the recipe. Rule: a
  Makefile-built provider of a CONFIG-mode dependency must ship its CMake
  package config.

- **shtab ≥ 1.6 outgrew upstream's hard-coded shell list** (2026-09-28,
  trash-cli `check()`): 3 `test_help` assertions fail because shtab's help
  text lists more shells than upstream's expectations hardcode — upstream
  brittleness, not a packaging defect. The suite stays full and the recipe
  documents the skew (the host's `BUILDENV=(!check)` makes makepkg skip
  `check()` here anyway). Leave a full suite with documented skew rather than
  deleting tests to make `check()` green.

- **A `checkdepends`-only test dep that upstream *configures* against walls
  `build()`** (2026-10-06, `bzip2-git` run #30): upstream's
  `tests/meson.build` hard-errors at configure without pytest, but
  `BUILDENV=(!check)` means makepkg never installs `checkdepends` — the
  probe dies in `build()` before `check()` exists. That is the boundary
  against the shtab rule above: delete a suite only when its configure-time
  requirement makes `build()` impossible and no option can disable it
  (validate `-D tests=…` against `meson_options.txt` first — bzip2 has no
  `tests` option at all, so the trim is `sed "/subdir('tests')/d"` at the
  inclusion point, dropping `check()`+`checkdepends` in the same change,
  libei-git shape). A suite that merely fails inside `check()` stays.

- **`cargo test` integration suites mis-resolve test binaries on this host's
  rust-git toolchain** (2026-09-28): the binaries land in
  `build/<pkg>/<hash>/out/` instead of `deps/`, which breaks harnesses that
  resolve the binary path. Irrelevant to packaging (`BUILDENV=(!check)`
  skips `check()`), so do not chase a scratch `cargo test` failure as a
  recipe bug.

- **An expired maintainer key whose signature predates the expiry verifies,
  with a warning** (2026-09-28, `file` 5.48): Zoulas' key expired 2026-08-15;
  makepkg reports EXPKEYSIG and still passes. Keep `#signed`/`validpgpkeys`
  and never `--skippgpcheck`; record the expiry date and the re-key
  contingency for the next bump. (Subkey signatures — rsync via Zen Dodd's
  subkey to primary `C0E10545`, fd via web-flow — resolve to the primary as
  the existing rule says; do not append every subkey.)

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

- **VCS `-s` freshness includes each declared source ref** (approved
  2026-10-01; the 2026-09-25 vulkan-pair incident): retain the
  archive-mtime ≥ PKGBUILD-mtime gate, then skip a VCS archive only when
  every declared source ref still resolves to the actual revision recorded
  for that archive after a successful build. Check Git, SVN, Mercurial, and
  Bazaar refs individually; never compare a shared checkout or unrelated
  repository `HEAD`. A moved ref follows the normal build/install path. If
  the selected ref cannot be parsed, or upstream does not answer a Git ref
  query even after the transport retries (0.5 s/1 s, 3 attempts; a completed
  `ls-remote` "no such ref" answer is not retried), PARK the recipe before
  `makepkg` — defer, lane rc 99, run-record reason `upstream-unverified` —
  never fail the run over an unverifiable upstream and never silently skip
  or build against unknown state (2026-10-02). Only a positively confirmed
  ref-equals-baseline may skip or install. If
  the per-archive baseline is missing, malformed, or mismatched, resolve every
  selected ref and rebuild once to record the revisions actually used; never
  infer that the current ref produced the old archive. Non-VCS recipes retain
  the mtime-only behavior, and `-s -i` still sends a genuinely skipped archive
  through the existing install path.

  Historical case: `-s -i` skipped `vulkan-headers-git` at 1.4.363 while
  `vulkan-icd-loader-git` fetched v1.4.364, whose CMake required
  VulkanHeaders ≥ `${PROJECT_VERSION}` ("not compatible with the version
  requested"). The incident-time recovery was to rebuild the pair with `-i`
  and without `-s`; that workaround is superseded by the rule above. The
  loader's versioned makedepends
  (`vulkan-headers>=1:${pkgver%%.r*}`) still makes a stale provider fail at
  the dependency check instead of inside the consumer's build
  (`tests/vulkan-pair.sh`). Pre-metadata VCS archives now take one
  selected-ref-checked `-s` rebuild before later resumes can skip them.
- **The recorded VCS baseline is read from the build's `$srcdir` working
  copy** (2026-10-02, xdg-utils incident): `vcs_source_checkout` probes
  `<recipe>/src/<name{,.git-stripped}>` first, then the package root, then an
  exported `SRCDEST` — never the reverse. `$startdir/src` is where
  `extract_git` materialises the tree `build()`/`package()` `cd` into, and
  the path needs no environment (`sudo` env_reset strips `SRCDEST` from the
  recorder exactly in the root-supervisor runs); a mirror in `SRCDEST` or at
  the package root carries the remote's default HEAD, not the built ref, so
  recording from it would mint a manifest for a revision the archive never
  contained. A checkout that exists nowhere stays a loud post-build failure —
  never record an "unknown" for a file whose consumers decide `-s` skips from
  it. Pinned by `tests/skip-upstream.sh`'s srcdir sections (decoy priority +
  hermetic `SRCDEST`).
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
  `Version and checksum sync this run` summary; with no official document the
  recipe refuses, restores, and is DEFERRED — parked with a named marker and
  its recovery lines while the dispatch continues, its dependents held back
  and labelled `waits on a deferred package`.
  `tests/stable-sync-checksums.sh` pins every scenario in its header and
  `tests/anchor-defer.sh` pins the deferral end to end; each was falsified
  before being trusted — reverting the sum map, the `name::` rule, the source
  diff, the VCS branch, the tag fallback, the refresh-only branch or the
  defer switch each makes scenarios fail exactly where they should.
  The same sync OWNS `pkgver`/`pkgrel` on `packages/stable` recipes, and since
  2026-09-28 it never *downgrades* them: a repo bump still moves forward
  (`wireplumber` 0.5.17-1.1→2.1), a `pkgver` move resets `pkgrel` to the
  repo's, but at equal `pkgver` a local `pkgrel` **ahead** of the repo is a
  deliberate bump and survives (the 2026-09-28 sync clobbered ripgrep's PGO
  `pkgrel=2` back to the repo's 1 on every loader run, silently re-stamping a
  three-phase PGO build with the pre-PGO revision identity — and the
  2026-09-26 campaign stance, "rewrite EXACTLY and in BOTH directions; align
  committed values to the repo rather than fight the sync; a deliberate local
  bump needs `--no-sync`", is superseded: `--no-sync` also disables version
  tracking, so it cannot carry a standing bump, and pkgrels never move down at
  a fixed `pkgver` in the repos, which makes "local ahead" unambiguous — a
  deliberate bump, never staleness). `tests/stable-sync-checksums.sh` case 12
  pins the kept direction and its pkgrel-only variant pins the adopted one.

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
  **typo is never auto-corrected** — a wrong guess rebuilds a package plus its
  consumers — it is reported with up to three candidates, ranked by an awk
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
  adding any package (check method in golden rule 9; registration is dynamic
  since 2026-10-05 — an install run registers accepted archives itself). Back up
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
  pinned by `signal-abort-lock.sh`; not one of the public `GSA_*` inputs —
  their roster lives in `docs/build-guide.md` § Environment surface), and
  `.SRCINFO` freshness has exactly one owner, `tests/srcinfo-freshness.sh`.
- **User-level fish wrapper functions intercept the battery's PATH stubs**
  (2026-09-26, harness; invocation guidance corrected 2026-10-09): the
  builder runs under fish, and fish autoloads functions from
  `$fish_function_path` before any PATH lookup — so a user-level `sudo`
  wrapper shadows the `sudo` stub a fixture placed in front of `$PATH`, and
  that wrapper re-execs the real sudo with `--preserve-env` added (a flag
  the builder never passed; this is why `stub_sudo` in
  `tests/lib/fixture-lib.bash` strips it — the stripping is the load-bearing
  mitigation and makes a plain run safe). Do **not** "fix" this with
  `fish_function_path=/nonexistent-fp bash tests/run-all.sh`: fish imports an
  env `fish_function_path` as a *single-element* list, so that prefix drops
  every function dir — including `vendor_functions.d`, where
  fish-pure-prompt's `_pure_set_default` autoloads from. Every fish
  startup then spews `Unknown command: _pure_set_default` noise from
  `vendor_conf.d/pure.fish`, and `run_builder` captures stdout+stderr
  combined, so exact-match fixtures (e.g. `abi-exposure-audit.sh` §A) fail
  with want/got blocks that look byte-identical — look for hidden stderr
  pollution before suspecting the lint. Run the battery plain
  (`bash tests/run-all.sh`).
- **Tree exclusions in `find` are `-prune`, never `-not -path`** (2026-10-09,
  builder): `-not -path` filters output only, so `sweep_stale_run_artifacts`
  still descended into every recipe's `src/`/`pkg/`/`build/` trees at run
  start — 11+ minutes of I/O before the first dispatch of a single-package
  run. All three staging-excluding finds (run-start sweep, `cleanup_pkgs`,
  the audit stale listing) now prune the staging dirs instead; exclusion
  sets unchanged. `tests/log-ownership.sh` §1b pins the boundary (decoys under
  `src/`/`build/` survive, a recipe-depth temp is swept). Details: NOTE.md
  2026-10-09.
- **A build failure blaming a missing makepkg/lib file during a `pacman`
  recipe install is a self-hosting race, not a recipe wall** (2026-10-09,
  scheduler): installing our `pacman` replaces `/usr/share/makepkg/*`, and a
  lane whose `makepkg` starts in that window dies on `util.sh: No such
  file`. Verify the toolchain and resume (`-s`); never "fix" the victim
  recipe. Details: NOTE.md 2026-10-09.
- **A systemd bump that drops a hook input is guarded in the mkinitcpio
  recipe, never worked around on the host** (2026-10-09, mkinitcpio): systemd
  262 dropped `systemd-tpm2-setup` and the initrd PCR units that
  `install/systemd` hard-required, breaking `mkinitcpio -P` for every kernel.
  `0002-guard-missing-systemd-tpm2-setup.patch` guards all seven absent names
  (0001 covers NvPCR). Scan the whole hook input list against the installed
  provider in one pass; bump `pkgrel` so a checked install cannot
  same-version-skip. Details: NOTE.md 2026-10-09.
