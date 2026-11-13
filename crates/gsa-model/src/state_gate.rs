//! Write-time ownership gate and safe state-file opening (rule 19, §J.5).
//!
//! Every engine state-file write opens its target with `O_NOFOLLOW` and checks
//! ownership via `fstat` on that same descriptor, so the ownership check and the
//! subsequent write share one inode with no symlink redirection or check-then-use
//! race. Foreign-owned state files are quarantined as
//! `<path>.stale.<epoch>.<pid>` (preserved, announced) before retrying the
//! checked open once.

use std::fs::{File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::path::{Path, PathBuf};

extern "C" {
    fn getuid() -> u32;
}

/// The UID of the running engine process.
pub fn current_uid() -> u32 {
    unsafe { getuid() }
}

/// `O_NOFOLLOW(2)` on Linux (`asm-generic/fcntl.h`).
const O_NOFOLLOW: i32 = 0o400000;

/// Why the ownership gate refused to hand back an open state file.
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

/// A gate failure together with the underlying OS error kind where available
/// (used by the run-lock fallback to distinguish `PermissionDenied` from other
/// failures).
pub struct GateFailure {
    pub error: GateError,
    pub kind: Option<std::io::ErrorKind>,
}

/// Quarantine a wrong-owner state file as `<path>.stale.<epoch>.<pid>`
/// (preserved, announced), returning the OS error kind on rename failure.
pub fn quarantine_foreign_kind(
    path: &Path,
    err: &mut dyn Write,
) -> Result<bool, (String, Option<std::io::ErrorKind>)> {
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
        let kind = e.kind();
        (
            format!(
                "state file {} is not owned by the running engine user and cannot be quarantined ({e}) — move it aside as the state owner (sudo), then rerun",
                path.display()
            ),
            Some(kind),
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

/// Quarantine a wrong-owner state file as `<path>.stale.<epoch>.<pid>`
/// (preserved, announced).
pub fn quarantine_foreign(path: &Path, err: &mut dyn Write) -> Result<bool, String> {
    quarantine_foreign_kind(path, err).map_err(|(message, _kind)| message)
}

fn open_nofollow(path: &Path, opts: &mut OpenOptions) -> std::io::Result<File> {
    opts.custom_flags(O_NOFOLLOW);
    opts.open(path)
}

fn open_refusal(path: &Path, e: std::io::Error) -> GateFailure {
    let kind = e.kind();
    let redirected = path
        .symlink_metadata()
        .map(|m| m.file_type().is_symlink())
        .unwrap_or(false);
    if redirected {
        GateFailure {
            error: GateError::Ownership(format!(
                "state file {} is a symlink — the ownership gate refuses to write through it; replace it with a regular file as the state owner (sudo), then rerun",
                path.display()
            )),
            kind: Some(kind),
        }
    } else {
        GateFailure {
            error: GateError::Open(format!(
                "cannot open state file {} ({e}) — pass --state-dir PATH or set GSA_STATE_DIR",
                path.display()
            )),
            kind: Some(kind),
        }
    }
}

fn fd_owned_by(file: &File, path: &Path, uid: u32) -> Result<bool, GateFailure> {
    let meta = file.metadata().map_err(|e| GateFailure {
        error: GateError::Open(format!("cannot stat {}: {e}", path.display())),
        kind: Some(e.kind()),
    })?;
    Ok(meta.uid() == uid)
}

/// Write-time ownership gate preserving the underlying `ErrorKind`.
pub fn gate_open_with_kind(
    path: &Path,
    opts: &mut OpenOptions,
    uid: u32,
    err: &mut dyn Write,
) -> Result<File, GateFailure> {
    let file = open_nofollow(path, opts).map_err(|e| open_refusal(path, e))?;
    if fd_owned_by(&file, path, uid)? {
        return Ok(file);
    }
    drop(file);
    quarantine_foreign_kind(path, err).map_err(|(message, kind)| GateFailure {
        error: GateError::Ownership(message),
        kind,
    })?;
    let file = open_nofollow(path, opts).map_err(|e| open_refusal(path, e))?;
    if fd_owned_by(&file, path, uid)? {
        return Ok(file);
    }
    drop(file);
    Err(GateFailure {
        error: GateError::Ownership(format!(
            "state file {} is still not owned by the running engine user after quarantine — move it aside as the state owner (sudo), then rerun",
            path.display()
        )),
        kind: None,
    })
}

/// Write-time ownership gate (rule 19, §J.5), fd-based with `O_NOFOLLOW` + `fstat`.
pub fn open_state_file_with_uid(
    path: &Path,
    opts: &mut OpenOptions,
    uid: u32,
    err: &mut dyn Write,
) -> Result<File, GateError> {
    gate_open_with_kind(path, opts, uid, err).map_err(|f| f.error)
}

/// Append-mode open under the ownership gate (lane and prefetch logs).
pub fn open_state_append(path: &Path, err: &mut dyn Write) -> Result<File, GateError> {
    let mut opts = OpenOptions::new();
    opts.create(true).append(true);
    open_state_file_with_uid(path, &mut opts, current_uid(), err)
}

/// Forensics append-mode open with `O_NOFOLLOW` after a warn-only gate refusal.
pub fn open_state_append_nofollow(path: &Path) -> std::io::Result<File> {
    let mut opts = OpenOptions::new();
    opts.create(true).append(true);
    open_nofollow(path, &mut opts)
}
