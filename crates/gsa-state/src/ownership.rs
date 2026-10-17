//! Write-time ownership (contract §J.5, `docs/MEMORY.md` rule 19): engine
//! state is owned by the privileged runner (mutating runs are root —
//! contract §B.10). A file owned by anyone the running engine is not is
//! quarantined as `<path>.stale.<epoch>.<pid>` (preserved, announced) before
//! any write opens it — no silent adoption. The gate itself is one seam,
//! `gsa-sched::lock::open_state_file_with_uid` (rule 19 has one home); this
//! module maps it onto [`StateError`] and supplies the uid-injectable entry
//! the tests drive.

use std::fs::{File, OpenOptions};
use std::io::Write;
use std::path::Path;

/// Why a state read/write failed, always naming the remedy (§J.3).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StateError {
    /// The state root or a store directory could not be created.
    Create(String),
    /// A file could not be read/written.
    Io(String),
    /// The gate refused the write: a file not owned by the running engine
    /// that could not be quarantined, or a symlink the gate will not write
    /// through.
    Ownership(String),
    /// A row was written without a known `sha256`+`size` — fail closed
    /// (§J.4: the row is written only after both are known).
    Diverge(String),
}

impl std::fmt::Display for StateError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            StateError::Create(m) | StateError::Io(m) | StateError::Ownership(m) => f.write_str(m),
            StateError::Diverge(m) => write!(f, "index write refused (fail closed, §J.4): {m}"),
        }
    }
}

impl std::error::Error for StateError {}

/// The write-time ownership gate against an explicit uid (the testable seam;
/// production passes [`current_uid`]). Returns the checked, opened handle —
/// the caller appends through it and never re-opens the path.
pub(crate) fn gate_with_uid(path: &Path, uid: u32, err: &mut dyn Write) -> Result<File, StateError> {
    let mut opts = OpenOptions::new();
    opts.create(true).read(true).append(true);
    gsa_sched::lock::open_state_file_with_uid(path, &mut opts, uid, err).map_err(|e| match e {
        gsa_sched::lock::GateError::Ownership(m) => StateError::Ownership(m),
        gsa_sched::lock::GateError::Open(m) => StateError::Io(m),
    })
}

/// The production gate (rule 19): quarantine a wrong-owner file, loudly, and
/// hand back the checked handle the caller writes through.
pub fn ownership_gate(path: &Path, err: &mut dyn Write) -> Result<File, StateError> {
    gate_with_uid(path, gsa_sched::signals::current_uid(), err)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir =
            std::env::temp_dir().join(format!("gsa-state-ownership-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn a_foreign_owned_file_is_quarantined_loudly() {
        let dir = scratch("foreign");
        let path = dir.join("index.jsonl");
        std::fs::write(&path, "kept\n").unwrap();
        let mut err = Vec::new();
        // A uid that is not ours: the gate must quarantine, never adopt. The
        // repair round re-verifies its own fd too, so an owner that can never
        // match (the injected uid) is refused even after the quarantine.
        let wrong = gsa_sched::signals::current_uid().wrapping_add(1);
        let refused = gate_with_uid(&path, wrong, &mut err)
            .unwrap_err()
            .to_string();
        assert!(
            refused.contains("still not owned"),
            "a re-planted foreign file is refused, never adopted: {refused}"
        );
        let err = String::from_utf8_lossy(&err).into_owned();
        assert!(
            err.contains("quarantined foreign-owned state file"),
            "the quarantine must be announced: {err}"
        );
        let stale: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().contains(".stale."))
            .collect();
        assert_eq!(stale.len(), 1, "preserved as <path>.stale.<epoch>.<pid>");
        // The quarantined copy is preserved byte-for-byte.
        assert_eq!(std::fs::read_to_string(&stale[0].path()).unwrap(), "kept\n");
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            "",
            "the repair open leaves a fresh file, never the foreign bytes"
        );
    }

    #[test]
    fn our_own_file_passes_untouched() {
        let dir = scratch("own");
        let path = dir.join("index.jsonl");
        std::fs::write(&path, "ours\n").unwrap();
        let mut err = Vec::new();
        let mut file = ownership_gate(&path, &mut err).unwrap();
        assert!(path.exists());
        assert!(err.is_empty(), "no note for an owned file: {err:?}");
        // The returned handle is live and lands on the checked inode.
        std::io::Write::write_all(&mut file, b"row\n").unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "ours\nrow\n");
    }

    #[test]
    fn a_symlink_is_refused_not_followed() {
        let dir = scratch("symlink");
        let target = dir.join("target.jsonl");
        std::fs::write(&target, "sentinel\n").unwrap();
        let path = dir.join("index.jsonl");
        std::os::unix::fs::symlink(&target, &path).unwrap();
        let mut err = Vec::new();
        // Even our own symlink pointing at our own writable file: the gate
        // refuses the redirection rather than write through it.
        let message = gate_with_uid(&path, gsa_sched::signals::current_uid(), &mut err)
            .unwrap_err()
            .to_string();
        assert!(
            message.contains("symlink"),
            "the refusal names the redirection: {message}"
        );
        assert_eq!(
            std::fs::read_to_string(&target).unwrap(),
            "sentinel\n",
            "nothing may land in the target"
        );
        assert!(
            std::fs::symlink_metadata(&path)
                .unwrap()
                .file_type()
                .is_symlink(),
            "the symlink survives as forensics"
        );
        let stale: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().contains(".stale."))
            .collect();
        assert!(
            stale.is_empty(),
            "a same-owner symlink is refused, never rule 19's quarantine"
        );
    }
}
