# plan-gsa-isolation.md — pacman-class isolation for the gsa engine (directories, privilege, distribution)

**Status: COMPLETE (2026-10-16).** W1 implemented and verified 2026-10-15
(privilege handle; `gsa-model::privilege` is the landed home, not
`gsa-build::priv`). W2 (config surface) and W3 (canonical recipe store)
implemented and verified 2026-10-16 (`gsa_model::config`, `gsa_state::recipes`,
`tests/gsa-store-v2.sh`; docs/NOTE.md same date records the settled design
decisions and the W1 audit). W4 (build/cache relocation to the build user's
cache with `GSA_BUILD_DIR`, truth-filtered dual-location archive discovery,
the standalone-PKGBUILD distribution input — stage → build → index,
`tests/gsa-standalone.sh` a–e — and the contract amendments
(`docs/gsa-contract.md` §B.11/§C.1/§G/§J/§K, this file's addendum in
`plan-native-pm.md`, `docs/MEMORY.md`, `docs/NOTE.md`) landed and verified
2026-10-16. The one item carried as follow-up hardening beyond this plan: the
strict single-location flip of the archive-writing fixture stubs (discovery
stays truth-filtered across `PKGDEST` + recipe dir meanwhile — a plan
non-goal keeps fixture semantics intact). Supersedes the
deployment/directory assumptions in `plan-native-pm.md` where they conflict
(the engine architecture itself stands); `plan.md` (fetch-ahead) is untouched
and stays a subsystem design.

## TL;DR

Today `gsa` is *summoned from the user's terminal path*: it discovers a workspace
from cwd, builds beside the recipes, and writes engine state to `/var/lib/gsa` —
while the ownership rules demand the build user own the state. Any `sudo gsa` run
poisons the tree root-owned and every later unprivileged run dies at the
`run.lock` quarantine wall (the reported bug); running under sudo then breaks the
other way (makepkg as root is refused). The fix is not a patch on that contradiction
but the pacman model: **gsa owns its domain, users get config only**.

- The **recipe store** is gsa-owned and **fetched on demand** (our repo), never
  user-cloned, never user-edited; the **PKGBUILD is the distribution unit** —
  gsa accepts a standalone recipe and spawns its own variable directories.
- The **build cache** is gsa-managed (`~/.cache/gsa` of the build user, paru-style);
  **sources honour `makepkg.conf`** (SRCDEST) untouched.
- The **privilege handle** is pacman's: reads unprivileged, mutations require root,
  with every build-side command dropped to the build user and every refusal naming
  its remedy.

## Locked owner decisions (2026-10-15)

1. Mutating runs require root **uniformly** (`-S`, `-B`, `-U`, `-Sw`, `-Sy`, `-Su`,
   write-side `-M` verbs, hidden write seams). `gsa -Q`/read-only verbs run
   unprivileged. No `--state-dir` escape hatch: root-only is root-only.
2. `gsa -B` (build-only) is mutating → root, like `-S`/`-U`.
3. Project model: **gsa-owned canonical copy** of the recipe set at a fixed path,
   fetched on demand — the user's dev checkout is edit-only. Builds never depend
   on cwd.
4. Build dir default: the **build user's `~/.cache/gsa`** (resolved via
   `SUDO_UID`/`SUDO_GID`), configurable.
5. Config surface: **`/etc/gsa.conf` + `~/.config/gsa/gsa.conf` auto-read**, no new
   CLI flag (`--config` stays what it is: the target `pacman.conf` of `-S`/`-U`).
6. Distribution: a **PKGBUILD alone** is shareable; gsa scaffolds its own
   `.state/`-class variable dirs and fetches the recipe/sources into gsa-owned
   places when needed.

## The directory model (one owner per path)

| Path | Owner | Content / rule |
| --- | --- | --- |
| `/var/lib/gsa/` | root | engine state: `index/`, `runs/`, `logs/`, `locks/`, `kv/` — written only by privileged runs (rule 19 restated: state is owned by the *privileged runner*, not "the build user") |
| `/var/lib/gsa/recipes/` | root | canonical recipe store, fetched on demand from the recipe repo (config `recipe_url`/`project` override for dev checkouts). Isolated from user edits like `/usr/share` — the user never hand-edits it |
| `~/.cache/gsa/` (SUDO_UID's home) | build user | `build/` trees, `pkg/` staging, built archives (engine passes `BUILDDIR`/`PKGDEST` to makepkg) |
| `makepkg.conf` `SRCDEST` | build user | source cache — honoured, never overridden ("the source fetch path could be clear to honour makepkg.conf") |
| `/etc/gsa.conf` | root | host config: `recipe_url`, `project` (dev override), `build_dir`, `state_dir`, defaults |
| `~/.config/gsa/gsa.conf` | build user (under sudo: SUDO_UID's home) | user config layer |
| a shared PKGBUILD | — | the distribution unit; gsa materialises its work dirs and fetches what the recipe needs on demand |

Consequences: cwd stops mattering (no volatile "user's terminal path"); there is no
ownership gap between "gsa-owned items" (root) and build outputs (build user);
`run.lock` root-owned is *correct state*, not corruption; a build user hitting a
mutating verb gets an early, transparent refusal instead of a quarantine wall.

## The privilege handle (transparent, pacman's shape)

| Class | Verbs | Rule |
| --- | --- | --- |
| read-only | `-Q*`, `-Ss/-Si/-Sl/-Sg`, `-Bl`, `--dry-run` plans, `-Ma`, `-Ml`, `-Mh` (view), hidden read seams (`--install-decide`, `--local-db-check`, `--qa-check`, `--stale-lock-check`) | any user; never touches state for write |
| mutating | `-S`, `-B`, `-U`, `-Sw`, `-Sy`, `-Su`, `-Mi`, `-Mc/-Mcc/-Mccc`, `-Ms --add/--remove`, `-Mw --add/--remove`, `-Md --fix`, `-Mh --prune`, `-Ml --keep`, hidden write seams (`--install-register`, `--register-ignorepkg`) | **root required**; unprivileged → early refusal, **rc 3** (contract §G.1 "refusal"), pacman-worded: `you cannot perform this operation unless you are root` + one line that builds run as your user under `sudo` |
| build-user-only | `-Mm` (mirrors) | keeps its existing invariant ("must run as the build user, never under a root supervisor", `docs/source-sharing.md`) — it mutates only user-domain source clones |

Under root:
- every build-side spawn (`makepkg`, `makepkg --printsrcinfo`, `updpkgsums`,
  recipe-tree helpers) drops to the build user via `setpriv --reuid --regid
  --init-groups` (SUDO_UID/GID); env preserved (stub-friendly for fixtures).
- euid 0 **without** SUDO_UID (bare root shell) + a build-touching verb → refusal
  with guidance ("run `sudo gsa …` from your build user; makepkg cannot run as root").
- engine-side writes into any build-user path are chowned to the build user; the
  pacman-shim's transaction lock moves under `sudo -n` (the mutex lives in
  root-owned state and the shim runs as the dropped build user).
- every privileged run prints one banner line: engine+pacman as root, makepkg and
  cache writes as `<user> (uid N)`.

## Distribution model

- `gsa` accepts a **standalone PKGBUILD** (path or URL) as a target: it stages the
  recipe into its own work area, creates its variable dirs, and fetches the
  recipe's sources on demand (honouring `SRCDEST`) — "gsa spawns its own `.state/`
  etc. variable directories and fetch the recipe in its place when needed".
- Sharing a package = sharing its PKGBUILD (+ patch files as declared sources);
  rebuilding = `gsa` + the recipe, no project clone required.
- "build will fetch our repo / crate": anything the build needs from our recipe
  repo or crates is fetched by gsa into gsa-owned places on demand — never by
  asking the user to `git clone` the project.

## Implementation waves (small, each independently verifiable)

- **W1 — privilege handle (fixes the reported bug).** `gsa-build::priv`
  (`build_user`, `drop_command`, `own_to_build_user`), gate in `gsa-cli::run`
  (read-only/mutating/build-user classification per the table, rc 3 refusals,
  banner), makepkg-family drop, shim flock-under-sudo (`gsa-build::shim`),
  `refresh_package_srcinfo`/`updpkgsums` drops + recipe-tree chown
  (`gsa-recipe::sync`), `mirrors.rs` unchanged (already build-user-only),
  `lock.rs`/`ownership.rs` messages + rule-19 wording. Plus
  `tests/gsa-privilege.sh` (new subject fixture) and unit tests at the
  classification/drop seams.
- **W2 — config surface.** `/etc/gsa.conf` + `~/.config/gsa/gsa.conf` parsing
  (`project`, `recipe_url`, `build_dir`, `state_dir`, defaults), precedence user >
  system > built-in; `~` and SUDO_UID resolution documented.
- **W3 — canonical recipe store.** On-demand fetch into `/var/lib/gsa/recipes`,
  staleness check, refresh verb (`-Sy` gains "store refresh" semantics alongside
  the version-sync pass), dev override `project` config key; cwd discovery demoted
  to a warning, then removed.
- **W4 — build/cache relocation + distribution.** `BUILDDIR`/`PKGDEST` →
  `~/.cache/gsa`, `SRCDEST` honoured from `makepkg.conf`; standalone-PKGBUILD
  target input (stage → build → index); contract amendments
  (`docs/gsa-contract.md` §B/§G/§J/§K, `plan-native-pm.md` addendum, MEMORY rule 19
  + new rule, NOTE entry).
- **W5 — fixture migration + verification (needs AC).** gsa fixtures run the
  engine via `sudo env PATH="$PATH"` (stub PATH preservation); battery 65/65;
  real smoke: `sudo gsa -S <small>` end-to-end, unprivileged `gsa -Q`, the
  `run.lock` incident replay.

## Test plan (authored while on battery, executed when AC returns)

1. `tests/gsa-privilege.sh` — red first (today's build-user mutation dies at the
   quarantine wall / sudo run builds as root), green after W1:
   a. unprivileged mutating verb → rc 3, message names root+sudo remedy, state
      untouched;
   b. unprivileged read-only verbs work over root-owned state;
   c. `sudo gsa` stub run: stub makepkg records uid == SUDO_UID, banner printed,
      archives land in the build-user cache;
   d. bare root shell (no SUDO_UID) build run → refusal with guidance;
   e. shim: transaction path works with root-owned `locks/` (flock under sudo).
2. `cargo test` per touched crate (classification, drop-wrap argv, ownership
   messages).
3. `bash tests/run-all.sh` — 65 fixtures, with the W5 sudo migration applied.

## Non-goals / preserved invariants

- Source verification is never weakened (no `--skipchecksums`/`--skippgpcheck`);
  the makepkg argv contract (§A.3.4) is untouched by the privilege drop.
- The host's pacman system survives every failure mode (rule 23) — gsa's root
  domain never deletes `/var/lib/pacman` state; `db.lck` is never removed.
- The fish builder and its 65-fixture battery semantics stay intact; W5 changes
  only how fixtures invoke the *native engine*.
