# The engine owns the makepkg configuration

Compile flags had two owners. `gsa-recipe/CONTRIBUTING.md` and
`docs/portability.md` promised that the host's `makepkg.conf` was the
optimization policy and that no recipe hard-coded `-O3`/`-march`/`-mtune`;
meanwhile 33 recipes appended flags, several of them compiler-specific
(`fftw`'s `-fipa-pta` is rejected by clang, `glibc-git` rewrites `-Ofast`,
`expat-git` adds `-fuse-ld=mold`), and nobody tracked which recipe built with
which compiler. The engine could not fix that from the outside: it inherited
whatever `/etc/makepkg.conf` plus the user override said, so "the flag set" was
a property of the machine, not of the toolchain being run.

We decided the **engine owns makepkg's configuration**. `/etc/gsa/` ships
`gsa.conf` (engine keys) and one body per compiler family
(`gcc-makepkg.conf`, `clang-makepkg.conf`); `~/.config/gsa/` is the user's
clone; the built-in bodies are the floor. Every lane and every
`makepkg --verifysource` is handed `--config <build root>/lane-makepkg-<family>.conf`,
a generated composite of built-ins → site files → the engine's own paths and
job flags. `/etc/makepkg.conf`, its drop-ins and `~/.makepkg.conf` are never
read.

## Decisions

- **Per compiler, not per package.** Two families, two bodies. `FFLAGS` rides
  the gcc body and the universal body carries `RUSTFLAGS` (rustc's target and
  link arg are neither a gcc nor a clang choice), so a recipe never needs a
  flag drop-in of its own.
- **`--config`, not environment variables.** makepkg's
  `source_makepkg_config` lets a config-file assignment beat the environment,
  which is why the job-budget shim of 2026-11-01 used `--config` in the first
  place. Exporting `CFLAGS=` would be overridden by any file that sets it.
- **The composite re-asserts the engine's paths LAST.** `BUILDDIR`, `PKGDIR`,
  `PKGDEST`, `SRCDEST` and the job flags come from `GSA_LANE_*` after every
  site file, so no config can re-point the build cache (one ladder per
  setting, rule 73).
- **`gsa.conf` is not sourced.** It is the engine's strict `key = value` file;
  sourcing it would print `build_dir: command not found` into every lane log.
  Universal makepkg settings are overridden in the per-compiler body, which
  inherits the built-in universal body.
- **Missing files are legal.** The built-in bodies are compiled in, so an
  engine upgrade ahead of the `gsa-pm` recipe that ships `/etc/gsa/` still
  builds. `GSA_CONF_DIR` collapses the directory resolution to one directory
  for fixtures and hermetic runs.
- **Compiler family is a decision, then a guess.** `--toolchain` beats the
  record's `toolchain=` tag, which beats the PKGBUILD inference (explicit
  driver markers only — a `clang` makedepend is not evidence). Two families
  with no decision refuse the lane (`toolchain-ambiguous`) rather than
  configure half a build with the wrong flag set.
- **The identity folds the config bytes.** The drift marker becomes
  `<family>|<compiler version line>|<sha256 of the composite>`, closing the
  "a flag edit cleans nothing" hole rule 6 queued (measured 2026-11-01:
  ninja-git reused a pre-edit CMake cache). `gsa --build-identity gcc|clang`
  exposes the value for operators and fixtures.
- **`SRCDEST` moves with it.** The engine stopped honouring makepkg.conf, so
  the source cache became a `srcdest` gsa.conf key with a built-in default
  (`~/.gsa-src`, keeping the existing multi-GB cache in place). The
  environment rung is gone: one ladder, no ambient override.

## Consequences

- A host that tuned `/etc/makepkg.conf` must move those settings to
  `/etc/gsa/<family>-makepkg.conf`; `/etc/gsa.conf` is read as the lowest
  rung with one warning until it moves.
- The first run after the upgrade reads every existing marker as drift and
  cleans once — correct, because the flags genuinely changed.
- Recipes that append GCC-only switches can still break a clang lane. The
  engine cannot detect that; the recipe half (dropping the appends, adding
  `toolchain=clang` tags) is the next move, and `CONTRIBUTING.md`'s "no
  hard-coded flags" promise is rewritten there.
- The recipe repository's `gsa-pm` becomes the thing that ships `/etc/gsa/`;
  until it does, the built-ins are what every run uses.
