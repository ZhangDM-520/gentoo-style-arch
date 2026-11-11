//! Live-process truth for a build tree.
//!
//! The build cache is resolved from `build_dir` and can be shared by several
//! state roots (a second operator, a CI shard, a native/cross pair), while
//! the run lock is per STATE ROOT. The only ownership proof for a directory
//! is therefore a live process inside it — a per-state-root lock cannot see
//! another root's run (blind-review 2026-11-11, data-center-ops).

use std::path::{Path, PathBuf};

/// A pid whose current working directory lives inside `tree`, if any.
///
/// `remove_dir_all` on such a tree kills an in-flight makepkg: the lane dies
/// with a missing `$srcdir`/`$pkgdir` and the operator is told the recipe is
/// broken. Destructive sweeps (the toolchain-identity clean, `-Mcc…` prune)
/// ask this first and keep the tree instead.
///
/// Unreadable `/proc` entries are SKIPPED, never guessed: an unprivileged
/// caller cannot read another user's `cwd`, and the mutating paths run as
/// root, where the link is readable for every process.
pub fn tree_in_use(tree: &Path) -> Option<u32> {
    // An absent or unresolvable tree is not in use (nothing to protect).
    let root: PathBuf = std::fs::canonicalize(tree).ok()?;
    let entries = std::fs::read_dir("/proc").ok()?;
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(pid) = name.to_str().and_then(|name| name.parse::<u32>().ok()) else {
            continue;
        };
        if pid == std::process::id() {
            continue;
        }
        let Ok(cwd) = std::fs::read_link(entry.path().join("cwd")) else {
            continue;
        };
        if cwd.starts_with(&root) {
            return Some(pid);
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_absent_tree_is_never_in_use() {
        assert_eq!(tree_in_use(Path::new("/nonexistent/gsa-tree")), None);
    }

    #[test]
    fn our_own_tree_is_not_reported_by_our_own_pid() {
        // The engine itself works in its cwd; only OTHER processes count —
        // otherwise every clean would refuse on its own working directory.
        let cwd = std::env::current_dir().unwrap();
        let seen = tree_in_use(&cwd);
        assert_ne!(seen, Some(std::process::id()));
    }
}
