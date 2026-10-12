//! Resource budgets: the `docs/portability.md` intensity formulas as data.
//!
//! Every term is host-derived (CPU threads, available memory) or stated by
//! `config/build-defaults.conf` (the GiB-per-job baselines) or by the
//! intensity profile constants ported verbatim from `configure_intensity`
//! (`build-all.fish`). The resolved plan is printed once (`parallelism:`) and
//! is the truth — nothing predicts a plan before it (docs/portability.md:
//! "do not predict the plan — read the line the builder prints").

/// One intensity profile (`docs/portability.md` "Parallelism"; the fish
/// `configure_intensity` constants, kept numerically identical).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Profile {
    pub name: &'static str,
    pub lane_cap: u32,
    pub cpu_per_lane: u32,
    pub memory_per_lane: u32,
    pub normal_memory_factor: f64,
    pub core_memory_factor: f64,
}

/// The closed intensity roster, in `gsa-topo::INTENSITY_LEVELS` order.
pub const PROFILES: [Profile; 5] = [
    Profile {
        name: "low",
        lane_cap: 1,
        cpu_per_lane: 16,
        memory_per_lane: 16,
        normal_memory_factor: 2.0,
        core_memory_factor: 1.5,
    },
    Profile {
        name: "medium",
        lane_cap: 2,
        cpu_per_lane: 8,
        memory_per_lane: 8,
        normal_memory_factor: 1.0,
        core_memory_factor: 1.0,
    },
    Profile {
        name: "high",
        lane_cap: 3,
        cpu_per_lane: 6,
        memory_per_lane: 6,
        normal_memory_factor: 0.67,
        core_memory_factor: 0.75,
    },
    Profile {
        name: "xhigh",
        lane_cap: 4,
        cpu_per_lane: 4,
        memory_per_lane: 4,
        normal_memory_factor: 0.5,
        core_memory_factor: 0.625,
    },
    Profile {
        name: "max",
        lane_cap: 6,
        cpu_per_lane: 2,
        memory_per_lane: 2,
        normal_memory_factor: 0.34,
        core_memory_factor: 0.5,
    },
];

pub fn profile(name: &str) -> Option<Profile> {
    PROFILES.into_iter().find(|p| p.name == name)
}

/// The GiB-per-job baselines from `config/build-defaults.conf`.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Baselines {
    pub memory_per_job_gib: f64,
    pub core_memory_per_job_gib: f64,
    pub reserved_memory_gib: f64,
}

impl Default for Baselines {
    fn default() -> Self {
        Baselines {
            memory_per_job_gib: 3.0,
            core_memory_per_job_gib: 4.0,
            reserved_memory_gib: 2.0,
        }
    }
}

/// A `--lanes` / `--jobs` value: `N` or `auto`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Override {
    Auto,
    Value(u32),
}

impl Override {
    pub fn parse(raw: &str) -> Result<Override, String> {
        if raw == "auto" {
            return Ok(Override::Auto);
        }
        match raw.parse::<u32>() {
            Ok(n) if n >= 1 => Ok(Override::Value(n)),
            _ => Err(format!(
                "expected a positive integer or 'auto', got '{raw}'"
            )),
        }
    }
}

/// Host facts the formulas consume. `threads`/`memory_gib` come from
/// `GSA_CPU_THREADS`/`GSA_MEMORY_GIB` when set, else from discovery.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct HostFacts {
    pub threads: u32,
    pub memory_gib: u32,
}

/// CPU threads: `std::thread::available_parallelism`, floor 1.
pub fn detect_threads() -> u32 {
    std::thread::available_parallelism()
        .map(|n| n.get() as u32)
        .unwrap_or(1)
        .max(1)
}

/// Available memory in whole GiB from `/proc/meminfo` (`MemAvailable`),
/// floor 1. Falls back to 1 when the file is unreadable so the formulas stay
/// deterministic instead of guessing a workstation's RAM.
pub fn detect_memory_gib() -> u32 {
    let Ok(content) = std::fs::read_to_string("/proc/meminfo") else {
        return 1;
    };
    for line in content.lines() {
        if let Some(rest) = line.strip_prefix("MemAvailable:") {
            let kib: u64 = rest.trim().trim_end_matches(" kB").parse().unwrap_or(0);
            return ((kib / 1024 / 1024).max(1)) as u32;
        }
    }
    1
}

/// Host facts honouring `GSA_CPU_THREADS` / `GSA_MEMORY_GIB` overrides
/// (docs/portability.md: "for a container or a deterministic scheduler
/// fixture"). An unparsable override is a usage error, never a silent fall
/// back to discovery.
pub fn host_facts() -> Result<HostFacts, String> {
    let threads = match std::env::var("GSA_CPU_THREADS") {
        Ok(v) if !v.is_empty() => v
            .parse::<u32>()
            .ok()
            .filter(|n| *n >= 1)
            .ok_or_else(|| format!("GSA_CPU_THREADS must be a positive integer, got '{v}'"))?,
        _ => detect_threads(),
    };
    let memory_gib = match std::env::var("GSA_MEMORY_GIB") {
        Ok(v) if !v.is_empty() => v
            .parse::<u32>()
            .ok()
            .filter(|n| *n >= 1)
            .ok_or_else(|| format!("GSA_MEMORY_GIB must be a positive integer, got '{v}'"))?,
        _ => detect_memory_gib(),
    };
    Ok(HostFacts {
        threads,
        memory_gib: memory_gib.max(1),
    })
}

/// The resolved plan: printed once, exported per lane, mirrored by the run
/// record's `lanes`/`normal-jobs`/`core-jobs` scalars.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Budget {
    pub threads: u32,
    pub memory_gib: u32,
    pub intensity: &'static str,
    pub lanes: u32,
    pub normal_jobs: u32,
    pub core_jobs: u32,
}

impl Budget {
    /// Resolve the plan exactly as `docs/portability.md`'s formulas state
    /// them (`build-all.fish` `run_lanes`' budget block is the reference
    /// semantics): normal jobs are budgeted globally, `lanes` is bounded by
    /// the profile cap, per-lane CPU/memory, the job budget and the package
    /// count; explicit `--lanes`/`--jobs` values (or their env twins) beat
    /// the profile.
    pub fn resolve(
        intensity: &str,
        lanes_override: Override,
        jobs_override: Override,
        baselines: Baselines,
        facts: HostFacts,
        package_count: usize,
    ) -> Result<Budget, String> {
        let profile = profile(intensity).ok_or_else(|| {
            format!("intensity must be one of low, medium, high, xhigh, or max (got '{intensity}')")
        })?;
        let threads = facts.threads.max(1);
        let memory_gib = facts.memory_gib.max(1);
        let package_count = package_count.max(1) as u32;

        let normal_memory = (memory_gib as f64 - baselines.reserved_memory_gib).max(1.0);
        let normal_memory_per_job =
            (baselines.memory_per_job_gib * profile.normal_memory_factor).max(f64::MIN_POSITIVE);
        let normal_job_budget = (normal_memory / normal_memory_per_job).floor().max(1.0) as u32;

        let lanes = match lanes_override {
            Override::Value(n) => n,
            Override::Auto => {
                let auto = normal_memory / normal_memory_per_job; // documented floor term
                let _ = auto;
                let lane_cap = profile.lane_cap;
                let cpu_term = threads / profile.cpu_per_lane;
                let mem_term = memory_gib / profile.memory_per_lane;
                lane_cap
                    .min(cpu_term.max(1))
                    .min(mem_term.max(1))
                    .min(normal_job_budget)
                    .min(package_count)
                    .max(1)
            }
        }
        .min(package_count)
        .max(1);

        let normal_jobs = match jobs_override {
            Override::Value(n) => n,
            Override::Auto => {
                let cpu_jobs = threads / lanes;
                let memory_jobs = normal_job_budget / lanes;
                cpu_jobs.min(memory_jobs).max(1)
            }
        };

        let core_memory_per_job =
            (baselines.core_memory_per_job_gib * profile.core_memory_factor).max(f64::MIN_POSITIVE);
        let core_jobs = threads
            .min((normal_memory / core_memory_per_job).floor().max(1.0) as u32)
            .max(1);

        Ok(Budget {
            threads,
            memory_gib,
            intensity: profile.name,
            lanes,
            normal_jobs,
            core_jobs,
        })
    }

    /// The `parallelism:` line — the one place the resolved plan is printed
    /// (docs/portability.md).
    pub fn parallelism_line(&self) -> String {
        format!(
            "parallelism: {} CPU threads, {} GiB available, intensity {}, {} lane(s), normal -j{}, core -j{}",
            self.threads, self.memory_gib, self.intensity, self.lanes, self.normal_jobs, self.core_jobs
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn facts(threads: u32, memory_gib: u32) -> HostFacts {
        HostFacts {
            threads,
            memory_gib,
        }
    }

    #[test]
    fn profiles_match_the_ported_constants() {
        let xhigh = profile("xhigh").unwrap();
        assert_eq!(xhigh.lane_cap, 4);
        assert_eq!(xhigh.cpu_per_lane, 4);
        assert_eq!(xhigh.memory_per_lane, 4);
        assert_eq!(xhigh.normal_memory_factor, 0.5);
        assert_eq!(xhigh.core_memory_factor, 0.625);
        assert!(profile("turbo").is_none());
        assert_eq!(PROFILES.len(), 5);
    }

    #[test]
    fn budget_formulas_follow_portability_doc() {
        // 24 threads / 29 GiB / xhigh / 3-4-2 baselines, 4 packages:
        // normal_memory = 27; per-job = 1.5; budget = 18
        // lanes = min(4, 6, 7, 18, 4) = 4; lane_jobs = min(6, 4) = 4
        // core: per-job = 2.5; core_jobs = min(24, 10) = 10
        let b = Budget::resolve(
            "xhigh",
            Override::Auto,
            Override::Auto,
            Baselines::default(),
            facts(24, 29),
            4,
        )
        .unwrap();
        assert_eq!(b.lanes, 4);
        assert_eq!(b.normal_jobs, 4);
        assert_eq!(b.core_jobs, 10);
    }

    #[test]
    fn explicit_overrides_beat_the_profile() {
        let b = Budget::resolve(
            "xhigh",
            Override::Value(2),
            Override::Value(6),
            Baselines::default(),
            facts(24, 29),
            40,
        )
        .unwrap();
        assert_eq!(b.lanes, 2);
        assert_eq!(b.normal_jobs, 6);
    }

    #[test]
    fn lanes_never_exceed_the_package_count() {
        let b = Budget::resolve(
            "max",
            Override::Auto,
            Override::Auto,
            Baselines::default(),
            facts(24, 29),
            1,
        )
        .unwrap();
        assert_eq!(b.lanes, 1);
    }

    #[test]
    fn tiny_host_still_gets_one_lane_and_one_job() {
        let b = Budget::resolve(
            "max",
            Override::Auto,
            Override::Auto,
            Baselines::default(),
            facts(1, 1),
            10,
        )
        .unwrap();
        assert_eq!(b.lanes, 1);
        assert_eq!(b.normal_jobs, 1);
        assert_eq!(b.core_jobs, 1);
    }

    #[test]
    fn overrides_parse_or_name_the_value() {
        assert_eq!(Override::parse("auto").unwrap(), Override::Auto);
        assert_eq!(Override::parse("3").unwrap(), Override::Value(3));
        assert!(Override::parse("0").unwrap_err().contains("'0'"));
        assert!(Override::parse("many").unwrap_err().contains("'many'"));
    }

    #[test]
    fn parallelism_line_matches_the_reference_shape() {
        let b = Budget::resolve(
            "xhigh",
            Override::Auto,
            Override::Auto,
            Baselines::default(),
            facts(24, 29),
            4,
        )
        .unwrap();
        assert_eq!(
            b.parallelism_line(),
            "parallelism: 24 CPU threads, 29 GiB available, intensity xhigh, 4 lane(s), normal -j4, core -j10"
        );
    }
}
