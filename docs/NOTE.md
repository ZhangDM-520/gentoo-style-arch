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
retired 2026-09-27), and logical groups `git`, `stable`, `core`, `misc`,
`app`, `build-tools` (stated in `config/topology.conf`).

| In older entries | Was | Now |
| --- | --- | --- |
| `.Heavy/`, `.Heavyweight/` | the heavyweight build area | `packages/core/` (or `packages/git/` for rolling recipes) |
| `.Static/`, `.Stable/` | stock-name packages whose versions track the repos | `packages/stable/` (or `packages/git/`) |
| `.Core/` | `.Heavyweight/` renamed 2026-09-15 | `packages/core/` |
| `.3rdP/` | third-party application recipes | `packages/stable/` — directory retired 2026-09-27 (group `third-party` retired with it; the recipes are `app` members) |
| `.Misc/` | auxiliary recipes | `packages/misc/` |
| `-g static`, `-g heavy`, `-g critical`, `-g rocm` | four separate groups | `-g stable` and `-g core` (2026-09-15); `core` auto-enables `-i` |
| `git,stable,core,misc,app` (five-name roster) | the logical-group roster before 2026-10-04 | six names — `build-tools` added 2026-10-04 |
| `-si`, `--sepinstall` | the separated-install flag | removed 2026-09-17 — `-i`/`--install` is the only spelling |
| `--installall` at end of run | the old collective install | `-ia` remains as a one-transaction escape hatch; a normal run installs per package with `-i` |
| `tests/*-pgo-transition.sh` (five 6-line wrappers) | one wrapper per PGO recipe | folded into `tests/pgo-transition.sh` (no args = all five pairs) on 2026-09-24 |
| `tests/kernel-config-verify.sh`, `kernel-recipe-sums.sh`, `kernel-recipe-version.sh` | three kernel fixtures | one `tests/kernel-recipes.sh` with three sections (2026-09-24) |
| `tests/log-ownership-root.sh`, `noctalia-pgo-train.sh`, `zen-pgo-workload.sh` + `zen-pgo-speedometer.sh`, `vencord-recipe.sh` + `vencord-inject.sh`, `project-config.sh` + `project-cli-hints.sh` | one file per sub-area | sections of `tests/log-ownership.sh`, `noctalia-pgo.sh`, `zen-pgo.sh`, `vencord.sh`, `project.sh` (2026-09-24) |

So `.Static/qt6-base` and `packages/stable/qt6-base` are the same recipe family,
and `.Heavy/llvm-git` is today's `packages/core/llvm-git`. Package IDs,
dependency edges, and incident root causes are unaffected by the renames.

## 2026-10-06 — libtool self-resolution poisoned an in-place rebuild (libao)

**Symptom.** Run #9 of the real-world `-i` full build failed at `libao`
(22/652) linking its pulse plugin: `mold: fatal: cannot open
.../src/plugins/pulse/.libs/libpulse.so: No such file or directory` — the
plugin's own output path opened as an *input*. The same generated command line
fails identically under bfd, lld and mold, so no linker is at fault.

**Root cause.** Three-step chain:
1. run #8's parallel lane had already built libao successfully at 03:54,
   leaving `src/libao-1.2.2/src/plugins/pulse/libpulse.la` behind in the reused
   `src/` tree — makepkg re-extracts over it (bsdtar does not clean first);
2. the `git pull` of 5d489a5 rewrote `libao/PKGBUILD` **byte-identically** at
   04:02, so its mtime passed the fresh 03:54 archive and `-s` could not skip
   the rebuild;
3. libtool resolved the plugin's `-lpulse` dependency against the stale
   `./libpulse.la` — the module name `libpulse` collides with the dependency
   name — and substituted the `.la`'s `.libs/libpulse.so`, i.e. the link's own
   not-yet-built output. Every linker fails opening it.

**Fix.** `packages/stable/libao/PKGBUILD`: `prepare()` purges stale libtool
outputs after `autoreconf` (`find . -name '*.la' -delete`). The module-vs-
dependency name collision is upstream's; the stale-tree poisoning is ours.

**Validation.** Red: the run #9 failure plus a direct repro over the stale tree
against all three linkers. Green: the stale `libpulse.la` restored (poison
re-applied), fixed PKGBUILD copied to the workspace, `makepkg -sf --noconfirm`
rc 0, archive `libao-1.2.2-7.1` ships `usr/lib/ao/plugins-4/libpulse.so` and
the other three plugins. `bash -n` clean; `.SRCINFO` byte-unchanged.

**Rule.** A reused `src/` tree is stale state just like a Meson build dir:
leftover `.la` files make libtool resolve a module named after its dependency
to the module's own output on rebuild. Any rebuild over a reused tree triggers
it — including spurious ones (a `git pull` that bumps a PKGBUILD's mtime past
its archive defeats `-s`). MEMORY rule 6 extended with the class.

## 2026-10-06 — a soname swap met exact-pin stock leftovers (spandsp-git, pipewire)

- **Symptom**: run #7 stopped at `spandsp-git` (17/652) — the build succeeded, the INSTALL did not:
  `spandsp-git and spandsp-0.0.6-7 are in conflict … removing spandsp breaks dependency
  'libspandsp.so=2-64' required by pipewire-audio`.
- **Root cause**: `spandsp-git` (FreeSWITCH fork 3.1.1) ships `libspandsp.so.4` while stock ships
  `.so.2` — the ICU 78→79 class (soname bump on a swap target). One installed pinner
  (`pipewire-audio`), no lib32 pins. A second blocker hid behind it: the stock leftover
  `gst-plugin-pipewire` — trimmed from our `pipewire` recipe 2026-09-04 but still installed —
  pins `pipewire=1:1.6.9-1` (and `libpipewire`/`pipewire-audio`) EXACTLY, so any pipewire pkgrel
  bump is uninstallable until it goes.
- **Fix (heal-set, ICU pattern)**: stage the built spandsp-git (`/tmp/spandspstage`, `spandsp.pc`
  `prefix`+`libdir` rewritten — `libdir` is hardcoded in that file, missing it links the stock
  lib) → heal-build `pipewire` against the stage (`PKG_CONFIG_PATH`, `makepkg -s` pulls
  `rtkit`/`valgrind` from repos exactly like the run-time path) → retire `gst-plugin-pipewire`
  (`pacman -R`; zero revdeps, and rebuilding it was rejected: it would re-add a trimmed output and
  lock every future pipewire bump into a lockstep pin) → ONE `pacman -U --noconfirm --ask 4` of
  spandsp-git + the rebuilt splits of the six installed names. `libcamera-git`/`libldacdec` were
  built first — pipewire makedepends the run had not reached yet (wave = the run's own order).
- **Validation**: pre-swap `.PKGINFO` showed `depend = libspandsp.so=4-64` (makepkg auto-versioned
  from the linked ELF) and `readelf` on `usr/lib/spa-0.2/bluez5/libspa-codec-bluez5-hfp-msbc.so`
  showed `NEEDED libspandsp.so.4`; post-swap `expac` shows `=4-64`, `ldd` resolves
  `libspandsp.so.4 => /usr/lib/libspandsp.so.4`, `pacman -Dk` clean.
- **Rule**: a soname bump on a swap target needs its pinners rebuilt in the SAME transaction, and
  the wave must also clear stock leftovers that pin swap-set packages at exact versions — check
  `expac -Q '%n\t%D' | grep '<pkgbase>='` for `=`-pins before planning the wave; a leftover that
  the set trims is retired, never rebuilt (MEMORY rule 27 family).

## 2026-10-06 — upstream git repo grew an unclonable ref (libldacdec, libldac)

- **Symptom**: `libldacdec` died at source download: `fatal: trying to write non-commit object
  15a1c66 to branch 'refs/heads/android17-security-release'` while cloning
  `android.googlesource.com/platform/external/libldac`; pristine-clone test reproduced it (not
  env, not a stale mirror).
- **Root cause**: the canonical AOSP repo advertises a corrupt branch ref pointing at a non-commit
  object, and git 2.56 refuses to write it. makepkg's `download_git` clones `--mirror` (ALL
  refs) and no `#commit`/`#branch` fragment narrows the clone, so every makepkg build from this
  URL is broken — including stock Arch's `libldac`, which carries the same source. `git fetch`
  of the pinned commit by SHA works fine; the objects are healthy, only the ref advertisement is
  not.
- **Failed approach (keep out)**: googlesource's `+archive/<sha>.tar.gz` looked ideal (canonical
  host, checksummable) but its bytes are REGENERATED PER REQUEST — three downloads gave three
  sha256s (gzip metadata; file list identical) — and the raw `.tar` endpoint is not a tar at all.
  A checksum that cannot pin the bytes is no verification; the URL was rejected. First-attempt
  lesson: my own probe that "verified" the checksum verified ONE generation only.
- **Fix**: both recipes fetch the same pinned commits from `github.com/anonymix007/libldac` — the
  libldacdec author's own mirror of the submodule repo — which clones cleanly. Content is pinned
  by the git object id (identical commit hash = identical content), and makepkg's git-archive
  checksums (`git archive --format tar <commit> | sha256sum`/`b2sum`) are pinned in the recipes;
  the mirror-derived sha256 for `e8ff0f96` matched the AUR recipe's googlesource-derived value
  byte-for-byte — independent content-identity proof. Pins: `e8ff0f96` = submodule gitlink at
  libldacdec's pinned commit, `82b6a1ab` = gitlink at ldacBT `v2.0.2.6` (both verified with
  `git ls-tree`).
- **Second trap in the same rebuild**: with real (non-`SKIP`) checksums on `#commit=` sources,
  makepkg's `calc_checksum_git` runs `git archive` against the bare SRCDEST mirror — and the
  agent-shell git hardening (`safe.bareRepository=explicit`) kills it (`cannot use bare
  repository`), while `download_git`'s own fetch path passes `-c safe.bareRepository=all` and is
  fine. Any makepkg invocation from an agent shell needs `GIT_CONFIG_COUNT=0`.
- **Validation**: `bash -n`; `.SRCINFO` regenerated; recipe-sources fixture PASS; both commits
  `cat-file`-verified in the mirror; red→green by the real workspace rebuilds (both packages
  built + installed; `libldacdec` reproducibly failed before).
- **Rule**: a VCS source must be cloneable AT the pinned ref on a clean checkout — if upstream's
  ref advertisement rots, move to a mirror whose content is pinned by the same commit id and
  record the mirror's provenance in the recipe; never "verify" a regenerated archive from a
  single download, and never silence a checksum with SKIP to make a build pass (MEMORY rule 28
  family).

## 2026-10-06 — a signing-key rotation was not in validpgpkeys (js140)

- **Symptom**: run #8 died at `js140` in source validation —
  `firefox-140.17.0esr.source.tar.xz ... FAILED (unknown public key 678E455D76767AA3)`.
- **Root cause**: Mozilla rotated its Firefox/Thunderbird signing SUBKEY on 2026-08-06 (the
  2025-03 subkey was revoked after its unencrypted copy leaked); the recipe's `validpgpkeys`
  listed only the unchanged PRIMARY, and the host keyring lacked the new subkey. Recipe-vs-
  upstream drift of the key-material class — same shape as a version bump, but on `validpgpkeys`.
- **Fix, verified before touching the recipe** (source-verification rule): the signing key's long
  id `678E455D76767AA3` was matched to the published subkey fingerprint
  `827E658608679618CD349F93678E455D76767AA3` in Mozilla's security-blog announcement; the
  subkey binding is signed by the pinned primary in Mozilla's own published key block
  (`packages.mozilla.org/rpm/firefox/signing-key.gpg`); `gpg --verify` of the shipped `.asc`
  against the tarball reports a good signature with primary `14F2…D98F0353`. Then the subkey
  was added to `validpgpkeys` with a role/rotation comment and imported into the build user's
  keyring (makepkg verifies against the user keyring — a correct `validpgpkeys` alone is not
  enough).
- **Validation**: `bash -n`; `.SRCINFO` regenerated; recipe-sources PASS; signature re-verified
  good in a clean temp keyring; red→green by the real workspace rebuild.
- **Rule**: `validpgpkeys` is versioned upstream state like `pkgver` — a signature failure with
  "unknown public key" on a long-stable recipe is a key-rotation signal, and the verification
  chain is blog/published-key → subkey binding → detached signature, in that order; never import
  a key you cannot place in a publisher's own announcement.

## 2026-10-06 — a git recipe lost a build input that only release tarballs carry (opus-git)

- **Symptom**: run #6 died on `opus-git` after 14 successful builds —
  `opus/meson.build:659:24: ERROR: File dnn/fargan_data.h does not exist.`
- **Root cause**: recipe-vs-upstream drift. `lpcnet_headers.mk`/`lpcnet_sources.mk` reference
  `dnn/fargan_data.{c,h}` UNCONDITIONALLY (fargan is core code since the DNN rewrite, unlike the
  optional dred/osce/deep-plc the recipe disabled), but the git tree carries no model data:
  upstream pins the model's sha256 in `autogen.sh` and publishes the *generated* weight tables
  (`dnn/*_data.{c,h}`) as `opus_data-<sha256>.tar.gz` on `media.xiph.org` — the file name IS the
  content checksum (`dnn/download_model.sh` verifies the argument against the download;
  `create_opus_data.sh` names the archive after its own digest). Release tarballs ship the
  tables pre-generated, which is why stock only builds from them. The recipe's stock-derived
  comment ("Git doesn't contain model data … disabled for VCS builds") described a fact about
  the TREE but the recipe then treated it as "no data exists at all" — the disable only covered
  the optional features while the unconditional ones died at configure.
- **Fix**: declare `opus_data-<sha256>.tar.gz` as a second `source=()` entry with a `b2` checksum
  (makepkg-verified, not an out-of-band `download_model.sh` call), extract the weight tables in
  `prepare()` excluding training-only `dnn/models/*.pth` (referenced by no build list), and add a
  `prepare()` guard that fails closed when the sha256 `autogen.sh` pins drifts from the recipe
  pin (prints both and the exact update). With the data present, stock's feature set is restored
  (`-D deep-plc/dred/osce=enabled`) — the earlier disable was data-forced, not a trim. The same
  rebuild then hit the lilv-git class AGAIN one stage later: `meson.build:682 find_program('doxygen',
  required: get_option('docs'))` — stock's doxygen makedep went with the opus-docs split, and
  `arch-meson`'s `--auto-features enabled` forces the `docs` feature ON. Fixed with
  `-D docs=disabled`, `# trim:`-annotated (house pattern).
- **Validation**: `bash -n`; `.SRCINFO` regenerated; drift guard probed both directions (real pin
  extracts to the recipe value; same-length mutation detected — first probe mutated the digest
  LENGTH and only proved the fail-closed path, a probe must preserve the input shape);
  `tests/recipe-sources.sh` PASS (513 local sources / 653 recipes). Red→green proven by the real
  workspace rebuild (both failures reproduced first): `opus-git 1.6.1.r68.g503d81b1-1` builds with
  `provides = libopus.so=0-64`, `usr/lib/libopus.so.0.11.1` at 4 475 792 B vs stock 4 515 784 B
  (stock feature parity), `opus_dred_*`/OSCE/PLC symbols exported, no docs payload and no
  `dnn/models/*.pth` in the archive.
- **Rule**: a VCS recipe for a project whose build needs generated/fetched data absent from git
  must pin that data as a checksummed source AND fail closed against whatever in-tree file names
  the upstream pin; and a trim/disable comment must state which facts forced it, so the option
  can be revisited when the fact changes (MEMORY rule 28).

## 2026-10-06 — a docs trim left its build stage behind (lilv-git)

- **Symptom**: run #5 died on `lilv-git` at 0m11s — `lilv/doc/meson.build:7: ERROR: Program
  'doxygen' not found`, although the recipe's own comment says the doxygen/python-sphinx
  makedeps were "dropped with the lilv-docs output". The output was dropped, the tool was
  dropped, the STAGE that produces them was not.
- **Root cause**: `arch-meson` passes `--auto-features enabled`, so every meson `feature` option
  is forced ON — lilv's `docs` feature makes `find_program('doxygen')`/`find_program('sphinx-build')`
  REQUIRED even though the package ships no docs. This is exactly MEMORY §8's trim warning:
  dropping only the tool leaves a build that dies looking for it. The man pages are safe — they
  are hand-written `doc/*.1` installed from `tools/meson.build`, not generated by the docs stage.
- **Fix (two stale steps, one recipe)**: (1) `arch-meson lilv build -D docs=disabled`,
  `# trim:`-annotated beside the existing makedepends note (house pattern: `libepoxy-git`
  `-D docs=false`, `libproxy-git`, `librsvg-git`, `dbus` `-D doxygen_docs=disabled`,
  `accountsservice`, `modemmanager-git`); (2) the `install /etc/bash_completion.d/lilv` move was
  deleted — upstream landed work item 15, so meson installs the completion straight into
  bash-completion's `completionsdir` and the stock /etc → /usr/share move had nothing to move
  (`install: cannot stat .../etc/bash_completion.d/lilv` was the next failure in the same
  rebuild). Red→green proven by the real rebuild: both failures reproduced, then all three
  split packages built with the hand-written `man1/*.1` pages and the completion in
  `lilv-tools-git`; `bash -n` clean, `.SRCINFO` unchanged (no metadata change).
- **Rule**: a docs/tool trim on a meson recipe must disable the FEATURE (`-D docs=disabled` /
  `-D <x>_doc=false`), not only the makedepends and the install paths — `arch-meson`'s
  `--auto-features enabled` turns every optional tool into a hard requirement. When a trim
  comment names a dropped output, the stage producing it must show the disable flag in the same
  hunk. And a package() relocation of an upstream install path is a versioned assumption: when
  upstream lands the fix (lilv work item 15), the move must go in the same change.

## 2026-10-06 — post-install NEEDED probe false-aborted on stock providers

- **Symptom**: run #4 of the same full build stopped at `libxpm-git` — the package BUILT and
  INSTALLED fine, then `post-install NEEDED probe` aborted: `usr/lib/libXpm.so.4.11.0 needs
  libX11.so.6 — unresolved after the transaction` (plus `libXt.so.6`, `libXext.so.6`), run rc 1,
  dispatch stopped. The dynamic linker resolves all three at runtime.
- **Root cause (guard model, not a package)**: the probe's resolution set was the
  transaction's `.PKGINFO` provides + the installed DB's provides. But stock Arch does NOT
  mirror files 1:1 in provides — `libx11`, `libxt`, `libxext` (and, measured over this host's
  top-level consumers, ~350 more stems) ship no `provides=(libX11.so)` at all (`pacman -Si
  libx11`: `Provides : None`). A provide-set-only probe therefore false-aborts every consumer
  of any provider whose PKGBUILD never declared its bare soname provide — and the run hits it
  one package at a time. The fixture's case D also leaked its `libgreet.so` exclusion entry
  into every later case (`reset_case` never removed it), masking exactly this class.
- **Fix**: `install_needed_probe` now has the runtime-file half of resolution — a NEEDED name
  also resolves when its file is on the resulting system: shipped by the transaction itself
  (per-probe `_PROBESHIP_` basename index over the extracted members) or owned by an installed
  package (one lazy `pacman -Ql` basename dump per probe). The provide set stays the primary
  (and still names the packaging gap in layer 1's lint); the file check is what decides the
  abort. True positives are kept: a soname whose file vanished (the icu 78→79 class) has
  neither a provide nor a file and still aborts. `tests/abi-postinstall-probe.sh` gains cases G
  (owned file, no provide — red-first against the unfixed builder, then green) and H (bytes
  shipped by the same transaction, no provide), and case D now removes its registry entry.
  Mutation-probed: disabling either fallback re-fails exactly its own case.
- **Rule**: a guard that models the packaging DB must not treat the DB as complete. When the
  question is "does this resolve at RUNTIME", the file on disk (or in the transaction) is the
  truth and declared provides are one evidence source among several. And when a fixture case
  mutates shared state (a registry, a config), restore it — a leaked entry silently turns the
  next case into a tautology.

## 2026-10-06 — icu-git soname bump 78→79: the atomic heal-set transition

- **Symptom**: third install refusal of the same real full build, this time on `icu-git`
  (run #3, ~13 min of building first): `removing icu breaks dependency 'libicuuc.so=78-64'
  required by libxml2`. Upstream ICU master had moved to soname 79 (`provides =
  libicuuc.so=79-64` in the freshly built archive) while the installed consumers still pin the
  exact soname `libicuuc.so=78-64`.
- **Root cause (class, not one package)**: makepkg's autodeps bake the linked soname into
  `depend = libicuuc.so=78-64`, and a rolling `-git` provider that bumps the soname can never
  satisfy the old pin — unlike the lib32 lockstep `name=version` pins of the same day, these
  pins are ABI truth and must NOT be relaxed. A full-system scan of the local DB (`grep -l
  libicu /var/lib/pacman/local/*/desc`) found exactly two 64-bit pinners — `libxml2`, `raptor` —
  but the runtime closure was wider: `pacman → libxml2 → ICU`, `snapper`, `cmake` and
  `gdb → libboost_regex`, so a forced swap would have broken the package manager and the
  snapper transaction hooks mid-run.
- **Fix (host, one atomic transaction)**: staged the built `icu-git` archive into
  `/tmp/icu79stage` (its `icu-*.pc`/`icu-config` prefixes rewritten to the stage), rebuilt the
  heal-set from Arch's packaging git against the stage — `libxml2 2.15.4-1.2`, `raptor
  2.0.16-9.2`, `libqalculate 5.12.0-1.2` (pkgrel `.2` local deltas; raptor's `.asc` verified
  against the vendored upstream key; the heal libxml2 is a bridge without docs/python, since
  doxygen is purged here and the run's in-set `libxml2-git` replaces it) — then ONE
  `pacman -U --noconfirm --ask 4` of `{icu-git, libxml2, raptor, libqalculate}`: the old pinners
  are replaced in the same transaction, so no `--assume-installed`/`-Rdd` hack was needed and
  the snapper pre/post hooks ran on consistent states. Post-check: `ldd` of pacman/snapper/cmake
  resolves `libicuuc.so.79`, no `.so.78` remains in any toolchain closure, and the only
  surviving `=78` pins are the untouched 32-bit ones.
- **Topology**: 23 records whose `.SRCINFO` declares `icu` (depends/makedepends) lacked the
  `icu-git` build-order edge (`libxml2-git`, `raptor`, `boost-libs`, `libical`, `harfbuzz-git`,
  `qt6-webengine`, `nodejs`, `postgresql-libs`, …), so a from-scratch run could compile ICU
  consumers against the wrong generation. All 23 now carry the edge.
- **Rule**: a soname bump is a batch, not a package: rebuild every pinner and every
  runtime-critical linker in ONE `pacman -U` transaction against the staged new provider, verify
  with `ldd`/`readelf -d` afterwards, and never relax a soname pin or reach for
  `--assume-installed` to get past one. Detect the set from the local DB (`grep -l
  'libicu<name>\.so=' /var/lib/pacman/local/*/desc`) plus a `readelf -d` sweep of `/usr/lib` —
  pin lists alone miss silent linkers that simply fail at runtime.

## 2026-10-06 — archive discovery dropped the epoch (real full build, first package)

- **Symptom**: the first package of a real 652-package `-i` run (`ninja-git`, epoch=2) built
  cleanly and then refused to install: `install requested but no built package archive matched
  the current pkgver-pkgrel — refusing to report success`, run rc 1, dispatch stopped.
- **Root cause**: `pkgbuild_version` (lib/sources.fish) returned the bare `pkgver`, but makepkg
  writes the archive filename from `get_full_version` = `epoch:pkgver` — the artifact is
  `ninja-git-2:1.13.2.r196.g4e4df1e5-1-x86_64.pkg.tar.zst` while discovery looked for the stem
  without the `2:`. `archive_matches_output` is literal string surgery (correctly — pkgver may
  carry metacharacters), so the epoch must be joined BEFORE the match. 47 recipes carry `epoch=`,
  so every one of them would have died the same way at install time. No fixture had used an epoch.
- **Fix**: `pkgbuild_version` now returns pkgver exactly as makepkg builds it into the filename
  (`${epoch:+$epoch:}${pkgver}`); its only consumer is `current_archives`, so the seam is
  contained. `tests/install-archive-guard.sh` case A4 pins an epoch-bearing recipe whose archive
  is `p1-2:1.0.0-1-any.pkg.tar.zst` (red-first: A4 reproduced the real-world refusal against the
  unfixed builder, green after).
- **Rule**: every version a helper feeds to FILENAME matching must be the makepkg full version
  (`epoch:pkgver-pkgrel`), never the raw `pkgver` variable; a version fed to pacman-level
  comparisons (`-Qp`/`-Qi` answers) is already full — never strip or add an epoch there.

## 2026-10-06 — lib32 lockstep pins block every stock→-git swap on a multilib host

- **Symptom**: after the epoch fix, the run reached `expat-git` and its install refused:
  `expat-git-2.9.0… and expat-2.8.5-1.1 are in conflict. Remove expat? → removing expat breaks
  dependency 'expat=2.8.5' required by lib32-expat`. The build itself was fine.
- **Root cause** (host-state class, not a recipe defect): Arch's multilib packages pin their
  64-bit counterpart at an EXACT version (`lib32-expat: expat=2.8.5`) to keep the two in lockstep.
  A rolling -git provider cannot satisfy `=`, so the swap is unsatisfiable while the lib32
  counterpart is installed. A full-system scan showed five such pins against this set's core
  swap targets: `lib32-expat→expat`, `lib32-libelf→libelf` (elfutils-git's `libelf-git` output),
  `lib32-libffi→libffi`, `lib32-ncurses→ncurses`, `lib32-nettle→nettle`.
- **Fix (host)**: rebuilt those five from Arch's own multilib PKGBUILDs with the pin relaxed to
  the bare provider name (each 32-bit lib is self-contained — the pin is a lockstep convention,
  not an ABI link), pkgrel `.1` local delta, installed in one transaction. Sources stayed
  signature-verified (upstream keys imported; never `--skippgpcheck`); only `lib32-libelf` needed
  a build tweak (`-Wno-error=null-dereference` for generated flex code under the GCC snapshot).
  The relaxed deps are satisfiable by the -git providers' versioned provides (`expat=$pkgver` etc.).
- **Rule**: on a multilib host, before swapping a library for its -git provider, check
  `pacman -Qi` exact-version pins on the stock name (`pacman -Qi | grep -E 'name=[0-9]'`);
  rebuild the pinning lib32 counterpart with an unversioned dep in the same wave as the swap.
  Strict `=` pins can never be satisfied by a rolling provider — never "fix" it by downgrading
  the provider's `provides` to lie about its version.

## 2026-10-05 — IgnorePkg closure becomes dynamic (registered at install time)

- **Symptom**: the `/etc/pacman.conf` `IgnorePkg` closure was a *static*
  contract — a hand-maintained list, linted report-only by `--audit`'s
  "IgnorePkg closure" section and by a battery gate. It cannot know what a
  future build will install, and on this host it had silently shrunk from
  254 names to 3 (restored 2026-10-03 from a system backup; the old list was
  never backed up and the external drive holding it was unmounted). Every
  recipe-contract run then reported the drift without being able to fix it.
- **Root causes**:
  1. the closure's source of truth was host state maintained by hand, so it
     drifted by construction and the lint could only report;
  2. the shared write core refused a second registration of the SAME day
     whenever the dated `.bak-YYYYMMDD` pre-image already existed and
     differed — after the first dynamic write of the day that is the normal
     state, so every later registration would have failed;
  3. (design hazard found while wiring fixtures) registration sitting
     outside the builder's pacman mutex let two `-i` lanes race the conf
     read-modify-write, and it shadowed `tests/pacman-mutex-shim.sh` §6's
     pinned failure shape (a seeded `db.lck` made registration wait 300 s
     and refuse before `pacman -U` ever ran, so `builder pacman mutex timed
     out` never printed).
- **Fix**: the closure is now written DYNAMICALLY by the one install
  pipeline. `install_register_names` resolves each accepted archive's
  names (`.PKGINFO` pkgbase+pkgname → the recipe's committed `.SRCINFO` →
  evaluated `PKGBUILD`, rung-3 added because fixture stub archives are
  empty; no rung answering = refuse, never a silent skip), and
  `install_register_ignorepkg` registers them through the shared
  `register_ignorepkg_names` core into `$_IGNOREPKG_CONF` (fixture seam) or
  `/etc/pacman.conf` **before** `pacman -U`, for install AND skip rows and
  `-ia` alike. The step runs INSIDE the builder pacman mutex via the hidden
  `--install-register` seam (`run_pacman_locked` → `pacman_lock_wait_clear`
  → write): fish's `exec` takes no redirections (measured — fd 9 = "Bad
  file descriptor"), so a fish process cannot hold a flock across its own
  code and the mutex always wraps an external command. The db.lck deferral
  is bounded (`_PACMAN_LOCK_WAIT_S`, default 300, fixture seam) and never
  deletes the lock; a timeout, a mutex timeout or a registration failure
  REFUSES the install and fails the run. `--no-register-ignorepkg` skips
  the step loudly (continuation-mirrored); `--register-ignorepkg` remains
  as the one-shot offline backfill. The static half is retired: the audit
  lint `IgnorePkg closure:` render, `audit_lint_ignorepkg`, the
  `--audit-lint ignorepkg` seam case and `tests/recipe-contract.sh` §C/§E.
  The shared write core now keeps an existing dated backup as the day's
  pre-image and proceeds (a differing backup is no longer a refusal).
- **Validation**: `tests/ignorepkg-register.sh` grew to 15 cases — the
  backfill suite (a–i) plus case j (second same-day write proceeds, the
  original `.bak` stays the pre-image) and the install-pipeline sections
  N1–N5 (register-before-install ordering oracle at `pacman -U` time;
  `--no-register-ignorepkg` leaves the conf byte-identical while the
  install still runs; a `db.lck` landing at build end defers the write and
  then it lands; a never-clearing lock + `_PACMAN_LOCK_WAIT_S=1` fails the
  run with no `pacman -U`; a second install run is idempotent). Six
  mutation probes were RUN and each went red at its own named assertion
  (M-N1 registration moved after the transaction, M-N2 skip-flag check
  bypassed, M-N3 wait short-circuited, M-N4 timeout `return 1`→`0`, M-j
  backup refusal re-added, M-idem always-write), then reversed.
  `tests/pacman-mutex-shim.sh` §6 stays green unchanged (the rc-75 shape is
  preserved because the seam rides `run_pacman_locked`). Full battery:
  **54 pass / 1 fail** — only `cleanup-extensions.sh`, the documented host
  drift (a fish `rm` fast-trash wrapper calling a missing `trash-put`),
  reproduced identically at pristine HEAD. Host `/etc/pacman.conf` md5
  identical before/after the whole battery (fixtures point
  `_IGNOREPKG_CONF` at per-run temp files). 12 install fixtures were wired
  to `_IGNOREPKG_CONF` + the shared `make_install_conf` skeleton so no
  battery run can write the host conf.
- **Rules**:
  - Registration is part of the transaction's critical section: it must
    stay BEFORE `pacman -U` and INSIDE `run_pacman_locked` (the hidden
    `--install-register` seam). A name is protected before it is
    installable — never after.
  - Name resolution is fail-closed: `.PKGINFO` → `.SRCINFO` → evaluated
    `PKGBUILD`, and "unnameable" refuses the install. Silent skips are the
    bug class this feature exists to close.
  - Exactly one dated pre-image per conf per day (`<conf>.bak-YYYYMMDD`),
    kept as the day's original; a later write proceeds and never rewrites
    it. The battery snapshot-diffs `/etc/pacman.conf` around every full run.
  - Any fixture that drives the install path must set `_IGNOREPKG_CONF` to
    its own file (per-RUN file when a fixture stages several cases) —
    without it registration writes the host's conf.

## 2026-10-05 — Pre-dispatch gate scaling + pre-dispatch ^C abort

- **Symptom**: `sudo fish build-all.fish -g git,stable,core,app -i` spent
  tens of minutes in the pre-dispatch phase before the first lane started
  (652 records / 2710 edges), and `^C` during that phase was unresponsive —
  the run continued into dispatch as if nothing happened.
- **Root causes** (three perf layers + one signal seam):
  1. the ABI gate's loops were O(V·E) fish iterations (per-member scans of
     the whole consumer index and the whole name-edge list per visited
     package);
  2. install-path provide matching was O(sonames × provides) with one
     command-substitution stem extraction per pair — measured 24.5 s per
     install probe against 8003 provides × 33 sonames;
  3. `abi_consumer_closure`'s BFS loop head ran `count $queue`, which is
     O(1) itself but expands the WHOLE queue into argv every iteration
     (38 s of the 46 s loop self-time over 19 822 iterations, profile
     2026-10-05);
  4. the interrupt latch `_INTERRUPT_HANDLED` was consumed only in
     `run_lanes`' loop, so every pre-dispatch phase (loader, ABI gate)
     swallowed `^C` silently.
- **Fix**: keyed/memoized gate + install-ABI helpers (one installed-member
  probe per unique id across all anchor×member visits, memoized stock
  provides / installed-state probes with the cache cleared right after each
  `pacman -U` transaction); keyed provide matching via candidate buckets;
  cached queue length maintained at the two BFS appends; `abort_before_dispatch`
  checked at every pre-dispatch phase boundary (replacing the inline block
  before `run_lanes`, with `run_record_plan` registration moved ahead of the
  ABI gate so the record exists before any abort); `run_record_finalize`
  rewritten over keyed row marks.
- **Validation**: gate probe on the real 652-package workspace — layer 1
  0.88 s / 44 member checks; layer 2 **562 s → 51.3 s** (31 changed
  providers, 16 877 closure iterations); pre-dispatch gate >37 min
  (non-completing) → **≈52 s**. Worst single cold closure 24.7 s → 2.6 s
  (glib2-git, 649 members) / 1.3 s (mesa-git). Install provide matching
  24.5 s → 0.39 s per probe. Synthetic 650-record run (instant stubs):
  pre-dispatch 29 s, 634 stub dispatches in 5.9 min on 2 lanes, rc 0.
  Fixtures: `tests/signal-abort-lock.sh` phase 17 (deterministic SIGINT via
  the gate's `pacman -Q` stub probe — rc 130, `never-started …
  interrupted-before-start` rows, no dispatch, no second-signal escalation);
  `tests/abi-batch-policy.sh` section H (240-member shared pool: exactly
  240 `-Q` probes across 960 anchor×member visits, 0 probes on the complete
  batch, one `-Qi` across 3 same-stock drift flavors — probe COUNTS as the
  scale pin; mutation-probed: an inverted bound fails the fixture).
  `tests/run-record.sh` scenario 5 was re-anchored from `sleep 1.5` to a
  makepkg-started marker: an interrupt that lands BEFORE dispatch is the
  other correct outcome (pinned by signal-abort-lock), and wall-clock timing
  flaked into it under battery parallelism. Full battery green except two
  failures reproduced identically at pristine HEAD (host drift, not repo:
  a fish autoloaded `rm` wrapper whose `trash-put` branch is not installed
  breaks the builder's `rm` calls; the host `/etc/pacman.conf` `IgnorePkg`
  closure had shrunk to 3 names, tripping the recipe-contract lint's
  report-only section E).
- **Rules**:
  - Fixture stub argv shapes ARE the contract: a raw probe may only be
    routed through a helper if the forked argv is char-for-char identical
    (adding `--` to `pacman -Q` silently disabled the refusal path, and
    only section-B-style refusal scenarios could catch it).
  - `count $list` in a hot loop head is O(list) via argv expansion — cache
    the length and maintain it at the append sites.
  - Fixture scale pins are probe/CALL COUNTS, never wall-clock; any fixture
    step that must happen after a phase starts waits on an event (marker
    file, log line), never on a sleep.
  - Pre-dispatch phase boundaries must honour the interrupt latch
    (`abort_before_dispatch`), and the ABI gate + install-ABI helpers must
    stay keyed/memoized — the per-name probe argv shapes are pinned by
    fixtures.

## 2026-10-05 — Design C: two leaf clusters move out of build-all.fish

- **Symptom/design**: `build-all.fish` reached 12 423 lines / 220 functions with
  no subsystem seam. The module survey's **Design C** (minimal cut, the
  recommended first move) extracts only leaf clusters — code that reads
  topology globals but writes no scheduler/run-record state.
- **What moved** (verbatim, 60 functions; line-multiset conservation checked):
  `lib/sources.fish` (52) — PKGBUILD/.SRCINFO parsing including the shared
  parses (`srcinfo_rows`, `pkgbuild_scan_rows`), version sync, VCS freshness,
  checksum anchoring; `lib/audit.fish` (10) — recipe-contract lints,
  `pacman_conf_ignorepkg_walk`, `register_ignorepkg`, `audit_workspace`, the
  two ABI audit lints. The entry sources both from `$SCRIPT_DIR/lib/` (fail-loud
  guard) before `load_project_config` and the hidden seam blocks. Left behind
  by decision: `report_pkgbuild_eval_failures`, `srcinfo_pkgnames`/
  `output_names`/`provides`, the built-archive discovery family and
  `freshness_skip_decision` — shared with the scheduler core, not clean leaves.
  Fixture migration: `tests/lib/fixture-lib.bash`'s `make_workspace` copies the
  modules beside the entry; `tests/log-ownership.sh`'s static source sweep reads
  `build-all.fish` **and** `lib/audit.fish` (its pinned section moved with
  `audit_workspace` — pointer migration only, assertion text untouched).
- **Validation**: `fish -n` ×3; a 91-channel seam capture (`--topology`,
  `--audit-lint` ×6 + usage shapes, `--install-decide` checked/force,
  `--lane-job` incl. result-line codec, lock/db/register seams, run-record
  blocks, `--list`) byte-identical before/after except two fields proven
  nondeterministic against a pre-edit noise floor (lane `dur`, lock-holder
  pid/timestamp); targeted fixtures 12/12; full battery 55/55 (baseline and
  after); `--list`/`--audit`/three dry-runs rc 0.
- **Rule**: the builder's module boundary is the named function set — fish has
  no visibility control, so `lib/sources.fish`'s out-param globals
  (`_VCS_REVISION_ERROR`, `_VCS_SKIP_TOLERANCE`, `_FRESHNESS_WAIVER{,_REASON}`,
  `_DEFER_REASON`, `_VERSION_SYNC_TMP_ERROR`, `_SR_ROWS`/`_PB_ROWS`) are its
  documented interface and `lib/audit.fish` writes none. Fixture synthesis must
  copy `lib/` modules beside the entry. Future extractions: leaf clusters only,
  verbatim moves, and a seam-capture diff (with a pre-edit noise floor) as the
  evidence.

## 2026-10-05 — keyed-var sweep erased nothing: defer flipped to build on re-read

- **Symptom**: two wave-3 gate fixtures regressed at once: `tests/skip-upstream.sh`
  ("unreachable legacy upstream (a parked recipe must not run makepkg): makepkg
  ran 1 times, expected 0") and `tests/stable-sync-checksums.sh` case 38
  (`si-db-error: the builder reported success; it was supposed to refuse`). Both
  are the defer-vs-build disposition: a recipe that must PARK on an unverifiable
  upstream instead ran a normal build.
- **Root cause**: `read_topology_config`'s stale-keyed-var sweep (the keyed-index
  rewrite) used `set -n | string match -r '^_(TID|TDEPKEYS|…)_'` and passed the
  result to `set -e`. Two fish traps in one line: `string match -r` prints only
  the *matched portion* — the prefix `_TID_`, never the full name `_TID_p1` — so
  `set -e` erased nothing; and regex capture groups are printed as additional
  "names" (junk `TID`, `TCONS` entries). The erase was therefore a no-op, so
  `unverifiable_defer_plan`'s topology re-read (taken whenever `_CONSUMER_INDEX`
  is empty — e.g. a one-package no-edge fixture topology) died on "duplicate
  package id in topology record" and hit its documented fallback `echo build`
  *before* any defer logic. `--list`/`--help` never re-read, so only the
  deferral seam showed it.
- **Fix**: all three name-pattern sweeps now match the whole name with
  non-capturing groups: `'^_(?:TID|TDEPKEYS|TDEP|TCONSKEYS|TCONS|TTAGS)_.*$'`
  (`read_topology_config`), `'^_(?:DS_DEPKEYS|DS_STARTED|DS_DONE|DS_DEFER|DS_CORE|DS_BAND|DS_INLIST)_.*$'`
  (`dispatch_state_refresh`), `'^_DBLOCKED_.*$'` (`_deferred_blocked_refresh`).
  The first site's comment records both traps.
- **Validation**: `fish -n`; erase semantics proved in isolation (before: `_TID_p1`
  survived; after: all three test keys erased); both fixtures green standalone;
  full battery re-run as the wave-3 gate.
- **Rule**: a keyed-variable sweep built from `set -n` + `string match -r` must
  use a full-name pattern (`^PREFIX_.*$`) and a non-capturing alternation
  `(?:…)` — anything less erases nothing and can inject junk names into `set -e`.
  Also: lane children redirect stderr into `state/logs/<pkg>.log`, so temporary
  trace echoes must go to a fixed scratch file — their absence from
  `FIXTURE_OUTPUT` proves nothing about whether the code ran.

## 2026-10-05 — --audit batched: 109 s → 20.6 s (shared parses, one pacman dump)

- **Symptom**: `--audit` took ~109 s (abi-exposure alone ~81 s) at 652 recipes:
  sed/grep forks per recipe per lint (~8–10 k forks), one `pacman -Qi` fork per
  pkgname (~649), 1 225 drift rows marshaling 10 k+ element lists per
  `string match`, O(n²) `set -a findings`.
- **Root cause**: every lint re-parsed every recipe and every lookup re-read the
  whole installed DB; plus a fish quoting bug silently defeated an earlier batch
  attempt (`(cmd)` is NOT expanded inside double quotes in fish 4.9.3 — the
  batch passed literal text and the per-name forks stayed).
- **Fix**: shared tagged parses (`srcinfo_rows`, `pkgbuild_scan_rows`) feed all
  lints; the exposure lint computes one pacman dump → awk row stream → fish
  predicates as row data → one join → `sort -u`; `abi_name_edges` walks shared
  rows fork-free; PGO scan batches `pacman -Ql`; findings accumulate file-backed.
  Name surface unified (drift D-F4/D-F5): one pkgbase+pkgname lookup
  everywhere; 8 previously-unresolvable CLI references now resolve with an
  announced substitution (e.g. `java-openjdk`→jdk-openjdk).
- **Validation**: before/after medians (3 runs) — `--audit` 109.0→20.6 s,
  abi-exposure 80.6→4.1 s; byte-identical findings for all lints (one line delta
  attributed to `python-ply` leaving the host system mid-work, not to code);
  7 lint fixtures green; M1–M4 probes falsified then reversed green.
- **Durable rule**: lint/audit I-O goes through the shared parses — never fork
  per recipe; `pacman -Qi -- a b …` prints one record per resolved target in
  target order (never deduped) so positional zips are correct; before blaming
  code for a one-line byte-diff, attribute it to `pacman.log` (the DB moved).

## 2026-10-05 — loader/selection/dispatch keyed: --list -g git 73 s → 4.4 s

- **Symptom**: `--help` 2.7 s (loader tax on EVERY invocation), `--list` 3.9 s,
  `--list -g git` 73.2 s, `--topology` 8.8 s, ~2.3 s re-validation per lane
  spawn (~25 min over a full run).
- **Root cause**: `contains`-list marshaling (~105 µs/call) in O(P²)/O(E×P)
  loader passes, per-entry command substitution in `expand_consumers` (O(C×E),
  ~2 M split-executions), O(P×E) `deps_of`/`print_topology` scans, and
  O(V²·E) readiness scans in the dispatch loop.
- **Fix**: one injective key scheme (`_topo_key`, prefix-free hex escapes)
  names fish variables as hash buckets: the loader publishes keyed
  `_TID_/_TDEP_/_TCONS_/_TTAGS_` maps (validation still runs every invocation —
  stronger than a content-hash cache), `expand_consumers` is keyed BFS,
  `deps_of`/`print_topology` are O(1) derefs, and dispatch readiness is O(1)
  markers tail-synced from append-only lane-state lists.
- **Validation**: byte-identical `--topology`/`--list`/`--list -g git`/`-n` plan
  and run-record vs the pre-task builder; orderings pinned by
  scheduler-dispatch-order/glibc-package still hold; 8 mutation probes
  falsified then reversed green. Medians: --help 2.7→1.2 s, --list 3.9→1.6 s,
  --list -g git 73.2→4.4 s, --topology 8.8→1.5 s, lane spawn 2.3→1.2 s.
- **Durable rule**: a bare `$$var` statement EXECUTES the list in fish — always
  `printf '%s\n' $list`; an incremental degree scheme needs the "no marker left
  ⇒ skip, never re-ready" guard (duplicate names pop twice); `_topo_key` is the
  only key scheme; lane-state lists feeding the dispatch refresh are
  append-only (a new list needs a matching tail-sync offset).

## 2026-10-05 — evaluation honesty: pkgbuild_array_checked everywhere, shim path quoted

- **Symptom**: the unchecked `pkgbuild_array` masked recipe-evaluation failure
  as an empty array — `record_vcs_archive_revisions` recorded "no VCS sources"
  over a recipe it never read, the freshness path could `-s`-skip an
  unevaluable recipe forever, and dead status guards sat in callers that
  believed they were checking. Separately, `ensure_pacman_shim` baked
  `$_PACMAN_MUTEX` unquoted into the build-user shim (word-split/injection
  through a user-controlled `GSA_STATE_DIR`).
- **Root cause**: `bash -c 'source "$1"; eval …'` exits 0 on source failure;
  the shim's printf template embedded the path as a bare `%s`.
- **Fix**: all 10 call sites moved to `pkgbuild_array_checked` (rc 2 = source
  failure) with honest handling per caller — manifest/manifest-verify refuse,
  sync paths name + roll back, the anchor candidate loop refuses, and
  `build_package` drops `skip_allowed` on doubt (an unevaluable recipe is
  never claimed fresh). The old function is deleted. The shim bakes the mutex
  as a shell-quoted literal.
- **Validation**: 6 fixtures green on the touched paths (skip-upstream,
  stable-sync-checksums, anchor-defer, srcinfo-freshness, pacman-mutex-shim,
  install-archive-guard); new fixture pins with falsified mutation probes —
  config-diagnostics build-defaults naming (malformed line/unknown key/
  unreadable file each named) and resume-command ambient CPU/RAM warnings.
- **Durable rule**: recipe evaluation failure is never "no sources" and never
  licenses a freshness claim; test data for a "malformed line" case must
  genuinely lack the delimiter (a line containing `key=value` text parses as
  an unknown KEY, not a malformed line).

## 2026-10-05 — lane lifecycle, run identity, signal teardown (w2-lane-lifecycle)

- **Symptom**: concurrent runs could double-dispatch over one workspace; a
  SIGKILLed dispatcher left `setsid` lanes building and installing unattended;
  a stale/foreign result file could kill a healthy lane as "lost"; interrupt
  exit was flat 130 and externally signalled lanes recorded `build-failed`.
- **Root cause**: no workspace run lock, no lane-parent liveness watchdog, per
  -index (not per-run) result slots, and a reason-less signal row grammar.
- **Fix**: a refuse-never-queue run lock (one flock holder process on fd 9);
  startup `orphan_lane_sweep` + a lane-side parent-liveness watchdog;
  run-scoped result files with `lane_result_decode` rc 2 = FOREIGN (ignored,
  never classifies or kills); signal row taxonomy (`signal-hup/int/term`) and
  exit rc 129/130/143; a clear-then-verify result gate
  (`result-clear-failed`); second signal = immediate KILL sweep; stale
  `*.tmp.*`/`.lane*.result` sweep with named operator commands.
- **Validation**: six fixtures (incl. 7× signal-abort-lock for flakes) + 12
  mutation probes red-then-restored; two root-cause fixes found by probes: the
  run-lock holder must be ONE process (a flock-parent/sh-child pair orphaned a
  poll loop past its dispatcher), and every deletion in fish-run builder code
  must be `command rm` — this host's fish `rm` is a trash function.
- **Durable rule**: one run per workspace (run lock, refuse-never-queue);
  lane results are run-scoped and foreign lines are ignored; a lock holder is
  one process so release cannot orphan it; bare `rm` in `build-all.fish`
  never deletes on this host — use `command rm`/`find -delete`.

## 2026-10-05 — Version sync made transactional (w2-version-sync)

- **Symptom**: a resumed `-s` loop reported "already built" forever at a stale
  version; `pacman -Si` failures and "not in repos" were one silent success;
  `sync_stable_version` could leave a half-rewritten tracked PKGBUILD; an
  unchecked `mktemp -d` collapsed anchor paths to the filesystem root; the
  anchor's failure path claimed "the recipe was restored" over an unchecked
  `cp`; multi-sed rewrites and a shared `.SRCINFO.tmp` let two runs destroy
  each other's work; eval snippets swallowed failure so `-ccc` claimed a clean
  scan over recipes it never read.
- **Root cause**: the skip claim ran before the version check; the query
  classifier folded every non-zero exit into "name unknown"; the rewrite path
  had no snapshot/rollback boundary and no charset gate on sed program text.
- **Fix**: version query/rewrite runs before the skip block and the claim is
  qualified (`skip_allowed`); `pacman -Si` exits separate name-unknown from
  query failure (new rc 4 → defer `upstream-unverified` or a loud as-is
  build); one shared charset gate + snapshot + staged
  `PKGBUILD.tmp.$fish_pid` + one `mv` publish + checked restore (failure =
  named error + anchor rc 5 — nothing builds over a dirty recipe);
  `version_sync_temp_dir` gates every anchor path; `refresh_package_srcinfo`
  has a 0/1/2 return contract and failures surface in log AND run summary;
  eval snippets are positional and name failures (`-ccc`/`-ln` exit non-zero).
- **Validation**: stable-sync-checksums (36 + new cases 37–44), anchor-defer
  (mktemp-fail, restore-fails), srcinfo-freshness green; 11 mutation probes
  red-then-restored.
- **Durable rule**: every tracked recipe rewrite is one staged per-process
  temp + one `mv` publish, snapshotted before the first write and rolled back
  through a CHECKED restore whose failure is its own named error. A version
  or query this run could not verify suppresses the freshness claim instead
  of making it.

## 2026-10-05 — Install pipeline integrity: plan-row grammar, discovery refusals, probe honesty (w2-installer)

- **Symptom**: plan rows were space-joined text, so an archive path with a
  space split into bogus fields and `pacman -U` got nonexistent paths; a
  recipe whose archive discovery failed silently shrank the `-ia` transaction
  to the evaluable subset and exited 0; a post-install NEEDED probe that
  could not run reported "clean"; a failed install plan could render "nothing
  to do" and exit 0; the same-version freshness compare was second-granular
  and skipped mid-second rebuilds; the empty-list refusal bypassed
  `install_emit`; a mixed skip note quoted one row's version for all.
- **Root cause**: no row codec (grammar matched the payload's spaces),
  discovery refusals were discarded instead of recorded, probe failures
  collapsed into the clean return, the install wrappers dropped
  `install_plan`'s status.
- **Fix**: tab-framed `plan_row`/`plan_row_fields` codec with every producer
  and consumer converted; `_GSA_DISCOVER_REFUSALS` rows (`refuse partial-set`,
  `refuse discover-failed`) refusing the plan by name; `install_needed_probe`
  rc 0/1/2 + `probe-skipped` rows rendered as named non-fatal warnings;
  `refuse plan-failed` backstop on both entry points; `find -newermt` ns
  compare with doubt-install; unified empty-list text through `install_emit`;
  skip-note version set. `readelf` joins the install prereqs.
- **Validation**: five fixtures green; `--install-decide` rc 0/1/2 with tab
  rows incl. spaced paths; 18 mutation probes red-then-restored.
- **Durable rule**: every plan/probe row goes through the tab codec — never
  hand-built rows; a discovery omission refuses the plan by name and `-ia`
  never installs a shrunken set; a probe that cannot run emits `probe-skipped`
  and is never "clean"; freshness compares use the full mtime timespec.

## 2026-10-05 — archive currency unified: complete-set + payload + manifest-v2 binding

- **Symptom**: `-s` skipped and `-i` installed archives that were not current
  builds — a split set cut mid-packaging skipped on its surviving half and
  installed subsets silently (run-record row said `ok`); a truncated archive
  re-skipped forever; a stale-version archive satisfied currency; a VCS
  manifest recorded for one build blessed a replacement archive.
- **Root cause**: currency was "newest `*.pkg.tar.zst` ≥ PKGBUILD mtime" —
  version-blind and set-blind — with two divergent freshness copies (toolchain
  pre-check vs skip block) and a v1 manifest not bound to archive bytes.
- **Fix**: one `current_archives` oracle (expected outputs from committed
  `.SRCINFO`/evaluated `pkgname`, evaluated pkgver-pkgrel, states complete/
  none/partial), a payload probe (`pacman -Qp`, fail-closed) in the skip
  gate, manifest v2 (sha256+size identity binding; v1 forces exactly one
  rebuild), and one shared `freshness_skip_decision` for both claim sites.
  `list_split_pkgs` excludes partial sets with a named warning; `-i` refuses
  and `-ia` warns without a transaction.
- **Validation**: four new fixture sections in `tests/skip-upstream.sh` and
  `tests/install-archive-guard.sh`, each mutation-probed red-then-green
  (completeness, payload, version, identity); `tests/toolchain-drift.sh`'s
  stub gained a pacman `-Qp` stub for the new probe; full battery green.
- **Durable rule**: an archive is current only as part of the complete output
  set at the evaluated pkgver-pkgrel, payload-readable, and bound (sha256+
  size) to its VCS baseline; doubt always rebuilds or refuses — never skips,
  never installs a subset. Pitfalls: bash rejects `:'"$'\n'"'` concatenation
  (use `:'$'\n'"…"`); fish `echo "x="(string join …)` silently emits nothing
  when the join is empty.

## 2026-10-05 — pacman lock / local-db recovery: never-delete + inode holders + named mutex-timeout

- **Symptom**: the db.lck and broken local-db probes auto-deleted on a
  two-probe `pgrep -x pacman|packagekitd|pamac` heuristic — contradicting
  the invariant "a system pacman database lock is never deleted
  automatically". Failure modes: alpm clients outside the name list (`paru`),
  probe↔rm TOCTOU, and a Ctrl-C storm killing the probe children so an empty
  holder list gated `rm` on LIVE pacman state mid-transaction. The dep
  shim flocked EVERY pacman call (incl. read-only `pacman -T`) on a fixed
  300 s wait, and a mutex timeout collapsed into `build-failed` while running
  the mutating recovery probes.
- **Root cause**: idleness was inferred from process NAMES and acted on; a
  timeout was treated as a pacman failure.
- **Fix**: idleness proven by open-handle inspection of `/proc/*/fd` against
  the lock inode (alpm holds `db.lck` open for whole transactions —
  measured); killed/short/uncertain scans (incl. hidden handles) classify
  `UNKNOWN` and nothing is EVER deleted — both probes are report-only and
  print the exact operator command. The shim splits query from transaction
  (queries run unlocked); flock rc 75 is named `builder pacman mutex timed
  out`, skips all recovery probes, and lands in the run record as row reason
  `mutex-timeout`.
- **Validation**: `fish -n`; `--list` rc 0; `local-db-repair` /
  `pacman-mutex-shim` / `signal-abort-lock` green (incl. a Ctrl-C-storm probe
  case and an end-to-end mutex-timeout row); 17 mutation probes
  red-then-reverted.
- **Durable rule**: a system pacman database lock and local-db entries are
  NEVER deleted automatically; idleness must be proven by lock-inode open
  handles and an unprovable probe is unknown — the operator gets a named
  command. A builder-mutex timeout is `mutex-timeout`, never `build-failed`,
  and triggers no recovery probes. Pitfalls: GNU find global options must
  precede paths (`find -L -maxdepth … DIR` matches nothing);
  `find -samefile` holds its reference open (never scan the scanner's own fd
  dir); `printf` reuses its format when extra args remain.

## 2026-10-04 — Q8 provides mapping scope lands as soname+name; the lint extends, 59 recipes become ratcheted debt

- **Symptom**: the provides↔soname mapping's expected reach was undecided
  (Q8), so `--audit-lint provides` enforced bare-soname stems and
  consumer-constrained versioned name provides, but not the mapped stock
  names a recipe swaps or compat-maps — the Class A
  `provides=(<stock>=$pkgver)` + `conflicts=(<stock>)` shape was convention,
  not lint.
- **Root cause**: two name-surface questions were conflated — how far a
  recipe's output names map stock names (swap, VCS counterpart, compat-map),
  and which form each side of the mapping takes. User decision: scope =
  SONAME + NAME with opposite forms — bare soname stems (makepkg
  auto-versions them), versioned name provides `name=$pkgver` wherever a
  recipe maps a stock name or a workspace consumer constrains the name by
  version; capability virtuals map nothing and stay unversioned, and a
  provide of the recipe's own output name maps nothing either.
- **Fix**: `audit_lint_provides` in `build-all.fish` grew a mapping registry
  (conflicted names + each output's name + its VCS-suffix-stripped
  counterpart, pooled per recipe, with a global cross-recipe output registry
  and a carrier check so self-provides don't self-flag). The lint reports
  unversioned mapped provides. Because the rule post-dates the set,
  `tests/recipe-contract.sh` section E pins the current 59 recipes / 113
  name pairs as a one-way ratchet: recipes gated by the >5 no-mass-edit
  rule were reported, not edited; new recipes must comply; the debt list
  only ever shrinks.
- **Validation**: `fish -n build-all.fish` rc 0;
  `fish build-all.fish --audit-lint provides` rc 0, report-only,
  113 findings (113 mapped, 0 constraint, 0 soname);
  `bash tests/recipe-contract.sh` PASS, incl. a mutation probe (delete one
  pinned pair → fixture fails → restore → green).
- **Durable rule**: mapped stock names take VERSIONED name provides
  (`provides=(<name>=$pkgver)`), soname stems take BARE provides, virtuals
  stay unversioned — recorded in `docs/MEMORY.md` §4 provides discipline;
  the per-recipe debt is a queued item there, not policy.

## 2026-10-04 — deferred topology edges adjudicated: 4 land on gcc-snapshot, the mutual pair stays broken consumer-side

- **Symptom**: the 2026-10-04 topology wiring left 5 evidence-backed edges
  out of `config/topology.conf` — the systemd↔util-linux mutual coupling's
  second direction plus 4 gcc-snapshot edges — parking them on two open
  questions (Q6 portal-cycle break side, Q7 deferral count) instead of the
  graph.
- **Root cause**: the dependency data contains one genuine mutual build
  coupling — `makedepends = util-linux` (`packages/core/systemd/.SRCINFO:24`)
  against `makedepends = systemd` (`packages/stable/util-linux/.SRCINFO:24`)
  — so both directions cannot hold in an acyclic build-order graph and one
  side must yield; the 4 gcc-snapshot edges were held only by the unsettled
  deferral count, not by any cycle (they close none).
- **Fix**: Q7 settled the deferral count at **0**, so all 4 landed on
  `gcc-snapshot`'s record — `binutils`, `git-git`, `python`, `zstd-git`
  (`makedepends = binutils/git/python/zstd` at
  `packages/core/gcc-snapshot/.SRCINFO:12,13,16,17`, plus runtime
  `depends = zstd` at :53; the stock names `git`/`zstd` resolve to their
  `X→X-git` supersession records per the wiring mapping rule). Q6 settled
  the mutual pair's break on the **CONSUMER side**: of the two, `util-linux`
  is the consumer of the exchanged libraries — it declares runtime
  consumption of systemd's `libsystemd.so`/`libudev.so`
  (`packages/stable/util-linux/.SRCINFO:66-68`) where systemd declares no
  runtime consumption of util-linux's libraries — so the edge that yields is
  the consumer's claim `util-linux→systemd`; the authored `systemd→util-linux`
  edge stands, and the pair remains exactly one edge, now as a chosen break
  instead of a deferral. The only cycle the deferred edges participate in is
  this 2-cycle, so the break side was decided for it.
- **Validation**: full-graph DFS over the changed map reports no cycle (652
  records; the loader's own topological sort re-validates the same property
  on every invocation — exercised by `--list`, `--audit` and the
  git/stable/core dry-runs); `bash tests/abi-batch-policy.sh` and
  `bash tests/project.sh` stay green.
- **Durable rules**: never land an edge without recipe-metadata evidence —
  each landed edge above names its `.SRCINFO` line; a mutual build coupling
  is broken on the consumer side (Q6 decision) and the chosen break is
  recorded here beside both `.SRCINFO` citations rather than left as a
  deferral; a deferral count of 0 means no wiring-deferred edge may remain
  un-adjudicated — it either lands or is recorded here as the break.

## 2026-10-04 — Q2 lands: the hub-rule debt register becomes core dual membership

- **Symptom**: rule 21(a) ("a package with ≥2 edge-consumers carries `core`")
  was pinned against the curated 144-record edge graph; on the full
  653-record wiring graph 204 records violated it — 203 carried as the
  written-debt Q2-open register in `tests/abi-batch-policy.sh`, plus one
  documented exception (fcitx5-git).
- **Root cause**: at wiring time the ABI-libs-vs-core question (Q2) was
  deferred instead of decided, so the pin's scope was narrowed with a
  register that preserved its teeth while the policy stayed open.
- **Fix**: the 2026-10-04 Q2 decision is **promote** — every one of the 203
  registered records gained `core` dual membership beside its existing group
  (`git,core` / `stable,core` / `app,core`, matching the `stable,core`
  precedent), and the register was deleted in the same change so the
  fixture's hub pin binds bare again over the whole graph. fcitx5-git keeps
  its rule 21(a) app-cluster exception exactly as the fixture documented it
  (5 of its 6 consumers are its own `app-cluster=fcitx5` siblings; stable
  `fcitx5-configtool` is the known outlier the decision accepted);
  fcitx5-qt-git is deliberately inside the
  promotion — its consumers are not all cluster siblings
  (`fcitx5-configtool` is stable). `docs/MEMORY.md` §1 rule 21(i) and the §5
  Q2/Q6/Q7 queue rows predate this change and are reconciled in the docs
  pass.
- **Validation**: `bash tests/abi-batch-policy.sh` green with the register
  gone — the F(b) pin re-derives its hub list from the records and all 204
  former violations now either carry `core` or sit on the one named
  exception; `bash tests/project.sh` green (its size expectations are
  derived from records, never pinned counts).
- **Durable rules**: hub-rule debt is not re-accumulatable as a register — a
  new ≥2-consumer record without `core` fails the pin until it carries
  `core` or a written exception naming its reason; when a decision lands,
  the narrowing workaround dies in the same change.

## 2026-10-04 — local/remote divergence: 4 local commits rebased onto 13 remote

- **Symptom**: `main` had diverged — 4 unpushed local commits (hermes-agent-git
  packaging, build-tools group migration, the recipe/ABI-guard/perf land)
  against 13 remote commits (version-sync waves, toolchain-drift clean, PGO
  training bounds, checksum-gate defer, `--skip` freshness tolerance,
  hermes-agent-git landing) from the other machine's tree.
- **Root cause**: two work lines landed the same period without a shared
  trunk; the hermes recipe existed on both sides (remote `a99d46d` was the
  verified build of local `cc7cc87`+`181839f`'s content), and both sides
  evolved `build-all.fish`, `config/topology.conf`, docs and PGO fixtures.
- **Fix**: linear-history rebase of the 4 onto `origin/main` with per-hunk
  intent preservation. Decisions worth knowing: the remote hermes recipe
  content won (its `.SRCINFO` was the consistent one) while the local-only
  journal entries were kept; the topology wiring kept the local edge sets
  (`hermes-agent-git` consumes `git-git,nodejs,python` — the edge-free record
  predates those recipes existing, and app records uniformly carry their
  workspace closure); `pick_next_ready` carries BOTH the toolchain-remediation
  force queue and the build-tools dispatch band (the band reorders ready
  candidates only); `tests/project.sh` counts scope through the `--topology`
  data channel (the documented contract) while deriving size expectations
  from records. Four merge regressions were fixed: `tests/pgo-lib.sh` kept
  pre-migration recipe paths (the core migration moved cairo/gtk3/wayland),
  `noctalia-git`'s `pkgrel=2` rebuild trigger was lost to a bulk-land reset
  and is restored, three `.SRCINFO`s regenerated from their merged PKGBUILDs,
  and `tests/abi-drift-install.sh` case G now stamps the GCC build-identity
  state — the toolchain-drift clean legitimately deletes cached archives on a
  missing identity, which had been silently destroying the case's pre-made
  bumped-provide archive.
- **Validation**: full battery 55/55; `--list` 3.9 s / 662 rows, `--audit`
  rc 0 (PGO payload clean, 102 s), three dry-run sweeps rc 0; `.SRCINFO`
  freshness green across 652 recipes.
- **Durable rules**: a fixture that pre-places build artifacts must also
  model the toolchain state the builder trusts, or the drift clean will eat
  its setup; a version-sync pkgver bump and a pkgrel rebuild trigger can
  collide (the pin in `tests/noctalia-pgo.sh` is the arbiter); when both
  sides rename recipe paths and fixtures, the fixtures' path lists are the
  usual silent casualty.

## 2026-10-04 — builder latency regression at 653-record scale

- **Symptom**: once the roster reached 653 records / 3373 edges, `fish
  build-all.fish --list` and `--audit` went from interactive to minutes per
  invocation.
- **Root cause**: the loader re-validates the whole record map, edge graph and
  topological sort on EVERY invocation, and the fish-side list scans grow
  quadratically with roster size — harmless at 148 records, pathological at
  653. The roster grew ~4x between two measurement points and no
  scale-sensitive path was re-measured across that jump.
- **Fix**: profiled with `fish --profile`, then rewrote the hot paths —
  `topo_sort` is now an order-identical O(V+E) Kahn sort with one record
  parse and precomputed reverse adjacency (was O(V×E): millions of
  `string split`/equality scans across 653 ids × 3373 edges, run twice per
  invocation — full-graph validation plus selection); the closure lint
  batches `readelf` invocations (256-path argv-safe chunks, same regexes)
  and indexes provides by name instead of nested scans; the exposure loop
  hoists its `count` guard; the provides/purged lints take one tagged `sed`
  pass per record instead of 5+2 forks. Behaviour unchanged: no seam, flag
  or output format was touched.
- **Validation**: 3-run means before/after — `--list` 152.3 s → 3.9 s,
  `--audit` 415.6 s → 113.7 s; independent re-measurement 5.06 s / 114.9 s.
  Byte-identity proven by diffing fresh runs against pre-change baselines
  (`--list` 662 lines, `--audit` 10,937 lines, diff rc=0), plus 300
  randomized old-vs-new `topo_sort` differential cases. Fixture battery
  green apart from the two pre-existing failures unrelated to the rewrite
  (`recipe-sources.sh` untracked local assets, resolved when the recipes
  were committed; `srcinfo-freshness.sh` stale `.SRCINFO` in three
  owner-edited recipes).
- **Durable rules** (MEMORY.md §1 rule 26): measure scale-sensitive
  validation paths after any roster-size jump (per-invocation map/graph/sort
  re-validation and the O(n²) fish list scans are the known hot paths), and
  never pin wall-times in fixture expectations — topology-derived sizes are
  computed from records, and timing assertions would block the perf work.

## 2026-10-04 — IgnorePkg write half: `--register-ignorepkg`

- **Symptom**: rule 9's IgnorePkg closure had only a read-only audit —
  registering the workspace pkgname universe in `/etc/pacman.conf` stayed a
  manual edit carrying the `[options]`-vs-repo-section trap, with no
  verification that the result was complete.
- **Root cause**: the read half (`--audit-lint ignorepkg`) was gated first
  (2026-09-26); the write half was left manual until its refusal vocabulary
  existed.
- **Fix**: `fish build-all.fish --register-ignorepkg [<path>]` computes the
  universe (pkgbase + every pkgname of each committed `.SRCINFO` — never a
  PKGBUILD grep, the kernel hides its names) and appends the missing names as
  cumulative `IgnorePkg =` lines inside `[options]` only, after the last
  existing IgnorePkg line there or before the next section header. The parser
  is pacman-exact: lines accumulate, whitespace-split, only inside `[options]`;
  a repo-section line is dropped by pacman and warned about loudly here. rc 0
  = the closure is complete afterwards (nothing-to-append counts), 1 =
  refusal with nothing changed (missing/stale `.SRCINFO` named as the blocker;
  target not writable and `sudo -n` unavailable — the builder never prompts;
  or the post-check caught a write that did not land), 2 = usage. Idempotent,
  dated pre-image backups that must match byte-for-byte before a re-run
  writes over one.
- **Validation**: `tests/ignorepkg-register.sh` 9/9 including falsification —
  a missing/stale `.SRCINFO` blocks the write loudly, and a non-writable conf
  with dead sudo exits rc 1 byte-identical.
- **Durable rules** (MEMORY.md §1 rule 9): auto-register never auto-trusts —
  any unverifiable universe refuses rather than writing a partial closure;
  the post-write `comm -23` verification is part of the seam, not optional.

## 2026-10-04 — purged-tools trim discipline: libuv-git docs, man-db NLS

- **Symptom**: two recipes still routed features through purged system tools
  — libuv-git built man pages via python-sphinx, man-db translated pages via
  po4a — and neither recipe had trimmed the corresponding outputs.
- **Root cause**: the 2026-09-26 purged-tools lint blocks *reintroduction* of
  the tools, but a recipe whose feature predates the purge kept the
  feature+output pair that needs them.
- **Fix**: trimmed feature AND output together, `# trim:` annotated at each
  removal site — libuv-git: the sphinx man-page docs stage and the
  `man1/libuv.1` install path; man-db: po4a translated man pages + gettext
  NLS and the `usr/share/man/<lang>/` + locale catalog trees.
- **Validation**: `fish build-all.fish --audit-lint purged` clean over every
  committed `.SRCINFO`; each trim annotation sits next to the removal it
  explains.
- **Durable rules** (MEMORY.md §1 rule 8): when a purged tool is a recipe's
  only route to a feature, trim the feature and its output together and say
  why in the recipe — dropping only the tool leaves a build that dies looking
  for it, dropping only the output leaves the stage that produces it.

## 2026-10-04 — provides normalization: bare soname provides only

- **Symptom**: `--audit-lint provides` flagged 15 hand-versioned soname
  provides across 10 recipes (a soname capability spelled with a version),
  tracked until now as known debt in the recipe-contract ratchet.
- **Root cause**: makepkg auto-versions a bare soname provide —
  `provides=(libfoo.so)` ships as a versioned `libfoo.so=…` capability in
  `.PKGINFO` derived from the package version — so hand-spelled versions
  duplicate that derivation and drift from it.
- **Fix**: all 15 reduced to bare stems; the ratchet list emptied and became
  a strict gate. Versioned NAME provides are a different capability kind and
  stay legal and lint-prescribed: `shelly=${pkgver}` (2026-10-04) and the
  toolchain pattern `meson=${pkgver}` (rule 4).
- **Validation**: `fish build-all.fish --audit-lint provides` clean;
  `tests/provides-audit.sh` pins the bare-stem rule and
  `tests/recipe-contract.sh` keeps the emptied ratchet strict.
- **Durable rules** (MEMORY.md §1 rule 4): bare soname provides only — never
  hand-version a soname; a versioned provide is for a NAME capability whose
  consumers constrain it by version.

## 2026-10-04 — fleet-session incidents: result ordering, idle agents, unverified .SRCINFO, two /tmp wipes

- **Symptom**: a multi-agent ingestion/wiring campaign produced duplicated work
  (record rows 91–120 written twice), agents that looked finished but reported
  nothing, 28 recipe directories that shipped without a committed `.SRCINFO`
  despite their author self-reporting validation, agents dying mid-work on
  transient model-HTTP failures, and — twice — total loss of `/tmp` prep
  artifacts (once a reboot, once a PC crash).
- **Root cause**: (1) task results do not return in call order, and cap
  rejections silently hit the *last* submitted calls, so a naive dispatch loop
  re-sent work it believed had been dropped; (2) `idle` is not `done` — an
  agent can end a turn with zero output *or* with complete artifacts and an
  empty report; (3) self-reported "validation passed" was trusted without
  checking the artifact it claimed; (4) `/tmp` was treated as durable scratch
  and mirrored only "before expected reboots".
- **Fix**: the duplicated rows were reconciled by integrity re-verification and
  an edge-union RECORD merge (never a last-writer-wins overwrite); completion
  was reconciled **by artifacts only** — an agent counts as done when its
  deliverable files exist and verify, regardless of report text or arrival
  order; the 28 directories were caught by a `.SRCINFO` presence sweep and
  regenerated; HTTP-killed agents were retried only after verifying and
  resuming their partial state; after the second wipe, every artifact written
  under `/tmp` is copied to session state at write time.
- **Validation**: rows 91–120 re-verified and merged with no divergent edges;
  `.SRCINFO` sweep now reports 653/653 recipe directories covered; retried
  agents converged without redoing verified partial work. These are process
  rules, validated by re-sweep rather than by fixture.
- **Durable rules** (MEMORY.md §1 rule 22): a) **mirror every `/tmp` artifact to
  session storage at the moment it is written**, not before expected reboots —
  the first mirror saved the session records but later prep artifacts
  (source-merge and wiring plans, host-closure plan, docs draft, merge-map)
  died with the crash; b) reconcile fleet work by artifacts, never by task
  result order or `idle` status; treat cap rejections as "resend after
  artifact check", never as "lost"; c) never accept self-reported validation —
  require the artifact (committed `.SRCINFO` regenerated with
  `makepkg --printsrcinfo`) before marking a recipe done; d) retry
  HTTP-killed agents only after inspecting partial state.

## 2026-10-04 — topology wiring: 653 records, 3373 acyclic edges

- **Symptom**: the recipe tree had no machine-checked build-order topology;
  merged split recipes had unclear identity, and superseding pairs (X replaced
  by X-git) had no wiring.
- **Root cause**: topology coverage had been maintained by hand and lagged the
  recipe set; alias records looked like a cheap way to keep old names
  addressable.
- **Fix**: wired `config/topology.conf` to **653 records = 653 recipe paths**
  (option b: **no alias records** — an alias record would make the scheduler
  rebuild a merged recipe once per alias; `--package <old-output>` addressing is
  kept by pkgname/split-output lookup instead). **3373 acyclic edges** verified,
  1218 of them newly added, including the X→X-git supersession mapping; 5 edges
  deferred (systemd↔util-linux mutual coupling, plus 4 gcc-snapshot edges
  pending the deferral count). README recipe/group counts aligned to 653/707.
  The supersession mapping was generated as X→X-git edges wherever a git
  recipe replaces a stock-name recipe, so a selection of the old name still
  schedules its replacement in the right order.
- **Validation**: acyclicity checked over the full 3373-edge graph; record
  count equals recipe-directory count (653 = 653); supersession edges
  spot-checked against the Class A/B provider split. The loader's full-map
  validation was exercised over the landed file at the 653-record scale
  afterwards (see the latency entry — correctness green, performance the open
  item).
- **Durable rules** (MEMORY.md §1 rule 24): merged recipes get exactly one
  record; old split-output names stay addressable through pkgname lookup,
  never through alias records; supersession is expressed as X→X-git edges, not
  by deleting X's record.
- **Open (tracked in MEMORY.md §5)**: ABI-libs-vs-core dual membership (Q2);
  which side of the portal cycle to break (Q6); gcc-snapshot deferral count
  (Q7); provides/soname mapping scope (Q8).

## 2026-10-04 — source-merge: 32 same-upstream clusters, 8 merges executed

- **Symptom**: many recipes fetched the same upstream tree independently —
  redundant downloads and redundant builds, and some split sets drifted from
  their stock counterparts.
- **Root cause**: recipes were created one package at a time; no policy existed
  for recipes sharing one upstream release tarball.
- **Fix**: a 687-`.SRCINFO` scan found **32 same-upstream clusters**, triaged
  as MERGE=12 (→10 buildable groups), SHARED-SRCDEST=9, KEEP=11. Executed:
  **gstreamer 8→1** (25 outputs; a `gst-libav` provides-clobber fixed; 60
  sibling pins `name=$pkgver-$pkgrel` following the qemu precedent), **vlc
  19→1** (53 outputs; 25 unreferenced stock splits trimmed and annotated),
  **poppler 3→1**, **qemu dedupe** (83 outputs verified byte-identical),
  **samba** (new `libwbclient` output; `$epoch:` pins), **transmission 2**,
  **wxwidgets 2** (build-compat upheld), **gobject-introspection 3** (pin
  check passed; python-gobject tests-commit mismatch demoted that pair to
  cluster-17 SHARED-SRCDEST scope), **nfs-utils 2**,
  **libspeechd/speech-dispatcher 2** (+5 `spd_*` provides). ~34 redundant
  builds removed or rebuilt. SHARED-SRCDEST link-sources estimated at 15–30 GB
  (llvm×3, gnulib×7 with an **unpinned-HEAD caveat**, ROCm, …).
- **Validation**: merged output counts match the pre-merge split inventories
  (gstreamer 25, vlc 53, qemu 83); provides of replaced splits preserved;
  sibling pin formula re-checked against qemu.
- **Durable rules** (MEMORY.md §1 rule 24): clusters merge only into one
  buildable recipe with one record; sibling outputs pin `name=$pkgver-$pkgrel`
  (qemu precedent: a merged split set's outputs must move as one version, or
  pacman sees unsatisfiable exact pins between siblings); when a merge
  candidate's tests pin a different commit than its source, demote it to
  SHARED-SRCDEST rather than force the merge; shared unpinned HEADs are a
  documented reproducibility caveat, not free disk savings.

## 2026-10-03→04 — library ingestion, stock-swap hardening, and the 5-layer ABI-drift guard

- **Symptom**: project library recipes were incomplete against the host, and
  the stock→house swap path could silently confirm package removals and ship
  provides that drifted from the stock packages they replace.
- **Root cause**: no ingestion pipeline for providers/consumers; `pacman -U
  --noconfirm --ask 4` auto-confirms `ALPM_QUESTION_CONFLICT_PKG` (bit 1<<2),
  so conflict removals proceed without a human; provides live in `.PKGINFO`
  and only a real rebuild updates them.
- **Fix (ingestion)**: 193 provider recipes — Class B 86 (stable/paru `-G`
  seeded from the repo/aur snapshot) and Class A 107 (git/upstream-VCS, built
  from upstream) — each Class A recipe carrying versioned
  `provides=(<stock>=$pkgver)` plus `conflicts=(<stock>)` so a stock package is
  both satisfied and displaced atomically; 347 ABI-exposed consumer recipes
  derived from 464 audited targets, with 35 user-approved Tier-2 exclusions
  recorded in `config/abi-exclusions.conf` (Tier-1 ABI exposure is never
  excludable).
  Anomalies parked rather than papered over: libmypaint soname drift (its
  shipped soname no longer matches the stock provide consumers bind to);
  nspr/nss hg `pkgver` sorts below stock, so versioned provides would satisfy
  nothing until rebased; opus-git lacks the DRED/OSCE/DeepPLC feature set the
  stock build carries, so it is not a drop-in replacement; spandsp resolves to
  the FreeSWITCH fork rather than the classic library (explicit sign-off
  wanted before it becomes the house provider); and `keys/*.asc` falls in a
  gitignore gap — key material for offline verification is currently neither
  clearly tracked nor clearly ignored (negation decision pending).
- **Fix (swap hardening)**: the `--ask 4` verdict is now treated as *confirm
  removals*, never as safety: the question bit `ALPM_QUESTION_CONFLICT_PKG`
  is 1<<2 = 4, so `--ask 4` answers "yes, remove the conflicting stock
  package" automatically on every conflict. Hardening therefore moved consent
  into the plan instead of the flag: the qt6-base-git `${pkgname[1]}` fix
  (wrong output name in the swap set), zlib-ng-compat-git provides/conflicts
  (it must own the zlib provides it replaces), an `audit_lint_swap` lint over
  every swap pair, and fixtures `swap-completeness` (every stock name in a
  swap family is covered by exactly one house output) and
  `install-conflict-ask` (pins the `--ask 4` auto-confirm behaviour so a
  future pacman change cannot silently alter it). Swap-lint debt remains on
  `niri-spicy-git` and `vscodium-insiders-git`.
- **Fix (ABI-drift guard — finished and independently verified)**: five layers
  — (1) closure lint (`audit_lint_abi_closure`): refuse a selection whose
  dependency closure contains a known-broken provider/consumer pairing;
  (2) `abi_batch_dependents` batch expansion, gated at the abi-batch gate:
  pulling an ABI origin expands to its coupled dependents so the rebuild batch
  cannot be chosen piecemeal; (3) `abi_provide_refusals` — a **fatal
  install-time `.PKGINFO` provide-diff refusal inside the install plan, wired
  right behind the PGO gate and before the force branch** — the built
  artifact's provides are diffed against the expected stock provides and any
  drift aborts the transaction rather than being waived by `-fi`/`-ia`;
  (4) `install_needed_probe`: post-install NEEDED probe — every installed
  consumer's ELF NEEDED entries must resolve in the new closure; (5)
  `audit_lint_abi_exposure` exposure audit: the full consumer-exposure
  inventory is re-checked against what actually shipped. All layers resolve
  through `read_abi_exclusions`, the strict loader over
  `config/abi-exclusions.conf` (`id|reason|review-by`, 35 user-approved
  Tier-2 entries) run on every invocation, and one fixture per layer —
  `abi-closure-lint`, `abi-drift-install`, `abi-postinstall-probe`,
  `abi-exposure-audit` — plus the `abi-batch-policy` extension covering the
  batch-expansion layer.
- **Validation**: ingestion counts reconciled (193 + 347 + 35 exclusions =
  464-target audit closure); guard battery green and independently re-run —
  abi fixtures 5/5, install fixtures 4/4.
- **Durable rules** (MEMORY.md §1 rules 23 and 25): never pass `--ask 4`
  casually — it confirms conflict removals; every Class A provider declares
  versioned stock provides and stock conflicts; provides changes require a
  real rebuild (`makepkg -Rf` only repackages); install planning refuses
  provide-diff drift *before* any force branch; unlisted ABI exclusions must
  be user-approved and land in `config/abi-exclusions.conf` with a reason and
  a review-by date.

## 2026-10-04 — build-tools dispatch class and the core membership migration

- **Symptom**: the grouping audit found multi-consumer ABI hubs and compile
  toolchains sitting outside `core`; toolchain long-poles (cmake-git,
  gcc-snapshot, llvm-git, …) queued behind unrelated work; `ripgrep` and `fd`
  had no `rust-git` build-order edge despite invoking cargo/rustc (`--audit`
  flags such gaps).
- **Root cause**: no dispatch-priority class existed — the five-name roster
  had no way to say "schedule this early" — and membership had drifted from
  `core`'s stated purpose because the docs described core's role but never
  stated a membership test.
- **Fix**: added the sixth group `build-tools` (roster
  `git,stable,core,misc,app,build-tools`, `_GROUP_NAMES` in
  `build-all.fish:239`) — a dispatch-first SCHEDULING class: within a run its
  members are dispatched before all other ready packages, but the band never
  overrides build-order edges; plan/`--list`/run-record/range order stays
  topological BUILD order (the ranges contract) even though actual dispatch
  may start build-tools members earlier. `-g build-tools` does not auto-enable
  `-i` (auto-install still keys on `core`). Membership is always dual
  `core,build-tools`. Full physical + logical migration of 13 recipes into
  `core` the same day — directories `packages/{git,stable}/<id>` →
  `packages/core/<id>` for cairo-git, pango-git, polkit-git, gtk3-git,
  babl-git, libdrm-git, ninja-git, wayland-git, rust-bindgen-git, dbus,
  systemd, linux-api-headers, ccache: the 9 hubs are `core`, and
  ninja-git/wayland-git/rust-bindgen-git/ccache are `core,build-tools`;
  autofdo-git and libclc-git stay physically under `packages/git/`
  (`core,build-tools`), and openssl/hip-runtime/hsa-rocr stay `stable,core`
  under `packages/stable/`. 16 toolchain records now carry
  `core,build-tools`: cmake-git, gcc-snapshot, llvm-git, meson-git, mold-git,
  qt5-tools, qt6-tools, rocm-llvm, rust-git, spirv-llvm-translator-git,
  autofdo-git, libclc-git, ninja-git, wayland-git, rust-bindgen-git, ccache.
  The `ripgrep` and `fd` topology records gained `rust-git` build-order edges.
  `fcitx5-git` stays `app` as the documented hub-rule exception: its five
  edge-consumers are all its own `app-cluster=fcitx5` siblings
  (`config/topology.conf:102-106`).
- **Validation**: `tests/scheduler-dispatch-order.sh` proves the dispatch band
  with a red-first fixture; `tests/abi-batch-policy.sh` pins the
  grouping-policy cases — its hub pin caught `libdrm-git` (2 consumers) having
  been dropped from the migration list mid-plan, and the fixture's refusal to
  pass is what forced the correction; the full battery `bash tests/run-all.sh`;
  `fish build-all.fish --audit` and `fish build-all.fish --list`; dry-run
  sweeps over the migrated recipes.
- **Durable rules** (now `MEMORY.md` §1 rule 21): (a) a package consumed by
  multiple packages (≥2 build-order consumers) is an ABI-coupled hub and
  carries `core` — exception: `app-cluster` members like `fcitx5-git` whose
  consumers are all cluster siblings; (b) compile toolchains carry
  `core,build-tools`; (c) `build-tools` is dispatch priority only — the band
  never overrides build-order edges, membership is always dual
  `core,build-tools`, and group moves never touch `abi=`/`app-cluster=` tags
  (qt5ct/qt6ct precedent: keep `abi=must` while leaving `core`); (d) a recipe
  invoking cargo/rustc must declare a `rust-git` build-order edge.

## 2026-10-03 — openshadinglanguage 1.15.7.0: version-sync bump left osl-llvm-compat.patch version-stale

Symptom: `prepare()` failed `Hunk #1 FAILED at 58.` on a clean extract of the
1.15.7.0 tarball; on a stale half-patched `src/` the same failure misreported as
`Reversed (or previously applied) patch detected!  8 out of 8 hunks ignored`.
After the patch was rebased, the first live build then failed one step later in
`build()`: `llvm_util.cpp: error: 'class llvm::ilist_iterator_w_bits<...>' has
no member named 'isSet'` in `op_alloca`.

Root cause: the tree's version sync bumped the recipe 1.15.3.0 → 1.15.7.0 while
`osl-llvm-compat.patch` was still written against 1.15.3.0 sources. Measured
against a clean 1.15.7.0 extract, the patch mixed three fates: hunks upstream
had absorbed (the `< 220` UnsafeFPMath / `< 230` NoInfs-NoNaNs-NoSignedZeros
guards, and the UnifyFunctionExitNodes include removal — 1.15.7.0 no longer
references that header at all), hunks still load-bearing (VERSION_MAX
23.9 → 24.9, and the LLVM-24 TargetOptions removals AllowFPOpFusion/FPOpFusion,
NoTrappingFPMath, HonorSignDependentRoundingFPMathOption, FloatABIType — all
four confirmed absent from the installed llvm-git 24 headers), and stale
context. Two further LLVM-24 API changes surfaced only at compile time:
`llvm::PassInfoMixin` moved to `llvm::detail` (the pass must derive from
`llvm::OptionalPassInfoMixin`, verified by negative compile), and
`IRBuilderBase::InsertPoint` became `using InsertPoint = BasicBlock::iterator`
(IRBuilder.h:245), losing `isSet()`.

Fix: refreshed the patch against a clean 1.15.7.0 extract — dropped the
absorbed hunks, rebased the load-bearing ones, kept the new-PM plumbing hunks
(`OptionalPassInfoMixin` + `llvm::`-qualified `createModuleToFunctionPassAdaptor`
calls), and relocated `op_alloca`'s insertion-point assertion to save time
(`OSL_ASSERT(m_builder->GetInsertBlock())` before `saveIP()`) so it stays
expressible on every LLVM version. sha512sums[1] updated with the new patch
bytes and `.SRCINFO` regenerated in the same change.

Validation: `makepkg -o` from a clean extract (both sha512 entries "Passed",
all 3 files patch with zero failed/skipped hunks, "Sources are ready"); the
patched tree compared byte-identical to the intended result; `ninja` resume of
the launcher's failed lane tree compiles and links the build() surface;
`tests/stable-sync-checksums.sh` PASS; fixture battery green except the three
known campaign-contention failures.

Rules: (1) a version-sync bump of a recipe carrying patches must re-verify the
patch against the new source from a **clean** extract — `command rm -rf src
pkg` first, because a stale half-patched `src/` turns a failed application into
the misleading "Reversed (or previously applied)" message; decide hunk fate
from the new source, not from which patch lines survive. (2) prepare() passing
is not build() passing: an LLVM-snapshot bump can break compile-time APIs
(`isSet()`, `PassInfoMixin`) that only a compile exercises.

## 2026-10-03 — install-pipeline docs pass: verify a status claim against artifacts first

Symptom — a session briefing reported the `--install` decision-pipeline work
as "54/54 tests green, pending docs", naming `tests/install-refusals.sh`,
`tests/pgo-input.sh`, `install_pending_refuses` and a `pgo_min_samples`
config knob. None of those names exist in this tree, in any commit (pickaxe
across all refs), in any session store, or anywhere on the filesystem, and
the briefing's score card mixed in another project's test areas. A session
working in the same checkout committed `9c3eeae` mid-investigation, so the
tree moved while it was being measured.

Root cause — a status report was taken at face value before checking it
against artifacts; the named work product either lived in a different
workspace or was never real here. Writing the briefed docs verbatim would
have documented behaviour that does not exist.

Fix — documented only what the code verifiably does: the one-plan/one-
executor split (`install_plan`/`install_execute`), the fail-closed rows
(`refuse empty-list` checked / `noop empty-list` force, `refuse pgo-*` from
`pgo_payload_refusals`), and the hidden `--install-decide <checked|force>`
seam — in MEMORY §1 rule 20, build-guide (Installation modes), architecture
(install path), maintainer-guide (changing install behaviour), README and
CONTRIBUTING (Validation).

Validation — seam exit codes measured live (force-empty `noop` → 0,
checked-empty `refuse` → 1, bad/missing mode → 2); claims match
`build-all.fish` (`install_plan` rows + the `--install-decide` dispatch);
`bash tests/run-all.sh` → PASS (47 fixture(s)) after the edits.

Durable rule — a claimed test score or "done" status is not evidence;
measure the artifact (files, `git log -S`, seam output) before acting on it,
and never document behaviour the tree does not have.

## 2026-10-03 — glibc-git vs mold: map parse and `-r` symbol versions

- **Symptom**: `glibc-git` `build()` died at `elf/rtld-libc.a` with
  `rtld-Rules:40: *** This makefile is a subroutine of elf/Makefile not to be
  used directly. Stop.` (`.state/logs/glibc-git.log`, make rc=1); the
  generated `elf/librtld.mk` was the single line `rtld-subdirs =`. With that
  seam fixed, a second failure surfaced at the `libc.so` link: `multiple
  definition of 'forkpty' … libc_pic.os.clean … first defined here`, both
  definitions at the same file offset — and mold aborted on the same input
  with a Rust panic (`input_files.rs: unwrap on None`).
- **Root cause** (two mold incompatibilities in glibc's internal
  *composition* links):
  1. the `$(objpfx)librtld.mk` rule parses the `librtld.map` link map with a
     sed whose address skip `^[0-9a-f ]*` matches GNU-ld/lld map lines only;
     mold map lines (`0x<addr> <size> <align> …(<m>.os):(<sect>)`) defeat the
     skip → 0 rows (measured; the map held 97 unique members) → empty
     `rtld-subdirs` → the opaque `rtld-Rules` stop. The same inputs
     re-linked `-fuse-ld=bfd` parse to the identical 97-member set.
  2. mold's `-r` relocatable link drops symbol versions from the output
     symtab: glibc's compat/default pairs (`forkpty@GLIBC_2.2.5` +
     `forkpty@@GLIBC_2.34`) collapse into duplicate *unversioned* rows at
     the same offset (`readelf -sW`: bfd `-r` keeps both versioned rows,
     mold `-r` emits two identical bare rows), and the corrupt intermediate
     breaks every later link. Verified separately that mold's final
     `-shared` link over a clean input *does* preserve versions through the
     version script — only the `-r` composition path is wrong.
- **Fix** (recipe-local `0001-bfd-relocatable-links-and-librtld-parse-guard.patch`,
  applied in `prepare()`): every relocatable *composition* link runs
  `-fuse-ld=bfd` (`reloc-link` in elf/Makefile — which also fixes the map
  format feeding the parse — plus `Makerules` `libc_pic.os`, `csu/Makefile`
  `link-relocatable`, and the top `Makefile` static-libc check); *artifact*
  links keep the host linker. The map rule depends on `Makefile` (a re-run
  cannot serve a map from a previous rule; the link names its inputs
  explicitly since `$^` would then grow `Makefile`), the parse asserts its
  own precondition with a named remediation, `prepare()` applies with
  `--fuzz=0` plus a verbatim spot grep, and purges generated composition
  intermediates — make never revisits an up-to-date corrupt file. Both
  `glibc-build` and `lib32-glibc-build` share `src/glibc`, so one patch
  covers both seams.
- **Validation**: fixture battery green in this run (count in REPORT.md);
  `GIT_CONFIG_COUNT=0 fish build-all.fish --no-deps glibc-git` built through
  `package()`; both build trees' `elf/librtld.mk` end in non-empty
  `rtld-subdirs = …`; the built `libc.so` dyn-syms carry both version rows
  (`forkpty@GLIBC_2.2.5`, `forkpty@@GLIBC_2.34`).
- **Rule**: a recipe parsing a tool-produced map/depfile owns the producing
  side of the seam — pin the format at the producer instead of extending a
  parse to private formats (mold's map format is undocumented). A mold `-r`
  link silently corrupts versioned symbol tables: keep `-fuse-ld=bfd` on
  relocatable composition links, never on artifact links. Upstream-source
  patches apply with `--fuzz=0` plus a verbatim grep, makefile-generated
  artifacts depend on their defining makefile (and when a prerequisite joins
  `$^`, name the inputs explicitly), and `prepare()` purges generated
  intermediates after a rule change. Never reconcile linker choice in
  `/etc/makepkg.conf` (shared system state; one line flips all 145 recipes).
- **Environment note** (not the recipe's defect): the host's fish defines an
  `rm` "fast trash" wrapper (`~/.config/fish/functions/rm.fish`), so the
  builder's toolchain-drift cleanup (`rm -rf src pkg build`) trashes instead
  of deleting; a `pkg/` dir arriving at mode 0111 then collided with 0111
  placeholders in `~/.local/share/Trash/files/` and the cleanup aborted with
  `mv: cannot move … Permission denied` / `rm: cannot trash …` before any
  build. Workaround: remove the empty `pkg/` (repo-side) before retrying;
  the missing `.state/toolchains/glibc-git` marker makes every failed-build
  retry wipe build state until one build succeeds.

## 2026-10-03 — shared-library inventory and rebuild-consumer audit

- **Question**: identify the project's current library recipes, compare them
  with installed pacman providers, and trace the consumers that would need to
  rebuild if more libraries became project recipes.
- **Method**: used `fish build-all.fish -l` as the recipe inventory, compared
  committed `.SRCINFO` `provides`/dependency fields with read-only
  `pacman -Qi`, and checked package payloads with `pacman -Qlq`. A package-name
  prefix search alone is incomplete: many libraries use names such as
  `glib2-git`, while some `lib*` packages do not ship ELF shared objects.
- **Inventory**: the live list returned 148 records and group counts of git
  42, stable 45, core 40, misc 1, app 23. The README counts were two recipes
  and two group memberships behind; they are now aligned with that listing.
  Committed soname `provides` cover 85 unique capabilities across 39 recipe
  IDs, and their package outputs were installed in the queried system.
- **Metadata gap**: `libdrm-git`, `libinput-git`, and `libime-git` each ship
  ELF `.so` files, but their `.SRCINFO` and installed package metadata provide
  only package-name aliases (`libdrm`, `libinput`, `libime`), not bare soname
  capabilities. `libclc-git` ships `libclc.bc`, not a shared object. The three
  ELF packages need review against the existing soname-provides rule in
  `MEMORY.md` §1.
- **Installed provider gaps**: project recipes directly require 53 sonames
  with installed host providers but no provider recipe in this tree (88
  package/field references). The largest consumer groups are `pipewire` (21),
  `curl` (10), `openssh` and `openvpn` (5 each), `udisks2` (4), and `dbus`,
  `dbus-broker`, and `dbus-broker-git` (3 each). Other affected consumers are
  `file`, `rsync`, `rust-git`, `util-linux`, `bash`, `ccache`, `cmake-git`,
  `glib2-git`, and `linux-tools`. The separate package capabilities `libgl`
  and `libegl` come from `libglvnd` (used by seven and one recipe IDs
  respectively); `libltdl` comes from `libtool` and is used by `imagemagick`.
  For PipeWire's external audio/codec/device libraries, the direct consumer is
  `pipewire`; its existing downstream edge brings `wireplumber` into the same
  selection.
- **Selection gap**: pacman dependencies are not the builder's consumer graph.
  Direct `.SRCINFO` soname references show 25 in-tree provider/consumer pairs
  without a topology edge. Read-only dry-runs confirmed the practical effect:
  `zstd-git` selected only itself despite `ccache`, `curl`, and `file` linking
  its soname; `libinput-git` selected only itself despite `niri-spicy-git` and
  the Qt bases depending on it; `libdrm-git` selected `libva-git` and
  `xorg-xwayland-git` but not its HSA, Mesa, or Qt 6 consumers. A new library
  recipe must therefore get an intentional edge from each relevant direct
  consumer; the builder then expands that consumer's declared downstream
  edges. Do not add every pacman dependency mechanically: the topology is
  curated, and some system-library relationships are cyclic.
- **Pitfall**: `.SRCINFO` fields are indented. A search anchored as
  `^provides` silently misses them; allow leading whitespace when auditing
  recipe metadata.
- **Disposition**: investigation and README count correction only. No recipe,
  topology, build, or install changes were made. Before wiring additional
  D-Bus consumers, resolve the already-queued choice between the duplicate
  `dbus-broker` and `dbus-broker-git` recipes.
- **Re-verification (fleet re-run, later same day)**: independent sub-agent
  passes reproduced every figure above (148 records, the three alias-only
  provides at `libdrm-git/.SRCINFO:16`, `libinput-git/.SRCINFO:21`,
  `libime-git/.SRCINFO:15`; `fish build-all.fish -n zstd-git` still expands to
  1 package) and added host-side scale: 1748 installed packages, 1139 shipping
  `/usr/lib/**/*.so*` (10 881 files), 139 built locally ("Unknown Packager"),
  and 105 project recipes verified as ELF-shipping (39 with bare-soname
  provides). New detail: `core/qt6-base-git/.SRCINFO:80` has an empty
  `provides = ` line on the split output `qt6-xcb-private-headers-git` —
  cosmetic metadata oddity, no known consumer impact. Counts of unshipped
  capabilities refined: 53 of 77 referenced sonames and ~170 `lib*` aliases
  have no in-tree provider; if package-name aliases are counted, unedged
  provider/consumer pairs balloon to 230 (the "25" figure is the soname-scope
  count).
## 2026-10-02 — one unqueryable upstream aborted a whole run (-s freshness defer)

- **Symptom**: a 147-package `-s` run built 16, failed 1, and left 131
  `never-started` — all because `libisl-git`'s upstream was momentarily
  unreachable. The `-s` skip path verifies every selected VCS ref before
  trusting an existing archive; when `git ls-remote` died at the transport
  level (TLS `unexpected eof while reading`, measured 2 failures in 3
  consecutive attempts against `repo.or.cz/isl.git` within one minute while
  `github.com` answered first try), `vcs_remote_revision` returned empty,
  `vcs_archive_is_current` returned 2 ("cannot establish"), both `-s`
  callers mapped that to `ui_error … return 1`, the lane decoded it as a
  *failed build*, and the fail-fast dispatcher stopped dispatching. Evidence:
  `.state/logs/libisl-git.log` carried the refusal line.
- **Root cause**: rc 2 conflates "cannot establish" with "bad package", and
  one shot of `git ls-remote` is not an oracle for "upstream is gone" — the
  transport failure was intermittent, not a moved ref (rc 1) and not a
  completed query (ls-remote exit 2 = clean "no such ref").
- **Fix** (all in `build-all.fish`):
  1. `git_ls_remote_quiet` wraps the three Git queries in
     `vcs_remote_revision` with a transport classifier on the exit status —
     0/2 are *answers* (never retried), anything else is a transport failure,
     retried 3 attempts with 0.5 s/1 s backoff.
  2. Both rc-2 sites in `build_package` (toolchain pre-check and main skip
     check) now `return $lane_outcome_defer` with reason
     `upstream-unverified` instead of `return 1`: the recipe is PARKED, not
     failed — nothing is skipped, built or installed, dependents wait
     (`waits-on-deferred`), dispatch continues, the run still exits non-zero
     and the package lands in the resume command. This is the same defer
     channel AUR/nvchecker/anchoring outages already use (lane rc 99).
  3. The lane-result wire gained an optional 4th field, the defer reason
     (`lane_result_encode/decode` accept legacy 3-field lines; the dispatcher
     falls back to `anchoring-refused`), so the run record says
     `upstream-unverified` instead of a false `anchoring-refused`, and the
     DEFERRED markers print the actual reason.
  The fail-closed invariant is untouched: an archive is skipped (and
  installed under `-s -i`) ONLY when every declared ref was positively
  confirmed equal to its recorded baseline. Deliberate give-up: liveness —
  an outage outlasting the ~1.5 s retry window parks that package for this
  run rather than guessing. A misclassified *persistent* transport error
  (expired credentials, proxy 403) costs only the backoff seconds because
  both classifier branches converge on defer; no branch can reach "skip".
- **Out of scope, deliberately**: the sibling seam — makepkg's own download
  failing (e.g. `curl: (35) TLS connect error` against ftp.astron.com) — still
  fails the package and stops dispatch. Classifying *those* failures means
  parsing makepkg output that also carries checksum/PGP integrity failures,
  which must never be retried or deferred into success; a wrong parse
  direction there is a security regression, while the skip path reads a
  first-party exit code. On any `-s` run with an existing archive the
  freshness query runs first, so the fix lands before makepkg is invoked.
  A first build (no archive) or a non-`-s` run never enters this check.
  Follow-up candidate: a curl retry in makepkg's `DLAGENTS`.
- **Validation**: `fish -n build-all.fish`; new sections in
  `tests/skip-upstream.sh` (flake-then-good skip, flake-then-moved rebuild,
  persistent-failure defer with dispatch continuation, held dependent, and
  the no-stale-install vector — `-s -i` with the ref moved and ls-remote
  always failing must end `p1 deferred 99 … upstream-unverified` with no
  `pacman -U` line for p1); `tests/run-record.sh`'s reason vocabulary gained
  `upstream-unverified`. Full battery green except the pre-existing
  `srcinfo-freshness.sh` failure (`packages/stable/xdg-user-dirs`: PKGBUILD
  modified in the dirty worktree, `.SRCINFO` not regenerated — predates this
  change).
- **Durable rule**: rc 2 ("cannot establish") defers, it never fails and
  never skips. Transport failures are retried; a completed "ref absent"
  answer is not. Only a positively confirmed ref==baseline may skip/install.



- **Symptom**: in a real 6-lane `-i` run, `xdg-utils` built cleanly
  (`xdg-utils-1.2.1-2-any.pkg.tar.zst`; makepkg log ended `Finished making:
  xdg-utils 1.2.1-2`) and the run then failed the package with
  `build succeeded but VCS revisions could not be recorded …: missing local
  checkout for xdg-utils.git`, which stopped dispatch (17 built, 1 failed,
  130 remaining). Measured on disk after the failure:
  `packages/stable/xdg-utils/src/xdg-utils` was a git checkout at exactly
  `356c380ad6fecc9ce6bea1f6a77986ba67402c80`, the pinned commit the build
  had just compiled.
- **Root cause**: `vcs_source_checkout` probed only `$pkg_path/<name>`,
  `$pkg_path/<name minus .git>` and — when `SRCDEST` happened to be exported
  into the *recorder's own* environment — `$SRCDEST/<name>`. Real makepkg
  keeps only the mirror in `SRCDEST` (`download_git`: `git clone --mirror`)
  and materialises the working copy that `build()`/`package()` `cd` into
  under `$srcdir` (`extract_git` clones into `$startdir/src/<name>`); `src/`
  was never a candidate. Two failure modes follow. With
  `SRCDEST=… sudo fish build-all.fish …`, sudo's env_reset strips `SRCDEST`
  before fish starts (measured UNSET), so no root matched and the recorder
  failed loudly *after* a green build — the observed incident. With `SRCDEST`
  exported (this host's fish exports `~/.makepkg.conf`'s value), the probe
  could instead find the SRCDEST mirror and record its HEAD: a download cache
  whose HEAD is the remote's default branch, not the built ref (measured:
  `~/.cache/gsa-src/xdg-utils` HEAD `03707c1f…` vs built `356c380a…`) — a
  manifest naming a revision the archive never contained. The same
  mirror-at-the-package-root conflation exists wherever `SRCDEST` defaults to
  `$startdir`; `noctalia-git` and `vencord-git` passed only because their
  package-root clones' HEADs happened to equal the built revisions.
- **Fix**: `vcs_source_checkout` now probes
  `$pkg_path/src/<name{,.git-stripped}>` first, then `$pkg_path`, then an
  exported `$SRCDEST`, first existing directory wins. `$startdir/src` is
  derived from the recipe path alone: it needs no environment and cannot
  disagree with makepkg's layout, which answers both the env_reset and the
  mirror-authority problems at once. The probe stays `-d`-only (the
  svn/hg/bzr fixture checkouts are plain directories); `source_filename`
  semantics, the signature-entry skip, and `vcs_local_revision`/
  `vcs_remote_revision` are untouched. The post-build failure remains a hard
  failure — see the rule.
- **Validation**: `tests/skip-upstream.sh` gained two sections whose fake
  makepkg materialises the checkout the way real `extract_git` does — under
  `$PWD/src/<name>`, not at the package root the old probe searched: an
  `upstream::`-override workspace asserting the manifest equals the `src/`
  revision against same-named decoys at the package root and in a hermetic
  `SRCDEST` (`$workspace/makepkg-srcdest`), both sanity-pinned at an older
  revision, plus `-s` skip parity; and a no-override `…/remote.git` workspace
  (the xdg-utils entry shape: `source_filename` keeps `.git`, makepkg strips
  it) with the same assertions. Both sections failed against the pre-fix
  builder with the incident's exact error (`missing local checkout for
  upstream`) and pass after the fix — red first, then green. The fixture's
  `SRCDEST` is now hermetic for every case, so the host source cache can
  never decide a fixture outcome. After the fix: `fish -n`, `--audit`,
  `--list`, dry-runs for `git`/`core`/`stable` all rc 0; full battery 46/46.
  `install-archive-guard.sh` and `toolchain-drift.sh` (round-1) stayed green.
  The battery started 43/46: pre-existing drift from the 2026-10-01/02 builds
  and a 20:42 pkgrel walk-back — regenerated the stale `.SRCINFO`s of
  `logseq-desktop-git`, `noctalia-git`, `vencord-git`, `bash`, and restored
  `noctalia-git`'s `pkgrel` to 3 (the committed `tests/noctalia-pgo.sh` pin
  from the 2026-09-23 PGO incident; makepkg's `pkgver()` writeback to
  `5.2.0.r5684.g30415127e` stays).
- **Rule**: the revision recorded in `*.gsa-vcs-revisions` is the HEAD of the
  working copy the build compiled — `$startdir/src/<name>` — never a
  download-root mirror; the package-root and `SRCDEST` probes are fallbacks
  for layouts that leave no `src/` copy. If no root yields a checkout, keep
  failing loudly instead of recording an "unknown": the manifest is the `-s`
  skip credential, and a placeholder would either never match a queried
  revision (permanent rebuild loop behind a parseable file) or, worse, be
  shaped to match one (an unverified skip). A recorder failure currently
  returns 1 and therefore stops dispatch; `lane_outcome_defer` (exit 99:
  park the package, keep dispatching) is the repo's existing vocabulary for
  that disposition — recorded as a follow-up, deliberately not changed here.

## 2026-10-02 — hermes-agent-git packaged CLI missed its project modules

- **Symptom**: `/usr/bin/hermes --version` failed at startup with
  `ModuleNotFoundError: No module named 'hermes_cli'`; invoking `hermes` by
  name was not a reproduction because the shell found a separate user install
  first.
- **Root cause**: `uv sync --no-install-project` kept the project packages
  only in the source checkout, while the hand-written wrapper used Python
  isolated mode to execute `cli.py` directly. The copied venv also rewrote
  shebangs to makepkg's temporary staging prefix, not the final `/usr/lib`
  runtime path.
- **Fix**: upstream's `setup.py` refuses wheel builds outside a Nix build
  (`HERMES_NIX_BUILD`), so the only supported shape is an EDITABLE install —
  confirmed against upstream's own installer output (`__editable__*.pth`).
  Build with `uv sync --editable`, expose upstream's `hermes`, `hermes-agent`,
  and `hermes-acp` console scripts, strip build-time `__pycache__` (binary,
  unrewritable), then rewrite every venv source reference (launchers, install
  metadata, the editable finder) to the runtime prefix and reject the payload
  if any build-source path remains.
- **Validation**: the exact `/usr/bin/hermes --version` failure was reproduced.
  PKGBUILD syntax, generated `.SRCINFO`, the recipe-contract/source/SRCINFO/
  nvchecker gates, live topology loading, and all focused upstream memory,
  review, and updater suites passed. The dashboard suite initially tripped its
  home-I/O guard because the inherited PATH found the separate user install;
  all 43 tests passed when rerun with a system-only PATH. The full repository
  battery had 44 passes and the known host rustc/LLVM-skew failure in
  `abi-batch-policy.sh`; that failure was not pursued, as it is unrelated to
  this recipe. Package `2026.10.02.051006.g0a374d1-1` built and installed via
  `pacman -U`; `/usr/bin/hermes --version` runs (`Install method: pacman`),
  `hermes update` refuses with the pacman remediation, and a post-install path
  scan found no build-source references. The packaged CLI's stricter YAML
  parser also surfaced a duplicate `title_generation` block in the user's live
  config (blocks merged, backup kept).
- **Rule**: a venv shipped inside a package must map source and staging paths
  to the final runtime root and verify no build-source references remain
  before producing the archive. For hermes specifically the install is
  EDITABLE (upstream refuses wheels outside Nix), so that verification must
  cover the editable finder and `.pth`; strip build-time `__pycache__` first —
  bytecode is binary and cannot be rewritten.
## 2026-10-01 — evaluated install versions and GCC LTO build-tree drift

- **Symptoms**: checked `-i` refused a freshly built archive when `pkgver`
  referenced earlier PKGBUILD variables. Separately, an incremental LTO link
  failed after a GCC snapshot change; the affected source tree contained
  objects emitted by different compiler builds.
- **Root causes**: `pkgbuild_var` scraped assignment text, so a valid shell
  expression remained literal and matched no archive. When version metadata
  was empty, `list_split_pkgs` instead selected every archive, which could
  install stale output. VCS `pkgver()` results are refreshed during makepkg,
  so the pre-build value is not the install-time version. The builder also had
  no record of which GCC build had produced each incremental tree. The
  available object evidence establishes compiler drift, but does not prove
  whether an all-old tree alone would fail under the new `lto1`.
- **Decisions and fix**:
  - Read PKGBUILD scalar metadata by sourcing it in Bash, matching the
    existing `pkgbuild_array` contract rather than implementing an incomplete
    shell parser. Archive discovery evaluates one version pair per recipe and
    only sources recipes that have an archive; `-ia` therefore still executes
    top-level code from archive-bearing PKGBUILDs and is not a sandbox.
    Evaluation failures are sent to stderr because archive discovery runs
    inside command substitution; case K pins that diagnostics do not become
    pacman archive arguments.
  - Match archives against the evaluated `pkgver-pkgrel` after makepkg's VCS
    `pkgver()` update. Remove the glob-all fallback: unknown version metadata
    makes no archive eligible (`-i` refuses an empty plan; `-ia` warns and
    no-ops). This chooses stale-output safety over installing an unversioned
    archive.
  - Record the GCC version line and recipe path per package under
    `.state/toolchains/`. A missing or changed identity uses the existing
    clean path before `-s`, removing `src/`, `pkg/`, `build/`, archives, and
    VCS revision sidecars. Record only after a successful build and revision
    recording; a failed build must clean again on retry. When `-s` has a
    current-mtime VCS archive, resolve its refs before deleting its archive
    and baseline, preserving the existing refusal for unreachable sources.
    This avoids a whole-workspace scan or bulk wipe.
    The key is GCC's reported version line rather than a binary hash; it
    detects snapshot identifiers carried in that line, not a same-line rebuild
    or a non-GCC compiler change.
- **Validation**: the shell-expression and GCC-drift fixtures were observed
  failing before their builder fixes. The VCS fixture caught the initial
  pre-clean regression and passed after the ref preflight was added. Focused
  archive, toolchain-drift, upstream-skip, mutex, and sudo-keepalive fixtures
  pass; a temporary mutation restoring glob-all discovery was killed by
  install-archive case J. Fish/Bash syntax, workspace audit/list, and dry-runs
  for `git`, `stable`, and `core` pass. The full battery reports 44 passed and
  two failures: `nvcheck-aggregator.sh` cannot traverse pre-existing ignored
  build-output directories, and `srcinfo-freshness.sh` finds ten recipes
  whose PKGBUILDs were already dirty at task start while their `.SRCINFO`
  remains stale. Neither condition was changed here. No real package build,
  package installation, or zsh cleanup was run.
- **Rule**: never derive a package archive pattern from PKGBUILD assignment
  text or install all archives when the version is unknown. A compiler
  identity belongs to each recipe's runtime state; on drift, clean that
  selected recipe before any skip decision, and do not advance the identity
  on failure. The next selected `app,stable,git,core` run can clean/rebuild
  each recipe as it reaches it; unselected groups remain untouched. Whether
  an all-old object tree fails under a newer GCC remains unproven, but the
  identity guard safely covers that possibility as well as mixed generations.

## 2026-10-01 — dbus-broker stale Meson Rust option state

- **Symptom**: rebuilding `dbus-broker-git` failed while Ninja regenerated the
  Meson build files, with `KeyError: 'Tried to access nonexistant project
  parent option b_freestanding.'` from Rust compiler option initialization.
  A clean setup of the same prepared source and recipe options succeeded.
- **Root cause**: the retained Meson CoreData lacked the Rust base option
  `b_freestanding`, which `RustCompiler.init_from_options()` reads. The recipe
  reused `$srcdir/build` across VCS source refreshes, so automatic regeneration
  encountered incomplete cached option state.
- **Fix**: `dbus-broker-git` now uses `meson setup --wipe` with the complete
  recipe option set before compiling, so setup rebuilds that cached state.
- **Validation**: `tests/dbus-broker-meson.sh` models stale option state at the
  PKGBUILD `build()` seam and its inline Meson stub emits the exact captured
  KeyError before the change; it passes after. A real no-compile Meson setup
  with `--wipe` and the prepared source/options succeeded. Recipe syntax and
  `.SRCINFO` checks passed, as did all 45 fixtures; no package build or
  installation was run.
- **Rule**: when a VCS recipe reuses a Meson build directory across source
  refreshes, wipe it before setup if cached compiler options can become stale.
  Capture the first failing log: a later regeneration retry may pass after
  state has changed.

## 2026-10-01 — legacy VCS archive baseline recovery

- **Symptom**: `-s` refused existing VCS archives created before per-archive
  revision records with `no recorded VCS baseline`, making the first resume
  after the upstream-aware skip change unusable. No actual `cairo-git` archive
  was present for a host-side probe; the synthetic fresh-archive fixture
  reproduced the exact refusal with a reachable local Git ref.
- **Root cause**: the initial fail-closed path treated absent build provenance
  the same as an unresolvable upstream ref. An archive's timestamp cannot
  identify which revision produced it, so adopting the current remote ref would
  create a false baseline.
- **Fix**: when a VCS archive has no usable revision record, `-s` first checks
  that every selected ref can be parsed and resolved. If any cannot, it refuses
  before `makepkg`; otherwise it does not skip the old archive and runs one
  normal build, recording the actual local revisions only after success.
  Future skips use that record. No current ref is attributed to the old
  archive.
- **Validation**: the new legacy-archive assertion went red first with the
  reported missing-baseline error. After the fix, `fish -n build-all.fish`,
  `bash -n tests/skip-upstream.sh`, and `bash tests/skip-upstream.sh` passed;
  the fixture covers one-time rebuild/record/re-skip, malformed-record
  recovery, and refusal before `makepkg` when the baseline is absent and the
  remote is unreachable. `bash tests/run-all.sh` passed all 44 fixtures.
- **Rule**: an archive without a trustworthy VCS revision record is not
  skippable; migrate it with one successful build after selected refs are
  resolvable. Unknown or unreachable refs still fail closed. Non-VCS mtime
  behavior and normal baseline-backed `-s -i` skips remain unchanged.

## 2026-10-01 — explicit nvchecker build-time version sync

- **Symptom**: `nvcheck.sh` could report newer versions, but a normal build
  still took its version from `pacman -Si` (or did not sync a `core` recipe at
  all). The first opted-in AUR fixture reproduced this as
  `aur-sync: the AUR pkgver was not applied to the core recipe`.
- **Root cause**: tracker files were report-only; file presence alone was not
  a safe build-time opt-in, and the builder had no section/provider identity to
  pair a resolved version with trustworthy source metadata. Rewriting
  `pkgver` without a provider check would leave the same checksum gap as the
  old stable path. The real Zen recipe also separates its topology ID
  (`zen-browser-pgo`), pkgname/config section (`zen-browser`), local
  `name::url` filename, and GitHub asset filename.
- **Fix**: added the validated `version-sync=nvchecker` topology opt-in and
  read provider/identity and one resolved section through `tools/nvcheck.sh`.
  Resolver state is disposable and outside the repository and
  `NVCHECK_STATE_DIR`. Untagged recipes keep the Arch `pacman -Si` path;
  `--no-sync` suppresses both paths. AUR `.SRCINFO` must match the configured
  pkgbase, resolved pkgver, and expanded source array before its pkgrel/epoch
  or sums are used. GitHub release digests match the configured repo, tag, and
  remote URL basename, even when makepkg stores the file under a `name::url`
  override. A provider with no checksum uses the loud fetch-only path;
  unavailable/mismatched metadata defers with the original recipe restored,
  while a published-checksum disagreement stops the run and restores it.
  GitHub pkgrel resets only on pkgver movement; AUR pkgrel/epoch come from
  matching `.SRCINFO` on a new version, and equal-version AUR metadata cannot
  lower a local pkgrel. The per-package log is opened before sync so provider
  failures survive in the log and the run-level sync summary.
- **Pitfall**: Fish rejects Bash-style heredoc syntax inside `build-all.fish`.
  Keep JSON/TOML parsing in the Bash `nvcheck.sh` CLI seams rather than
  embedding Python heredocs in the Fish scheduler.
- **Validation**: `fish -n build-all.fish`; `bash -n` for the resolver and
  focused fixtures; `bash tests/nvcheck-aggregator.sh`;
  `bash tests/stable-sync-checksums.sh` (31 scenarios); `bash tests/project.sh`,
  `bash tests/abi-batch-policy.sh`, and `bash tests/glibc-package.sh` all pass.
  Ten temporary mutation probes were killed by the intended assertions for
  checksum mismatch, AUR source matching/fetch-only/pkgrel, GitHub pkgrel,
  `--no-sync`, deferral status, and Zen section/asset-name mapping. The final
  full suite reported 44 fixtures passed; `srcinfo-freshness.sh` passed for
  147 recipes and GCC snapshot `.SRCINFO` matched `makepkg --printsrcinfo`.
  `--audit` exited 0 (report-only; it still lists existing legacy-doc,
  toolchain-edge, and hand-versioned-soname findings), and `--list` plus
  `--dry-run` for `stable`, `core`, and `git` exited 0. No live provider query,
  package build, or installation was run.
- **Rule**: only the topology tag opts in. Read the source from that exact
  tracker section; require provider metadata to describe the rewritten recipe;
  verify any published digest, and label every fetch-only refresh. Retry
  provider outages, restore on metadata races or integrity failures, and leave
  the untagged Arch path unchanged.

## 2026-10-01 — upstream-aware `-s` skip contract

- **Symptom**: the 2026-09-25 Vulkan pair showed that an mtime-only `-s` could
  skip a VCS provider archive after upstream had moved, leaving a consumer to
  build against a mismatched version.
- **Root cause**: archive and `PKGBUILD` mtimes do not identify which VCS
  revisions produced an archive, and a shared source checkout or unrelated
  repository `HEAD` is not a reliable per-archive baseline.
- **Fix**: retained the mtime gate, then added an ignored per-archive revision
  record for each VCS source and a selected-ref query before skipping. Git,
  SVN, Mercurial, and Bazaar are covered; a moved ref follows the normal
  build/install path. At initial rollout, a missing baseline and an unavailable
  remote both aborted; the legacy-archive follow-up above replaces only the
  missing/unusable-baseline path with a one-time rebuild after ref resolution.
  Remote-resolution failures still abort. `-c` and `-cc` remove revision
  records with their archives.
- **Validation**: `fish -n build-all.fish`, `bash -n tests/skip-upstream.sh`,
  and `bash tests/skip-upstream.sh` passed. The focused fixture covers an
  advanced branch, default HEAD, an unchanged and then moved annotated tag,
  missing baseline, unreachable remote, PKGBUILD-mtime staleness, skipped
  `-s -i`, SVN/Hg/Bazaar adapters, and `-c`/`-cc` metadata cleanup. A mutation
  probe disabled the upstream comparison in a temporary builder copy; the
  advanced-branch assertion failed as expected. `--audit`, `--list`, and
  dry-runs for `git`, `stable`, and `core` exited 0 (`--audit` is report-only).
  The full battery reported 43 passed and one failure:
  `stable-sync-checksums.sh`'s newly added AUR-sync case failed because the
  concurrent, uncommitted `version-sync=nvchecker` worktree changes add its
  fixture and tag selector but not the `build-all.fish` resolver/build call it
  expects.
  Running that fixture directly reproduced the same `AUR pkgver was not
  applied` failure. Follow-up after the provider integration above: the focused
  sync fixture now passes, and the complete suite reports 44/44. The interim
  failure was sequencing between the parallel workstreams; the VCS `-s`
  changes were preserved.
- **Initial rule**: compare a source's selected ref, not a shared checkout's
  unrelated `HEAD`. The original rollout required older VCS archives to be
  rebuilt without `-s`; the follow-up above supersedes that migration
  instruction. Never skip an unknown baseline or infer one from the current
  remote ref.

## 2026-10-01 — ABI severity with non-ABI topology tags

- **Symptom**: a real `-i` run with an ABI anchor and an `app-cluster`-only
  selected package printed `test: Missing argument at index 3` in both the
  ABI-dependent scan and anchor check, yet reported a successful run record.
  Dry-runs did not enter the failing gate.
- **Root cause**: `_TAGS` stores all valid tags, so
  `package_abi_severity` matched the app-cluster record and returned without
  output when it had no ABI severity. Callers compare that result with
  `must`, `should`, or `none`; the empty result made fish's `test` invocation
  incomplete.
- **Fix**: return `none` for a matched record with no ABI tag, preserving the
  shared tag index and the separate optional app-cluster lookup. Added a
  stubbed real-run regression case combining ABI, app-cluster-only, untagged,
  and mixed-tag records.
- **Validation**: section E reproduced both diagnostics before the fix and
  passes afterward. Post-fix checks passed: `fish -n build-all.fish`,
  `bash -n tests/abi-batch-policy.sh`, `bash tests/abi-batch-policy.sh`,
  `bash tests/app-group.sh`, and `bash tests/run-all.sh` (43 fixtures).
- **Rule**: helpers over a shared topology-tag field must return their complete
  contract even when a record contains only another valid tag; dry-runs do
  not substitute for exercising real scheduler gates.

## 2026-10-01 — split `glibc-git` package integration

- **Change**: added one `packages/core/glibc-git` recipe with the matched
  `glibc-git`, `lib32-glibc-git`, and `glibc-locales-git` outputs, versioned
  compatibility provides, and the approved build-order chain
  `linux-api-headers -> glibc-git -> gcc-snapshot`. Updated the static README
  counts and split-name fixture coverage.
- **Selection policy**: logical `core` membership is intentional even though
  `-g core` auto-enables immediate installation and can replace the installed
  system libc. This also installs the new libc before its consumer. The
  `gcc-snapshot` edge deliberately triggers a costly same-pass rebuild:
  GCC's split outputs require versioned `glibc>=2.40` and
  `lib32-glibc>=2.40` providers, and the chosen policy rebuilds them against
  the selected libc.
- **Pitfall found**: the first local `check()` implementation omitted Arch's
  syscall-restricted test exclusions. Added the pinned recipe's `_skip_test`
  helper and 12 exclusions; a synthetic Makefile check confirmed the helper
  removes only its target row. The locale `SUPPORTED` transform was also
  exercised on a continuation row and produced the expected `locale charset`
  output.
- **Host boundary**: after explicit authorization, added the three output
  names to `[options]` `IgnorePkg`, saved a pre-change backup, and verified
  that `pacman-conf IgnorePkg` reads them. No glibc build, test-suite run,
  package installation, or live-libc replacement was performed.
- **Validation**: recipe syntax, generated `.SRCINFO` parity, and local asset
  checksums passed; the focused package fixture and all 43 fixtures in
  `bash tests/run-all.sh` passed. `--audit`, `--list`, and dry-runs for `core`,
  `stable`, and `git` succeeded; the audit's report-only findings are
  pre-existing and unrelated. The disposable-root safety rule and source
  evidence are documented in
  [`glibc-git-research.md`](glibc-git-research.md).
- **Rule**: test libc packaging only in a disposable root; keep the native,
  multilib, and locale outputs on one source revision and exact version.

## 2026-10-01 — `glibc-git` / `lib32-glibc-git` integration research

- **Question**: how to add and optimize a rolling glibc and multilib pair
  without violating the project's recipe, ABI, or host-safety contracts.
- **Finding / pitfall**: current Arch packaging builds `glibc`,
  `lib32-glibc`, and `glibc-locales` from one pinned source revision and exact
  version. The existing GCC snapshot requires versioned `glibc` and
  `lib32-glibc` providers (`>=2.40`), so unversioned `provides` would not be a
  drop-in replacement. The topology choice for rebuilding `gcc-snapshot` with
  every glibc update is intentionally left open because it adds a heavy
  consumer build.
- **Disposition at research completion**: research only; no recipe, topology,
  or host `IgnorePkg` changes, and no build or install. The later
  implementation is recorded in the entry immediately above. The
  source-backed findings and proposed wiring are in
  [`glibc-git-research.md`](glibc-git-research.md).

## 2026-09-30 — `libldacdec` recipe (stable) + the `pipewire → libldacdec` build-order edge

- **What**: new leaf recipe `packages/stable/libldacdec` (Apache-2.0, AUR-derived,
  pinned commits `c90094b15e25` libldacdec + `e8ff0f96f26b` android libldac
  submodule): the reverse-engineered unofficial LDAC Bluetooth **decoder**
  library. Installs `libldacBT_dec.so`, `ldac/ldacBT_dec.h`, `ldacBT-dec.pc`;
  `provides=(libldacBT_dec.so)` (bare soname stem, rule 4).
- **Edge `pipewire → libldacdec`** (new topology record + pipewire edge list):
  the pipewire recipe now builds with `-D bluez5-codec-ldac-dec=enabled`, so
  libldacdec is a pipewire makedepends and a `pipewire-audio` runtime depend
  (`libldacdec libldacBT_dec.so`) — libldacdec must build first.
- **Build fix kept from the working AUR recipe**: upstream's Makefile links
  `libldacdec.so` with a dangling `-lldacdec` self-reference — GNU ld silently
  accepts the not-yet-written output file, mold fails `library not found:
  ldacdec`. `make libldacdec.so LDLIBS='-lm -lsndfile'` first (self-reference
  dropped), then `make ldacdec` against the finished library; the two-step
  order is the fix. `patchelf --set-soname libldacBT_dec.so` + rename make the
  recorded soname match the installed name.
- **Decision**: no `.nvchecker.toml` — upstream publishes no tags and the
  recipe pins commits, so there is no version stream to track (the metadata is
  optional per `docs/architecture.md`; a config with nothing to track is dead
  weight). `libldacdec` added to the host's `/etc/pacman.conf` IgnorePkg
  closure (rule 9).

## 2026-09-30 — noctalia patch snapshot refreshed to PR #4002 head `9d530d40` (timer-reset fix included)

- **Trigger**: the PR follow-ups. After our 2026-09-22 snapshot,
  **noctalia-dev/noctalia#4002** gained two commits on 2026-09-28 —
  **b95dce90** `fix(idle): don't reset waiting behaviors without locked_timeout
  on lock` and **9d530d40** `docs(idle): document locked_timeout and its scope`
  — prompted by BBaoVanC/TheSkyentist reporting that the lock re-armed *every*
  behavior and wiped in-flight countdowns (a regression from upstream #3388).
  Our `0001-idle-lock-resume-and-inhibit-tracking.patch` froze the 2026-09-22
  diff, so it carried the reset regression.
- **Change**: the snapshot is now PR head `9d530d40`'s diff **code-only** —
  the `docs/user/services/idle.mdx` hunks are excluded (deviation from the
  2026-09-22 "diff unchanged" wording: the docs are upstream's, the patch
  carries the behavioural fix).   `sha256sums` refreshed to `b4ecd6ad…4793bfa`; static `pkgver`/`pkgrel` set
  to `5.2.0.r5671.g368755604-3` (see the pkgver note below for the `-3` and
  where that pair comes from); the `prepare()` comment now
  carries the full contract (provenance, code-only rule, refresh trigger,
  pre-flight requirement, removal on merge). PR #4002 and issue #4190 are both
  still open, so the patch stays.
- **pkgver() drift fixed in passing** (separate defect the acceptance build
  exposed): upstream moved `version:` from a meson string to `files('VERSION')`,
  the recipe's `sed` matched nothing, and the archive came out
  `noctalia-git-.r5671.g368755604-1` — an empty version prefix with zero build
  errors. `pkgver()` now falls back to the `VERSION` file (verified against the
  build tree: yields `5.2.0.r5671.g368755604`). The installed package keeps the
  odd prefix until the next rebuild. Related mechanism worth knowing: when
  `pkgver()` moves the version, **makepkg itself** rewrites the static
  `pkgver=` line and resets `pkgrel=1` in a VCS PKGBUILD (lane log
  `==> Updated version: …`) — which is exactly how the 2026-09-23 PGO-fix
  bump got eaten during the acceptance build, and why `tests/noctalia-pgo.sh`
  asserts `pkgrel >= 2`. This change restores the bump as `pkgrel=3`.
- **Validation**:
  - `git apply -3 --check` against a fresh clone of upstream
    `main@368755604`: clean, zero offsets/fuzz — the three files' preimage
    blobs are unchanged upstream since the patch base.
  - Recipe checklist: `bash -n`, `makepkg --printsrcinfo` in sync,
    `--audit`/`--list`, dry-runs for git/stable/core (42/44/39 packages), full
    fixture battery **42/42** (`noctalia-pgo.sh` included). The audit's 18 lint
    findings are pre-existing and non-noctalia.
  - Acceptance build+install: `fish build-all.fish --no-deps -i noctalia-git`
    (11m47s, run-record ok), patch applied into the build tree, binary
    `v5.2.0-52-g368755604302-dirty`, baked `.gcda` count 0.
  - **Behavioural A/B on this host (niri)** with a test chain
    (dim 10 s → screen-off 15 s → lock 20 s, plus a `probe` at 30 s and a
    `locked-probe` with `locked_timeout = 5`): on the new binary dpms goes Off
    at dim+5.1 and **stays Off across the lock** (dim+10.1), and `dim`'s
    resume_command does **not** replay at lock — the original bug stays fixed;
    `locked-probe` fires 5.08 s after the lock-time re-arm (the `locked_timeout`
    switch works); `probe` fires at dim+20.0, i.e. its countdown **survives**
    the lock. Control: the previous binary's cycle fired `probe` at
    *lock+30.07 s* — exactly the reset regression b95dce90 fixes. Shell
    restarted the niri way; the `nri-idle` user policy was restored afterwards
    and verified live (`nri-idle status`).
- **Durable rule**: the snapshot tracks PR #4002's head as a **code-only** diff
  and is refreshed whenever #4002 gains commits; every refresh is pre-flighted
  with `git apply -3` against current `main` first (the recipe floats on
  `#branch=main`); patch + `source`/`sha256sums` entry + `prepare()` are
  deleted once #4002 merges — the `-dirty` version suffix is the reminder the
  patch is in.

## 2026-09-30 — selection expansion flipped: consumers, not the dependency chain

Symptom — a bare package selection expanded its **upstream** build-order
chain (`build-all.fish niri-spicy-git` also rebuilt llvm-git, rust-git,
mesa-git — everything niri *consumes*). Wrong risk direction: rebuilding X
cannot break what X consumes — to `dbus`, `pipewire` is only an ABI consumer,
so building X alone is harmless to its prerequisites. The ABI risk lives in
X's **consumers**.

Decision (user-confirmed) — a selection means **X + its transitive consumers**
(reverse build-order edges). Upstream expansion is removed: prerequisites are
assumed installed and current, and bootstrap/fresh builds use `-g` group runs.
`--no-deps` keeps its leaf-only meaning (the escape hatch that keeps a
consumer-bearing name leaf). Group selections and app-prompt rows expand
consumers too (uniformly — the old "app never expands" exception is gone; app
packages typically have no consumers). Blast radius on the real topology:
53 of 146 records have ≥1 consumer, closures up to 21 (`glib2-git`), while the
old upstream closures maxed at 8 — the cost profile inverted, and 64% of
records got *cheaper* (consumer-free = already leaf).

Fix — `read_topology_config` now builds a reverse-adjacency cache
(`_CONSUMER_INDEX`, the `_pkgname_index` shape); `expand_deps` became
`expand_consumers` (BFS over consumers); all selection forms funnel through
one closure before `topo_sort`. Reused unchanged: topological sort (X before
its consumers), lanes, `-i` install-before-dependents, deferral, the
`abi=must/should` gate (still the backstop refusing `--no-deps`/group runs
that omit an installed `abi=must` batch member), and the run
record/continuation (a consumer-closed selection re-expands idempotently on
resume). `-l` now heads `Selected packages in build order (N)` and the
accounting line reads `consumer expansion added N of the M selected packages`
(CONTEXT discipline: never "dependency" for build-order relations).

Validation — `fish -n` clean; real-topology dry runs: `-n niri-spicy-git` → 1
(was 3), `-n mold-git` → 1, `-n pipewire` → `pipewire, wireplumber`,
`-n glib2-git` → 22 rows (glib2-git first), `--no-deps glib2-git` → 1,
`-l -g git` → 66 (cross-group consumers included); fixture pins rewritten in
`tests/project.sh` (new `consumer-expansion` section: 2-hop chain, cross-group
pull, leaf, idempotent continuation), `tests/abi-batch-policy.sh` (B1 re-pinned
to `--no-deps llvm-git`; D now consumer-direction), `tests/app-group.sh`,
`tests/dashboard.sh`; full battery `bash tests/run-all.sh` **42/42**, `--audit`
rc 0.

Durable rule — **expand along the risk, not the recipe**: a rebuild's blast
radius is its consumers, so a selection is "X + everything at ABI risk from
X's rebuild"; what X consumes is a build-order fact (`topo_sort`, `-i`), not
something to rebuild. Recorded edges are pruned local build-order edges, so
consumer closures are a *lower* bound on real ABI risk — the `abi=` coupled
batch tags remain the expression of risk the graph cannot show (e.g.
`mesa-git` is `abi=should` with zero recorded consumers).

## 2026-09-29 — krita-git generate failure: openexr 3.5's `zstd CONFIG` dependency vs. Makefile-built zstd-git

Symptom — `krita-git` (r66780) died in `build()` at the CMake **generate**
step: dozens of `Target "kritaui" contains relative path in its
INTERFACE_INCLUDE_DIRECTORIES: "Imath_INCLUDE_DIR-NOTFOUND"`, plus
`Imported target "OpenEXR::OpenEXR" includes non-existent path`
(`.state/logs/krita-git.log` in the `~/Workspace` clone). The previous krita
attempt (09-06/09-07) had passed configure and died later on the uic issue.

Root cause — three stacked facts, each reproduced:
1. CachyOS shipped `openexr 3.5.1-1.1` on 09-26; its `OpenEXRConfig.cmake`
   now runs `find_dependency(zstd CONFIG)` unconditionally.
2. `zstd-git` builds with zstd's Makefile, whose `make install` ships no CMake
   package config (only the CMake build's `install(EXPORT)` generates one), so
   config-mode OpenEXR resolution fails: a standalone probe reported
   `OpenEXR_FOUND=0 ver=3.5.1`, `zstd_FOUND=0`, and "OpenEXR could not be
   found because dependency zstd could not be found".
3. krita's bundled `cmake/modules/FindOpenEXR.cmake` then falls into its
   manual-lookup branch, which searches for `ImfConfig.h` (OpenEXR's header
   name) where Imath ships `ImathConfig.h` → `Imath_INCLUDE_DIR` stays
   `NOTFOUND` and is spliced verbatim into the hand-created `OpenEXR::OpenEXR`
   imported target's interface includes → generate fails. A/B probe of the
   module: unpatched yields `OpenEXR_INCLUDE_DIRS=/usr/include/OpenEXR;Imath_INCLUDE_DIR-NOTFOUND`,
   patched yields `/usr/include/OpenEXR;/usr/include/Imath`.

Fix —
- `zstd-git` `package()` installs a hand-written
  `/usr/lib/cmake/zstd/zstdConfig.cmake` (+ `zstdConfigVersion.cmake`,
  SameMajorVersion) defining `zstd::libzstd_shared` (the name OpenEXR's
  exported targets link) and a `zstd::libzstd` alias; no
  `zstd::libzstd_static`, the package ships shared libs only. The Makefile
  build cannot emit upstream's `install(EXPORT)` files and a second CMake
  build just for config files would fight the PGO phases.
- `krita-git` `prepare()` rewrites `ImfConfig.h` → `ImathConfig.h` in the
  bundled FindOpenEXR.cmake (six refs, Imath block only), same
  drop-when-upstream-fixes convention as the uic `QWidget` sed above it.

Validation — rebuilt and installed `zstd-git` via
`fish build-all.fish --no-deps --forceinstall` (success, 1m33s; archive
contains both cmake files, `pacman -Ql zstd-git | grep cmake` confirms).
Probe after install: `find_package(OpenEXR NO_MODULE)` → `OpenEXR_FOUND=1
ver=3.5.1`, `zstd_FOUND=1 ver=1.5.7` (Imath/openjph/libdeflate all found).
Fallback seam proven by the A/B above. Fixtures: `bash tests/run-all.sh` 40/42
— the two `-i` install fixtures (`install-archive-guard`, `sudo-keepalive`)
failed only while an external pacman transaction held `db.lck` (the builder's
install preflight), and both re-ran PASS lock-free. **Non-claim:** krita
itself was not recompiled; the seam is verified at generate level only — the
next real `--no-deps krita-git` build is the end-to-end follow-up.

Durable rule — a Makefile-built (or otherwise config-less) provider of a
library that CMake consumers resolve via CONFIG mode must ship the CMake
package config: one consumer's `find_dependency` failure silently degrades
every downstream find-module into its fallback path. And when a CMake generate
error shows a `Foo_INCLUDE_DIR-NOTFOUND` *string* as a relative path, the
producer is a hand-rolled find-module fallback — read that module first, not
the consumer's CMakeLists.

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
- **Rule at the time**: while `-s` was mtime-only, avoid resuming a coupled
  VCS pair when a consumer may have moved upstream — rebuild provider and
  consumer together with `-i` (docs/maintainer-guide.md "Updating coupled
  stacks"). This incident-time workaround is superseded by the approved
  upstream-aware contract in the 2026-10-01 entry near the top of this
  journal. When upstream enforces a version requirement, version-pin the
  consumer's makedepends to the provider and keep both sides' epochs in step.

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

## 2026-09-30 — `build-all.fish` VCS-anchor guard fix + 1.6.9/0.5.18 re-anchors
- **Guard bug (fixed)**: `vcs_source_sum` located the checkout by `source_filename`
  (`pipewire.git`), but makepkg's `get_filename` strips a trailing `.git` from VCS URLs, so the
  clone lands in `pipewire` — the guard reported "the VCS checkout was not available to recompute
  Arch's b2 against" no matter how healthy the clone was. Candidates now try both spellings.
- **Silent-failure coupling (fixed)**: `git archive | b2sum` hashed empty stdin when git failed
  (e.g. the host's injected `safe.bareRepository=explicit` breaking bare-repo archive), yielding
  the b2 of nothing and a confident wrong-sum verdict. The archive now goes to a temp file and a
  git failure is honestly reported as "could not reproduce" (case 2).
- **Re-anchors**: version-sync had moved pipewire to 1.6.9-1 and would have moved wireplumber to
  0.5.18-1, resetting pkgrel; local deltas are re-stamped per convention as `1.1` (pipewire
  1.6.9-1.1, wireplumber 0.5.18-1.1). Sums refreshed with `updpkgsums` and verified byte-identical
  to the b2 Arch publishes for each VCS source (`git archive` of the tag): pipewire `85867001…`,
  wireplumber `eea6a3e0…`.
