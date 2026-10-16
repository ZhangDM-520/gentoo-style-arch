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
`reserved_memory_gib`), and one intensity profile. `--intensity xhigh` is the
default automatic profile; `--lanes`/`--jobs` (each `N` or `auto`) override
its values. This section is the whole parallelism story.

The old automatic output reported `-j` per lane, so `2 lanes × -j6` could
represent twelve normal job slots while each lane independently received the
same memory allowance. The profiles therefore budget normal jobs globally,
and each profile scales lanes, jobs and memory together.

### Profiles

| Profile | lane cap | CPU per lane | GiB per lane | normal-memory factor | core-memory factor |
| --- | --- | --- | --- | --- | --- |
| `low` | 1 | 16 | 16 | 2.0 | 1.5 |
| `medium` | 2 | 8 | 8 | 1.0 | 1.0 |
| `high` | 3 | 6 | 6 | 0.67 | 0.75 |
| `xhigh` (default) | 4 | 4 | 4 | 0.5 | 0.625 |
| `max` | 6 | 2 | 2 | 0.34 | 0.5 |

In words: `low` is one conservative lane with maximum headroom; `medium` is
the balanced baseline (its factors are 1.0, so the raw `build-defaults.conf`
GiB numbers are the medium-profile per-job cost); `high` adds lanes and lowers
the per-job memory estimate; `xhigh` is the aggressive default; `max` is the
highest automatic utilization with the greatest OOM risk.

### Formulas

`threads` = CPU threads, `memory_gib` = available memory in GiB — detected
unless overridden; the factors come from the profile table above:

```
normal_memory         = max(1, memory_gib - reserved_memory_gib)
normal_memory_per_job = memory_per_job_gib * normal-memory factor
normal_job_budget     = max(1, floor(normal_memory / normal_memory_per_job))

lanes (auto)     = max(1, min(lane cap,
                              max(1, floor(threads / CPU-per-lane)),
                              max(1, floor(memory_gib / GiB-per-lane)),
                              normal_job_budget, package_count))
lane_jobs (auto) = max(1, min(floor(threads / lanes),
                              floor(normal_job_budget / lanes)))

core_memory_per_job = core_memory_per_job_gib * core-memory factor
core_jobs           = max(1, min(threads,
                                 floor(normal_memory / core_memory_per_job)))
```

The same profile on a 24-thread workstation and an 8-thread laptop yields
different lane and job counts by design: the intent is to raise independent
package throughput without multiplying the memory allowance by the lane
count. Because every term is host-derived, **never predict a plan — read the
`parallelism:` line the run prints**:

```
parallelism: N CPU threads, M GiB available, intensity <profile>, K lane(s), normal -j…, core -j…
```

That line is the only truth; the run record's `lanes:`/`normal-jobs:`/
`core-jobs:` scalars carry the same resolved numbers.

### Scheduling rules the plan does not express

- **Core runs alone.** A `core` package gets the separate `core_jobs` budget
  above and runs in its own lane, never sharing dispatch with normal packages
  (contract §K.2).
- **The `build-tools` band.** Members of the `build-tools` group dispatch
  before other ready packages — a priority band only, never over a
  build-order edge (contract §K.2).

### Overrides

```sh
gsa -S @git --lanes 1 --jobs 4
gsa -S @git --intensity medium
GSA_LANES=2 GSA_JOBS=1 gsa -S @git
GSA_INTENSITY=low gsa -S @git
```

A flag beats its env twin (`--lanes`/`--jobs`/`--intensity` over
`GSA_LANES`/`GSA_JOBS`/`GSA_INTENSITY`); `--lanes`/`--jobs` accept `N` or
`auto`, `--intensity` a profile name. `GSA_CPU_THREADS` and `GSA_MEMORY_GIB`
override resource discovery for a container or a deterministic scheduler
fixture — leave them unset on a normal host. `GSA_TARGET_CPU` is the
intentional CPU-tuning override of the next section. The numeric defaults in
`config/build-defaults.conf` are the medium-profile per-job baseline: change
them in a local branch or use an explicit override; never encode one host's
RAM size in a recipe.

The engine exports `GSA_BUILD_JOBS` — the lane's job count — to each lane and
rewrites `MAKEFLAGS`/`NINJAFLAGS` (stripping `-jN`, keeping the caller's other
flags). A recipe that wants parallelism reads `GSA_BUILD_JOBS` instead of
calling `nproc` or hard-coding `-j`.

## CPU optimization

The default optimization policy comes from the host's `makepkg.conf`. Set
`GSA_TARGET_CPU` only when intentionally producing packages for a known
target CPU; the Rust snapshot recipe uses it instead of a hard-coded
`znver5`. Native optimizations in selected recipes are host-derived and
should not be redistributed as portable binary artifacts.

That last point separates two things that are easy to conflate:

* **A recipe is portable.** No recipe here pins one machine's ISA. Every
  native-flag injection is conditional on the environment not already setting a
  target, and says so (`niri-spicy-git`, `rust-bindgen-git`,
  `xwayland-satellite-git`); no recipe narrows `arch` below `x86_64`; and the
  kernel's `_processor_opt` is a knob with `zen4` and `generic` alternatives
  beside its `native` default. Copy those patterns rather than adding a new
  hard-coded `-march`.
* **An artifact is not.** `makepkg.conf` supplies `-march=native`, so a package
  built from this tree is tuned to the building machine and is not a
  redistributable binary. Hard-coding a target in a recipe would only move that
  problem from the build host to the reader.

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
