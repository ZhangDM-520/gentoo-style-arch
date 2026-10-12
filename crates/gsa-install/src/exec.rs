//! The transaction executor (contract §K.3): exactly one `pacman -U`
//! subprocess at a time, `sudo -n` only — the engine never prompts.
//!
//! Discipline: `pacman -U --noconfirm --ask 4 [pacman args…] <archives…>`
//! under the state-root mutex (`gsa_build::shim::mutex_path`), the same lock
//! the PACMAN shim serializes makepkg's own transactions on. The system
//! `db.lck` is NEVER deleted (rule 23) — idleness is proven by an
//! open-file-descriptor scan, never by filenames.

use std::fs::{File, OpenOptions};
use std::os::unix::io::AsRawFd;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

/// One install transaction's inputs.
#[derive(Clone, Debug)]
pub struct TxnRequest {
    /// State root: `<state>/locks/pacman-mutex` serializes transactions.
    pub state_dir: PathBuf,
    /// Target pacman.conf (`--config`), passed to the subprocess when set.
    pub conf: Option<PathBuf>,
    /// The archives to install (decision rows with `install` only).
    pub archives: Vec<PathBuf>,
    /// Trailing `-- <pacman args…>`, forwarded verbatim before the archives
    /// (today's `-ia --overwrite '*'` idiom).
    pub pacman_args: Vec<String>,
}

/// The outcome vocabulary of one transaction attempt.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TxnOutcome {
    /// The transaction ran and pacman exited 0.
    Ok,
    /// pacman exited non-zero (or could not run). `rc` is pacman's exit
    /// status (or -1 on spawn failure); `message` names what stopped.
    Failed { rc: i32, message: String },
    /// The state-root mutex did not clear inside the bounded wait.
    MutexTimeout,
    /// `sudo -n` failed mid-run: the credential is gone and cannot be
    /// refreshed without prompting (§K.3) — dispatch stops exactly once.
    SudoLost,
}

extern "C" {
    fn flock(fd: i32, op: i32) -> i32;
}

const LOCK_EX: i32 = 2;
const LOCK_NB: i32 = 4;

/// Exclusive flock on the state-root mutex (the same lock the PACMAN shim
/// serializes makepkg's own transactions on), bounded wait like the shim's
/// `flock -w 600`. The file handle IS the guard: the lock releases on drop.
fn acquire_mutex(path: &Path, timeout: Duration) -> Option<File> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).ok()?;
    }
    // Never truncate a possibly-held lock inode (rule 19's exception).
    let file = OpenOptions::new()
        .create(true)
        .write(true)
        .open(path)
        .ok()?;
    let deadline = Instant::now() + timeout;
    loop {
        let rc = unsafe { flock(file.as_raw_fd(), LOCK_EX | LOCK_NB) };
        if rc == 0 {
            return Some(file);
        }
        if Instant::now() >= deadline {
            return None;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

/// Preflight (§K.3): a `-S`/`-U` run whose installs cannot succeed
/// non-interactively refuses BEFORE building starts (rc 3,
/// `sudo cannot install non-interactively`). Proven with `sudo -n true` —
/// never `sudo -v` (a NOPASSWD entry makes `-v` fail while every install
/// succeeds, `docs/MEMORY.md` rule 11).
pub fn preflight_installs() -> Result<(), String> {
    let output = Command::new("sudo")
        .args(["-n", "true"])
        .output()
        .map_err(|e| format!("sudo cannot install non-interactively ({e})"))?;
    if output.status.success() {
        Ok(())
    } else {
        Err("sudo cannot install non-interactively".to_string())
    }
}

/// Run the ONE `pacman -U` transaction for this call, serialized through the
/// state-root mutex. `-S` runs call this once per built package (an install
/// transaction per package, install-before-dependents); `-U` runs once.
pub fn execute_txn(req: &TxnRequest) -> TxnOutcome {
    let mutex_path = gsa_build::shim::mutex_path(&req.state_dir);
    let _guard = match acquire_mutex(&mutex_path, Duration::from_secs(600)) {
        Some(file) => file,
        None => return TxnOutcome::MutexTimeout,
    };

    let mut cmd = Command::new("sudo");
    cmd.arg("-n")
        .arg("pacman")
        .arg("-U")
        .arg("--noconfirm")
        .arg("--ask")
        .arg("4");
    if let Some(conf) = &req.conf {
        cmd.arg("--config").arg(conf);
    }
    for arg in &req.pacman_args {
        cmd.arg(arg);
    }
    for archive in &req.archives {
        cmd.arg(archive);
    }
    match cmd.output() {
        Err(e) => {
            if e.kind() == std::io::ErrorKind::PermissionDenied {
                TxnOutcome::SudoLost
            } else {
                TxnOutcome::Failed {
                    rc: -1,
                    message: format!("cannot run the install transaction: {e}"),
                }
            }
        }
        Ok(output) => {
            let rc = output.status.code().unwrap_or(-1);
            if rc == 0 {
                return TxnOutcome::Ok;
            }
            let stdout = String::from_utf8_lossy(&output.stdout);
            let stderr = String::from_utf8_lossy(&output.stderr);
            let lower = stderr.to_lowercase();
            // The credential is gone and cannot be refreshed without
            // prompting: sudo says so, or sudo failed with rc 1 and pacman
            // never spoke (§K.3 — the engine never prompts).
            if lower.contains("password")
                || lower.contains("prompt")
                || lower.contains("no tty")
                || lower.contains("a terminal is required")
            {
                return TxnOutcome::SudoLost;
            }
            if rc == 1 && stdout.trim().is_empty() && stderr.trim().is_empty() {
                return TxnOutcome::SudoLost;
            }
            let message = stderr
                .lines()
                .rev()
                .find(|l| !l.trim().is_empty())
                .map(|l| l.trim().to_string())
                .filter(|l| !l.is_empty())
                .unwrap_or_else(|| "pacman -U failed".to_string());
            TxnOutcome::Failed { rc, message }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mutex_serializes_and_releases() {
        let dir = std::env::temp_dir().join(format!("gsa-exec-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = gsa_build::shim::mutex_path(&dir);
        let guard = acquire_mutex(&path, Duration::from_millis(100)).expect("first lock");
        assert!(
            acquire_mutex(&path, Duration::from_millis(100)).is_none(),
            "a second exclusive flock must time out"
        );
        drop(guard);
        let mut released = false;
        for _ in 0..100 {
            if let Some(g) = acquire_mutex(&path, Duration::from_millis(20)) {
                drop(g);
                released = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(released, "the mutex releases when the guard drops");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
