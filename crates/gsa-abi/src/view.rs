//! The installed-ELF view (plan-native-pm.md §4.4): a read-only projection
//! of pacman's local database plus a file probe over the ELF files it owns
//! — the "installed ELF DB" every revdep, preserved-lib and content-truth
//! check reads. The hybrid model allows reads; nothing here writes.
//!
//! The probe root is `/` in production (owned paths are slash-less,
//! `usr/lib/…`); tests may mount a synthetic root. `gsa-install::LocalDb`
//! converts into this view at the seam — the parse stays there, the ABI
//! semantics stay here.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use crate::provides::{provide_covers, provide_name};

/// One installed package as the ABI surfaces need it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InstalledPkg {
    pub name: String,
    /// Canonical full version `epoch:pkgver-pkgrel`.
    pub version: String,
    pub provides: Vec<String>,
    pub depends: Vec<String>,
    /// Slash-less owned paths (`usr/lib/libfoo.so.1`, from pacman's `files`).
    pub files: Vec<String>,
}

/// The installed-ELF view: packages, owned-path truth, and the file probe.
#[derive(Clone, Debug, Default)]
pub struct InstalledView {
    pkgs: BTreeMap<String, InstalledPkg>,
    paths: BTreeSet<String>,
    basenames: BTreeSet<String>,
    root: PathBuf,
}

impl InstalledView {
    /// A view over `pkgs` probing files at `/` (production).
    pub fn new(pkgs: impl IntoIterator<Item = InstalledPkg>) -> InstalledView {
        Self::with_root(PathBuf::from("/"), pkgs)
    }

    /// A view probing owned files under `root` (synthetic roots in tests).
    pub fn with_root(root: PathBuf, pkgs: impl IntoIterator<Item = InstalledPkg>) -> InstalledView {
        let mut view = InstalledView {
            pkgs: BTreeMap::new(),
            paths: BTreeSet::new(),
            basenames: BTreeSet::new(),
            root,
        };
        for pkg in pkgs {
            for file in &pkg.files {
                let normalized = file.strip_prefix('/').unwrap_or(file);
                view.paths.insert(normalized.to_string());
                if let Some(base) = normalized.rsplit('/').next() {
                    view.basenames.insert(base.to_string());
                }
            }
            view.pkgs.insert(pkg.name.clone(), pkg);
        }
        view
    }

    pub fn get(&self, name: &str) -> Option<&InstalledPkg> {
        self.pkgs.get(name)
    }

    pub fn packages(&self) -> impl Iterator<Item = &InstalledPkg> {
        self.pkgs.values()
    }

    /// True when some installed package's name or provide set covers `dep`
    /// (soname auto-version semantics via `provide_covers`).
    pub fn provides_cover(&self, dep: &str) -> bool {
        let name = provide_name(dep);
        if name.is_empty() {
            return false;
        }
        self.pkgs
            .values()
            .any(|pkg| pkg.name == name || pkg.provides.iter().any(|p| provide_covers(p, name)))
    }

    /// The installed packages whose name/provides cover `dep` (the provider
    /// lookup behind subscription recording).
    pub fn providers_of(&self, dep: &str) -> Vec<&InstalledPkg> {
        let name = provide_name(dep);
        self.pkgs
            .values()
            .filter(|pkg| pkg.name == name || pkg.provides.iter().any(|p| provide_covers(p, name)))
            .collect()
    }

    /// The installed packages owning the named file (exact path or the same
    /// basename) — runtime file truth for providers that declare no soname
    /// provide (stock Arch, rule 25(b)).
    pub fn file_owners(&self, path: &str) -> Vec<&InstalledPkg> {
        let normalized = path.strip_prefix('/').unwrap_or(path);
        let base = normalized.rsplit('/').next().unwrap_or("");
        self.pkgs
            .values()
            .filter(|pkg| {
                pkg.files.iter().any(|f| {
                    let f = f.strip_prefix('/').unwrap_or(f);
                    f == normalized || f.rsplit('/').next() == Some(base)
                })
            })
            .collect()
    }

    /// True when some installed package owns a file whose path or basename
    /// matches (runtime file truth — rule 25(b)).
    pub fn owns_file(&self, path: &str) -> bool {
        let normalized = path.strip_prefix('/').unwrap_or(path);
        self.paths.contains(normalized)
            || self
                .basenames
                .contains(normalized.rsplit('/').next().unwrap_or(""))
    }

    /// Read-only probe of one owned file's bytes through the view root.
    /// Missing/unreadable files yield `None` and are skipped by callers
    /// (never guessed).
    pub fn read_file(&self, rel: &str) -> Option<Vec<u8>> {
        let normalized = rel.strip_prefix('/').unwrap_or(rel);
        std::fs::read(self.root.join(normalized)).ok()
    }

    /// The root-joined path a probe would read (report rendering).
    pub fn probe_path(&self, rel: &str) -> PathBuf {
        self.root.join(rel.strip_prefix('/').unwrap_or(rel))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pkg(name: &str, provides: &[&str], files: &[&str]) -> InstalledPkg {
        InstalledPkg {
            name: name.to_string(),
            version: "0:1.0.0-1".to_string(),
            provides: provides.iter().map(|s| s.to_string()).collect(),
            depends: Vec::new(),
            files: files.iter().map(|s| s.to_string()).collect(),
        }
    }

    #[test]
    fn provide_and_file_truth_resolve_like_the_local_db() {
        let view = InstalledView::new([
            pkg("libfoo-git", &["libfoo.so=1-64"], &["usr/lib/libfoo.so.1"]),
            pkg("stock", &[], &["usr/lib/libstock.so.1"]),
        ]);
        assert!(view.provides_cover("libfoo.so.1"));
        assert!(!view.provides_cover("libfoo.so.2"));
        assert!(view.owns_file("libstock.so.1"));
        assert!(view.owns_file("/usr/lib/libstock.so.1"));
        assert!(!view.owns_file("libgone.so.1"));
        assert_eq!(view.providers_of("libfoo.so.1").len(), 1);
    }

    #[test]
    fn the_probe_reads_through_the_view_root() {
        let dir = std::env::temp_dir().join(format!("gsa-abi-view-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("usr/lib")).unwrap();
        std::fs::write(dir.join("usr/lib/libx.so.1"), b"payload").unwrap();
        let view = InstalledView::with_root(dir.clone(), [pkg("x", &[], &["usr/lib/libx.so.1"])]);
        assert_eq!(view.read_file("usr/lib/libx.so.1").unwrap(), b"payload");
        assert!(view.read_file("usr/lib/libmissing.so").is_none());
        assert_eq!(
            view.probe_path("usr/lib/libx.so.1"),
            dir.join("usr/lib/libx.so.1")
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
