# Package policy

Each package directory (`packages/<category>/<package-id>/`) is a small recipe
module:

- `PKGBUILD` is the source of truth.
- `.SRCINFO` is committed metadata generated from that recipe.
- Local patches, hooks, install scripts, desktop files, configuration
  snippets, and other assets the build needs are committed with the recipe.
- Upstream licence material (`LICENSE`, `LICENSES/`, `REUSE.toml`) is
  preserved as shipped.
- A recipe that generates its `PKGBUILD` commits the generator pair with it
  (`PKGBUILD.in` template + `update.PKGBUILD` script) — maintenance metadata,
  kept in lockstep with `PKGBUILD` (every manual edit is mirrored into the
  template). Packaging-repository CI configs (e.g. `.travis.yml`) are not
  content and are never committed.

Fetched or generated at build time and never vendored: remote Git
repositories, release archives, downloaded signatures, key caches, source
trees, build trees, staging directories, and package archives. Build trees,
staging, and archives belong to the build user's build cache, not the recipe
directory (CONTEXT.md, "Build cache"); shared VCS mirrors are runtime state
too (`docs/source-sharing.md`).

A recipe's own `FETCHED-ONLY` file (one source-basename glob per line)
declares names that are fetched at build time and excuses them from the
local-asset checks (`tests/recipe-sources.sh`).

Keep package-local upstream attribution and licences. The root MIT license
does not relicense package recipes or bundled upstream material.

When trimming a recipe, remove the corresponding dead `makedepends`,
`depends`, split package, `_pick`, install, and check paths together. A
feature disabled in `build()` must not leave a packaging step that expects its
output. Validate with `bash -n` and `.SRCINFO` regeneration
(`makepkg --printsrcinfo --dir packages/<category>/<pkg> > packages/<category>/<pkg>/.SRCINFO`);
the full trimming standard is `CONTRIBUTING.md`'s.
