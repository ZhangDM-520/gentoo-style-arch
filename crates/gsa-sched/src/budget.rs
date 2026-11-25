//! Resource budgets: the `docs/portability.md` intensity formulas as data.
//!
use gsa_model::{INTENSITY_LEVELS, INTENSITY_PROFILES};

const MAX_AUTO_LANES: u32 = 4;
const CPU_PER_AUTO_LANE: u32 = 4;
const GIB_PER_AUTO_LANE: f64 = 4.0;

/// Resolve a level and its resource percentage from the shared roster.
pub fn intensity_profile(intensity: &str) -> Result<(&'static str, u32), String> {
    INTENSITY_PROFILES
        .into_iter()
        .find(|&(name, _)| name == intensity)
        .ok_or_else(|| {
            format!(
                "intensity must be one of {} (got '{intensity}')",
                INTENSITY_LEVELS.join(", ")
            )
        })
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
/// floor 1.
pub fn detect_memory_gib() -> Result<u32, String> {
    memory_gib_from_read(std::fs::read_to_string("/proc/meminfo").map_err(|e| e.to_string()))
}

/// Whole GiB of `MemAvailable` from one `/proc/meminfo` read.
///
/// An UNREADABLE file is the documented fallback (1 GiB): the formulas stay
/// deterministic instead of guessing a workstation's RAM. A READABLE file
/// whose field is missing or unparsable is an error, never the fallback — an
/// unparsable field floored to 1 GiB masquerades as a one-GiB host and
/// resolves one lane / one job for a build that should take minutes, with no
/// diagnostic at all.
fn memory_gib_from_read(read: Result<String, String>) -> Result<u32, String> {
    let Ok(content) = read else {
        return Ok(1);
    };
    let field = content
        .lines()
        .find_map(|line| line.strip_prefix("MemAvailable:"))
        .ok_or_else(|| {
            "cannot detect available memory: /proc/meminfo has no MemAvailable field \
             (set GSA_MEMORY_GIB to state the host's memory)"
                .to_string()
        })?;
    let kib: u64 = field
        .trim()
        .trim_end_matches(" kB")
        .trim()
        .parse()
        .map_err(|_| {
            format!(
                "cannot detect available memory: /proc/meminfo MemAvailable is not a number \
                 (got '{}'; set GSA_MEMORY_GIB to state the host's memory)",
                field.trim()
            )
        })?;
    Ok((kib / 1024 / 1024).max(1) as u32)
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
        _ => detect_memory_gib()?,
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
    pub resources: Option<ResourceBudget>,
    pub threads: u32,
    pub memory_gib: u32,
    pub intensity: &'static str,
    pub lanes: u32,
    pub normal_jobs: u32,
    pub core_jobs: u32,
}

/// Run-wide capacity and fallbacks for adaptive dispatch.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ResourceBudget {
    pub cpu: u32,
    pub memory: u64,
    pub normal_bytes: u64,
    pub core_bytes: u64,
    pub explicit_jobs: Option<u32>,
}

impl Budget {
    /// Scale CPU and usable memory before sizing lanes and job counts.
    pub fn resolve(
        intensity: &str,
        lanes_override: Override,
        jobs_override: Override,
        baselines: Baselines,
        facts: HostFacts,
        package_count: usize,
    ) -> Result<Budget, String> {
        let (intensity, percent) = intensity_profile(intensity)?;
        let threads = facts.threads.max(1);
        let memory_gib = facts.memory_gib.max(1);
        let package_count = package_count.max(1) as u32;

        let cpu_budget =
            (u64::from(threads) * u64::from(percent) / 100).clamp(1, u64::from(u32::MAX)) as u32;
        let usable_memory = (f64::from(memory_gib) - baselines.reserved_memory_gib).max(1.0);
        let scaled_memory = usable_memory * f64::from(percent);
        let memory_jobs = |per_job: f64| {
            // Decimal baselines can land one floating-point step below an
            // exact whole slot. Allow that step before rounding down.
            (scaled_memory / (100.0 * per_job.max(f64::MIN_POSITIVE)))
                .next_up()
                .floor() as u32
        };
        let normal_job_budget = memory_jobs(baselines.memory_per_job_gib).max(1);

        let lanes = match lanes_override {
            Override::Value(n) => n,
            Override::Auto => {
                let cpu_lanes = cpu_budget / CPU_PER_AUTO_LANE;
                let memory_lanes = memory_jobs(GIB_PER_AUTO_LANE);
                MAX_AUTO_LANES
                    .min(cpu_lanes)
                    .min(memory_lanes)
                    .min(normal_job_budget)
                    .min(package_count)
                    .max(1)
            }
        }
        .min(package_count)
        .max(1);

        // Explicit jobs may use up to the scaled per-lane ceiling.
        let auto_jobs = {
            let cpu_jobs = cpu_budget / lanes;
            let memory_jobs = normal_job_budget / lanes;
            cpu_jobs.min(memory_jobs).max(1)
        };
        let normal_jobs = match jobs_override {
            Override::Value(n) => n.min(auto_jobs),
            Override::Auto => auto_jobs,
        };

        let core_jobs = cpu_budget
            .min(memory_jobs(baselines.core_memory_per_job_gib))
            .max(1);

        let bytes = |gib: f64| (gib * (1u64 << 30) as f64).ceil().max(1.0) as u64;
        Ok(Budget {
            resources: Some(ResourceBudget {
                cpu: cpu_budget,
                memory: (scaled_memory / 100.0 * (1u64 << 30) as f64).floor() as u64,
                normal_bytes: bytes(baselines.memory_per_job_gib),
                core_bytes: bytes(baselines.core_memory_per_job_gib),
                explicit_jobs: match jobs_override {
                    Override::Value(_) => Some(normal_jobs),
                    Override::Auto => None,
                },
            }),
            threads,
            memory_gib,
            intensity,
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
    fn retired_or_unknown_intensity_is_rejected() {
        for level in ["max", "ex"] {
            let error = Budget::resolve(
                level,
                Override::Auto,
                Override::Auto,
                Baselines::default(),
                facts(24, 29),
                4,
            )
            .unwrap_err();
            assert_eq!(
                error,
                format!("intensity must be one of low, medium, high, xhigh (got '{level}')")
            );
        }
    }

    #[test]
    fn xhigh_can_exceed_both_detected_limits() {
        let budget = Budget::resolve(
            "xhigh",
            Override::Value(1),
            Override::Auto,
            Baselines {
                memory_per_job_gib: 1.0,
                core_memory_per_job_gib: 1.0,
                reserved_memory_gib: 0.0,
            },
            facts(10, 10),
            1,
        )
        .unwrap();
        assert_eq!((budget.normal_jobs, budget.core_jobs), (11, 11));
    }

    #[test]
    fn fractional_memory_baseline_keeps_whole_job_at_boundary() {
        for (level, per_job, expected) in [
            ("low", 0.05, 7),
            ("low", 0.07, 5),
            ("low", 0.071, 4),
            ("xhigh", 0.55, 2),
        ] {
            let budget = Budget::resolve(
                level,
                Override::Value(1),
                Override::Auto,
                Baselines {
                    memory_per_job_gib: per_job,
                    core_memory_per_job_gib: per_job,
                    reserved_memory_gib: 0.0,
                },
                facts(40, 1),
                1,
            )
            .unwrap();
            assert_eq!(
                (budget.normal_jobs, budget.core_jobs),
                (expected, expected),
                "{level} with {per_job} GiB per job"
            );
        }
    }

    #[test]
    fn budget_formulas_follow_portability_doc() {
        // 26 scaled threads and 29.7 scaled GiB yield 9 normal slots
        // across 4 lanes and 7 slots for a solo core package.
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
        assert_eq!(b.normal_jobs, 2);
        assert_eq!(b.core_jobs, 7);
    }

    #[test]
    fn explicit_overrides_beat_the_profile() {
        let b = Budget::resolve(
            "xhigh",
            Override::Value(2),
            Override::Value(3),
            Baselines::default(),
            facts(24, 29),
            40,
        )
        .unwrap();
        assert_eq!(b.lanes, 2);
        assert_eq!(b.normal_jobs, 3);
    }

    #[test]
    fn explicit_jobs_above_the_host_budget_is_clamped() {
        let clamped = Budget::resolve(
            "xhigh",
            Override::Auto,
            Override::Value(12),
            Baselines::default(),
            facts(24, 29),
            10,
        )
        .unwrap();
        assert_eq!(clamped.normal_jobs, 2);
        let under = Budget::resolve(
            "xhigh",
            Override::Auto,
            Override::Value(1),
            Baselines::default(),
            facts(24, 29),
            10,
        )
        .unwrap();
        assert_eq!(under.normal_jobs, 1);
    }

    #[test]
    fn lanes_never_exceed_the_package_count() {
        let b = Budget::resolve(
            "low",
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
    fn unparsable_mem_available_is_never_a_tiny_host() {
        // Present but unparsable: an error naming the field, never the 1 GiB
        // floor (which would silently plan one lane for a large host).
        let error = memory_gib_from_read(Ok(
            "MemTotal: 65536000 kB\nMemAvailable: plenty kB\n".to_string()
        ))
        .unwrap_err();
        assert!(error.contains("MemAvailable"), "{error}");
        // A readable file without the field is the same class.
        assert!(memory_gib_from_read(Ok("MemTotal: 65536000 kB\n".to_string())).is_err());
        // A well-formed field still yields whole GiB.
        assert_eq!(
            memory_gib_from_read(Ok("MemAvailable:       30408704 kB\n".to_string())),
            Ok(29)
        );
        // Only an unreadable file takes the documented 1 GiB fallback.
        assert_eq!(
            memory_gib_from_read(Err("No such file or directory".to_string())),
            Ok(1)
        );
    }

    #[test]
    fn tiny_host_still_gets_one_lane_and_one_job() {
        let b = Budget::resolve(
            "low",
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
            "parallelism: 24 CPU threads, 29 GiB available, intensity xhigh, 4 lane(s), normal -j2, core -j7"
        );
    }
}
