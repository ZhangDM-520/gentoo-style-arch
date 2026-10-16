# Maintainer guide

The recipe-maintenance manual for the `gsa` era. Commands below use current
`gsa` spellings; `docs/gsa-contract.md` §B.9 is the authoritative old→new
spelling roster, and `gsa --help` prints the authoritative flag roster.

## Groups

Group membership is topology data: the `groups` field of a recipe's
`config/topology.conf` record, never its directory name. The roster is stated
once, in the strict loader `gsa-topo`, and is closed — no name outside it is
readable.

| Group | Purpose | Membership |
| --- | --- | --- |
| `git` | recipes whose `pkgver` tracks a VCS snapshot (the `-git` style) | by tracking style, not physical category |
| `stable` | recipes tracking released upstream versions | by tracking style, not physical category |
| `core` | ABI-coupled hubs and the coupled stacks; runs alone with a memory-aware job budget | any recipe with ≥2 build-order consumers (see the rule below); deliberately overlaps the physical categories |
| `misc` | general one-off recipes | roster slot, currently without members (standalone-staged recipes use `packages/misc/` as their physical category — contract §B.11) |
| `app` | optional applications; `@app` triggers the TTY multi-select prompt | exclusive — wiring a record into `app` replaces its previous group |
| `build-tools` | compile toolchains; a dispatch-priority band, not a partition | always dual: `core,build-tools` |

Member counts drift with every addition; run this against
`config/topology.conf` rather than trusting a number in a doc:

```sh
awk -F'|' '!/^#/ && NF>2 {n=split($3,a,","); for(i=1;i<=n;i++) c[a[i]]++} END {for (g in c) print g, c[g]}' config/topology.conf
```

Group membership rules (2026-10-04): a package consumed by multiple packages
(≥2 build-order consumers) is an ABI-coupled hub and carries `core` — the
exception is `app-cluster` members like `fcitx5-git`, whose only consumers are
their own cluster siblings; compile toolchains carry `core,build-tools`
(dispatch-priority semantics in `docs/architecture.md`); `app` membership
stays exclusive. Group moves never touch `abi=`/`app-cluster=` tags
(`qt5ct`/`qt6ct` keep `abi=must` after leaving `core`). A recipe invoking
cargo/rustc must declare a `rust-git` build-order edge; `gsa -Ma` lints such
gaps.

## Adding a recipe

Place a clean recipe directory under the physical category that best describes
it, and add one record to `config/topology.conf`:
`id|path|groups|edges[|tags]`. The record is the only place that binds a
recipe ID to a filesystem path. `groups` is a comma list over the six group
names (see "Groups"), `edges` is the comma list of the packages this one
consumes (its local build-order edges — a record ending in a bare `|` is a
deliberate no-edge record), and `tags` carries coupled-batch policy
(`abi=must` / `abi=should`, see "Updating coupled stacks"), the optional
`app-cluster=<name>` prompt-cluster tag (see "The app group"), and the
explicit `version-sync=nvchecker` provider opt-in (see "Version-synced
external releases"). The loader validates every record on every invocation
and one malformed record breaks every command — and names the offender.

Keep `.SRCINFO` synchronized:

```sh
makepkg --printsrcinfo --dir packages/<category>/<package> \
  > packages/<category>/<package>/.SRCINFO
```

Do not copy the upstream Git checkout into the project. A VCS `source=`
entry, a pinned tag/commit, and a local patch are enough to reproduce the
recipe.

A new local asset must survive two ignore layers: the recipe's own
`.gitignore` (most recipes default-deny with a bare `*` plus `!` negations,
so a file without a matching negation is silently dropped from the commit)
and the root `.gitignore`, which denies every new subdirectory under a recipe
except `LICENSES/` — a recipe that needs a directory of its own needs the
negation added there too. Confirm with `git check-ignore -v <asset>` (no
output = visible). Never let a recipe `.gitignore` match itself.

`b2sums` is a flat list with one entry per source, so it can only match one
combination of a recipe's knobs. Keep the source set knob-independent where
you can. Where you cannot, make the recipe refuse the combinations it cannot
serve *and* keep the sum-generation path runnable — `packages/misc/linux-cachyos`
does both, and `tests/kernel-recipes.sh` pins it. Never grow `b2sums` with
per-knob `b2sums+=(…)` appends next to each `source+=(…)`: `updpkgsums`
rewrites the whole assignment as a literal on every version bump, so the
appends double-count at the first bump.

## Version-synced external releases

The `version-sync=nvchecker` topology tag is the only switch that routes a
build-time version update through a recipe's `.nvchecker.toml`; other configs
remain report-only. Use `gsa -Qt` to inspect the validated opt-in records
rather than inferring them from recipe paths.

Before adding an opt-in, pin the provider's identity in the matching tracker
section and ensure the recipe's version format can be applied safely. For AUR,
the fetched `.SRCINFO` must match `pkgbase`, `pkgver`, and the expanded source
array before it can supply pkgrel/epoch or checksum anchors. For GitHub, a
release digest anchors only the configured repo/tag/asset; absent digests are
reported as fetch-only. Provider outages defer the package, while a checksum
mismatch refuses the run and restores the recipe. `--no-sync` bypasses all
provider lookups and edits; see `docs/build-guide.md` for the full trust and
recovery contract.

## The app group

`app` is a real group whose members are leaf packages — a selection of one
expands to nothing beyond it, because app packages typically have no
consumers. A record wired into it carries `app` **alone** — membership
replaces the record's previous group. The 2026-09-27 wiring moved 22 records
in; `qt5ct`/`qt6ct` thereby left `core`, and the `third-party` group retired
at the same time (its two recipes relocated to `packages/stable/`). Leaving a
group does not touch coupled-batch tags: `qt5ct`/`qt6ct` keep their `abi=must`
tags, so a Qt ABI batch must still name them explicitly even though `@core` no
longer dispatches them.

An `@app` build or `--dry-run` on a TTY prompts to multi-select before the
normal pipeline runs (all unchecked + Enter = the whole group; any checked =
only those; `q` aborts); non-TTY runs and listings take the whole group
silently.

`app-cluster=<name>` (tags field, charset `[A-Za-z0-9._+-]+`, at most one per
record, comma-joined with any `abi=` tags) collapses records into one row of
that prompt — the `app-cluster=fcitx5` records present as a single
`fcitx5 [member ids]` row whose toggle checks or clears every member. The
cluster is prompt presentation only: members remain separate packages in the
listing (`-Sl`), the run record, ranges and lanes, and the prompt's "N
checked" counts rows, not packages. The tag is accepted on any record but is
inert outside the app prompt.

## Updating coupled stacks

LLVM snapshots have no stable C++ ABI. Rebuild Rust, Mesa, SPIR-V, libclc,
OpenShadingLanguage, and other consumers in the same documented pass after a
snapshot change. Qt private APIs similarly require the matching Qt module
batch. ROCm and stock-name replacement packages may require immediate
installation before the next consumer starts. Verify the installed ABI,
provides, and dependency closure rather than trusting version strings alone.

Changing install behaviour means changing `gsa-install`'s decision rows
(`gsa-install::decide`) — never introducing a second decision in a render or
execution path — and pinning the change with a fixture that asserts the
hidden `--install-decide <checked|force>` rows (`install`/`skip`/`refuse`/
`noop`/`parked`; rc 0 plan / 1 refusal / 2 bad usage) instead of rendered
prose.

Coupled-batch membership is topology data, in the record's `tags` field:
`abi=must` marks the ABI origin (llvm-git, the Qt base packages) and the
modules that must rebuild with it; `abi=should` marks same-pass candidates
that are only noted, never gated. The batch itself is derived from the edge
graph — every abi-tagged package that transitively depends on a selected
anchor — so membership cannot drift away from the edges the way prose could.
A real build whose selection includes an `abi=must` anchor while an installed
`abi=must` batch member is omitted is refused before anything dispatches,
with the missing members named; `--dry-run` and listings never gate.
Uninstalled members are never gated: they rebuild against the new ABI on
their next build anyway.

The same trap appears when a recipe *becomes* a Rust consumer. `mold-git` was
reworked into a cargo-based 3-phase Rust PGO build, which silently made it a
system rustc/cargo consumer, while its edge record stayed a deliberate
no-edge record (today: an empty `edges` field in its `config/topology.conf`
record) — a no-edge record is valid syntax, and the scheduler trusts it
blindly, so mold could dispatch before `rust-git` and died on an ABI-skewed
`rustc` one llvm-snapshot bump later (`prepare()`'s `cargo fetch` hit the
undefined `cl::ParseCommandLineOptions` symbol). A recipe that gains a
`cargo`/`rustc` invocation in ANY phase (prepare/build/check/package) must
gain a `rust-git` edge in the same change, and `gsa -Ma` flags violations of
that (toolchain lint). With the edge in place the guarantee it buys is build
order — `rust-git` before `mold-git` whenever both are selected. The consumer
direction is what a bare `llvm-git` selection exercises: it expands to its
consumers in build order — `rust-git`, `spirv-llvm-translator-git`,
`mesa-git`, `openshadinglanguage`, then each of *their* consumers such as
`mold-git` — while a bare `mold-git` selection is just `mold-git`, its
prerequisite `rust-git` assumed current (`--leaf` makes that explicit for any
name).

The 2026-09-25 Vulkan pair exposed this drift: an mtime-only `--skip` could
keep `vulkan-headers-git` at 1.4.363 while `vulkan-icd-loader-git` fetched
v1.4.364 and required newer headers. The historical recovery was to rebuild
the pair with `-S` (install as you go) and without `--skip`; that workaround
is superseded by the approved upstream-aware skip contract. Keep the
consumer's versioned makedepends (`vulkan-headers>=1:<pkgver base>`) aligned
with the provider's versioned provide so dependency resolution rejects a
stale provider before the consumer build.

For a VCS recipe, `--skip` may skip only after its existing archive-mtime
versus `PKGBUILD`-mtime check passes and each source's declared ref matches
the actual per-archive revision baseline captured by a successful build.
Resolve the selected ref for Git, SVN, Mercurial, and Bazaar sources, not an
unrelated `HEAD` in a shared checkout. A moved ref follows the normal build
path (and immediate installation under `-S`). If a selected ref cannot be
parsed or resolved, fail clearly before `makepkg`; do not skip or build
against unknown upstream state. When an archive has no usable baseline,
resolve every selected ref and perform one normal build to record the actual
revisions used for its replacement. Never infer that the current ref produced
the old archive. A later `--skip` can skip the rebuilt archive. Non-VCS
recipes remain mtime-only, and `--skip` under `-S` installs a genuinely
skipped archive through the existing path.

## Validating a change

```sh
cargo test --workspace                 # engine
bash tests/run-all.sh                  # fixture battery (parallel; substring filter)
bash -n packages/<category>/<pkg>/PKGBUILD   # any recipe whose shell you touched
makepkg --printsrcinfo --dir packages/<category>/<pkg> \
  > packages/<category>/<pkg>/.SRCINFO       # recipe metadata change
gsa -Ma                                # audit lints — report-only; read the report
gsa -S --dry-run @git                  # topology edit; repeat for the other groups
```

`CONTRIBUTING.md` holds the submission checklist; never use a real rebuild as
a syntax check.

## Documentation history

`docs/MEMORY.md` is the compact operational contract. `docs/NOTE.md` is the
chronological incident journal retained from the original workspace. Add a
dated note for every non-trivial packaging or scheduler change:

1. symptom;
2. root cause;
3. fix;
4. validation;
5. durable rule for the next maintainer.

Keep private paths, credentials, host logs, and generated artifacts out of
both files.
