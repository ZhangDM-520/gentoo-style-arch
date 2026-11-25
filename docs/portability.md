# Portability and machine adaptation

The recipes are Arch/x86_64-oriented, but nothing assumes the author's CPU
count, memory size, home path, or Zen 5 target. Resource planning is entirely
host-derived; this file is the home of the intensity profiles, the
parallelism rules, and the CPU/ISA policy. Build and install operations live
in `docs/build-guide.md`.

## Parallelism

`gsa` derives its whole resource plan from the host on every run — CPU
threads, available memory, the GiB-per-job baselines in
`config/build-defaults.conf` (`memory_per_job_gib`, `core_memory_per_job_gib`,
`reserved_memory_gib`), and one intensity profile. `medium` is the default
unless a project, environment variable, or flag selects another level.

### Profiles

| Level | Share of CPU threads and usable memory |
| --- | ---: |
| `low` | 35% |
| `medium` (default) | 75% |
| `high` | 95% |
| `xhigh` | 110% |

`xhigh` can budget more CPU threads and memory than the host reports. The
configured reserve is subtracted before scaling memory. The configured
normal and core GiB-per-job values apply at every level.

### Formulas

`share` is the level's percentage divided by 100. CPU threads and available
memory in GiB come from host detection or the environment overrides below.

```
cpu_budget        = max(1, floor(threads * share))
memory_budget     = max(1, memory_gib - reserved_memory_gib) * share
normal_job_budget = max(1, floor(memory_budget / memory_per_job_gib))

lanes (auto)      = max(1, min(4,
                               floor(cpu_budget / 4),
                               floor(memory_budget / 4),
                               normal_job_budget, package_count))
lane_jobs (auto)  = max(1, min(floor(cpu_budget / lanes),
                               floor(normal_job_budget / lanes)))

core_jobs         = max(1, min(cpu_budget,
                               floor(memory_budget / core_memory_per_job_gib)))
```

When converting scaled memory to whole lanes or job slots, allow one
floating-point step at the integer boundary for decimal inputs.

The `parallelism:` line and format-2 `normal-jobs:` and `core-jobs:`
scalars show these baseline estimates. The lane-start event shows the
actual worker count assigned at dispatch. Dry runs show the baseline and
leave build history untouched.

### Adaptive worker assignment

The scheduler reserves one worker per ready lane in dispatch order, then
distributes the remaining workers in rounds. Each worker reserves one CPU
slot and its package's estimated memory per worker. Active lanes keep their
reservations until they finish. When the machine is idle, the first ready
package can always start with one worker. Core packages still run alone,
and the `build-tools` priority band still observes dependency order. Adaptive reservations use whole bytes, rounding
capacity down and estimates up, so a decimal baseline can yield one fewer
worker at an exact boundary.

On hosts with delegated cgroup v2 memory accounting, a successful build can record peak memory,
CPU time, elapsed time,
and assigned workers. The estimate is the highest peak bytes per assigned
worker among the five latest samples for the same recipe ID, architecture,
and toolchain family. The worker count can grow to twice the largest
recorded count. Each run uses the history it read at startup. If accounting
is unavailable, builds continue using available history and baselines. If a lane leaves processes in its accounting scope, the scheduler terminates
them and discards that sample. Accounting uses a child of the caller’s cgroup when memory accounting is available there.
A systemd unit can also use `Delegate=memory` and
`DelegateSubgroup=gsa-supervisor` with the memory controller enabled for the
unit’s children. Apply resource controls to the delegated unit so they cover
both the supervisor and the build lanes. The scheduler skips sibling
accounting when it detects a narrower limit on the supervisor subgroup.

The build user's `~/.local/state/gsa/build-history.tsv` wins per recipe key
over `/usr/share/gsa/build-history.tsv`. When neither has a sample, the
scheduler uses the configured core or normal memory baseline. Set
`GSA_BUILD_HISTORY` to an absolute file path for a separate history or to
`off` to use baselines without reading or recording samples. The suffix
`.gsa-lock` is reserved for history locks.

### Overrides

```sh
gsa -S @git --lanes 1 --jobs 4
gsa -S @git --intensity medium
GSA_LANES=2 GSA_JOBS=1 gsa -S @git
GSA_INTENSITY=low gsa -S @git
```

A flag beats its env twin (`--lanes`/`--jobs`/`--intensity` over
`GSA_LANES`/`GSA_JOBS`/`GSA_INTENSITY`); `--lanes`/`--jobs` accept `N` or
`auto`, `--intensity` a profile name. An explicit `--jobs` (or `GSA_JOBS`)
sets a maximum for normal lanes. Requests above the baseline per-lane
ceiling are clamped and announced on stderr. Actual assignments can be
lower when active reservations or package history call for it. Core packages
retain their separate budget. An explicit `--lanes` (or
`GSA_LANES`) above the selection's package count is clamped to one lane per
package and announced the same way; the automatic lane count already includes
that bound. Explicit lane counts can exceed the automatic lane limit.
`GSA_CPU_THREADS` and `GSA_MEMORY_GIB`
override resource discovery for a container or a deterministic scheduler
fixture — leave them unset on a normal host. `GSA_TARGET_CPU` is the
intentional CPU-tuning override of the next section. The numeric defaults in
`config/build-defaults.conf` are the per-job baselines for all levels: change
them in a local branch or use an explicit override; never encode one host's
RAM size in a recipe.

The engine exports `GSA_BUILD_JOBS` — the lane's job count — to each lane and
rewrites `MAKEFLAGS`/`NINJAFLAGS` (stripping `-jN`, keeping the caller's other
flags). A recipe that wants parallelism reads `GSA_BUILD_JOBS` instead of
calling `nproc` or hard-coding `-j`.

## CPU optimization

The optimization policy belongs to the **engine**, not to the host's
`makepkg.conf` (contract §B.11, amended 2026-11-10). The engine ships a
built-in per-compiler baseline in `/etc/gsa/gcc-makepkg.conf` and
`/etc/gsa/clang-makepkg.conf` (the user's `~/.config/gsa/` clone overrides
assignment by assignment), and every lane is handed it as a generated
`makepkg --config` composite. `/etc/makepkg.conf` and `~/.makepkg.conf` are
never sourced.

The compiler line is `-march=native -mtune=native`, deliberately not a pinned
target: it compiles for whatever host runs the build, so a body shipped to a
reader is not mis-tuned for their machine (on this host it resolves to
`znver5`, so today's codegen is unchanged). Besides `-O3`, the bodies carry
`-fno-plt`, `-fno-semantic-interposition`, `-falign-functions=32
-falign-loops=32`, `-mprefer-vector-width=256`, `-ffp-contract=fast`,
`-fcf-protection=none`, `-fno-math-errno`, `-fno-trapping-math`,
`-Wp,-D_FORTIFY_SOURCE=3`, and `LDFLAGS` = mold + `-Wl,-z,relro -Wl,-z,now` +
`-Wl,-z,pack-relative-relocs` + `-flto` per family (`auto` gcc, `thin` clang).
The GCC-only passes are in the gcc body alone: `-fipa-pta` (clang hard-rejects
it) and `-fprefetch-loop-arrays` (clang accepts the spelling and silently
ignores it). `-fira-hoist-pressure` and `-fstack-reuse=all` are NOT shipped —
both are gcc defaults at `-O3`. `RUSTFLAGS` (`-C opt-level=3 -C
target-cpu=native -C link-arg=-fuse-ld=mold`) is universal and `export`ed by
the composite, because makepkg exports only its own buildenv list and a recipe
that just runs `cargo` would otherwise keep a generic target — and, since
cargo never reads `LDFLAGS`, the default bfd linker as well.

A different target CPU, or any single decision reversed, is a **site edit of
that file**, not a flag on the command line; `GSA_TARGET_CPU` stays what it
always was — the recipe-selection input the Rust snapshot recipe reads instead
of pinning `znver5` in its PKGBUILD.

A recipe may still append package-specific deltas (`CFLAGS+=" -ffast-math"`),
but it no longer carries the per-compiler baseline: the switches 133 recipes
used to append (`-fipa-pta`, `-fprefetch-loop-arrays`, `-fira-hoist-pressure`,
`-fstack-reuse=all`) were stripped 2026-11-10 and live in the gcc body. Two
idioms remain, and both are in `contributing` in the recipe repository:

* a **delta** the package needs (`-ffast-math` for `fftw`, `-DNDEBUG` for
  `libjxl`) with the reason in a comment;
* a **removal** of a shipped flag, as a substitution —
  `CFLAGS=${CFLAGS/-fno-math-errno/}` (the pattern `xorg-server` already uses
  to drop `-fno-plt` and `-Wl,-z,now`) — never a re-assignment that discards
  the rest of the line.

Native optimizations in built packages are host-derived and should not be
redistributed as portable binary artifacts.

That last point separates two things that are easy to conflate:

* **A recipe is portable.** No recipe here pins one machine's ISA. Every
  native-flag injection is conditional on the environment not already setting a
  target, and says so (`niri-spicy-git`, `rust-bindgen-git`,
  `xwayland-satellite-git`); no recipe narrows `arch` below `x86_64`; and the
  kernel's `_processor_opt` is a knob with `zen4` and `generic` alternatives
  beside its `native` default. Copy those patterns rather than adding a new
  hard-coded `-march`.
* **An artifact is not.** The engine's baseline body supplies
  `-march=znver5` (or whatever the site's `/etc/gsa` body says), so a package
  built from this tree is tuned to its target and is not a redistributable
  binary. Hard-coding a target in a recipe would only move that problem from
  the build host to the reader.

The set is maintained against AMD laptop hardware (see `README.md`), and the
hardware-support trims are validated on one such model. The recipes build on
any Arch x86_64 host; it is the trims that a second, non-AMD model would be
needed to re-verify.

## Host-specific profiles

The CachyOS kernel recipe keeps its baseline `config` because it is a
required packaging input, but AutoFDO and Propeller profiles are disabled by
default. Generate matching profiles on the target host, place them in the
recipe directory, and opt in through the documented recipe variables only for
that host. Generated profiles are ignored by Git.

## Architecture limits

Some recipes are intentionally limited by upstream or package design to
`x86_64`, AMD ROCm, or a specific Arch ABI. Those constraints belong in the
recipe's `arch`, dependencies, and documentation; the scheduler should not
pretend that a non-supported architecture is portable.
