//! Advisory measurements and worker reservations for the lane supervisor.
use std::collections::BTreeMap;
use std::fs::{self, File};
use std::io::{Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::time::Instant;

const HEADER: &str = "gsa-build-history-v1";
const SYSTEM_PATH: &str = "/usr/share/gsa/build-history.tsv";
const SAMPLE_LIMIT: usize = 5;
const MAX_HISTORY_BYTES: u64 = 16 * 1024 * 1024;
const O_NONBLOCK: i32 = 0o4000;

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd)]
pub struct Key(String, String, String);

impl Key {
    pub fn new(recipe: &str, family: &str) -> Self {
        Self(recipe.into(), std::env::consts::ARCH.into(), family.into())
    }
}

#[derive(Clone, Copy)]
pub struct Sample {
    pub workers: u32,
    pub peak: u64,
    pub cpu_usec: u64,
    pub elapsed_usec: u64,
}

#[derive(Default)]
pub struct History(BTreeMap<Key, Vec<Sample>>);

impl History {
    pub fn enabled() -> bool {
        std::env::var_os("GSA_BUILD_HISTORY").as_deref() != Some(std::ffi::OsStr::new("off"))
    }

    fn parse(data: &str) -> Result<Self, String> {
        let mut lines = data.lines();
        if lines.next() != Some(HEADER) {
            return Err("unsupported history format".into());
        }
        let mut history = Self::default();
        for (i, line) in lines.enumerate() {
            let fields: Vec<_> = line.split('\t').collect();
            let parse = || -> Option<(Key, Sample)> {
                let [recipe, arch, family, workers, peak, cpu, elapsed] = fields.as_slice() else {
                    return None;
                };
                if gsa_model::RecipeId::new(*recipe).is_err()
                    || arch.is_empty()
                    || !arch.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
                    || gsa_model::toolchain::Toolchain::parse(family).is_err()
                {
                    return None;
                }
                let sample = Sample {
                    workers: workers.parse().ok()?,
                    peak: peak.parse().ok()?,
                    cpu_usec: cpu.parse().ok()?,
                    elapsed_usec: elapsed.parse().ok()?,
                };
                if sample.workers == 0 || sample.peak == 0 || sample.elapsed_usec == 0 {
                    return None;
                }
                Some((
                    Key((*recipe).into(), (*arch).into(), (*family).into()),
                    sample,
                ))
            };
            let (key, sample) = parse().ok_or_else(|| format!("invalid history row {}", i + 2))?;
            history.insert(key, sample);
        }
        Ok(history)
    }

    fn render(&self) -> String {
        use std::fmt::Write as _;
        let mut data = format!("{HEADER}\n");
        for (Key(recipe, arch, family), samples) in &self.0 {
            for sample in samples {
                let _ = writeln!(
                    data,
                    "{recipe}\t{arch}\t{family}\t{}\t{}\t{}\t{}",
                    sample.workers, sample.peak, sample.cpu_usec, sample.elapsed_usec
                );
            }
        }
        data
    }

    fn insert(&mut self, key: Key, sample: Sample) {
        let samples = self.0.entry(key).or_default();
        if samples.len() == SAMPLE_LIMIT {
            samples.remove(0);
        }
        samples.push(sample);
    }

    pub fn preferred(&self, shipped: &Self, key: &Key) -> Option<Estimate> {
        self.estimate(key).or_else(|| shipped.estimate(key))
    }

    fn estimate(&self, key: &Key) -> Option<Estimate> {
        let samples = self.0.get(key)?;
        Some(Estimate {
            bytes: samples
                .iter()
                .map(|s| s.peak.div_ceil(u64::from(s.workers)))
                .max()?,
            max_workers: samples.iter().map(|s| s.workers).max()?.saturating_mul(2),
        })
    }

    fn read(path: &Path) -> Result<Self, String> {
        // Opening a FIFO in a user-controlled history directory must not
        // block the supervisor's helper before the file-type check.
        let file = match File::options()
            .read(true)
            .custom_flags(O_NONBLOCK)
            .open(path)
        {
            Ok(file) => file,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound && !path.is_symlink() => {
                return Ok(Self::default());
            }
            Err(e) => return Err(format!("{}: {e}", path.display())),
        };
        if !file.metadata().map_err(|e| e.to_string())?.is_file() {
            return Err(format!("{} is not a regular file", path.display()));
        }
        let mut data = String::new();
        file.take(MAX_HISTORY_BYTES + 1)
            .read_to_string(&mut data)
            .map_err(|e| format!("{}: {e}", path.display()))?;
        if data.len() as u64 > MAX_HISTORY_BYTES {
            return Err(format!("{} exceeds the history size limit", path.display()));
        }
        Self::parse(&data).map_err(|e| format!("{}: {e}", path.display()))
    }

    pub fn system() -> Result<Self, String> {
        Self::read(Path::new(SYSTEM_PATH))
    }

    pub fn user(exe: &Path) -> Result<Self, String> {
        let output = gsa_model::privilege::build_command(exe)
            .arg("--build-history-user")
            .output()
            .map_err(|e| e.to_string())?;
        if !output.status.success() {
            return Err(String::from_utf8_lossy(&output.stderr).trim().to_owned());
        }
        Self::parse(&String::from_utf8(output.stdout).map_err(|e| e.to_string())?)
    }

    pub fn save(exe: &Path, key: Key, sample: Sample) -> Result<(), String> {
        let mut incoming = Self::default();
        incoming.insert(key, sample);
        let mut child = gsa_model::privilege::build_command(exe)
            .args(["--build-history-user", "merge"])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| e.to_string())?;
        let written = child
            .stdin
            .take()
            .unwrap()
            .write_all(incoming.render().as_bytes());
        let output = child.wait_with_output().map_err(|e| e.to_string())?;
        if !output.status.success() {
            return Err(String::from_utf8_lossy(&output.stderr).trim().to_owned());
        }
        written.map_err(|e| e.to_string())
    }
}

fn user_path() -> Result<PathBuf, String> {
    if gsa_model::privilege::effective_uid() == 0 {
        return Err("build history must be accessed as the build user".into());
    }
    if let Some(value) = std::env::var_os("GSA_BUILD_HISTORY") {
        if value == "off" {
            return Err("build history is disabled by GSA_BUILD_HISTORY".into());
        }
        if !value.is_empty() {
            let path = PathBuf::from(value);
            let name = path
                .file_name()
                .filter(|_| path.is_absolute())
                .ok_or("GSA_BUILD_HISTORY must be an absolute file path or 'off'")?;
            if name.as_encoded_bytes().ends_with(b".gsa-lock") {
                return Err("build history paths ending in .gsa-lock are reserved".into());
            }
            return Ok(path);
        }
    }
    Ok(gsa_model::config::build_user_home()?.join(".local/state/gsa/build-history.tsv"))
}

pub fn export(out: &mut dyn Write) -> Result<(), String> {
    let history = History::read(&user_path()?)?;
    out.write_all(history.render().as_bytes())
        .map_err(|e| e.to_string())
}

pub fn merge(input: &mut dyn Read) -> Result<(), String> {
    let path = user_path()?;
    let dir = path.parent().unwrap();
    let mut lock_name = path.file_name().unwrap().to_os_string();
    lock_name.push(".gsa-lock");
    let mut data = String::new();
    input
        .take(MAX_HISTORY_BYTES + 1)
        .read_to_string(&mut data)
        .map_err(|e| e.to_string())?;
    if data.len() as u64 > MAX_HISTORY_BYTES {
        return Err("history input exceeds the size limit".into());
    }
    let incoming = History::parse(&data)?;
    fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let lock = File::options()
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(O_NONBLOCK)
        .open(dir.join(lock_name))
        .map_err(|e| e.to_string())?;
    if !lock.metadata().map_err(|e| e.to_string())?.is_file() {
        return Err("build history lock is not a regular file".into());
    }
    let deadline = Instant::now() + std::time::Duration::from_secs(1);
    loop {
        match lock.try_lock() {
            Ok(()) => break,
            Err(std::fs::TryLockError::WouldBlock) if Instant::now() < deadline => {
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            Err(error) => return Err(format!("cannot lock build history: {error}")),
        }
    }
    let mut history = History::read(&path)?;
    for (key, samples) in incoming.0 {
        for sample in samples {
            history.insert(key.clone(), sample);
        }
    }
    let rendered = history.render();
    if rendered.len() as u64 > MAX_HISTORY_BYTES {
        return Err("merged history exceeds the size limit".into());
    }
    let tmp = dir.join(format!(".build-history.{}.tmp", std::process::id()));
    let mut file = File::options()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&tmp)
        .map_err(|e| e.to_string())?;
    let result = file
        .write_all(rendered.as_bytes())
        .and_then(|()| file.sync_all())
        .and_then(|()| fs::rename(&tmp, &path));
    if result.is_err() {
        let _ = fs::remove_file(tmp);
    }
    result.map_err(|e| e.to_string())
}

#[derive(Clone, Copy)]
pub struct Estimate {
    pub bytes: u64,
    pub max_workers: u32,
}

pub fn allocate(
    cpu: u32,
    memory: u64,
    idle: bool,
    candidates: &[(usize, Estimate)],
) -> Vec<(usize, u32, u64)> {
    let mut cpu = cpu;
    let mut memory = memory;
    let mut lanes = Vec::new();
    for &(index, estimate) in candidates {
        if cpu == 0 || memory < estimate.bytes {
            // Keep dispatch priority. On an idle scheduler even an
            // oversized package must be allowed to make progress.
            if idle && lanes.is_empty() {
                return vec![(index, 1, estimate.bytes)];
            }
            break;
        }
        cpu -= 1;
        memory -= estimate.bytes;
        lanes.push((index, 1, estimate.bytes));
    }
    while cpu > 0 {
        let eligible: Vec<_> = lanes
            .iter()
            .zip(candidates)
            .enumerate()
            .filter_map(|(slot, ((_, workers, _), (_, estimate)))| {
                (*workers < estimate.max_workers && memory >= estimate.bytes)
                    .then(|| (slot, estimate.bytes, estimate.max_workers - workers))
            })
            .collect();
        if eligible.is_empty() {
            break;
        }
        let slots = eligible.len() as u32;
        let cost: u128 = eligible
            .iter()
            .map(|&(_, bytes, _)| u128::from(bytes))
            .sum();
        let headroom = eligible.iter().map(|&(_, _, limit)| limit).min().unwrap();
        let memory_rounds = u128::from(memory).checked_div(cost).unwrap_or(u128::MAX);
        let rounds = u128::from((cpu / slots).min(headroom)).min(memory_rounds) as u32;
        // Apply whole rounds together. A partial round can exhaust CPU or
        // make at least one lane ineligible on the next pass.
        for (slot, bytes, _) in eligible {
            let extra = if rounds != 0 {
                rounds
            } else {
                u32::from(cpu > 0 && memory >= bytes)
            };
            let (_, workers, reserved) = &mut lanes[slot];
            let bytes = bytes * u64::from(extra);
            *workers += extra;
            *reserved += bytes;
            cpu -= extra;
            memory -= bytes;
        }
    }
    lanes
}

pub const ACCOUNT_ENV: &str = "_GSA_LANE_ACCOUNTING";

pub struct Scope {
    path: PathBuf,
    started: Instant,
}

impl Scope {
    /// Attach the blocked lane before letting it start the recipe.
    pub fn attach(pid: u32, previous: Option<PathBuf>) -> Option<Self> {
        let previous = previous?;
        // DelegateSubgroup=gsa-supervisor opts into a dedicated supervisor
        // leaf. The delegated unit owns the shared limits for all builds.
        let parent = if previous
            .file_name()
            .is_some_and(|name| name == "gsa-supervisor")
        {
            for control in [
                "memory.max",
                "memory.high",
                "memory.swap.max",
                "pids.max",
                "cpu.max",
            ] {
                let value = fs::read_to_string(previous.join(control));
                match value {
                    Ok(value) if value.split_whitespace().next() == Some("max") => {}
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                    _ => return None,
                }
            }
            for control in ["cpuset.cpus", "cpuset.mems", "io.max"] {
                match fs::read_to_string(previous.join(control)) {
                    Ok(value) if value.trim().is_empty() => {}
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                    _ => return None,
                }
            }
            previous.parent()?
        } else {
            &previous
        };
        let path = parent.join(format!("gsa-build-{}-{pid}", std::process::id()));
        fs::create_dir(&path).ok()?;
        if !path.join("memory.peak").is_file()
            || fs::write(path.join("cgroup.procs"), pid.to_string()).is_err()
        {
            let _ = fs::remove_dir(&path);
            return None;
        }
        Some(Self {
            path,
            started: Instant::now(),
        })
    }

    pub fn path(pid: u32) -> Option<PathBuf> {
        let membership = fs::read_to_string(format!("/proc/{pid}/cgroup")).ok()?;
        let relative = membership.lines().find_map(|l| l.strip_prefix("0::/"))?;
        Some(Path::new("/sys/fs/cgroup").join(relative))
    }

    fn sample(&self, workers: u32) -> Option<Sample> {
        let peak = fs::read_to_string(self.path.join("memory.peak"))
            .ok()?
            .trim()
            .parse()
            .ok()?;
        let cpu = fs::read_to_string(self.path.join("cpu.stat")).ok()?;
        let cpu_usec = cpu
            .lines()
            .find_map(|l| l.strip_prefix("usage_usec "))?
            .parse()
            .ok()?;
        let elapsed_usec = self.started.elapsed().as_micros().try_into().ok()?;
        (peak > 0 && elapsed_usec > 0).then_some(Sample {
            workers,
            peak,
            cpu_usec,
            elapsed_usec,
        })
    }
}

pub fn wait(mut child: Child, scope: Option<Scope>, jobs: u32) -> (Option<i32>, Option<Sample>) {
    use std::os::unix::process::ExitStatusExt;
    let sample = scope.as_ref().and_then(|scope| {
        let mut marker = [0];
        child.stdout.take()?.read_exact(&mut marker).ok()?;
        (marker == [1]).then(|| scope.sample(jobs)).flatten()
    });
    drop(child.stdin.take());
    let signal = child.wait().ok().and_then(|status| status.signal());
    if let Some(scope) = scope {
        let _ = fs::remove_dir(scope.path);
    }
    (signal, sample)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn estimate(bytes: u64) -> Estimate {
        Estimate {
            bytes,
            max_workers: u32::MAX,
        }
    }

    #[test]
    fn shares_workers_after_reserving_for_later_lanes() {
        let ready = [(0, estimate(1)), (1, estimate(4))];
        assert_eq!(allocate(12, 9, true, &ready), [(0, 5, 5), (1, 1, 4)]);
        // The second lane still fits when the first reservation is active.
        assert_eq!(allocate(7, 4, false, &ready[1..]), [(1, 1, 4)]);
        assert!(allocate(6, 3, false, &ready[1..]).is_empty());
        assert_eq!(allocate(6, 3, true, &ready[1..]), [(1, 1, 4)]);
    }

    #[test]
    fn honours_worker_limits_and_returns_capacity_to_ready_lanes() {
        let ready = [
            (
                0,
                Estimate {
                    bytes: 1,
                    max_workers: 2,
                },
            ),
            (1, estimate(1)),
        ];
        assert_eq!(allocate(8, 8, true, &ready), [(0, 2, 2), (1, 6, 6)]);
        assert_eq!(allocate(8, 8, true, &ready[1..]), [(1, 8, 8)]);
    }

    #[test]
    fn allocates_extreme_cpu_overrides_in_whole_rounds() {
        let ready = [(0, estimate(1)), (1, estimate(2))];
        let half = u32::MAX / 2;
        assert_eq!(
            allocate(u32::MAX, u64::MAX, true, &ready),
            [
                (0, half + 1, u64::from(half + 1)),
                (1, half, u64::from(half) * 2)
            ]
        );
    }

    #[test]
    fn uses_latest_samples_and_prefers_the_user_per_key() {
        let key = Key::new("light", "gcc");
        let shipped_only = Key::new("other", "clang");
        let sample = |workers, peak| Sample {
            workers,
            peak,
            cpu_usec: 42,
            elapsed_usec: 42,
        };
        let mut user = History::default();
        let mut shipped = History::default();
        shipped.insert(key.clone(), sample(16, 640));
        shipped.insert(shipped_only.clone(), sample(8, 80));
        user.insert(key.clone(), sample(16, 640));
        for _ in 0..4 {
            user.insert(key.clone(), sample(4, 16));
        }
        user.insert(key.clone(), sample(2, 11));
        let user = History::parse(&user.render()).unwrap();
        let estimate = user.preferred(&shipped, &key).unwrap();
        assert_eq!((estimate.bytes, estimate.max_workers), (6, 8));
        assert_eq!(user.preferred(&shipped, &shipped_only).unwrap().bytes, 10);
        assert!(user
            .preferred(&shipped, &Key::new("unknown", "gcc"))
            .is_none());
        assert!(History::parse("unknown format\n").is_err());
    }
}
