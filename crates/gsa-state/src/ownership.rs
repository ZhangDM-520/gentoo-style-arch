//! Write-time ownership (contract §J.5, `docs/MEMORY.md` rule 19): engine
//! state is owned by the privileged runner (mutating runs are root —
//! contract §B.10). A file owned by anyone the running engine is not is
//! quarantined as `<path>.stale.<epoch>.<pid>` (preserved, announced) before
//! any write opens it — no silent adoption. The quarantine itself is
//! `gsa-sched::lock`'s (rule 19 has one home); this module is the gate every
//! `gsa-state` write path passes through.

use std::io::Write;
use std::os::unix::fs::MetadataExt;
use std::path::Path;

/// Why a state read/write failed, always naming the remedy (§J.3).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum StateError {
    /// The state root or a store directory could not be created.
    Create(String),
    /// A file could not be read/written.
    Io(String),
    /// The file is not owned by the running engine and could not be quarantined.
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

/// The write-time ownership gate against an explicit uid (the testable
/// seam; production passes [`current_uid`]). A wrong owner is quarantined
/// loudly through `gsa-sched::lock::quarantine_foreign`.
pub(crate) fn gate_with_uid(path: &Path, uid: u32, err: &mut dyn Write) -> Result<(), StateError> {
    if let Ok(meta) = std::fs::metadata(path) {
        if meta.uid() != uid {
            gsa_sched::lock::quarantine_foreign(path, err).map_err(StateError::Ownership)?;
        }
    }
    Ok(())
}

/// The production gate (rule 19): quarantine a wrong-owner file, loudly,
/// before the caller opens it for write.
pub fn ownership_gate(path: &Path, err: &mut dyn Write) -> Result<(), StateError> {
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
        // A uid that is not ours: the gate must quarantine, never adopt.
        let wrong = gsa_sched::signals::current_uid().wrapping_add(1);
        gate_with_uid(&path, wrong, &mut err).unwrap();
        let err = String::from_utf8_lossy(&err).into_owned();
        assert!(
            err.contains("quarantined foreign-owned state file"),
            "the quarantine must be announced: {err}"
        );
        assert!(!path.exists(), "the wrong-owner file must be moved aside");
        let stale: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().contains(".stale."))
            .collect();
        assert_eq!(stale.len(), 1, "preserved as <path>.stale.<epoch>.<pid>");
        // The quarantined copy is preserved byte-for-byte.
        assert_eq!(std::fs::read_to_string(&stale[0].path()).unwrap(), "kept\n");
    }

    #[test]
    fn our_own_file_passes_untouched() {
        let dir = scratch("own");
        let path = dir.join("index.jsonl");
        std::fs::write(&path, "ours\n").unwrap();
        let mut err = Vec::new();
        ownership_gate(&path, &mut err).unwrap();
        assert!(path.exists());
        assert!(err.is_empty(), "no note for an owned file: {err:?}");
    }
}
