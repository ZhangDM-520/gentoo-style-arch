//! Run lock, write-time ownership, and orphan sweeps (contract §J.5, §K).
//!
//! - The run lock is an `flock(2)` on `<state>/locks/run.lock`: one engine run
//!   at a time over one state root. A held lock is a refusal, never a wait.
//! - Write-time ownership (rule 19): every state file is owned by the build
//!   user from the moment it is created; a file owned by someone else is
//!   quarantined as `<path>.stale.<epoch>.<pid>` (preserved, announced) or the
//!   write fails naming the remedy. There is no root fallback.
//! - Orphan sweeps: startup and post-run sweeps reap `--lane-job` children of
//!   dead runs and stale run artifacts (`.tmp.*`, abandoned result files).
//!   Unrelated `makepkg` processes are never touched (§K.3).
//! - `--stale-lock-check` is the production pacman-lock probe without a run:
//!   holder identification via `/proc/*/fd`, never `db.lck` deletion.

use std::fs::{File, OpenOptions};
use std::io::Write;
use std::os::fd::AsRawFd;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

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

/// Acquire the run lock over the state root (contract §K). A busy lock is a
/// refusal naming the holder's lock path — the engine never waits on it and
/// never deletes a held lock file.
pub fn acquire_run_lock(state_dir: &Path) -> Result<RunLock, String> {
    let locks = state_dir.join("locks");
    std::fs::create_dir_all(&locks)
        .map_err(|e| format!("cannot create {}: {e}", locks.display()))?;
    let path = locks.join("run.lock");
    let file = OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .open(&path)
        .map_err(|e| format!("cannot open run lock {}: {e}", path.display()))?;
    if !flock_exclusive_nonblocking(file.as_raw_fd()) {
        return Err(format!(
            "another gsa run holds {} (a second run over the same state root is refused)",
            path.display()
        ));
    }
    let _ = writeln!(&mut { &file }, "{}", std::process::id());
    Ok(RunLock { file, path })
}

/// Quarantine a wrong-owner state file as `<path>.stale.<epoch>.<pid>`
/// (preserved, announced) — rule 19's unprivileged remedy. Returns Ok(true)
/// when a file was quarantined.
pub fn quarantine_foreign(path: &Path, err: &mut dyn Write) -> Result<bool, String> {
    let epoch = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let stale = PathBuf::from(format!(
        "{}.stale.{}.{}",
        path.display(),
        epoch,
        std::process::id()
    ));
    std::fs::rename(path, &stale).map_err(|e| {
        format!(
            "state file {} is not owned by the build user and cannot be quarantined ({e}) — move it aside by hand",
            path.display()
        )
    })?;
    let _ = writeln!(
        err,
        "gsa: note: quarantined foreign-owned state file {} -> {}",
        path.display(),
        stale.display()
    );
    Ok(true)
}

/// The write-time ownership gate (rule 19): before opening a state file for
/// write, a wrong owner is repaired loudly. A create failure names the
/// remedy (`--state-dir`).
pub fn ownership_gate(path: &Path, err: &mut dyn Write) -> Result<(), String> {
    if let Ok(meta) = std::fs::metadata(path) {
        if meta.uid() != current_uid() {
            quarantine_foreign(path, err)?;
        }
    }
    Ok(())
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
    ownership_gate(&state_dir.join("locks").join("run.lock"), err)?;
    Ok(())
}

/// Startup/post-run orphan sweep (contract §K.3): remove stale run artifacts
/// (`.tmp.*`, abandoned result/park files) from dead runs, and reap
/// `--lane-job` processes of dead runs whose result files are unowned.
/// Unrelated `makepkg` processes are never touched.
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
        let Ok(files) = std::fs::read_dir(entry.path()) else {
            continue;
        };
        for file in files.flatten() {
            let fname = file.file_name().to_string_lossy().into_owned();
            let stale = fname.contains(".tmp.")
                || (!own_run && (fname.ends_with(".result") || fname.ends_with(".park")));
            if stale {
                let _ = std::fs::remove_file(file.path());
            }
        }
        if !own_run {
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
        if !cmdline.iter().any(|a| a == "--lane-job") {
            continue;
        }
        let in_state = cmdline.iter().skip(2).any(|a| a.starts_with(&state_prefix));
        if !in_state {
            continue;
        }
        // Orphan check: the parent is pid 1 (or absent).
        let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).unwrap_or_default();
        let after = stat.rsplit_once(')').map(|(_, rest)| rest).unwrap_or("");
        let ppid: i32 = after
            .split_whitespace()
            .nth(1)
            .and_then(|s| s.parse().ok())
            .unwrap_or(0);
        let pgid: i32 = after
            .split_whitespace()
            .nth(2)
            .and_then(|s| s.parse().ok())
            .unwrap_or(pid);
        if ppid == 1 || ppid == 0 {
            let _ = writeln!(
                err,
                "gsa: note: sweeping orphan lane process {pid} (process group {pgid})"
            );
            send_signal(-pgid, SIGKILL);
        }
    }
}

/// `--stale-lock-check` (contract §D.1): the production pacman-lock probe
/// without a run. Reports `db.lck` presence and identifies any holder by an
/// open-file-descriptor scan over `/proc/*/fd` — never by filename heuristics,
/// never by deleting `db.lck`. Report-only: rc 0.
pub fn pacman_lock_probe(out: &mut dyn Write, err: &mut dyn Write) -> i32 {
    let db_path = pacman_db_path();
    let lock_path = db_path.join("db.lck");
    let _ = writeln!(out, "db-path: {}", db_path.display());
    let _ = writeln!(out, "lock: {}", lock_path.display());
    let Ok(meta) = std::fs::metadata(&lock_path) else {
        let _ = writeln!(out, "status: free");
        return 0;
    };
    let ino = meta.ino();
    let dev = meta.dev();
    let mut holders: Vec<(i32, String)> = Vec::new();
    if let Ok(proc_dir) = std::fs::read_dir("/proc") {
        for entry in proc_dir.flatten() {
            let pid: i32 = match entry.file_name().to_string_lossy().parse() {
                Ok(pid) => pid,
                Err(_) => continue,
            };
            let Ok(fds) = std::fs::read_dir(format!("/proc/{pid}/fd")) else {
                continue;
            };
            for fd in fds.flatten() {
                let Ok(target) = std::fs::metadata(fd.path()) else {
                    continue;
                };
                if target.ino() == ino && target.dev() == dev {
                    let cmdline = std::fs::read_to_string(format!("/proc/{pid}/cmdline"))
                        .unwrap_or_default()
                        .replace('\0', " ");
                    holders.push((pid, cmdline.trim().to_string()));
                    break;
                }
            }
        }
    }
    if holders.is_empty() {
        let _ = writeln!(out, "status: present-idle (no open holder)");
    } else {
        let _ = writeln!(out, "status: held");
        for (pid, cmdline) in holders {
            let _ = writeln!(out, "holder: {pid} {cmdline}");
        }
    }
    let _ = writeln!(err, "gsa: note: db.lck is never deleted by gsa");
    0
}

/// Resolve pacman's database root the way makepkg does: `pacman-conf DBPath`,
/// falling back to `/var/lib/pacman` when the tool is missing or silent.
fn pacman_db_path() -> PathBuf {
    if let Ok(output) = std::process::Command::new("pacman-conf")
        .arg("DBPath")
        .output()
    {
        if output.status.success() {
            let text = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !text.is_empty() {
                return PathBuf::from(text);
            }
        }
    }
    PathBuf::from("/var/lib/pacman")
}

#[cfg(test)]
mod tests {
    use super::*;

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
    fn lock_probe_never_deletes_the_lock_file() {
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
}
