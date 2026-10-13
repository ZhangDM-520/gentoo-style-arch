//! Pruning safety — the referent guards every `gsa-maint` prune consults
//! before it deletes anything (contract §B.7's "symlinks are never deleted or
//! followed" plus the maintain contract's two named guards):
//!
//! 1. **`keep in-use`** (the IgnorePkg closure, [`crate::ignorepkg`]): an
//!    entry still declared by a committed recipe or carried by an installed
//!    package is in use and never leaves the closure.
//! 2. **`keep referenced-by-run`** (every archive-deleting prune — the
//!    strengths and the doctor): an archive whose recipe appears in the
//!    newest stored run record's `remaining:` list is still referenced by
//!    that run — its continuation's replay may carry `--skip`/`--skip-built`,
//!    which consume existing archives — and is never deleted. A later record
//!    whose `remaining` no longer names the recipe releases the reference.
//!
//! The in-flight half of the same guarantee is the run lock ([`crate::hold_run_lock`]):
//! a mutating prune refuses (rc 3 `run-in-flight`) while another engine run
//! holds the state root, so no archive a run is currently using can be
//! deleted (the §J.4 guard seen from the maintain side).

use std::collections::BTreeSet;

use gsa_state::{RunHistory, StateRoot};

use crate::Row;

/// The recipes whose files a prune must not delete: the newest stored run
/// record's `remaining:` set. Corrupt lines and an empty history protect
/// nothing (nothing is referenced).
pub fn referenced_by_run(state: &StateRoot) -> BTreeSet<String> {
    let mut protected = BTreeSet::new();
    let Ok((records, _corrupt)) = RunHistory::read(state) else {
        return protected;
    };
    if let Some(newest) = records.last() {
        for id in &newest.continuation.remaining {
            protected.insert(id.as_str().to_string());
        }
    }
    protected
}

/// The `keep` row for a protected prune target.
pub fn keep_row(subject: &str, reason: &str) -> Row {
    Row::new(subject, "keep", reason)
}
