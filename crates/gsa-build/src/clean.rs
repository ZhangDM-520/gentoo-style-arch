//! Prune strength 1 (contract §B.5 cluster letter `c`; `gsa -Mc`): remove
//! one recipe's `src/`/`pkg/`/`build/` trees and its built archives, so the
//! next build starts clean. Scope is exactly the recipe directories the
//! selection resolved to — nothing outside them is ever touched, and
//! symlinks are removed as links, never followed (contract §B.7's rule for
//! the stronger prunes applies here too).

use std::path::Path;

/// What one prune touched, for the run's notes.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct CleanReport {
    pub removed: Vec<String>,
    pub errors: Vec<String>,
}

/// Prune strength 1 for one recipe directory: `src/`, `pkg/`, `build/` and
/// every `*.pkg.tar.zst` archive beside the recipe (makepkg state lives
/// beside the recipe, contract §J.2).
pub fn clean_recipe(recipe_dir: &Path, report: &mut CleanReport) {
    for name in ["src", "pkg", "build"] {
        let path = recipe_dir.join(name);
        let Ok(meta) = std::fs::symlink_metadata(&path) else {
            continue;
        };
        let removed = if meta.file_type().is_symlink() {
            std::fs::remove_file(&path)
        } else {
            std::fs::remove_dir_all(&path)
        };
        match removed {
            Ok(()) => report.removed.push(path.display().to_string()),
            Err(error) => report
                .errors
                .push(format!("cannot remove {}: {error}", path.display())),
        }
    }
    let Ok(entries) = std::fs::read_dir(recipe_dir) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.ends_with(".pkg.tar.zst") {
            match std::fs::remove_file(entry.path()) {
                Ok(()) => report.removed.push(entry.path().display().to_string()),
                Err(error) => report
                    .errors
                    .push(format!("cannot remove {}: {error}", entry.path().display())),
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strength_one_removes_build_trees_and_archives_only() {
        let dir = std::env::temp_dir().join(format!("gsa-clean-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let recipe = dir.join("packages/git/pkg1");
        std::fs::create_dir_all(recipe.join("src")).unwrap();
        std::fs::create_dir_all(recipe.join("pkg")).unwrap();
        std::fs::create_dir_all(recipe.join("build")).unwrap();
        std::fs::write(recipe.join("a-1.0-1-any.pkg.tar.zst"), "").unwrap();
        std::fs::write(recipe.join("PKGBUILD"), "pkgname=pkg1\n").unwrap();
        std::fs::write(recipe.join(".SRCINFO"), "pkgbase = pkg1\n").unwrap();
        let mut report = CleanReport::default();
        clean_recipe(&recipe, &mut report);
        assert!(!recipe.join("src").exists());
        assert!(!recipe.join("pkg").exists());
        assert!(!recipe.join("build").exists());
        assert!(!recipe.join("a-1.0-1-any.pkg.tar.zst").exists());
        assert!(
            recipe.join("PKGBUILD").exists(),
            "recipes survive the prune"
        );
        assert!(recipe.join(".SRCINFO").exists());
        assert_eq!(report.removed.len(), 4);
        assert!(report.errors.is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
