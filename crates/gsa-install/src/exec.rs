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
    /// The state-root mutex is held by another transaction and did not
    /// clear inside the bounded wait — contention only; a lock file that
    /// cannot be opened is the named `Failed` class.
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

/// Why the state-root mutex could not be taken. Contention and an unusable
/// lock path are different failures: reporting the second as
/// [`TxnOutcome::MutexTimeout`] blames a concurrent run for a permissions
/// problem and returns instantly while the row claims a 600 s wait.
#[derive(Debug, PartialEq, Eq)]
enum MutexError {
    /// The lock file is open and another holder keeps it — the bounded wait
    /// expired.
    Busy,
    /// The lock file could not be opened at all; the reason names the path
    /// and the remedy.
    Unopenable(String),
}

/// Exclusive flock on the state-root mutex (the same lock the PACMAN shim
/// serializes makepkg's own transactions on), bounded wait like the shim's
/// `flock -w 600`. The file handle IS the guard: the lock releases on drop.
fn acquire_mutex(path: &Path, timeout: Duration) -> Result<File, MutexError> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|error| {
            MutexError::Unopenable(format!(
                "cannot create the transaction mutex directory {}: {error} \
                 (check the state root's ownership, or pass --state-dir)",
                dir.display()
            ))
        })?;
    }
    // Never truncate a possibly-held lock inode (rule 19's exception).
    let file = OpenOptions::new()
        .create(true)
        .write(true)
        .open(path)
        .map_err(|error| {
            MutexError::Unopenable(format!(
                "cannot open the transaction mutex {}: {error} \
                 (check that its directory is writable, or pass --state-dir)",
                path.display()
            ))
        })?;
    let deadline = Instant::now() + timeout;
    loop {
        let rc = unsafe { flock(file.as_raw_fd(), LOCK_EX | LOCK_NB) };
        if rc == 0 {
            return Ok(file);
        }
        if Instant::now() >= deadline {
            return Err(MutexError::Busy);
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
/// succeeds, `AGENTS.md` rule 11).
pub fn preflight_installs(conf: Option<&Path>) -> Result<(), String> {
    let output = sudo_true_command()
        .output()
        .map_err(|e| format!("sudo cannot install non-interactively ({e})"))?;
    if !output.status.success() {
        return Err("sudo cannot install non-interactively".to_string());
    }
    // A stale lock makes every install of the run impossible (pacman refuses
    // to open the database while the file exists), so refuse BEFORE building
    // instead of wasting the whole run and then blaming a live holder
    // (blind-review 2026-11-11, ci-fleet-operator). A LIVE lock is not a
    // refusal: it can clear while the run builds, and the executor waits
    // for it bounded.
    let db_root = crate::pacman_db_root_for(conf)?;
    if let Some(stale) = crate::register::stale_db_lock(&db_root) {
        return Err(crate::register::stale_db_lock_message(&stale));
    }
    Ok(())
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
/// so dispatch must stop exactly once.
///
/// Only sudo's OWN words count. sudo runs with `-n`, so a credential problem
/// always speaks on stderr; a transaction that dies without a word is not
/// evidence of a lost credential — treating it as one reported a silent
/// `pacman` failure as "sudo credential expired", with dispatch halted for a
/// hiccup (blind-review finding, 2026-11-11). The caller now reports such a
/// failure as `exited N with no output`.
pub fn sudo_credential_lost(stderr: &str) -> bool {
    let lower = stderr.to_lowercase();
    lower.contains("password")
        || lower.contains("prompt")
        || lower.contains("no tty")
        || lower.contains("a terminal is required")
}

/// Wait for a live pacman database lock the way registration does (rule 9/23:
/// bounded, never deleted) before the transaction spawns. A stale lock (no
/// live holder) proceeds untouched.
fn await_db_lock(db_root: &Path) -> Result<(), String> {
    // A lock that turns stale DURING the wait is a refusal, exactly like the
    // pre-check above: pacman cannot open the database while the file
    // exists, and proceeding produced pacman's own lock error with retry
    // advice that could never terminate (blind-review 2026-11-11,
    // data-center-ops).
    crate::register::wait_for_db_lock_for(
        db_root,
        crate::register::StalePolicy::Refuse,
        "install-transaction",
    )
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
    // A stale `db.lck` cannot be transacted through at all (pacman refuses
    // while the file exists) and must never be deleted here: fail with the
    // staleness named rather than letting pacman indict the file and the
    // engine repeat "wait for the other package manager" (which never ends).
    // The target configuration names the DB (and its `db.lck`) this
    // transaction will open — never the host's (security-auditor F4).
    let db_root = match crate::pacman_db_root_for(req.conf.as_deref()) {
        Ok(root) => root,
        Err(message) => return TxnOutcome::Failed { rc: -1, message },
    };
    if let Some(stale) = crate::register::stale_db_lock(&db_root) {
        return TxnOutcome::Failed {
            rc: -1,
            message: crate::register::stale_db_lock_message(&stale),
        };
    }
    // A live `db.lck` is waited for, not raced: firing `pacman -U` into it
    // reported pacman's "unable to lock database … you can remove" line as
    // the failure reason, which invites deleting a LIVE lock.
    if let Err(message) = await_db_lock(&db_root) {
        return TxnOutcome::Failed { rc: -1, message };
    }
    let mutex_path = gsa_build::shim::mutex_path(&req.state_dir);
    let _guard = match acquire_mutex(&mutex_path, Duration::from_secs(600)) {
        Ok(file) => file,
        // Contention: the documented bounded wait expired.
        Err(MutexError::Busy) => return TxnOutcome::MutexTimeout,
        // The lock file itself is unusable — a permissions/filesystem
        // problem, never a concurrent run. The message names it and the
        // remedy; reporting it as a timeout would blame the wrong cause.
        Err(MutexError::Unopenable(message)) => return TxnOutcome::Failed { rc: -1, message },
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
            // prompting — and sudo says so (§K.3: the engine never prompts).
            if sudo_credential_lost(&stderr) {
                return TxnOutcome::SudoLost;
            }
            // A lock failure names the lock and says what NOT to do: pacman's
            // own last line ("you can remove …") is an invitation the engine
            // must never forward (rule 9/23).
            if stderr.contains("unable to lock database") {
                return TxnOutcome::Failed {
                    rc,
                    message: format!(
                        "another package manager holds the database lock — wait for it to finish and retry; never delete {}",
                        db_root.join("db.lck").display()
                    ),
                };
            }
            let message = stderr
                .lines()
                .rev()
                .find(|l| !l.trim().is_empty())
                .map(|l| l.trim().to_string())
                .filter(|l| !l.is_empty())
                .unwrap_or_else(|| {
                    // No prose at all: name the exit status instead of
                    // inventing a cause.
                    if stdout.trim().is_empty() {
                        format!("pacman -U exited {rc} with no output")
                    } else {
                        format!("pacman -U exited {rc}")
                    }
                });
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
        assert_eq!(
            acquire_mutex(&path, Duration::from_millis(100)).err(),
            Some(MutexError::Busy),
            "a second exclusive flock must time out"
        );
        drop(guard);
        let mut released = false;
        for _ in 0..100 {
            if let Ok(g) = acquire_mutex(&path, Duration::from_millis(20)) {
                drop(g);
                released = true;
                break;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        assert!(released, "the mutex releases when the guard drops");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn an_unopenable_mutex_path_is_not_a_mutex_timeout() {
        let dir = std::env::temp_dir().join(format!("gsa-exec-unopenable-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        // A regular file where the lock directory must be: neither the
        // directory creation nor the open can succeed, and neither is
        // contention.
        let blocker = dir.join("locks");
        std::fs::write(&blocker, "not a directory\n").unwrap();
        let path = blocker.join("pacman-mutex");
        match acquire_mutex(&path, Duration::from_millis(50)) {
            Err(MutexError::Unopenable(message)) => {
                assert!(
                    message.contains(&blocker.display().to_string()),
                    "the reason names the unusable path: {message}"
                );
                assert!(message.contains("transaction mutex"), "{message}");
                assert!(message.contains("--state-dir"), "{message}");
            }
            Err(MutexError::Busy) => panic!("an unusable lock path is not contention"),
            Ok(_) => panic!("the lock file cannot be created below a regular file"),
        }
        // The production entry maps it to the named failure class, never the
        // 600 s-timeout row. A SYNTHETIC configuration, not `None`: with no
        // `--config` the preflight reads the HOST database's `db.lck`, so a
        // package manager running on this machine decided this unit test's
        // outcome (the assertion below then reported a stale lock instead of
        // the mutex it is about).
        let conf = dir.join("pacman.conf");
        // `pacman-conf` resolves DBPath, so the directory must exist.
        std::fs::create_dir_all(dir.join("db")).unwrap();
        std::fs::write(&conf, format!("[options]\nDBPath = {}/db\n", dir.display())).unwrap();
        let req = TxnRequest {
            state_dir: dir.clone(),
            conf: Some(conf),
            archives: Vec::new(),
            pacman_args: Vec::new(),
            repairs: Vec::new(),
        };
        match execute_txn(&req) {
            TxnOutcome::Failed { rc, message } => {
                assert_eq!(rc, -1, "no pacman subprocess ran");
                assert!(message.contains("transaction mutex"), "{message}");
            }
            other => panic!("expected a named failure, got {other:?}"),
        }
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
        assert!(
            pinned_c(&sudo_true_command()),
            "the preflight pins LC_ALL=C"
        );
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
                sudo_credential_lost(stderr),
                "{stderr:?} must classify as SudoLost"
            );
        }
        // Silence is NOT a credential loss: sudo -n always says why.
        assert!(!sudo_credential_lost(""));
    }

    #[test]
    fn pacman_failures_are_never_credential_loss() {
        // pacman's own error prose is not sudo asking for anything.
        assert!(!sudo_credential_lost(
            "error: failed to commit transaction (conflicting files)\n"
        ));
        // pacman's silence is pacman's failure, not a lost credential.
        assert!(!sudo_credential_lost(""));
    }
}
