//! Run lock, write-time ownership, and orphan sweeps (contract §J.5, §K).
//!
//! - The run lock is an `flock(2)` on `<state>/locks/run.lock`: one engine run
//!   at a time over one state root. A held lock is a refusal, never a wait.
//! - Write-time ownership (rule 19, plan-gsa-isolation.md W1): engine state is
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
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
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
    // The gate's checked handle IS the lock file: the flock and the pid write
    // land on the inode the ownership check saw, never a second open. The
    // quarantine note goes to stderr because this entry predates an err sink
    // and its callers surface only the error string.
    let mut opts = OpenOptions::new();
    opts.create(true).truncate(false).write(true);
    let file = open_state_file_with_uid(&path, &mut opts, current_uid(), &mut std::io::stderr())
        .map_err(|e| e.to_string())?;
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
            "state file {} is not owned by the running engine user and cannot be quarantined ({e}) — move it aside as the state owner (sudo), then rerun",
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

/// `O_NOFOLLOW(2)`'s Linux value. Hard-coded like signals.rs's `LOCK_EX`:
/// this tree keeps libc out of the dependency list, and Linux's `O_*` values
/// are ABI-stable.
const O_NOFOLLOW: i32 = 0o400000;

/// Why the ownership gate refused to hand back an open state file. The split
/// preserves the error classes callers already route: `Ownership` is the gate
/// refusing (wrong owner, redirection), `Open` is the open itself failing.
#[derive(Debug)]
pub enum GateError {
    Ownership(String),
    Open(String),
}

impl std::fmt::Display for GateError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            GateError::Ownership(m) | GateError::Open(m) => f.write_str(m),
        }
    }
}

fn open_nofollow(path: &Path, opts: &mut OpenOptions) -> std::io::Result<File> {
    opts.custom_flags(O_NOFOLLOW);
    opts.open(path)
}

/// Shape an open failure as the gate's refusal: a symlinked final component
/// is named as the redirection it is (its own remedy), everything else keeps
/// the §J.3 state-root remedy. The re-stat is diagnostic only — the refusal
/// itself already happened in `open(2)`, and `ErrorKind::FilesystemLoop` is
/// still unstable.
fn open_refusal(path: &Path, e: std::io::Error) -> GateError {
    let redirected = path
        .symlink_metadata()
        .map(|m| m.file_type().is_symlink())
        .unwrap_or(false);
    if redirected {
        GateError::Ownership(format!(
            "state file {} is a symlink — the ownership gate refuses to write through it; replace it with a regular file as the state owner (sudo), then rerun",
            path.display()
        ))
    } else {
        GateError::Open(format!(
            "cannot open state file {} ({e}) — pass --state-dir PATH or set GSA_STATE_DIR",
            path.display()
        ))
    }
}

fn fd_owned_by(file: &File, path: &Path, uid: u32) -> Result<bool, GateError> {
    let meta = file
        .metadata()
        .map_err(|e| GateError::Open(format!("cannot stat {}: {e}", path.display())))?;
    Ok(meta.uid() == uid)
}

/// The write-time ownership gate (rule 19, §J.5), fd-based: the file is
/// opened with `O_NOFOLLOW` and ownership is checked via `fstat` on that same
/// fd, so the check and the write share one inode — no symlink redirection,
/// no check-then-use window between gate and open. The caller gets the
/// checked handle back and must write through it, never re-open the path.
/// A wrong owner is quarantined and the repaired path re-verified on its own
/// fd: quarantine is forensics, not the boundary (the rename races like any
/// path operation), so a re-planted foreign file is refused, never adopted.
/// Residual: `O_NOFOLLOW` guards only the final path component; parent
/// directories are trusted as part of the runner-owned state root (§J.5).
pub fn open_state_file_with_uid(
    path: &Path,
    opts: &mut OpenOptions,
    uid: u32,
    err: &mut dyn Write,
) -> Result<File, GateError> {
    let file = open_nofollow(path, opts).map_err(|e| open_refusal(path, e))?;
    if fd_owned_by(&file, path, uid)? {
        return Ok(file);
    }
    drop(file);
    quarantine_foreign(path, err).map_err(GateError::Ownership)?;
    let file = open_nofollow(path, opts).map_err(|e| open_refusal(path, e))?;
    if fd_owned_by(&file, path, uid)? {
        return Ok(file);
    }
    drop(file);
    Err(GateError::Ownership(format!(
        "state file {} is still not owned by the running engine user after quarantine — move it aside as the state owner (sudo), then rerun",
        path.display()
    )))
}

/// The append-shaped production entry (lane logs): the checked handle every
/// state write must use instead of opening the path again.
pub fn open_state_append(path: &Path, err: &mut dyn Write) -> Result<File, GateError> {
    let mut opts = OpenOptions::new();
    opts.create(true).append(true);
    open_state_file_with_uid(path, &mut opts, current_uid(), err)
}

/// The warn-only caller's open after a gate refusal (rule 19: forensics
/// appends report and continue). Same no-symlink discipline as the gate — a
/// refused redirection can never be recovered into its target.
pub fn open_state_append_nofollow(path: &Path) -> std::io::Result<File> {
    let mut opts = OpenOptions::new();
    opts.create(true).append(true);
    open_nofollow(path, &mut opts)
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

/// Startup/post-run orphan sweep (contract §K.3): remove stale run artifacts
/// (`.tmp.*`, abandoned result/park files) from dead runs, and reap
/// `--lane-job` / `--fetch-job` processes of dead runs whose result files
/// are unowned. Unrelated `makepkg` processes are never touched.
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
        if !cmdline
            .iter()
            .any(|a| a == "--lane-job" || a == "--fetch-job")
        {
            continue;
        }
        let in_state = cmdline.iter().skip(2).any(|a| arg_in_state(a, &state_prefix));
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

/// `--stale-lock-check` (contract §D.1): the production pacman-lock probe
/// without a run. Reports `db.lck` presence and identifies any holder by an
/// open-file-descriptor scan over `/proc/*/fd` — never by filename heuristics,
/// never by deleting `db.lck`. Report-only on the lock report itself (rc 0);
/// the db-root resolution failing loudly is rc 1 (a report on a silently
/// guessed root is worse than no report).
pub fn pacman_lock_probe(out: &mut dyn Write, err: &mut dyn Write) -> i32 {
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
        assert!(!arg_in_state("/var/lib/gsa-alt/runs/1/x.result", "/var/lib/gsa"));
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
}
