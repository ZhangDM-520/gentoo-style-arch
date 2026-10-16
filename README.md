# Gentoo_Style_Arch

A curated Arch Linux package set — and `gsa`, the build engine that
rebuilds it as one coherent system.

The set exists to rebuild a large, dependency-coupled desktop and toolchain
stack from `PKGBUILD` recipes with one command: the engine resolves the
build order, builds and installs each package before its consumers compile,
and keeps the whole run accountable — plan, outcome, and continuation — as
one run record. Everything is tuned to the machine that builds it, so the
result is a local, self-optimizing system rather than a binary distribution.

The project targets **AMD laptops** (amdgpu/radeon) on Arch x86_64. Recipes
may trim Intel- and NVIDIA-only firmware and code paths; ISA settings are
derived from the build environment, never pinned. Built packages are not
redistributable binaries — they are tuned to the building machine.

## The two halves

- **The recipe set** — `packages/<category>/<package-id>/`: one `PKGBUILD`
  per recipe with its committed `.SRCINFO`, local patches and assets, and
  upstream license material. Declarative topology (build order, groups,
  coupled-ABI batches) lives once in `config/topology.conf`.
- **The engine** — `gsa`, a native binary built from this repository's Rust
  workspace (`crates/`), packaged by `packages/core/gsa-pm`. It is
  pacman-shaped on purpose: `-Q` to query, `-S` to build and install, `-B`
  to build only, `-U` to install built archives, `-M` to maintain state.

What is deliberately absent: upstream source trees, package archives, build
outputs, and downloaded signatures. A clean checkout fetches what it needs
through each recipe's `source=()` entries, and every fetch is checksum- and
signature-verified — verification is never weakened.

## Quickstart

On an Arch-based system:

```sh
sudo pacman -S --needed base-devel git ripgrep rust
cargo build --release        # produces ./target/release/gsa
```

Inspect before building anything:

```sh
./target/release/gsa --help  # the authoritative command roster
./target/release/gsa -Sl     # the set, in build order
./target/release/gsa -S --dry-run @git
```

Then build. Selection is mandatory — a bare invocation never starts an
unattended rebuild — and a selection expands to the named packages plus
everything that must rebuild after them:

```sh
sudo ./target/release/gsa -S @git        # build + install, consumers included
sudo ./target/release/gsa -S glib2-git   # one package and its consumers
./target/release/gsa -B --leaf glib2-git # just this one, archives only
```

`-S` installs each package before its consumers compile; `-B` builds to
archives and installs nothing. The tree also ships the `gsa-pm` recipe that
installs the engine as `/usr/bin/gsa` for everyday use.

## The mental model

- **Topology, not directory names.** Each package's identity, group
  membership, and build-order edges are one declarative record in
  `config/topology.conf`; the engine re-validates the whole map on every run.
- **Consumers, not dependencies.** Rebuilding a package also rebuilds
  everything that must build after it — the ABI risk lives in its consumers.
- **One run, one record.** Plan, per-package outcomes, and the continuation
  are computed once and rendered as dashboard, prose, and machine output.
- **Fail closed.** A failed package parks its consumer cone and the run says
  exactly why; a refused install never touches pacman; an interrupted run
  prints the same record a finished one does.
- **The build runs as you.** The engine and pacman act as root; `makepkg`
  and all build-side tools run as your user. It never prompts.

## Read before building

Every `PKGBUILD` is executable shell code with the privileges and network
access `makepkg` has. Read the recipe and `SECURITY.md` before building or
installing anything you have not reviewed.

## Where to go next

| Document | What it answers |
| --- | --- |
| `docs/gsa-contract.md` | The `gsa` command contract: grammar, selection, exit codes, state layout |
| `docs/build-guide.md` | Operations: install modes, cleanup strengths, environment surface, troubleshooting |
| `docs/portability.md` | CPU/RAM tuning, effort profiles, ISA policy |
| `docs/architecture.md` | How the engine and the recipe set are structured, and why |
| `docs/maintainer-guide.md` | Adding and updating recipes, coupled stacks |
| `CONTRIBUTING.md` | The recipe-change checklist and validation standard |
| `docs/package-policy.md`, `docs/source-sharing.md` | What a recipe may contain; shared source mirrors |
| `SECURITY.md` | Trust model and safe-operation rules |
| `CONTEXT.md` | The project's vocabulary |
| `docs/MEMORY.md`, `docs/NOTE.md` | Operational rules and the incident history behind them |

## Licensing

`LICENSE` covers the engine and project documentation only. Recipes carry
upstream/AUR material under its own copyright, license, and source terms —
preserve each package's attribution and license files when redistributing or
modifying a recipe.
