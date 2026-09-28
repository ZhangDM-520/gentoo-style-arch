# Contributing

Contributions should improve a recipe or the builder for a clean Arch
checkout. **This set is maintained for AMD laptops** — AMD CPUs with
amdgpu/radeon graphics — and the hardware-support trims follow from that
target: a recipe may drop Intel- and NVIDIA-only firmware, drivers and code
paths, and should name the platform or family it trims against, so a reader can
see what the recipe no longer covers. Non-AMD paths stay when a maintained
feature needs them. Do not submit upstream source clones, generated build
trees, package archives, downloaded signatures, local PGP key caches, or
host-specific logs and profiles.

Explain non-obvious decisions in the recipe. **A comment explains the code, the
kernel option, or the trim decision; it does not inventory the machine it was
written on.** Kernel versions, package versions installed on the author's
machine, CPU thread counts, bootloader command lines and incident narratives
belong in `docs/NOTE.md`; `docs/MEMORY.md` §5 holds a live decision.
`linux-cachyos` is the worked example (2026-09-19).

## Recipe changes

1. Work in the relevant directory under `packages/`.
2. Keep upstream attribution, package-local license files, checksums, and
   source URLs intact.
3. Put necessary local patches, hooks, install files, and desktop assets next
   to the recipe. Explain non-obvious compatibility patches in the recipe.
   **A new local asset must survive `.gitignore`.** Nine recipes default-deny
   with a bare `*` (or `/*`) plus `!` negations, so a file added without a
   matching negation is silently dropped from the commit while still building
   locally — a clean checkout then fails with "was not found in the build
   directory" (2026-09-16). Add the negation in the same change and confirm
   with `git check-ignore -v <asset>` (no output = visible). Never let a recipe
   `.gitignore` match itself: an ignore file that hides itself cannot be
   committed, so on a clean checkout the rule is simply absent.
4. Update `config/topology.conf` when adding or relocating a recipe. The
   record format is exactly `id|path|groups|edges[|tags]`; the loader rejects
   any other shape, and the record is the only place that binds an ID to a
   path.
5. Record group membership (`groups`, a comma list of the five group names)
   and any local dependency edges (`edges`) in the same record, and only after
   verifying a dependency with the package metadata and a build-order reason.
   Coupled-batch tags (`abi=must`/`abi=should`) belong in the same record's
   `tags` field — see "Updating coupled stacks" in `docs/maintainer-guide.md`.
6. Regenerate `.SRCINFO`:

   ```sh
   makepkg --printsrcinfo > .SRCINFO
   ```

### Source verification and signing keys

1. Never disable verification with `--skippgpcheck` or remove `#signed` from a
   source to work around a failure.
2. A tag can be signed by a signing **subkey**, while the upstream
   `validpgpkeys` array lists only the **primary** fingerprint. Compare
   `git verify-tag <tag>` (or `gpg --verify`) against the maintainer's
   published key:

   ```sh
   git verify-tag v42            # reports the key that made the signature
   gpg --list-keys --with-subkey-fingerprint <primary-fingerprint>
   ```

3. Confirm the reported fingerprint belongs to a UID and subkey published by
   the maintainer (for example `https://github.com/<maintainer>.gpg`), then add
   that fingerprint to `validpgpkeys` with a comment naming the role. Import
   the verified key locally so the build can check the signature.
4. If a fingerprint cannot be confirmed against a published key, stop and
   report the mismatch instead of trusting it.

## Optimization and trimming standard

Use the host's `makepkg.conf` as the default optimization policy. Do not
append hard-coded `-O3`, `-march`, `-mtune`, or other host-specific ISA flags
to a recipe. Use host-derived native settings only when they are already
provided by the build environment; an explicit target such as
`GSA_TARGET_CPU` must be intentional and documented.

Trim packaging to the maintained target:

- remove dead documentation, man pages, examples, tests, split packages,
  `depends`, `makedepends`, `_pick` paths, install paths, and check paths
  together;
- keep PGO-training test suites, kmod compressors, the GTK4 Vulkan renderer,
  Rust `profiler=true`, the `clang-opencl-headers` split, and CUPS/printing
  support when they are part of the maintained feature set;
- keep mold, LTO, and PGO phases aligned with the package's documented
  exception (the Meson reconfigure rules and the verification procedure are in
  `docs/build-guide.md`; the failure mechanisms are in `MEMORY.md` §6); a
  recipe that trains with `-fprofile-generate` must call the shared payload
  gate (`lib/pgo.sh`) as the last statement of its package function(s) —
  never copy its implementation; a new PGO family earns a fixture and extends
  the module when its leak shapes are new (the 2026-09-28 C-autotools and Go
  flavors needed no module change) — and the builder's central gate does not
  make the call optional; and
- never use invalid `options` such as `!check` or `autodeps` to paper over a
  recipe problem.

After a trim, verify that disabled features have no remaining packaging
paths, removed tools are absent from `makedepends`, and the resulting
`.SRCINFO` matches the recipe. Do not remove a test or feature merely because
it is not installed at runtime if it trains PGO or protects a maintained
capability.

## Validation

Before submitting a change, run:

```sh
fish -n build-all.fish
fish build-all.fish --audit
fish build-all.fish --list
fish build-all.fish --dry-run --group git
fish build-all.fish --dry-run --group stable
fish build-all.fish --dry-run --group core
bash -n packages/path/to/PKGBUILD
makepkg --printsrcinfo --dir packages/path/to
bash tests/run-all.sh
```

`tests/run-all.sh` runs every fixture (discovered, so new ones need no edit
here) — in parallel by default, because every fixture is non-mutating and
`$TMPDIR`-scoped; pass a substring to narrow it,
e.g. `bash tests/run-all.sh recipe`, or `--serial` to debug one at a time. The
fixtures cover the project configuration, recipe
registration and assets, source sharing, PGO transitions and the PGO install
gate, and the scheduler's resource profiles, so run the whole battery rather
than only the file matching the recipe you touched — the map-format change of
2026-09-17 was caught by two unrelated recipe fixtures.

`--audit` also reports installed files under a PGO recipe that still carry a
baked `.gcda` path, and names PGO recipes that are not installed at all, so it
is the quickest way to spot a stale install that predates a recipe fix.

Do not use a full real rebuild as a syntax check. For changes to scheduling,
installation, cleanup, source sharing, or signals, add or run a focused
fixture with fake build/install commands and verify exit status, logs, and
child-process cleanup.

## Topology and ABI coupling

Keep ABI-coupled packages in the same documented batch. LLVM consumers,
Rust, Qt private-API modules, ROCm, and the system replacement packages are
not ordinary independent leaf updates. Batch membership is declared in the
`tags` field of the package's `config/topology.conf` record
(`abi=must` / `abi=should`); the batch itself is derived from the edge graph.
Record the reason for a new edge in `docs/NOTE.md` and update the maintainer
rules in `docs/MEMORY.md` when the operational contract changes.
