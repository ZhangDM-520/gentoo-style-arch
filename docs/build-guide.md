# Build guide

## Prerequisites

Use an Arch-based system with `fish`, `makepkg`, `nproc`, `ps`, `awk`, `sed`,
`tail`, and `getent`. Add `ripgrep` (`rg`) for `--audit` and `git` for
`--link-sources`. Building and installing also needs `pacman` (adding `flock`,
plus `sudo` unless you run as root supervisor) and `base-devel` for the
recipes themselves. A working compiler, enough disk space, and the package
dependencies named by the selected recipes are also required.

`--audit` needs `rg`, and `--link-sources` needs `git`. The upstream-aware
`-s/--skip` check also needs the client for each declared source protocol
(`git`, `svn`, `hg`, or `bzr`) and access to its remote when a selected recipe
has VCS sources; a non-VCS recipe keeps the mtime-only skip check.

## Inspect, dry-run, then build

```sh
fish build-all.fish --help
fish build-all.fish --audit
fish build-all.fish --list
fish build-all.fish --dry-run --group core
fish build-all.fish --group git --intensity xhigh
```

The builder refuses an empty selection. Every selection expands to the named
packages plus their transitive consumers — the packages that must rebuild
after them — because rebuilding a package cannot break what it consumes, while
its consumers carry the ABI risk. Prerequisites are assumed installed and
current, so nothing upstream is pulled in; bootstrap and fresh builds use `-g`
group runs. `--no-deps` is for a deliberately scoped leaf rebuild of exactly
the named packages, whose installed prerequisites are already known to be
current.

## Installation modes

Without `--install`, a successful build leaves package archives for later
review or `--installall`. With `--install`, each split package is installed
immediately after its build, before dependents are dispatched. This avoids
compiling against an older ABI. Core selection automatically enables
immediate installation because its ABI coupling makes a collective install
unsafe.

`--installall` (`-ia`) installs every archive in the workspace in **one**
pacman transaction, so it cannot honour the install-before-dependents rule:
use it only to re-install a set that does not depend on each other (for
example after `--cleanup`, or with `--overwrite`), never as a substitute for
`--install` in a run whose packages are chained in build order.

Root-supervisor mode is:

```sh
sudo fish build-all.fish --group core
```

The supervisor installs as root but runs `makepkg` as the invoking user and
resolves that user's real home directory. A bare root shell without an
invoking user is rejected. Runtime-state ownership is settled at write time:
the supervisor repairs wrong owners (announced), creates every state file as
the invoking user — never as root — and a run killed mid-flight can no longer
leave logs that poison the next one.

### Skip and resume

`-s/--skip` keeps the archive-mtime versus `PKGBUILD`-mtime check. For
non-VCS recipes, that remains the full freshness check. For a VCS recipe, it
is only the first gate: the builder compares the actual source revisions
recorded for that archive after a successful build with the current remote
revision of each VCS source's declared ref (`git`, `svn`, `hg`, or `bzr`).
Every declared ref must still match before the archive can be skipped. A
moved ref makes the archive stale and the package follows the ordinary build
path. Resolve the declared ref, not an unrelated repository `HEAD` or the
mutable shared source checkout.

If an archive has no usable revision baseline, `-s` never assumes that the
current upstream ref produced it. The builder first checks that each declared
ref can be parsed and resolved, then performs one normal build to record the
actual source revisions used for the replacement archive. A later `-s` can
skip it normally. If a ref cannot be resolved, the builder stops before
`makepkg`; it does not skip the archive or begin an unverified migration. A
valid baseline whose ref moved follows the normal build path. On a genuine
skip, `-s -i` continues through the existing install path; a one-time legacy
rebuild follows the normal build/install path.

### Stable version sync and checksum verification

Untagged `packages/stable` recipes track the Arch repository version and are
updated automatically before they build: the builder reads the repo's version
with `pacman -Si` and rewrites `pkgver`/`pkgrel` in the recipe **in place** when
the repo is newer. A downgrade is never written: a higher content `pkgver` is
kept, and at equal `pkgver` a local `pkgrel` **ahead** of the repo is a
deliberate bump (a PGO wave marks its own revision — ripgrep's `pkgrel=2` over
the repo's 1) and is kept too; only a repo `pkgrel` actually ahead is adopted,
and a `pkgver` move resets `pkgrel` to the repo's. A `pkgver()`-driven recipe
is skipped entirely. The edit is left in the working tree for you to commit,
uncommitted. When a source URL moves, the builder refreshes its checksum and
`.SRCINFO` from the official anchor; when no source moves, the committed sums
remain valid, though the `.SRCINFO` may need regeneration after a version-field
change. Review the diff before committing.

#### Explicit nvchecker providers

Build-time nvchecker is opt-in through the validated topology tag
`version-sync=nvchecker`; an existing `.nvchecker.toml` alone does not change
the version source. Run `fish build-all.fish --topology` to inspect which
records currently opt in. The builder reads the provider from the selected
config section, then runs only that section with temporary
`old_ver.json`/`new_ver.json` state outside the repository and
`NVCHECK_STATE_DIR`. This path requires `nvchecker` and Python 3.11+; moved
sources also require `curl` and `updpkgsums`.

GitHub packages reset `pkgrel` to 1 only when `pkgver` moves and retain a local
`pkgrel` at the same version. AUR packages use the matching `.SRCINFO` for
`pkgrel` and `epoch` on a new version; at equal `pkgver`, the upstream
`pkgrel` may move forward but never lowers a local revision. The snapshot
recipe derives `_pkgver` from its strict `pkgver` date format, so the source
URL moves with the selected snapshot and unsupported formats fail closed.

For moved GitHub release assets, a published asset digest is matched to the
configured repository, release tag, and filename, then verified against the
fetched bytes. For `name::url` sources, the remote URL basename selects the
release asset while `name` still identifies the local fetched file. A release
without a matching digest uses the existing loud
fetch-only path; the log and run summary do not describe its refreshed hash as
upstream verification. AUR `.SRCINFO` must match the configured `pkgbase`, the
resolved `pkgver`, and the recipe's expanded source array before its checksums
can anchor a build; `SKIP` entries follow the same fetch-only rule. Provider/
network failures and AUR metadata races defer the package; a published-checksum
disagreement stops the run as an integrity failure. Rewrites are rolled back
on a failed version mapping, metadata match, or checksum check.

`--no-sync` disables both the default Arch query and every opted-in nvchecker
query/checksum refresh; it builds the committed recipe version and sums as-is.

A rewrite that moves **`pkgver`** can move the `source=()` URLs with it, so the
committed sums can end up describing the previous version and `makepkg` would
reject the freshly fetched sources.

Note where the version came from versus where the bytes come from: `pacman -Si`
reports the version Arch publishes, but `makepkg` fetches that tarball from
**upstream** (`ftp.gnu.org`, `github.com`, `cdn.kernel.org`, …). "The official
repo" covers the version, not the fetch, so syncing cannot vouch for the bytes
on its own. `updpkgsums` by itself would not either: it rewrites the sums from
whatever arrived, which agrees with any tarball, including a substituted one —
a verification-shaped no-op.

What makes the sums stale is not the version bump but a **moved source**: 26 of
the 28 `packages/stable` recipes pin a literal version inside their `source=()`
URLs, so a rewrite leaves them fetching exactly what they fetched before and
their committed sums still verify. Only `linux-api-headers` and
`linux-firmware` spell the version into a URL. The builder therefore diffs the
expanded `source=()` array around the rewrite and only acts when an entry
actually changed; otherwise the build runs against the committed sums.

For moved entries in the untagged Arch path, the sums are re-anchored to the
**official Arch packaging repo**:

1. Fetch `https://gitlab.archlinux.org/archlinux/packaging/packages/<pkgbase
   or split pkgname>/-/raw/<ref>/.SRCINFO` — the same authority the version came
   from. `<ref>` is `main`, with **the version's own tag** (`<pkgver>-<pkgrel>`)
   as the fallback for when the packaging repo has already moved past the
   version the repos carry (bash's `main` is 5.3.20 while the repos serve
   5.3.15). The revision must carry the version just synced to: another
   version's sums describe different files.
2. Match the moved `source=()` entries against the checksums it publishes, by
   the name `makepkg` gives each one (a `name::url` override wins over the URL
   basename). Entries it publishes a value for are *anchored* (step 4);
   entries it publishes **no** checksum for (SKIP, or absent from its source
   list — e.g. the kernel recipes' concatenated local sources) are
   *refresh-only*: the same `updpkgsums` run refreshes them, and the package
   log and the run summary each name them as fetch-only (see below).
3. Write the refreshed sums with makepkg's own `updpkgsums`, so the recipe keeps
   its formatting and its choice of algorithm.
4. Verify the fetched sources against Arch's published checksum. The algorithm
   need not match ours: Arch's hash is applied to the artifact, and the artifact
   is what the recipe's own hash now describes. A VCS entry is verified the way
   `makepkg` verifies it — `git archive --format tar <tag>` hashed, not a
   directory — because a pinned tag is reproducible here (checked against `fish`
   4.9.3 and `ccache` 4.14, whose values matched Arch's byte for byte).
5. Refresh the committed `.SRCINFO`, when the recipe ships one — the sums are
   part of it, so leaving it behind would pin the previous version's checksums.
   `updpkgsums` and that step run as the invoking user in root mode, because
   `makepkg` refuses to run as root.

That makes the refresh an anchor rather than a rubber stamp — a substituted
fetch is caught here, which is exactly what plain `updpkgsums` cannot do. The
package log records the result, which in a multi-lane run is the only record
that exists:

```
ℹ <package>: checksums re-anchored to the official <pkg> <ver> checksums,
  and verified against the fetched sources
```

**A source that disagrees with Arch's checksum refuses the build** — that is
the integrity signal, and it *stops the dispatch* like a failed build — and the
recipe is restored byte-for-byte where it was already rewritten. The same
refusal, now carried as a **deferral** (below), covers the paths where
anchoring is impossible at all: `curl` or `updpkgsums` missing; no official
revision carries our version; its sources and checksums do not line up (an
unparseable file is never an anchor); the checkout could not be recomputed;
or `updpkgsums` itself fails. Nothing is built or installed in those cases,
and the message names the failing entry:

```
✗ <package>: refusing to build — a source does not match the official Arch checksum
    <file>: Arch's sha512 is <want>, the fetched source hashes to <got>
```

Refresh-only entries get the loud record instead of a refusal:

```
⚠ <package>: official <pkg> <ver> publishes no checksum for (refreshed from
  the fetch, NOT anchored):
    <file>
  Attestation: a detached signature is PGP-verified against the anchored
  payload at build time, a VCS source is pinned by its #tag/#commit, and a
  plain download is attested by nothing but the fetch (TLS). Review these
  sums before committing; '--no-sync' builds the committed version as-is.
```

**One unanchorable recipe no longer strangles the dispatch** (2026-09-24):
the impossible-to-anchor paths *defer* the recipe instead of failing it. The
lane result protocol is unchanged — `_ANCHOR_DEFER_RC` (99) rides in the
ordinary rc field — but the reap parks the recipe (`DEFERRED`, never counted
failed, dispatch keeps going), `pick_next_ready` holds back its dependents
(printed `waits on a deferred package`, not "dependency cycle"), the run
summary tails the parked recipe's log (the named error plus both recovery
lines), and the run exits non-zero with every parked or waiting package in the
resume command. Before this, ONE recipe whose official `.SRCINFO` published no
checksum for a moved source cost the other ~120 packages their dispatch —
twice in a row. Signature files are outside checksum anchoring altogether
(`.sign` joins `.sig`/`.asc`): makepkg verifies them with PGP against
`validpgpkeys` over the anchored payload, which is why refreshing their hash
would prove nothing.

At the end of every run that touched the tree, the sync's dispositions are
printed at run level — a run never commits; that stays the maintainer's:

```
Version and checksum sync this run (uncommitted — review with 'git diff', then commit):
  <pkg>: <old-ver> → <new-ver> (synced with <Arch repo, AUR, or GitHub>)
  <pkg>: checksums refreshed at <ver> — <n> anchored to <provider>, <m> refresh-only (fetch-only sums: review before committing)
```

`--no-sync` avoids both sync paths: no provider lookup or rewrite, no
anchoring, no refusal, and no refresh-only record. The committed version and
sums build as-is, at the cost of not tracking Arch or opted-in upstream
versions. **`--skipchecksums` is never passed by
the builder.** In the default Arch path, a missing official document carries
the manual `updpkgsums` recovery line. An opted-in provider outage or AUR
metadata race instead defers for a retry; never clear it by treating a
fetch-generated hash as provider verification. A published-checksum mismatch
stops the run and restores the original recipe.
Signature verification is a separate check throughout — it is enforced
wherever the recipe has a `validpgpkeys` source, and 13 of the 28
`packages/stable` recipes anchor authenticity that way rather than by checksum.

### sudo during `--install`

Unprivileged `--install` installs happen inside lane children, which have no
terminal, so every transaction is `sudo -n` — and as of 2026-09-26 **every**
privilege escalation in the builder is `sudo -n`. The builder never prompts
for a password (`sudo_elevate_interactively` is gone). It keeps "I cannot
refresh a credential" distinct from "installs are impossible":

- Before dispatch it probes what sudo can actually do, and **refuses to
  start** (`sudo cannot install non-interactively`) when installs could not
  succeed — rather than building for an hour first. A TTY changes nothing:
  with a cold credential and a terminal attached the run still refuses
  (`tests/sudo-keepalive.sh` scenario 4 pins this).
- While running it keeps the timestamp warm with a non-interactive
  `sudo -n -v` refresh at `_SUDO_KEEPALIVE_S` (150 s, well inside the sudo
  timeout). If that refresh is refused but a plain install command works — a
  sudoers `NOPASSWD` entry covers the installs — there is no credential to
  keep warm and it stops probing instead of stopping the run.
- If the credential is genuinely lost mid-run, dispatch stops once
  (`sudo credential expired and cannot be refreshed`, one message, not one
  per poll), in-flight lanes drain, and the run lists the unstarted packages
  as remaining and exits non-zero. A stopped dispatch is never reported as a
  successful build. There is no prompt to fall back to: rerun under `sudo
  fish build-all.fish …` or prime `sudo -v` yourself first.

`--installall` behaves the same way — it never prompts either.
`sudo fish build-all.fish …` remains the option-free way to avoid credential
expiry altogether: installs run as root and `makepkg` still builds as you.

## Runtime state and cleanup

Builder state is under `.state/` by default. Set `GSA_STATE_DIR` to put logs,
lane results, and lock files elsewhere. makepkg source mirrors and
archives follow its `SRCDEST`/`PKGDEST` configuration:

```sh
GSA_STATE_DIR="$HOME/.local/state/gentoo-style-arch" \
  fish build-all.fish --group git
```

State files are owned by the build user from the moment they are created. If
a previous root-mode run was killed mid-flight and left an unopenable file
behind, an unprivileged run preserves it under a
`<file>.stale.<epoch>.<pid>` name — announced — and starts a fresh log rather
than failing; running the same command once under `sudo` repairs ownership of
the whole state directory at startup instead.

`--cleanup` removes package archives. `--nuclear` interactively removes
downloaded sources, VCS clones, and makepkg staging directories while keeping
recipe-local patches and intentional symlinks. Review its target list before
confirming. Ctrl-C terminates isolated lane process groups and restores the
terminal dashboard.

A downloaded remote archive is deleted only if its URL source's filename has one
of the extensions in `_DOWNLOAD_ARCHIVE_EXTS` — the same set the root
`.gitignore` denies, so a `-ccc` sweep and the ignore rules cannot disagree about
what a download is (`tests/cleanup-extensions.sh` fails if they do). Because the
match is on URL-backed sources, a *local* asset in a recipe directory is never a
target even when it carries one of those extensions. `--nuclear` reads its
confirmation from stdin and prints the same target list to a pipe as to a
terminal, so `printf 'n\n' | fish build-all.fish -ccc` lists what it would
delete and then aborts — answering `y` deletes it.

## Builder output contract

One run record per run — plan plus one outcome row per package — is rendered
three ways: the interactive dashboard (live), the prose summary, and the
machine block below. The machine block is default-on, printed to stdout after
the dashboard has finished (so its ANSI renderer cannot garble it), and on the
interrupt and sudo-preflight paths too:

```
--- run record begin ---
format: 1
selection-source: groups=… packages=… ranges=…
order: <the selection, topological>
lanes: …
normal-jobs: …
core-jobs: …
intensity: …
outcome: success|failed|interrupted
rc: <run exit code>
<pkg> <status> <rc> <dur> <reason>
--- run record end ---
```

Rows are full, never exceptions-only, one per package in topological order,
space-separated `pkg status rc dur reason` (the reason is the remainder of the
line). `rc` and `dur` are integers (`dur` in seconds) or `-` when the package
never produced one. The status enum, with its reasons:

- `succeeded` — `ok`.
- `failed` — `build-failed` (lane ran, rc is in the row), `lane-lost` (reap
  anomaly, rc 125), `log-unwritable` (dispatch refused: log not openable).
- `deferred` — rc **99**, reason `anchoring-refused`: checksum anchoring was
  impossible, the recipe is parked rather than failed, dispatch continues and
  its dependents wait. Not a failed build.
- `blocked` — `waits-on-deferred` (dependent of a parked recipe) or
  `never-ready` (dependency cycle / missing dep).
- `never-started` — `dispatch-stopped`, `preflight-refused`, or
  `interrupted-before-start`.
- `interrupted` — `interrupted-mid-build`: started and in flight when the run
  was interrupted.

An interrupted or partial run always ends with a continuation suggestion under
"To resume, run:" — a command rendered from the builder's single
continuation-flag table: the plan values (`--lanes`/`--jobs`/`--intensity`),
the install flavour (`-i` → `--install`, `-fi` → `--forceinstall`), the
semantics flags (`--no-deps`/`--no-sync`/`--allow-broken-rustc`), and the
remaining package list in place of the original selection (failed packages
included — they must rebuild before their dependents). `-c`/`--clean` and
`-s`/`--skip` are deliberately not mirrored (`-c` would wipe the archives a
resume needs; `-s` is the user's call — the printed tip says to add it), and
one-shot actions (`-n`, `-l`, `-ia`, `-cc`, `-ccc`, `-ln`, `--audit`,
`--help`) are never mirrored. Ambient environment inputs (`GSA_TARGET_CPU`,
`GSA_STATE_DIR`) are warned about, never baked into the command. The interrupt
path prints the summary, the machine block and this suggestion before exiting
130, so a Ctrl-C run leaves the same three artifacts as a completed one.

## Troubleshooting

Read the per-package log named in a failure message. A stale system pacman
lock is not removed automatically. Resume with the remaining package IDs
printed by the failure summary, usually adding `--skip --install` after
checking whether the archive was already produced. Under `--install`, a
package whose exact version is already installed with an install date not
older than its archive skips its transaction automatically; add
`--forceinstall` (implies `--install`) when the install must run anyway —
for example after repackaging a same-version payload.

Per-package logs live in `.state/logs/` — Git-ignored, and removed with the
state directory. If a run may need post-mortem forensics (a long build, a
machine that stalls), put them somewhere durable first:

```sh
GSA_STATE_DIR="$HOME/.local/state/gentoo-style-arch" fish build-all.fish -g core -i
```

### When the machine freezes during a build

A hard freeze leaves nothing in the per-package log, because the log is exactly
what stops being written. Two things are worth knowing:

**The journal is persistent, so the frozen boot is still readable after the
reset.** `/var/log/journal` keeps every boot; `journalctl -b -1` shows the boot
before the reset, and a boot whose last line is ordinary activity (rather than
`Journal stopped`) is a boot that did not shut down. That is how the texlive
freeze of 2026-09-18 was localised to a single second of one phase.

**Switch the magic SysRq keys back on before you need them.** This host shipped
with `kernel.sysrq=16` (only `sync` enabled), which disables every recovery key
and makes a hard power cut the only option — after 63 of those the drive's
unsafe-shutdown counter is the record of it. `sysctl -w kernel.sysrq=1` at
runtime costs nothing and gives you, at a physical keyboard:
`Alt+SysRq+R` (unraw the keyboard), `E` (SIGTERM everything), `I` (SIGKILL
everything), `S` (sync), `U` (remount read-only), `B` (reboot). If the screen is
dead but the box is alive, `Ctrl+Alt+F3` reaches a virtual console — and the
kernel messages on it settle whether the kernel or only the display died.

**Measure it instead of guessing.** The 2026-09-18 texlive freezes were chased
with a host-side sampler and then with a hardlink-farm reproduction; both are
gone now, because the freezes were not the workload — they were
[CVE-2026-90432](https://github.com/sched-ext/scx/issues/3687) in the kernel
recipe's sched_ext fork/exec path, fixed by the 2026-09-19 move to the CachyOS
RC channel (`docs/MEMORY.md`). What the measurement settled is worth keeping:
at full real scale (105,846 renames in 264 s) the split loop moved io PSI 0.00
with ≤2 processes in D state and ≤16 % device utilisation, so the loop was
never the cause.

### mkinitcpio and optional NvPCR definitions

The package set disables systemd's bootloader integration because this project
boots through Limine. That means systemd does not install optional
`/usr/lib/nvpcr/*.nvpcr` definitions, while stock `mkinitcpio` 42-1's systemd
hooks still try to add that glob literally. The project carries a patched
`mkinitcpio` recipe that skips absent optional definitions:

```sh
fish build-all.fish --no-deps --install mkinitcpio
sudo mkinitcpio -P
```

Do not re-enable systemd's bootloader feature just to satisfy this optional
initramfs input; the guarded hook is the intended compatibility boundary.

### PGO libraries recreating old build paths

Some recipes use a temporary profile-generation build for training. The final
package must not contain that instrumentation. If an older `glib2-git` or
`cairo-git` install recreates `src/build` after cleanup, replace the packages
before removing the residual tree:

```sh
fish build-all.fish --no-deps --install glib2-git
fish build-all.fish --no-deps --install cairo-git
readelf -sW /usr/lib/libglib-2.0.so.0 | grep -E '__gcov_|__llvm_profile'
strings -a /usr/lib/libglib-2.0.so.0 | grep -cE '/[^[:space:]]*\.gcda'
```

Both checks must produce no output and a count of `0`. **`readelf` alone is a
false negative**: makepkg strips before writing the archive, so the profile
runtime's symbol entries are gone while the absolute `.gcda` destinations
baked in at compile time survive in `.rodata`. Measured on the 2026-09-19
recurrence, `readelf -sW /usr/bin/Xwayland` reported clean (883 symbol
entries, no match) while `strings -a` found all 348 paths.

Restart applications that were running against the old libraries, then remove
only the now-inactive residual build trees. Do not treat GLib warnings from a
portal or sandboxed application as evidence of a builder process; correlate
them with the installed library symbols and profile-file paths first.

The same verification applies to `gtk3-git`, `gtk4-git`, and
`xorg-xwayland-git`. If a GUI application reports an undefined `__gcov_*`
symbol, replace the affected custom package with the fixed rebuild before
rebuilding dependents; repository packages are a temporary recovery path, not
the underlying fix.

#### The two verification seams

A payload check runs at one of two places, and the two cannot use the same
predicate:

| Seam | Where | Predicate |
| --- | --- | --- |
| Recipe | `package()`, against the staged `$pkgdir` tree, before makepkg strips | `readelf` **and** `strings` (shared gate `lib/pgo.sh`) |
| Builder | `install_pkgs_now()` / `install_all()`, against the finished `.pkg.tar.zst` | `strings` only |

A recipe-level check must be able to **fail the build**, and the shared gate is
built so it cannot do anything else. `verify_no_profile_instrumentation` lives
in **one module**, `lib/pgo.sh`, sourced by every PGO recipe through `source
"$startdir/../../../lib/pgo.sh"` and called as the LAST statement of
`package()` — of each `package_*` function in a split recipe, against that
function's own `$pkgdir`. On any hit it prints the offending binary and the
predicate that matched, then `exit 1`, which kills makepkg's function
subshell and fails the build. The `|| return 1` convention this replaces was
unenforceable: bash returns the status of a function's last command, so a
check whose status a later command overwrote was silently discarded and
makepkg packaged the instrumented payload anyway (four recipes were in
exactly that state until 2026-09-20). Recipes call the gate; they never copy
its implementation — the copied versions had drifted (mold-git's predicates
were stricter than the rest) and the copy-paste mandate was itself the
recurrence engine. A new PGO family earns a fixture and extends `lib/pgo.sh`
when its leak shapes are new (2026-09-28's C-autotools and Go flavors needed
no module change);
`tests/pgo-lib.sh` pins the module's behaviour and how each recipe resolves
it, and `tests/pgo-transition.sh` drives each recipe's profile *and*
below-threshold fallback branches.

Both are deliberate. The recipe seam sees unstripped files, which is the only
place `readelf -sW` is meaningful. The builder seam is the durable one: it
covers every recipe rather than the handful that remember to call a guard, and
it runs immediately before files are added to `/usr`, so the check is worth
its cost. `verify_pgo_payload()` in `build-all.fish` implements it and is
gated on the sibling `PKGBUILD` containing `-fprofile-generate`, so
non-PGO recipes are untouched.

The builder seam extracts and scans the **whole archive**, not a
`usr/bin`+`usr/lib` subtree. Subtree scoping embeds an assumption about where
a recipe installs files, and it is wrong for a leak under `usr/libexec` (the
fixture's `deep-bad` payload demonstrates the miss). Whole-archive scanning is
precise as well as complete: archive metadata (`.PKGINFO`, `.BUILDINFO`,
`.MTREE`), prose documentation quoting a `.gcda` path, and source comments
quoting one all pass, because the predicate matches a standalone
`file: /path/to/x.gcda` string rather than any mention of `.gcda`.
`.BUILDINFO` is not a trap in either direction — it records
`-fprofile-generate` in `buildenv` but contains no `.gcda` string at all.

The scan **fails closed**. `tar` with member names that match nothing exits
non-zero and extracts nothing, which would make the scan pass vacuously; the
check therefore treats a non-zero `tar` status or an empty extraction as a
hard failure rather than a clean result.

Replacing the packages is only half the fix — stale installs keep leaking
until they are rebuilt. `build-all.fish --audit` reports every installed file
owned by a PGO recipe that still carries a baked `.gcda` path, and names the
PGO recipes that are not installed at all, so a recurrence is visible without
re-deriving the sweep.

During a Meson PGO transition, the final reconfigure must replace both
compiler and linker argument caches (`c_args`, `cpp_args`, `c_link_args`, and
`cpp_link_args`). Profile-use flags also reach Meson's temporary compiler
probes, so `-Wno-error=missing-profile` is required for that reconfigure;
otherwise a missing profile for a probe can be misreported as an ABI or
feature-detection failure. Instrumentation validation is performed against
the staged package payload after `meson install`; temporary helpers under
`build/meson-private/` are not shipped and must not be treated as package
artifacts. This section is the operational reference for the PGO rules that
`CONTRIBUTING.md` states and that `MEMORY.md` §6 explains as failure modes.

A CMake-based PGO recipe has the same requirement with a sharper edge. CMake
reads `CFLAGS`, `CXXFLAGS` and `LDFLAGS` only while it *initialises*
`CMakeCache.txt`, so once the phase-1 configure has run, changing those
variables in the environment is ignored — including by a re-run of the
configure step. `make clean` does not remove the cache either. Phase 2 therefore
has to reach *into* the cache and rewrite the flag strings, then provoke a
regeneration — `cmake-git` does exactly this:

```sh
sed -i 's/-fprofile-generate/-fprofile-use …/g' CMakeCache.txt
if grep -q -- '-fprofile-generate' CMakeCache.txt; then   # a leftover silently
  error "phase 2 is still a phase-1 build"; return 1      # ships a phase-1 payload
fi
touch CMakeLists.txt    # what makes the generated Makefile re-check and regenerate
make clean
make
```

**Rewrite the cache; deleting it is the trap that looks like the local fix.** A
`CMakeCache.txt` is not "the flags" — it is every decision phase 1's
`./bootstrap` made: the install prefix from `--prefix=/usr`, `--mandir`/
`--docdir`/`--datadir`, the `CMAKE_USE_SYSTEM_*` dependency selection, and the
`-fuse-ld=mold` link flags. Measured on 2026-09-20 while this recipe deleted the
cache: the phase-2 configure printed `-- Using bundled: CURL EXPAT …` where
phase 1 had `-- Using system-installed: …`, and the payload was installed under
`pkg/usr/local/…` instead of `pkg/usr/…`. That also describes the cheaper route's
cost — the reconfigure reuses the cached feature answers and takes seconds, while
a fresh configure re-probes and takes ~100 s. Passing the flags with
`-DCMAKE_C_FLAGS=…` on a reconfigure is the same idea by a supported door.

`make clean` is still required: regenerated rules do not invalidate phase-1
objects, so without it `make` compares fresh objects against unchanged sources
and relinks the instrumented ones. Re-running `./bootstrap` is worse than either
route — the bootstrap is a *build of a compiler*, from the same sources phase 1
compiled, so a second bootstrap under `-fprofile-use` compiles its objects
against the phase-1 generate-mode profiles and make dies on
`-Werror=coverage-mismatch`; that is how this fix failed on 2026-09-20 before the
cache edit was tried.

A profile-*use* pass needs two tolerance flags, and they are load-bearing for
different reasons. `-Wno-missing-profile` is the guard on a fresh probe:
`-fprofile-use` warns on a probe that never ran, and CMake's
`Source/Checks/cm_cxx_features.cmake` reads *any* warning in a probe's output as
"feature unavailable", so a project that re-probes concludes this compiler has no
C++11 support and aborts the configure. Keeping the cache is what keeps that from
happening at all, so read this flag as the backstop for any recipe that does
re-probe. `-Wno-error=coverage-mismatch` cannot be avoided: `-fprofile-use`
enables passes the generate phase never ran, so a few functions come back with a
different arc count, which GCC treats as an error by default; downgraded, those
functions compile without profile data while the rest keep it.
