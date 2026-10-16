//! Prune strength 1 (contract §B.5 cluster letter `c`; `gsa -Mc`): remove
//! one recipe's `src/`/`pkg/`/`build/` trees and its built archives, so the
//! next build starts clean. Scope is exactly the recipe directories the
//! selection resolved to — nothing outside them is ever touched, and
//! symlinks are removed as links, never followed (contract §B.7's rule for
//! the stronger prunes applies here too).
//!
//! In a shared `PKGDEST` the scope is per-ARCHIVE truth, never a name
//! prefix: an archive belongs to this recipe only when its own `.PKGINFO`
//! names one of the recipe's outputs (the gsa-install discovery authority,
//! rule 11) — or, for an archive whose `.PKGINFO` cannot be read, only when
//! its file name matches one output at the recipe's current version key
//! (`gsa_recipe::freshness::archive_matches_output`). A prefix is not
//! evidence: output `python`'s `NAME-` prefix is shared by `python-attrs`
//! and prefix matching deleted an unselected recipe's archives (and with
//! them their binpkg-index rows and rollback material).

use std::path::{Path, PathBuf};

/// What one prune touched, for the run's notes.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct CleanReport {
    pub removed: Vec<String>,
    pub errors: Vec<String>,
}

/// Prune strength 1 for one recipe directory: `src/`, `pkg/`, `build/` and
/// every `*.pkg.tar.zst` archive beside the recipe (legacy location and
/// fixture stubs), plus — when the W4 build layout is known — the recipe's
/// archives in the shared `PKGDEST` (output-name truth, see the module
/// docs), and its `build/`/`pkg/` trees under the build user's cache. An
/// archive's `.gsa-vcs-revisions` sidecar is pruned exactly when its
/// archive is (gsa-maint's sidecar class).
pub fn clean_recipe(
    recipe_dir: &Path,
    pkgbase: &str,
    outputs: &[String],
    layout: Option<&gsa_model::config::BuildLayout>,
    report: &mut CleanReport,
) {
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
                .push(format!("cannot remove {}: {e}", path.display(), e = error)),
        }
    }
    remove_archives_in(recipe_dir, &|_| true, report);
    if let Some(layout) = layout {
        // The version key backs the filename-truth fallback for archives
        // whose `.PKGINFO` cannot be read; when it cannot be established,
        // that fallback is simply unavailable (never a broader match).
        let version = gsa_recipe::freshness::current_version_key(recipe_dir).ok();
        remove_archives_in(
            &layout.pkgdest,
            &|path| archive_belongs_to_outputs(path, outputs, version.as_ref()),
            report,
        );
        for tree in [layout.builddir.join(pkgbase), layout.pkgdir.join(pkgbase)] {
            if !tree.exists() {
                continue;
            }
            match std::fs::remove_dir_all(&tree) {
                Ok(()) => report.removed.push(tree.display().to_string()),
                Err(error) => report.errors.push(format!(
                    "cannot remove {}: {error}",
                    tree.display()
                )),
            }
        }
    }
}

/// Is this shared-PKGDEST archive one of the recipe's outputs? `.PKGINFO`
/// truth first (rule 11: the archive's own metadata is the authority, any
/// version); an archive whose `.PKGINFO` cannot be read falls back to the
/// freshness filename truth at the recipe's CURRENT version key, and
/// nothing broader — doubt never deletes.
fn archive_belongs_to_outputs(
    archive: &Path,
    outputs: &[String],
    version: Option<&(String, String)>,
) -> bool {
    match gsa_recipe::pkginfo::read_pkginfo(archive) {
        Ok(info) => outputs.iter().any(|o| o == &info.pkgname),
        Err(_) => match version {
            Some((pv, pr)) => outputs
                .iter()
                .any(|o| gsa_recipe::freshness::archive_matches_output(archive, o, pv, pr)),
            None => false,
        },
    }
}

fn remove_archives_in(
    dir: &Path,
    selected: &dyn Fn(&Path) -> bool,
    report: &mut CleanReport,
) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let path = entry.path();
        if !name.ends_with(".pkg.tar.zst") || !selected(&path) {
            continue;
        }
        match std::fs::remove_file(&path) {
            Ok(()) => {
                report.removed.push(path.display().to_string());
                // The `.gsa-vcs-revisions` sidecar is pruned exactly when
                // its archive is (gsa-maint/src/prune.rs's sidecar class).
                let mut sidecar_name = path.clone().into_os_string();
                sidecar_name.push(".gsa-vcs-revisions");
                let sidecar = PathBuf::from(sidecar_name);
                match std::fs::symlink_metadata(&sidecar) {
                    Ok(_) => match std::fs::remove_file(&sidecar) {
                        Ok(()) => report.removed.push(sidecar.display().to_string()),
                        Err(error) => report.errors.push(format!(
                            "cannot remove {}: {error}",
                            sidecar.display()
                        )),
                    },
                    Err(_) => {}
                }
            }
            Err(error) => report
                .errors
                .push(format!("cannot remove {}: {error}", path.display())),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

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
        clean_recipe(&recipe, "a", &["a".to_string()], None, &mut report);
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

    /// One real `.pkg.tar.zst` archive whose `.PKGINFO` names `pkgname`.
    fn write_pkg_archive(path: &Path, pkgname: &str, version: &str) {
        let file = std::fs::File::create(path).unwrap();
        let encoder = zstd::Encoder::new(file, 0).unwrap();
        let mut builder = tar::Builder::new(encoder);
        let body = format!("pkgbase = {pkgname}\npkgname = {pkgname}\npkgver = {version}\narch = x86_64\n");
        let mut header = tar::Header::new_gnu();
        header.set_size(body.len() as u64);
        header.set_mode(0o644);
        header.set_cksum();
        builder
            .append_data(&mut header, ".PKGINFO", body.as_bytes())
            .unwrap();
        let encoder = builder.into_inner().unwrap();
        encoder.finish().unwrap();
    }

    fn scratch_layout(name: &str) -> (PathBuf, PathBuf, gsa_model::config::BuildLayout) {
        let dir = std::env::temp_dir().join(format!("gsa-clean-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let recipe = dir.join("packages/stable/python");
        std::fs::create_dir_all(&recipe).unwrap();
        std::fs::write(
            recipe.join(".SRCINFO"),
            "pkgbase = python\npkgname = python\npkgver = 3.12\npkgrel = 1\n",
        )
        .unwrap();
        let root = dir.join("cache");
        let layout = gsa_model::config::BuildLayout {
            builddir: root.join("build"),
            pkgdir: root.join("pkg"),
            pkgdest: root.join("pkgs"),
            root,
        };
        std::fs::create_dir_all(&layout.pkgdest).unwrap();
        (dir, recipe, layout)
    }

    #[test]
    fn shared_pkgdest_prunes_only_this_recipes_outputs() {
        let (dir, recipe, layout) = scratch_layout("pkgdest");
        let pkgdest = &layout.pkgdest;
        // Our current-version archive, its VCS sidecar, a stale-version
        // archive of ours ...
        write_pkg_archive(
            &pkgdest.join("python-3.12-1-x86_64.pkg.tar.zst"),
            "python",
            "3.12-1",
        );
        std::fs::write(
            pkgdest.join("python-3.12-1-x86_64.pkg.tar.zst.gsa-vcs-revisions"),
            "revs",
        )
        .unwrap();
        write_pkg_archive(
            &pkgdest.join("python-3.11-2-x86_64.pkg.tar.zst"),
            "python",
            "3.11-2",
        );
        // ... and two foreign archives: `python-attrs` shares the `python-`
        // name prefix (the prefix bug deletes it), `python-libs` is a split
        // output this recipe never declared.
        write_pkg_archive(
            &pkgdest.join("python-attrs-2.0-1-x86_64.pkg.tar.zst"),
            "python-attrs",
            "2.0-1",
        );
        std::fs::write(
            pkgdest.join("python-attrs-2.0-1-x86_64.pkg.tar.zst.gsa-vcs-revisions"),
            "revs",
        )
        .unwrap();
        write_pkg_archive(
            &pkgdest.join("python-libs-3.12-1-x86_64.pkg.tar.zst"),
            "python-libs",
            "3.12-1",
        );
        let mut report = CleanReport::default();
        clean_recipe(
            &recipe,
            "python",
            &["python".to_string()],
            Some(&layout),
            &mut report,
        );
        assert!(
            pkgdest.join("python-attrs-2.0-1-x86_64.pkg.tar.zst").exists(),
            "an unselected recipe's archive must survive the prune (output-name truth, not prefix)"
        );
        assert!(
            pkgdest.join("python-attrs-2.0-1-x86_64.pkg.tar.zst.gsa-vcs-revisions").exists(),
            "a surviving archive's sidecar must survive with it"
        );
        assert!(
            pkgdest.join("python-libs-3.12-1-x86_64.pkg.tar.zst").exists(),
            "an output name this recipe never declared must survive the prune"
        );
        assert!(
            !pkgdest.join("python-3.12-1-x86_64.pkg.tar.zst").exists(),
            "the current-version archive must be pruned"
        );
        assert!(
            !pkgdest.join("python-3.12-1-x86_64.pkg.tar.zst.gsa-vcs-revisions").exists(),
            "a pruned archive's sidecar must be pruned with it"
        );
        assert!(
            !pkgdest.join("python-3.11-2-x86_64.pkg.tar.zst").exists(),
            "a stale-version archive of our own output must be pruned (its .PKGINFO says python)"
        );
        assert!(report.errors.is_empty(), "{:?}", report.errors);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn pruned_archives_take_their_vcs_sidecars_with_them() {
        let (dir, recipe, _layout) = scratch_layout("sidecar");
        write_pkg_archive(
            &recipe.join("a-1.0-1-any.pkg.tar.zst"),
            "a",
            "1.0-1",
        );
        std::fs::write(
            recipe.join("a-1.0-1-any.pkg.tar.zst.gsa-vcs-revisions"),
            "revs",
        )
        .unwrap();
        let mut report = CleanReport::default();
        clean_recipe(&recipe, "a", &["a".to_string()], None, &mut report);
        assert!(!recipe.join("a-1.0-1-any.pkg.tar.zst").exists());
        assert!(
            !recipe.join("a-1.0-1-any.pkg.tar.zst.gsa-vcs-revisions").exists(),
            "the recipe-dir prune must take the sidecar exactly when its archive goes"
        );
        assert!(report.errors.is_empty(), "{:?}", report.errors);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
