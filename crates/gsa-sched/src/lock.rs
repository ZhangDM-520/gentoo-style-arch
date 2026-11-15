//! Run lock, write-time ownership, and orphan sweeps (contract §J.5, §K).
//!
//! - The run lock is an `flock(2)` on `<state>/locks/run.lock`: one engine run
//!   at a time over one state root. A held lock is a refusal, never a wait.
//! - Write-time ownership (rule 19, docs/plans/plan-gsa-isolation.md W1): engine state is
//!   owned by the privileged runner — mutating runs are root (contract §B.10),
//!   so root-owned state is the correct state, never corruption. A state file
//!   owned by anyone the running engine is not is quarantined as
//!   `<path>.stale.<epoch>.<pid>` (preserved, announced) or the write fails
//!   naming the remedy. There is no silent adoption.
//! - Orphan sweeps: startup and post-run sweeps reap `--lane-job` /
//!   `--fetch-job` children of dead runs and stale run artifacts (`.tmp.*`,
//!   abandoned result files). Unrelated `makepkg` processes are never
//!   touched (§K.3).
//! - `--stale-lock-check` is the production pacman-lock probe without a run:
//!   holder identification via `/proc/*/fd`, never `db.lck` deletion.

use std::fs::{File, OpenOptions};
use std::io::Write;
use std::os::fd::AsRawFd;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

use gsa_model::state_gate::{gate_open_with_kind, GateFailure};
pub use gsa_model::state_gate::{
    open_state_append, open_state_append_nofollow, open_state_file_with_uid, quarantine_foreign,
    GateError,
};

use crate::signals::{current_uid, flock_exclusive_nonblocking, send_signal, SIGKILL};

/// The held run lock; dropped to close the fd and release the flock.
pub struct RunLock {
    /// Held open for the process lifetime: closing it releases the flock.
    /// The lock FILE is deliberately never deleted — unlinking a
    /// possibly-held lock inode is the race class rule 19/§K.3 forbids.
    #[allow(dead_code)]
    file: File,
    path: PathBuf,
}

impl RunLock {
    pub fn path(&self) -> &Path {
        &self.path
    }
}

/// Why a run-lock acquisition failed — the one distinction the fallback
/// seam (`gsa_maint::hold_run_lock`) needs: `Permission` is EACCES/EPERM
/// anywhere in the create/open/ownership path (a state root the running
/// user may not write), `Busy` is flock contention (another engine run
/// holds the lock — never a fallback trigger), `Other` is every remaining
/// failure. `Display` renders the same message callers already surface.
#[derive(Debug)]
pub enum RunLockError {
    Permission(String),
    Busy(String),
    Other(String),
}

impl std::fmt::Display for RunLockError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            RunLockError::Permission(m) | RunLockError::Busy(m) | RunLockError::Other(m) => {
                f.write_str(m)
            }
        }
    }
}

/// Classify one OS error behind a pre-rendered message.
fn classify_io(e: std::io::Error, message: String) -> RunLockError {
    if e.kind() == std::io::ErrorKind::PermissionDenied {
        RunLockError::Permission(message)
    } else {
        RunLockError::Other(message)
    }
}

/// Acquire an explicit lock FILE — the one flock machinery behind
/// [`acquire_run_lock`] and the build-user fallback: create the parent,
/// take the non-blocking exclusive flock, keep the fd. `scope` fills the
/// busy message ("a second run over the {scope} is refused"). A busy lock
/// is a refusal naming the holder's lock path — the engine never waits on
/// it and never deletes a held lock file.
pub fn acquire_run_lock_file(path: &Path, scope: &str) -> Result<RunLock, RunLockError> {
    if let Some(parent) = path.parent() {
        if !parent.as_os_str().is_empty() {
            std::fs::create_dir_all(parent).map_err(|e| {
                let message = format!("cannot create {}: {e}", parent.display());
                classify_io(e, message)
            })?;
        }
    }
    // The gate's checked handle IS the lock file: the flock and the pid write
    // land on the inode the ownership check saw, never a second open. The
    // quarantine note goes to stderr because this entry predates an err sink
    // and its callers surface only the error string.
    let mut opts = OpenOptions::new();
    opts.create(true).truncate(false).write(true);
    let file = gate_open_with_kind(path, &mut opts, current_uid(), &mut std::io::stderr())
        .map_err(|f| classify_failure(f))?;
    if !flock_exclusive_nonblocking(file.as_raw_fd()) {
        return Err(RunLockError::Busy(format!(
            "another gsa run holds {} (a second run over the {} is refused); {}",
            path.display(),
            scope,
            held_lock_diagnosis(path)
        )));
    }
    // Truncate before the write: a longer pid from a previous holder would
    // otherwise survive the overwrite and a reader would name a stranger.
    let _ = file.set_len(0);
    let _ = writeln!(&mut { &file }, "{}", std::process::id());
    Ok(RunLock {
        file,
        path: path.to_path_buf(),
    })
}

/// What a BUSY lock file says about its holder, without taking the flock:
/// the pid the file answers with, whether that pid is a live `gsa` run, and
/// the command that clears a genuinely stale lock. One derivation, shared by
/// the refusal (`acquire_run_lock_file`) and `--stale-lock-check`, so the two
/// surfaces can never describe one file differently (R2-vera-8: an operator
/// holding `flock` on the run lock got a refusal naming no holder, no
/// liveness verdict and no remedy, while the only lock verb answered about
/// `db.lck`).
/// Who holds a busy lock — the evidence, in the order it is trustworthy:
/// the process that demonstrably has the file OPEN (an fd scan, the same
/// technique `db.lck`'s holder rows use), then the pid the lock file itself
/// records. A file's recorded pid alone cannot tell a foreign holder (a
/// plain `flock`) from a leftover file, which is why the refusal used to
/// name nothing (R2-vera-8).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LockHolder {
    /// A process has the file open: `gsa` answers whether its argv[0] is a
    /// gsa run (a holder that is not gsa is a stale lock from the engine's
    /// point of view).
    Process { pid: u32, gsa: bool },
    /// No process has it open; the lock file records this pid (or none).
    Recorded { pid: Option<u32>, gsa: bool },
    /// Nothing visible and nothing recorded; `scan_incomplete` says whether
    /// the fd scan could not inspect every process.
    Unknown { scan_incomplete: bool },
}

/// The holder evidence plus the sentence and the remedy that follow from it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LockDiagnosis {
    pub holder: LockHolder,
}

impl LockDiagnosis {
    /// Stated as one sentence, for a refusal or a report row reason. It
    /// always answers the one question a stuck operator has: is a live gsa
    /// run behind this, or is the lock stale?
    pub fn describe(&self) -> String {
        match &self.holder {
            LockHolder::Process { pid, gsa: true } => {
                format!("holder pid {pid} is a live gsa run")
            }
            LockHolder::Process { pid, gsa: false } => {
                format!("holder pid {pid} is not a gsa run — no gsa process holds it")
            }
            LockHolder::Recorded { pid: Some(pid), gsa: true } => format!(
                "the lock file records pid {pid}, a live gsa run that holds no descriptor on the file — the lock is stale"
            ),
            LockHolder::Recorded { pid: Some(pid), gsa: false } => format!(
                "the lock file records pid {pid}, which is not a live gsa run — no gsa process holds it"
            ),
            LockHolder::Recorded { pid: None, .. } => {
                "the lock file records no holder pid — no gsa process holds it".to_string()
            }
            LockHolder::Unknown {
                scan_incomplete: true,
            } => "the holder could not be identified (not privileged to inspect every /proc/*/fd entry)"
                .to_string(),
            LockHolder::Unknown {
                scan_incomplete: false,
            } => "nothing holds the file open and it records no holder pid".to_string(),
        }
    }

    /// Is the lock held by a live engine run? Then the remedy is to wait;
    /// otherwise the file is stale and the remedy is the exact command.
    pub fn live_gsa(&self) -> bool {
        match self.holder {
            LockHolder::Process { gsa, .. } | LockHolder::Recorded { gsa, .. } => gsa,
            LockHolder::Unknown { .. } => false,
        }
    }

    /// The holder's pid, when one is known.
    pub fn pid(&self) -> Option<u32> {
        match self.holder {
            LockHolder::Process { pid, .. } | LockHolder::Recorded { pid: Some(pid), .. } => {
                Some(pid)
            }
            LockHolder::Recorded { pid: None, .. } | LockHolder::Unknown { .. } => None,
        }
    }

    /// The exact command that clears a stale lock, printed and never
    /// implied. Deleting a HELD lock is the race §K.3 forbids, so the
    /// remedy is only offered once the holder is known not to be a live
    /// engine run; a live holder's remedy is to let that run finish.
    pub fn remedy(&self, path: &Path) -> String {
        match self.pid() {
            Some(pid) if self.live_gsa() => {
                format!("let the run holding it finish; if pid {pid} is wedged, stop it and re-run")
            }
            _ => format!("rm {}", path.display()),
        }
    }
}

/// Diagnose a busy lock file: scan `/proc/*/fd` for a process holding THIS
/// inode, then fall back to the pid the file records. Reads only — the
/// caller already knows the file is busy, so this never flocks it.
pub fn diagnose_held_lock(path: &Path) -> LockDiagnosis {
    let recorded_pid = std::fs::read_to_string(path)
        .ok()
        .and_then(|text| text.trim().parse::<u32>().ok());
    let holder = match std::fs::metadata(path) {
        Ok(meta) => {
            let holders = fd_holders(meta.ino(), meta.dev());
            // A holder can FORK a child that inherits the descriptor (flock
            // over a command does exactly that), so the scan may see two
            // processes for one hold. The gsa one is the holder of record:
            // naming the child would report a live engine run as foreign.
            let chosen = holders
                .pids
                .iter()
                .find(|(_, _, is_gsa)| *is_gsa)
                .or_else(|| holders.pids.first());
            match chosen {
                Some((pid, _, is_gsa)) => LockHolder::Process {
                    pid: *pid,
                    gsa: *is_gsa,
                },
                None => LockHolder::Recorded {
                    pid: recorded_pid,
                    gsa: recorded_pid.map(is_gsa_process).unwrap_or(false),
                },
            }
        }
        // No stat, no scan: the recorded pid is all the evidence there is.
        Err(_) => LockHolder::Recorded {
            pid: recorded_pid,
            gsa: recorded_pid.map(is_gsa_process).unwrap_or(false),
        },
    };
    LockDiagnosis { holder }
}

/// One `/proc/*/fd` scan for the processes with one inode open — the ONE
/// derivation behind `db.lck`'s `holder:` rows and the run lock's refusal,
/// so the two locks are identified by the same evidence.
struct FdHolders {
    /// `(pid, command line rendered the way the holder row prints it,
    /// whether argv[0]'s file name is gsa)`.
    pids: Vec<(u32, String, bool)>,
    skipped: usize,
    proc_unreadable: Option<String>,
}

fn fd_holders(ino: u64, dev: u64) -> FdHolders {
    let mut found = FdHolders {
        pids: Vec::new(),
        skipped: 0,
        proc_unreadable: None,
    };
    let proc_dir = match std::fs::read_dir("/proc") {
        Ok(dir) => dir,
        Err(error) => {
            found.proc_unreadable = Some(error.to_string());
            return found;
        }
    };
    // The refusing caller holds the lock file open by definition — its own fd
    // is what lost the flock — so a scan that counted itself would answer
    // "a live gsa run holds it" about the very run being refused and name no
    // real holder (R2-vera-8's fixture caught exactly that).
    let own_pid = std::process::id();
    for entry in proc_dir.flatten() {
        let pid: u32 = match entry.file_name().to_string_lossy().parse() {
            Ok(pid) => pid,
            Err(_) => continue,
        };
        if pid == own_pid {
            continue;
        }
        let fds = match std::fs::read_dir(format!("/proc/{pid}/fd")) {
            Ok(fds) => fds,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(_) => {
                found.skipped += 1;
                continue;
            }
        };
        for fd in fds.flatten() {
            let Ok(target) = std::fs::metadata(fd.path()) else {
                continue;
            };
            if target.ino() == ino && target.dev() == dev {
                let raw = std::fs::read(format!("/proc/{pid}/cmdline")).unwrap_or_default();
                let argv0 = raw
                    .split(|b| *b == 0)
                    .find(|s| !s.is_empty())
                    .map(|s| String::from_utf8_lossy(s).into_owned())
                    .unwrap_or_default();
                let is_gsa = std::path::Path::new(&argv0)
                    .file_name()
                    .map(|name| name == "gsa")
                    .unwrap_or(false);
                let rendered = String::from_utf8_lossy(&raw).replace('\0', " ");
                found.pids.push((pid, rendered.trim().to_string(), is_gsa));
                break;
            }
        }
    }
    found
}

/// Is this pid a live `gsa` process? The command line's first component's
/// file name, so a renamed build or a wrapper still answers `gsa`; a pid
/// that is gone or belongs to another program is not. The same evidence the
/// orphan sweep uses (`/proc/<pid>/cmdline`), never a name heuristic on a
/// filename.
fn is_gsa_process(pid: u32) -> bool {
    let Ok(bytes) = std::fs::read(format!("/proc/{pid}/cmdline")) else {
        return false;
    };
    let argv0 = bytes
        .split(|b| *b == 0)
        .find(|s| !s.is_empty())
        .map(|s| String::from_utf8_lossy(s).into_owned())
        .unwrap_or_default();
    std::path::Path::new(&argv0)
        .file_name()
        .map(|name| name == "gsa")
        .unwrap_or(false)
}

fn held_lock_diagnosis(path: &Path) -> String {
    let diagnosis = diagnose_held_lock(path);
    format!(
        "{}; to clear it: {}",
        diagnosis.describe(),
        diagnosis.remedy(path)
    )
}

/// The pre-probe default [`RunLockState::Absent`]: `Findings::default()`
/// builds the struct before the one probe fills it.
impl Default for RunLockState {
    fn default() -> Self {
        RunLockState::Absent
    }
}

/// The run lock's state, one derivation for every reader (`-Md`'s report and
/// `--stale-lock-check`): R2-vera-8 found the only lock verb answering about
/// `db.lck` while a run was refused for `locks/run.lock`, so a person with a
/// stale holder had no diagnostic that described the lock actually in the way.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RunLockState {
    /// No lock file: nothing has ever run over this root.
    Absent,
    /// The file exists and nothing holds it.
    Free,
    /// A process holds it; the diagnosis names the recorded pid, whether it
    /// is a live `gsa` run, and the remedy for a genuinely stale lock.
    Held(LockDiagnosis),
}

impl RunLockState {
    /// The status word the two surfaces print for this state.
    pub fn status(&self) -> &'static str {
        match self {
            RunLockState::Absent => "absent",
            RunLockState::Free => "free",
            RunLockState::Held(_) => "held",
        }
    }

    /// Is this a defect a reader must act on? Only a lock held by no live
    /// engine run is: a live holder is the normal state of a busy root, and
    /// a free or absent lock is healthy.
    pub fn is_finding(&self) -> bool {
        matches!(self, RunLockState::Held(d) if !d.live_gsa())
    }

    /// The `-Md` row as `(action, reason)`: a healthy state is `health`
    /// with an `ok …` reason (the doctor's one "this is a statement, not a
    /// finding" shape, shared with `local-db health ok`), and a stale
    /// holder is its own action with the remedy printed.
    pub fn row(&self, path: &Path) -> (&'static str, String) {
        match self {
            RunLockState::Absent => (
                "health",
                format!("ok absent — no lock file at {}", path.display()),
            ),
            RunLockState::Free => ("health", "ok free — no holder".to_string()),
            RunLockState::Held(diagnosis) if diagnosis.live_gsa() => (
                "health",
                format!(
                    "ok held — {} (normal while a run is in flight)",
                    diagnosis.describe()
                ),
            ),
            RunLockState::Held(diagnosis) => (
                "stale-run-lock",
                format!(
                    "{}; clear it: {}",
                    diagnosis.describe(),
                    diagnosis.remedy(path)
                ),
            ),
        }
    }
}

/// Where the §K.3 run lock lives under one state root.
pub fn run_lock_path(state_dir: &Path) -> std::path::PathBuf {
    state_dir.join("locks").join("run.lock")
}

/// Probe the run lock without creating it and without holding it past the
/// call: a read-only surface (`-Md`, `--stale-lock-check`) must be able to
/// ask. A held lock is diagnosed from the file's recorded pid, never from a
/// second flock attempt that would misreport its own conflict.
pub fn run_lock_state(state_dir: &Path) -> RunLockState {
    let path = run_lock_path(state_dir);
    match std::fs::metadata(&path) {
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return RunLockState::Absent;
        }
        // An unreadable lock file is not an absent one (rule 71): the caller
        // sees a state it can report as held-with-unknown-holder rather than
        // a clean root that stands the gate down.
        Err(_) => return RunLockState::Held(unknown_holder()),
    }
    match run_lock_held(state_dir) {
        Some(true) => RunLockState::Held(diagnose_held_lock(&path)),
        Some(false) => RunLockState::Free,
        // Unopenable: reported as held with no visible holder, never free.
        None => RunLockState::Held(unknown_holder()),
    }
}

/// The diagnosis for a lock nothing could be learned about — never rendered
/// as "free", which would stand the gate down on an unreadable file.
fn unknown_holder() -> LockDiagnosis {
    LockDiagnosis {
        holder: LockHolder::Unknown {
            scan_incomplete: true,
        },
    }
}

/// The §K.3 state-root run lock (`<state>/locks/run.lock`), classified for
/// the fallback seam's permission-vs-contended distinction.
pub fn try_acquire_run_lock(state_dir: &Path) -> Result<RunLock, RunLockError> {
    acquire_run_lock_file(&state_dir.join("locks").join("run.lock"), "same state root")
}

/// Acquire the run lock over the state root (contract §K). A busy lock is a
/// refusal naming the holder's lock path — the engine never waits on it and
/// never deletes a held lock file.
pub fn acquire_run_lock(state_dir: &Path) -> Result<RunLock, String> {
    try_acquire_run_lock(state_dir).map_err(|e| e.to_string())
}

/// Classify one gate failure for [`RunLockError`].
fn classify_failure(f: GateFailure) -> RunLockError {
    let message = f.error.to_string();
    match f.kind {
        Some(std::io::ErrorKind::PermissionDenied) => RunLockError::Permission(message),
        _ => RunLockError::Other(message),
    }
}

/// Create the state-root layout this phase owns (§J.1 subset): `logs/`,
/// `locks/`, `runs/`. The default root `/var/lib/gsa` failing to create is
/// an early failure naming `--state-dir` as the remedy (§J.3) — never a
/// silent fallback.
pub fn ensure_state_dirs(state_dir: &Path, err: &mut dyn Write) -> Result<(), String> {
    for sub in ["logs", "locks", "runs"] {
        let dir = state_dir.join(sub);
        std::fs::create_dir_all(&dir).map_err(|e| {
            format!(
                "cannot create state directory {} ({e}) — pass --state-dir PATH or set GSA_STATE_DIR",
                dir.display()
            )
        })?;
    }
    // The run.lock gate is fatal and fd-based (the checked open is the gate;
    // `acquire_run_lock` gates its own open again and keeps that handle).
    let mut opts = OpenOptions::new();
    opts.create(true).truncate(false).write(true);
    open_state_file_with_uid(
        &state_dir.join("locks").join("run.lock"),
        &mut opts,
        current_uid(),
        err,
    )
    .map_err(|e| e.to_string())?;
    Ok(())
}

/// Is a run holding the lock right now? `Some(true)` = held (a live run),
/// `Some(false)` = free, `None` = no lock file to probe (or unreadable).
/// The probe never creates the file, so a read-only surface (`gsa -Mh`) can
/// ask without mutating the state root; flock conflicts across separate open
/// file descriptions, so the answer is exact even within one process.
pub fn run_lock_held(state_dir: &Path) -> Option<bool> {
    let file = std::fs::File::open(state_dir.join("locks").join("run.lock")).ok()?;
    Some(!flock_exclusive_nonblocking(file.as_raw_fd()))
}

/// Startup/post-run orphan sweep (contract §K.3): remove stale run artifacts
/// (`.tmp.*`, abandoned result/park files) from dead runs, and reap
/// `--lane-job` / `--fetch-job` processes of dead runs whose result files
/// are unowned. Unrelated `makepkg` processes are never touched.
///
/// A run that died before it could persist its record (no `run.closed`, but
/// its `run.open` stamp is present) is EVIDENCE, not garbage: its lane
/// markers survive and are stamped `run.died` once, so `gsa -Mh` can still
/// report what was in flight. Only `-Mh --prune` retires those directories.
pub fn sweep_orphans(state_dir: &Path, current_run: &str, err: &mut dyn Write) {
    let runs = state_dir.join("runs");
    let Ok(entries) = std::fs::read_dir(&runs) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if !entry.path().is_dir() {
            continue;
        }
        let own_run = name == current_run;
        let died = !own_run
            && entry.path().join("run.open").exists()
            && !entry.path().join("run.closed").exists();
        let Ok(files) = std::fs::read_dir(entry.path()) else {
            continue;
        };
        for file in files.flatten() {
            let fname = file.file_name().to_string_lossy().into_owned();
            let stale = fname.contains(".tmp.")
                || (!own_run
                    && !died
                    && (fname.ends_with(".result")
                        || fname.ends_with(".park")
                        // lane-state markers (ux) are run-scoped exactly like
                        // results: a dead run's `.started` proves nothing —
                        // unless the run itself died, in which case they are
                        // the only record of what was in flight.
                        || fname.ends_with(".started")
                        // the run's own stamps: a finished run needs neither
                        || fname == "run.open"
                        || fname == "run.closed"));
            if stale {
                let _ = std::fs::remove_file(file.path());
            }
        }
        if died {
            let stamp = entry.path().join("run.died");
            if !stamp.exists() {
                let epoch = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_secs())
                    .unwrap_or(0);
                let _ = std::fs::write(&stamp, format!("epoch={epoch}\n"));
            }
            let _ = writeln!(
                err,
                "gsa: note: run {name} died before it recorded itself; its lane markers are kept under runs/{name} (gsa -Mh reports it, gsa -Mh --prune retires it)"
            );
        } else if !own_run {
            let _ = std::fs::remove_dir(entry.path()); // only when empty
        }
    }
    reap_dead_run_lanes(state_dir, err);
}

/// Reap `--lane-job` processes from earlier runs whose result files are
/// unowned: a lane whose parent is gone (reparented) is an orphan and its
/// process group is killed. Identification is by `/proc/<pid>/cmdline` plus
/// the result-path argument; `makepkg` processes themselves are never named.
fn reap_dead_run_lanes(state_dir: &Path, err: &mut dyn Write) {
    let state_prefix = state_dir.to_string_lossy().into_owned();
    let Ok(proc_dir) = std::fs::read_dir("/proc") else {
        return;
    };
    for entry in proc_dir.flatten() {
        let pid: i32 = match entry.file_name().to_string_lossy().parse() {
            Ok(pid) => pid,
            Err(_) => continue,
        };
        if pid == std::process::id() as i32 {
            continue;
        }
        let cmdline = match std::fs::read(format!("/proc/{pid}/cmdline")) {
            Ok(bytes) => bytes
                .split(|b| *b == 0)
                .filter(|s| !s.is_empty())
                .map(|s| String::from_utf8_lossy(s).into_owned())
                .collect::<Vec<_>>(),
            Err(_) => continue,
        };
        if !cmdline
            .iter()
            .any(|a| a == "--lane-job" || a == "--fetch-job")
        {
            continue;
        }
        let in_state = cmdline
            .iter()
            .skip(2)
            .any(|a| arg_in_state(a, &state_prefix));
        if !in_state {
            continue;
        }
        // Orphan check: the parent is pid 1 (or absent).
        let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).unwrap_or_default();
        let Some((ppid, pgid)) = orphan_ppid_pgid(&stat, pid) else {
            continue;
        };
        if ppid == 1 || ppid == 0 {
            let _ = writeln!(
                err,
                "gsa: note: sweeping orphan lane process {pid} (process group {pgid})"
            );
            send_signal(-pgid, SIGKILL);
        }
    }
}

/// Does one argv item belong to the state root? Whole path components only:
/// `/var/lib/gsa-alt` merely SHARES the name prefix of `/var/lib/gsa` and is
/// a different state root — prefix matching let a concurrent run's live
/// lane be swept.
pub fn arg_in_state(arg: &str, state_root: &str) -> bool {
    let root = state_root.trim_end_matches('/');
    if root.is_empty() {
        return arg.starts_with('/');
    }
    arg == root || arg.starts_with(&format!("{root}/"))
}

/// The `(ppid, pgid)` pair of one `/proc/<pid>/stat` line (the `pid` stands
/// in for an unreadable process group). `None` = the ppid is UNKNOWN — a
/// parse failure is never evidence of orphanhood, and an unknown pid is
/// never touched.
pub fn orphan_ppid_pgid(stat_line: &str, pid: i32) -> Option<(i32, i32)> {
    // The comm field is parenthesised and may itself carry `)` — the ppid
    // arrives only after the LAST one.
    let after = stat_line.rsplit_once(')').map(|(_, rest)| rest)?;
    let mut fields = after.split_whitespace();
    fields.next()?; // state
    let ppid: i32 = fields.next()?.parse().ok()?;
    let pgid: i32 = fields
        .next()
        .map(str::parse)
        .and_then(Result::ok)
        .unwrap_or(pid);
    Some((ppid, pgid))
}

/// `--stale-lock-check` (contract §D.1): the production lock probe without a
/// run — BOTH locks a run must take. `db.lck` presence and its holders
/// (identified by an open-file-descriptor scan over `/proc/*/fd`) come first
/// and stay byte-identical; the §K.3 run lock follows as `run-lock:` /
/// `run-status:` / `run-holder:`, from the same derivation `-Md` prints
/// (R2-vera-8: the verb answered `db.lck status: free` while a run was
/// refused for `locks/run.lock`). Never deletes either file. Report-only on
/// the lock report itself (rc 0); the db-root resolution failing loudly is
/// rc 1 (a report on a silently guessed root is worse than no report), and an
/// unreachable run lock (no resolvable state root) is rc 1 for the same
/// reason.
pub fn pacman_lock_probe(out: &mut dyn Write, err: &mut dyn Write) -> i32 {
    let db_rc = db_lock_probe(out, err);
    // The run lock's half follows the db.lck rows (byte-identical above) and
    // never changes the db.lck verdict: each lock reports its own state.
    let run_rc = run_lock_probe(out, err);
    db_rc.max(run_rc)
}

/// The `db.lck` half of the probe: presence, holders, and the never-delete
/// note, unchanged from the pre-R2-vera-8 behaviour.
fn db_lock_probe(out: &mut dyn Write, err: &mut dyn Write) -> i32 {
    let (db_path, fallback) = match pacman_db_path() {
        Ok(resolved) => resolved,
        Err(message) => {
            let _ = writeln!(err, "gsa: cannot resolve pacman's DBPath: {message}");
            let _ = writeln!(out, "db-path: unresolved");
            return 1;
        }
    };
    if let Some(note) = fallback {
        let _ = writeln!(err, "gsa: note: {note}");
        let _ = writeln!(
            out,
            "db-path: {} (fallback: pacman-conf is missing — not established)",
            db_path.display()
        );
    } else {
        let _ = writeln!(out, "db-path: {}", db_path.display());
    }
    let lock_path = db_path.join("db.lck");
    let _ = writeln!(out, "lock: {}", lock_path.display());
    let meta = match std::fs::metadata(&lock_path) {
        Ok(meta) => meta,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            let _ = writeln!(out, "status: free");
            return 0;
        }
        Err(error) => {
            let _ = writeln!(err, "gsa: cannot stat {}: {error}", lock_path.display());
            let _ = writeln!(out, "status: unreadable");
            return 1;
        }
    };
    // The same fd scan the run lock's diagnosis uses: `db.lck`'s holder rows
    // and a refused run lock are identified by one piece of evidence.
    let holders = fd_holders(meta.ino(), meta.dev());
    if let Some(error) = &holders.proc_unreadable {
        let _ = writeln!(err, "gsa: cannot read /proc: {error}");
    }
    let skipped_fds = holders.skipped;
    let proc_unreadable = holders.proc_unreadable.is_some();
    let rc = if !holders.pids.is_empty() {
        let _ = writeln!(out, "status: held");
        for (pid, cmdline, _) in holders.pids {
            let _ = writeln!(out, "holder: {pid} {cmdline}");
        }
        0
    } else if proc_unreadable || (skipped_fds > 0 && crate::signals::current_uid() == 0) {
        let _ = writeln!(
            out,
            "status: unprobed (insufficient permissions to inspect /proc/*/fd)"
        );
        1
    } else if skipped_fds > 0 {
        let _ = writeln!(
            err,
            "gsa: note: skipped {skipped_fds} unreadable /proc/*/fd entries (not privileged to inspect foreign processes)"
        );
        let _ = writeln!(
            out,
            "status: present-idle (no visible open holder; {skipped_fds} foreign /proc/*/fd skipped)"
        );
        0
    } else {
        let _ = writeln!(out, "status: present-idle (no open holder)");
        0
    };
    let _ = writeln!(err, "gsa: note: db.lck is never deleted by gsa");
    rc
}

/// The `locks/run.lock` half of `--stale-lock-check`: the state root the
/// engine would use, and the lock a `-S`/`-B`/`-U` run must take. Reads only
/// (never creates, never deletes); rc 1 when the state root cannot be
/// resolved, because a report on a guessed root is worse than no report —
/// the same policy the db-root half follows.
fn run_lock_probe(out: &mut dyn Write, err: &mut dyn Write) -> i32 {
    let state_dir = match gsa_model::config::resolve_state_dir(None) {
        Ok(dir) => dir,
        Err(message) => {
            let _ = writeln!(err, "gsa: cannot resolve the state root: {message}");
            let _ = writeln!(out, "run-lock: unresolved");
            return 1;
        }
    };
    let path = run_lock_path(&state_dir);
    let state = run_lock_state(&state_dir);
    let _ = writeln!(out, "run-lock: {}", path.display());
    let _ = writeln!(out, "run-status: {}", state.status());
    if let RunLockState::Held(diagnosis) = &state {
        match diagnosis.pid() {
            Some(pid) => {
                let _ = writeln!(out, "run-holder: {pid} gsa={}", diagnosis.live_gsa());
            }
            None => {
                let _ = writeln!(out, "run-holder: none recorded");
            }
        }
        let _ = writeln!(err, "gsa: note: {}", diagnosis.describe());
        let _ = writeln!(err, "gsa: note: to clear it: {}", diagnosis.remedy(&path));
    }
    let _ = writeln!(
        err,
        "gsa: note: the run lock is never deleted by gsa while it is held"
    );
    0
}

/// Resolve pacman's database root the way makepkg does: `pacman-conf
/// DBPath`. A `pacman-conf` that exists but errors (or answers empty) is a
/// hard failure — the probe must never report on a silently guessed db
/// root. A MISSING tool cannot answer: the built-in `/var/lib/pacman` stands
/// in, but only loudly — the note rides along for the caller to print, so
/// the guess is never silent for a probe that reports on it.
fn pacman_db_path() -> Result<(PathBuf, Option<String>), String> {
    match std::process::Command::new("pacman-conf").arg("DBPath").output() {
        Ok(output) if output.status.success() => {
            let text = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if text.is_empty() {
                return Err("pacman-conf DBPath answered with an empty path".to_string());
            }
            Ok((PathBuf::from(text), None))
        }
        Ok(output) => Err(format!(
            "pacman-conf DBPath failed ({}): {}",
            output.status,
            String::from_utf8_lossy(&output.stderr).trim()
        )),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok((
            PathBuf::from("/var/lib/pacman"),
            Some(
                "pacman-conf is missing: falling back to the built-in default /var/lib/pacman, which may not be pacman's real DBPath"
                    .to_string(),
            ),
        )),
        Err(error) => Err(format!("cannot run pacman-conf: {error}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// PATH-mutating tests serialize: the probe resolves `pacman-conf`
    /// through the process-global PATH.
    static PATH_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("gsa-lock-test-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn run_lock_excludes_a_second_holder() {
        let dir = scratch("lock");
        let lock = acquire_run_lock(&dir).expect("first lock");
        let err = Vec::new();
        let mut err = err;
        ensure_state_dirs(&dir, &mut err).unwrap();
        // A second flock on the same file through a new fd must fail: the
        // kernel's flock is per-open-file-description.
        let file = OpenOptions::new()
            .create(true)
            .write(true)
            .open(dir.join("locks").join("run.lock"))
            .unwrap();
        assert!(!flock_exclusive_nonblocking(file.as_raw_fd()));
        drop(lock);
        // The flock releases when the last fd of that open file description
        // closes. A child forked by a concurrent test thread (this test
        // binary shares its process across tests) transiently inherits the
        // fd until its exec, so the release can land a few microseconds
        // after `drop`; a bounded settle window keeps the test about the
        // lock's semantics (released on drop) instead of that fork race.
        let mut released = false;
        for _ in 0..200 {
            if flock_exclusive_nonblocking(file.as_raw_fd()) {
                released = true;
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        assert!(
            released,
            "the run lock must release when the RunLock is dropped"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn stale_artifacts_are_swept_and_final_names_survive_their_run() {
        let dir = scratch("sweep");
        let runs = dir.join("runs");
        let dead = runs.join("111-1");
        let own = runs.join("222-2");
        std::fs::create_dir_all(&dead).unwrap();
        std::fs::create_dir_all(&own).unwrap();
        std::fs::write(dead.join("a.result"), "v2 a 0 1 ok\n").unwrap();
        std::fs::write(dead.join("b.result.tmp.9"), "partial").unwrap();
        std::fs::write(own.join("c.result.tmp.9"), "partial").unwrap();
        std::fs::write(own.join("c.result"), "v2 c 0 1 ok\n").unwrap();
        let mut err = Vec::new();
        sweep_orphans(&dir, "222-2", &mut err);
        assert!(!dead.join("a.result").exists(), "dead run's results swept");
        assert!(!dead.join("b.result.tmp.9").exists());
        assert!(!own.join("c.result.tmp.9").exists(), "stale temp swept");
        assert!(
            own.join("c.result").exists(),
            "current run's result survives"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_died_run_keeps_its_markers_and_a_finished_one_is_swept() {
        let dir = scratch("sweep-died");
        let runs = dir.join("runs");
        let died = runs.join("111-1");
        let finished = runs.join("222-2");
        let own = runs.join("333-3");
        for run in [&died, &finished, &own] {
            std::fs::create_dir_all(run).unwrap();
        }
        // 111-1 died: opened, never closed.
        std::fs::write(died.join("run.open"), "pid=1 epoch=5\n").unwrap();
        std::fs::write(died.join("a.started"), "pid=9 epoch=5 log-offset=0\n").unwrap();
        std::fs::write(died.join("a.result"), "v2 a 0 1 ok\n").unwrap();
        // 222-2 finished and recorded itself.
        std::fs::write(finished.join("run.open"), "pid=2 epoch=5\n").unwrap();
        std::fs::write(finished.join("run.closed"), "epoch=6\n").unwrap();
        std::fs::write(finished.join("a.result"), "v2 a 0 1 ok\n").unwrap();
        let mut err = Vec::new();
        sweep_orphans(&dir, "333-3", &mut err);
        assert!(
            died.join("a.result").exists() && died.join("a.started").exists(),
            "a died run's markers are evidence and must survive the sweep"
        );
        assert!(died.join("run.died").exists(), "the sweep dates the death");
        assert!(
            !finished.join("a.result").exists() && !finished.exists(),
            "a finished run's markers are swept exactly as before"
        );
        assert!(
            String::from_utf8_lossy(&err).contains("run 111-1 died"),
            "the sweep says which run it kept and why: {}",
            String::from_utf8_lossy(&err)
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn lock_probe_never_deletes_the_lock_file() {
        let _guard = PATH_TEST_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let dir = scratch("probe");
        let lock = dir.join("db.lck");
        std::fs::write(&lock, "").unwrap();
        // Route the probe at the scratch db by shadowing pacman-conf.
        let bin = dir.join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        let stub = bin.join("pacman-conf");
        std::fs::write(&stub, format!("#!/bin/sh\necho '{}'\n", dir.display())).unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o755)).unwrap();
        let path = std::env::var("PATH").unwrap_or_default();
        std::env::set_var("PATH", format!("{}:{}", bin.display(), path));
        let mut out = Vec::new();
        let mut err = Vec::new();
        let rc = pacman_lock_probe(&mut out, &mut err);
        std::env::set_var("PATH", path);
        assert_eq!(rc, 0);
        let text = String::from_utf8_lossy(&out).into_owned();
        assert!(text.contains("lock:"), "{text}");
        assert!(lock.exists(), "the probe must never delete db.lck");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_stale_lock_names_its_recorded_pid_and_the_exact_remedy() {
        let dir = scratch("stale-lock");
        std::fs::create_dir_all(dir.join("locks")).unwrap();
        let path = run_lock_path(&dir);
        // R2-vera-8's repro: a plain `flock` holds the file and no engine run
        // ever wrote a pid, so the refusal had no identity to report.
        std::fs::write(&path, "").unwrap();
        let empty = diagnose_held_lock(&path);
        assert_eq!(empty.pid(), None);
        assert!(!empty.live_gsa());
        assert!(
            empty.describe().contains("no holder pid"),
            "an empty lock file must be named as such: {}",
            empty.describe()
        );
        assert_eq!(
            empty.remedy(&path),
            format!("rm {}", path.display()),
            "the remedy is the exact command, printed"
        );

        // A pid nothing owns is equally stale, and names its offender.
        std::fs::write(&path, "999999999\n").unwrap();
        let dead = diagnose_held_lock(&path);
        assert_eq!(dead.pid(), Some(999_999_999));
        assert!(!dead.live_gsa(), "an absent pid is not a live gsa run");
        assert!(
            dead.describe().contains("999999999"),
            "a recorded pid is named: {}",
            dead.describe()
        );
        assert_eq!(dead.remedy(&path), format!("rm {}", path.display()));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_live_gsa_holder_is_recognized_and_the_remedy_is_to_wait() {
        let dir = scratch("live-lock");
        std::fs::create_dir_all(dir.join("locks")).unwrap();
        let path = run_lock_path(&dir);
        std::fs::write(&path, "").unwrap();
        // `exec -a gsa` gives the child argv[0] = "gsa" without needing a
        // copy of this binary: the liveness test reads the command line, so
        // whatever the executable is, the argv0 basename is the evidence.
        let mut child = std::process::Command::new("bash")
            .args(["-c", "exec -a gsa sleep 5"])
            .spawn()
            .expect("spawn the gsa-shaped holder");
        let pid = child.id();
        std::fs::write(&path, format!("{pid}\n")).unwrap();
        let mut diagnosis = diagnose_held_lock(&path);
        for _ in 0..100 {
            if diagnosis.live_gsa() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
            diagnosis = diagnose_held_lock(&path);
        }
        assert!(
            diagnosis.live_gsa(),
            "a live process whose argv[0] basename is gsa holds it: {diagnosis:?}"
        );
        assert!(diagnosis.describe().contains("live gsa run"));
        assert!(
            diagnosis
                .remedy(&path)
                .starts_with("let the run holding it finish"),
            "a live holder is never told to delete its lock: {}",
            diagnosis.remedy(&path)
        );
        let _ = child.kill();
        let _ = child.wait();
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn acquiring_truncates_a_longer_stale_pid() {
        let dir = scratch("pid-truncate");
        std::fs::create_dir_all(dir.join("locks")).unwrap();
        let path = run_lock_path(&dir);
        // A previous holder with a longer pid must not survive the overwrite:
        // "1234567" + this pid would read as one longer, wrong number.
        std::fs::write(&path, "999999999\n").unwrap();
        let lock = acquire_run_lock_file(&path, "test root").expect("acquire");
        let recorded: u32 = std::fs::read_to_string(&path)
            .expect("read back")
            .trim()
            .parse()
            .expect("the file holds exactly one pid");
        assert_eq!(recorded, std::process::id());
        drop(lock);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn run_lock_state_distinguishes_absent_free_and_held() {
        let dir = scratch("run-state");
        assert_eq!(run_lock_state(&dir), RunLockState::Absent);
        assert_eq!(run_lock_state(&dir).status(), "absent");
        std::fs::create_dir_all(dir.join("locks")).unwrap();
        std::fs::write(run_lock_path(&dir), "").unwrap();
        assert_eq!(run_lock_state(&dir), RunLockState::Free);
        assert!(run_lock_state(&dir)
            .row(&run_lock_path(&dir))
            .1
            .contains("no holder"));
        // A hold through a separate open file description IS the conflict the
        // kernel reports, so the same process can probe its own hold.
        let lock = acquire_run_lock_file(&run_lock_path(&dir), "test root").expect("acquire");
        let held = run_lock_state(&dir);
        assert_eq!(held.status(), "held");
        assert!(held.is_finding(), "a non-gsa hold is a finding");
        drop(lock);
        assert_eq!(run_lock_state(&dir), RunLockState::Free);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn orphan_ppid_pgid_is_none_when_the_ppid_cannot_be_read() {
        // A healthy stat line answers (ppid, pgid).
        assert_eq!(
            orphan_ppid_pgid("42 (gsa --lane-job) S 1 77 77 0 -1 0 0", 42),
            Some((1, 77))
        );
        // The ppid may arrive only after the last `)` — comm may itself
        // carry parentheses.
        assert_eq!(
            orphan_ppid_pgid("42 (a)b) S 3 88 88 0 -1 0 0", 42),
            Some((3, 88))
        );
        // An unparseable ppid is UNKNOWN — never an orphan to SIGKILL.
        assert_eq!(
            orphan_ppid_pgid("", 42),
            None,
            "an unreadable /proc stat line is UNKNOWN, never ppid 0"
        );
        assert_eq!(orphan_ppid_pgid("42 (x) S", 42), None);
        assert_eq!(orphan_ppid_pgid("42 (x) S junk 5 5", 42), None);
    }

    #[test]
    fn state_matching_is_whole_path_components() {
        assert!(arg_in_state("/var/lib/gsa/runs/1/x.result", "/var/lib/gsa"));
        assert!(arg_in_state("/var/lib/gsa", "/var/lib/gsa"));
        assert!(arg_in_state("/var/lib/gsa/runs/x", "/var/lib/gsa/"));
        // A sibling state root that merely SHARES the name prefix is not
        // inside it — prefix matching let a concurrent run's live lane be
        // swept.
        assert!(!arg_in_state(
            "/var/lib/gsa-alt/runs/1/x.result",
            "/var/lib/gsa"
        ));
        assert!(!arg_in_state("/var/lib/gsa-extra", "/var/lib/gsa"));
    }

    fn shadow_pacman_conf(dir: &Path, body: &str) -> String {
        let bin = dir.join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        let stub = bin.join("pacman-conf");
        std::fs::write(&stub, body).unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o755)).unwrap();
        let path = std::env::var("PATH").unwrap_or_default();
        std::env::set_var("PATH", format!("{}:{}", bin.display(), path));
        path
    }

    #[test]
    fn lock_probe_fails_loud_when_pacman_conf_errors() {
        let _guard = PATH_TEST_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let dir = scratch("conf-err");
        let path = shadow_pacman_conf(&dir, "#!/bin/sh\necho boom >&2\nexit 3\n");
        let mut out = Vec::new();
        let mut err = Vec::new();
        let rc = pacman_lock_probe(&mut out, &mut err);
        std::env::set_var("PATH", path);
        assert_ne!(
            rc, 0,
            "a pacman-conf that exists but errors must fail loud, never silently mean /var/lib/pacman"
        );
        let text = String::from_utf8_lossy(&err).into_owned();
        assert!(text.contains("DBPath"), "{text}");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn lock_probe_announces_the_fallback_when_pacman_conf_is_missing() {
        let _guard = PATH_TEST_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let dir = scratch("conf-missing");
        let bin = dir.join("bin");
        std::fs::create_dir_all(&bin).unwrap();
        let path = std::env::var("PATH").unwrap_or_default();
        // No pacman-conf anywhere on PATH.
        std::env::set_var("PATH", bin.display().to_string());
        let mut out = Vec::new();
        let mut err = Vec::new();
        let rc = pacman_lock_probe(&mut out, &mut err);
        std::env::set_var("PATH", path);
        assert_eq!(rc, 0, "the lock report itself is report-only (§D.1)");
        let text = String::from_utf8_lossy(&err).into_owned();
        assert!(
            text.contains("pacman-conf"),
            "a missing pacman-conf must be announced: {text}"
        );
        let out = String::from_utf8_lossy(&out).into_owned();
        assert!(
            out.contains("fallback"),
            "the report must mark the guessed db root as a fallback: {out}"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn lock_probe_reports_non_notfound_stat_error_instead_of_free() {
        let _guard = PATH_TEST_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let dir = scratch("stat-err");
        let not_a_dir = dir.join("not-a-dir");
        std::fs::write(&not_a_dir, "file").unwrap();
        let saved_path = std::env::var("PATH").unwrap_or_default();
        let path = shadow_pacman_conf(
            &dir,
            &format!("#!/bin/sh\necho '{}'\n", not_a_dir.display()),
        );
        let mut out = Vec::new();
        let mut err = Vec::new();
        let rc = pacman_lock_probe(&mut out, &mut err);
        std::env::set_var("PATH", path);
        assert_ne!(
            rc, 0,
            "ENOTDIR on db.lck must fail instead of returning 0/free"
        );
        let out_str = String::from_utf8_lossy(&out);
        // The db.lck verdict is the whole `status:` LINE: the run-lock half
        // prints its own `run-status:` key, so a substring match on
        // `status: free` would read the second lock's answer as this one's.
        assert!(
            !out_str.lines().any(|line| line == "status: free"),
            "ENOTDIR must never misreport status: free: {out_str}"
        );
        std::env::set_var("PATH", saved_path);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
