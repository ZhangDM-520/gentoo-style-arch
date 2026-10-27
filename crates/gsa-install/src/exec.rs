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
    /// In-run repair targets (rule 25(d)): `(consumer, provider)` pairs
    /// whose forced-rebuild markers the transaction stages BEFORE pacman
    /// runs (§E.3 gap-G1) — fail-closed, nothing mutated on failure.
    pub repairs: Vec<(String, String)>,
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

/// The preflight's `sudo -n true` (one builder per sudo spawn, so the
/// C-locale pin lives in exactly one place each). `LC_ALL=C` makes sudo's
/// own diagnostics C-locale by construction — the `SudoLost` match in
/// [`sudo_credential_lost`] then sees stable English on any host.
fn sudo_true_command() -> Command {
    let mut cmd = Command::new("sudo");
    cmd.args(["-n", "true"]).env("LC_ALL", "C");
    cmd
}

/// Preflight (§K.3): a `-S`/`-U` run whose installs cannot succeed
/// non-interactively refuses BEFORE building starts (rc 3,
/// `sudo cannot install non-interactively`). Proven with `sudo -n true` —
/// never `sudo -v` (a NOPASSWD entry makes `-v` fail while every install
/// succeeds, `docs/MEMORY.md` rule 11).
pub fn preflight_installs() -> Result<(), String> {
    let output = sudo_true_command()
        .output()
        .map_err(|e| format!("sudo cannot install non-interactively ({e})"))?;
    if output.status.success() {
        Ok(())
    } else {
        Err("sudo cannot install non-interactively".to_string())
    }
}

/// The ONE `sudo -n pacman -U …` command for a transaction (§K.3).
/// `LC_ALL=C` pins sudo's and pacman's own messages to C-locale (the same
/// pin `gsa-recipe`'s `pacman -Si` sync uses), so the credential-loss
/// classification below matches stable English whatever the host locale.
fn sudo_pacman_command(req: &TxnRequest) -> Command {
    let mut cmd = Command::new("sudo");
    cmd.arg("-n")
        .arg("pacman")
        .arg("-U")
        .arg("--noconfirm")
        .arg("--ask")
        .arg("4")
        .env("LC_ALL", "C");
    if let Some(conf) = &req.conf {
        cmd.arg("--config").arg(conf);
    }
    for arg in &req.pacman_args {
        cmd.arg(arg);
    }
    for archive in &req.archives {
        cmd.arg(archive);
    }
    cmd
}

/// Credential-loss classification (§K.3) for one failed `sudo -n pacman -U`
/// attempt: the credential is gone and cannot be refreshed without prompting,
/// so dispatch must stop exactly once. The English phrase match is the belt
/// over the silent-rc-1 rule; sudo's exit codes discriminate nothing finer
/// (sudo exits 1 for nearly every failure and propagates pacman's rc), so no
/// rc-only classification exists to prefer.
pub fn sudo_credential_lost(rc: i32, stdout: &str, stderr: &str) -> bool {
    let lower = stderr.to_lowercase();
    if lower.contains("password")
        || lower.contains("prompt")
        || lower.contains("no tty")
        || lower.contains("a terminal is required")
    {
        return true;
    }
    // sudo failed with rc 1 and pacman never spoke (§K.3 — the engine never
    // prompts).
    rc == 1 && stdout.trim().is_empty() && stderr.trim().is_empty()
}

/// Run the ONE `pacman -U` transaction for this call, serialized through the
/// state-root mutex. `-S` runs call this once per built package (an install
/// transaction per package, install-before-dependents); `-U` runs once.
pub fn execute_txn(req: &TxnRequest) -> TxnOutcome {
    // Rule 25(d): the consumers' forced-rebuild markers stage BEFORE the
    // transaction lands (fish `repair_marker_write`) — fail-closed, a
    // marker that cannot be recorded aborts with nothing mutated.
    if let Err(message) = crate::stage_repair_markers(&req.state_dir, &req.repairs) {
        return TxnOutcome::Failed { rc: -1, message };
    }
    let mutex_path = gsa_build::shim::mutex_path(&req.state_dir);
    let _guard = match acquire_mutex(&mutex_path, Duration::from_secs(600)) {
        Some(file) => file,
        None => return TxnOutcome::MutexTimeout,
    };

    let mut cmd = sudo_pacman_command(req);
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
            // The credential is gone and cannot be refreshed without
            // prompting: sudo says so, or sudo failed with rc 1 and pacman
            // never spoke (§K.3 — the engine never prompts).
            if sudo_credential_lost(rc, &stdout, &stderr) {
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

    fn pinned_c(cmd: &Command) -> bool {
        cmd.get_envs().any(|(key, value)| {
            key == std::ffi::OsStr::new("LC_ALL") && value == Some(std::ffi::OsStr::new("C"))
        })
    }

    #[test]
    fn sudo_spawns_pin_the_c_locale() {
        let req = TxnRequest {
            state_dir: PathBuf::from("/state"),
            conf: Some(PathBuf::from("/etc/pacman.conf")),
            archives: vec![PathBuf::from("/a.pkg.tar.zst")],
            pacman_args: vec!["--overwrite".to_string(), "*".to_string()],
            repairs: Vec::new(),
        };
        let txn = sudo_pacman_command(&req);
        assert!(
            pinned_c(&txn),
            "sudo -n pacman -U must pin LC_ALL=C so the SudoLost match is locale-stable"
        );
        let args: Vec<String> = txn
            .get_args()
            .map(|a| a.to_string_lossy().into_owned())
            .collect();
        assert_eq!(
            args[..6],
            ["-n", "pacman", "-U", "--noconfirm", "--ask", "4"],
            "the transaction argv is the documented one"
        );
        assert!(args.contains(&"--config".to_string()));
        assert!(args.contains(&"/a.pkg.tar.zst".to_string()));
        assert!(pinned_c(&sudo_true_command()), "the preflight pins LC_ALL=C");
    }

    #[test]
    fn credential_loss_matches_the_c_locale_sudo_phrases() {
        for stderr in [
            "sudo: a password is required",
            "sudo: no tty present and no askpass program specified",
            "sudo: a terminal is required to read the password",
            "sudo: 3 incorrect password attempts",
        ] {
            assert!(
                sudo_credential_lost(1, "", stderr),
                "{stderr:?} must classify as SudoLost"
            );
        }
        // The silent-rc-1 belt: sudo failed and pacman never spoke.
        assert!(sudo_credential_lost(1, "", ""));
    }

    #[test]
    fn pacman_failures_are_never_credential_loss() {
        // pacman's own error prose is not sudo asking for anything.
        assert!(!sudo_credential_lost(
            1,
            "",
            "error: failed to commit transaction (conflicting files)\n"
        ));
        // pacman spoke → the failure is pacman's, not a lost credential.
        assert!(!sudo_credential_lost(1, "progress output\n", ""));
        // Non-1 silent failures are not the §K.3 signature.
        assert!(!sudo_credential_lost(2, "", ""));
    }
}
