//! Three-state file reads: present, legitimately absent, or broken.
//!
//! "Absent" and "could not read" are different facts and must stay
//! different: a missing file is often valid state (a base-only `.SRCINFO`,
//! an index a clean checkout never wrote), while an unreadable one disables
//! whatever gate asked for it. Collapsing both into an `Option` is how a
//! gate stands down silently. There is deliberately no `Option` escape
//! hatch for the broken state: a caller that wants to ignore a broken read
//! has to write that down at its own seam and say why.

use std::path::Path;

/// One read's outcome — the three states a caller must distinguish.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Loaded {
    /// The file was read.
    Present(String),
    /// The file does not exist. Legitimate only where the caller says so.
    Absent,
    /// The path exists (or is unusable) but the read failed; the reason
    /// names the path.
    Broken(String),
}

/// The primitive both verbs build on: `NotFound` is [`Loaded::Absent`],
/// every other `io::Error` is [`Loaded::Broken`].
pub fn load(path: &Path) -> Loaded {
    match std::fs::read_to_string(path) {
        Ok(text) => Loaded::Present(text),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            if std::fs::symlink_metadata(path).is_ok() {
                Loaded::Broken(format!("cannot read {}: {error}", path.display()))
            } else {
                Loaded::Absent
            }
        }
        Err(error) => Loaded::Broken(format!("cannot read {}: {error}", path.display())),
    }
}

/// The REQUIRED verb: absent and broken are both errors (a required file
/// that is missing is as wrong as one that cannot be read).
pub fn required(path: &Path) -> Result<String, String> {
    match load(path) {
        Loaded::Present(text) => Ok(text),
        Loaded::Absent => Err(format!("{} is missing", path.display())),
        Loaded::Broken(reason) => Err(reason),
    }
}

/// The OPTIONAL verb: absent is `Ok(None)`; broken is still an error.
pub fn optional(path: &Path) -> Result<Option<String>, String> {
    match load(path) {
        Loaded::Present(text) => Ok(Some(text)),
        Loaded::Absent => Ok(None),
        Loaded::Broken(reason) => Err(reason),
    }
}
