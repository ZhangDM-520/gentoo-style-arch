# Build guide

## Prerequisites

An Arch-based x86_64 system with `makepkg`, `pacman` and `base-devel`, plus
`git`, `curl`, `sudo` and `flock` (util-linux) for the engine's privileged
path. The engine is the native Rust `gsa` binary from the `crates/` workspace
(`cargo build --release` → `target/release/gsa`); installed systems get it
from `packages/core/gsa-pm` as `/usr/bin/gsa`. The opt-in version-sync
provider path additionally needs `nvchecker` (Python 3.11+) and `updpkgsums`;
the toolchain-identity probe reads `gcc`. The upstream-aware `--skip` check
needs the client for each declared source protocol (`git`, `svn`, `hg`, or
`bzr`) and access to its remote when a selected recipe has VCS sources; a
non-VCS recipe keeps the mtime-only skip check. `fish` is needed only to run
the frozen fish oracle (`tests/assets/build-all.fish`) inside its fixture
sections — never to build. A working compiler, enough disk space, and the
package dependencies named by the selected recipes are also required.

`gsa --help` is the authoritative flag roster (contract §L: a flag absent from
it does not exist), and `docs/gsa-contract.md` is normative where the two
overlap. Contract §B.9 maps every retired `build-all.fish` spelling onto its
`gsa` one — check, never remember.

## Families and selection

The grammar is pacman-shaped (contract §B):

```
gsa <FAMILY>[cluster-letters] [long-modifiers] [targets…] [ranges…] [-- <pacman args…>]
```

Exactly one family per invocation; lowercase sub-option letters cluster onto
it. A bare `gsa` is a usage error, and a build never starts without a
selection.

| Family | What it does |
| --- | --- |
| `-Q` | query the buildable universe and the side-car database (read-only) |
| `-S` | build the selection and install each package before its consumers compile |
| `-B` | build-only: archives to the build cache, nothing installed |
| `-U` | install from archives in one `pacman -U` transaction; nothing is built |
| `-M` | maintain engine state: audit, doctor, IgnorePkg, logs, mirrors, prune, sets/world, history |

`gsa fetch` is a word alias for `gsa -Sw` (fetch-only). Cluster letters run
onto the family: `f` = force install (`gsa -Sf`, `gsa -Uf`); `c` = prune
strength 1 before the build (`gsa -Sc`, `gsa -Bc`; combinable: `gsa -Sfc
@git`). Trailing `-- <pacman args…>` are forwarded verbatim to every
`pacman -U` of an install run (for example `gsa -Ua -- --overwrite '*'`).
`--quiet` and `--verbose` parse but are deferred to a later phase and answer
with a usage error naming them.

Targets — exact lookup only; a typo is never auto-corrected, it fails with the
nearest candidates (contract §C.1):

- a recipe ID (`mesa-git`), a recipe path (`packages/git/mesa-git`), a
  case-variant ID (matched and announced), or a pacman `pkgname` including a
  split output (`zen-browser` → `zen-browser-pgo`);
- a group or user set as `@name` (`@git`, `@core`, `@<set>`) — groups and
  sets share one `@` namespace;
- a standalone PKGBUILD: a `PKGBUILD` file path, a directory holding one, or
  a URL of one — staged into its own one-node workspace and built there, no
  project clone required (never mixed with workspace references);
- an archive path, under `-U` only.

Ranges (`22..38`, `22..`, `..15`) are 1-based indices into the ordered
selection exactly as `gsa -Sl` prints it; a range needs a selection to anchor
it. A selection expands to the named packages plus their transitive
**consumers** — the packages that must rebuild after them, because rebuilding
a package cannot break what it consumes while its consumers carry the ABI
risk. Prerequisites are never pulled in: they are assumed installed and
current, so bootstrap and fresh builds use `@` group runs (`gsa -S @git`).
`--leaf` suppresses the expansion and keeps exactly the named recipes.

An `@app` build (or `--dry-run`) on a TTY prompts to multi-select before the
pipeline runs: all unchecked + Enter = the whole group, any checked = only
those, `q` aborts. Non-TTY runs and listings take the whole group silently.
Records tagged `app-cluster=<name>` present as one row that toggles as one;
the packages stay separate in listings, ranges, lanes and the run record.

## Inspect, dry-run, then build

```sh
gsa --help
gsa -Ma
gsa -Sl
gsa -S --dry-run @core
gsa -B @git --intensity xhigh
```

Inspect without building: `gsa -Sl` (ordered selection with range indices),
`gsa -Si <ref…>` (recipe info), `gsa -Ss <pattern…>` (search the buildable
universe), `gsa -Sg [name…]` (groups/sets and members), `gsa -Qt` (resolved
topology records — the tooling data channel), `gsa -Qi`/`gsa -Qs`/`gsa -Q`
(package info/search/list), `gsa -Qb`/`gsa -Qp` (binpkg index rows / archive
probe). Anything else the roster does not print is not a spelling.

The retired fish entry point still exists at the repo root as a **retirement
shim**: `build-all.fish` prints the old-spelling → `gsa` migration table
(contract §B.9) and exits non-zero without running anything. It is kept for
one release cycle after the 2026-10-14 cutover; the fish engine itself is
frozen as a fixture oracle under `tests/assets/`, not an engine any more.

## Installation semantics

`gsa -B` builds to archives in the build cache and installs nothing; a
successful build leaves them for later review or a later `-U`. `gsa -S` builds
the selection and installs each package's archives immediately after its
build, before any consumer compiles — install-before-consumers (contract
§B.4) — so nothing compiles against an older ABI. A `core` selection needs no
special flag: `-S @core` installs as it builds; `-B @core` is a deliberate
build-only choice whose archives are installed later with `-U`.

`gsa -U` installs named packages' newest index-complete archive sets (or
explicit archive paths) in ONE `pacman -U` transaction. `gsa -Ua` installs
every index-complete archive set in the workspace in one transaction (force
mode inherently); an empty eligible set is `noop empty-list`. Because one
transaction cannot honour install-before-consumers, `-Ua` is the escape hatch
for a set whose members do not consume each other (for example after
`gsa -Mcc`, with `--`-forwarded pacman arguments: `gsa -Ua -- --overwrite
'*'`) — never a substitute for `-S` on a build-ordered set.

Before its transaction, `-S`/`-U` compare each archive against the installed
database: a package whose exact version is already installed with an install
date not older than its archive skips its install (`skip already-current`).
Add the `f` cluster letter (`gsa -Sf`, `gsa -Uf`) when the install must run
anyway — for example after repackaging a same-version payload.

Install decisions are fail-closed and computed once: an empty archive list is
a refusal under `-S` (`refuse empty-list` — a run that installs nothing
would leave later packages compiling against the old system version) and a
no-op under `-Ua`; a PGO archive that still carries a baked
`.gcda`/`.profraw` destination is refused (`refuse pgo-*`) and a bare soname
provide that drifts against the installed database refuses likewise
(`refuse abi-soname` / `refuse abi-consumer`), before anything is
written into `/usr` — unless every linked surface consumer is covered: it
rides the same transaction (`-Ua`), or it is scheduled strictly
later in the same run (in-run repair — the run rebuilds it against the moved
surface; the provider's plan-row reason marks it `repair <consumer>
<provider-id>`, a forced-rebuild marker under
`<state root>/abi-repair/` keeps `--skip`/`--skip-built` from skipping that
rebuild, and the consumer's own install clears the marker — contract §E.3's
2026-10-14 amendment). To see exactly
what a run would decide without touching
pacman, sudo or the build, ask the hidden seam directly (contract §D.1):

```sh
gsa --install-decide checked <archive...>   # rc 0 plan / 1 refusal / 2 bad usage
```

The seam prints one row per candidate **finding**, in plan order, shaped
`<pkgbase> <decision> <reason…>` (the reason is the remainder of the line).
The decision vocabulary is `install`, `skip`, `refuse`, `noop`, `parked`
(contract §E.3; a refusing PGO/ABI candidate can carry several rows sharing
its subject). The rc contract is fixed: **0** a plan with no `refuse` row,
**1** a plan containing at least one `refuse` row (the full plan still
prints, pacman-free end to end), **2** bad usage. `parked` alone never yields
rc 1.

Root-supervisor mode is:

```sh
sudo gsa -S @core
```

The engine and pacman run as root; the makepkg family and every build-side
tool are dropped to the **build user** (`SUDO_UID`) via `setpriv`, with the
identity environment following the drop (contract §B.10) — `makepkg` never
runs as root and recipe code never executes as root. Engine state is written
by the privileged runner, so root-owned state is correct state (contract
§J.5; see **Runtime state and the build cache**).

## Build-time behaviour

### Skip and resume

Before any `--skip` decision, the engine compares the recipe's recorded
GCC identity with the current `gcc --version` build line. A missing or changed
identity removes that recipe's `src/`, `pkg/`, and `build/` trees, its package
archives, and their VCS revision records, then rebuilds even if `--skip` was
requested. The marker is written only after a successful build and VCS
revision recording, so a failed attempt is cleaned again on retry. Markers are
under the state root's `toolchains/` (contract §J.1; `--state-dir` beats
`GSA_STATE_DIR`); changing the state directory
intentionally causes a one-time clean for each selected recipe. This is
per-recipe state, not a scan or bulk cleanup of the workspace.
When `--skip` has a current-mtime VCS archive, the selected refs are resolved
before this automatic clean; an unreachable ref still refuses before the
archive and its baseline are removed.

After that check, `--skip` (long-only — the short `-s` is dropped; `s` is
pacman's search idiom) keeps the archive-mtime versus
`PKGBUILD`-mtime predicate. For non-VCS recipes, that remains the full
freshness check. For a VCS recipe, it is only the first gate: the engine
compares the actual source revisions recorded for that archive after a
successful build with the current remote revision of each VCS source's
declared ref (`git`, `svn`, `hg`, or `bzr`). Every declared ref must still
match before the archive can be skipped. A moved ref makes the archive stale
and the package follows the ordinary build path. Resolve the declared ref, not
an unrelated repository `HEAD` or the mutable shared source checkout.

"Already built" means more than an mtime match (2026-10-05): the archive must
be part of the *complete* output set its recipe declares (every split output
present at the evaluated `pkgver-pkgrel`), every member must pass a payload
readability probe (`pacman -Qp`), and a VCS archive must match the sha256+size
identity its revision baseline was recorded with. A missing sibling output, a
truncated write, a pkgver change, a replaced archive, or an old-format
baseline each forces a rebuild with a named diagnostic; anomaly diagnostics
print even in quiet output. A partial output set never reaches install
discovery at all.

Two flags reshape the skip decision (2026-10-06, `docs/NOTE.md`):

- `--skip-built` claims "built remains built" with the freshness analysis
  **off**: the newest complete, payload-valid output set at **any** version is
  skipped (run-record row reason `skip-built`) — no upstream VCS probes (the
  mode touches no network at all), no waivers. The claim dies only on a
  recipe CHANGE: a `PKGBUILD` commit newer than the set rebuilds (its file
  mtime when no git metadata exists — checkout/pull mtime churn never
  rebuilds). An incomplete split set or an unreadable archive still rebuilds
  with the same named diagnostics as `--skip`. With `-S` the skipped
  package still installs — the claimed set, however its version drifts from
  the committed `pkgver`. The two are different claims and cannot be combined
  (`gsa --help`).
- `--vcs-skip-tolerance N` is the CLI form of the waive threshold described
  above. It overrides `GSA_VCS_SKIP_TOLERANCE` and accepts positive integers
  only; `0`, negatives and non-numbers are a loud usage error (exit non-zero),
  unlike the env var, whose garbage values fall back to the default of 5 with
  a warning.

If an archive has no usable revision baseline, `--skip` never assumes that the
current upstream ref produced it. The engine first checks that each declared
ref can be parsed and resolved, then performs one normal build to record the
actual source revisions used for the replacement archive. A later `--skip` can
skip it normally. If a ref cannot be resolved, the engine stops before
`makepkg`; it does not skip the archive or begin an unverified migration.
Git ref queries classify transport failures by `ls-remote` exit status: 0/2
are completed answers (2 = clean "no such ref", never retried), anything
else is retried on the bounded schedule (`LS_REMOTE_BACKOFF` in
`crates/gsa-recipe/src/freshness.rs`): 6 attempts, 2/5/10/20/40 s backoff
(~93 s). If upstream still does not
answer, the recipe is *deferred* (lane rc 99, run-record reason
`upstream-unverified`): nothing is skipped, built, or installed, its
consumers wait, the rest of the run continues, and the run exits non-zero — an
unverifiable upstream parks one recipe, it never fails the run and never
licenses a skip (2026-10-02, `docs/NOTE.md`). A valid baseline whose ref
moved follows the normal build path. On a genuine
skip, `-S --skip` continues through the existing install path; a one-time
legacy rebuild follows the normal build/install path.

### Fetch-ahead (prefetch)

Build runs prefetch by default: an advisory lookahead window over the plan
order fetches sources for upcoming recipes while earlier ones build — one
fetch child at a time (`gsa --fetch-job`, contract §D.1), re-derived from live
run state so started, parked, deferred and skipped packages never consume a
slot. The verdicts are advisory by construction: they never write a run-record
row and never change the run rc; the per-run advisory log is
`<state root>/prefetch.log` (truncated at run start) and the warning count is
the `prefetch-warnings:` extension scalar of the run record (contract §H.2).

Tune or disable it with the two `gsa --help` modifiers:

- `--no-prefetch` — opt out entirely.
- `--prefetch-ahead N` — window size (default 8, positive integers only).

The two conflict and combining them is a usage error. How to check what a run
carried: the flags are mirrored in the run record's continuation per the
2026-10-14 amendment to §H.2 — `--no-prefetch` and a **non-default**
`--prefetch-ahead N` show up in `command:` (a default window mirrors
nothing), so

```sh
gsa -S --dry-run @git | sed -n '/run record begin/,/run record end/p' | grep '^command:'
```

settles which form a continuation replays.

### Stable version sync and checksum verification

Untagged `packages/stable` recipes track the Arch repository version and are
updated automatically before they build: the engine reads the repo's version
with `pacman -Si` and rewrites `pkgver`/`pkgrel` in the recipe **in place** when
the repo is newer. A downgrade is never written: a higher content `pkgver` is
kept, and at equal `pkgver` a local `pkgrel` **ahead** of the repo is a
deliberate bump (a PGO wave marks its own revision — ripgrep's `pkgrel=2` over
the repo's 1) and is kept too; only a repo `pkgrel` actually ahead is adopted,
and a `pkgver` move resets `pkgrel` to the repo's. A `pkgver()`-driven recipe
is skipped entirely. The edit is left in the working tree for you to commit,
uncommitted. When a source URL moves, the engine refreshes its checksum and
`.SRCINFO` from the official anchor; when no source moves, the committed sums
remain valid, though the `.SRCINFO` may need regeneration after a version-field
change. Review the diff before committing.

#### Explicit nvchecker providers

Build-time nvchecker is opt-in through the validated topology tag
`version-sync=nvchecker`; an existing `.nvchecker.toml` alone does not change
the version source. Run `gsa -Qt` to inspect which
records currently opt in. The engine reads the provider from the selected
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

What makes the sums stale is not the version bump but a **moved source**: most
untagged `packages/stable` recipes pin a literal version inside their
`source=()` URLs, so a rewrite leaves them fetching exactly what they fetched
before and their committed sums still verify. Only recipes that spell the
version into a URL (for example `linux-api-headers` and `linux-firmware`) move
their fetch — `grep -n pkgver packages/stable/*/PKGBUILD` shows which. The
engine therefore diffs the expanded `source=()` array around the rewrite and
only acts when an entry actually changed; otherwise the build runs against the
committed sums.

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
   directory — because a pinned tag is reproducible here (spot-checked against
   Arch's own published values, which matched byte for byte).
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
  payload at build time, a VCS source pinned by #tag/#commit is anchored to
  that ref, a #branch= pin tracks a branch tip — attested by the fetch (TLS)
  only, allowed only as a named maintenance branch (MEMORY rule 30) — and a
  plain download is attested by nothing but the fetch (TLS). Review these
  sums before committing; '--no-sync' builds the committed version as-is.
```

The `#branch=` rule is a tracked deviation in the current tree: 56 pins point
at trunk branches (`master`/`main`/`dev`/`develop`; counted 2026-10-28 —
recount with `grep -rn '#branch=' packages --include=PKGBUILD`), tracked but
never blessed by this note.

**One unanchorable recipe no longer strangles the dispatch** (2026-09-24):
the impossible-to-anchor paths *defer* the recipe instead of failing it. The
deferral rides the ordinary lane rc field as 99 (`defer`, contract §F.1); the
run parks the recipe (`deferred` — never counted failed, dispatch keeps
going), its consumers wait (`parked waits-on-deferred`), the summary names the
error plus both recovery lines, and the run exits non-zero (5 when a deferral
is the only blemish) with every parked package in the continuation. Before
this, one recipe whose official `.SRCINFO` published no checksum for a moved
source cost the rest of the run its dispatch — twice in a row. Signature files are outside checksum anchoring altogether
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
the engine.** In the default Arch path, a missing official document carries
the manual `updpkgsums` recovery line. An opted-in provider outage or AUR
metadata race instead defers for a retry; never clear it by treating a
fetch-generated hash as provider verification. A published-checksum mismatch
stops the run and restores the original recipe.
Signature verification is a separate check throughout — it is enforced
wherever the recipe has a `validpgpkeys` source, and several `packages/stable`
recipes anchor authenticity that way rather than by checksum (`grep -l
validpgpkeys packages/stable/*/PKGBUILD`).

## Privilege model

gsa is pacman-shaped (contract §B.10): **reads run as any user; mutations
require root.** Every `-Q*`, listing, `--dry-run` plan, report form of a `-M`
verb and hidden read seam runs unprivileged. `-S`, `-B`, `-U`, `-Sw`, `-Sy`,
`-Su` and the write-side `-M` verbs need root and answer an early refusal
(rc 3) with a `sudo` remedy otherwise. `gsa -Mm` (mirrors) is the inverse: it
runs as the build user only and is refused under a root supervisor.

Under `sudo gsa …` the engine and pacman run as root while the makepkg family
and every build-side tool are dropped to the build user (`SUDO_UID`) via
`setpriv`, with the identity environment following the drop. A bare root
shell (no `SUDO_*`) is refused for build-touching verbs with guidance — the
engine never improvises a build user. One banner line on stderr names the
split.

Nothing ever prompts: **every** privilege escalation is `sudo -n` and a TTY
changes nothing (contract §K.3). The engine keeps "I cannot refresh a
credential" distinct from "installs are impossible":

- Before dispatch the install preflight probes what sudo can actually do, and
  **refuses to start** before any build (rc 3, `preflight-refused`) when
  installs could not succeed non-interactively.
- While running, installs go through one serialized `pacman -U` at a time,
  each via the engine's PACMAN shim (`sudo -n flock -x` on the state-root
  mutex), so makepkg's own dependency installs share the same lock (contract
  §K.3).
- If the credential is genuinely lost mid-run, dispatch stops once (`sudo
  credential expired and cannot be refreshed` — one message, not one per
  poll), in-flight lanes drain, and the run lists the unstarted packages as
  remaining and exits non-zero. A stopped dispatch is never reported as a
  successful build. Rerun under `sudo gsa …` or prime `sudo -v` first.

`gsa -Ua` behaves the same way — it never prompts either. `sudo gsa …` is the
option-free way to avoid credential expiry altogether.

## Maintain and cleanup

The `-M` family is engine-state self-healing only — it never touches `/usr` or
`/var/lib/pacman` (contract §B.7):

| Verb | Action |
| --- | --- |
| `gsa -Ma` | audit report: legacy paths, package drift, stale runtime artifacts, recipe-contract lints, installed PGO payload report. Report-only: exit 0, read the report |
| `gsa -Md [--fix]` | doctor: runtime-state reconciliation (logs, stale lane/run artifacts, binpkg index `sha256+size` consistency, side-car rows with no pacman counterpart); `--fix` applies the named repairs |
| `gsa -Mi [--prune\|--backfill]` | IgnorePkg closure of the target `pacman.conf` (`--config PATH`, default `/etc/pacman.conf`): default reports drift, `--prune` removes stale entries, `--backfill` adds missing ones |
| `gsa -Ml [--tail <ref>] [--keep N]` | per-package log browse/tail; `--keep N` is the log-retention prune |
| `gsa -Mm` | mirrors: dedupe VCS source clones into canonical mirrors (`docs/source-sharing.md`). Build-user-only — never under a root supervisor |
| `gsa -Mc <targets…>` | prune strength 1: `src/`/`pkg/`/`build/` trees and archives of the selection (the `c` cluster letter on `-S`/`-B` does the same first, before the skip check) |
| `gsa -Mcc` | prune strength 2: every built archive in the workspace plus its VCS-revision sidecar; symlinks are never deleted or followed |
| `gsa -Mccc` | prune strength 3: additionally pulled sources — source clones, downloaded tarballs, staging dirs |
| `gsa -Ms [name…] [--add\|--remove <ref…>]` | named sets (`config/sets/`; computed sets are read-only) |
| `gsa -Mw [--add\|--remove <ref…>]` | the world set (what you explicitly want built) |
| `gsa -Mh [--prune] [--show <run-id>]` | run history: recorded run records and their continuations; `--show` renders one, `--prune` enforces the bounded retention |

The prune strengths are deliberately pacman's `-Sc`/`-Scc` cache-prune shape.
`gsa -Mccc` removes downloaded sources, VCS clones, and makepkg staging
directories while keeping recipe-local patches and intentional symlinks. A
downloaded remote archive is deleted only if its URL source's filename has one
of the download extensions the root `.gitignore` denies, so a `-Mccc` sweep and
the ignore rules cannot disagree about what a download is
(`tests/cleanup-extensions.sh` fails if they do); because the match is on
URL-backed sources, a *local* asset in a recipe directory is never a target
even when it carries one of those extensions.

The engine never prompts (contract §K.3): the mutating confirmations
(`gsa -Mm`, `gsa -Mccc`) print their target lists and stop rc 3
(`confirmation-required`) without `--noconfirm`; `--noconfirm` proceeds and
`--dry-run` renders the targets without mutating anything. Ctrl-C terminates
isolated lane process groups (one `SIGTERM` each, shared grace window,
`SIGKILL` for survivors), writes the full run record, and exits 130 (contract
§K.3).

## Runtime state and the build cache

Engine state lives under **one** state root: `/var/lib/gsa` by default —
binpkg index, ABI records, world/sets, run history, logs, locks, per-recipe
toolchain identities, `abi-repair/` markers, and the `recipes.last-fetch`
store-refresh stamp (contract §J.1). The canonical recipe store is **not**
here (see below). Relocate the entire root with `--state-dir PATH`, `GSA_STATE_DIR`, or
the gsa.conf `state_dir` key (contract §J.3: flag beats env beats config beats
the built-in default). When the resolved root is unwritable and no override is
given, the run fails early naming `--state-dir` as the remedy; there is never
a silent fallback to a home or workspace-local directory:

```sh
gsa -S @git --state-dir "$HOME/.local/state/gentoo-style-arch"
```

Every state write passes a write-time ownership gate (contract §J.5): the
privileged runner owns what it writes, so **root-owned state is correct
state**. A file owned by someone else is preserved under a
`<path>.stale.<epoch>.<pid>` name — announced, never silently adopted — before
the write opens it; a possibly-held pacman-lock inode is never renamed.

The canonical recipe store is build-user working data and lives **outside**
the state root: `GSA_RECIPES_DIR` > the gsa.conf `recipe_dir` key > the build
user's `~/.local/share/gsa/recipes` (contract §B.11/§J.2); `--state-dir` and
`GSA_STATE_DIR` never move it. `gsa -Sy` (or a mutating run's on-demand
fetch) populates it from `recipe_url`, refreshes it in place with a fetch +
hard reset (hand edits to the store are not preserved — point `project` at a
dev checkout for that), and hands it to the build user — as it does after the
one-shot migration of a legacy `<state>/recipes` (`.git` and any dirty
worktree survive the move; when both trees exist the resolved store wins and
the legacy tree is left in place, never deleted; a move failure is a hard
error). A root-owned store is never correct state: the makepkg family writes
there as the build user.

makepkg's working state is the **build user's cache**, never the recipe tree
(the W4a layout, contract §J.2). The engine passes `BUILDDIR`, `PKGDIR` and
`PKGDEST` on every makepkg spawn:

| makepkg variable | Lands at | Content |
| --- | --- | --- |
| `BUILDDIR` | `<build_dir>/build` | build trees (the live source tree is `<build_dir>/<pkgbase>/src`) |
| `PKGDIR` | `<build_dir>/pkg` | staging |
| `PKGDEST` | `<build_dir>/pkgs` | finished `.pkg.tar.zst` archives |

`build_dir` defaults to the build user's `~/.cache/gsa` and is set by the
gsa.conf `build_dir` key or `GSA_BUILD_DIR` (env wins); the engine creates the
three directories and hands them to the build user. Finished archives do
**not** land in the recipe directory: archive discovery scans the shared
`PKGDEST` first and the recipe directory only as a pre-W4a legacy fallback for
old trees, and every candidate is matched by `.PKGINFO`/output-name truth, so
a shared `PKGDEST` can never hand over another recipe's archive. A run whose
build-cache layout is unusable refuses rather than silently falling back to
recipe-dir trees.

Sources are a separate story: `SRCDEST` stays governed by `makepkg.conf` —
the environment `SRCDEST`, then the build user's `~/.makepkg.conf`, then
`/etc/makepkg.conf` — and the engine resolves through that chain rather than
re-inventing it.

## Environment surface

The engine's environment contract in four lists: the configuration files it
reads, the `GSA_*` inputs it reads, the inherited environment that silently
changes its behaviour, and what it exports. `gsa --help` is the authoritative
input roster — check it (or grep `crates/` for a variable name) rather than
counting names. Planning defaults and the intensity formulas live in
`docs/portability.md`.

**Configuration files** (contract §B.11): the engine auto-reads
`/etc/gsa.conf` (system) then `~/.config/gsa/gsa.conf` (user) — user wins —
and `GSA_CONF` replaces both with exactly one file (fixture and hermetic
control). The keys are `project`, `recipe_url`, `build_dir`, `state_dir`,
`recipe_dir`; `~`
expands to the build user's home (`SUDO_UID`'s home under `sudo`). An unknown
key or malformed line is an error naming file:line and key — never a silent
default.

**Inputs the engine reads** (the `--help` roster; a run-time flag overrides
the three planning defaults):

- `GSA_LANES` — default lane count. Default: `lanes` in
  `config/build-defaults.conf` (`auto`).
- `GSA_JOBS` — default per-lane job count. Default: `jobs` in
  `config/build-defaults.conf` (`auto`).
- `GSA_INTENSITY` — default intensity level (`low`, `medium`, `high`, `xhigh`,
  `max`). Default: `intensity` in `config/build-defaults.conf`.
- `GSA_CPU_THREADS` — overrides the detected CPU thread count the parallelism
  plan is computed from; must be a positive integer (anything else is a usage
  error). Default: CPU detection.
- `GSA_MEMORY_GIB` — overrides the detected available memory in GiB the
  parallelism plan is computed from; must be a positive integer (anything else
  is a usage error). Default: memory detection.
- `GSA_CONF` — replaces the auto-read `gsa.conf` layers with exactly one file
  (see above).
- `GSA_STATE_DIR` — the state-root override of contract §J.3; `--state-dir
  PATH` beats it, the gsa.conf `state_dir` key sits below it, and the default
  is `/var/lib/gsa`.
- `GSA_BUILD_DIR` — the build-cache root (**Runtime state and the build
  cache**): makepkg `BUILDDIR`/`PKGDIR`/`PKGDEST` land below it (`build/`,
  `pkg/`, `pkgs/`). Beats the config `build_dir` key; default: the build
  user's `~/.cache/gsa`. `SRCDEST` is NOT part of this surface — `makepkg.conf`
  governs sources.
- `GSA_RECIPES_DIR` — the canonical recipe store root (**Runtime state and the
  build cache**): build-user working data, never below the state root. Beats
  the gsa.conf `recipe_dir` key; default: the build user's
  `~/.local/share/gsa/recipes`. `--state-dir`/`GSA_STATE_DIR` never influence
  the store.
- `GSA_TARGET_CPU` — the engine does **not** consume it: it reaches recipes
  through the inherited environment (CPU tuning; the host `makepkg.conf`
  applies when unset), and a continuation warns about it via `env-required:`
  rather than mirroring it (contract §H.2).
- `GSA_VCS_SKIP_TOLERANCE` — how many upstream commits a recorded baseline may
  trail a moving Git ref before `--skip` refuses to waive the rebuild. The
  `--vcs-skip-tolerance` flag overrides this value and rejects
  non-positive-integer input outright; the env var remains the transport that
  carries the effective value into build lanes.

**Inherited environment that changes behaviour** without being validated
configuration:

- `SRCDEST` — makepkg's source-mirror root; the version-sync path consults it
  when locating declared sources.
- `TMPDIR` — scratch root for version-sync and toolchain-probe work; version
  sync refuses a `TMPDIR` inside the repository.
- `MAKEFLAGS` / `NINJAFLAGS` — forwarded into build lanes; the engine strips
  any `-jN` and appends the lane's own job count, preserving the caller's other
  flags (contract §K.1).
- `PACMAN` — the engine exports its **own** `PACMAN` shim to each lane
  (`flock` + `sudo -n`) so makepkg's `-s` dep installs share the engine's
  pacman mutex (contract §K.3); a caller-set `PACMAN` is replaced by that
  shim, not honoured.
- `GIT_CONFIG_COUNT` — injected agent-shell git config breaks bare-repo and
  makepkg VCS operations; the engine runs its own git calls under
  `GIT_CONFIG_COUNT=0` (and `GIT_TERMINAL_PROMPT=0`), and so must any hand-run
  `makepkg --printsrcinfo`.

**Outputs the engine exports** (never inputs):

- `GSA_BUILD_JOBS` — the lane's job count, exported per lane so a recipe reads
  it instead of calling `nproc` or hard-coding `-j`.

Names outside that roster are not engine vocabulary: `_GSA_*` and `GSA_FAKE_*`
knobs are fixture seams only (contract §D.2 and the 2026-10-14 §K.3
amendment), and a scenario is expressed with a stub rather than a new engine
knob.

## Engine output: the run record

One run record per run — plan plus one outcome row per package plus the
continuation — is computed once, as one typed structure, and rendered three
ways: the interactive dashboard (live), the prose summary, and the machine
block below. The machine block is default-on, printed to stdout after the
dashboard has finished (so its ANSI renderer cannot garble it), and on the
interrupt and preflight-refusal paths too. Since the 2026-10-14 cutover the
same structure is also persisted into the state root's run history
(`gsa -Mh`) — storage of one record, not a fourth derivation (contract
§H.1).

To read a run's block, cut it out of the stream — never scrape the prose:

```sh
gsa -S --dry-run @git | sed -n '/run record begin/,/run record end/p'
```

The grammar is contract §H.2: scalars first (fixed order), then three row
sections —

```
--- run record begin ---
format: 2
selection-source: sets=<targets,…> leaf=<yes|no> range=<ranges,…>
order: <the selection, topological>
lanes: …
normal-jobs: …
core-jobs: …
intensity: …
outcome: planned|success|refused|failed|deferral|interrupted
rc: <run exit code>
--- plan ---
<pkg> <plan> <reason…>
--- outcome ---
<pkg> <status> <rc> <dur> <reason…>
--- continuation ---
command: …
remaining: …
not-mirrored: …
env-required: …
--- run record end ---
```

The budget scalars `lanes`, `normal-jobs` and `core-jobs` are always
non-negative integers — they render `0`, never `-`, for any record whose run
dispatched nothing (dry-run plans, `-U` transactions, preflight refusals);
the 2026-10-14 amendment to §H.2 fixes that, and `-` remains valid only for a
row's `rc`/`dur`. Rows are full, never exceptions-only: **one plan row and
one outcome row per selected package**, in topological order, `order` free of
duplicates — even when the decision seam emitted several findings for one
subject, the record collapses per subject (§H.2, 2026-10-14). A row's reason
is the remainder of the line.

Plan values (`build`, `build-install`, `install`, `fetch`, `skip`, `parked`,
`refused`, `noop`) are listed in §H.2; outcome statuses
(`succeeded|failed|deferred|parked|never-started|interrupted`) and every
reason key are §H.3, including the 2026-10-14 additive-keys amendment. A
reason never claims more than its row means — a waiver row keeps
`freshness-waived`/`abi-provider-waived`/`skip-built`, not `ok` — and
`parked` is not a failure: consumers of a deferred or failed package wait
while dispatch continues, and the run still exits non-zero (exit codes §G).

The continuation section has four keys: `command:` (the restated
invocation), `remaining:` (space-separated package IDs — every row not
`succeeded`, in row order; a failed package must rebuild before its
consumers), `not-mirrored:` (the flags deliberately not replayed), and
`env-required:` (ambient variables the resume must set). Which flags are
mirrored is the engine's single flag-rule table — the 2026-10-14 amendment to
§H.2 names the full set (`--leaf` mirrors only in its true form; prune
strengths, one-shot actions and hidden seams never replay) — read the table
there rather than a copy here. Environment inputs are warned about through
`env-required:`, never baked into the command; the resolved
`--lanes`/`--jobs`/`--intensity` values are mirrored as explicit flags.

Fixtures assert on the record, never on prose, through the strict `format: 2`
parser `tests/lib/rr-v2.bash rr2_body` (contract §H.2's 2026-10-14
strictness amendment): it rejects blank lines, control characters, duplicate
scalars/rows/continuation keys, plan or outcome rows that disagree with
`order`, `rc` values that match neither the status's lane code nor `-`, and
unknown continuation keys. When checking a change by hand, compare blocks (or
`gsa -Mh --show <run-id>` renderings), not summary text.

## Troubleshooting

Read the per-package log named in a failure message (`gsa -Ml --tail <ref>`
browses them). A stale system pacman lock is not removed automatically. Resume
with the remaining package IDs printed by the failure summary (or the run
record's `command:`/`remaining:`), usually adding `--skip` to a `-S` resume
after checking whether the archive was already produced (or `--skip-built` to
trust the built set outright — see **Skip and resume**).

Per-package logs live under the state root's `logs/` (contract §J.1) —
Git-ignored, and removed with the state directory. If a run may need
post-mortem forensics (a long build, a machine that stalls), put them
somewhere durable first:

```sh
gsa -S @core --state-dir "$HOME/.local/state/gentoo-style-arch"
```

### `anchoring-refused` / `updpkgsums` cannot write the recipe store

A store `PKGBUILD` the build user cannot write makes checksum refresh refuse
(`updpkgsums could not refresh the checksums … No write permission in …` →
`anchoring-refused` deferrals). The store is build-user working data
(contract §J.2): run `sudo gsa -Sy` once — it refreshes the store and hands
it to the build user, and migrates a legacy `<state>/recipes` on sight (one
loud note; move failure is a hard error, move the tree manually then retry).
A root-owned store is never correct state.

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
and makes a hard power cut the only option — each of which lands on the drive's
unsafe-shutdown counter. `sysctl -w kernel.sysrq=1` at
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
at full real scale the split loop moved io PSI 0.00
with ≤2 processes in D state and ≤16 % device utilisation, so the loop was
never the cause.

### mkinitcpio and optional NvPCR definitions

The package set disables systemd's bootloader integration because this project
boots through Limine. That means systemd does not install optional
`/usr/lib/nvpcr/*.nvpcr` definitions, while stock `mkinitcpio` systemd
hooks still try to add that glob literally. The project carries a patched
`mkinitcpio` recipe that skips absent optional definitions:

```sh
gsa -S --leaf mkinitcpio
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
gsa -S --leaf glib2-git
gsa -S --leaf cairo-git
readelf -sW /usr/lib/libglib-2.0.so.0 | grep -E '__gcov_|__llvm_profile'
strings -a /usr/lib/libglib-2.0.so.0 | grep -cE '/[^[:space:]]*\.gcda'
```

Both checks must produce no output and a count of `0`. **`readelf` alone is a
false negative**: makepkg strips before writing the archive, so the profile
runtime's symbol entries are gone while the absolute `.gcda` destinations
baked in at compile time survive in `.rodata`. Measured on the 2026-09-19
recurrence, `readelf -sW` on an affected binary reported clean while
`strings -a` found every baked profile path.

Restart applications that were running against the old libraries, then remove
only the now-inactive residual build trees. Do not treat GLib warnings from a
portal or sandboxed application as evidence of a engine process; correlate
them with the installed library symbols and profile-file paths first.

The same verification applies to `gtk3-git`, `gtk4-git`, and
`xorg-xwayland-git`. If a GUI application reports an undefined `__gcov_*`
symbol, replace the affected custom package with the fixed rebuild before
rebuilding consumers; repository packages are a temporary recovery path, not
the underlying fix.

#### The two verification seams

A payload check runs at one of two places, and the two cannot use the same
predicate:

| Seam | Where | Predicate |
| --- | --- | --- |
| Recipe | `package()`, against the staged `$pkgdir` tree, before makepkg strips | `readelf` **and** `strings` (shared gate `lib/pgo.sh`) |
| Engine | the install pipeline's PGO payload gate (`gsa-install`; `pgo-*` refusal rows, contract §E.3), against the finished `.pkg.tar.zst` | whole-archive profile-destination string scan (`gsa-recipe::pkginfo::pgo_hits`) |

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
makepkg packaged the instrumented payload anyway (several recipes were in
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
place `readelf -sW` is meaningful. The engine seam is the durable one: it
covers every recipe rather than the handful that remember to call a guard, and
it runs immediately before files are added to `/usr`, so the check is worth
its cost. The engine seam is `gsa-install`'s PGO payload gate — the fail-closed
`refuse pgo-*` decision rows of contract §E.3 — and it engages only for a
PGO-instrumented recipe (`gates::pgo_instrumented_recipe` gates on the
sibling `PKGBUILD` containing `-fprofile-generate`), so non-PGO recipes are
untouched.

The engine seam extracts and scans the **whole archive**, not a
`usr/bin`+`usr/lib` subtree: `gsa-recipe::pkginfo::pgo_hits` walks every
member. Subtree scoping embeds an assumption about where
a recipe installs files, and it is wrong for a leak under `usr/libexec` (the
fixture's `deep-bad` payload demonstrates the miss). Whole-archive scanning is
precise as well as complete: archive metadata (`.PKGINFO`, `.BUILDINFO`,
`.MTREE`), prose documentation quoting a `.gcda` path, and source comments
quoting one all pass, because the predicate matches a standalone
`file: /path/to/x.gcda` string rather than any mention of `.gcda`.
`.BUILDINFO` is not a trap in either direction — it records
`-fprofile-generate` in `buildenv` but contains no `.gcda` string at all.

The scan **fails closed**. An archive that cannot be read or whose member
stream errors mid-scan is refused (`pgo-unreadable` — contract §E.3), never
treated as a clean result.

Replacing the packages is only half the fix — stale installs keep leaking
until they are rebuilt. `gsa -Ma` carries the installed-PGO-payload report
(contract §B.7), so a recurrence is visible without re-deriving the sweep.

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
