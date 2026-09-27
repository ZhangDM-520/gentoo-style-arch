# zen-browser-pgo

Builds the `zen-browser` package from the upstream release source snapshot with
the optimisation the recipe's name refers to: a self-generated 3-tier PGO
profile, `--enable-optimize=-O3`, and thin + cross-language LTO configured
through `mozconfig` rather than through the environment.

The recipe does **not** set a CPU ISA. It declares `arch=('x86_64')` and
inherits `-march` from the host's `makepkg.conf`, which is what keeps it
portable to any x86_64 host; see `docs/portability.md`. The directory was
previously named `Zen-Browser-Arch-znver5-optimized`, which claimed a target
CPU the recipe never set (2026-09-19).
