# Gentoo_Style_Arch

Gentoo_Style_Arch is a curated Arch Linux package set for rebuilding a
large, dependency-coupled desktop and toolchain stack from `PKGBUILD`
recipes. It contains the recipes and the scheduler; it does **not** vendor
upstream source trees, package archives, build outputs, or downloaded
signatures.

The project is intentionally Arch-specific. Every `PKGBUILD` is executable
shell code and may fetch and build software with the privileges and network
access available to `makepkg`. Read the recipe and the security guidance
before building or installing anything.

The set is maintained for **AMD laptops**: AMD CPUs with amdgpu/radeon
graphics. Hardware-support trims follow from that target — a recipe may drop
Intel- and NVIDIA-only firmware, drivers and code paths — while the recipes
themselves are written to build on any Arch x86_64 host, deriving ISA settings
from the environment rather than pinning one. Packages built from this tree are
tuned to the building machine (see `docs/portability.md`) and are not
redistributable binaries. Trimming has been exercised on one AMD model, so
treat "AMD laptop, any" as the intent and a second model as useful
verification.

## What is included

The current set has 651 recipe records — one per recipe directory — and 877
group memberships (counts of the `groups` tokens in `config/topology.conf`,
counted 2026-10-12; re-check with
`awk -F'|' '!/^#/ && NF>2 {n=split($3,a,","); for(i=1;i<=n;i++) c[a[i]]++} END {for (g in c) print g, c[g]}' config/topology.conf`).
The counts differ because many records are dual-members (`stable,core`,
`core,build-tools`, `git,core`, …), and 81 split-package recipes build many
pacman package names — one recipe, many pkgnames (`gst-plugins-base`,
`vlc-plugin-freetype` and `gnome-desktop-4` are package names built by the
`gstreamer`, `vlc` and `gnome-desktop` recipes, not records of their own),
357 output names beyond the record count;
`core` is a logical build group whose 260 members deliberately overlap the
physical layout: 51 recipes live under `packages/core/`, and further
members come from `packages/git/` and `packages/stable/`:

| Group | Members | Purpose |
| --- | ---: | --- |
| `git` | 140 | Top-level development and rolling packages |
| `stable` | 404 | Stock-name packages synchronized with Arch repositories |
| `core` | 260 | Heavy, ABI-coupled, source-heavy, and ROCm packages |
| `misc` | 0 | Roster slot (group name stays readable; no current member) |
| `app` | 56 | Optional applications; a TTY build/`-n` run prompts to multi-select (all unchecked + Enter = build all; records sharing an `app-cluster` tag toggle as one row); leaf builds — app packages typically have no consumers to expand |
| `build-tools` | 17 | Dispatch-priority class: within a run its members are dispatched before all other ready packages but never over build-order edges; membership is always dual `core,build-tools`, and selecting `-g build-tools` does not auto-enable `-i` |

Package records — the ID-to-path binding, group membership, the local
build-order graph, and coupled-batch tags — are declarative, one record per
package in `config/topology.conf` (`id|path|groups|edges[|tags]`); do not
infer build order from directory names.

## Fresh checkout

On an Arch-based system, install the normal packaging tools first:

```sh
sudo pacman -S --needed base-devel fish git ripgrep
```

Then inspect the project before building:

```sh
fish build-all.fish --help
fish build-all.fish --list
fish build-all.fish --audit
fish build-all.fish --dry-run --group git
```

Validate a change with the fixture battery (`tests/`) — it is fast and
non-mutating — and with `makepkg`'s own checks. `tools/` holds host-side
diagnostics that are deliberately too heavy for that battery:

```sh
bash tests/run-all.sh                  # every fixture (parallel by default)
bash tests/run-all.sh recipe           # substring filter
bash tests/run-all.sh --serial         # one at a time
tools/go-modcache-check.sh             # is the Go module cache intact?
```

Build a selected group or package. Selection is mandatory; a bare invocation
never starts an unattended full rebuild. A selection expands to the named
packages plus their transitive consumers — the packages that must rebuild
after them — in build order; prerequisites are assumed installed and current.
`--no-deps` rebuilds exactly what is named:

```sh
fish build-all.fish --group git
fish build-all.fish --group core
fish build-all.fish glib2-git               # glib2-git and its consumers
fish build-all.fish --no-deps glib2-git     # glib2-git alone
```

Use `--install` only when the immediately installed package state is desired.
A package whose exact version is already installed (with an install date not
older than its archive) skips its transaction; `--forceinstall` implies
`--install` and always installs. Install decisions are fail-closed — a run
whose discovery yields no archive refuses to install nothing, and PGO
archives carrying a baked profile destination are refused — and
`fish build-all.fish --install-decide <checked|force> <archive...>` prints
exactly what would be decided (rc 0 plan / 1 refusal / 2 bad usage). Unprivileged runs use `sudo` for each
transaction; long runs are generally more reliable when the supervisor is
started as:

```sh
sudo fish build-all.fish --group core
```

The builder still runs `makepkg` as the invoking user in root-supervisor mode.
See `docs/build-guide.md` before using installation or cleanup modes.

## Adaptive parallelism

The default `--intensity xhigh` profile derives concurrency from available CPU
threads and `MemAvailable`. It budgets normal-lane jobs globally, rather than
granting every lane an independent memory allowance. Heavy `core` recipes run
alone with a separate memory-aware job limit.

Choose a named effort profile when automatic scheduling should be less or more
aggressive:

| Profile | Intent |
| --- | --- |
| `low` | One conservative lane; maximize memory headroom |
| `medium` | Balanced baseline for long-running hosts |
| `high` | More independent lanes and lower per-job memory budget |
| `xhigh` | Default; aggressive utilization with bounded automatic lanes |
| `max` | Highest automatic utilization; use only when OOM risk is acceptable |

Override the plan explicitly when needed:

```sh
fish build-all.fish --group git --intensity medium
fish build-all.fish --group git --lanes 1 --jobs 2
GSA_INTENSITY=low fish build-all.fish --group git
```

`GSA_CPU_THREADS` and `GSA_MEMORY_GIB` are also available for constrained
containers and deterministic scheduler fixtures. Normally they should be
left unset so the host's `/proc` and `nproc` values are used. Explicit
`--lanes` and `--jobs` values take precedence over the profile.

Runtime logs, lane results, and locks are written under
`.state/` by default and are ignored by Git. makepkg source trees and package
archives remain beside their recipe unless your makepkg configuration directs
them elsewhere; those classes are also ignored. Set `GSA_STATE_DIR` to keep
builder state outside the checkout.

## Source policy

Remote Git repositories, release archives, PGP key caches, and build trees are
deliberately absent. A clean checkout fetches them through the `source=()`
entries in each recipe. Local patches, hooks, install scripts, desktop files,
configuration inputs, licenses, and `.SRCINFO` files are retained because
they are part of the packaging work.

`--link-sources` can deduplicate compatible VCS mirrors after sources have
been fetched. Shared mirrors are runtime state and must not be committed.

## Licensing

`LICENSE` applies only to the original scheduler and project documentation.
Recipes contain upstream/AUR material with their own copyright, license,
maintainer, checksum, and source terms. Preserve the package-local metadata
when redistributing or modifying a recipe.

See:

- `docs/build-guide.md` for operations and cleanup;
- `docs/portability.md` for CPU, RAM, ISA, and profile controls;
- `docs/maintainer-guide.md` for recipe and dependency maintenance;
- `docs/MEMORY.md` and `docs/NOTE.md` for the retained operational history;
- `SECURITY.md` before running a new or changed recipe.
