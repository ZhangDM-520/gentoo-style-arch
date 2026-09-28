# NOTE — Gentoo_Style_Arch maintainer incident journal

Historical journal for the self-built `-git` Arch package set. The current
project stores one clean recipe per package and keeps runtime `src/`, `pkg/`,
logs, caches, and source mirrors outside the publishable interface.
Chronological incident log below (symptom -> root cause -> fix -> rule);
current consolidated state lives in `MEMORY.md`.

Older entries retain historical directory names where they explain an
incident. They are not active configuration. Do not add private paths,
credentials, downloaded sources, or generated build output to this journal.

### Naming history (read this before interpreting old entries)

The workspace was reorganized twice; entries keep whatever names were true when
they were written. Current names are `packages/<category>/<package-id>/` with
categories `git`, `stable`, `core`, `misc` (the `third-party` category was
retired 2026-09-27), and logical groups `git`, `stable`, `core`, `misc`, `app`
(stated in `config/topology.conf`).

| In older entries | Was | Now |
| --- | --- | --- |
| `.Heavy/`, `.Heavyweight/` | the heavyweight build area | `packages/core/` (or `packages/git/` for rolling recipes) |
| `.Static/`, `.Stable/` | stock-name packages whose versions track the repos | `packages/stable/` (or `packages/git/`) |
| `.Core/` | `.Heavyweight/` renamed 2026-09-15 | `packages/core/` |
| `.3rdP/` | third-party application recipes | `packages/stable/` — directory retired 2026-09-27 (group `third-party` retired with it; the recipes are `app` members) |
| `.Misc/` | auxiliary recipes | `packages/misc/` |
| `-g static`, `-g heavy`, `-g critical`, `-g rocm` | four separate groups | `-g stable` and `-g core` (2026-09-15); `core` auto-enables `-i` |
| `-si`, `--sepinstall` | the separated-install flag | removed 2026-09-17 — `-i`/`--install` is the only spelling |
| `--installall` at end of run | the old collective install | `-ia` remains as a one-transaction escape hatch; a normal run installs per package with `-i` |
| `tests/*-pgo-transition.sh` (five 6-line wrappers) | one wrapper per PGO recipe | folded into `tests/pgo-transition.sh` (no args = all five pairs) on 2026-09-24 |
| `tests/kernel-config-verify.sh`, `kernel-recipe-sums.sh`, `kernel-recipe-version.sh` | three kernel fixtures | one `tests/kernel-recipes.sh` with three sections (2026-09-24) |
| `tests/log-ownership-root.sh`, `noctalia-pgo-train.sh`, `zen-pgo-workload.sh` + `zen-pgo-speedometer.sh`, `vencord-recipe.sh` + `vencord-inject.sh`, `project-config.sh` + `project-cli-hints.sh` | one file per sub-area | sections of `tests/log-ownership.sh`, `noctalia-pgo.sh`, `zen-pgo.sh`, `vencord.sh`, `project.sh` (2026-09-24) |

So `.Static/qt6-base` and `packages/stable/qt6-base` are the same recipe family,
and `.Heavy/llvm-git` is today's `packages/core/llvm-git`. Package IDs,
dependency edges, and incident root causes are unaffected by the renames.

## 2026-09-28 — real build of the utility batch: bare-repo VCS, keyring imports, the curl split conflict, and the sync pkgrel downgrade

Symptom — the first real `--no-deps -i` pass over the 17 new stable recipes
hit four failure classes in sequence: (1) `fatal: cannot use bare repository …
(safe.bareRepository is 'explicit')` on every git-source recipe (libnotify,
desktop-file-utils, xdg-user-dirs, fd, fzf); (2) `unknown public key` for IDs
makepkg could not find although every `validpgpkeys` entry was present
(libnotify's `40F65066…`, playerctl's `564F0717…`); (3) `pacman -U` of the curl
three-way split in ONE transaction refused 10 file conflicts —
`/usr/lib/libcurl.so.4 exists in both 'curl' and 'libcurl-gnutls'`, plus
`libcurl.so.3`/`4.x.y` in both `libcurl-compat` and `libcurl-gnutls` — and the
builder correctly stopped dispatch ("later packages would build against the
wrong system state"); (4) quietly, the loader sync rewrote ripgrep's deliberate
PGO `pkgrel=2` down to the repo's `1` before it built, so the three-phase PGO
build came out stamped `15.2.0-1`.

Root cause — (1) the agent-shell git hardening breaks makepkg VCS operations
(documented remedy `GIT_CONFIG_COUNT=0`); (2) `validpgpkeys` lists *acceptable*
keys, it does not import them — the error IDs were subkeys of primaries the
build user's keyring lacked; (3) `package_libcurl-gnutls()` in our curl recipe
created an extra `libcurl.so.{3,4,4.0.0…4.7.0}` symlink set Arch does not: the
two split functions were otherwise byte-identical to Arch's, and Arch's gnutls
split ships only `libcurl-gnutls.so.*` (compared against the official
gitlab PKGBUILD). The extra set collides with `curl`'s real `libcurl.so.4` and
with `libcurl-compat`'s compat symlinks; (4) `sync_stable_version`'s
never-downgrade guard covered `pkgver` only — at equal `pkgver` it rewrote
`pkgrel` in both directions (the 2026-09-26 "rewrite EXACTLY" contract), which
cannot carry a PGO wave's standing revision mark.

Fix — (2) imported all 12 `validpgpkeys` fingerprints from
keyserver.ubuntu.com (5 new, 7 already present; importing a primary brings the
subkeys the errors named); (3) deleted the one extra `ln -s` line and
repackaged with `makepkg -Rf` — only packaging had changed and the three
`src/build-curl*` trees were intact, so no rebuild and no retrain — then
verified the three archives' `.so` partitions pairwise with `comm`: zero
overlap, `curl` owns `libcurl.so{,.4,.4.8.0}` and the splits only their own
symlink sets; (4) the sync now compares `pkgrel` with `vercmp` at equal
`pkgver` and adopts only a repo value actually ahead; ripgrep's `pkgrel=2`
restored and rebuilt (`15.2.0-2` installed). `tests/stable-sync-checksums.sh`
gained case 12 (local pkgrel ahead kept) plus a forward assertion on its
pkgrel-only variant (repo ahead still adopted).

Validation — `bash tests/stable-sync-checksums.sh` green (case 12 fails
against the old guard, so it is not vacuous); full battery green (42/42,
`recipe-sources` included); `fish
build-all.fish --audit` (no lint findings, no baked PGO payloads across 14 669
inspected files), `--list` and the git/stable/core dry-runs green;
resume run `curl fzf ripgrep` ok (curl skip-installed from the repackaged
archives, fzf forward-synced to `0.74.4-1.1`); `pacman -Qi` sweep shows all 19
package names (17 recipes; curl splits in three) installed and `pacman -Ql` of
the three curl packages matches the designed partition.

Durable rule — a split package ships its own soname set and never re-exports
the base library's names; verify file partitions with `tar -tf` + `comm`
before any multi-archive `-i` transaction. When only `package*()` changes,
`makepkg -Rf` repackages from existing build trees. `validpgpkeys` is
necessary but not sufficient: the fingerprints must be in the build user's
keyring, and primaries bring the subkeys the errors name. The stable sync
never downgrades `pkgrel` at `pkgver` parity — the 09-26 "both directions"
contract is superseded (MEMORY updated). An `-i` conflict stops the dispatch
on purpose; fix, then resume the remainder with `-s`.

## 2026-09-28 — utility batch (17 leaf recipes) and the C-autotools / Go / ripgrep PGO tiers

Symptom — the 2026-09-27 `trash-put` hang showed the set ships no trash-cli
while Arch extra pins the affected 0.24.5.26, and beyond it the desktop/dev
utility layer (clipboard, notification, mime, brightness, jq/curl/file/rsync,
ripgrep/fd/fzf) had no recipes at all; PGO coverage stopped at the
meson/CMake/Rust families. Root cause (trash-cli hang) — upstream 0.24.x
retries forever on hard errno values; fixed by `e62b15d085` (HARD_ERRNOS),
present in 0.26.9.14, absent from Arch extra's 0.24.5.26.

Fix — 17 release-tracked recipes under `packages/stable/`, every record
`id|packages/stable/<id>|stable|` (empty edges, no tags — true leaves, no
incoming edges either): trash-cli 0.26.9.14 (pure Python; unsigned
lightweight tag → checksum-pin, no `validpgpkeys`; pytest `check()` with the
upstream `mock`→`unittest.mock` sed; shtab completions for all six commands
including `trash-rm`, which Arch omits); desktop glue (xdg-utils 1.2.1 — pure
shell, `options=(!lto !strip !debug)` as a non-codegen signal — libnotify
0.8.8, wl-clipboard 2.3.0, shared-mime-info 2.5.1 + `30-update-mime-database.hook`
(FS#72858), desktop-file-utils 0.28 + hook, xdg-user-dirs 0.20, playerctl
2.4.1, brightnessctl 0.5.1, ffmpegthumbnailer 2.3.1); dev glue (jq 1.8.2,
curl 8.22.0 as the three-way `pkgbase` split curl/libcurl-compat/libcurl-gnutls,
file 5.48, rsync 3.5.1); Rust/Go CLIs (ripgrep 15.2.0, fd 10.5.0, fzf 0.74.4).

PGO wave 2 — three tiers, each with a plain-build fallback and
`verify_no_profile_instrumentation` as the LAST `package()` statement:
ripgrep joins the Rust family (mold-git/niri-spicy-git pattern, `-Cprofile-generate`
+ LTO off → training → `llvm-profdata merge` → `-Cprofile-use` + fat LTO +
CGU=1 + strip; upstream benchsuite corpora are multi-GB external, so training
is the tree-based fallback — 11 runs, 22 `.profraw`; floor `pgo_min_profraw=0`,
fat-LTO plain fallback). jq/file/rsync open the C-autotools family: every
phase re-runs `./configure`, phase 1 strips `-flto*` and uses symmetric
`-fprofile-generate=<dir>`, training is `make check` plus filter/sweep/tree-copy
loops (gcda 23/25/119; floors `pgo_min_gcda` 15/15/20), phase 2 restores LTO +
`-fprofile-use=<dir> -Wno-error=missing-profile -Wno-error=coverage-mismatch`;
rsync keeps Fedora's rhbz#1898912 LTO history as the escape-hatch comment, and
LTO+PGO builds fine on GCC 17. fzf is the first Go flavor: upstream bench
suite + `fzf --profile-cpu` filter runs over a 200k-line list, merged via
`go tool pprof -proto` into `$srcdir/cpu.pprof`, wired as
`GOFLAGS+=-pgo=$srcdir/cpu.pprof`; floor `pgo_min_samples=500` (from
`go tool pprof -top` "Total samples") with `-pgo=off` fallback — 3528 samples
achieved. The recipe states the honest caveat: the profile over-represents
micro-benchmarks versus interactive TUI use; it represents the batch-matching
hot path.

Signatures — the subkey rule worked as documented: rsync's signature is by Zen
Dodd's signing subkey resolving to primary `C0E10545` (= Arch's
`validpgpkeys`), and fd's commit is web-flow-signed. `file` 5.48's Zoulas key
**expired 2026-08-15** — the signature predates the expiry, so makepkg warns
EXPKEYSIG and still verifies; a future bump may need a refreshed key.
libnotify/playerctl/fzf carry `#signed`; fzf's Junegunn Choi fingerprints had
to enter the host keyring first (machine prerequisite for rebuilds).

Host — one cumulative `IgnorePkg =` line (19 names) added inside `[options]` of
`/etc/pacman.conf` (backup `/etc/pacman.conf.20260928-utilities.bak`).
Known skew — trash-cli's 3 `test_help` assertions fail against shtab ≥ 1.6
(help text lists more shells than upstream hardcodes): upstream brittleness,
suite left full and documented in the recipe; the host's `BUILDENV=(!check)`
makes makepkg skip `check()` here.

Validation — `fish build-all.fish --list`: 145 recipes (git 42, stable 44,
core 39, misc 1, app 22 — 148 memberships, the three `stable,core` records
counted twice). `tests/pgo-transition.sh` gained a 4th `style` column
(meson/autotools) and passes 8/8; new fixtures `tests/ripgrep-pgo.sh` and
`tests/fzf-pgo.sh` pass. Fixture battery 41/42: only `recipe-sources.sh`
fails, with 6 `untracked local source`/`untracked install script` rows for the
batch's new patch/hook/conf/install files — the batch is not yet committed and
the fixture's criterion is `git ls-files`, so `git add`/commit clears it.
`lib/pgo.sh` deliberately unchanged —
the C-autotools family shares its `.gcda` predicate and Go leaks none of the
literals it covers (the gate trivially passes there).

Durable rule — `-fprofile-generate=<dir>` and `-fprofile-use=<dir>` must name
the SAME directory on BOTH sides: a bare `-fprofile-generate` plus
`-fprofile-use=<dir>` silently misses every profile (GCC probe — the counters
land where the use phase does not look). A PGO floor decides
profile-used-versus-plain-fallback, so changing one is a behavioural change
(MEMORY §4). A new PGO family earns a fixture and touches `lib/pgo.sh` only
when its leak shapes are new. An expired maintainer key whose signature
predates the expiry is a warning, not a failure: keep `#signed`/`validpgpkeys`,
never `--skippgpcheck`, and record the expiry plus the re-key contingency.

## 2026-09-27 — `app` group wired (22 members), `third-party` retired, `app-cluster` prompt rows

Symptom — the `app` group sat at 0 members while some 20 desktop
applications lived in `git`/`stable`/`core`/`third-party`, so `-g app` could
not select
them; the fcitx5 stack also presented as six separate prompt rows that had to
be toggled one by one, and `third-party` was a two-recipe group duplicating
what `stable` already means. Root cause — `app` had been created as a prompt
layer (2026-09-23) without ever being wired, and no tag expressed prompt-row
clustering. Fix — 22 records now carry `app` as their **sole** group
(membership replaces the previous group): zen-browser-pgo, bettbox, qt5ct,
qt6ct, libreoffice-fresh, networkmanager-openvpn, blender-git,
easyeffects-git, the five fcitx5 recipes (fcitx5-git, fcitx5-gtk-git,
fcitx5-lua-git, fcitx5-qt-git, fcitx5-chinese-addons-git), gimp-git,
krita-git, libime-git,
logseq-desktop-git, noctalia-git, onlyoffice-git, vscodium-insiders-git,
vencord-git, niri-spicy-git. Deliberately not wired: autofdo-git (core
toolchain), bpftune-git (daemon), flatpak-git (framework), texlive-texmf
(24-output data), xcb-imdkit-git (build dep). The `third-party` group was
retired — description arm, accumulator and `packages/third-party/` gone;
`zen-browser-pgo` and `bettbox` relocated to `packages/stable/` as pure
renames (PKGBUILDs unchanged) — and `-g third-party` with the historical
`third_party`/`3rdp` aliases now fails the unknown-group path. The audit's
legacy `.3rdP/` path-drift regex is intentionally kept: it scans for pre-Git
filesystem paths, not group names. New topology tag `app-cluster=<name>`
(fifth field, comma-joined with `abi=` tags, charset `[A-Za-z0-9._+-]+`, at
most one per record, accepted on any record but inert outside the app
prompt) collapses prompt rows: the six fcitx-family records
(fcitx5-git/-gtk-git/-lua-git/-qt-git/-chinese-addons-git, libime-git) share
`app-cluster=fcitx5` and the multi-select shows them as one
`fcitx5 [member ids]` row whose toggle checks or clears all members; they
remain six separate packages in `-l`, the run record, ranges and lanes, and
"N checked" counts rows, not packages. Prompt semantics are otherwise
unchanged: filter layer in front of the pipeline, TTY-only, all-unchecked +
Enter = whole group, `q`/EOF abort non-zero, `-l` never prompts, non-TTY
takes the whole group, and group selections never `expand_deps`.

Consequence — `qt5ct`/`qt6ct` thereby left `core` while keeping their
`abi=must` tags, so `-g core`'s solo dispatch no longer rebuilds them and a
Qt ABI batch must name them explicitly. A cluster is presentation data only;
never build grouping logic on it.

Validation — group counts read from the `groups` fields of
`config/topology.conf` and confirmed with `fish build-all.fish --list -g
<group>`: git 42, stable 27, core 39 (34 under `packages/core/`,
`autofdo-git`/`libclc-git` under `packages/git/`, `hip-runtime`/`hsa-rocr`/
`openssl` the three `stable,core` members under `packages/stable/`), misc 1,
app 22 — 128 records, 131 memberships. Prompt clustering exercised by the
app fixtures (updated in the concurrent `tests/` change).

Durable rule — `app` membership is exclusive (a record carries `app` alone)
but never clears coupled-batch tags; the roster is five names and nothing
outside it resolves; an `app-cluster` tag affects prompt presentation only.

### Host incident the same day: fish `rm` wrapper hang

Fixture and builder runs on the maintainer host hung at ~100 % CPU before
doing any work; pristine HEAD hung identically, so it was not a repo bug.
Root cause — the user-level fish config autoloaded a trash-cli-backed `rm`
wrapper that spun on any invocation, and both the builder and the fixtures
call `rm` early. Workaround for reproducers: run under
`XDG_CONFIG_HOME=$(mktemp -d)` so fish falls back to the system `rm`. Rule:
when a run hangs with no output, suspect the shell environment first and
re-test at HEAD before debugging the repo; keep host specifics out of these
docs.

## 2026-09-26 — audit lints: provides versioning, purged tools, IgnorePkg (architecture-deepening wave-4)

Symptom — three rules lived only in prose and rotted: the IgnorePkg closure
once lost 62 names unnoticed, purged tools crept back through makedepends
(makepkg reinstalls them silently), and an unversioned toolchain provide
silently failed a `>=N` makedepend by letting pacman fall back to the repo
package. Fix (`af84810`) — C9's three-tier mapping: deterministic form rules
become `--audit` lints (provides versioning with a 15-entry ratchet for the
known hand-versioned soname provides; exact-name purged-tools denylist over
makedepends/checkdepends), host-state rules become a report-only IgnorePkg
closure gate that reads /etc/pacman.conf directly with [options]-scoped
cumulative semantics and skips only when unreadable, and the heavy ELF rule
becomes `tools/provides-audit.sh` paired with its reduced-scale fixture.
Per-recipe exceptions are data now: `packages/stable/bash/FETCHED-ONLY`
(source-basename globs) excuses fetched-at-build-time names from both the
missing and untracked checks in `tests/recipe-sources.sh`, replacing a
name-matched branch in the repo-wide walker. run-all's filter guard exits 2
on a typo instead of passing an empty battery.

Validation — `fish -n`/`bash -n`; `--audit` rc 0 with three new report-only
sections (15 ratchet findings printed by design; purged + IgnorePkg clean on
this host, 224 names covered); seam probes (clean on the real conf, Q17 skip
on an unreadable one); battery PASS (40 fixture(s)).

Durable rule — per-recipe exceptions are data (FETCHED-ONLY markers), never
name-matched branches in repo-wide fixtures, and the marker excuses both the
missing and untracked checks.

## 2026-09-26 — topology: one record per package (architecture-deepening wave-3)

Symptom — declaring "this package is in core and builds after llvm" took
three records in three files in three syntaxes (`packages.map`,
`groups/core.list`, `dependencies.conf`), adding a recipe was a
four-touchpoint dance, and coupled-batch membership lived in prose that
drifted from the code (the mold-git `rust-git`-edge incident was exactly a
package's prose outliving its record). Root cause: the topology was split by
data shape, not by concern.

Fix (`db09690`) — `config/topology.conf` carries one record per package,
`id|path|groups|edges[|tags]`: the id→path binding stays explicit, group
membership is a comma list against a roster stated once (`_GROUP_NAMES`), a
trailing empty `edges` field is the deliberate no-edge statement (records
always exist — the old map⊆deps asymmetry where four packages had no dep
record is gone), and `abi=must`/`abi=should` tags carry coupled-batch
membership as data (25 must: llvm/rust + the qt6/qt5 module sets; 21 should:
mesa, spirv, libclc, OSL, mold-git and other consumers). The duplicate-id
path that used to fail with a bare `return 1` now names the offender and
line. A GENERIC batch gate replaces the hard-coded llvm/rust literals: the
anchor is a selected `abi=must` package with no abi-tagged transitive dep;
on a real build (`-n`/`-l` exempt) an installed `abi=must` member omitted
from the selection refuses before dispatch with per-member recovery lines,
`abi=should` members get one same-pass note, and leaf rebuilds of members
(`--no-deps rust-git`, `qt6-svg`, …) stay legal. The `--topology` data
channel is now the only way tooling reads topology — `tests/srcinfo-freshness.sh`
dropped its own awk parser and the per-recipe registration greps consume the
channel. Fixture synthesis writes records (`make_workspace`/`add_package`,
plus the `set_topology_record` writer); `config-diagnostics.sh` re-pins its
rejection cases against the new grammar including the new duplicate-id case.

Validation — `fish -n`; `--audit`/`--list` (128/128); dry-runs
git(58)/stable(29)/core(41) rc 0; full battery
`fish_function_path=/nonexistent-fp bash tests/run-all.sh` → PASS (38
fixture(s)); reference resolution (path, case-variant, pkgname) smoke-checked
unchanged.

Durable rules — one record per package; the record is the ONLY id→path
binding (never infer topology from directory names); batch membership is
data, never prose; tooling reads `--topology`, never `config/` directly.

## 2026-09-26 (architecture-deepening wave-2) — install plan/executor split, lane outcome vocabulary, run-record fixtures

Feature record, wave 2 of the same refactor (two commits):
`751b514` (C4+C5, builder) and `e73a350` (C3+C8, tests). Symptom it
removes — the install decision was made in five places across
quiet/loud × checked/force output quadrants (four fixes in six days kept
re-deciding it), lane exit codes crossed the process boundary as bare
numbers with no named meaning (the `unknown` result-pkg row was one
symptom), and the wave-1 run record had no fixture pinning it while
seven fixtures still scraped prose.

Root cause: decide/execute conflated in one code path, and an unnamed
protocol used as an interface. Fix: `install_plan` computes silent plan
rows (`install`/`skip`/`refuse`/`noop`) once and only `install_execute`
renders and transacts (`-ia` shares the pipeline in force mode — no
same-version skip; `_INSTALL_FORCE` deleted, mode/sink ride as
arguments); `verify_pgo_payload` became the silent-plan step
`pgo_payload_refusals`; `check_pacman_db_health` consolidated behind
`install_preflight` (wire count 4→3, fixture count edited in the same
change set); all privilege escalation unified to `sudo -n` with the
interactive prompter deleted — under Q10 a cold credential fails fast
(`sudo cannot install non-interactively` at preflight,
`sudo credential expired and cannot be refreshed` mid-run) and a TTY
changes nothing. The lane protocol got a named vocabulary
(`lane_outcome_{ok,failed,defer,lost,hup,int,term}` +
`lane_outcome_name`) and one codec pair
(`lane_result_encode`/`decode`, `lane_argv`/`lane_argv_check`); the
signal handler now writes nothing when the pkg identity is unknown
instead of an unattributable row. Tests: new `tests/run-record.sh` pins
the machine block end to end (markers, plan scalars, row grammar,
status enum as data — deferred = rc 99, the interrupt continuation),
seven fixtures migrated from prose-scraping to `rr_*` row assertions,
`tests/dashboard.sh` became the ONE prose-rendering section, and
sudo-keepalive scenario 4 was inverted to the Q10 policy (cold
credential + PTY → refuse, zero `sudo -v` attempts).

Validation: `fish -n build-all.fish`; the three builder fixtures PASS
(new: `--install-decide` cases I1–I7, three-call-site count, empty-pkg
lane → rc 125 + loud write failure); all ten test-stream files `bash -n`
clean; full battery `fish_function_path=/nonexistent-fp bash
tests/run-all.sh` → PASS (38 fixture(s)) on the merged tree.

Durable rules: install decisions are computed once as rows and only the
executor renders; lane rc values come only from `lane_outcome_*` and
cross the boundary only through the codec pair; the machine block is the
assertion surface (the `rr_*` parser is the interface under test) and
prose wording is pinned in exactly one rendering adapter; the builder
NEVER prompts for a password — sudo-keepalive scenario 4 is the tripwire
for that policy.

## 2026-09-26 (architecture-deepening wave-1) — run record, shared PGO gate, one fixture helper, and the ADR set

Feature record rather than an incident: the first wave of the
architecture-deepening refactor landed as five commits. Symptom it removes —
three seams each carried two or more parallel truths: outcome/continuation
knowledge was re-derived in the dispatcher, the `_RL_*` globals and the
summary; seven per-recipe copies of the instrumentation check had drifted;
17 fixture scripts each hand-rolled their own workspace/stub synthesis.
Root cause — no single owner for any of the three facts, so copies drifted by
construction (and the copy-paste mandate was the recurrence engine of the
instrumented-archive incidents of 2026-09-16/2026-09-19 — four guard call
sites were decorative and silently packaged instrumented payloads until
2026-09-20). Fix — settle the design first, then replace each duplicated
truth with one owner, one commit per phase.

### The design settled (three ADRs, `docs/adr/`)

- `0001-pgo-shared-gate.md` — one shared PGO payload gate (`lib/pgo.sh`) with
  fatal semantics, per-recipe *calls* kept (the symbol predicate is only
  reachable pre-strip), both verification seams stay.
- `0002-topology-one-record.md` — collapse the four topology syntaxes into
  one per-package record (`id|path|groups|edges`, coupled batches as tags),
  with the rejected options recorded so they stop being rediscovered.
- `0003-run-record.md` — one builder-internal run record rendered three ways
  (dashboard, prose, default-on machine block), continuation arguments from
  one flag-rule table, ambient env knobs warned about rather than mirrored.

### Wave-1 phases (five commits, one line each)

1. `0490b00` docs — CONTEXT.md glossary + `docs/adr/0001..0003`: the
   vocabulary and the three decisions, with the options each one rejected.
2. `b470843` builder — `run_record_row/field/plan/finalize` + the
   `print_run_record` machine block + one `continuation_args` mirror behind
   `_CONTINUATION_RULES`, and the interrupt path now prints summary + record +
   continuation then exits 130: one record replaces the parallel truths, and
   the 2026-09-26 failed-package drop from a resume suggestion cannot recur
   because both mirrors render from the same table.
3. `820e645` tests — `tests/lib/fixture-lib.bash` (the one synthesis helper)
   with 17 synthesizers migrated onto it, the `GSA_FAKE_*` stub-knob family
   renamed in one pass (12 names), `run-all.sh` excludes `./lib/*`, and
   `project.sh` pins its self-scan with `expected_invocations=20`: the
   hand-rolled copies had drifted slightly in 17 places.
4. `975c126` recipes — `lib/pgo.sh` shared fatal gate and the 7 consumers
   converted (`|| return 1` lint deleted as unenforceable),
   `tests/pgo-lib.sh` pins the module, `tests/pgo-transition.sh` gained the
   below-threshold fallback branch, and cmake-git dropped `--sphinx-man`/
   python-sphinx so a purged host package cannot re-enter via makedepends.
5. `9c9ec80` tests — `tests/pgo-lib.sh` hard-fails on a shared module that is
   visible to git but untracked: the commit-pending tolerance would have left
   every clean checkout broken.

### Validation record

Merged wave-1 tree: `fish_function_path=/nonexistent-fp bash tests/run-all.sh`
→ **PASS (37 fixtures)** (the prefix keeps user fish wrapper functions from
intercepting the fixtures' PATH stubs); the PGO fixture families are green —
`tests/pgo-lib.sh` across the 7 consumers and `tests/pgo-transition.sh` across
its five pairs including the new fallback branches; negative test for the
untracked-module rule: `git rm --cached lib/pgo.sh` in a scratch export makes
`tests/pgo-lib.sh` exit non-zero with "lib/pgo.sh is not tracked", as
intended. `fish -n build-all.fish` clean; the run-record change needed zero
fixture edits.

### Durable rules

- **Fatal gate over `|| return 1`**: a check inside a bash function whose
  failure must stop the build is one shared `exit 1` gate called LAST — bash
  returns the last command's status, so a mid-body `|| return 1` call is
  silently discarded (the four decorative guards). Recipes call the shared
  gate; they never copy its implementation.
- **One synthesis helper**: fixtures build their workspaces and trivial stubs
  through `tests/lib/fixture-lib.bash`; a second synthesizer copy is drift by
  construction (17 copies already had). Oracle-shaped stubs stay inline in the
  fixture that gives them meaning.
- **The run record is the single reporting seam**: dashboard, prose summary
  and machine block are three renderings of one record — never a second
  account of the run — and every continuation command renders from the one
  flag-rule table.

## 2026-09-26 (full-rebuild campaign) — 6 root-caused fixes, batch close-out, and the version-refresh port

Campaign close-out for the full workspace rebuild across all groups, run in
the `~/Workspace/gentoo-style-arch` scratch clone (build workspace; canonical
edits landed in this repository). The individual incidents have their own
entries below (2026-09-25 "toolchain drift recipes" and "abi batch policy";
2026-09-26 "qt6 spec-type unpin") — this entry carries the campaign shape,
the per-fix index with commit hashes, the ops findings no incident entry
covers, and the close-out numbers. Session totals: **9 commits pushed, 6 real
bugs root-caused and fixed**. (`588055e`, the vulkan pair, is the lead-in fix
of the same session and is journaled at 2026-09-25 (vulkan pair) — not
repeated here.)

### Campaign shape and batch close-out

Final batch of 17 packages finished **17/17 green at 11:39**: qt5-base-git
6m59s, blender-git 53m47s, krita-git 52m14s, onlyoffice-git 122m53s, the
rest of the Qt5/Qt6 modules ≤5m each. Close-out also carried the
version-refresh port: 17 version-line-only PKGBUILD refreshes plus the 2
stable pkgrel alignments below, each with a regenerated `.SRCINFO`.

### The six root-caused fixes (one commit each in this repository's log)

1. **`677d93c` "Fix llvm/rust ABI skew: toolchain edges, batch policy, probe
   re-run"** — Symptom: `rustc: symbol lookup error … librustc_driver-…so:
   undefined symbol … version LLVM_24.0` (exit 127). Root cause: the llvm-git
   snapshot bump (LLVM 24, 20:50 on 2026-09-25) has no stable C++ ABI and the
   installed rustc driver was linked against the old LLVM — rust, mesa, spirv
   and libclc consumers must move as one batch. Fix: toolchain dependency
   edges in `config/dependencies.conf`, batch policy, probe re-run. Incident
   detail: 2026-09-25 (abi batch policy).
2. **`a019000` "fish: fix install(SCRIPT CODE) rejection by cmake-git 4.4
   snapshots" + `e7e6011` "blender-git: drop invalid DEPENDS from
   install(CODE) for cmake-git 4.4"** (one bug, two recipes) — Symptom: the
   cmake-git 4.4 snapshot rejected fish's `install(SCRIPT … CODE …)` form and
   blender-git's `DEPENDS` on `install(CODE …)`. Root cause: cmake 4.4
   tightened `install()` argument parsing and both forms were deprecated
   looseness. Fix: fish migrated to canonical `install(CODE …)`, blender
   dropped the invalid `DEPENDS`. Both verified past the error at configure
   and `cmake --install`; blender's was a full 53m47s build. Detail:
   2026-09-25 (toolchain drift recipes).
3. **`0721777` "xwayland-satellite-git: rebase round-half-up patch onto
   63cdf17"** — Symptom: the local patch no longer applied. Root cause:
   upstream main moved to 63cdf17 and rewrote the patched height code. Fix:
   patch rebased onto 63cdf17, still needed (issue #479 open). Detail:
   2026-09-25 (toolchain drift recipes).
4. **`0824f97` "openshadinglanguage: guard removed llvm 24 TargetOptions
   fields"** — Symptom: `llvm_util.cpp` compile errors on
   `llvm::FPOpFusion`/`HonorSignDependentRoundingFPMathOption`. Root cause:
   the llvm 24 snapshot removed those TargetOptions fields and upstream OSL
   has not caught up. Fix: version guards in the recipe's existing
   `osl-llvm-compat.patch`. Detail: 2026-09-25 (toolchain drift recipes).
5. **`5fd636f` "autofdo-git: work around gcc PR 127395 constexpr brace-init
   ICE"** — Symptom: compile dies in bundled abseil under the GCC 17
   snapshot. Root cause: upstream GCC ICE (PR 127395, constexpr
   brace-init). Fix: worked around in the recipe. Detail: 2026-09-25
   (toolchain drift recipes).
6. **`089b897` "qt6-languageserver: unpin LSP-3.18 spec types; drop
   qt6-declarative shim"** — Symptom: qmlls compile failures from
   qtlanguageserver↔qtdeclarative LSP-3.18 spec type skew. Root cause: the
   deliberate qtlanguageserver pin hit its documented exit condition once
   qtdeclarative adapted. Fix: unpin plus deletion of the now-stale
   qt6-declarative skew shim. Detail: 2026-09-26 (qt6 spec-type unpin).

### Transient and ops findings

- **4 transient network fetch flakes** (TLS `unexpected eof`):
  documentfoundation, documentfoundation-mirror (which also served 404s),
  code.qt.io, invent.kde.org. The retry idiom works every time, and `git
  clone` self-cleans its partial directory on a failed clone (verified) —
  these are transient, never a recipe fault.
- **1 stale pacman-db incident**: `plasma-wayland-protocols` 404'd on all
  mirrors — a repo package missing everywhere means the local pacman db is
  stale, not that upstream deleted it; `sudo pacman -Sy` fixed it.
- **Builder UX trap (near-miss, confirmed twice — cycle-1 libreoffice and
  cycle-10 qt5-base-git)**: the failure summary's "To resume, run:"
  suggestion AND its "Remaining" count EXCLUDE the failed package itself.
  Copying the suggested command verbatim therefore leaves the failed package
  stale while its dependents build against stale installed copies. Fixed in
  this campaign (builder workstream, commits separately): the resume list
  now includes the failed package, and `tests/resume-command.sh` pins it
  against regression.
- **Stable-version sync semantics (verified)**: the builder rewrites stable
  recipes' `pkgver`/`pkgrel` to match the official repo EXACTLY on every
  load, and in BOTH directions — `openshadinglanguage` was rewritten
  1.2→1.1 (down) to match the repo's 1.15.3.0-1.1, `wireplumber`
  0.5.17-1.1→2.1. A local `pkgrel` bump on a stable recipe is therefore
  clobbered on the next load. Decision taken: align committed values to the
  repo (OSL `pkgrel=1.1`, wireplumber `0.5.17-2.1`) rather than fight the
  sync; a deliberate local bump needs `--no-sync` and should expect the
  mismatch to be visible.
- **Freshness-audit semantics**: a raw PKGBUILD-vs-archive mtime comparison
  over-reports staleness — a bulk content-identical rewrite touched 36
  PKGBUILDs at 06:25, and version-line bookkeeping commits post-date their
  builds. The content-aware audit (last commit touching the PKGBUILD vs the
  newest archive's build time, plus pkgver-vs-archive-name comparison)
  showed **0 genuinely stale recipes**: every "stale" recipe's newest archive
  name matched its current pkgver exactly. `linux-cachyos` is the single
  documented exclusion (its rebuild was deliberately dropped by the user at
  06:31; the running 7.3.rc4 kernel stays).

### Validation record

Final batch 17/17 green (timings above); freshness audit 0 stale
(content-aware); the version-refresh port (17 version-line-only PKGBUILD
refreshes + 2 stable pkgrel alignments) landed with `.SRCINFO`
regenerations; `--audit`/`--list`/dry-run sweep and the full fixture battery
green.

### Durable rules

- **Rule**: a failure summary's resume suggestion and remaining count must
  include the failed package itself — dependents compile against *installed*
  copies, so a resume that omits it builds on stale foundations.
  `tests/resume-command.sh` is the regression pin.
- **Rule**: the stable sync owns `pkgver`/`pkgrel` of `packages/stable`
  recipes and rewrites them to the repo's values in both directions on every
  load. Do not hand-bump `pkgrel` on a stable recipe without `--no-sync`;
  the standing convention is to align committed values to the repo.
- **Rule**: TLS `unexpected eof` (and single-host 404s) on fetches are
  transient — retry before touching a recipe; `git clone` leaves no partial
  dir to clean. But a repo package 404ing on ALL mirrors is a stale local
  pacman db: `sudo pacman -Sy`, then retry.
- **Rule**: judge recipe freshness by content, not mtime — compare the last
  commit touching the PKGBUILD and pkgver against the newest archive name;
  a bulk rewrite or a bookkeeping commit otherwise flags half the tree as
  stale.

## 2026-09-26 (qt6 spec-type unpin) — qtdeclarative adapted to the LSP-3.18 regeneration, so the qtlanguageserver pin hit its exit condition

- **Symptom**: `qt6-declarative` fails compiling qmlls —
  `qworkspace.cpp:68: 'class QJsonObject' has no member named
  'workspaceFolders'` and
  `qtextsynchronization.cpp:47: 'TextDocumentContentChangeWholeDocument' was
  not declared in this scope` (only the two `QmlLSPrivate` objects fail).
- **Root cause**: Qt private-API skew between qtlanguageserver and
  qtdeclarative. `qt6-languageserver` was deliberately pinned below
  qtlanguageserver's LSP-3.18 spec regeneration (`dba4b9f`) with the
  documented exit condition "unpin when qtdeclarative adapts"; qtdeclarative
  dev HEAD (c0289db7c8, 2026-09-25) adapted, so the pin's private header
  still carried `std::optional<QJsonObject> workspace` /
  `TextDocumentContentChangeEventVariant1/2` where the new code expects
  `workspaceFolders` / `Partial`/`WholeDocument`.
- **Fix**: unpin `qt6-languageserver` back to `#branch=dev` (pre-pin idiom;
  dev tip 146b9ac has `dba4b9f` as ancestor and the regenerated types in
  `qlanguageserverspecttypes_p.h`), record the met exit condition in
  PINNED-README.md + the PKGBUILD comment, and delete qt6-declarative's now-
  stale 2026-09-08 prepare() skew shim (18 lines, an inverted no-op once both
  sides speak the new spec). Both `.SRCINFO`s regenerated.
- **Validation**: `bash -n` both; printsrcinfo deltas as expected; shim
  residue grep clean; evidence the regeneration is included verified by
  `git grep` at the mirror's dev tip. Real verification is the build order
  qt6-languageserver → qt6-declarative → remaining qt6/qt5 batch.
- **Rule**: a pin-with-exit-condition must be unpin+cleanup in the SAME batch
  the exit condition fires (including inverse shims in sibling recipes), and
  the qtlanguageserver↔qtdeclarative pair moves as one ABI-coupled unit —
  fetch both from the same dev day.

## 2026-09-25 (toolchain drift recipes) — post-10-Sep toolchain snapshots broke recipes independently of the llvm skew; fixes land one commit each

Four recipes broke while the llvm/rust skew recovery was in flight — three
against newer host toolchain snapshots (cmake-git 4.4.20260919, GCC
17.0.0 20260920) and one from upstream drift. Each fix is its own commit;
entries append here as they land.

### fish 4.9.3 vs cmake-git 4.4: `install(SCRIPT CODE)` rejected

- **Symptom**: configure stops at `cmake/Install.cmake:74` —
  `SCRIPT: missing required value` (fish last built clean 15 Sep).
- **Root cause**: `install(SCRIPT CODE "…")` is a deprecated loose form;
  the cmake snapshot tightened argument parsing so SCRIPT consumes the CODE
  keyword. The block only ever ran inline code (no script file).
- **Fix**: `packages/stable/fish/cmake-install-code.patch` rewrites the call
  to `install(CODE "…")` — the identical install-time hook, already used
  unpatched at lines 99–100 of the same file; pkgrel bump.
- **Validation**: patch applies `--fuzz=0` at the exact site against the real
  4.9.3 tree; `bash -n`; `.SRCINFO` regenerated. Full build confirms at
  configure and `cmake --install`.
- **Rule**: a cmake *snapshot* tightens syntax before the stable release does;
  when a recipe fails on a tightened legacy form, migrate the call to the
  canonical form (do not pin an older cmake).

### xwayland-satellite-git: round-half-up patch conflicted after upstream main moved

- **Symptom**: `prepare()` fails applying `0001-round-half-up.patch` —
  upstream main moved add2795 → 63cdf17 (v0.8.3 era).
- **Root cause**: upstream commit 5274bdc (#496) rewrote exactly the height
  code the patch hunked, so `git apply -3` conflicted. The patch is still
  needed: issue #479 is open, and 63cdf17 (#448) only rounds popup
  xdg_positioner rects — a different conversion path.
- **Fix**: patch rebased onto 63cdf17 — round-half-up kept on x/y/w/h,
  #496's titlebar-height move absorbed into the configure arm (both
  conversions round), `update_surface_viewport` rounds instead of `ceil()`,
  #496's test expectations retargeted (112→113, 93→104), #479 regression
  test kept. pkgver 0.8.2.r16.g63cdf17, new b2sum, `.SRCINFO` regenerated.
- **Validation**: `git apply --check` + `patch --dry-run` clean against the
  real tree at 63cdf17; apply-verify-reset reproduced the authored diff;
  `bash -n`; printsrcinfo. Test-module compile-and-pass is unverified by
  design (no builds before the supervised full build; `!check` host).
- **Rule**: a `-git` recipe's patch is pinned to a moving upstream; when it
  conflicts, first check whether the patched behavior landed upstream (drop
  then), else rebase and re-validate against the exact fetched revision.

### openshadinglanguage 1.15.3.0 vs llvm-git 24: removed TargetOptions fields

- **Symptom**: compile errors in `llvm_util.cpp` at the jit-engine and NVPTX
  option sites — `llvm::FPOpFusion`/`TargetOptions::AllowFPOpFusion` and
  `HonorSignDependentRoundingFPMathOption` no longer exist in the llvm-git
  24 snapshot.
- **Root cause**: llvm-project `9d4a7d05d2` (PR #222683) and `3e3965fa48`
  (PR #222027) removed both fields; FP contraction now derives solely from
  per-instruction `contract` FMF and the sign-dependent rounding option was
  superseded by `strictfp`. Upstream OSL has **no** fix yet (main, release,
  dev-1.15 and tags through v1.15.7.0 all still use the removed API).
- **Fix**: `osl-llvm-compat.patch` extended with `#if OSL_LLVM_VERSION < 240`
  guards at all 5 sites (matches the patch's existing version-guard
  convention). Behavior-preserving on the jit path (OSL emits no `contract`
  FMF / no `llvm.fmuladd`, so Standard/Strict never contracted; `HonorSign…`
  was already LLVM's default). NVPTX `Fast` loses free FMA contraction —
  perf-only, OptiX not enabled in this recipe. pkgrel 1.1→1.2.
- **Validation**: patch applies clean against the pristine v1.15.3.0 tarball
  (sha512-verified); all 5 sites mechanically confirmed inside guards;
  `bash -n`; printsrcinfo delta = pkgrel + patch sum only.
- **Rule**: when an LLVM snapshot removes an API and upstream has not caught
  up, take the semantic mapping from the removal PR and a known-good
  migration (here: openxla/xla@91888df6ce), guard by version in the recipe's
  existing compat patch, and document any behavior delta in the patch itself.

### autofdo-git vs GCC 17 snapshot: constexpr brace-init ICE (gcc PR 127395)

- **Symptom**: compile dies in bundled abseil's
  `crc_memcpy_x86_arm_combined.cc:164` — `internal compiler error: in
  verify_ctor_sanity, at cp/constexpr.cc:7362` (GCC 17.0.0 20260920).
  autofdo was also the one runtime-broken skew consumer (`create_llvm_prof`
  had 138 undefined symbols), so a successful rebuild fixes both.
- **Root cause**: `constexpr uint32_t kCrcDataXor = uint32_t{0xffffffff};` —
  the braced scalar cast is a CONSTRUCTOR of scalar type; the GCC snapshot
  folds it at template-parse but `reduced_constant_expression_p()` rejects
  non-aggregate CONSTRUCTORs → `gcc_assert(ctx->ctor)`. Matches gcc
  **PR 127395** exactly (ASSIGNED, draft fix withdrawn 2026-09-17, still
  unfixed upstream; abseil master still has the line).
- **Fix**: recipe patch replaces the braced cast with the equivalent plain
  literal `0xffffffffu` — no CONSTRUCTOR, semantics unchanged. grep-guarded
  `patch --forward` in prepare() (re-run safe, drops loudly on upstream
  drift); pkgrel 5→6.
- **Validation**: patch clean against on-disk source (autofdo `5d0de4e` /
  abseil `2f9e432c`); apply + re-run simulation both exit 0; scan of the
  compiled trees found no other trigger-shaped site; `bash -n`; printsrcinfo.
- **Rule**: a GCC-snapshot ICE on a known upstream PR gets a minimal
  source-shape patch at the recipe level (never a toolchain pin); the patch
  stays until the compiler fix lands, and `prepare()` must fail loudly when
  upstream moves the patched line.

### blender-git vs cmake-git 4.4: `install(CODE … DEPENDS)` rejected

- **Symptom**: configure aborts at `source/creator/CMakeLists.txt:2163
  (install)` — `install CODE given unknown argument: "DEPENDS"`.
- **Root cause**: upstream's manpage block calls
  `install(CODE "…manpage gen…" DEPENDS blender)`; `DEPENDS` was never a
  valid `install(CODE)` argument — old CMake silently ignored it, the
  cmake-git 4.4.3 snapshot hard-errors. Same drift class as the fish case.
- **Fix**: recipe patch deletes the dead `DEPENDS blender` token (behavior-
  neutral: it was always ignored, install-phase ordering already guarantees
  the binary exists); picked up by prepare()'s existing `*patch` →
  `git apply` mechanism.
- **Validation**: `patch --dry-run --fuzz=0` + `git apply --check` clean
  against the real checkout (a72cf3c0d50367bb, stable 3-line context
  surviving pkgver drift); resulting call has `CODE` as sole argument;
  `bash -n`; printsrcinfo.
- **Rule**: when cmake-git tightens parsing, the fix is to migrate the call
  to its canonical argument set (fish: `install(CODE …)`; blender: drop the
  never-valid token) — never pin an older cmake; expect more lenient-parsing
  victims to surface one at a time.

## 2026-09-25 (abi batch policy) — the run's own llvm-git install broke rustc after the preflight had passed; the builder now refuses llvm-without-rust and re-probes mid-run

- **Symptom**: 20:50:26 — a running batch installed `llvm-git`
  24.0.0_r598996.57e112ccb2a5 and the system `rustc` broke instantly
  (`librustc_driver-….so: undefined symbol:
  llvm::cl::ParseCommandLineOptions…, version LLVM_24.0`). 3 s later a
  `mold-git` build died in `prepare()`
  (`cargo fetch --locked --target "$(rustc -vV …)"`) with
  `rustc: symbol lookup error: … version LLVM_24.0`; `rustc -vV` → rc=127.
  The `check_rustc_sanity` preflight had passed at 19:31 and never ran again;
  separately, `mold-git` (a cargo recipe) was dispatched before `rust-git`
  because its `dependencies.conf` record was the deliberate no-edge
  `mold-git:`.
- **Root cause — hypotheses** (diagnosing-bugs record):
  - **H1 (primary, winning — mechanism confirmed)**: the llvm-git snapshot
    bump left rust-git ABI-skewed. LLVM trunk changed the
    `cl::ParseCommandLineOptions` overload (trailing `bool` param dropped)
    while keeping the `LLVM_24.0` version node — pure C++ ABI churn.
    `objdump -T`: `librustc_driver` needs `…vfs10FileSystemES2_b`; the new
    `libLLVM` exports `…vfs10FileSystemES2_`. rust-git (installed 16:46,
    built against the previous snapshot) was not rebuilt in the batch.
  - **H2 (secondary, confirmed)**: the `mold-git:` record (line 45 of
    `config/dependencies.conf` at diagnosis time; now `mold-git:rust-git`) is
    a deliberate no-edge record, but the reworked cargo-based mold-git recipe
    invokes system rustc/cargo in prepare()/build(). **The scheduler resolved
    the chain exactly as declared — the declaration was wrong.** Dry-run
    evidence at diagnosis time:
    `-n --no-deps mold-git rust-git` ordered mold first; `-n mold-git`
    expanded to 1 (empty declared chain).
  - **H3 (confirmed, timing gap)**: `check_rustc_sanity` (a real
    rustc-compile preflight) runs once per run before dispatch and
    legitimately passed at ~19:31 — the run's own llvm install at 20:50:26
    created the skew mid-run, invisible to the preflight.
  - **H4 (falsified)**: partial llvm install / broken local db — `pacman -Qk
    llvm-git` clean (5301 files, 0 missing).
  - **H5 (falsified)**: library shadowing — `ldd /usr/bin/rustc` resolves
    `libLLVM.so.24.0` from `/usr/lib`.
  Net: the rustc sanity probe ran only as a start-of-run preflight, so the
  run's own llvm install created the ABI skew *after* the last possible probe
  (H1+H3); and nothing enforced that a recipe compiling with cargo/rustc
  carries a `rust-git` edge (H2), or that a selection moving the LLVM ABI
  rebuilds rust-git in the same batch.
- **Fix** (two halves):
  (a) dependency graph — 5 new `rust-git` edges: `mold-git:rust-git`,
  `xwayland-satellite-git:rust-git`, `linux-cachyos:rust-git`,
  `zen-browser-pgo:rust-git`, `bettbox:rust-git`, each verified against the
  recipe's actual cargo/rustc usage (linux-cachyos via `CONFIG_RUST=y`
  in-tree kbuild Rust, bettbox via `fvm flutter build linux` → cargokit
  `cargo`); pre-existing edges verified for niri-spicy-git, scx-scheds-git,
  scx-tools-git, fish, zram-generator, rust-bindgen-git; deliberately NO edge
  for mesa-git (Rust only in non-default `MESA_WHICH_LLVM` cases — the
  default build compiles none).
  (b) three builder policies in `build-all.fish` (contract items 1–3):
  (1) `--audit` toolchain lint — every mapped recipe whose PKGBUILD invokes
  `cargo`/`rustc` (rust-git excepted) must name `rust-git` in its edge record,
  or the audit reports `toolchain: <id> uses cargo/rustc but declares no
  rust-git edge`; (2) ABI-batch refusal in `main` — a real build (`dry_run=0`,
  `list_flag=0`) whose selection contains `llvm-git` but not `rust-git` is
  refused while `rust-git` is installed, with recovery text pointing at the
  same-pass rebuild; (3) `run_lanes` re-runs `check_rustc_sanity` after a
  successful `-i` lane for `llvm-git`/`llvm-libs-git`, before anything else
  dispatches — on failure it takes the existing stop-dispatch contract (stop
  starting lanes, drain in-flight ones, exit non-zero; a *deferral* is not a
  failure — lane rc 99 parks instead, see 2026-09-24). `--allow-broken-rustc`
  deliberately does NOT cover the mid-run probe: it is documented as "not a
  way past a real ABI mismatch", and a probe failure after this run's own
  llvm install is exactly that. (The `mold-git:rust-git` edge itself is (a)
  above.)
- **Validation**: new `tests/abi-batch-policy.sh` (four sections: audit lint
  fires for a cargo recipe without the edge, stays silent with it / for
  comments / for rust-git itself; llvm-without-rust refusal while `-n`/`-l`
  stay green and llvm+rust is not over-refused; dispatcher probe stops before
  the next package with the probe message; `mold-git:rust-git` declared and
  ordering a mold-git selection). Fixture red before, green after, and every
  seam falsified by mutation (lint off → A fails, refusal off → B fails, probe
  off → C fails). `bash -n tests/abi-batch-policy.sh`,
  `fish -n build-all.fish`; `--audit` rc=0 with `toolchain: none`; `--list`;
  `--dry-run` clean for git(58)/stable(29)/core(41); full battery
  `bash tests/run-all.sh` 35/36 — the ONLY failure is
  `srcinfo-freshness.sh` on `packages/core/mold-git`, a pre-existing stale
  `.SRCINFO` from the concurrent commit ef03218, not this fix. Post-fix
  `-n mold-git` (bare name, dep expansion) expands to **3** — `llvm-git`,
  `rust-git`, `mold-git` — because the pre-existing `rust-git:llvm-git` edge
  transitively pulls llvm-git in (correct per the documented bare-name
  semantics); the ordering guarantee that matters is rust-git before
  mold-git. Host `rustc` was found still broken at implementation time — the
  incident's recovery had not yet run.
- **host recovery**: recovery rebuild finished clean. `rustc -vV` rc=0 —
  `rustc 1.100.0-nightly (2c1a66d7d 2026-09-25)`; `rust-git
  1:1.100.0.r341518.g2c1a66d` rebuilt via stage0 bootstrap (39m24s,
  `--allow-broken-rustc` used only for that self-rebuild); `ldd -r
  /usr/lib/librustc_driver-*.so` → 0 undefined. Workspace loop
  `fish build-all.fish --no-deps mold-git`: `✓ mold-git (6m59s)` →
  `All builds succeeded!` (mold-git 2.42.1.r468.g6fc6e191). Tier-2
  rebuilt+installed 11/15 — mold-git, niri-spicy-git, scx-scheds-git,
  scx-tools-git, zram-generator, rust-bindgen-git, mesa-git, libclc-git,
  spirv-llvm-translator-git (4→0 undefined) — llvm-git kept as ABI base;
  runtime skew cleared except autofdo. Four recipe-level blockers remain,
  NOT skew but post-10-Sep toolchain snapshot drift — two toolchain
  snapshots broke recipes independent of the LLVM skew: (1) fish 4.9.3 vs
  cmake-git 4.4.20260919 `install(SCRIPT CODE)` → "SCRIPT: missing required
  value"; (2) xwayland-satellite-git upstream main moved add2795→63cdf17,
  `0001-round-half-up.patch` conflicts; (3) openshadinglanguage 1.15.3.0:
  `llvm::FPOpFusion`/`AllowFPOpFusion`/`HonorSignDependentRoundingFPMathOption`
  removed in the llvm-git 24 snapshot; (4) autofdo-git: GCC 17.0.0 20260920
  ICE `verify_ctor_sanity` — still 138 undefined in `create_llvm_prof`, the
  one hard-broken runtime consumer. Tracked and fixed separately (recipe
  fixes land as their own commits). Deferred provenance rebuilds
  (runtime-clean, optional): zen-browser-pgo, bettbox, linux-cachyos
  (rust-enabled kernel).
- **Durable rule**: a probe that runs only at run start cannot see a skew the
  run itself installs — re-probe the toolchain after any lane that installs
  llvm-git/llvm-libs-git, before dispatching more work. A selection that moves
  the LLVM C++ ABI must rebuild rust-git in the same batch, and every
  cargo/rustc recipe declares its `rust-git` edge explicitly — in ANY phase
  (prepare/build/check/package), in the same change that introduces the
  invocation. A bare `package-id:` no-edge record is valid syntax the
  scheduler trusts blindly: re-verify it against the recipe's real toolchain
  usage, not its history.

## 2026-09-25 (stale DESTDIR) — rebuild #2 died 21 minutes in: the failed run #1 poisoned the next install

- **Symptom**: rebuild #2 (rust-src step fixed) compiled cleanly, then
  `install.sh` aborted at the rustc component with `cp: not writing
  through dangling symlink …/rustlib/x86_64-unknown-linux-gnu/bin/rust-objcopy`,
  and the installer log showed it creating `librustc_driver-….so.old` /
  `rust-analyzer-proc-macro-srv.old` backups in dest-rust.
- **Root cause**: makepkg keeps `$srcdir` across runs, and run #1's
  failed `build()` had already mutated `dest-rust` — deleted the
  `manifest-*` files, created the relative tool symlinks
  (`rust-objcopy` → `../../../../bin/llvm-objcopy`, which dangles inside
  DESTDIR until the package sits at `/usr`), moved the licenses. Run #2's
  installer no longer recognised those files (manifests gone → `.old`
  backups) and `cp` refuses to write through a dangling symlink.
- **Fix**: `build()` now starts with
  `rm -rf "$srcdir/dest-rust" "$srcdir/dest-src"` — a deterministic
  fresh DESTDIR on every attempt. `tests/rust-recipe.sh` pins the line.
- **Validation**: `bash -n`, fixtures green in both trees, `.SRCINFO`
  regenerated, rebuild #3 launched.
- **Durable rule**: DESTDIR is build output, not leftover scratch a
  failed run may half-mutate — wipe it at the top of `build()`, the way
  makepkg itself wipes `$pkgdir` before `package()`.

## 2026-09-25 (rust-src rename) — upstream renamed x.py's `src` install step; the rebuild died after 35 minutes at `_pick dest-src`

- **Symptom**: the `!lto`-fixed rebuild (Workspace r341498) compiled
  cleanly — "Build completed successfully in 0:35:26", stage2 clippy
  installed — then `build()` aborted with `mv: cannot stat
  'usr/lib/rustlib/src'`. No package, no install. The launcher shell
  reported rc=0 because its output was piped through `tail`; only the
  build log's `==> ERROR: A failure occurred in build()` told the truth.
- **Root cause**: upstream rust-lang/rust@abcb9780d6d4 "Rename the src
  install build step to rust-src" (2026-09-07 — between the last
  successful r339451 build and r341498) changed the step's selector from
  `run.path("src")` to `run.alias("rust-src")` and its tools gate to
  `tools.contains("rust-src")`. The default-run condition is
  `config.extended && …` and this recipe's bootstrap.toml never sets
  `[build] extended`, so bare `x.py install` silently installs
  rustc/cargo/rustfmt/clippy/rust-std but no `rust-src` component; the
  following `_pick dest-src usr/lib/rustlib/src` then fails and kills the
  whole build — at the very end of a 35-minute compile.
- **Fix**: `build()` now runs a second, explicit
  `DESTDIR=… python ./x.py install rust-src` (explicit selectors bypass
  the default gate); the template's tools entry `src` → `rust-src`; and
  the template's b2sum was refreshed in `b2sums` — makepkg refuses a stale
  checksum in seconds, before any compiling. `tests/rust-recipe.sh` pins
  all three: the explicit step, the renamed tools entry, and the
  checksum↔template match. Mirrored to the canonical repo and the
  `~/Workspace` copy.
- **Validation**: probe install of `rust-src` into a scratch DESTDIR
  produced `usr/lib/rustlib/src` in 36 s (rc=0); `bash -n`,
  `makepkg --printsrcinfo`, and the fixture are green in both trees;
  the full rebuild with the fix is running — see the verification note
  appended below once it lands.
- **Durable rule**: a recipe that runs `x.py install` and then packages a
  component split must invoke that component's install step explicitly —
  upstream renames and default-gate conditions make the implicit set
  unstable. Editing any `source=` file means refreshing its checksum in
  the same change. And never judge a build by a piped shell's rc: read the
  build log / the artifacts.

## 2026-09-25 (rust-git `!lto`) — makepkg's `-flto=auto` and lld disagree: stage1 died with 140 undefined `LLVMRust*`

- **Symptom**: the rust-git rebuild after llvm-git r598801 (r341461,
  `~/Workspace` copy) failed at stage1 — `ld.lld: error: undefined reference:
  LLVMRustBuildMemCpy` and ~25 more, when linking `rustc_main` against
  `stage1-rustc/…/librustc_driver-fe0c….so` under `--no-allow-shlib-undefined`.
  The new driver .so had **140 U `LLVMRust*`**, only `LLVMRustStringWriteImpl`
  defined, and **no `NEEDED libstdc++`**; the Sep-8 installed .so had U=0 and
  libstdc++ present. The rlib and `libllvm-wrapper.a` did define all 166
  wrapper symbols — the objects existed, the link never took them.
- **Root cause** (every step measured): rust-git carried
  `options=( !emptydirs lto )` and the host's `/etc/makepkg.conf` has
  `OPTIONS=(… lto …)` + `LTOFLAGS="-flto=auto"`, so makepkg's
  `buildenv/lto.sh` appended **`-flto=auto`** to CXXFLAGS (proof:
  rustc_llvm's build-script stdout `CXXFLAGS = … -flto=auto -pipe`; the
  PKGBUILD only appends `-pipe`). `rustc_llvm/build.rs` compiles the five
  C++ llvm-wrapper files with those flags → every wrapper `.o` was a
  **GCC-LTO GIMPLE object** (all `.gnu.lto_*` sections; `.gnu.lto_.opts`
  holds the literal flag; GCC 17.0.0 snapshot20260920). stage0 rustc
  (`1.99.0-beta.3` nightly-2026-08-30 — proven from
  `stage1-rustc/.rustc_info.json` — spec `linker-flavor: gnu-lld-cc`)
  links stage1 via `cc -fuse-ld=lld` → host `/usr/bin/ld.lld`, and **lld
  never runs GCC's LTO plugin**: a minimal repro (plain `.o` +
  `libllvm-wrapper.a`) left the symbol undefined with rc=0 under both LLD
  23.1 (stage0's rust-lld) and LLD 24 (llvm-git r598801), even with gcc's
  full `-plugin liblto_plugin.so -plugin-opt=lto-wrapper…` chain, while
  the same objects link `T` with **mold** and with **bfd**. So the wrapper
  members never entered the driver .so and the `--no-allow-shlib-undefined`
  link died. This is NOT LLVM ABI skew: llvm-git only happens to supply the
  `ld.lld` binary (the old rustc's death at r598801 is the separate,
  expected Rule-13 rebuild case).
- **Fix**: `lto` → explicit `!lto` in rust-git's `options` — deleting the
  line is not enough, global OPTIONS enables `lto` for every package.
  Applied to the canonical recipe and the user's Workspace copy (pkgver
  r341461 kept); `.SRCINFO` regenerated in both; new `tests/rust-recipe.sh`
  pins `!lto` in the PKGBUILD **and** the committed `.SRCINFO`.
- **Validation**: `bash -n`, `makepkg --printsrcinfo`,
  `fish build-all.fish --audit`/`--list` rc=0, dry-run rc=0, full battery
  **PASS (34)** including the new fixture. Exposure audit: every other
  recipe that links through lld (`autofdo-git`, `linux-cachyos`) already
  carries `!lto`; all remaining makepkg-LTO consumers link with mold or
  bfd, which do run the GCC plugin (verified empirically).
- **Durable rule**: rust-git must keep `!lto` — Rust-side fat LTO
  (`lto = "fat"` in bootstrap.toml) is a different knob and stays. Any
  recipe whose C/C++ is compiled from makepkg flags and linked by
  rustc/ld.lld must disable `lto`: mold and bfd run GCC's LTO plugin,
  lld does not.

## 2026-09-25 (vulkan pair) — a `-s` batch left vulkan-headers-git at 1.4.363 while the loader fetched v1.4.364 requiring it: "VulkanHeaders … not compatible"

- **Symptom**: `vulkan-icd-loader-git: BUILD FAILED (rc=1, 0m02s)` in a wide
  `-s -i` batch — `CMake Error at CMakeLists.txt:63 (find_package)`:
  requested VulkanHeaders "1.4.364", while installed
  `/usr/share/cmake/VulkanHeaders/VulkanHeadersConfig.cmake` reports 1.4.363.
- **Root cause**: coupled VCS pair drift plus the `-s` blind spot. The
  batch's `-s` build-skipped `vulkan-headers-git` (its 1.4.363 archive is
  newer than its PKGBUILD) while `vulkan-icd-loader-git` fetched upstream
  `v1.4.364`, whose `find_package(VulkanHeaders ${PROJECT_VERSION} CONFIG …)`
  requires headers ≥ its own version. The skip predicate (archive mtime ≥
  PKGBUILD mtime) is stale-by-construction for `-git` recipes: the PKGBUILD
  does not change when upstream does. (The `already installed at 1.4.363 …
  skipping their install` line in the headers log is the same-day `-i`
  same-version check working as designed — it skipped a byte-identical
  reinstall and is not the cause.)
- **Fix**: rebuild the pair together with `-i` and without `-s`
  (`fish build-all.fish -i vulkan-icd-loader-git` — bare-name dep expansion
  builds and installs headers before the loader compiles, rule 11), plus
  hardening: the loader's makedepends is now
  `"vulkan-headers>=1:${pkgver%%.r*}"` (epoch 1 matches the headers recipe's
  versioned provide; the base tracks each loader bump), so a stale provider
  fails at "Checking buildtime dependencies" with an actionable message
  instead of a cryptic CMake version error mid-build. A compatibility probe
  pinned the gate semantics: "at least" (1.4.362 accepted against a 1.4.363
  config, 1.4.364 rejected).
- **Validation**: the red-capable loop
  (`fish build-all.fish --no-deps vulkan-icd-loader-git` in the workspace
  clone) reproduced the exact symptom before the fix and is green after;
  `pacman -Q vulkan-headers-git vulkan-icd-loader-git` both ≥ 1.4.364; new
  fixture `tests/vulkan-pair.sh` passes; `--audit`/`--list` and the full
  battery green.
- **Rule**: never resume a coupled VCS pair with `-s` when a consumer may
  have moved upstream — rebuild provider and consumer together with `-i`
  (docs/maintainer-guide.md "Updating coupled stacks"). When upstream
  enforces a version requirement, version-pin the consumer's makedepends to
  the provider and keep both sides' epochs in step.

## 2026-09-25 (install skip) — `-s -i` re-ran `pacman -U` for packages already installed at the built version; `-i` now checks, `-fi` forces

- **Symptom**: the documented resume idiom `build-all.fish -s -i` skipped
  already-built archives but still ran `pacman -U --noconfirm --ask 4` for
  every one of them on every run — even when the exact built version was
  already installed. A long resume paid a full transaction set for nothing.
- **Decisions** (confirmed before implementing): the check applies to EVERY
  `-i` install (fresh-build path and `-s` skip path share one installer);
  `-fi/--forceinstall` implies `-i` and bypasses the check; a freshness
  guard is required; `-ia/--installall` stays untouched (collective escape
  hatch by definition installs everything built).
- **Fix**: new `install_skip_reason` in `build-all.fish` answers two
  read-only queries per archive — `pacman -Qp` (built name+version straight
  from the archive, so epochs and split outputs arrive in pacman's own
  canonical form, with no filename/PKGBUILD parsing) and
  `LANG=C pacman -Qi` (installed `Version` + `Install Date` → `date -d`
  epoch) — and `install_pkgs_now` drops an archive only when (a) the
  versions are identical AND (b) the install date is NOT older than the
  archive. The freshness guard is what makes a same-version rebuild
  install: version equality alone would skip a patched rebuild whose new
  payload never reached the system. Any doubt — no query answer, a missing
  field, an unparseable date — falls through to `pacman -U`, so the
  conservative direction is always the transaction, never silence. `-fi`
  rides install_flag's plumbing (`main` → `run_lanes` → `--lane-job`'s
  fifth flag → `lane_job` → `build_package` → `_INSTALL_FORCE`, the same
  global hand-off `_BUILD_QUIET` uses) and skips the check entirely; the
  failure-resume and sudo-rerun suggestions now mirror `--forceinstall`.
- **Pitfalls hit**:
  - the `--lane-job` argv contract grew from 8 to 9 tokens — every direct
    caller must pass the fifth flag or the child exits 2
    (`tests/signal-abort-lock.sh` invoked it directly);
  - an inline `echo "…"(test …; and echo " (forced)")"` broke fish parsing:
    a `"` inside the command substitution terminated the outer quote early
    and `(forced)` was executed as a substitution ("Unknown command:
    forced") — compute display labels in `set -l` blocks instead;
  - the lane's `already built` ui_info is gated to interactive mode, so a
    `-s` fixture cannot observe the skip at the terminal — it counts stub
    makepkg invocations instead (`GSA_FIXTURE_MAKEPKG_COUNT`).
- **Validation**: `fish -n build-all.fish`; `bash -n tests/*.sh`;
  `--audit`/`--list` clean; help renders `-fi`; real-host parse check
  (`LANG=C pacman -Qi bash` → `date -d` → epoch); full battery
  `bash tests/run-all.sh` — PASS (33 fixtures), including the six new
  `install-archive-guard.sh` cases C–H (skip, version mismatch, stale
  install date, force bypass + implies-`-i`, `-s -i` double skip,
  `-s -fi`) and `resume-command.sh`'s `--forceinstall` mirror.
- **Rule**: `-i` installs only on positive evidence — exact version match
  AND install date ≥ archive mtime; every doubt installs. `-fi` forces and
  implies `-i`; `-ia` is unaffected. Pinned by
  `tests/install-archive-guard.sh`.

## 2026-09-24 (battery restructure) — 45 scruffy fixtures and a 4-minute serial battery → 33 files, one file per subject, 29 s in parallel

- **Symptom**: `tests/` had grown one incident at a time — 45 flat scripts
  (~6,970 lines), five six-line wrapper files, six subjects split across two or
  three files each, and one `.SRCINFO` freshness check asserted in five places.
  The full battery cost ~4 minutes, so it was starting to feel too expensive to
  run habitually — which is exactly how a battery stops catching things.
- **Cost audit (per-fixture wall time)**: `dashboard.sh` 48.9 s (case C waited
  out the *real* 30 s abort grace plus a 60 s deadline), `project-cli-hints.sh`
  26.7 s (21 fish invocations, each paying the loader's full map/graph/sort
  validation), `srcinfo-freshness.sh` 22.5 s (job cap 8 on a 24-thread host) —
  34 % of the run in three files; 20 fixtures were already sub-second. The
  runner was a plain serial `for` loop.
- **Fix**:
  1. *Merges* — `kernel-config-verify`+`-sums`+`-version` → `kernel-recipes.sh`;
     `log-ownership-root` → `log-ownership.sh`; `noctalia-pgo-train` →
     `noctalia-pgo.sh`; `zen-pgo-workload`+`-speedometer` → `zen-pgo.sh`;
     `vencord-recipe`+`-inject` → `vencord.sh`; `project-config`+`-cli-hints` →
     `project.sh`. Each absorbed script is appended as a `( subshell )`
     section, so its variables, `trap`, `set +e/-e` toggles and `fail()` prefix
     stay isolated and a failure still names the sub-area. The five wrappers
     folded into `pgo-transition.sh` (no arguments = all five
     package/project/recipe pairs; three arguments = that pair alone).
  2. *Parallel runner* — `run-all.sh` now fans out with `xargs -P` (default
     `nproc`, `-j N`/`RUN_ALL_JOBS`, `--serial`), buffers each fixture's output
     under `$TMPDIR`, and reports alphabetically regardless of completion order;
     same discovery (recursive, `tests/assets/` excluded), same filter, same
     `PASS (n fixture(s))` contract.
  3. *Seam instead of waiting* — `build-all.fish` reads `_LANE_STOP_GRACE_S`
     from the environment (underscore-prefixed **internal** seam, default still
     30 s, non-numeric junk falls back to 30; the seven public `GSA_*` inputs in
     `--help` are untouched). `dashboard.sh` case C exports 5 s and scales its
     stub lanes to ~10 s: the assertion is still TERM → grace → single KILL.
  4. *Inner parallelism* — `project.sh` collects its `run`/`run_split` calls
     from its own text and pre-executes them concurrently, replaying from a
     cache (assertions byte-for-byte unchanged); `srcinfo-freshness.sh` defaults
     to one job per hardware thread.
  5. *One owner per check* — the byte-exact `.SRCINFO` diff was removed from
     `logseq-desktop-recipe`, `texlive-recipe`, `bpftune-tuners-hook` and the
     zen section; `srcinfo-freshness.sh` covers every recipe in
     `config/packages.map`.
  6. *The tripwire* — `signal-abort-lock.sh`'s two **global**
     `--lane-job` process scans are now scoped to `$fixture` (lane argv always
     carries `$SCRIPT_DIR/build-all.fish`). The 2026-09-24 harness entry's
     "never run two batteries at once" rule was an unscoped-`ps` bug waiting to
     self-inflict the moment the runner went parallel.
- **Validation**: full battery **PASS (33) in 29 s** parallel and **PASS (33)
  in 108 s** with `--serial`; red-checks — a neutered assertion inside the
  *absorbed* kernel-sums section and a neutered assertion in `project.sh`'s
  replayed body each fail the battery, then pass again after byte-exact
  restoration; `fish -n`, `--audit`, `--list`, and the three dry-runs green;
  filter (`kernel`, `project.sh`), `-j` and `--serial` paths exercised.
- **Durable rules**: (a) a fixture must be parallel-safe — non-mutating,
  `$TMPDIR`-scoped, and process assertions scoped to its own fixture path, never
  global; (b) merge a sibling subject into the existing file as a subshell
  section, do not add a top-level script per check; (c) `.SRCINFO` freshness is
  asserted only by `srcinfo-freshness.sh`; (d) timing tests use the
  `_LANE_STOP_GRACE_S` seam, never a real grace window, and
  `signal-abort-lock.sh` pins the 30 s default so the seam cannot drift.

## 2026-09-24 (texlive prepare) — a config-only SVN husk in SRCDEST sailed past makepkg's warning and killed prepare() at the awk step

- **Symptom**: `build-all.fish` dispatched `texlive-texmf` (rc=1, 23m20s in
  `.state/logs/texlive-texmf.log`): the 6 minted overlay patches and
  `texmf.cnf.patch` applied cleanly (all 7 `patching file …` lines), then
  `awk: fatal: cannot open file 'tlpkg/texlive.tlpdb' for reading: No such
  file or directory` → `==> ERROR: A failure occurred in prepare().` The awk
  is prepare()'s last phase — the per-collection split that reads the tlpdb
  for membership, runfiles, formats, maps, hyphen rules and bin-script links
  (and whose output `texlive-basic` also *packages* into
  `/usr/share/tlpkg`).
- **Measurement** (plan gate, before any edit): upstream HAS the file at the
  pinned revision — `svn info -r 78408
  svn://tug.org/texlive/tags/texlive-2026.1/Master/tlpkg/texlive.tlpdb` →
  `Node Kind: file`, `Revision: 78408`, and `svn ls …/Master/tlpkg/` lists
  `texlive.tlpdb`. Locally `find` found no tlpdb anywhere in the recipe, and
  `svn info <recipe>/tlpkg` → `E155007: … is not a working copy`: the SRCDEST
  `tlpkg/` contained ONLY `.makepkg/` (svn's config dir — `auth`, `config`,
  `servers`, `README.txt`), no `.svn`, no content. The log shows why makepkg
  let it through: `-> Updating tlpkg svn repo...` / `Skipped '.'` /
  `svn: E155007: None of the targets are working copies` /
  `==> WARNING: Failure while updating tlpkg svn repo` — an *update* failure
  on an existing directory is non-fatal — and the extract step then copied
  the husk into `$srcdir/tlpkg` (identical 03:31 mtimes on both sides). The
  sibling sources show the healthy path: `x86_64-linux/` was absent at run
  start, so makepkg *cloned* it and it works. So: **absent locally, not moved
  upstream** — an interrupted/failed initial checkout (dir created 03:31,
  inside the run window whose TERM lands at 03:34:47 in dispatcher.log; the
  old run's log was overwritten, so interrupt-vs-network for that first
  failure is UNPROVEN) left a husk that every later run "updates" without
  ever fetching.
- **Patch-series question answered**: neither patch touches `tlpkg/`
  (`grep -c tlpkg` → 0 in both; targets are `texmf-dist/minted/*` and
  `./texmf.cnf` copied from `texmf-dist/web2c`), all 7 applied in the failing
  run, and `_rev=78408`/`pkgver=2026.1` are unchanged since the recipe's
  first commit — there was **no version bump**; nothing in prepare() besides
  the missing input changed.
- **Contract chosen**: the awk step stays byte-for-byte — the tlpdb
  legitimately ships at the pinned revision and is itself a packaged output,
  so skip/rewrite would gut the split. The fetch is repaired instead: the
  husk was moved to `/tmp/gsa-tlpkg-husk-backup` (evidence) and removed so
  makepkg performs a fresh pinned `svn checkout`, plus a preflight at the
  top of `prepare()` fails in seconds with the exact repair
  (`rm -rf tlpkg src/tlpkg && makepkg -f`) instead of 23 minutes in at a
  bare awk fatal. Sums (`SKIP` for the three VCS entries), sources and
  `.SRCINFO` are untouched (`makepkg --printsrcinfo` diff empty).
- **Validation**: `fish -n`, `bash -n`, `--audit`, `--list`, dry-runs
  git/core/stable, full battery **44/44**; the repaired checkout then took
  `build-all.fish --no-deps texlive-texmf` through prepare() into packaging
  (see validation note below).
- **Durable rules**: a non-working-copy directory in SRCDEST is a landmine —
  makepkg only WARNs on the update and builds from whatever garbage is
  there; never "just re-run" a tlpdb-class failure without checking
  `svn info <source-dir>` first. `svn ls`/`svn info` against the pinned
  revision is the measurement for "the source disappeared"; the build log's
  text alone is not.

## 2026-09-24 (lane reap race) — `signal-abort-lock.sh`'s rc=125 flake: the dispatcher read the result, then checked the child, and the child died in between

- **Symptom**: `tests/signal-abort-lock.sh` failed intermittently (one
  44-fixture battery 43/44, green on rerun; also seen 1-in-8 and, when pinned
  by a strictly SERIAL loop, at iter 20/30) with
  `phase 3 … dispatcher did not report the honest 143` and the run summary
  `✗ lane supervisor produced no valid result (pid=3542191, state=(gone))` /
  `result file bytes: (no bytes)` — while the package log *simultaneously*
  carried `lane child received TERM (rc=143, pid=3542191) — honest signal
  result recorded`, i.e. the child did everything the 2026-09-23 fix
  promised, with the SAME pid the supervisor named.
- **Root cause** (ordering proof, no guesswork): the dispatcher's reap reads
  the result ONCE (`cat "$rf"`) and only afterwards asks
  `lane_pid_alive`. `write_lane_result` publishes atomically with `mv`,
  and the child's sequence is `mv → honest log line → re-raise → death`.
  `(no bytes)` therefore means the `cat` happened **before** the `mv`;
  `state=(gone)` plus the honest line (which precedes the forensics block in
  `p1.log`) means the `ps` happened **after** the death — the whole
  publish-and-die fell into the gap between the read and the check. The
  result was on disk; the dispatcher had already decided it saw nothing and
  reaped rc=125. Window is milliseconds, hence ~1-in-20 serially. (Two
  other reds seen while reproducing — "run … reported success" — were
  self-inflicted: two overlapping loop instances, whose global
  `find_lane_pid` greps crossed; that hazard is already named in the
  2026-09-24 harness entry and is NOT this defect.)
- **Fix** (one hunk in `build-all.fish`'s reap): after the liveness check
  reports the child dead with no valid result, re-read the file ONCE.
  Publication happens-before death, so if the child wrote, the result exists
  at that moment; a genuinely missing write stays empty and keeps today's
  forensics/`stop_lane_process` behaviour unchanged. No new GSA_* knob, no
  fixture reshuffle, no restyling.
- **Validation**: red-first — the unmodified fixture's phase-3 failure was
  captured serially with full output before the edit; after the edit the
  same fixture ran **50/50 green serially** and the full battery **44/44**;
  `fish -n` clean. A deterministic red harness is impossible without a
  builder test knob (the window is dispatcher-internal), so the pin is the
  captured red plus the 50-run green tail, not a new fixture.
- **Durable rules**: result-file reads and liveness checks are NOT one
  atomic observation — any future code that branches on "empty result" must
  re-read after observing death; `rc=125 with '(no bytes)' forensics` can
  still be this lost race, not only a dead-before-write child; and the
  serial-reproduction rule stands (two overlapping batteries produce
  unrelated reds that look like new defects).

## 2026-09-24 (sync anchoring) — one missing published checksum refused the recipe, and the refusal strangled the dispatch; sync now runs updpkgsums, and an unanchorable recipe defers

- **Symptom**: `build-all.fish -g stable,core,git,third-party -s -i`
  (unprivileged and root alike), `linux-tools` committed at 7.2.5 while the
  repos served 7.2.7: `✗ linux-tools: BUILD FAILED (rc=1, 0m01s)` —
  `refusing to build — the official packaging repo carries linux-tools 7.2.7
  but publishes no checksum for: linux-7.2.7.tar.sign` plus the manual
  `updpkgsums` line — makepkg never started — and the first lane failure
  stopped everything: `✗ Build failed — stopped dispatching, drained
  in-flight lanes.`, ~120 packages never dispatched, two consecutive runs.
  (Both rows were measured by the plan; the mechanism is line-traced below
  and both behaviours are reproduced at fixture scale. The full-scale run was
  NOT re-executed — the tree already carries the 7.2.7 sums.)
- **Root cause**, two defects plus one stance gap:
  1. `source_filename`'s detached-signature suffix list was
     `.sig|.asc|.signature` — missing `.sign`, the kernel.org spelling. So
     the signature entered `anchor_names`, `srcinfo_sum_map` drops the
     official SKIP value, and the grade step classified it "unanchored" and
     refused *before* updpkgsums ever ran. Measured with `makepkg
     --verifysource`: intact `.sign` → `linux-7.2.7.tar ... Passed`;
     corrupted → `SIGNATURE NOT FOUND`, rc=1 — its integrity is
     cryptographic (PGP against `validpgpkeys`, over a payload whose sha256
     IS published: `4ac34c…` matched the on-disk tarball), not a hash of the
     signature. Real `updpkgsums` preserves `SKIP` too (measured on a copy:
     sums stayed `4ac34c/SKIP/2e187`).
  2. The dispatcher treated ANY lane rc≠0 as a failed build →
     `stop_starting` → drain. Anchoring-impossible (no official document,
     refresh failure) is not a build failure.
  3. Stance: the refusal's own remedy told the maintainer to run
     `updpkgsums` by hand — the guard declined to automate exactly what it
     prescribed, and one such entry parked a 126-package run.
- **Fix** (the trust model, stated): entries the official `.SRCINFO`
  publishes a value for are unchanged — anchored, verified against Arch after
  the `updpkgsums` write; a disagreement still refuses and restores, and now
  *stops* the dispatch (integrity signal, like a failed build). Entries it
  publishes NO checksum for (SKIP or absent) are refreshed at sync-fire by
  the same `updpkgsums` run and recorded LOUDLY as fetch-only: per entry in
  the package log (`publishes no checksum for (refreshed from the fetch, NOT
  anchored)` + the attestation line — PGP for a signature, #tag/#commit for a
  VCS, TLS for a plain download) and in a new run-level
  `Synced with the repo this run …` summary (`synced.list`, cleared per run)
  carrying the review/commit instruction. Signature files are excluded from
  checksum anchoring altogether (`.sign` added to `source_filename`). No
  official document at our version still refuses and restores — nothing can
  be classified without the document — but is DEFERRED:
  `_ANCHOR_DEFER_RC` (99) rides the ordinary lane-rc field (the `pkgdir rc
  seconds` protocol is untouched), the reap parks it (not `failed`, no
  `stop_starting`), dependents are held back by `pick_next_ready` and
  labelled `waits on a deferred package` (not "cycle"), the summary tails
  the parked log (named error + manual recovery + `--no-sync`), and the run
  exits non-zero with the parked packages in the resume command. Install
  failures and makepkg failures still stop the run; root-mode ownership
  semantics were not touched (concurrent log-ownership work left intact).
- **Validation**: red-first — flipped case 5, new case 5b, and
  `tests/anchor-defer.sh` were all red on the old code (the defer fixture's
  RED output reproduced the measured stop-dispatch signature at scale-1:
  `c-plain` never dispatched), green after; full battery **44/44**;
  `fish -n`, `--audit`, `--list`, dry-runs git/core/stable all green. Also
  regenerated the five stale `-git` `.SRCINFO`s (pre-existing battery red
  from uncommitted version bumps) and `linux-firmware`'s (bumped externally
  mid-session).
- **Durable rules**: never fetch-alone for an entry Arch publishes — that
  half of the guard is exactly as it was; refresh-only entries must always be
  named (log + run summary), never silent; a checksum disagreement with Arch
  stops the run; an anchoring that is merely *impossible* defers, never
  aborts, and its dependents never build; the run-level sync summary is the
  commit witness — a run never commits.

## 2026-09-24 (harness) — sudo-keepalive's fake clock raced itself; never run two batteries at once

- **Symptom**: `tests/sudo-keepalive.sh` failed ~2 runs in 3 — on the
  pre-change baseline *and* on the log-ownership tree alike (proven by
  stashing `build-all.fish` and re-running): `✗ p3/p4: BUILD FAILED (rc=125,
  -60m00s)` with `result file bytes: 'p3 0 -5400'`.
- **Root cause**: the fake `date` stub bumped a shared tick counter with an
  unguarded read-truncate-write. Dispatcher and lane children call it
  concurrently; a reader that opens the file between truncate and write gets
  an empty read, resets the counter to 1, and the lane's duration
  (`end - start`) turns negative — `lane_result_valid` rejects non-`[0-9]`
  durations, so a *successful* build is reaped as malformed rc=125.
- **Fix**: serialize the read-modify-write under `flock -x` on the counter
  (tests/sudo-keepalive.sh); the clock contract (+300 s per call) is
  unchanged.
- **Validation**: 3/3 green after the fix (2/3 red before, on both trees).
- **Durable rules**: fixture stub state shared across builder processes must
  be serialized (`flock`); and never run two fixture batteries at once —
  `signal-abort-lock.sh`'s survivor scan matches `--lane-job` processes
  GLOBALLY, so another session's lanes trip it (observed twice: one
  self-inflicted parallel run, one while a concurrent session ran its own
  battery). Both times the fixture was green when run alone.
- **Unproven row**: the first full battery showed `log-ownership-root.sh`
  failing with the pre-fix signature (rc=125, EACCES, no repair
  announcement) while every later run — battery-filtered and standalone —
  was green. Never reproduced; interference from the concurrent session
  during that battery is suspected. Named unproven, not fixed.

## 2026-09-23 (log ownership) — a root-mode crash poisoned the next run's logs; state ownership is now settled at write time

- **Symptom**: run A (`sudo fish build-all.fish …`, started 19:10) was killed
  mid-flight at 19:34. Run B — unprivileged `fish build-all.fish -g
  stable,core,git,third-party -s -i` at 22:33 — died in seconds:
  `✗ util-linux / dbus / libisl-git: BUILD FAILED (rc=125, 0m00s)`, each row
  preceded by fish's `warning: An error occurred while redirecting file
  '.state/logs/<pkg>.log' / open: Permission denied`. Exactly six logs were
  `root:root` (run A's in-flight set), `.state/` itself was root:root, and
  `linux-api-headers` — user-owned log — built fine.
- **Root cause**: every log open happens in the SUPERVISOR's shell, so root
  mode created files root-owned at birth: the lane-spawn
  `printf '' >"$child_log"` and `… >>"$child_log"` redirect,
  build_package's truncate, the makepkg append
  `sudo -u … makepkg >>"$log_file"` (fish opens the redirect before sudo
  drops privileges), and `tee -a` in `install_pkgs_now`. The only repair was
  `chown -R "$_BUILD_USER": "$pkg_path" "$LOG_DIR"` at build_package EXIT —
  a crash window: a killed run leaves exactly its in-flight logs poisoned,
  and the next unprivileged run dies at the SAME redirect (rc=125) before
  build_package's `cannot write build log:` probe can print anything — hence
  every row claiming 0m00s. `$_STATE_DIR` appears in NO chown argument,
  which is the measured post-crash asymmetry: `.state` stayed root:root
  while `logs/` had already been repaired by an exit chown.
- **Fix — ownership is decided when a file is OPENED** (three helpers in
  `build-all.fish`):
  - `ensure_state_dirs` (startup, and at every former `mkdir -p "$LOG_DIR"`
    site): root mode sweeps `chown -R "$_BUILD_USER": "$_STATE_DIR"` —
    directories *and* files an earlier interrupted root run left behind;
    unprivileged mode refuses to run when `LOG_DIR` is not writable, naming
    the file/owner and the exact `sudo chown -R` remedy (`log_ownership_hint`).
  - `ensure_log_writable <file>` (before every state-file create, truncate or
    append): root mode repairs a wrong owner **in place**, loudly
    (`⚠ repaired root-owned runtime file:`), and creates missing files with
    `sudo -u "$_BUILD_USER" touch` — never as root, because root creation is
    precisely what poisons the next run (no fallback to root on failure).
    Unprivileged mode cannot chown, so an unopenable file is QUARANTINED to
    `<path>.stale.<epoch>.<pid>` — a rename needs only directory write — with
    a `⚠ preserved unopenable log:` announcement; the crashed run's forensics
    are moved aside, never truncated. Root mode deliberately checks OWNER
    only: real root can write a mode-0444 file, so mode is not the poison.
  - Sites wired: lane spawn (before any lane state exists; a preparation
    failure stops dispatch and is counted in `failed[]` so the run exits
    non-zero), build_package, the `install_pkgs_now` transcript (before
    pacman runs — rule-11 forensics must be recordable or the install is
    refused), `write_lane_result`'s tmp (chowned before the atomic publish —
    the `pkg rc seconds` protocol is untouched), the pacman-shim tmp, and
    `dispatcher.log`/reap/escalate/signal forensics as guarded best-effort
    (report, don't break, the run being recorded). The pacman mutex is the
    stated exception: never rename a possibly-held lock inode — root
    pre-creates it as the build user, unprivileged runs only verify readable
    (flock(1) opens read-only; measured: `flock -x` succeeds on a 0444 file).
  - `install-all.log` is a dead variable (`run_pacman_locked` never opens
    its `log_file` argument); documented at the site instead of invented.
- **Validation**: `tests/log-ownership.sh` (unprivileged quarantine contract:
  sentinel preserved under `.stale.*`, no rc=125, no redirect error, run
  green; red before the fix) and `tests/log-ownership-root.sh` (root-mode
  in-place repair: per-file non-`-R` chown naming the poisoned log, loud
  announcement, no quarantine, run green; red before the fix) — the fixture
  cannot chown to root, so the poison is a 0644 log whose owner a `stat`
  stub reports as root, which is exactly the predicate the builder tests.
  Full battery green: 43/43 fixtures on the final tree, both log-ownership
  halves included — `srcinfo-freshness` was closed by regenerating the two
  `.SRCINFO`s whose PKGBUILDs the run-B auto-sync bump had invalidated
  (`linux-firmware` 20260916, `linux-tools` 7.2.7: `makepkg --printsrcinfo`,
  the recipe-checklist follow-through); `--audit`, `--list` and three
  dry-runs (git/stable/core) green. See the 2026-09-24 harness entry for the
  `sudo-keepalive` fake-clock race and the battery-concurrency rule. Live on the real tree: `sudo chown root:` on
  `linux-api-headers.log`, then the unprivileged `-s` run quarantined it
  loudly and finished `All builds succeeded!` (rc=0, no rc=125); the documented
  `sudo chown -R zhangdm: .state` remedy then restored the whole state tree.
  Two run-A leftovers that broke `nvcheck-aggregator` were also repaired:
  `noctalia-git/pkg` and `vscodium-insiders-git/pkg` sat at mode 0111
  (owner without read → `find` EACCES).
- **Durable rule**: every `$LOG_DIR` open site must go through
  `ensure_log_writable` before the first redirect touches the file; state
  directories only through `ensure_state_dirs`; root never creates a state
  file directly; the mutex inode is never renamed. Forensics appends stay
  best-effort (guarded), everything else fails named.

## 2026-09-24 — the signal finally named itself: a window close is a TERM, and it half-committed pacman's local db (vscodium-insiders)

- **Symptom (user report)**: "error happened during create package phase" —
  `vscodium-insiders-git.log` shows makepkg's `.BUILDINFO` generation printing
  `error: could not open file /var/lib/pacman/local/vscodium-insiders-git-…/desc`,
  then the build finishing fine, then the lane's install failing with
  `could not fully load metadata` → `error: failed to prepare transaction
  (invalid or corrupted package)` (rc=1) → `✗ Install failed`.
- **Root cause chain (every step measured)**:
  1. **The phase-3 forensics worked on their first real incident.**
     `.state/logs/dispatcher.log` (workspace) records
     `2026-09-24T17:50:30 [DEBUG-gsa-term] signal: TERM received …
     chain=fish ← sudo ← systemd --user(1516) ← init` + `cleanup … stop begin
     reason=interrupt pkg=vscodium-insiders-git … Build interrupted`. PID 1516
     confirmed `systemd --user`: the launching shell was already gone (sudo
     orphaned), so this is **systemd user-scope teardown SIGTERMing the run —
     closing the terminal window kills the build**. The identical chain marks
     17:07, 17:28 and 17:50 today and retroactively answers 2026-09-23's
     unnamed 19:34:01 mass-TERM. The "lane watching" suspicion is exonerated
     by the lane's own log: the cleanup path ran exactly as designed.
  2. That run's `pacman -U` logged `[ALPM] transaction started` at 17:50:27
     and was TERMed ~3 s later **mid-commit**: the local entry directory was
     left containing **only `mtree`** (no `desc`, no `files`), the package
     half-removed (`/usr/share/…` present, `/usr/lib/vscodium*` gone), no
     `db.lck` (pacman unlocked but could not roll the local dir back). A
     system-wide scan showed exactly this one desc-less entry.
  3. From then on the entry was unusable **in every direction**: `pacman -U`
     and `-R` and `-Ql` and makepkg's `.BUILDINFO` probe all hard-fail on the
     missing members — and pacman's headline error, `invalid or corrupted
     package`, **indicts the archive, which was perfectly fine**. That
     misdirection is what made the failure look like a packaging bug.
- **Repair (approved, executed)**: `cp -a` backup of the dangling dir to
  `/tmp/vscodium-dangling-entry.bak` → `sudo rm -rf` the entry (it contains no
  `desc`, so no scriptlet can ever run for it; `-R` cannot read it either) →
  `sudo pacman -U --noconfirm --overwrite '*' <existing archive>` — the plain
  `-U` refused exactly as predicted because the half-removed package's
  orphaned `/usr/share/vscodium-insiders-git/**` files now belong to no
  package (the documented `-ia --overwrite '*'` house escape hatch). Verified:
  `pacman -Qk` → `2857 total files, 0 missing files`, `-Ql` lists, desc rescan
  empty, no `db.lck`, hooks ran.
- **Prevention (`build-all.fish`)**: `check_pacman_db_health <local-dir>` —
  scans `$(pacman-conf DBPath)/local/*/` for entries missing `desc` **or**
  `files` (both are universal on a healthy box: measured 1754/1754), gates on
  the same holder double-probe as `check_pacman_lock` (a live transaction may
  legitimately be mid-commit → report-only), and removes loudly only when
  idle-twice, naming the entry, the interrupted-commit cause, and the
  reinstall step (`-s -i`/`-ia`). New `pacman_db_path`/`pacman_db_local_path`
  helpers keep one `pacman-conf DBPath` seam (fixtures never see the host
  db). Wired at the same four sites as the lock probe: `check_runtime_prereqs`
  (refuse `-i`, warn build-only), `install_all` (refuse `-ia`), the interrupt
  teardown (the exact aftermath window), and `run_pacman_locked`'s failure
  path (repair right where the misleading error surfaces). Hidden seam
  `--local-db-check <path>` (same precedent as `--stale-lock-check`; no
  `GSA_*` knob).
- **Validation**: `tests/local-db-repair.sh` — six phases (idle removal +
  warning text, holder-kept + pid/cmd + manual recovery, healthy entry
  untouched while a broken sibling is removed, desc-without-files shape,
  empty/absent dir, static seam+4-site pins); **falsified before trusted**
  (neutering the `rm -rf` makes phase 1 fail; restored → PASS). `fish -n`,
  `--audit`/`--list`/dry-runs, full battery green; live host repair verified.
- **Durable rules**: closing the terminal window is a SIGTERM to the entire
  run — long builds belong in a terminal you keep open (tmux) or must expect
  termination at window close; dispatcher.log names the sender, so a dead run
  is diagnosed from it first. `invalid or corrupted package` (plus a raw
  `desc` open error in `.BUILDINFO`) indicts the **local db**, not the
  archive: a desc/files-less `local/` dir is the signature of an interrupted
  `-U` commit, healed only by entry removal + reinstall — the builder now
  does both, loudly, when the box is provably idle.

## 2026-09-23 (night) — lanes died to an unnamed signal, the abort corrupted pacman, noctalia's training never ran, and zen trained on Speedometer 2.0

One report, three isolatable defects, fixed by three parallel agents.

### A. Builder: unexpected TERM, rc=125 "invalid outcome", and the lock storm they fed

- **Symptom**: a `sudo fish build-all.fish … 25..` run (started 19:33:53) had
  its dispatcher and all six lanes die **simultaneously at 19:34:01** —
  `dbus.log`, `util-linux.log`, `vencord-git.log`, `libisl-git.log`,
  `xcb-imdkit-git.log`, `texlive-texmf.log` all show `ERROR: TERM signal caught`
  mid-`git clone`/mid-`pacman -S`. The user account for exactly one interrupt
  all evening (a wrong `14..` range, ^C); for this event they did nothing.
  Follow-on: six logs of `waiting for builder pacman mutex → could not lock
  database: File exists` killed the next run in 5 s, and the recurring
  complaint was a lane raising `lane supervisor produced no valid result`
  (rc=125) *after pacman had installed successfully*.
- **Root cause chain, established from the journal, `sudo` session gantt, and
  fish history** (all runs sequential on pts/0 — no overlap):
  1. In code the dispatcher TERMs lanes only via `cleanup_active_lanes`,
     which runs **after the dispatcher itself receives INT/TERM** (the
     malformed-result branch's message appears in no log). So the dispatcher
     was signalled — by whom is **not provable post-hoc**: nothing in
     `build-all.fish`, no second run, no timer, no session teardown. One ^C
     is admitted; the 19:34:01 signal source remains unidentified, so the fix
     makes the *next* incident self-identifying instead of guessing.
  2. Lane children ran the dispatcher's `handle_interrupt` (INT+TERM bound to
     a bare flag-setter) and therefore **swallowed** signals, and a child
     killed before `write_lane_result` produced the rc=125 "invalid outcome"
     with no clue why.
  3. `stop_lane_process` TERMed every PID in the lane PGID **every 50 ms,
     SIGKILL at ~0.5 s**. A pacman caught in that blast was re-signalled
     while unlocking, so it never removed `/var/lib/pacman/db.lck` (dir mtime
     19:34; cleaned by hand via pkexec at 19:34:33) — the stale lock is what
     made every later install hard-fail. Independently, makepkg's own `-s`
     dependency installs run `pacman` **outside** the builder flock (six
     dep-pacmans raced the builder's `pacman -U` at 19:33:58; `util-linux.log`
     shows pacman politely waiting, the `-U` side failing).
- **Fix (`build-all.fish`)**:
  - Handlers split: `gsa_on_int/term/hup` → `gsa_handle_signal`. Dispatcher
    mode appends timestamped `[DEBUG-gsa-term] signal: … (pid, ancestry)` to
    the new **`$LOG_DIR/dispatcher.log`** then sets `_INTERRUPT_HANDLED` as
    before; **HUP is newly bound** (it used to orphan live lanes silently).
    Lane mode (marker set at `--lane-job` entry) writes an honest result
    (`129/130/143`) + `lane child received <SIG>` to the package log and
    re-raises — fish's `exit` inside a handler always yields rc 0, so the
    child erases its handler and re-raises; INT is the exception (fish exits
    0 even handler-less), which is why the result *file* carries the honest
    130: the dispatcher reads only that file.
  - `stop_lane_process`: **one** TERM sweep, deadline-based `_LANE_STOP_GRACE_S
    = 30` (0.1 s polls that `ps` cost cannot stretch), single SIGKILL of
    survivors afterwards, escalations logged to dispatcher.log *and* the
    package log; zombies excluded from `lane_processes`. The WHY-comment
    cites this incident: the old 50 ms blitz re-interrupted pacman's unlock.
  - Reap forensics: a missing/malformed result now records the lane pid's
    `ps` state plus the escaped raw result bytes (and an empty pid list no
    longer silently skips the statement — fish drops commands whose
    substitution failed).
  - `check_pacman_lock`: holder probe (PATH-stubbable `pgrep` on
    pacman/packagekitd/pamac) with recovery instructions, **never removes
    while a holder is alive**; removal only after two idle probes 1 s apart,
    loudly. Path from `pacman-conf DBPath` (fallback
    `/var/lib/pacman/db.lck`) so fixtures never touch host state; hidden
    `--stale-lock-check <path>` mode is the fixture seam (no new `GSA_*`
    knob — the builder still honours exactly seven). Wired into
    `check_runtime_prereqs` (refuse `-i`/`-ia` while busy, warn build-only),
    `install_all`, after `cleanup_active_lanes`, and `run_pacman_locked`'s
    failure path. *Reconciliation*: the older report-only todo said "NEVER
    remove"; the user's later explicit approval chose idle-removal — both are
    honored (report always, remove only when provably idle), recorded in the
    code comment.
  - `ensure_pacman_shim`: install runs generate `$LOG_DIR/.pacman-shim` (0755,
    baked absolute mutex, `flock -x -w 300 /usr/bin/pacman "$@"`) and
    `lane_job` exports `PACMAN=<shim>` (makepkg honours `PACMAN=${PACMAN:-pacman}`,
    verified at `/usr/bin/makepkg:1203`) — makepkg's dep installs now
    serialize on the builder mutex. Leaf/no-deadlock: `run_pacman_locked` is
    flock→pacman directly.
- **Validation**: `fish -n`, `--audit`, `--list`, dry-runs git/stable/core
  (58/29/41) all pass; new fixtures `tests/signal-abort-lock.sh` (stale/busy
  lock probe, honest `143` result instead of rc=125, INT/TERM/HUP → exit 130 +
  named signal in dispatcher.log + exactly-one-TERM + zero survivors,
  busy-preflight `-i` refusal, static 30 s/one-TERM/KILL-after-grace shape)
  and `tests/pacman-mutex-shim.sh` pass; manual PTY proofs: interrupt exits
  130 with SIGKILL at exactly +30 s. `tests/dashboard.sh` case C was rebased
  (6 s → 60 s deadline, stub ticks 300 → 900): the old bound encoded the very
  TERM-blast being removed — the stub lanes now run ~45 s so the post-grace
  KILL, not their own loop, is what ends them.
- **Durable rules**: a run's signal story must be readable after the fact —
  dispatcher.log names the signal, the result file names the lane's death;
  rc=125 without forensics is a bug. Never blast-TERM a process group that
  may hold a package database lock: one TERM, grace, then KILL. Every pacman
  invocation a lane can reach (yours *or* makepkg's) goes through the one
  flock.

### B. noctalia-git: the training sway died on `sun_path`, so PGO never trained

- **Symptom**: `==> WARNING: PGO profile incomplete (1 .gcda files)` then
  `ERROR: Value "none" … not one of the choices. Possible choices … "off",
  "generate", "use"` → `A failure occurred in build()`.
- **Root cause**: `_pgo_train` sandboxed `XDG_RUNTIME_DIR` under the deep
  `$srcdir/pgo-work`; sway's `sway-ipc.<pid>.<rand>.sock` then exceeded the
  **108-byte Unix `sun_path`** (`src/pgo-work/sway.log`: `Socket path won't
  fit into ipc_sockaddr->sun_path`; journal shows the training sway SEGVing at
  19:29:48 and 19:33:20 — the second was the user's manual `makepkg -si`).
  Dead sway → no GUI workload → 1 `.gcda` → the fallback's
  **`-Db_pgo=none`, a value meson does not have** (the enum is
  off/generate/use) hard-failed the build.
- **Fix**: fallback → `-Db_pgo=off`; `XDG_RUNTIME_DIR` now
  `mktemp -d /tmp/nct-pgo-rt.XXXXXX` (700, removed on exit — house precedent
  mold-git/easyeffects-git train under `/tmp`); the training tree launches
  under `setsid` and is torn down as a **group** (TERM → 5 s bounded grace →
  KILL) so no stray sway survives; CLI subcommands run `env -u WAYLAND_DISPLAY`
  so they always take the exit-through-main() path that flushes profiles.
  `pkgrel=2`, `.SRCINFO` regenerated.
- **Validation**: acceptance build `fish build-all.fish --no-deps noctalia-git`
  exit 0 (7m36s): **315 fresh `.gcda`** (baseline cleared first), log says
  `PGO profile collected (315 …)` + meson `b_pgo : use`, zero `sun_path`
  errors in the new sway.log, no journal SEGV, no strays, no `/tmp/nct-pgo-rt.*`
  leftovers. Fixtures `tests/noctalia-pgo.sh` + `tests/noctalia-pgo-train.sh`
  pass and were red-checked against the old PKGBUILD.
- **Pitfalls pinned**: sandbox paths have a **length budget** — anything a
  compositor/socket puts in `XDG_RUNTIME_DIR` must fit `sun_path`; and stock
  `update_pkgver()` rewrites the PKGBUILD and **resets `pkgrel=1`** whenever
  `pkgver()` moves — for `-git` recipes bump `pkgrel` after the first
  post-sync build (this build moved r5568→r5570 and undid the bump once).

### C. zen-browser: profile collection ran deprecated Speedometer 2.0

- **Symptom/decision**: the PGO profile phase's workload entry was the
  deprecated **Speedometer 2.0** with a single scenario; user decision
  *sp3-only* — replace it, keep everything else.
- **Audit (1.07 GB `zen.source.tar.zst`, 1.22.3b = FF156 base)**: the tree
  *already* carries a correct SP3 setup — `profileserver.py` starts
  `sp3_httpd` on port 8000 with docroot `third_party/webkit/PerformanceTests/Speedometer3`
  (a real 62 MB tree; `params.mjs` honours `startAutomatically`) plus the
  `http://localhost:8000/index.html?startAutomatically=true` entry with the
  120 s extended timeout. SP3 **requires a root path** ("will fail if it is
  not"), which is exactly why the second httpd exists — so the planned
  relative `webkit/…` entry would have been wrong. The fix is therefore a
  deletion: `0007-pgo-speedometer3.patch` removes only the SP2 entry (zero
  additions), applied in `prepare()` after 0004/0005; `pkgrel=2`.
- **Bonus finding**: `sha256sums[0]` was still the **1.22.1b** sum — commit
  `5f4078b` (update zen upstream track) bumped `pkgver` without re-pinning the
  tarball, so the recipe could not have fetched at all. Re-pinned to
  `5dafd8ae…`, verified against **GitHub's server-side asset digest** (exact
  hash + 1,068,387,924 size — anchored, not TOFU); `.SRCINFO` regenerated
  (was stale at 1.22.1b too). Root `.gitignore:21 *.tar.*` already covers the
  fetched tarball.
- **Validation**: `tests/zen-pgo-workload.sh` + `tests/zen-pgo-speedometer.sh`
  pass (red-checked on drift), real-tree `patch -Np1 --dry-run` rc=0,
  `bash -n` clean; the full three-pass build is deliberately left to the
  user's next big run (the fetched tarball is kept as its resume cache).
- **Durable rule**: an upstream-track bump that changes `pkgver` must re-pin
  every version-spelled sum in the same commit, and a benchmark swap must
  check *root-path* requirements before choosing a URL shape.

### D. Battery and cross-lane integration

Three agents worked disjoint file sets (`build-all.fish`+fixtures;
`packages/git/noctalia-git`; `packages/third-party/zen-browser-pgo`+fixtures),
each running only its filtered fixtures; the parent ran the **full battery
once: 41 fixtures** — 40 pass, `recipe-sources.sh` flags the new untracked
`0007-…patch` until it is committed (by design: sources must be committed).
The sweep also caught a **pre-existing** stale `.SRCINFO` on `gcc-snapshot`
(from `8dd4f46 update gcc upstream track`) — regenerated mechanically.

## 2026-09-23 — vencord-git initiates injection: wrapper + official-compatible shim, and the scriptlet phases have no fallback

- **Symptom**: phase 1 (`f5811c1`) shipped the payload only — the installed
  files were inert, exactly the "stale scripts" reported. Worse, the host had
  already been injected by the *official* installer (root-owned shim written
  10:58 requiring `~/.config/Vencord/dist/patcher.js`, its own downloaded
  copy), so nothing at all pointed Discord at the pacman-owned
  `/usr/lib/vencord`.
- **Root causes (three)**:
  1. the official installer cannot be repointed at a pacman payload — it
     downloads its own Vencord build into `~/.config/Vencord/dist` and would
     hit EACCES writing under `/usr/lib` as a user;
  2. this host's `discord` is the self-updating bootstrap — every self-update
     lands a pristine `app-*/resources` tree, so any one-shot patch dies on
     the next update;
  3. **pacman has no scriptlet-phase fallback**: an upgrade calls
     `pre_upgrade`/`post_upgrade`, never `pre_install`/`post_install`. Proven
     live — the pkgrel=2 upgrade executed nothing (no output, desktop
     unwrapped) even though `pacman -Qp` reported "Install Script: Yes"
     (pacman 7's `.PKGINFO` has no `install =` key at all; the `.INSTALL`
     archive member is the scriptlet, and PKGBUILD(5) names each phase).
- **Fix (`pkgrel=3`, all in `packages/git/vencord-git/`)** — the initiation
  contract:
  - `vencord-inject` (python, stdlib only): byte-equivalent port of the
    official `WriteAppAsar` — verified against the *live* official shim
    (identical framing `4I` header, identical JSON shape, round-trip parse).
    `inject` renames `app.asar`→`_app.asar` on a pristine tree and always
    rewrites the shim to `require("/usr/lib/vencord/patcher.js")`, so it is
    idempotent **and** adopts an official-installer patch in place;
    `uninject` restores the original bytes; `status` exits 0 only when the
    newest `app-*` of every `discord*` channel under `$XDG_CONFIG_HOME` is
    injected against the payload. Root policy mirrors upstream: never bare
    root, `SUDO_USER`/`DOAS_USER` HOME adopted, root-written files chowned
    back (verified: env survives pacman's scriptlet sandbox).
  - `discord-vencord` wrapper: re-asserts injection on **every launch** —
    this is what survives Discord self-updates — then `exec`s the stock
    launcher with args intact; injection failure is non-fatal.
  - stock `discord.desktop` `Exec=` redirect **without shipping that path**
    (a shipped file would file-conflict with the `discord` package):
    `post_install`/`post_upgrade` wrap it, a Path-trigger libalpm hook
    re-wraps after every discord install/upgrade (house gtk4/glib2 pattern,
    format compared), and `pre_remove` — the house cleanup phase (7
    `pre_remove` vs 2 `post_remove` in this repo; `post_remove` runs after
    the package's own files are already deleted) — unwraps **and** unpatches
    so a removal never leaves a shim requiring a missing `patcher.js`.
  - `depends=('python')`, four local sources sha256-pinned, `.install` and
    hook committed as recipe assets.
- **Validation**: `tests/vencord-recipe.sh` now pins the initiation assets,
  the `python` depend, the no-client-hard-depends rule, `pre_remove` cleanup
  and **the `post_upgrade` presence** (the no-fallback lesson); the new
  `tests/vencord-inject.sh` proves inject/status/adoption/idempotence
  (sha-stable)/interrupted-state repair/byte-exact uninject/fresh-bootstrap
  no-op/desktop wrap+restore idempotence/absent-file no-op/wrapper
  arg+exec-through on scratch `$XDG_CONFIG_HOME` trees; full battery
  **PASS 34 → 35**; then the **full live lifecycle on this host**:
  `pacman -R` → `pre_remove` restored the pristine `app.asar` and the stock
  `Exec=`, fresh `-U` → `post_install` message + wrapped `Exec=` + live shim
  repointed to `/usr/lib/vencord/patcher.js` (`status` rc 0), same-version
  `-U` → `post_upgrade` re-ran the same body with sha-identical results;
  `pacman -Dk` clean. Two measurement traps while testing: a `pacman -R`
  without `--noconfirm` aborts silently at the prompt (read the state, not
  the pipe's exit code), and a log filter keyed on the word `upgrading`
  misses pacman's actual `reinstalling` line.
- **Rules**: (1) the payload is inert until injected — initiation is part of
  this package's job, not the user's; (2) any `.install` action that must
  happen on upgrades needs the upgrade-phase function names; (3) scriptlets
  must be exercised through real transactions — install **and** upgrade
  **and** remove, because each phase is a separate entry point; (4) never
  ship a file at another package's path — redirect through a Path-triggered
  hook that edits content in place.

## 2026-09-23 — new `app` group: a TTY multi-select prompt as a layer in front of the normal selection pipeline

- **Decision (user-confirmed)**: isolate a sixth logical group `app` for
  optional applications drawn from the git/third-party/stable categories —
  mechanism only, membership wired separately. Four confirmed behaviors:
  (1) app packages are **leaf builds, never `expand_deps`** — they are ABI
  *consumers*, so installed dependencies are assumed current and a local
  dependency edge must not drag a costly chain into the run; (2) non-TTY stdin
  skips the prompt and builds the whole group; (3) the prompt is a
  fish-native numbered toggle loop (no fzf/gum dependency); (4) it triggers on
  real builds and `-n` only — `-l` lists the whole group, unprompted.
- **Design**: `prompt_app_selection` prints the menu on **stderr** (stdout is
  the data channel the seam captures) and returns checked-only, or the whole
  group when everything is unchecked (all-unchecked = build all; `q` aborts
  non-zero). The seam sits immediately after `resolve_group` in the `-g` loop:
  whatever comes back becomes that group's contribution to `build_list`, and
  topo sort, ranges, lanes, install are the unchanged existing pipeline.
  Group selections were *already* leaf selections — `expand_deps` only runs
  for positional names — so requirement (1) needed pinning, not new blocking
  logic.
- **Bug found while testing (empty-group phantom)**: fish `printf` with **no
  arguments still runs the format once**, so an empty `app.list` produced a
  phantom `""` member: `resolve_group` emitted one newline, `topo_sort` read
  `""` as a package and reported `blocked: (empty)`, and the final
  `printf '%s\n' $sorted` re-injected it at the output seam ("Total: 1
  packages" with an empty entry). Fixed in all three places: the `app` case
  prints only when non-empty, `topo_sort` drops empty input tokens, and its
  output is guarded. An empty `app.list` now warns (`populate
  config/groups/app.list`) and exits non-zero with the standard no-selection
  error.
- **Fixture learnings (`tests/app-group.sh`, PTY via `script -qec`)**:
  (a) emptying `app.list` with single-membership members trips the loader's
  "listed in no group" rule *before* the seam — mirror reality (members keep
  their category group) by moving them aside for that scenario; (b) fish's DA
  terminal query has no responder under `script`'s PTY and **consumes the
  piped toggle input as bogus query replies** (the `2` vanished mid-exchange,
  the next read hung until timeout) — run the PTY scenarios with `TERM=dumb`,
  which skips the queries while the FD-level `test -t 0` the seam keys on
  stays true; (c) the PTY slave maps `\n`→`\r\n` (ONLCR), so extracted fields
  compare as `app1\r` — strip CR before string comparisons. Also: an inverted
  `[ ! -f ] && fail` assertion "passed" whenever the file was correctly
  absent — assertions of absence need the positive form.
- **Wiring**: six group files exactly (`app.list` starts comments-only);
  `project-config.sh` now pins six, the ten synthetic-workspace fixtures loop
  six names, and the loader/resolve/help/audit/bare-list enumerations all
  gained `app`. No auto `-i` for app (unlike core — consumers, not ABI
  providers).
- **Validation**: `fish -n`; `--audit`, `--list`, `-n -g git|stable|core`
  green; empty `-n -g app` refuses with the hint; `bash tests/run-all.sh`
  (full battery, incl. the new fixture — loader strictness, empty-list
  refusal, non-TTY whole-group + no-expansion pin, `-l` silence on a PTY,
  Enter/toggle/`q` on a PTY, combined `-g app -g git`, real-build subset).
- **Durable rules**: `config/groups/` holds exactly six files; `-g app` is a
  leaf selection whose prompt is a front-layer filter (never re-plumb the
  pipeline for it); the prompt reads stdin only after `test -t 0`, so pipes
  can never hang.

## 2026-09-23 — added `vencord-git`: desktop standalone Discord client mod in the git group

- **Scope decisions (user-confirmed)**: package https://github.com/Vendicated/Vencord
  as `packages/git/vencord-git` with the **desktop standalone artifacts only**
  (`pnpm buildStandalone` → the six bundles → `/usr/lib/vencord`); no web build
  and no browser-extension outputs. `check()` runs `pnpm testTsc` (type-check
  only — upstream's full `pnpm test` also re-runs eslint, stylelint and the
  plugin-manifest generator on every git bump). Fixture, host IgnorePkg entry
  and docs shipped in the same change.
- **Recipe**: root `pnpm install --frozen-lockfile` — Vencord's root
  `pnpm-workspace.yaml` declares `packages/*`, so a *subdirectory* install
  would need the workspace-isolating flag (the 2026-09-18 logseq incident);
  there is no subdirectory install here, and `tests/vencord-recipe.sh` pins
  that guard's absence. `arch=(any)`, `provides`/`conflicts` = `vencord`, and
  **no hard depends**: `discord`/`vesktop` are optdepends because the loader is
  a host choice — a deliberate divergence from the AUR recipe, which
  hard-depends on `vesktop` (not installed here). `package()` writes the
  `package.json` shim beside the payloads (loader contract, AUR parity).
- **Optimization (MEMORY §4 Electron/JavaScript bullet)**: `options=('!strip'
  '!debug' '!lto')` — nothing ships compiled except esbuild's prebuilt helper —
  plus the house ccache + mold probe for any incidental native addon, and no
  hard-coded ISA/optimisation flags of its own. Upstream honours
  `SOURCE_DATE_EPOCH` (`BUILD_TIMESTAMP`), so makepkg's stamp is baked in.
- **Wiring**: one `packages.map` record, one `git.list` member, one lone
  `dependencies.conf` record (no workspace edges — git/nodejs/pnpm come from
  the host repos). `build-all.fish` needed **no code change**: the loader
  revalidates the whole map/graph/sort on every invocation, and `--audit`,
  `--list` and the three group dry-runs went green with the record in place.
- **Host**: `/etc/pacman.conf` backed up to
  `/etc/pacman.conf.20260923-vencord.bak` first, then `IgnorePkg =
  vencord-git` inserted **inside `[options]`** (after the last IgnorePkg
  line; a line in a repo section is silently dropped). Closure check per the
  2026-09-19 audit — `comm -23` of the `.SRCINFO` **pkgname set** vs
  `pacman-conf IgnorePkg` — is empty again. Note the pkgbase-only names
  `fcitx5-qt-git` and `texlive-texmf` are *not* gaps: they are non-installable
  split bases whose outputs (`fcitx5-qt5/6-git`, 24 `texlive-*` splits) are
  covered.
- **Counts were already stale before this change**: the README claimed
  126 recipes / 129 memberships / git 56, but measuring (find PKGBUILD,
  group-line sums) showed 127 / 130 / 57 pre-change — an earlier addition
  never updated them. Corrected to the measured post-change truth:
  **128 recipe directories, 131 group memberships, git 58** (stable 29,
  core 41, misc 1, third-party 2; `hip-runtime`/`hsa-rocr`/`openssl` are
  deliberately double-listed, so 131 sums to 128 distinct members).
- **Validation**: `bash -n`; `makepkg --printsrcinfo`; `--audit`/`--list`/
  dry-runs for git, stable and core all rc=0; full fixture battery **PASS
  (33 fixtures**, 32 → 33 with `tests/vencord-recipe.sh` pinning assets,
  source, stage order, the optimisation standard, topology membership,
  gitignore visibility and `.SRCINFO` freshness); a **real build**
  (`--no-deps --no-sync vencord-git`) finished green in 1m54s — makepkg
  wrote `pkgver=1.15.6.r4.g59a542865` back into the PKGBUILD, and the
  archive `vencord-git-1.15.6.r4.g59a542865-1-any` (1.6 MB) was inspected:
  all six bundles + css/maps/`.LEGAL.txt`, the shim, LICENSE and README are
  present, and `.PKGINFO` carries `conflict = vencord`, the optdepends and
  the makedepends. **No install was performed.**
- **Rules**: (1) `~/.makepkg.conf` sets `BUILDENV=(… !check …)`, so makepkg
  skips **every** recipe's `check()` on this host — the stage was validated
  by running `pnpm testTsc` manually against the built tree (rc=0, 13.5 s);
  do not read a missing `Starting check()...` line as a recipe defect.
  (2) Never edit the README/MEMORY counts from memory — measure first; the
  baseline was already off by one. (3) pnpm's `configured to use 11.9.0 …
  your current pnpm is v11.26.0` warning is cosmetic (install, type-check
  and build all proceeded).

## 2026-09-22 — `noctalia-git` carries the upstream idle fix, so locking stops waking the display

- **Bug** (owner-reported, reproduced here): with `dim 50 s → screen off 70 s → lock 120 s`, the lock
  lit the panel back up and the whole chain replayed. Root cause is in Noctalia, not in the config:
  `IdleManager::setSessionLocked()` → `recreateBehaviorNotifications()` →
  `recreateBehaviorNotification()` ran `runResumeBehavior()` for every behaviour whose
  `phase == BehaviorPhase::Idled`, then destroyed and recreated the notification.
  `action = "screen_off"` hard-wires `resumeAction = ScreenOn`
  (`resolveIdleBehaviorActions()`), so a `screen_off` that had already blanked the display powered the
  monitors back **on** at the lock, `dim`'s `resume_command` restored the backlight, and every
  countdown restarted from the lock instant.
- **Evidence, not logs**: `/sys/class/drm/card1-eDP-1/dpms` (kernel DRM state) goes `Off` at the
  blanking stage and **back `On` 36 ms after** `[lockscreen] session is locked`, with
  `idle behavior notifications re-armed` following at `+0.31 s`. Chain shortened to 10/15/20 s so a
  cycle takes 20 s; reproduced twice on demand.
- **Upstream, not bespoke**: issue **noctalia-dev/noctalia#4190** (open, `niri`) and PR **#4002**
  (`mergeable`, "Closes #4190"). The PR was built and verified on niri from this host — panel stays
  `Off` across the lock, no replay, backlight still restored on real input — and a review plus an
  approving review were submitted upstream, together with the reproducer on #4190. **This recipe is a
  stopgap for one host until that PR merges.**
- **Change**: `prepare()` applies
  `0001-idle-lock-resume-and-inhibit-tracking.patch` with `git apply -3`, following the
  `xwayland-satellite-git` convention (`source=(... patch)`, `sha256sums` + verified hash). The patch
  is PR #4002's diff unchanged, applied against `main` at `e7acd06`; plain and 3-way application were
  both pre-flighted. `.SRCINFO` regenerated with `makepkg --printsrcinfo` — the patch appears as a
  source, as it does for the sibling package.
- **Why the host, not the recipe class**: `noctalia-git` is foreign and already in `IgnorePkg`, so a
  locally built package survives updates; a `stable` recipe here would have had to pin a moving VCS
  ref. Built with `./build-all.fish --no-deps -i noctalia-git` (9m08s), installed, shell restarted the
  niri way (`kill <pid>` + `niri msg action spawn -- noctalia`); the running binary reports
  `v5.1.0-70-ge7acd065406b-dirty`, where `-dirty` is the marker that the patch is in.
- **Removal**: delete the patch, the `source`/`sha256sums` entry and `prepare()`, and regenerate
  `.SRCINFO`, once #4002 lands. The `-dirty` suffix in the version string is the reminder.
## 2026-09-20 — `build-all.fish` audit: the harness was misreporting its own success

- **Scope**: a full static read of `build-all.fish` (3561 lines, 73 functions)
  against the documentation that describes it, plus the fixtures that were
  supposed to pin it. Baseline `75bd2f6`. Fixture count 26 → 32. Repairs only:
  no behaviour was redesigned, and no real build was run, so **every finding
  here is proven by static reading or by a fixture, never by a completed
  build**.
- **Root cause, one family**: almost every defect was the builder making a
  **claim about its own work that was not true**. Not a crash and not a wrong
  build — a false report of success, of verification, or of coverage. That
  shape is why they survived: a check that cannot fail its caller reports
  success whether or not the thing it checks happened, and nothing downstream
  contradicts it.

Findings, in the order they were fixed:

1. **`-i` reported success while pacman never ran** (`8a7a672`).
   `list_split_pkgs` read `pkgver=` with `grep | cut | string trim -c "'"`,
   which keeps a trailing PKGBUILD comment, so the split-archive pattern
   matched nothing; `install_pkgs_now` then treated *no arguments* as success.
   Reproduced end-to-end before touching anything: the run printed "All builds
   succeeded!" and `pacman.log` stayed empty. Two defects hiding each other —
   neither is visible alone. Fixed with `pkgbuild_var()`, which parses a *value*
   rather than text (strips an unquoted trailing comment — `x=1#2` is one word
   in bash, so the strip requires leading whitespace — and either quote style,
   and whose every stage is fed by the pipeline above it so no stage can fall
   back to reading stdin, which interactively is the terminal). Used for
   pkgver/pkgrel/pkgbase in `list_split_pkgs` and `sync_stable_version`, where
   the same defect bit from the other side: a trailing comment made an
   already-current stable recipe differ from the repo version on **every** run,
   so it was rewritten each time and a garbage operand reached `vercmp`, the
   comparison the never-downgrade guard rests on. `install_pkgs_now` now fails
   loudly on an empty list.
2. **Invalid project config named nothing** (`ed2d444`). `load_project_config`
   returned 1 silently from six places, and the caller can only say "project
   configuration is invalid under <dir>" — so a malformed record, an unknown
   package or dependency, an ungrouped package, or a missing file all left the
   user bisecting their own config by hand. Each path now names the offender.
   The numeric/parallelism defaults also named the internal variable
   (`_MEMORY_PER_JOB_GIB`) instead of the key the user actually wrote
   (`memory_per_job_gib`).
3. **The resume command did not resume what was run** (`434940e`). The failure
   summary's resume line carried only `--lanes/--jobs/--intensity`, so resuming
   a run made with `-i` rebuilt the remaining packages **without installing
   them** — the rule-11 ABI hazard `-i` exists to prevent — while the tip
   printed directly beneath it said "add -s so already-built pkgs are skipped".
   It now mirrors `--install`, `--no-deps`, `--no-sync` and
   `--allow-broken-rustc`, and invents nothing that was not passed.
   `read_group_config` rejected a bad entry with a bare `return 1`, so the only
   message was "invalid package group: git" beside a 56-line list — and a
   *missing* file was reported as *invalid*. It now names file and line (bad
   character, unknown package, duplicate), and says "missing" when that is what
   happened.
4. **The interactive dashboard had no coverage at all** (`4c818ab`). ~200 lines
   of terminal control; `_OUTPUT_INTERACTIVE` is gated on `test -t 1` and every
   other fixture pipes the builder, so nothing had ever executed it.
   `tests/dashboard.sh` drives the real thing under a pty (`script -qec` with a
   controlled `stty cols`), and measures rendered rows with the same
   `string length --visible` production uses, so escapes and multibyte icons
   count the way the builder counts them. Also de-duplicated the log path
   (finding 8 below).
5. **An invariant three documents state had no fixture** (`e64a3ff`). "Core
   runs solo" is asserted in README, docs/architecture.md and MEMORY.md;
   `tests/scheduler-intensity.sh` pinned only the printed plan numbers, so
   `GSA_CPU_THREADS`/`GSA_MEMORY_GIB` covered the formula, not the behaviour.
   New `tests/scheduler-core-solo.sh` measures observed concurrency from the
   stub's own timestamps.
6. **The checksum verification the stable sync disables was invisible**
   (`e417a7e`). `sync_stable_version` rewrites a stable recipe's pkgver/pkgrel
   in place and deliberately leaves the committed sums describing the previous
   version, so `build_package` adds `--skipchecksums` for that build — and
   those sources are built, and with `-i` installed, without a committed sum.
   `--skipchecksums` appeared **exactly once in the whole repository**, on the
   line that adds it: not in `--help`, not in `build-guide.md`, not in
   MEMORY.md. In the shipped flow it was not merely undocumented but
   *unreachable*: `build_package` has one call site (`lane_job`, always
   `quiet_flag=1`), every lane redirects its stdout/stderr into the per-package
   log, and the single echo naming the argv is gated on the non-quiet flag that
   nothing passes — so the flag reached neither the terminal nor any log. The
   trade is deliberate (skipping the check is what makes a synced build
   possible), so the fix is **disclosure, not a behaviour change**: the package
   log states it unconditionally and ungated, because a multi-lane run's log is
   the only record it leaves; `--help` explains it under `--no-sync`;
   `build-guide.md` gains a section covering the rewrite, the skipped checks,
   the fact that signature checks are **unaffected** (`--skipchecksums` is not
   `--skippgpcheck`), and how to restore verification.
7. **Coverage added that was not a defect**: `sync_stable_version` had never
   been exercised by any fixture. `tests/stable-sync-checksums.sh` pins the
   rewrite itself (so the rest cannot pass vacuously), the flag reaching
   makepkg's argv, the disclosure in the log, and — in a second run — that
   `--no-sync` disables all three, so the message cannot rot into unconditional
   noise.
8. Duplicate report, not a defect: the BUILD FAILED / "Last lines" / `-i` hint
   block appears twice, but the two paths are mutually exclusive by
   `_OUTPUT_INTERACTIVE`. Left alone.

- **Method, and the part worth keeping**: every fixture was **falsified before
  it was trusted**. `git stash push -- build-all.fish`, run, `git stash pop`;
  the fixture must fail on the pre-fix builder. Two of them were wrong first
  and the failure is the instructive part:
  - `tests/dashboard.sh`'s interrupt case originally asserted "no lane child
    survived" by grepping `ps` argv for the sandbox makepkg path. Replacing
    `lane_processes` with something that cannot signal anything left it
    **passing** — so it measured nothing. Cause: the builder execs makepkg by
    **bare name** (`bash <dir>/bin/makepkg`), so the grep matched the fixture's
    own command line. Lanes are now identified by recorded PID (`kill -0` plus
    a `Z`-state check, the way `lane_pid_alive` decides it). Second cause, more
    important: "nothing survived" is not a property of `stop_lane_process` at
    all — the function ends in `wait $lane_pid`, so even a builder that signals
    nothing returns only once its lanes finished by themselves. The property
    that matters is **promptness**; the stub now runs 15 s and ignores TERM, so
    a builder that waits instead of killing overruns a 6 s deadline, and the
    SIGKILL escalation in `stop_lane_process` is genuinely exercised.
  - The core-solo invariant needed **two scenarios**, because each direction
    passes while the other's guard is removed. Uniform stub durations were
    tried first and were wrong: every lane frees in the same poll, core is
    dispatched into an already-idle pool and the guard is never reached. Phase
    A needs staggered durations **and** an asserted precondition that core was
    actually held back, plus a baseline that two normal packages overlapped, so
    "core never overlapped" cannot be true for the wrong reason. Phase B places
    core first and requires the other lane to stay idle with work ready.
- **Rules recorded** (MEMORY.md §1.18 and §6): a *lowered guard must be
  announced where the record is*; and the audit method — **grep a
  security-relevant flag for its documentation, in both directions**.
- **Validated**: `fish -n`; `--audit`; `--list`; dry-runs for git/stable/core;
  `bash tests/run-all.sh` 32/32 PASS.
- **Left open, deliberately**:
  - the `--skipchecksums` **policy** question — should a synced stable build
    refresh the sums (`updpkgsums`) instead of skipping verification? That is
    the owner's decision, not the auditor's, and it is the one remaining hole
    under finding 6.
  - an unreproduced `tests/sudo-keepalive.sh` flake: it failed once inside a
    battery and then passed 5/5 isolated, 3/3 under load and 32/32 twice. Its
    failure text was lost to `tail` (the runner prints a failing fixture's
    output *before* the summary, so piped output discards the only evidence).
    The hypothesis — the fixture installs a stub `date` advancing 300 s per
    call, so assertions counting dispatcher polls are load-sensitive by
    construction — is recorded, not fixed.
  - `install_all`'s `install-all.log` is dead: `run_pacman_locked` ignores its
    `-a log_file`, and all four call sites redirect at the call site. Writing
    it would either hide pacman output or add a `tee`; left alone.
  - `assign_group` has no `case '*'`; unreachable today, recorded as latent.

## 2026-09-20 — cmake-git's PGO phase 2 never ran: the configure cache, not the rebuild, holds the flags

- **Symptom**: the queued rebuild of `cmake-git` — the fix for the five
  instrumented installed files — **failed 100 % of the time**, aborting inside
  its own `package()` guard with "final package still contains profile
  instrumentation" for `cmake`, `ccmake`, `cpack` and `ctest`, while the
  installed instrumented build (4.4.3.936, built 2026-09-07) stayed in place.
  Read as a machine-load or environment problem it made no sense: the run had
  the whole host.
- **Root cause**: `build()` ran PGO as two phases, and phase 2 could not work.
  Phase 1 exports `-fprofile-generate` and runs `./bootstrap`; phase 2 only
  swaps the flags in the exported variables
  (`${CFLAGS/-fprofile-generate/-fprofile-use}`) and runs `make clean; make`.
  But **CMake reads `CFLAGS`/`CXXFLAGS`/`LDFLAGS` once, while it initialises the
  cache**, and phase 1's `./bootstrap` wrote `CMakeCache.txt` with the phase-1
  flags. `make clean` does not remove that cache, so the final link line still
  read `-fprofile-generate` and the payload stayed a phase-1 build. Phase 1 did
  its job — the log records `Profile data generated: 755 .gcda files`.
- **Proven, not inferred**: `CMakeCache.txt` still read
  `CMAKE_CXX_FLAGS:STRING=… -fprofile-generate` after the "phase-2" rebuild, and
  the final executable link line in the build log still carried
  `-fprofile-generate`. Reproduced in ~10 s on a scratch CMake project: with the
  cache present, changing the environment changes nothing; **even re-running the
  configure step with the cache in place still ignores the environment**; only
  dropping `CMakeCache.txt` (or passing `-DCMAKE_C_FLAGS=` explicitly) makes the
  new flags take effect.
- **Fix, first form (refused by the build — kept here because the reason is the
  useful part)**: factor the bootstrap invocation into a `bootstrap_cmake()`
  helper and make phase 2 `make clean` → `rm -f CMakeCache.txt` →
  `bootstrap_cmake` → `make`. The re-bootstrap was wrong: `./bootstrap` compiles
  the bootstrap CMake out of the same sources, so running it a second time under
  `-fprofile-use` recompiles those objects against the profiles phase 1 produced
  *for a generate-mode build* and dies on
  `-Werror=coverage-mismatch` ("source locations … have changed, the profile
  data may be out of date") in `Bootstrap.cmk/Makefile`. The build log shows
  phase 1 fine (`Profile data generated: 755 .gcda files`) and the failure
  immediately after, in `bootstrapping CMake`.
- **Fix, second form (also refused — the warning trap)**: phase 2 becomes
  `make clean` → `rm -f CMakeCache.txt` → `make`, deleting the cache so the
  generated `Makefile` reconfigures by itself on the next invocation, reading the
  phase-2 environment. Measured on a scratch project rather than assumed:
  `-DFOO=1` at configure, then `rm CMakeCache.txt` and `make` with `-DFOO=2` →
  `flags.make` contains `-DFOO=2` and the build succeeds. **It failed anyway**,
  one step further on: `make_unique`/`unique_ptr`/`filesystem` all answered
  "no" during the reconfigure, so configure aborted with "The C++ compiler does
  not support C++11 (e.g. std::unique_ptr)". `Source/Checks/cm_cxx_features.cmake`
  decides a feature is missing when the probe output matches
  `"(^|[ :])[Ww][Aa][Rr][Nn][Ii][Nn][Gg]"` — **any** warning counts as
  unsupported — and the probes are compiled fresh, so `-fprofile-use` warns
  `-Wmissing-profile` ("profile count data file not found", the paths are new)
  on every one of them. The check log shows the probes *building and linking
  cleanly*; only the warning made CMake answer "no".
- **Fix, third form (also refused — the profile mismatch)**: phase 2 keeps the
  cache purge **and** appends `-Wno-missing-profile`. That is the one warning the
  probes legitimately produce, and suppressing it let the reconfigure reach a yes
  — but the build then died at 5 % on
  `Source/kwsys/ProcessUNIX.c.o`, in *both* the C and the C++ target:
  "number of counters in profile data for function `cmsysProcess_AddCommand`
  does not match its profile data (counter `arcs`, expected 15 and have 16)
  [-Werror=coverage-mismatch]". GCC treats a mismatched profile as an error by
  default, and the mismatch is intrinsic to the two-phase scheme rather than
  something in this tree: `-fprofile-use` enables passes the `-fprofile-generate`
  phase did not run, so a handful of functions come back with a different arc
  count.
- **Fix, fourth form (the purge itself was wrong — measured, then replaced)**:
  keeping the purge and adding both flags produced a payload that *built* clean
  (0 baked paths in all four binaries) and then failed `package()` on an
  unrelated symptom: the phase-2 configure had printed `-- Using bundled: CURL
  EXPAT …` where phase 1 printed `-- Using system-installed: …`, and the tree
  landed under `pkg/usr/local/…`. Root cause: `CMakeCache.txt` is not "the
  flags" — it is every decision `./bootstrap` made, so `--prefix=/usr`,
  `--mandir`/`--docdir`/`--datadir`, thirteen `CMAKE_USE_SYSTEM_*` entries and
  `-fuse-ld=mold` all reverted the moment it was deleted. The exported
  `CFLAGS`/`CXXFLAGS`/`LDFLAGS` in this form were dead code for the same reason
  the original code was: with a cache present, CMake ignores the environment.
- **Fix, final**: rewrite the flag strings *inside* the cache and force a
  regeneration — `sed -i 's/-fprofile-generate/-fprofile-use
  -Wno-missing-profile -Wno-error=coverage-mismatch/g' CMakeCache.txt`, fail the
  build if any `-fprofile-generate` survives, `touch CMakeLists.txt`, then
  `make clean` → `make`. Pre-flight on the real tree: the reconfigure took
  **3.1 s** (the cached feature answers mean no probe re-runs at all, which also
  demotes `-Wno-missing-profile` from required to backstop), and it regenerated
  **65/65** `flags.make` and **44/44** `link.txt` to the use-flags with **0**
  left at generate, kept `CMAKE_INSTALL_PREFIX:PATH=/usr` in both the cache and
  `cmake_install.cmake`, kept mold on the link line and all thirteen
  `CMAKE_USE_SYSTEM_*` entries. `-Wno-error=coverage-mismatch` is what lets the
  build finish, at the cost of compiling the mismatching functions (kwsys
  process handling) without profile data — every other function keeps the real
  profile, and the payload is uninstrumented either way, which is the point of
  the phase. `make clean` stays, for a second reason: regenerated rules do not
  invalidate phase-1 objects, so without it `make` would relink the instrumented
  ones against fresh sources.
- **Validation**: `bash -n` on the recipe; `.SRCINFO` freshness fixture green.
  The real build is the remaining proof and is deliberately **not** run as a
  syntax check — `strings -a /usr/bin/cmake | grep -c '\.gcda'` must reach 0 for
  `cmake`/`ccmake`/`cpack`/`ctest`.
- **Rule**: this is the **CMake twin of the Meson staleness rule** — a
  configure-time argument cache survives a rebuild, and `make clean` is not a
  reconfigure. Replace the cached values and make the build system regenerate;
  do **not** delete the cache, which carries the install prefix, the install
  directories and the dependency selection as well as the flags, and losing them
  is invisible until the payload is inspected. Do **not** re-run the bootstrap
  either: it is a *build of a compiler* and inherits whatever profile data the
  previous phase left lying in its own object directory.
  Then watch what the reconfigure has to say: `-fprofile-use` adds
  `-Wmissing-profile` to every fresh probe, and a project whose feature checks
  treat a warning as a negative answer will read an untrained profile as a
  missing compiler feature. A PGO phase 2 needs its build system's *own* probe
  policy checked, not just its cache.
- **`-fprofile-generate` and `-fprofile-use` do not describe the same build.**
  `-fprofile-use` enables optimization passes the generate phase never ran
  (`-funroll-loops`, `-fpeel-loops`, `-ftracer`, …), so some functions come back
  with a different arc count and GCC refuses their profile — as an *error*, by
  default. A phase 2 that cannot regenerate its inputs needs
  `-Wno-error=coverage-mismatch` (which compiles those functions unprofiled)
  alongside `-Wno-missing-profile`.
  The distinction is worth keeping: `xorg-xwayland-git` gets it right with
  `meson setup --reconfigure`, and its rebuild is simply waiting its turn.

## 2026-09-20 — the downloaded-archive rule lived in two places, and they had already drifted twice

- **Symptom**: 36 MB of upstream release archives (nine archives plus a font,
  ten files) were tracked and pushed in `packages/stable/libreoffice-fresh/`,
  and had been public since the 2026-09-16 release sweep. The ignore half was
  fixed on the spot (`213424a`: `git rm --cached` plus `*.tgz`/`*.zip`/`*.jar`/
  `*.ttf` in the root `.gitignore`), but its **other half was still broken**:
  `nuclear_cleanup()` matched downloads with a hand-written test,
  `string match -q '*.tar.*' -- "$fname"; or string match -q '*.whl'`, so
  `-ccc` deleted this recipe's eighteen `.tar.*` downloads and left the ten
  behind for a sweep to commit.
- **Root cause**: the same list was written twice — once as the ignore rules,
  once as the cleanup match — with no link between them. They had in fact
  **already drifted once** (see the 2026-09-14 entry: `texlive-texmf`'s `svn://`
  checkouts and its `latexminted` wheel survived `--nuclear` forever), and each
  drift was repaired by appending one more pattern to one of the two lists.
- **Fix**: one list, in `build-all.fish`, as `_DOWNLOAD_ARCHIVE_EXTS`, used by
  `nuclear_cleanup()`; `.gitignore` carries the same set and names the shared
  invariant in a comment. `*.whl` joined the ignore rules so the two sets are
  literally equal, and `_DOWNLOAD_ARCHIVE_EXTS`'s wildcard entry is **quoted** —
  fish glob-expands an unquoted `tar.*` and silently drops it when nothing
  matches, which would have shrunk the list back to the old behaviour without
  any error.
- **Second defect, found by the new fixture**: the report of what `-ccc` keeps is
  the maintainer's only chance to see it before agreeing, and in a pipe it
  printed a blank line. The builder shadows `set_color` with a wrapper that is
  empty off a terminal, and fish drops a whole word like
  `(set_color cyan)"text"(set_color normal)` when the substitution yields
  nothing — so `echo` lost the text entirely. Eighteen call sites (this function's
  banner, the symlink summary, and the `--link-sources`/dedup reports) were
  rewritten as `printf '%s%s%s\n' (set_color cyan) "text" (set_color normal)`,
  where the text is its own argument and survives either way. A pipe is the
  documented interface to parse, so a report that only exists on a terminal is
  not a report.
- **Validation**: new `tests/cleanup-extensions.sh` drives a synthetic workspace
  under `$TMPDIR` and asserts that every archive type the ignore file denies is
  deleted by `-ccc`, that a local (non-URL) asset and its signature survive, that
  a symlinked source is kept and reported, that the deletion is named in the
  report, and that the report survives a pipe. It also **cross-checks the two
  lists statically in both drift directions**, and was proven to fail in each
  (shrinking the builder list; deleting a rule; adding `*.7z`). Battery
  24 → **25 fixtures, all green**. `tests/texlive-recipe.sh` asserted the old
  literal `'*.whl'` match; it now asserts membership of the shared list, pointing
  at the general fixture.
- **Rule**: a deny-list and a delete-list are the same list, so keep one
  definition and test the equality — an interval where only one of them is right
  is invisible in the diff and shows up months later as committed upstream
  archives. Corollary, from the same fixture: anything a scripted consumer is
  expected to read must be checked **through a pipe**, because the colour
  wrapper that makes a terminal pleasant is what silently deletes the text.

## 2026-09-20 — the PGO payload check was a per-recipe convention, so it kept being missed

- **Symptom**: the 2026-09-16 PGO leak recurred on `cmake-git` and
  `xorg-xwayland-git` — five installed files (`cmake`, `ccmake`, `cpack`,
  `ctest`, `Xwayland`) re-creating hundreds of `.gcda` files on every run —
  even though a fix for exactly this defect had already landed, and two
  recipes carried a verification function for it.
- **Root cause**: verification was a per-recipe convention, not an invariant.
  21 recipes instrument with `-fprofile-generate`; only 5 checked their own
  output. Two earlier commits each fixed the subset they were looking at
  (`f613685`, `4db32c5`), so the 22nd recipe was guaranteed to miss it. Worse,
  **four of those five checks could not fail a build at all**: they were called
  mid-`package()` without `|| return 1`, and bash returns the status of the
  *last* command, so the check printed its ERROR, exited 0, and makepkg
  packaged the instrumented payload anyway. Only `cairo-git` had the call as
  the final command, which is the one position where the status propagates by
  accident. The 2026-09-16 entry had also documented *two* checks —
  `readelf -sW` for symbols **and** `strings` for baked `.gcda` paths — while
  the digest line and the recipe function implemented only the first, which is
  a false negative on anything makepkg has stripped (`readelf` → 0 matches on
  `/usr/bin/Xwayland`, `strings -a` → 348).
- **Fix**: moved the invariant into the builder. `verify_pgo_payload()` in
  `build-all.fish` runs at both install seams (`install_pkgs_now()` and
  `install_all()`), gated on the sibling `PKGBUILD` containing
  `-fprofile-generate`, extracts the **whole** archive, requires a standalone
  `/<path>.gcda` string, and fails closed when `tar` yields nothing.
  `audit_workspace()` gained an "Installed PGO payloads" section, because a
  gate cannot retroactively fix a stale install — that is what hid this defect
  for six weeks. The five existing recipe guards were upgraded to the dual
  predicate, which also fixed a latent bug where `return 1` on the first hit
  skipped the remaining files, and `cmake-git` gained the guard it never had.
- **Validation**: `tests/pgo-payload-guard.sh` pins the gate end-to-end in a
  synthetic workspace (four payloads, stub `pacman`/`sudo`); red tests prove
  the gate, the archive scope and the strict predicate are each load-bearing.
  `tests/pgo-transition.sh` now exercises both detectors at the recipe seam,
  asserts repo-wide that no call site discards the check result, and uses leak
  paths that avoid `.Heavyweight`, which `--audit` correctly reported as
  legacy-layout drift.
- **Measurements that changed the design** (each replaced a written
  assumption): `.BUILDINFO` contains no `.gcda` — it records
  `-fprofile-generate` in `buildenv`, which a path predicate ignores — so the
  "whole-archive scanning trips over metadata" rationale was simply wrong, and
  whole-archive scanning turned out to be the more complete choice. Scanning
  every file owned by every PGO recipe costs ~13 s for 14 559 files, which
  `--audit` can afford. `ctest` carries **482** baked paths, not 481, because
  the first sweep had been restricted to `/usr/bin`, `/usr/lib` and
  `/usr/lib32` while the recipe path is `packages/git/xorg-xwayland-git`.
- **Rule**: a whole-set invariant belongs in the builder, not in a per-recipe
  convention — if two commits can each fix "part of it", the next recipe will
  miss it. A check that cannot fail its caller is worse than no check, because
  it reports success: a `verify_*` call inside `package()` needs `|| return 1`
  (or must be the function's last command), since bash discards the status of
  every earlier command. Verify PGO payloads with `strings`; add `readelf` only
  where the files are still unstripped. And a check that guards a write into
  `/usr` must never report clean because it in fact scanned nothing.

## 2026-09-20 — stable sync re-anchors its checksums to Arch

- **Symptom**: `sync_stable_version` rewrote `pkgver` from `pacman -Si` and the
  committed sums were deliberately left describing the previous version, so the
  builder passed `--skipchecksums`. The flag reached neither the terminal nor
  any log, because `build_package` is only ever called quiet and each lane logs
  its own stream.
- **Fix**: the builder now anchors the sums of every *moved* source to the value
  Arch published for the version it synced to, taken from the official packaging
  repo's `.SRCINFO`, writes them with `updpkgsums`, and verifies the fetched
  source against Arch's checksum. `--skipchecksums` is never passed. Anything
  it cannot anchor refuses the build and restores the recipe. `--help`,
  `docs/build-guide.md` and §1 rule 18 describe the behaviour instead of the
  now-removed flag.
- **Why the trigger is the source, not the version**: 26 of 28 `stable` recipes
  pin a literal version inside `source=()` URLs, so a `pkgver` bump usually
  leaves their sums valid — the rebuild difference is a *diff of the expanded
  `source=()` array*.
- **Rule**: a check that hashes what arrived agrees with a substituted tarball.
  Anchor to the authority the value came from, fail closed when it is
  unavailable, and never leave a lowered guard undisclosed.
- **Incidental finding**: sweeping every `stable` recipe against Arch found
  **four committed checksums that were simply wrong** — fish 4.9.3, upower
  1.91.4, ccache 4.14, systemd 261.3, all VCS `#tag=` sources at the same
  version as Arch. Each was confirmed from a fresh mirror with
  `makepkg --verifysource` before being rewritten, and each had been shipping a
  sum only a build with verification disabled could survive.
- **Validation**: `tests/stable-sync-checksums.sh` pins eleven scenarios, each
  falsified before being trusted; the full battery is 32/32. A partial clone
  (`--filter=blob:none`) proved unusable as a mirror — it renders an
  `export-subst` file differently and reports a false mismatch.

## 2026-09-19 — two orphan trees under `~/Projects` were instrumented binaries, and the IgnorePkg closure had drifted

- **Symptom**: `~/Projects/.Heavyweight/cmake-git/src/cmake/` and
  `~/Projects/xorg-xwayland-git/src/build/` kept reappearing — 779 files, every
  one a `.gcda`, with no `PKGBUILD`, no `.SRCINFO` and no `.git` anywhere inside.
  They were first read as debris from an old `makepkg` run under the pre-2026-09-15
  layout. They are not.
- **Root cause**: a recurrence of the 2026-09-16 defect, on the two packages that
  fix did not cover. The **installed** `/usr/bin/cmake` (cmake-git 4.4.3.936,
  built 2026-09-07) and `/usr/bin/Xwayland` (built 2026-09-16) are PGO phase-1
  builds that were packaged, so each carries hundreds of *absolute* `.gcda`
  destinations baked into the executable — 431 in `cmake`, plus 432/438/481 in
  `ccmake`/`cpack`/`ctest`, and 348 in `Xwayland`. libgcov `mkdir -p`s those
  paths at process exit, which is why deleting the trees achieved nothing.
- **How it was proven, not inferred**: the trees were deleted twice, and one
  `cmake --version` plus one `Xwayland` call re-created **all 779 files**. The
  mechanism was then isolated by running `cmake --version` alone and watching the
  mtime of a single `.gcda` advance from `00:13:02` to `00:19:05`, and by
  `strings -a /usr/bin/cmake | grep -c 'Heavyweight.*\.gcda'` → 431.
- **The verification in this journal was half-implemented**: the 2026-09-16 entry
  prescribes both `readelf -sW` (no `__gcov_`/`__llvm_profile` symbols) **and**
  `strings` (no legacy `.gcda` destinations), but the digest line and
  `verify_no_profile_instrumentation()` in the `xorg-xwayland-git` recipe implement
  only the first. On a stripped binary that half-check is a false negative:
  `readelf -sW /usr/bin/Xwayland` reports clean while `strings -a` finds all 348
  paths. The recipe is incomplete rather than wrong — inside `package()` the
  binaries are not yet stripped, so the check does work there.
- **Sweep**: every installed file under `/usr/bin`, `/usr/lib` and `/usr/lib32`
  was tested for an absolute `.gcda` destination. Exactly five files in two
  packages match. `glib2-git` and `cairo-git` return 0, so the 2026-09-16 fix held
  for the packages it touched.
- **Fix**: queued, not applied — a rebuild of `cmake-git` and `xorg-xwayland-git`
  via `--no-deps --install`. Neither name can be fixed by `-Syu`, because both are
  `IgnorePkg`-locked, which is the protection working as intended.
- **Second finding, same session**: the `IgnorePkg` closure golden rule was **32
  names short**. `comm -23` of the committed `.SRCINFO` pkgname set (218) against
  `pacman-conf IgnorePkg` (221, no globs) left the three
  `linux-cachyos-rt-bore-lto*` outputs, all 30 `texlive-*` splits, `autofdo-git`,
  `bpftune-git`, `logseq-desktop-git`, `mkinitcpio`, `openshadinglanguage` and
  `vscodium-insiders-git` unprotected. The audit must read `.SRCINFO`: the kernel's
  `pkgbase="linux-$_pkgsuffix"` makes a `PKGBUILD` grep report a literal `linux-`.
- **Fix applied**: the 32 names were appended as three new one-line `IgnorePkg =`
  entries inside `[options]`, after backing `/etc/pacman.conf` up to
  `/etc/pacman.conf.bak-20260919`. The existing 221 entries were not regenerated.
- **Verification**: `comm -23` is empty; `pacman-conf IgnorePkg` parses and reports
  253 entries, all lines still inside `[options]`; no duplicate names introduced.
  `pacman -Sy` was **not** usable as a check while a build held the database lock —
  `pacman-conf` reads the file directly and needs no lock.
- **Rule**: an installed binary that writes `.gcda` is not "debris in a stale
  directory", it is a packaging failure with a self-healing symptom. Delete the
  tree only after the package is rebuilt, and verify the rebuild with `strings`,
  never with `readelf` alone.

## 2026-09-19 — a mistyped package name said nothing useful, and `-g gti` said nothing at all

- **Symptom**: `fish build-all.fish mesa-gti` printed

  ```
  ✗ package recipe not found for ID 'mesa-gti'
  ```

  and stopped. No suggestion, no pointer to the listing, and no way to tell a
  typo from a package that does not exist. `fish build-all.fish -g gti` was
  worse: it exited 1 having printed **nothing**, so the only clue was the exit
  status. A name that *is* installed on the host — `zen-browser` — was refused
  outright, because resolution knew only recipe IDs and recipe paths.
- **Root cause (two, and only the second is the interesting one)**:
  1. `canonicalize_pkg_ref` had exactly two lookup tables (the ID list and the
     map's recipe-path column) and neither is the name a user has in hand. The
     pacman `pkgname` was simply not a lookup key, even though every recipe
     commits a `.SRCINFO` that names it.
  2. `resolve_group`'s diagnostic went to **stdout**, which is a *data* channel:
     `main` reads the group with `set -l gl (resolve_group $g)`, so the message
     was captured into `$gl` and thrown away. The function's own return status
     was the only surviving signal, and the caller's `ui_error` path was never
     reached because the caller only returns when `resolve_group` fails — which
     it does, silently.
- **Fix — the name index**: `_pkgname_index` reads `name|id` pairs from every
  recipe's committed `.SRCINFO` (218 distinct names across 126 recipes; measured
  zero unexpanded `${…}`, because `makepkg --printsrcinfo` already expanded
  them, and *no name shared by two recipes*, so a lookup cannot pick the wrong
  recipe). `canonicalize_pkg_ref` gained two exact tiers — case-variant ID and
  pacman `pkgname` — and `_ref_form_note` announces each substitution, so a
  reference never silently means something else. A typo is deliberately **not**
  auto-corrected: a wrong guess would build a whole dependency chain, and
  `libstdc++-snapshot` → `gcc-snapshot` is a 17-package split recipe. Typos are
  reported by `_report_unknown_ref` with up to three ranked candidates
  (exact name, case variant, substring, Levenshtein ≤ 2). The distance sweep
  runs in **awk**, one process for all 126 candidates: the same sweep in fish
  costs ~0.4 s, and `awk` was also the correct tool because a token containing
  glob characters (`libstdc++-snapshot`) cannot become a pattern there.
  `resolve_group` now writes its diagnostic to stderr.
- **Fix — the listings, which is where the same defect class showed up again**:
  a range indexes the **selection** in dependency order, but `--list` printed
  the whole-set order and `-l` returned at parse time, discarding `-g`. So
  `-l` index 22 was `vscodium-insiders-git` while `-g git 22..24` built
  `ninja-git, mesa-git, niri-spicy-git` — two different answers with nothing
  saying which one a range meant. `-l` now runs *after* the selection pipeline
  (so `-l -g git` prints the 56 packages a range addresses, and says so), `-n`
  with no selection covers the whole set — which is what `--help` had claimed
  for it all along while the run errored — and ranges name their mistakes:
  out-of-bounds reports the selection size and the valid window, a clamped bound
  warns, `..` and `N..M` with a start past the end are refused instead of
  silently selecting everything or nothing. `-g core`'s auto-install warning is
  suppressed for `-l` only: a listing installs nothing.
  A bare name that expands into its dependency chain now says how much of the
  selection it added (`niri-spicy-git` → "added 2 of the 3").
- **Validation**: `tests/project-cli-hints.sh` (new, 23rd fixture) asserts every
  message above — including that the group diagnostic is on **stderr** and not
  on stdout — and was mutation-tested red on five mutations: hints removed,
  `-l`'s parse-time return restored, the out-of-bounds guard dropped, the
  pkgname tier dropped, and `resolve_group`'s `>&2` removed. The last one
  initially stayed **green**, because the swallowed text leaked back into the
  output through another path (the captured string became a "package" and was
  echoed by the topology error) — which is exactly why the assertion was
  rewritten to check the channel, not the merged text. Full battery 23/23;
  `--list` with no selection is byte-identical to before (diffed against the
  previous revision), so `tests/project-config.sh` and every documented
  invocation are unaffected.
- **Durable rule**: a diagnostic written to a function's stdout is *data* when a
  caller captures it — put it on stderr, or it will be silently swallowed and
  the exit status will be the only evidence. And an index that a user has to
  know by heart (which of 126 IDs is the one) should be discoverable from the
  metadata the repo already commits: `.SRCINFO` is authoritative, needs no
  PKGBUILD evaluation, and `tests/srcinfo-freshness.sh` already keeps it honest.

## 2026-09-19 — the knob switch died in makepkg's integrity check

- **Symptom**: a build of the recipe with `_cpusched=cachyos` — every other knob
  at its default — aborted before `prepare()`:

  ```
  ==> ERROR: Integrity checks (b2) differ in size from the source array.
  ```

  Nothing in the recipe mentioned sums, and the failure arrived after
  "Retrieving sources", so it looked like a corrupt download or a tampered
  source rather than a bookkeeping mismatch.
- **Root cause**: `source[]` is assembled from four knobs, `b2sums` is a single
  flat literal, and makepkg requires exactly one integrity entry per source.
  Measured by sourcing the PKGBUILD per knob set: `_cpusched=cachyos|eevdf|rt`
  drops the one scheduler patch (4 sources), `_build_zfs=yes` adds one,
  `_build_r8125=yes` adds one, `_build_nvidia_open=yes` adds four — and
  `_use_llvm_lto`, `_build_debug`, `_autofdo`, `_propeller`, `_capture_chain`,
  `_hardened` and `_host_tune` change nothing. The committed literal is sized
  for the defaults (5), so it is correct for exactly one combination out of the
  reachable ones. The recipe's own NOTE said to run `updpkgsums` after a
  `_cpusched` switch, but nothing enforced it and makepkg's message names
  neither the knob nor the remedy.
- **Why the obvious fix is wrong**: per-knob sums (`b2sums+=('…')` next to each
  `source+=`) make every combination build, but `updpkgsums` rewrites the whole
  `b2sums=(…)` assignment as a literal on every version bump, so the appends
  would double-count at the first bump — a silent break in the tool the version
  bump depends on. Upstream avoids the problem by shipping one PKGBUILD per
  scheduler (`linux-cachyos`, `-bmq`, `-eevdf`, `-rt-bore`, `-hardened`, `-lts`,
  `-rc`), each with sums sized for its own default; a merged recipe cannot.
- **Fix**: the PKGBUILD now checks the pair itself, at parse time, before
  anything is fetched or written:
  ```sh
  if [ "${GENINTEG:-0}" -eq 0 ] && [ "${#b2sums[@]}" -ne "${#source[@]}" ]; then
      _die "b2sums has N entries but source[] has M for this knob set. … Run 'updpkgsums' in ${startdir} …"
  fi
  ```
  The `GENINTEG` exemption is the load-bearing part: `updpkgsums` runs
  `makepkg -g`, which has to source the PKGBUILD to do its job, and the whole
  point of running it is that the sums do not match yet — an unguarded abort
  would make the remedy impossible to run. makepkg sets `GENINTEG=1` during
  option parsing and sources the PKGBUILD into its own shell, so the mode is
  visible to it (measured on pacman 7.x; no `/proc` poking needed).
- **Validation**: the guard refuses `_cpusched=cachyos` and
  `_build_nvidia_open=yes` by name; accepts the default set and the six knobs
  measured to be source-neutral; `makepkg --printsrcinfo` on the pristine recipe
  is byte-identical to the committed `.SRCINFO`; and the remedy was run
  end-to-end in a scratch copy — `_cpusched=cachyos updpkgsums` regenerated
  `b2sums` to 4 entries, after which the `cachyos` set parsed clean and
  `rt-bore` was the set that got refused. `tests/kernel-recipe-sums.sh` pins all
  of it and is red on four mutations: guard removed, guard unconditional,
  `GENINTEG` exemption removed, and a default set edited away from the shipped
  sums (the drift case the 7.3 move hit when `misc/0001-rt-i915.patch` was
  dropped).
- **Durable rule**: a `b2sums` literal is sized for one knob combination. Either
  keep the source set knob-independent, or make the recipe refuse the
  combination it cannot serve *and* keep the sum-generation path runnable.

## 2026-09-19 — the recipes were reporting on my laptop

- **Symptom**: `CONTRIBUTING.md` scopes a contribution to "a clean Arch
  checkout" and excludes "host-specific logs and profiles", but two commits of
  mine (`56e6c76`, `3ecf456`) had put the opposite into tracked files. The
  `linux-cachyos` PKGBUILD documented the running kernel version
  (`7.2.5-1-cachyos-rt-bore-lto`), the CPU thread count, an inventory of the
  Limine command line and its sysctl drop-in, the `mitigations=off` and
  `zswap.enabled=0` boot decisions, and a narrative of a hard freeze. A tracked
  working document under `stable/systemd/` carried the exact CPU model in its
  first "verified facts" list. A `third-party` recipe ID claimed `znver5` while
  the recipe set no ISA at all.
- **Root cause**: the journal rule — host incidents go in `NOTE.md`, the
  operational contract goes in `MEMORY.md` — was never stated as a rule for
  *recipes*, so every fact learned while debugging leaked into the file being
  edited. Nothing stated who the set is *for* either, so a machine-specific
  trim read as an accident rather than as the target.
- **The audit's own correction**: the ISA half of the complaint did not hold.
  No recipe hard-codes this machine's ISA — every native-flag injection is
  conditional and says so (`niri-spicy-git`, `rust-bindgen-git`,
  `xwayland-satellite-git`), no recipe narrows `arch` below `x86_64`,
  `rust-git` parameterises through `GSA_TARGET_CPU`, and the kernel's
  `_processor_opt` is a documented knob with `zen4`/`generic` alternatives.
  What *is* machine-specific is the **artifact**, because `makepkg.conf`
  supplies `-march=native`. That distinction is now written down rather than
  assumed.
- **Fix**:
  - 16 comment sites — 15 in `packages/misc/linux-cachyos/PKGBUILD`, one in
    `verify-config.sh` — rewritten to explain the option or the trim instead of
    the machine. Three needed the *claim* to move, not the wording: the AutoFDO
    drift note is now self-contained (the committed `config` carries no
    `AUTOFDO_CLANG`/`PROPELLER_CLANG` line, so the old text rested on host
    state); `_host_tune` is grounded in the committed `config` (`MAXSMP=y`,
    `NR_CPUS=8192`, `CPUMASK_OFFSTACK=y`, `ZSWAP=y`) rather than a thread
    count; the capture-chain note keeps the contradiction it documents and
    drops the incident.
  - `_capture_chain` default flipped to `no`, with the off branch given the same
    verified treatment so the flip has a tested opposite. The default run stays
    **84 expectations**: the 8 capture assertions swap to their off-state
    counterparts, read out of the committed `config` and confirmed at the seam.
  - `README.md` now states the target (**AMD laptops** — AMD CPUs with
    amdgpu/radeon graphics) and that trimming has been exercised on one model;
    `docs/portability.md` splits the portable recipe from the non-portable
    artifact; `CONTRIBUTING.md` measures a contribution against the target and
    states the comment rule.
  - `linux-firmware`, `libdrm-git` and `hip-runtime` now say the AMD target
    instead of "this machine" where the trim follows from the target. The five
    remaining "this machine" sites (`dbus`, `udisks2`, `wireplumber`,
    `rocm-llvm`) are capability absences, not specs, and stay.
  - `stable/systemd/Workspace_information&TODO.md` deleted — a completed
    planning document with the CPU model in it, and not an artifact
    `docs/package-policy.md` permits. Its durable findings moved into the
    recipe: the PGO branch is now marked as never having completed (the
    experimental GCC 17 snapshot segfaults in `IPA pass: profile`), and
    `check()` names the pre-existing openssl/tpm2-tss failures and `--nocheck`.
  - `Zen-Browser-Arch-znver5-optimized` renamed to `zen-browser-pgo`; the
    README now says what the recipe does (3-tier PGO, `-O3`, thin+cross LTO via
    mozconfig, ISA inherited from the host).
  - Two further sites the plan's inventory missed and the repo-wide sweep
    caught: `bpftune-git`'s hook rationale carried a coredump count and two
    timestamps (`2026-09-16 07:38:35, 18:57:50`) plus `/var/log/pacman.log` as
    evidence — the mechanism (dlopen + stale pointers → `strstr()` SIGSEGV)
    stays, the evidence goes; and `pyside6-git`'s maintainer line carried
    `~/Projects`. Both date from `b02cefd` ("Prepare Gentoo_Style_Arch for
    public release"), so the release pass missed them. `libdrm-git`'s trim now
    says the AMD target rather than naming an SoC it does not actually select
    on (the meson flags are AMD-wide, not SoC-specific).
- **Validation**: `bash -n` on every edited recipe; `makepkg --printsrcinfo`
  unchanged; real seam (`makepkg --nobuild`, real 7.3-rc3 tree) — default 84
  with the off-state set, `_capture_chain=yes` 84 with the on-set,
  `_hugepage=always` aborting by name; the `_capture_chain=yes` environment
  override proven to reach the lane child (the spawn is `setsid --wait fish
  build-all.fish --lane-job`, which inherits the environment, and the seam
  proves `makepkg` passes it into `prepare()`); 21/21 fixtures;
  `--audit`/`--list`/`--dry-run --group third-party` clean after the rename.
- **Durable rules**:
  - **A comment explains the code, the kernel option, or the trim decision; it
    does not inventory the machine it was written on.** Kernel versions,
    installed package versions, CPU thread counts, bootloader command lines and
    incident narratives belong in this journal.
  - **Declare the target.** A trim that follows from the maintained hardware is
    a scope statement and should name the platform; a trim that follows from one
    author's environment is a capability absence and should say so. Neither is a
    licence plate for the running machine.
  - **A recipe is portable; the artifact is not.** Recipes derive ISA settings
    from the environment and so build on any x86_64 host; `makepkg.conf`
    supplies `-march=native`, so the packages are tuned to the builder and are
    not redistributable.
  - `_capture_chain` is opt-in. `WQ_WATCHDOG` and `PSTORE_CONSOLE` are
    config-only — no command line can set them — so a kernel built with the
    default off keeps whatever panic path the command line provides but loses
    the workqueue-hang detector. Set `_capture_chain=yes` in the environment
    when that detector is the point.

## 2026-09-19 — `linux-cachyos`: the config toggles were a wish list, not a contract

- **Symptom**: three of the recipe's knobs did nothing, and nothing anywhere said
  so. The installed 7.2.5 kernel and the freshly resolved 7.3-rc3 `.config` both
  carry **no `TRANSPARENT_HUGEPAGE` at all** — not `=n`, *absent* — although the
  shipped `config` file asks for `madvise` and the recipe's `_hugepage` default
  is `madvise`. THP has never been enabled on this host.
- **Root cause — three independent ones, all silent:**
  1. **`_hugepage` is dead code.** `mm/Kconfig:844` gates the whole
     `menuconfig TRANSPARENT_HUGEPAGE` on `!PREEMPT_RT`, and `_cpusched=rt-bore`
     writes `PREEMPT_RT=y`. `scripts/config` sets the symbol without consulting
     Kconfig, the next `olddefconfig` deletes it, and the log prints neither.
     The same gate removes `NUMA_BALANCING` and `QUEUED_RWLOCKS` from the
     shipped config (15 symbols in total are `!PREEMPT_RT`-gated).
  2. **`_use_kcfi` is dead code.** 7.3's user-selectable symbol is `CONFIG_CFI`
     (`arch/Kconfig:954`); `ARCH_SUPPORTS_CFI_CLANG` no longer exists and
     `CFI_CLANG` is a promptless `transitional` symbol kept only to migrate an
     old `.config`. Measured: the recipe's three-name write leaves `CONFIG_CFI`
     **unset**, while `-e CFI` selects it.
  3. **`cachyos`/`eevdf` wrote a symbol that cannot exist.** `SCHED_BORE` is
     *added* to `init/Kconfig` by `sched/0001-bore-cachy.patch`, and the source
     case only fetched that patch for `bore|hardened|rt-bore`. Verified: upstream
     `linux-cachyos` and `linux-cachyos-rc` have the identical gap, so this is
     **not** a local divergence — the fix records the fact (`!SCHED_BORE`)
     instead of pretending to fix it.
  Plus two ordering faults: `_use_current` (`zcat /proc/config.gz > .config`) and
  `_localmodcfg` (`make localmodconfig`) ran *after* the entire toggle block and
  discarded it, and `_preempt` under `rt*` was skipped without a word.
- **Fix**: the knobs become a *resolved, verified* contract — every expectation
  either holds in the final `.config` or `prepare()` aborts in seconds with a
  named reason.
  - New `verify-config.sh` (recipe-local; bash + coreutils only) takes
    `<config-file> <expectation>...` in five forms — `SYM=v`, `SYM`, `!SYM`,
    `SYM!=v`, `SYM>=N` — prints **every** failure as `SYMBOL: expected X, got Y`,
    and exits 1 on any unmet expectation (2 on misuse). It reports `absent`
    separately from `n` on purpose: `n` means "fix the dependency", `absent`
    means "the symbol was renamed or removed, fix the name".
  - `prepare()` builds `_config_wants` beside each write and runs the check right
    after `make prepare` / `make config`; failure is a named `_die`. The default
    run asserts **84** expectations.
  - Base-config selection moved **ahead** of every toggle, so the explicit knobs
    always win whatever base was chosen.
  - Parse-time gates (a `_die` before any write, so they cost seconds, not a
    patch run): `bmq` and `hardened` (the 7.3 patch set ships neither), `muqss`
    (the local patch still targets 7.2), `_hugepage` or `_preempt` explicitly set
    under `rt*`, `_build_zfs=yes` under `rt*`.
  - New knobs: `_capture_chain` (yes — the config now argues *for* the crash
    chain that was assembled entirely outside the recipe), `_host_tune` (yes,
    `_nr_cpus=64`), `_hardened` (no), `_rt_feature_drops` (`abort|accept`).
    `_tcp_bbr3` renamed to `_tcp_bbr` with a warned legacy alias: it enables plain
    BBR + FQ, and `CONFIG_TCP_CONG_BBR3` no longer exists in 7.3 at all.
  - Deleted the dead `_sums_sched` array (nothing consumed it, and its
    `rt|rt-bore` entry still pointed at the removed `misc/0001-rt-i915.patch`).
- **Validation**: new `tests/kernel-config-verify.sh` covers every engine form,
  the absent-vs-`n` distinction, multi-failure counting, misuse exit 2, and
  structural assertions on the PKGBUILD (base-config selection precedes the first
  `scripts/config`; every documented `_cpusched` value is handled by all three
  `case` blocks; no unconditional `!SYM` in the invariants array contradicts a
  toggle's `-e SYM`). Real seam, `makepkg --nobuild` against the real 7.3-rc3
  tree: default 84, `_hardened=yes` 85, `_hugepage=always
  _rt_feature_drops=accept` 84 (warns), `_autofdo=yes` 84, `_use_llvm_lto=none`
  83, `_host_tune=no` 80 — all rc=0; and all seven contradiction cases abort with
  their named reason. Full fixture battery 21/21.
- **Durable rules**:
  - **A `scripts/config` write is not evidence.** An unknown symbol is a no-op
    and a gated symbol is written and then deleted. Only the resolved `.config`
    *after* `make prepare` is evidence, which is why the check reads the file
    instead of trusting the write.
  - **`!SYM` and `SYM=n` are different claims.** A `choice` member whose prompt
    is hidden — `bool "Cubic" if TCP_CONG_CUBIC=y` in `net/ipv4/Kconfig`, with
    `TCP_CONG_CUBIC=m` here — **disappears from `.config` entirely** (absent),
    while a merely unselected member is emitted `# CONFIG_X is not set` (`n`);
    `DEFAULT_RENO` in the same choice is `n` while `DEFAULT_CUBIC` is absent.
    Assert `!SYM` for such members. This cost one wrong table entry, caught only
    by the real-seam run. (The `IOMMU_DEFAULT_*` choice members do emit `n`, so
    it is per-symbol — measure, do not generalise.)
  - **An invariant must not contradict its own toggle.** `!AUTOFDO_CLANG` sat in
    the unconditional invariants array while `_autofdo=yes` wrote
    `-e AUTOFDO_CLANG`, which made the AutoFDO path unbuildable; the same shape
    was waiting on the `_hardened` trio. Guard such an assertion on the knob,
    outside the array. The fixture now enforces this class directly.
  - **Validate the copy you edited, on a clean `src/`.** The seam scratch tree
    holds a *copy* of the recipe, and two validation rounds silently tested the
    stale copy and reported a contradiction that had already been fixed. And
    makepkg re-applies patches to an existing `src/`, so every case that reaches
    `prepare()` needs a clean `src/` or it fails on an already-patched tree — a
    harness fault that looks exactly like a recipe fault.
  - **AutoFDO/Propeller drift is a decision, not a default.** The installed
    7.2.5 kernel was built with `AUTOFDO_CLANG=y` and `PROPELLER_CLANG=y`; the
    recipe defaults both to `no`, so the first default rebuild replaces an
    optimised kernel with a plain one and warns nowhere. The header records it
    and `prepare()` asserts the off state, so the swap is at least visible.
  - **A verification failure is fatal on purpose.** Shipping a kernel whose
    options silently differ from the recipe's own declaration is worse than not
    shipping one — the whole point of the exercise is that the recipe cannot
    lie about itself.

## 2026-09-19 — kernel: the build freezes were CVE-2026-90432; recipe moved to the CachyOS RC channel

- **Symptom**: any build could hard-freeze the machine — last frame stuck, no
  keyboard or mouse, hard power-off the only recovery — and it was independent
  of build weight. Nothing was ever recorded: no panic, oops, MCE, RCU stall,
  hung-task report or OOM in any retained journal.
- **Root cause**: `CVE-2026-90432`, "sched_ext: Abort directly from the
  hardlockup handler" (Tejun Heo, 2026-07-27; `Fixes: bd2d76455b65 "sched_ext:
  Defer scx_hardlockup() out of NMI"`). `scx_hardlockup()` deferred the abort to
  an `irq_work`, and *"the perf watchdog fires on the hard-locked CPU itself,
  where a queued irq_work never runs with IRQs off"* — so a stalled sched_ext
  scheduler left that CPU hard-locked for good. The same commit notes the
  handler *"used to return %true whenever sched_ext was loaded, suppressing the
  kernel's hardlockup report even when the abort was refused"*, which is why
  every journal was blank. Affected `7.1 <= v < 7.2.6`; fixed in 7.2.6+ /
  7.3-rc1+. Stable backport `4d6270bbb…`, upstream `3c4b38064…`, file
  `kernel/sched/ext/ext.c`.
- **Why it was hard to see**: every crash kernel (7.2.2-1, 7.2.3-ck1-1,
  7.2.4-ck1-1, 7.2.4-1.1, 7.2.5-1) lies inside the affected range, so the earlier
  "six kernel packages crashed, therefore not a kernel regression" reading was
  wrong; the one kernel never booted during a crash (`linux-cachyos-lts` 6.18.52)
  is the one outside the range. The trigger is a fork/exec + I/O storm — i.e.
  any build — which is why build weight never mattered. Upstream's own analysis
  (`sched-ext/scx#3687`, closed 2026-08-18) describes the same framework-side
  fault affecting **all** sched_ext schedulers, with the same workload shape
  ("fork/exec-heavy I/O load", "concurrent fsync, `O_DIRECT` and fork-mode I/O"),
  and measured 1 unrecoverable freeze in 30 induced stall runs on a 12-CPU guest
  — this host has 24 threads. Field report `sched-ext/scx#3667` names
  `scx_pandemonium` directly. The 2026-09-18 texlive freezes are the same fault:
  that workload is the same fork/exec + I/O pattern, so the NVMe-ASPM /
  `ananicy-cpp` / zram leads are retired.
- **Why nothing was captured**: besides the CVE suppressing the report, the host
  had `nowatchdog` (so `nmi_watchdog=0`), `hardlockup_panic=0`,
  `panic=0`/`panic_on_oops=0`, `kernel.sysrq=16` (sync only) and a 5-minute
  journald `SyncIntervalSec`. It was configured to be undiagnosable. The chain is
  now armed — see `MEMORY.md` §5.
- **Fix**: `packages/misc/linux-cachyos` moved from the 7.2 stable channel to the
  CachyOS RC channel — `_major=7.3`, `_rcver=rc3`, `_tagrel=4`,
  `pkgver=${_major}.${_rcver}` = `7.3.rc3`, `_srctag=cachyos-7.3-rc3-4`.
- **Version-sensitive follow-on**: `_patchsource` is scoped by `_major`, so one
  bump invalidates every patch filename. The 7.3 set has no
  `misc/0001-rt-i915.patch` (CachyOS added it to 7.2 on 2026-06-29 and never
  carried it forward; it touches `drivers/gpu/drm/i915/` and `kernel/ksysfs.c`,
  so its absence affects Intel GPUs only), no `sched/0001-prjc-cachy.patch` and
  no `misc/0001-hardened.patch`, and the nvidia patches renumber
  (`0002`/`0003` → `0001`/`0002`, plus a new `0003-Pass-dmem_cgroup_init…`).
  CachyOS's own 7.3 RC PKGBUILD still names rt-i915, but only in a branch its
  default `_cpusched=cachyos` cannot reach — dead code there, a 404 here.
  `config` was replaced with `linux-cachyos-rc/config`: 185 lines differ from the
  7.2 rt-bore config, 12 of them tool versions and the rest symbol churn, while
  `PREEMPT`/`PREEMPT_DYNAMIC`/`HZ=300`/`NO_HZ_FULL`/`RCU_BOOST` are identical and
  the variant identity is applied by `scripts/config` anyway. `_nv_ver` also
  moved 610.57.04 → 615.71.09 to match upstream.
- **Trap worth remembering**: the recipe's startdir *is* `SRCDEST`, and the
  tracked patch files sitting there are what makepkg actually uses — so
  `updpkgsums` printed "Found <file>" and re-summed the stale 7.2
  `0001-bore-cachy.patch` (40,750 B) instead of fetching the 7.3 one (42,503 B).
  Green sums, wrong patch. Replaced by hand; `0001-rt-i915.patch` deleted as
  unreferenced.
- **Validation**: tarball signature `Good signature from "Peter Jung
  <admin@ptr1337.dev>"`, fingerprint
  `E8B9AA39F054E30E8290D492C3C4820857F654FE` — matching `validpgpkeys`, so no
  `--skippgpcheck`; both patches apply cleanly to the extracted
  `cachyos-7.3-rc3-4` tree (`patch -Np1 --dry-run`); `PREEMPT_RT`, `SCHED_BORE`
  and `CACHY` still exist in the new tree, so no silent variant loss;
  `bash tests/run-all.sh` PASS (20 fixtures), including the repo-wide
  `srcinfo-freshness` (126 recipes); `--audit`, `--list` and `--dry-run -g misc`
  clean. The earlier 6-minute `-c --no-deps bettbox` rebuild passed (Tctl 91 °C)
  but ran with sched_ext unloaded, so it is a smoke test, not a control.
  The hand-holding this bump needed is now pinned by
  `tests/kernel-recipe-version.sh`: the tarball URL must name `pkgver`, and every
  `_patchsource` URL must sit under the `pkgver`'s major. Verified red on both —
  a hardcoded `_srcname` and a patch set scoped to `master/7.2` each fail with a
  named reason, and both were reverted before the run.
- **Still open**: the 2026-09-01 cluster — four unclean shutdowns inside 27
  minutes, the first ten minutes after `ryzenadj` + `ryzen_smu-dkms-git` were
  installed and **before `scx-scheds-git` existed** — cannot be this CVE. See
  `MEMORY.md` §5.
- **Rule**: before blaming a workload for a hard freeze, check the build host's
  kernel against the sched_ext abort/lockup CVEs; and when a freeze leaves *no*
  trace at all, suspect a handler that suppresses the report rather than an
  absence of faults.

## 2026-09-19 — bettbox: a host freeze corrupted the Go module cache

- **Symptom**: `fish build-all.fish -g third-party` failed inside bettbox's
  `build()` — `run go mod tidy` →
  `verifying github.com/xyproto/randomstring@v1.0.5: zip: not a valid zip file` →
  `Unhandled exception: go mod tidy error` (`setup.dart:167`). The recipe was not
  at fault.
- **Root cause**: the host had hard-frozen and been powered back on at 12:28. XFS
  log recovery restored metadata without the data of the last seconds, so files
  existed with plausible sizes and mtimes and **zeroed content**. In `~/go`: 17
  module zips of size 0, 19 `.ziphash` files of the correct length but entirely
  NUL, 32 of 149 extracted trees holding zero-length files, 17 zero-length
  `~/.cache/go-build` entries. The all-NUL hashes are the dangerous half — Go
  caches "verified" there, so it never re-downloads the module and the failure
  surfaces later (`zip has been modified`) or not at all.
- **Not the recipe, not the network**: the tarball's sha256 matched the PKGBUILD
  (`7e6ed765…`), `proxy.golang.org` served the module, the vendored
  `core/Clash.Meta` tree was complete (1035 files, 7.4 MB), and the Flutter/pub
  caches were clean. `bettbox` is the repo's only Go recipe.
- **Red signal**: `cd .../Bettbox-1.19.2/core && go mod verify` — seconds,
  read-only, and it named every damaged module.
- **Fix**: `go clean -modcache && go clean -cache` — a deliberately blunt purge,
  because the damage class is "size preserved, content zeroed" and a surgical
  purge cannot see all of it. The rebuild then re-downloaded all 149 modules and
  completed: `✓ bettbox (5m56s)`, archive `bettbox-1.19.2-1-x86_64.pkg.tar.zst`
  (50 MB), and `go mod verify` → `all modules verified`.
- **A second, unrelated break found while fixing it**: the committed `.SRCINFO`
  was still at 1.19.1 with the *previous* tarball's sha256 while the PKGBUILD was
  1.19.2 — a version bump that never re-ran `--printsrcinfo`. Only three fixtures
  checked `.SRCINFO`, each its own recipe, so the other 123 were unchecked; a
  recipe consumed through `.SRCINFO` would have built the wrong sources against
  the wrong sums.
- **New tooling**: `tools/go-modcache-check.sh` — read-only detector for the four
  detectable damage classes (zero-length zip, all-NUL `.ziphash`, zero-length
  record, zero-length `.go` inside an extracted tree; `.lock` is legitimately
  empty and is skipped), with `--purge` to remove the affected module's record and
  tree. `tests/modcache-check.sh` drives it against a synthetic cache and keeps a
  damaged **decoy** cache it is never pointed at, which must survive untouched.
  `tests/srcinfo-freshness.sh` generalises the per-recipe `.SRCINFO` check across
  all 126 recipes from `config/packages.map` (~32 s at `-P 8`;
  `GSA_SRCINFO_JOBS` overrides the parallelism).
- **Validation**: `go mod verify` clean, `✓ bettbox (5m56s)` with the archive
  produced, `bash tests/run-all.sh` → **PASS (19 fixtures)**.
- **Rule**: after any unclean shutdown, treat freshly written files as suspect and
  verify the consumer before blaming the recipe — for Go, `go mod verify`, and
  `go clean -modcache` whenever a file could have kept its size. A version bump
  must regenerate `.SRCINFO` in the same commit, and a repo-wide fixture now
  enforces that.

## 2026-09-19 — hard freezes: the capture chain is armed, and the history is longer

- **Symptom (restated)**: a build kick-off freezes the whole machine — last frame
  stuck, no keyboard or mouse input, only a hard power-off recovers it. Two more
  this session (11:55:48→12:01:07, 12:28:03→12:43:03). It also zeroed the
  authoring session's own `plan.md`, the same write-loss that corrupted the Go
  cache above, and zeroed a restored copy of the bettbox plan.
- **New: the freeze is chronic, not a 2026-09-18 episode.** `last -x` over the
  whole wtmp (the machine was installed 2026-08-31 15:20) shows ~23 unclean
  shutdowns, and the *first* is **2026-09-01 00:37 — ten minutes after
  `ryzenadj` and `ryzen_smu-dkms-git` were installed at 00:33/00:36**, with four
  inside 27 minutes. They continue on 09-05, 07, 08, 09, 10 (six), 11, 14, 17, 18
  (three) and 19 (two), across **four** kernel packages (`7.2.2-1-cachyos`
  bore-lto, `7.2.3-ck1-1`, `7.2.4-ck1-1.1`, `7.2.5-1` rt-bore-lto) — so it is not
  a kernel-version regression. `scx-scheds-git` was not installed until 09-03
  17:52, so sched_ext cannot explain the first night.
- **Why every freeze was silent, and what changed.** The configuration forbade
  evidence: `nowatchdog` on the cmdline (`nmi_watchdog=0`, `watchdog=0`), every
  `*_panic` sysctl 0 including `panic`/`panic_on_oops`, `kernel.sysrq=16` (sync
  only — no recovery key worked), and journald's 5-minute default flush losing the
  final seconds every time. The 2026-09-18 entry left "make sysrq persistent and
  drop `nowatchdog`" outstanding; that is now done, plus:
  - `/etc/sysctl.d/99-diagnostic.conf` — `watchdog_thresh=30`, watchdog and both
    lockup detectors enabled, `softlockup_panic`/`hardlockup_panic`/
    `softlockup_all_cpu_backtrace`/`hung_task_panic`/`panic_on_oops`=1, `panic=10`,
    `sysrq=1`, re-applied every boot.
  - `/etc/default/limine` — `nowatchdog` removed and
    `hardlockup_panic=1 softlockup_panic=1 softlockup_all_cpu_backtrace=1
    hung_task_panic=1 hung_task_timeout_secs=120 panic_on_oops=1 panic=10
    efi_pstore.pstore_disable=N` added; `limine-update` regenerated all three boot
    entries.
  - `/etc/systemd/journald.conf.d/10-diagnostic.conf` — `SyncIntervalSec=1s` (was
    the 5-minute default) and `SystemMaxUse=1G`, overriding the vendor 50 MB cap.
  - `gsa-heartbeat.service` — a timestamp to `/var/log/heartbeat.log` and the
    journal every 5 s, which separates "the kernel died" from "the display died".
- **Closure (2026-09-20): the chain is gone, because it answered its question.**
  CVE-2026-90432 in the sched_ext fork/exec path was the cause (2026-09-19 entry
  above), the kernel moved past it, and a diagnostic left armed past its question
  is only unmeasured overhead — so the list above was dismantled:
  `/etc/sysctl.d/99-diagnostic.conf`, `gsa-heartbeat.service` with
  `/usr/local/bin/gsa-heartbeat.sh` and `/var/log/heartbeat.log`,
  `/etc/systemd/journald.conf.d/10-diagnostic.conf`, and the eight parameters
  added to `/etc/default/limine` were all removed; `limine-update` regenerated
  all four boot entries at 09:35 and the running boot keeps the old chain until
  the next reboot. `tools/texlive-split-probe.sh` and `tests/probe-watchdog.sh`
  went with them (both deleted in commit `b1eaf00`). Everything is backed up in
  `/root/freeze-diag-backup-20260920/`, and the pre-cleanup command line is at
  `/etc/default/limine.bak-20260920-pre-diag-cleanup`
  (`/etc/default/limine.bak-20260919-freeze-diag` is the earlier, pre-diagnosis
  one and still carries `nowatchdog`). The two lessons below are the durable
  half and are why re-arming is worth doing *first*, not after.
- **`efi_pstore` was disabled by default** (`pstore_disable=Y`), so
  `/sys/fs/pstore` had never been able to receive anything despite being mounted
  and empty since installation. Set to `N`, the chain was validated at 13:09 with
  a deliberate `Alt+SysRq+c`: `Kernel panic - not syncing: sysrq triggered crash`
  landed in pstore in 17 compressed records and the machine self-rebooted in 27 s
  on `panic=10`. **The panic never reached the journal** — pstore is the channel
  that survives, which is exactly why it had to be enabled first.
- **One full-length rebuild has since passed**: bettbox, 6 minutes, 149 modules
  re-downloaded, Tctl peaking at 91 °C against a 92 °C limit — no freeze. That run
  had the undervolt applied but `sched_ext` unloaded (`/etc/scx_loader.toml` was
  rewritten at 13:00:46 without `default_sched`; `dmesg` shows pandemonium
  unregistering at uptime 965 s), so it is an sched_ext-free data point, **not** a
  control.
- **Hypotheses, none confirmed**: (a) the `ryzenadj` undervolt applied at every
  login — present at *every* crash including the four that predate scx, though the
  maintainer's counter-evidence is that a −14 global offset survived single-core
  builds; the untested half is the per-core `--set-coper` path, whose
  `core<<20 | offset` packing is hand-rolled, whose CO value cannot be read back
  (`--dump-table` has no CO field), and whose `ryzenadj` exit status the script
  discards; (b) `scx_pandemonium` under a fork/exec storm; (c) the pre-existing
  NVMe ASPM/device lead. On (c): the link does run ASPM L1 + L1.2 (`LnkCtl: ASPM
  L1 Enabled`, `L1SubCtl1: PCI-PM_L1.2+ ASPM_L1.2+`) with the policy now
  `default`, but **all AER counters are zero** on both the device and its root
  port, the NVMe error log is empty and SMART reports 0 media errors — absence of
  evidence, not evidence.
- **Still queued at the time** (all superseded by the CVE finding): a real
  ASPM-off differential (removing `pcie_aspm=powersave` only moved the policy to
  `default`, which still enables L1 — it needs `pcie_aspm=off`), `ananicy-cpp`
  (still active), the zram resize
  (`zram-size = ram * 2.5` = 74.9 GB of RAM-backed swap on a 29 GiB machine, and
  with `zswap.enabled=0` it is the only swap), and a phase-free 20 GB write
  burst. The last one needed the probe, which no longer exists.
- **Rule**: arm the capture chain *before* investigating a hard freeze — lockup
  detectors with `*_panic=1` so a wedge panics and reboots leaving a trace,
  `kernel.sysrq=1` so `Alt+SysRq`+`l`/`w`/`b` can dump and sync, a 1 s journal
  flush, a heartbeat witness, and pstore (check `pstore_disable`; it defaults to
  `Y`). And count crashes from `last -x` over the whole wtmp rather than the
  retained journals — journald keeps about a day, which hides how long a problem
  has existed.

## 2026-09-18 — copilot-instructions told agents to commit, not to ask

- **Symptom**: the agent instruction file stated that the host's commit routine
  was inherited unchanged and that "a completed task ends in its own descriptive
  commit, pushed". The host file at `~/.copilot/copilot-instructions.md` says
  the opposite — always ask whether to commit, commit & push, or leave the tree
  alone — so an agent reading only the repository instructions would commit and
  push unprompted.
- **Root cause**: commit 18d1011 added the host-comparison section and folded
  the commit routine into the inherited-unchanged list while introducing it.
  Nothing else in the file addressed committing, so the mischaracterisation
  stood as the only statement on the subject.
- **Fix**: the relationship section now claims workspace isolation alone as
  inherited unchanged, and a new **Committing** convention under Conventions
  restates the host rule concretely — ask first and let only the answer decide,
  never treat a green fixture battery as consent, and carry the host's trailer
  verbatim on a body shaped like the rest of the log.
- **Validation**: the trailer string compares byte-for-byte identical to the
  host file; `bash tests/run-all.sh` passes (16 fixtures) and no fixture reads
  the instruction file, so the change is documentation-only; `docs/MEMORY.md`
  carries no competing commit rule.
- **Rule**: when this file classifies a host rule as inherited unchanged, read
  the host wording first. An ask-first rule cannot be restated as an automatic
  action, and a prompt is not a default.

## 2026-09-18 — logseq-desktop-git: three build incidents (condensed) — Java virtual, pnpm workspace root, opam switch resume

Three same-day incidents on one recipe, folded here; the individual
verification loops are preserved in the recipe fixture.

- **A concrete Java dependency demanded the removal of the JDK** (first
  failure): `makedepends` named `jre-openjdk`, which conflicts with the
  `jdk-openjdk` that `clojure` — the same `makedepends` — requires, so
  pacman's only resolution was to remove the JDK. Nothing compiles Java
  (shadow-cljs emits JavaScript). Fix: `'jre-openjdk'` → `'java-runtime'`
  (every JDK and full JRE provides the virtual). Verify with `pacman -T` over
  depends+makedepends — that is exactly makepkg's own gate. Rule: request a
  capability through its virtual, never one concrete provider (golden rule 4);
  a concrete provider can be *mutually exclusive* with another package the
  same dependency graph needs, making the graph unsatisfiable rather than
  merely narrow.
- **pnpm installed the repo root instead of `static/`**: the upstream tree's
  root `pnpm-workspace.yaml` has no `packages:` field, so a `pnpm install`
  from inside `static/` resolves the ROOT project, exits 0 in half a second,
  creates no `node_modules`, and the failure surfaces one step later as
  `Command "electron-builder" not found` — `--frozen-lockfile` cannot catch
  an install that succeeded on the wrong project. Fix: `pnpm install
  --frozen-lockfile --ignore-workspace` in both `cli/` and `static/` (the
  flag is load-bearing). Side effects were checked, not assumed: the flag
  detaches the install from the root `.npmrc` allowlists and
  `shamefully-hoist` — harmless here because electron-builder fetches the
  Electron distribution itself and the static `postinstall` rebuilds
  `keytar`; the full payload (`static/dist/linux-unpacked/logseq`,
  `chrome-sandbox`, `app.asar`, `sidecar`) was verified in place. Rule: a
  `pnpm install` in a subdirectory of a tree whose root has a
  `pnpm-workspace.yaml` must pass `--ignore-workspace` unless that
  subdirectory is a declared workspace member; treat a successful install
  that creates no `node_modules` as the symptom.
- **A resumed build aborted on `opam switch create`** (found while validating
  the fix above): `build()` restarts from the top while `$srcdir` persists,
  and `opam switch create` exits 2 on an already-installed switch, which
  errexit turns into an abort before the first bundle — the recipe was
  single-shot per source tree. Fix: create the switch only when absent
  (`opam switch list --short | grep -Fxq` guard), OCaml 5.1.1 pinned to
  match upstream CI. Rule: every `build()` step must be idempotent —
  `opam switch create`, `mkdir`, `patch`, a bare `git clone`.
- **Validation**: `tests/logseq-desktop-recipe.sh` pins all three (the
  `--ignore-workspace` flag, `java-runtime` with no `jre|jdk` entry, the
  switch guard), each red-verified; `.SRCINFO` regenerated — the fixture's
  parity check caught the stale file.
## 2026-09-18 — texlive prepare(): two hard freezes, and a split loop that lost 8 minutes

- **Symptom**: building `texlive-texmf` froze the whole machine twice — once
  during the source fetch (08:40:54), once 43 s into `prepare()`'s split loop
  (10:41:38). The screen stopped, no CPU load was visible, and only a hard power
  reset brought it back. There was no log: the run's own log lived in `.state/`,
  which no longer exists, and nothing was captured before the reset.
- **What the journal still had**: it is persistent, so the frozen boot survives.
  Boots `-2` and `-1` are the only two of the last fourteen that end without a
  shutdown message, and both end during the texlive build. Nothing else — no OOM
  kill, no `systemd-oomd` action, no hung-task warning, no XFS error, no NVMe
  error, no `Call Trace`. The journal simply stops mid-stream, which is what a
  wedged device or a dead kernel looks like from outside. In the last run the
  loop had moved basic/bibtexextra/binextra/context (9.3k files) and 4,521 files
  into `fontsextra` when it died — ~14k renames and ~330 spawns/s, far too
  little to kill a machine by saturation.
- **Three configuration choices made it undiagnosable and unrecoverable**:
  `/etc/default/limine` carries `nowatchdog` (no lockup detector, so a kernel
  hang leaves no trace) and `loglevel=3` (warnings off the console), and
  `kernel.sysrq=16` disables every SysRq recovery key — a hard reset was the only
  way out. The drive reports **63 unsafe shutdowns**.
- **What measurement ruled out** (a temporary host sampler, `texlive-split-probe.sh`,
  written for this investigation and [removed 2026-09-20](#2026-09-19--hard-freezes-the-capture-chain-is-armed-and-the-history-is-longer)
  in commit `b1eaf00`, once the cause was known): the split
  loop itself. The real loop, extracted from the PKGBUILD at run time, running on
  a hardlink farm at full `fontsextra` scale — 105,846 files moved in 264 s —
  produced **io PSI 0.00 throughout, at most 2 processes in D state, peak device
  utilisation 16 %, memory flat, zram untouched**. The loop's work does not
  saturate this machine; the trigger needed something that was present then (the
  19 GB source fetch, a concurrent lane, or an intermittent device fault) — and
  it turned out to be the kernel itself (CVE-2026-90432). The prime suspect
  recorded here, the NVMe link (ASPM L1 + L1.2 on a **WD SN560**, which this
  entry said the cmdline forced via `pcie_aspm=powersave`), **rests on a premise
  that was never true**: checked 2026-09-20, there is no `pcie_aspm=` token in
  `/proc/cmdline` or `/etc/default/limine` and the policy reads `default` — the
  L1 state is the firmware default. The queued differentials (ASPM off,
  `ananicy-cpp` stopped, zram off) are therefore moot rather than pending.
- **Fixed regardless — the loop was the recipe's hot path**: 4,115 full rescans
  of the 18.7 MB tlpdb plus one `mkdir -p` + one `mv` per file (301k process
  spawns). It now cuts the tlpdb into per-package sections in ONE awk pass,
  extracts runfiles/formats/maps/hyphens with shell builtins, and issues the
  renames per destination directory in batches. Fixture: **37 spawns vs 2,482**
  (67x fewer). Real data: **0.94 s vs 13.79 s** for `fontsrecommended` (5,299
  files, 14.7x). The whole split drops from ~8 minutes to well under a minute,
  which shrinks the window in which a stall can happen at all.
- **Also fixed — a silently broken package**: the loop MOVES files out of
  `texmf-dist`, so a build resumed over an already-split tree produced packages
  with files missing. In this checkout **13,870 of 150,746** planned runfiles were
  already gone. `prepare()` now counts the gaps and refuses, printing the count,
  the reason, up to five of the missing paths, and the remedy (`rm -rf src`).
- **Validation**: `tests/texlive-split.sh` runs the previous implementation
  (frozen as `tests/assets/texlive-split-legacy.sh`) and the live one over the
  same synthetic tree and requires identical type/mode/path/symlink listings,
  identical content hashes, identical `pkgdesc-*`/`depends-*`/`packages-*` and
  `.fmts`/`.maps`/`.dat*`, plus the spawn reduction and the depletion refusal. On
  real data both implementations produced 6,098 identical tree entries and 5,302
  identical file hashes. The fixture earned its keep during the rewrite: an
  accumulated `AddFormat` list that kept a trailing newline made the follow-up
  `read` loop iterate once more and the `grep` match a second time.
- **Outcome (same day, resolved as "not the recipe")**: the maintainer ran the
  frozen pre-rewrite loop at full `fontsextra` weight from a console with no
  compositor and it **completed**; then built the package for real with
  `makepkg -si` in the desktop session and it **built and installed** (23
  archives, `texlive-meta` 2026.1-1 at 13:10, ~4 min of split on a fresh 19 GB
  checkout). So two independent full-weight runs of the exact workload that was
  mid-flight both freezes have since finished. A workload that resolves the
  symptom does not reproduce it, which leaves an intermittent device or kernel
  fault as the remaining explanation, and the ASPM/zram/ananicy differentials in
  `MEMORY.md` §5 as the next step. Nothing was changed on the host to make the
  builds succeed.
- **The part worth keeping: the freezes were diagnosable only by luck.** The
  journal was persistent, so `journalctl -b -1` still held the dead boot's kernel
  log; the recipe's own log did not exist (`.state/` was gone), and no lockup
  detector was armed (`nowatchdog`), no recovery key worked (`kernel.sysrq=16`),
  and a wildcard `rm -rf /tmp/texlive-split-probe.*` deleted the samples of a run
  that was still in flight. The probe was deleted with the diagnosis chain
  (`b1eaf00`), but the habit it taught is not: a sampler that aborts without keeping its evidence has thrown away the
  experiment, and nobody should clean `/tmp` by glob while a measurement is
  running.
- **Rule**: a bulk `prepare()` that moves files must (a) refuse to run on
  incomplete inputs instead of shipping a quietly broken package, and (b) be
  batched — these loops cost process spawns, not bytes. And when a machine
  hard-freezes with "no CPU load": read `journalctl -b -1` first (the frozen
  boot's kernel log survives the reset), and switch `kernel.sysrq` back on before
  blaming the workload.

## 2026-09-17 — sudo keepalive stopped runs for nothing, then spammed

- **Symptom** (screenshot from a `-i` run): a three-line block — "sudo timestamp
  expired and cannot be refreshed non-interactively — stopping dispatch" —
  repeated every poll for as long as lanes kept building, while the dashboard
  sat on `▲ STOPPING`. Dispatch stopped; when the in-flight lanes happened to
  succeed, the run then printed **"All builds succeeded! Built: 0 packages"**.
- **Root cause 1 — the probe measured the wrong thing.** `sudo -n -v` was used
  as a proxy for "an install can run". On this host it is not:
  `/etc/sudoers` has `(ALL) ALL` *and* `(ALL : ALL) NOPASSWD: ALL`, so
  `sudo -n -v` fails forever (the password rule owns validation) while
  `sudo -n pacman -U …` succeeds every time — verified live:
  `sudo -n -v` → rc=1, `sudo -n pacman --version` → rc=0. The keepalive fired
  ~150 s in (the cached credential had aged past its timeout by then), declared
  the credential dead, and stopped a run whose installs were never at risk.
- **Root cause 2 — the failure path had no memory.** `last_sudo` was only
  updated on success, so once the probe failed the branch re-fired on every
  0.5 s poll and re-printed the whole message; nothing latched.
- **Root cause 3 — a stopped dispatch reported success.** `run_lanes` returned
  0 whenever no package had *failed*, so packages that were never dispatched
  disappeared into "All builds succeeded! Built: 0 packages".
- **Fix** (`build-all.fish`):
  - `sudo_probe` classifies `fresh` (`sudo -n -v` refreshed), `nopasswd`
    (`-v` refused but `sudo -n pacman` works → nothing to keep warm) or `cold`,
    and the last of those probes the mechanism the lanes themselves use, so its
    answer cannot be rosier than an install would be.
  - An `-i` preflight settles sudo *before* building: it refreshes, or
    self-elevates, or refuses to start. Building for an hour to discover that
    the installs cannot happen was the old behaviour.
  - `sudo_elevate_interactively` lets the dispatcher ask for the password
    itself (it owns the terminal; lane children never do), gated on stdin
    being a terminal and bounded by `timeout` so an unattended run cannot hang.
  - The cold path latches (`sudo_state = down`): one message, one stop, no
    repeats — and if packages were left unstarted the run exits non-zero with
    `_RL_SUDO_NOTE` replacing the misleading "Build failed" heading.
- **Fixing that exposed a second, older bug** (same subsystem, found because the
  new fixture tails lane stderr): `set -gx MAKEFLAGS (string join ' ' $make_flags)`
  always failed — fish hands every argument after the first to `string`'s own
  option parser, so `-j4` produced `string join: -j4: unknown option`, the
  substitution aborted, and **MAKEFLAGS was never exported to a lane**. The
  per-lane job budget therefore never reached upstream Makefiles (only
  `GSA_BUILD_JOBS`, which the workspace's own PKGBUILDs read, did). Fixed with
  a quoted list expansion (`set -gx MAKEFLAGS "$make_flags"`), which joins with
  spaces and cannot be parsed as an option.
- **Tests**: new `tests/sudo-keepalive.sh` drives four real sudoers shapes
  (`nopasswd`, `cold`, `expires` mid-run, `promptable`) through the actual
  dispatcher with a fake `sudo`/`pacman` and a virtual clock (the 150 s
  interval elapses inside a 10 s fixture), including a pty sub-case via
  `script` that proves the dispatcher prompts exactly once and carries on. It is
  red on the previous script ("nopasswd run stopped dispatch although installs
  need no password"). `tests/scheduler-intensity.sh` now asserts each lane's
  exported `-j` budget in `MAKEFLAGS`/`NINJAFLAGS`/`GSA_BUILD_JOBS`, which is
  red on the old `string join` form.
- **Rule**: probe a capability with the mechanism the code will actually use,
  never with a neighbouring command that merely looks equivalent; and a run
  that stops before dispatching everything is a failure, not a success.

## 2026-09-17 — structure audit, phases A–C (condensed): dead CLI surface, dead control data, documentation truth pass

One audit in three passes, folded here; each phase kept its rule.

- **Phase A (builder)**: dead function `find_audit_pkg_dirs` and the
  `-si/--sepinstall` alias removed (`-i` is the only spelling of the
  immediate install; `-si` now reports `unknown option`); the three legacy
  audit scans collapsed into one widened `rg` pass matching every pre-Git
  layout name (`.Stable|.Static|.Heavy|.Heavyweight|.Core|.Misc|.3rdP/`);
  the byte-identical `--lanes`/`--jobs` validation blocks deduplicated behind
  `parallelism_is_valid`; `-ia/--installall` kept and documented as the
  one-transaction escape hatch that structurally cannot satisfy rule 11.
  Rule: an option, function, or audit arm that cannot change any outcome is a
  stale claim about how the project works — delete the CLI surface in the
  same pass that retires the behaviour, and when an audit section can only
  print `none`, either widen what it looks for or remove it.
- **Phase B (control data)**: `config/packages.map`'s dead third field
  (`original-path`) removed — the loader stores only `$id|$path`, so the
  column was parsed and thrown away (its only consumer was the loader's own
  field-count guard); the map is now exactly `package-id|recipe-path` and a
  three-field record fails with `invalid package map record`. Dead and
  self-hiding `.gitignore` rules removed (a bare `*` ignore hides the ignore
  file itself). New repo-wide `tests/recipe-sources.sh` (every non-URL
  `source=()` entry and `install=` script exists, is committed, and no ignore
  rule hides it — 118 local sources, 11 install scripts at baseline, each
  assertion red-verified) and the discovering runner `tests/run-all.sh`.
  Rule: dead control data is worse than a missing feature — it looks like
  authority; delete it in the same change that retires the layout it
  describes, and never trust a per-recipe guard to cover a repo-wide
  invariant.
- **Phase C (documentation truth pass)**: every stale claim in `MEMORY.md`
  §2/§3/§5, `architecture.md`, `portability.md`, `README.md`,
  `build-guide.md` and `CONTRIBUTING.md` was checked against the host or the
  code and rewritten rather than softened — §5's pending list re-verified
  with pacman (most items already done; the ROCm row was wrong in the
  opposite direction), §3 rewritten as version-free durable facts
  (`pacman -Q` is authoritative), golden rule 1's "non-GNU ls" blame
  corrected to the CachyOS fish aliases, runtime-state ownership corrected
  (`.state/` holds builder state only; `SRCDEST`/`PKGDEST` land beside each
  recipe), `portability.md`'s one host's numbers replaced by the formulas
  from `run_lanes` (recomputed for the fixture's pinned inputs), the
  prerequisite lists aligned with `check_runtime_prereqs`, and this journal
  gained its naming-history preamble. Rule: docs that state current state rot
  silently — state *how to check* (a command, a formula, a pointer) instead
  of copying the answer, keep dated snapshots in the journal, and re-verify a
  pending-task list against the host before trusting any item on it.
## 2026-09-17 — stray `config/groups` inventory removed

- **Symptom**: `config/groups/physical-groups.list` sat in the directory the
  builder loads group definitions from and looked authoritative, but nothing in
  the tree referenced it.
- **Character in the build script**: it was never read. `read_group_config` is
  called for exactly the five declared names
  (`for group_name in git stable core misc third-party`), and `resolve_group`
  switches on those same five, so `--group physical-groups` is rejected (rc=1)
  without any file being opened. Even if it were read, its tab-separated
  `category<TAB>package-id` lines fail the loader's `^[A-Za-z0-9._+-]+$` check
  and it would report `invalid package group`.
- **Staleness**: it was a publication-time snapshot that was already wrong when
  created — its 123 entries missed `core cmake-git` and `stable mkinitcpio`, and
  by now also missed `git logseq-desktop-git` and `git texlive-texmf`.
- **Redundancy**: its whole content is derivable from `config/packages.map`
  (`awk -F'|' 'NF>=2 && $0 !~ /^#/ {n=split($2,a,"/"); print a[2]"\t"$1}'
  config/packages.map | sort`), so nothing is lost by deleting it.
- **Fix**: deleted the file. Nothing else changed — the loader never opened it,
  `--group physical-groups` behaves identically before and after (rejected,
  rc=1, no output), and every group command still validates the five real files
  through `load_project_config`.
- **Guard**: `tests/project-config.sh` now asserts that `config/groups/`
  contains exactly the five declared groups, so a stray file there (an
  inventory, a `.bak`, a hand-made list) fails the fixture instead of drifting
  silently.
- **Validation**: `tests/project-config.sh` plus the whole fixture battery,
  `--list`, `--audit` and `--dry-run` for the five groups all pass after the
  removal.
- **Rule**: a file living in a directory the builder reads, but unreachable
  through that directory's loader, is a trap — either wire it up or delete it;
  never keep a stale duplicate of another control file.

## 2026-09-17 — texlive-texmf recipe (TeX Live collections, meta closure)

- **Task**: be able to build the 19 `texlive-*` packages that
  `paru -S texlive-meta` would install, tracking upstream, in the `git` group.
- **Finding**: those 19 packages are exactly `texlive-meta` plus its depends
  closure, and the dependencies come from a single pkgbase. Arch builds the
  whole collection set from `texlive-texmf`, whose three pinned SVN sources
  (`Master/{texmf-dist,tlpkg,bin/x86_64-linux}`, `#revision=78408`) are split
  per collection by `prepare()` from `tlpkg/texlive.tlpdb`. The per-collection
  repositories visible in Arch's GitLab (`texlive-fontsextra`, ...) are stale
  leftovers: the shipped `extra/texlive-*` packages come out of
  `texlive-texmf`, and `texlive-doc`/`texlive-meta` are splits of it too.
- **Decision**: keep the recipe trimmed to the maintained target —
  `texlive-meta` plus the 22 non-lang collections. The 17 `lang*` collections
  and `texlive-doc` are dropped together with their `texlive-langextra`
  provides/replaces and the `groups=('texlive-lang')` branch. Only whole splits
  are removed, so `pkgrel` stays 1 and every retained package remains
  content-identical to the repository package at `2026.1-1`.
- **Finding (SVN sources)**: `makepkg` accepts a plain `svn://…#revision=N`
  source (no `svn+` prefix needed), caches the checkout in
  `$SRCDEST/<basename>` and refreshes it with `svn update -r`. The builder's
  `nuclear_cleanup` only understood `git+` VCS sources and `*.tar.*` downloads,
  so the recipe's `texmf-dist`/`tlpkg`/`x86_64-linux` checkouts (~3.5 GB) and
  the new `latexminted` wheel would have survived `--nuclear` forever. Fixed:
  `svn://`/`svn+` sources are now resolved like `git+` ones (name derivation
  matches makepkg's `get_filename`, verified against all three URLs) and
  `*.whl` is cleaned with the other downloads.
- **Finding (optimisation)**: `arch=(any)` means there is no compiler phase, so
  the ISA/LTO/PGO playbook cannot apply. Debug packages are produced by the
  strip tidy rule, so upstream's `options=(!strip)` also disables the debug
  split, and the host `makepkg.conf` already sets `!debug`. The applicable
  optimisation is scope, so the tlpdb splitting loop and the
  `texmf-dist/doc/*` skip were left verbatim (changing them would alter package
  contents) and `makedepends` stay at `subversion` only.
- **Validation**: `bash -n`, `makepkg --printsrcinfo` parity, `fish -n`,
  `--list`, `--audit` (no membership drift; dependency graph resolves) and
  `--dry-run --group git` pass, and the new `tests/texlive-recipe.sh` fixture
  is red-verified for a removed collection, a pkgver bump, a `_rev` bump, a
  restored `texlive-doc` split, a dropped `!strip`, an added `build()` phase,
  a removed SVN cleanup branch, and a missing support file.
- **Live upstream check**: `2026.1` is the newest tag, and the pinned revision
  resolves (`svn info -r 78408` succeeds for both
  `tags/texlive-2026.1/Master/tlpkg` and `.../texmf-dist`). Two traps found
  while checking, both now documented in `BUILDING`: `Revision:` from
  `svn info` is the *repository* revision (80294 at check time) while
  `Last Changed Rev` is only that directory's own last change (78234) — TeX
  Live keeps patching a tag after it is cut (r78237 and r78408 touched files
  under `tlpkg`), so the higher pin is deliberate; and an https fallback does
  not exist (`https://svn.tug.org/texlive/` and `http://tug.org/svn/texlive/`
  answer HTTP 406, so only `svn://` on port 3690 works). An earlier draft of
  `BUILDING` claimed an https alternative and was corrected.
- **Not run**: the full build (multi-GB checkout plus 23 splits), by request.
- **Rule**: when a distribution builds many split packages from one pkgbase,
  mirror that pkgbase rather than inventing per-split recipes; trim by deleting
  whole splits together with their depends/provides/paths, and state explicitly
  when a package has no compiler phase to optimise.
- **Flagged, then fixed in a follow-up commit**: `config/groups/physical-groups.list`
  was unreachable, stale control state. Removed; the reason is recorded in the
  entry above this one.

## 2026-09-17 — logseq-desktop-git recipe (desktop, upstream HEAD)

- **Task**: add a self-tracking Logseq desktop recipe to the `git` group that
  follows the house optimization standard.
- **Decision**: track upstream `master` (the 2.x database line;
  `src/main/frontend/version.cljs` carries `2.0.1`) rather than the 0.10.x
  maintenance line, because group recipes follow upstream HEAD. `pkgver()`
  reads the version the tree carries and appends the revision count and short
  hash, matching the noctalia-git idiom.
- **Finding**: upstream removed the ClojureScript CLI. The desktop app embeds
  a CLI runtime that is built by OCaml + Melange (`cli/dune`) and bundled by
  Vite, and `scripts/prepare-desktop-runtime-js.mjs` hard-requires
  `static/js/logseq-cli.js`. `ocaml` and `opam` are therefore real
  makedepends, not optional extras. The recipe creates a private switch under
  `$srcdir/opam-root` (never the builder's `~/.opam`) and pins OCaml 5.1.1 to
  match the upstream release workflow.
- **Finding**: the only valid build sequence is the one in
  `.github/workflows/build-desktop-release.yml`: `pnpm install`, `gulp build`,
  `cljs:release-electron`, `db-worker-node:bundle`, `opam exec -- pnpm
  cli:release`, `webpack-app-build`, `desktop:prepare-runtime-js`, then
  electron-builder inside `static/`. The published AUR `logseq-desktop-git`
  PKGBUILD is stale (yarn, electron-forge, 0.9.10) and is kept only as
  attribution.
- **Optimization standard**: the only compiled code is the two native Node
  addons (`@zvec/zvec`, `keytar`), so the recipe declares
  `options=(!strip !debug !lto)` and applies ccache plus the mold probe to
  those addons only. No ISA or optimization flags are hard-coded.
- **Packaging**: electron-builder runs with `--dir` (unsigned unpacked tree)
  instead of the upstream AppImage; the tree is installed under
  `/opt/logseq-desktop-git`, `chrome-sandbox` is installed setuid root, and
  `/usr/bin/logseq` reads extra flags from
  `${XDG_CONFIG_HOME:-$HOME/.config}/logseq-flags.conf`. Electron is bundled
  from the version pinned in `resources/package.json` rather than taken from
  the repositories.
- **Validation**: `bash -n PKGBUILD`, `makepkg --printsrcinfo` parity,
  `fish build-all.fish --list`, `--dry-run --group git` (55 packages) and
  `--audit` (no membership drift, graph resolves) pass, together with
  `tests/project-config.sh` and the new `tests/logseq-desktop-recipe.sh`
  fixture (red-verified against removed mold probe, `!lto`, `ocaml`
  makedepend, setuid bit, and branch). The full build was not executed here:
  it needs several GB of npm, Clojure, opam and Electron downloads, and a full
  rebuild is explicitly not a syntax check for this project.
- **Rule**: for a from-source Electron package, mirror the upstream release
  workflow literally, treat heavyweight toolchains (opam/OCaml) as real
  makedepends, and keep their state inside `$srcdir`.

## 2026-09-17 — mkinitcpio optional NvPCR glob failure

- **Symptom**: `mkinitcpio -P` failed for every kernel with
  `file not found: '/usr/lib/nvpcr/*.nvpcr'`; the generated image was
  reported as potentially incomplete.
- **Cause**: the Projects systemd recipe intentionally sets
  `-Dbootloader=disabled` for Limine, so it does not install systemd's
  optional NvPCR definition files. Stock `mkinitcpio 42-1` added an
  unguarded glob to its systemd and `sd-encrypt` install hooks.
- **Fix**: added a `mkinitcpio` stable recipe at `pkgrel=2` with a minimal
  patch that skips absent optional `.nvpcr` files, plus a regression fixture.
  The systemd bootloader choice remains unchanged.
- **Second failure (source verification)**: the first rebuild of the new
  recipe aborted with `unknown public key 6B5387E670A955AD`. The upstream
  `validpgpkeys` array lists only nl6720's primary key; the `v42` tag is
  signed by the newer NIST P-384 signing subkey
  `73B3CABFC4BF3F207641BD4B6B5387E670A955AD`.
- **Fix for the second failure**: verified the subkey fingerprint against the
  maintainer's published key (GitHub `nl6720.gpg`, GitLab Arch, keys.openpgp.org),
  added it to `validpgpkeys` next to the primary key, imported the verified key,
  and re-ran the build. No verification was skipped.
- **Validation**: the hook fixture passes with no `/usr/lib/nvpcr` directory;
  `git verify-tag v42` reports `Good signature`; the package builds, and the
  installed `mkinitcpio 42-2` ships hooks with the guard at
  `/usr/lib/initcpio/install/{sd-encrypt,systemd}`. `sudo mkinitcpio -P`
  regenerated every preset (Limine) successfully, including
  `linux-cachyos-rt-bore-lto` and stock `linux`.
- **Rule**: optional initramfs payloads must be guarded at the hook boundary;
  do not make an unrelated bootloader feature mandatory to satisfy an
  optional glob.
- **Re-verify** without touching the installed package by pointing the hook
  search path at a directory of copied hooks (`-D` replaces, not extends, the
  search path, so pass the parent containing `hooks/`, `install/`, and
  `post/`):

  ```sh
  sudo mkinitcpio -D /tmp/hookroot -g /tmp/red.img -k /boot/vmlinuz-linux
  sudo mkinitcpio -D /usr/lib/initcpio -g /tmp/green.img -k /boot/vmlinuz-linux
  ```

  Stock hooks report `file not found: '/usr/lib/nvpcr/*.nvpcr'`; the patched
  hooks finish with `Initcpio image generation successful`.
- **Rule**: when a signed tag fails verification, resolve the signer against
  the maintainer's published key and add the signing subkey fingerprint to
  `validpgpkeys`; never bypass the check.

## 2026-09-16 — Published recipe omitted by local ignore rule

- **Symptom**: a fresh checkout rejected `xorg-xwayland-git` during
  `build-all.fish --list` with `invalid package map path`, even though the
  package was listed in `config/packages.map` and `config/groups/git.list`.
- **Cause**: the source workspace's package-local `.gitignore` contained `*`.
  The migration copied the map entry but a normal `git add` skipped the
  recipe directory, leaving a mapped package with no published `PKGBUILD`.
- **Fix**: restored the recipe and `.SRCINFO` to the public tree without the
  wildcard ignore file, and added `tests/project-config.sh` to exercise the
  real listing path.
- **Rule**: after a package migration, run `build-all.fish --audit` and
  `build-all.fish --list`; every map entry must have a tracked `PKGBUILD`.
  Do not publish package-local wildcard ignore files that can hide recipe
  changes.

## 2026-09-17 — GTK4 local packaging assets omitted

- **Symptom**: a clean checkout failed before building GTK4 because
  `gtk-update-icon-cache.hook` was declared in `source=()` but was not found
  in the recipe directory.
- **Cause**: the four GTK4 hooks/scripts existed only as ignored working-tree
  files; the package-local wildcard `.gitignore` hid them from the public
  repository.
- **Fix**: publish all four local assets, remove the GTK4 wildcard ignore, and
  add `tests/gtk4-recipe-assets.sh` to require every asset to be present and
  tracked.
- **Rule**: every non-URL `source=()` asset is essential recipe input and must
  be tracked; package-local wildcard ignore files are not an acceptable way to
  hide generated build state.

## 2026-09-16 — GLib/Cairo/GTK/Xwayland PGO: Meson's cached args kept the instrumentation (condensed: 4 incidents)

Four same-day incidents, one root cause; folded here.

- **Symptoms**: (a) the final Meson reconfigure failed in compiler feature
  probes (`-Wmissing-profile` on untrained probe files under `-Werror`);
  (b) the verifier rejected builds over `build/meson-private/
  sanity_check_for_c.exe`, a temporary helper nothing installs; (c) after a
  full group build `nautilus` and Electron failed to load `libgtk-4.so.1` /
  `libgdk-3.so.0` (`undefined __gcov_indirect_call`); (d) deleted `.gcda`
  trees under the old build paths **came back** — recreated by the already
  installed instrumented libraries at process exit (`gdbus --version`
  refreshes them; `perf trace` shows the `RDWR|CREAT` opens).
- **Root cause (all four)**: the recipes changed `CFLAGS`/`CXXFLAGS` after
  `meson setup`, but Meson kept the cached phase-1 `-fprofile-generate`
  compiler AND linker args, so the "final" build stayed instrumented and
  shipped; the low-profile fallback also reconfigured without compiling a
  final non-instrumented build.
- **Fix**: glib2-git, cairo-git, gtk3-git, gtk4-git and xorg-xwayland-git now
  replace all four Meson caches (`c_args`, `cpp_args`, `c_link_args`,
  `cpp_link_args`) on the profile-use `meson setup --reconfigure`, add
  `-Wno-error=missing-profile` only on that transition, compile both PGO
  branches, and verify the **staged package payload** — never the build tree —
  for `__gcov_*`/`__llvm_profile` symbols and `.gcda` destinations. pkgrel
  bumps where the packages had shipped.
- **Validation**: shared fake-Meson fixtures cover all five recipes — the
  stale-cache failure reproduced, temporary helpers ignored, contaminated
  staged libraries rejected. The earlier `xdg-desktop-portal`
  `$HOME`/unknown-user warnings are a separate portal namespace issue, not
  the path creator.
- **Rule**: a Meson PGO transition is a cache migration, not an
  environment-variable update; validate instrumentation at the package
  boundary; and never trust a deleted profile tree to stay deleted while an
  instrumented binary is installed — the class recurred in cmake-git /
  xorg-xwayland-git (2026-09-19/20, see the 2026-09-20 cmake entry and
  MEMORY.md §4/§6).
## 2026-09-16 — Full PKGBUILD optimization audit

- **Scope**: all 122 tracked `PKGBUILD` recipes in the public Projects
  checkout; every recipe passed `bash -n` and `.SRCINFO` generation.
- **Findings**: WirePlumber appended unconditional `-march=native -O3` flags
  and installed dead NEWS/README documentation. GTK4 demos and libadwaita's
  optional `weston`/check path remain documented cleanup candidates, not
  automatic removals.
- **Fix**: removed WirePlumber's host-specific flag override and dead
  documentation install, then added the optimization and trimming contract to
  `CONTRIBUTING.md`.
- **Rule**: use host `makepkg.conf` defaults, trim dead packaging inputs only
  with their dependent paths, and preserve PGO workloads and maintained
  features explicitly called out by `MEMORY.md`.

## 2026-09-16 — OpenShadingLanguage LLVM 24 compatibility

- **Root cause**: LLVM 24 removed `TargetOptions::NoTrappingFPMath`,
  `FloatABIType`, and related legacy floating-point fields; OSL 1.15.3.0
  still referenced them, and its LLVM version ceiling rejected LLVM 24.
- **Fix**: repaired `osl-llvm-compat.patch` with valid LLVM version guards,
  removed the obsolete `UnifyFunctionExitNodes` include, updated the LLVM
  version ceiling to 24.9, and refreshed the patch checksum.
- **Validation**: the patch applies cleanly, the Ninja build completes, and
  `makepkg -sf --noconfirm` successfully creates the package.

## 2026-09-16 — legacy build-path guard

- **Cause**: old positional commands could still pass `.Heavyweight/...` or
  `.Static/...` directly to `build-all.fish`, so makepkg wrote into the
  pre-migration trees.
- **Fix**: positional paths now canonicalize to `.Core/...` or `.Stable/...`;
  `build_package` rejects any remaining legacy path. Removed the stale
  root-owned `.Heavyweight/{glib2-git,cmake-git,gtk4-git}` trees and added
  `.Heavyweight`/`.Heavy` → `.Core` plus `.Static` → `.Stable` compatibility
  aliases.
- **Validation**: legacy-path dry runs resolve to the migrated directories and
  `build-all.fish --audit` reports no legacy directory; the aliases resolve to
  the canonical trees.

## 2026-09-16 — multi-lane dispatcher made truly asynchronous

- **Symptom**: `--lanes 2` behaved like waves: the second lane started only
  after the first lane finished, and dependents waited for the whole wave
  instead of only their own dependencies.
- **Root cause**: Fish executes a backgrounded function call synchronously in
  this environment; `lane_job ... &` therefore blocked the dispatch loop.
- **Fix**: added a hidden `--lane-job` child mode and launch each lane through
  an external `fish` process. The parent now polls result files and refills an
  idle lane as soon as its dependencies finish (and install, when `-i` is set).
- **Validation**: mocked `cairo-git` (1s), `libdrm-git` (4s), and dependent
  `pango-git` (1s) ran with `--lanes 2`; `pango-git` started after `cairo-git`
  and before `libdrm-git` finished. Syntax, group dry runs, and `--audit` pass.

## 2026-09-16 — lane dashboard and process-output rendering

- **Symptom**: the interactive `--lanes 2` transcript could wrap lane events
  across terminal columns, interleave install/progress output with dispatcher
  lines, and print `Build interrupted` more than once after Ctrl-C. Piped
  output also contained ANSI color sequences.
- **Root cause**: the dispatcher emitted unbounded raw lines instead of owning
  a TTY-aware render surface; lane children inherited the parent's terminal
  and relied on inner build functions to stay quiet; and the signal handler
  was installed in the `--lane-job` children as well as the parent. Fish's
  `set_color` also emits ANSI when stdout is not a TTY.
- **Fix**: interactive runs now redraw a compact, width-capped dashboard;
  non-TTY and `TERM=dumb` runs use plain append-only output. Lane supervisors
  run under `setsid --wait` in isolated process groups, redirect their complete
  stdout/stderr stream to the package log, and are tracked for synchronous
  interruption cleanup. Child mode no longer installs the human-facing signal
  handler, and log tails strip carriage-return/escape controls before replay.
- **Validation**: a deterministic pseudo-TTY/pipe harness with long package
  names, child progress output, fake installs, a failing lane, and Ctrl-C
  passes the dashboard, no-ANSI, isolation, failure-drain, and exit-130 checks.
  `fish -n`, git/stable/core dry-run counts, legacy-path canonicalization, and
  `--audit` also pass.
- **Rule**: only the parent dispatcher may render live terminal state; all
  lane child output belongs in per-package logs, and every terminal update must
  be width-safe or use the plain non-TTY fallback.

## 2026-09-16 — LLVM source-heavy packages moved to core

- **Change**: moved `libclc-git` (the requested “linclc-git”) and
  `autofdo-git` from `git` to `core`; the routine counts are now 54 `git` and
  41 `core`. Both are serialized with other source-heavy/ABI-critical builds.
- **Source-sharing guard**: `-ln/--link-sources` now accepts only an actual Git
  mirror or working clone. It no longer mistakes an empty source directory
  inside a package repository for a valid mirror, and it can replace stale
  empty paths while preserving populated non-Git paths.
- **Current state**: the existing LLVM mirror path was empty; after confirming
  the live `-g git,stable` build did not touch these packages, the targeted
  fan-out was repaired. Both source-cache names now point at the missing
  `.Core/llvm-git/llvm-project` canonical path, which makepkg can populate on
  the first core LLVM build. Run the full unprivileged `build-all.fish -ln`
  after the active build finishes to recheck the other source groups.

## 2026-09-16 — lane dashboard log tails and activity hint

- **Symptom**: a long-running lane could appear healthy while blocked by a
  stale pacman database lock; the dashboard repeated its title and the event
  row did not visibly prove that the dispatcher was still polling.
- **Fix**: active lanes now show the last three sanitized lines from their
  per-package logs, refreshed on each 0.5-second dispatcher poll. The
  dashboard keeps only the one-time header, uses compact `✓`/`✗`/`⚠`/`·`
  markers, and prefixes the event row with a `-`/`\`/`|`/`/` spinner.
  Per-package logs are cleared at dispatch so preflight cannot expose a prior
  run's tail.
- **Boundary**: pipe and `TERM=dumb` output remains the existing plain
  append-only format; child build/install streams remain log-only.
- **Validation**: the temporary PTY/pipe fixture covers stale-lock visibility,
  exactly three tail rows, ANSI/control sanitization, title ownership,
  spinner cycling, narrow terminals, failure tails, and Ctrl-C exit 130.
  Fish syntax, group dry-runs, and workspace audit also pass.

## 2026-09-16 — builder frontend/backend hardening

- **Frontend review**: output paths had drifted between dashboard, sequential
  builds, installs, failures, maintenance commands, and argument errors
  (`✔`/`✓`, mixed headings, and duplicated ad-hoc color/icon formatting).
- **Backend review**: parallel installs could independently contend on
  pacman’s database lock; a lane supervisor that exited before writing a
  result could leave the dispatcher waiting forever; several filesystem,
  directory, ownership, dependency-expansion, and source-link failures were
  not surfaced explicitly.
- **Fix**: added shared UI helpers and status vocabulary, visible-cell
  dashboard truncation, atomic/validated lane results, supervisor liveness
  handling with fail-and-cleanup behavior, explicit blocked-selection failure,
  checked runtime/filesystem boundaries, and a builder-owned `flock` around
  pacman transactions. Stale `/var/lib/pacman/db.lck` files are never removed
  automatically.
- **Validation**: the temporary command matrix covers interactive/pipe output,
  narrow dashboards, fake pacman install serialization, dead and malformed
  lane results, failure reporting, source-link repair, Fish syntax, group
  dry-runs, and workspace audit. No live package build was used as a test.

## 2026-09-16 — selectable scheduler intensity profiles

- **Symptom**: automatic scheduling exposed only CPU/RAM-derived `lanes` and
  `jobs`, so users could not choose a documented effort level. The displayed
  `-j` value was per lane, making the old plan easy to misread as a global
  worker count.
- **Fix**: added `low`, `medium`, `high`, `xhigh`, and `max` profiles, with
  `xhigh` as the default. Automatic normal-lane memory is budgeted globally
  and divided across lanes; core packages retain a separate solo budget.
  `--intensity` and `GSA_INTENSITY` select the profile, while explicit
  `--lanes` and `--jobs` remain hard overrides.
- **Rule**: treat `max` as an intentional low-headroom mode. Keep the
  resolved intensity and plan in the startup output, and preserve both in
  failure resume commands.
- **Validation**: a temporary/future-maintainer fixture with fake `makepkg`
  runs all five profiles on a deterministic 24-thread/21-GiB host and checks
  the resolved lane/job plans without building a real package.

## 2026-09-15 — hsa-rocr build recovered from stale partial download

- **Symptom**: `makepkg -sif` repeatedly failed while retrieving
  `rocm-7.2.4.tar.gz`: curl attempted to resume at byte 831488, but the
  GitHub codeload endpoint rejected byte-range resume requests.
- **Root cause**: stale `rocm-7.2.4.tar.gz.part` remained after the previous
  interrupted download.
- **Fix**: removed only the resolved partial archive and reran
  `GIT_CONFIG_COUNT=0 makepkg -sif --noconfirm` under `.Static/hsa-rocr`.
  The fresh 41.3 MiB download, build, packaging, and pacman reinstall all
  completed successfully.
- **Verification**: installed `hsa-rocr 7.2.4-1.1`; `.PKGINFO` contains
  `provides = hsakmt-roct=7.2.4`. The existing `pkgrel=1.1` change was
  preserved.

## 2026-09-15 — imported PKGBUILD signing keys

- Extracted 46 unique active `validpgpkeys` fingerprints from all workspace
  `PKGBUILD` files, excluding commented-out examples.
- Imported the set in one `gpg --recv-keys` operation using
  `hkps://keyserver.ubuntu.com`; 43 fingerprints are now present in the user
  keyring.
- Three fingerprints were not retrievable from the public keyservers tried:
  `3D10AD045AB4AAFF8E8F36AF9B980AC2FB874FEB`,
  `ABAF11C65A2970B130ABE3C479BE3E4300411886`, and
  `C305FEBD4C4081119CB3C12CE640E67B2C7F96AA`.

## 2026-09-15 — linux-firmware VCN backport fixed for newer tag

- **Symptom**: `prepare()` failed at `git checkout 20260622 amdgpu/*vcn*`
  because the 20260910 source added `amdgpu/vcn_5_3_0.bin`, which does not
  exist in the 20260622 tag.
- **Root cause**: the old glob passed every current VCN path to checkout;
  Git rejects paths absent from the historical tree. Removing that firmware
  alone also left a stale `WHENCE` entry, causing `copy-firmware.sh` to fail.
- **Fix**: `prepare()` now enumerates current and historical VCN files,
  removes the current set, restores only files present in `20260622`, and
  removes manifest entries for VCN files absent from that tag.
- **Verification**: `makepkg -sif --noconfirm` completed; all seven split
  packages installed at `1:20260910-1`, initramfs regeneration succeeded,
  `makepkg --printsrcinfo` and `bash -n PKGBUILD` pass, and no packaged
  `vcn_5_3_0.bin` remains.

## 2026-09-15 — package-stack groups renamed and merged

- **Change**: renamed `.Static/` to `.Stable/` for packages whose versions
  synchronize with official repositories, and `.Heavyweight/` to `.Core/` for
  the heavyweight build area.
- **Groups**: replaced `static`, `heavy`, `critical`, and `rocm` with
  `stable` and `core`. `core` is the deduplicated union of the former
  heavyweight, ABI-critical, and ROCm memberships and automatically enables
  immediate per-package installation.
- **Script updates**: rewrote dependency paths, stable-version synchronization,
  scheduler solo-build checks, help text, group resolution, counts, and
  validation guidance in `build-all.fish`.
- **Documentation**: updated current-state descriptions in `MEMORY.md`;
  historical incident entries retain their original terminology.
- **Migration cleanup**: 5,320 preserved symlinks under the renamed trees
  referenced the old absolute or relative `.Heavyweight`/`.Static` paths;
  their targets were rewritten to `.Core`/`.Stable`. One unrelated broken
  staged dbus service symlink remains under `.Stable/dbus/pkg/` and was not
  changed.

## 2026-09-15 — legacy-leftover audit and builder audit mode

- **Change**: added `build-all.fish --audit`, a read-only report covering
  legacy directories, active control-file references, generated path
  references, package-group drift, dependency-path validity, and stale
  runtime/error artifacts.
- **Cleanup**: removed the stale `Project-structure.txt` snapshots, the
  abandoned `.build-logs/.lane1.result`, package-local `.srcinfo.err`
  remnants, and the unused `expand_dependents` helper. Historical migration
  references in this journal were retained.
- **Classification**: `.Stable/ccache`, `.Stable/dbus-broker`,
  `.Stable/systemd`, and the `.3rdP/` projects were classified as routine
  group candidates; `autofdo-git` and `bpftune-git` were added to `git`,
  while `ccache`, `dbus-broker`, and `systemd` were added to `stable`.
- **Auxiliary relocation**: moved `linux-cachyos` to `.Misc/`; `.Misc/`
  packages are excluded from audit membership and routine group discovery.
- **Outstanding**: `.Heavyweight/glib2-git/src/build` was recreated after
  the directory migration without a visible active builder. It was removed
  only after confirming no `makepkg`, `build-all.fish`, Meson, or Ninja
  process; if it reappears, trace the external creator before rebuilding.

## 2026-09-02 – 2026-09-04 (condensed) — Qt dev-stack skew, the workspace trim, source sharing, and the pacman rollback

Pre-2026-09-15 naming applies throughout (see the naming-history table
above). This and the next two sections condense 31 detailed entries from the
old era into symptom → fix lines; the durable rules live in `MEMORY.md` §1
and §6, and the commit/version identifiers of each fix are kept inline.

- **09-02 Qt private-API skew (root incident)**: `qt6-base-git` (6.13.0-dev
  internally) exports `QtPrivate_6_13_0`; stock 6.11.2 modules reference
  `QtPrivate_6_11_2`, which no longer exists → dlopen failures. Decision:
  maintain the full Qt dev stack house-built under the same stock names
  (stock-only by design: qt6-translations, qt6ct, qt5ct; qt6-webengine never
  attempted). Acceptance test after every Qt rebuild:
  `nm -D --undefined-only <lib> | grep QtPrivate_6_` must show only the base
  tag; ANY qt6-base-git update ⇒ rebuild every `.Heavyweight/qt6-*` in the
  same pass, and never `-Syu` a fresh base-git over stock modules (rules 5
  and 14). pyside6-git: scoped with `-DMODULES=`, pkgver greps
  `QT_REPO_MODULE_VERSION` from `.cmake.conf` (git describe on dev branches
  resolves to ancient tags and must not be used).
- **09-03 batch expansion + pacman episode**: 14+ packages wired (scx pair,
  fish, zram-generator, dbus/dbus-c++, pipewire, wireplumber, udisks2,
  linux-api-headers, linux-tools, linux-firmware trimmed to the Strix Halo +
  Cirrus set, fcitx5). PGO where the yield was real, LTO-only fallback
  otherwise (pacman, dbus, pipewire, fish — 0 gcda / 9 profraw, Rust PGO
  kept). **Self-built pacman was permanently removed**: it corrupted the
  local db; the user reverted to stock pacman. Root-owned `.gcda` appears
  when instrumented daemons are installed mid-iteration (→ `sudo rm -rf
  src`); avoid installing mid-iteration. `sync_static_version` gained an
  epoch split (`epoch=`) and a never-downgrade guard; dry-run every group
  after any revert/desync before building. `pipewire-jack` split dropped
  (conflicts with jack2; `pipewire-jack-client` kept) — and a cleanup glob
  `pipewire-jack-*` also matched `-client`, so re-run `makepkg -Rf` after
  glob-based cleanup.
- **09-04 PKGBUILD trim audit (full workspace)**: standard = trim
  docs/man/examples/tests/dead splits/dead makedeps; keep PGO training
  suites, all kmod compressors, the GTK4 Vulkan renderer, rust
  `profiler=true`, and cups/printing. Applied to hip-runtime (AMD-only; cuda
  and gcc15 became orphans), rocm-llvm (clang;lld, `AMDGPU;Native`),
  llvm-git (`X86;AMDGPU`), gcc-snapshot (c,c++,fortran,lto), rust-git,
  mesa-git, libclc-git, libdrm-git, polkit-git, gtk3/gtk4-git, cmake-git,
  doxygen-git (drops qt6-base + xapian runtime deps), mold-git, systemd,
  dbus-broker (both copies — the redundancy is still queued), seatd-git,
  ccache/vulkan-icd-loader/libva/libdex, util-linux, udisks2, pipewire
  (splits matched to the disabled meson features), wireplumber, scx-scheds,
  qt6-base/qt5-base (SQL drivers → sqlite-only), linux-tools (hyperv/
  intel-speed-select/x86_energy_perf_policy splits off). dbus-c++ deleted
  from workspace and system. New `-ccc/--nuclear` option finds all pulled
  sources and offers their deletion (dry-run prints sizes). linux-firmware's
  extra legacy `rm` line deferred (still queued). Qt consumer verdicts:
  qt6-webchannel/positioning/serialport/speech/multimedia and the whole Qt5
  stack stay.
- **09-04 Qt dev-stack rebuild (20 modules) + stale-meson purge**: all
  `.Static/qt*` built and installed (qt6-graphs added for easyeffects).
  `pkgver()` MUST grep `QT_REPO_MODULE_VERSION` from `.cmake.conf`; pacman 7
  makepkg needs a non-empty static `pkgver=`. qtlanguageserver pinned at
  `d845a85` (LSP 3.17 types) because qtdeclarative still used 3.17 names —
  with a documented unpin condition, met 2026-09-26 (see that entry).
  qt6-speech packages EMPTY without Multimedia — rebuild speech after it.
  gtk3-git's `provides=`/`conflicts=` must live in the package()-scoped
  arrays (global-only edits in split-style PKGBUILDs silently do nothing).
  Mirror strategy that worked: bare mirrors seeded at the pkg dir root with
  retry + GitHub fallback, then repo-local `url.<mirror>.insteadOf` so
  makepkg fetches locally (mirrors are then updated by hand). Qt PGO
  trainers run against build-tree libs via `LD_LIBRARY_PATH` +
  `QT_QPA_PLATFORM=offscreen` (Arch ships no Qt6 .pc files) and MUST
  self-quit — SIGINT/SIGTERM skip the atexit gcda flush → 0 profiles.
  Stale-meson purge after meson-git 1.12.0→1.12.99: 26 workspace build dirs
  configured by the old version fail on rebuild; audit with
  `find . -name meson-info.json`, build dirs live at arbitrary depths (rule
  6).
- **09-04 doxygen-git**: upstream `src/util.h` is missing `#include
  <fstream>` under GCC 17 — guarded sed in `prepare()`, idempotent and
  self-nooping once upstream fixes it (built 1.19.0.r99). Also: build-all.fish
  takes only its own single-letter flags — makepkg args like `-sif` must not
  be passed to it.
- **09-04 jamesdsp-git → easyeffects-git**: easyeffects-git added (dep edge +
  git group), jamesdsp-git removed. PGO 224 gcda via a trainer that spawns a
  private `pipewire` + `wireplumber` inside `dbus-run-session` with
  sandboxed XDG dirs (easyeffects aborts at startup without a live
  PipeWire), quitting via `easyeffects --quit` — NEVER pkill daemon names
  (user session), PID-scoped cleanup only. A GCC 17.0.0 experimental lto1
  ICE (`IPA pass: cp`, `-fprofile-use`) can be TRANSIENT — retry once before
  dropping PGO. OOM event: never run two heavy builds concurrently.
- **09-04 shared-source symlinks + `-ln/--link-sources`**: the "symlink
  feature not working" had never existed as such — the llvm mirror carried a
  local `url.<libclc-path>.insteadOf` redirect (origin LOOKED like GitHub)
  and a missing `remote.origin.fetch` refspec (stale at 1380 refs). New
  layout: canonical clone + symlinked twins (4 pairs: llvm-project,
  rocm-llvm/hipcc, zlib-ng, gtk), makepkg clones through the symlink via
  `git clone -s` alternates; ~14.5 G freed. Rules: a canonical's origin URL
  must equal the PKGBUILD source URL (else makepkg aborts "is not a clone
  of"); a mirror tag/URL move changes BOTH PKGBUILDs of a pair; `-ccc` never
  touches symlinks but a nuclear of the canonical dir dangles its twins.
  `-ln/--link-sources` automates the grouping, canonical selection, refspec
  repair and dedup (fake-scenario tested; real run: 4 groups, 4 links).
- **09-04 `.Static` self-sync bug**: `sync_static_version` queried only
  `pacman -Si $pkgbase`; hip-runtime builds `pkgname=(hip-runtime-amd)`, so
  the sync silently early-returned, the custom 7.2.4-1 fell behind stock
  7.2.4-1.1, and a `-Syu` legitimately replaced it. Fix: candidate list =
  pkgbase + every sourced pkgname (first repo hit wins). Known gap kept:
  `libisl-git` never syncs (the repo package is `libisl`); manual bumps
  there.
## 2026-09-05 – 2026-09-06 (condensed) — provides discipline, meson/mold/packaging traps, and the gimp chain

- **09-05 meson/meson-git conflict (unversioned provides trap)**:
  `dbus-broker-git`'s "Installing missing dependencies" pulled repo `meson`
  (satisfying `meson>=0.60.0`) into conflict with installed `meson-git` —
  an unversioned `provides=(meson)` cannot satisfy a versioned dep. Fix:
  versioned provides everywhere (`provides=("meson=${pkgver}")`, likewise
  ninja-git/cmake-git/doxygen-git; mold-git already did it). A provides fix
  needs a real rebuild (they live in `.PKGINFO`). Rule 4.
- **09-05 xz-git (po4a trim vs autogen.sh hard-fail)**: upstream
  `autogen.sh` unconditionally runs `po4a/update-po`, which fails when po4a
  is absent — `./autogen.sh --no-po4a` (built 5.8.3.r85, `liblzma.so=5-64`
  intact). Bonus: util-linux still carried a po4a makedep — dropped, or
  makepkg would have silently reinstalled the purged tool. Rule: when
  dropping a docs-only makedep, grep prepare()/autogen paths for its tools
  and check the remaining makedeps of every recipe.
- **09-05 libunwind-git (two stacked failures)**: (1) a stale non-git
  `src/libunwind` plus the parent AUR-mirror `.git` swallowed git calls in
  `$srcdir` — pkgver came out `.r0.ge76caf7` from the wrong repo and
  `autoreconf` failed; wipe `src/ pkg/` after any repo restructuring and
  beware a parent `.git`. (2) `breaks dependency 'libunwind.so=8-64'` —
  pacman 7.1 does NOT derive soname provides at `-U` time, `autodeps` is
  config-only and lint-rejected, so the provides array must declare them (5
  sonames). Debug path: `tar -xOf ./"$P" .PKGINFO | grep provides`.
- **09-05 util-linux 2.42.3 (three packaging traps)**: meson option TYPES
  matter — `python` is a string (interpreter name), the feature gate is
  `-Dbuild-python=disabled`; with `--auto-features enabled` (arch-meson) a
  missing tool behind `.require(tool.found())` HARD-FAILS configure
  (`-Dtranslate-docs=disabled`); split-package STAGING dirs live under
  `$srcdir` (clean `src/<staging-name>`, never the PKGBUILD root) and a
  removed `install -d` can be the only creator of a later `mv` target.
- **09-06 xdg-desktop-portal (upstream meson option rename)**: `Unknown
  option: "docs"` — upstream renamed `docs`→`documentation` and
  `man`→`man-pages` (new `meson.options` filename). Option names are
  upstream API; check `meson.options`/`meson_options.txt` when setup fails.
- **09-06 wireplumber (trim-leftover `_pick`)**: `package()` aborted on
  `mv: cannot stat 'usr/lib/girepository-1.0'` — the disabled introspection
  feature never installs that dir but the trim left its `_pick`. When
  disabling a meson feature, remove EVERY `_pick` path it installed (dirs AND
  globs). Source-verified mechanism (refines rule 3): makepkg
  `find_libprovides` auto-VERSIONS any bare `libfoo.so` provide from the
  packaged ELF soname — what it never does is synthesize one for an
  undeclared library (that was the libunwind failure). Full mechanism in
  MEMORY.md §6.
- **09-06 qt5-base-git (LTO-strip hook hollows static archives)**: makepkg
  tidy `safe_strip_lto` runs `strip -R .gnu.lto_*` over EVERY packaged
  `.a`; slim-LTO members (GCC ≥12 default) are pure IR, so the strip left
  symbol-less stubs and qt5ct failed linking `QDBusMenuBar::*` out of
  `libQt5ThemeSupport.a` — the hollow member's md5 (`c661bb56`) was
  identical across every build. Fix:
  force `-ffat-lto-objects` in `mkspecs/common/gcc-base.conf` (deleting
  `-fno-fat-lto-objects` is NOT enough — GCC 17 defaults slim), full clean
  rebuild (installed `5.15.2+kde_r45808.gfbed962c319-1`; the fixed
  ThemeSupport archive md5 `f002bb99` keeps 18 defined `QDBusMenuBar`
  symbols). `makepkg -Rf`
  can never fix tidy-mutated content (it reproduces it byte-for-byte).
  Verify: `ar p <a> <m> > f.o && gcc-nm f.o | grep -v gnu_lto | wc -l` —
  gcc-nm needs a REAL FILE (a stdin pipe silently returns nothing) and
  never `|| fallback` onto `grep -c`. Same class in qt6-base (harmless
  while its hollow archives are consumed only inside qt6's own .so builds).
- **09-06 pacman.conf IgnorePkg audit**: 62 of 159 self-maintained names
  unprotected, 54 of them installed — one `-Syu` away from clobbering the
  whole Qt module stack. Fixed with a cumulative `IgnorePkg =` line inside
  `[options]` (127→189). Two traps: a `sed "27r file"` append landed the
  names without the `IgnorePkg =` prefix, and a `tee -a` append landed at
  EOF inside `[extra]`, where pacman silently drops the directive — the
  closure re-diff caught both. Method: golden rule 9.
- **09-06 19-package integration**: 6 root `-git` recipes + 11 stock
  rebuilds (babl-git/gegl-git scaffolded from AUR to complete the gimp
  chain; split-output discovery — `networkmanager-vpn-plugin-openvpn` is a
  split of `networkmanager-openvpn`); mold + PGO applied per the playbook
  (bash/zsh train via `make check` with timeout + `|| true`; autotools
  CFLAGS bake at `./configure`, so every PGO phase re-runs configure);
  +14 `_DEPS` edges; IgnorePkg third line (189→214, same EOF trap, closure
  check caught it).
- **09-06 rust-git vs minimal llvm-git (target-set skew)**: installing the
  deliberately minimal llvm-git (`X86;AMDGPU`) broke any rust-git built
  against a full-target llvm — exactly 69 missing target-init symbols (14
  removed targets), and the single `LLVM_24.0` version node makes every
  miss report that node: diff `readelf -W --dyn-syms`, never trust the
  version string. Fix: rebuild rust-git (bootstrap is immune — bootstrap.toml
  sed-deletes the `rustc` AND `cargo` lines; keep the `rustfmt` deletion
  too). Rules: rule 13 (the 09-07 fix that replaced collective installs is
  below). Collateral: git-git's removed `mw-to-git` contrib excised;
  blender-git needs `makepkg-git-lfs-proto` built; `GIT_CONFIG_COUNT=0` is
  also what makes git-lfs fetches work in bare mirrors (the handler
  tolerates the failure and leaves an empty LFS store → "remote missing
  object" at extract). Transient `curl 56 SSL_read` on huge fetches: resume
  with `git -C src/<repo> submodule update <path>`.
- **09-06 (pm) mold false-negatives `has_link_argument` → zero verdefs**:
  after the util-linux build, `libuuid`/`libblkid` shipped ZERO
  `.gnu.version_d` nodes (libmount kept all 105) and libreoffice failed
  with `undefined reference to uuid_unparse_lower@UUID_1.0`. Cause: meson
  probes `-Wl,--version-script=…` by linking a trivial conftest with
  `--fatal-warnings`; mold hard-errors on version-script symbols absent
  from the conftest where GNU ld tolerates → check NO → the link arg is
  silently dropped. Fix: `LDFLAGS+=" -fuse-ld=mold
  -Wl,--undefined-version"` (util-linux 2.42.3 rebuilt: 7 × `UUID_1.0` + 43
  × `BLKID_`). Any `has_link_argument` probe whose flag touches
  symbol/version semantics is suspect under mold; re-verify `readelf -V`
  after mold bumps or linker flips. (The earlier meson-git r175 attribution
  was DISPROVEN.) Collateral same pass: git-git contrib `mw-to-git` excised
  (removed upstream); blender's LFS clone needed retries against
  projects.blender.org TLS flakes and the obsolete oneapi patch was
  dropped; rust-bindgen-git `0.73.1.r0.g66a1e2aa-1` built once rustc
  recovered.
- **09-06 (eve) OSL vs llvm-git 24 (version-node skew)**: every `oslc`
  shader compile died with `libLLVM.so.22.1: version 'LLVM_22.1' not found`
  — llvm-git 24 exports only `LLVM_24.0` and repo OSL was built against
  22.1. Fix: house `.Static/openshadinglanguage` 1.15.3.0-1.2 (same
  sonames/ABI as the tarball, zero blender-side risk) with
  `osl-llvm-compat.patch`: backport of upstream `2e43fc367` adapted,
  `VERSION_MAX` 22.9→24.9, `llvm::OptionalPassInfoMixin` (LLVM 24 moved
  `PassInfoMixin` — note the ADL break in `createModuleToFunctionPassAdaptor`)
  and `TargetOptions` removal guards. Verify: `readelf -V
  /usr/lib/liboslcomp.so.1.15` reports `LLVM_24.0`. Patch-authoring tip for
  non-git sources: extract the pristine tarball twice, `diff -ru`, fix the
  `a/`/`b/` prefixes, dry-run before wiring into source=. blender-git then
  rebuilt cleanly through the oslc stage.
- **09-06 (eve) blender-git 5.3 glog double-registration**: the first full
  run aborted at startup with `flag 'logtostderr' was defined more than once
  (… '/usr/src/debug/google-glog/…flags.cc' and 'extern/glog/src/logging.cc')`
  — bundled extern/glog plus system libglog (pulled transitively by
  `libceres.so`) both register flags at load. Fix: `-DWITH_SYSTEM_GLOG=ON
  -DWITH_SYSTEM_GFLAGS=ON` (installed `5.3.r164916.gf2261d10cdd5-1`;
  `blender --version` exits 0 again). Diagnostic path: the abort names both
  files — the `/usr/src/debug/<system-pkg>` one is the system lib's static
  init, the `extern/…` one the vendored copy; find the puller with
  `readelf -d`/ldd over the deps.
- **09-06 (eve II) gegl/babl provides, and krita's uic rejection**:
  arch-meson `--auto-features enabled` turns missing `mrg`/`maxflow` auto
  deps into fatal configure errors — probe a throwaway `arch-meson <src>
  /tmp/probe` to enumerate ALL missing deps in one pass, then disable
  explicitly. Unversioned sonames need the BARE `libfoo.so` provide (makepkg
  derives `libfoo.so=libfoo.so-64`; the literal is lint-rejected) — applied
  to gegl-git (3 sonames) and babl-git; `pacman -Dk gimp` and `ldd` then
  resolve from the house packages. Bare name provides cannot satisfy
  `name>=X`: cairo-git/glib2-git carry
  `provides+=("${pkgname%-git}=${pkgver%%.r*}")`. krita's Assistants plugin
  ships `class=" QWidget"` (upstream `3e8c536cf3`) and uic ≥ 6.13 rejects
  the whole file — sed in `prepare()` (drop when upstream fixes). Lesson: a
  "missing generated header" compile error means the generator failed
  earlier in the log — grep the generate step first.
## 2026-09-07 – 2026-09-09 (condensed) — install-before-dependents, the keystone group, and the LLVM snapshot recovery

- **09-07 gimp/krita chain completed**: cairo-git rebuilt (1.18.4.r141) with
  the versioned `cairo=1.18.4` provide → gimp-git `2:3.3.1.r1561` (the dev
  binary is `gimp-3.3`; there is no `/usr/bin/gimp`) → krita-git
  `6.1.0.prealpha.r66655` (`krita --version` → `6.1.0-prealpha (git
  d554c53)`). `pacman -U --noconfirm` does NOT auto-remove conflicting
  packages — the prompt defaults to N; pass `--ask 4` for stock→-git swaps.
  `tar -xOf` on filenames with an epoch colon needs a `./` prefix (tar reads
  `host:file`). Headless GUI smoke test:
  `env -u DISPLAY -u WAYLAND_DISPLAY QT_QPA_PLATFORM=offscreen timeout 90
  <app> --version`.
- **09-07 end-install (`-i`) semantics replaced — the root cause of the
  09-06 rust/llvm break, restated**: the old `-i` built everything, then
  installed collectively; topo order was correct but llvm-git was only
  RECORDED as built, and rust-git compiled hours later against the OLD
  installed llvm. Correct build order does not help if installation lags
  compilation. `-i` now installs each package immediately after its build,
  in topo order, via `install_pkgs_now` (`sudo pacman -U --noconfirm
  --ask 4`, rc checked — an install failure aborts the run); all
  collective-install machinery deleted; the `-s` skip path installs too. The
  `-si/--sepinstall` alias lived on until 2026-09-17. Rule: never
  reintroduce build-then-install-collectively for ABI-coupled chains;
  `install_pkgs_now` is the single install path (rule 11).
- **09-07 `-g critical` keystone group + `--no-deps` + mandatory
  selection**: the operationally meaningful split is "ABI-coupled
  keystones", not "slow builds" — `-g critical` = 6 hubs (llvm-git,
  rust-git, qt6-base-git, qt5-base-git, glib2-git, openssl) with the reverse
  dependency closure (61 pkgs) auto-enabling `-i`; `--no-deps` builds
  exactly the named packages; a bare invocation errors out (the interactive
  "include heavy?" prompt died with it). Dep-edge audit against
  `pacman -Qi Depends` (noctalia has NO qt6-declarative; NM-openvpn reaches
  ssl only via libnm) — audit edges with metadata, never assumptions. `-g`
  accepts repeats and commas, deduped before topo_sort. Today this is `-g
  core` (rule 12).
- **09-07 post-trim system audit**: `pacman -Dk`/`-Qkk` plus a 60724-pair
  soname audit (every ELF's DT_NEEDED vs ldconfig) → nothing the trim
  removed is needed; 55 unresolved sonames were all classified as optional
  dlopen plugins. Findings: llvm-ocaml-git stale split (removed), seatd-git
  missing its bare `libseat.so` provide (added; rule 4), fastfetch noise.
  Never `xargs -P` parallel readelf into one pipe — outputs interleave
  mid-line and corrupt the parse.
- **09-07 (pm) keystone trim verdicts, `.Heavy`→`.Heavyweight` restructure,
  mold global, parallel lanes**: all keystones kept their consumer-facing
  artifacts (GTK4 print backends compile INTO libgtk — a missing
  `print-backends/` dir is not a loss; don't "fix" it like gtk3's). The ROCm
  stack was uninstalled as one transaction (nothing NEEDs those sonames, but
  HIP compute/Blender-HIP is gone — restore-or-prune still queued). mold
  became the system linker (`-fuse-ld=mold` in `/etc/makepkg.conf`; bfd is
  single-threaded and `-flto=auto` gets no jobserver under ninja).
  `--lanes N` ready-set dispatcher: a lane refills only when its workspace
  deps are INSTALLED (rule 11), heavy-group packages run solo, failure stops
  dispatch and drains in-flight lanes (since 2026-09-24 a *deferral*, lane rc
  99, is not a failure: the package parks and its dependents keep waiting),
  output goes to per-package logs.
  Fish landmines collected: command substitution splits on newlines ONLY; a
  `#` comment after a `\` continuation swallows the rest of the logical
  command; `string join <delim> -- $argv` for flag-leading args; `$pre cmd`
  with empty `$pre` errors ("expanded command was empty").
- **09-07 fcitx5 chain**: a self-built fcitx5 core with stock addons is
  addon ABI skew — the whole -git chain is now self-built (xcb-imdkit-git,
  fcitx5-git 5.1.22.r0, fcitx5-lua-git, libime-git, fcitx5-qt-git,
  fcitx5-gtk-git, fcitx5-chinese-addons-git; the addon PKGBUILDs name the
  `-git` deps literally, so stock does not satisfy them). Trims: qt4 split
  removed, GTK2 IM module off, `#include <string>` sed (GCC 17 transitive
  includes).
- **09-07 (evening) LLVM snapshot bump broke rustc**: an llvm-libs rebuild
  (the BPF build) made rustc heap-corrupt/segfault on EVERY compile — LLVM
  snapshots have no stable C++ ABI and rustc's driver links libLLVM
  directly (victims: rust-git, mesa-git, spirv-llvm-translator-git,
  openshadinglanguage). Recovery: downgrade-rebuild llvm-libs at the
  rust-compatible snapshot `r595808.29fda2c4ecca` (pin `#commit=` in the
  PKGBUILD source, rebuild + install as a downgrade, unpin after — the BPF
  target is build config and survives), then rebuild linux-tools and
  scx-scheds-git. Incident-response hardening landed with it:
  `check_rustc_sanity` preflight (trivial `fn main(){}` compile;
  `--allow-broken-rustc` escape hatch), `sudo -n` installs with a 150 s
  keepalive (a `sudo -v` probe alone must never decide "installs are
  impossible"), failure reports that split install-failure from
  build-failure, and root-supervisor mode (`sudo fish build-all.fish` —
  makepkg and all workspace artifacts run as the invoking user, ownership
  restored after each package, `-ln` refuses under sudo). 09-08 follow-up:
  a rule-13 recurrence (llvm moved `r595886`→`r595945`) healed with a plain
  rust-git rebuild — the bootstrap uses the DOWNLOADED official stage0, so
  "rust-git cannot rebuild itself once broken" no longer holds; a
  nondeterministic `stack smashing detected` in stage1 cleared on retry
  (`coredumpctl info` names the crashing frame).
- **09-08 old-path audit after the `.Heavy` rename**: the rename poisoned
  three separate things, each surfacing at a different time — git
  `objects/info/alternates` and origin URLs inside `src/rust/.git`
  ("does not appear to be a git repository"), and share-the-mirror symlinks
  (`gtk3-git/gtk` dangled, then EACCES behind a stray root-owned
  `.Heavy/`). Audit pattern: `find -type l` (+ `-xtype l`), grep `.git`
  alternates/config, then a string sweep. Second finding: root-mode's
  `chown -R` restore ran ONLY on the success path, so every failed root run
  left root-owned files that poisoned retries (43 files) — masked as
  "Unhandled python OSError", which is always an environment problem: force
  the traceback with `MESON_FORCE_BACKTRACE=1` from INSIDE the failing
  context. chown now runs on both paths. Also: git-git's `all` target needs
  pod2man on PATH (`/usr/bin/core_perl` under Perl 5.42); openssl 3.6.4 was
  trimmed to `no-docs` + `install_sw install_ssldirs` (no pod2man
  dependency ever again).
- **09-07 (night) bash PGO training freeze**: `timeout 900 make check` hung
  at 0 % CPU, ^C-immune — the suite's interactive test touched the tty from
  a background process group → kernel SIGTTIN STOPs the whole tree (STAT
  `T`, wchan `do_signal_stop`; only SIGKILL works). Fix:
  `timeout --foreground 900 make check </dev/null >/dev/null 2>&1`.
- **09-09 vscodium-insiders-git**: ccache + package-level `!lto` for a
  prebuilt-Electron packaging workflow — only the native Node addons are
  compiled. Rule: optimize only the native compilation path; do not force
  LTO or invent a PGO phase for packaging work.
