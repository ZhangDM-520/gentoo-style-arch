//! One containment rule for every destructive target.
//!
//! A prune path is built by joining engine-owned roots with names that came
//! from REPOSITORY DATA (`pkgbase` out of a committed `.SRCINFO`, an archive
//! name out of a `.PKGINFO`) or from the topology's `path` field, which may
//! be a symlink. Neither is a path: a `..` component walks out of the root,
//! and a symlinked recipe directory moves `remove_dir_all` outside it. The
//! lexical `Path::starts_with` guard passes both (blind review,
//! 2026-11-11: `pkgbase = ../../victim` deleted a sibling cache tree as
//! root).
//!
//! [`delete_allowed`] is the ONE answer, and it is deliberately strict:
//! doubt never deletes.

use std::path::{Component, Path};

/// May this caller delete `target` as part of `root`'s tree?
///
/// Two halves, both required:
///
/// 1. `target` is `root` plus a purely NORMAL relative path — no `..`, no
///    root/prefix component (a repository-supplied name is a name);
/// 2. the target's own resolved location stays inside `root`'s resolved
///    location, so a symlinked ancestor cannot move the delete elsewhere.
///
/// A target that is ITSELF a symlink is unlinked, never followed, so its
/// containment is decided at its parent. Anything unresolvable is refused.
pub fn delete_allowed(root: &Path, target: &Path) -> bool {
    let Ok(relative) = target.strip_prefix(root) else {
        return false;
    };
    if relative.as_os_str().is_empty() {
        return false;
    }
    if !relative
        .components()
        .all(|c| matches!(c, Component::Normal(_)))
    {
        return false;
    }
    let Ok(root_real) = root.canonicalize() else {
        return false;
    };
    let anchor = match std::fs::symlink_metadata(target) {
        Ok(meta) if meta.file_type().is_symlink() => target.parent().unwrap_or(target),
        _ => target,
    };
    // The deepest EXISTING ancestor: a target is often already gone (a second
    // prune, a half-finished tree), and an intermediate link is still a move.
    let mut probe = anchor;
    loop {
        if probe.exists() {
            break;
        }
        match probe.parent() {
            Some(parent) if parent != probe => probe = parent,
            _ => return false,
        }
    }
    let Ok(probe_real) = probe.canonicalize() else {
        return false;
    };
    probe_real != root_real && probe_real.starts_with(&root_real)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "gsa-guard-{name}-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// `pkgbase = ../../victim` is the repository-data escape: the join
    /// produces a path that `starts_with(root)` accepts.
    #[test]
    fn a_parent_component_is_never_deleted() {
        let dir = scratch("parent");
        let root = dir.join("build");
        std::fs::create_dir_all(root.join("tree/src")).unwrap();
        std::fs::create_dir_all(dir.join("victim/src")).unwrap();
        let escaped = root.join("tree/../../../victim/src");
        assert!(
            escaped.normalize_starts_with(&root),
            "premise: lexical prefix passes"
        );
        assert!(!delete_allowed(&root, &escaped));
        assert!(delete_allowed(&root, &root.join("tree/src")));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A symlinked recipe directory moves `remove_dir_all` outside the
    /// workspace without a single `..` component.
    #[test]
    fn a_symlinked_ancestor_cannot_move_the_delete() {
        let dir = scratch("symlink");
        let root = dir.join("ws");
        let outside = dir.join("outside");
        std::fs::create_dir_all(root.join("packages")).unwrap();
        std::fs::create_dir_all(outside.join("src")).unwrap();
        std::os::unix::fs::symlink(&outside, root.join("packages/evil")).unwrap();
        assert!(!delete_allowed(&root, &root.join("packages/evil/src")));
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The link itself is unlinked, never followed: containment is decided at
    /// its parent, so a legitimate `src -> /data/src` stays prunable.
    #[test]
    fn a_trailing_symlink_is_judged_at_its_parent() {
        let dir = scratch("trailing");
        let root = dir.join("ws");
        let outside = dir.join("outside");
        std::fs::create_dir_all(root.join("pkg")).unwrap();
        std::fs::create_dir_all(&outside).unwrap();
        std::os::unix::fs::symlink(&outside, root.join("pkg/src")).unwrap();
        assert!(delete_allowed(&root, &root.join("pkg/src")));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_root_itself_and_foreign_paths_are_refused() {
        let dir = scratch("bounds");
        let root = dir.join("ws");
        std::fs::create_dir_all(root.join("a")).unwrap();
        std::fs::create_dir_all(dir.join("elsewhere")).unwrap();
        assert!(!delete_allowed(&root, &root));
        assert!(!delete_allowed(&root, &dir.join("elsewhere")));
        assert!(!delete_allowed(
            &dir.join("missing-root"),
            &dir.join("elsewhere")
        ));
        let _ = std::fs::remove_dir_all(&dir);
    }

    trait LexicalPrefix {
        fn normalize_starts_with(&self, root: &Path) -> bool;
    }
    impl LexicalPrefix for Path {
        fn normalize_starts_with(&self, root: &Path) -> bool {
            self.starts_with(root)
        }
    }
}
