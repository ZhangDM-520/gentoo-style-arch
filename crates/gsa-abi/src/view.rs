//! The installed-ELF view (docs/plans/plan-native-pm.md §4.4): a read-only projection
//! of pacman's local database plus a file probe over the ELF files it owns
//! — the "installed ELF DB" every revdep, preserved-lib and content-truth
//! check reads. The hybrid model allows reads; nothing here writes.
//!
//! The probe root is `/` in production (owned paths are slash-less,
//! `usr/lib/…`); tests may mount a synthetic root. `gsa-install::LocalDb`
//! converts into this view at the seam — the parse stays there, the ABI
//! semantics stay here.

use std::collections::BTreeMap;
use std::path::PathBuf;

use crate::provides::{provide_covers, provide_covers_as, provide_name};
pub use gsa_model::abi::{path_class, ElfClass};

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
    /// basename -> the owned paths carrying it (class + liveness filtering
    /// needs the paths, not just the names). ONE index: an exact-path set
    /// beside it duplicated every owned path without answering anything
    /// this cannot (a path sits in the map under its own basename).
    basenames: BTreeMap<String, Vec<String>>,
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
            basenames: BTreeMap::new(),
            root,
        };
        for pkg in pkgs {
            for file in &pkg.files {
                let normalized = file.strip_prefix('/').unwrap_or(file);
                if let Some(base) = normalized.rsplit('/').next() {
                    view.basenames
                        .entry(base.to_string())
                        .or_default()
                        .push(normalized.to_string());
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

    /// Class-scoped [`Self::provides_cover`]: an auto-versioned `-32`/`-64`
    /// provide covers only a consumer member in the same [`ElfClass`].
    pub fn provides_cover_as(&self, dep: &str, class: ElfClass) -> bool {
        let name = provide_name(dep);
        if name.is_empty() {
            return false;
        }
        self.pkgs.values().any(|pkg| {
            pkg.name == name
                || pkg
                    .provides
                    .iter()
                    .any(|p| provide_covers_as(p, name, class))
        })
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

    /// Class-scoped [`Self::providers_of`].
    pub fn providers_of_as(&self, dep: &str, class: ElfClass) -> Vec<&InstalledPkg> {
        let name = provide_name(dep);
        self.pkgs
            .values()
            .filter(|pkg| {
                pkg.name == name
                    || pkg
                        .provides
                        .iter()
                        .any(|p| provide_covers_as(p, name, class))
            })
            .collect()
    }

    /// The installed packages owning the named file (exact path or the same
    /// basename) — runtime file truth for providers that declare no soname
    /// provide (stock Arch, rule 25(b)).
    pub fn file_owners(&self, path: &str) -> Vec<&InstalledPkg> {
        self.file_owners_as(path, path_class(path))
    }

    /// Class-scoped [`Self::file_owners`]: only owned files in `class` match.
    pub fn file_owners_as(&self, path: &str, class: ElfClass) -> Vec<&InstalledPkg> {
        let normalized = path.strip_prefix('/').unwrap_or(path);
        let base = normalized.rsplit('/').next().unwrap_or("");
        self.pkgs
            .values()
            .filter(|pkg| {
                pkg.files.iter().any(|f| {
                    let f = f.strip_prefix('/').unwrap_or(f);
                    path_class(f) == class
                        && (f == normalized || f.rsplit('/').next() == Some(base))
                })
            })
            .collect()
    }

    /// True when some installed package owns a file whose path or basename
    /// matches AND that file is really present at the probe root in the
    /// requested ELF class (rule 25(b) runtime file truth).
    ///
    /// Two measured masking bugs are closed here: a `lib32-*` basename must
    /// not satisfy a 64-bit need (the lib32-icu class that hid the icu .78
    /// breakage), and a listed-but-dangling symlink must not count as a
    /// resolution (the `tk` `libtk.so -> libtk9.0.so` class).
    pub fn owns_file_as(&self, path: &str, class: ElfClass) -> bool {
        let base = path
            .strip_prefix('/')
            .unwrap_or(path)
            .rsplit('/')
            .next()
            .unwrap_or("");
        let Some(candidates) = self.basenames.get(base) else {
            return false;
        };
        candidates
            .iter()
            .any(|candidate| path_class(candidate) == class && self.root.join(candidate).exists())
    }

    /// Strict file truth for the dominant class of the probe path itself
    /// (bare sonames probe as 64-bit).
    pub fn owns_file(&self, path: &str) -> bool {
        self.owns_file_as(path, path_class(path))
    }

    /// Read one owned ELF file's bytes through the view root.
    ///
    /// The probe set is every file an ELF home can hold (`usr/lib` alone is
    /// 371 K of this host's 936 K owned paths), but only 25 757 files under
    /// `/usr` are ELF: 380 357 of one `@core` plan's 385 498 `openat` calls,
    /// and 87% of its sampled cycles in the kernel, were spent reading files
    /// whose first four bytes answer the question. The magic gate reads those
    /// four bytes and stops, so a non-ELF path costs one `open` and one `read`
    /// and never enters the allocator or `object::File::parse`.
    ///
    /// A caller that wants another file's bytes does not exist: every reader
    /// here parses `DT_SONAME`/`DT_NEEDED`, and `object::File::parse` rejects
    /// non-ELF anyway — the gate skips work, never a finding. Missing,
    /// unreadable and non-ELF files all yield `None` and are skipped by
    /// callers (never guessed).
    pub fn read_elf(&self, rel: &str) -> Option<Vec<u8>> {
        use std::io::Read;
        let normalized = rel.strip_prefix('/').unwrap_or(rel);
        let mut file = std::fs::File::open(self.root.join(normalized)).ok()?;
        let mut magic = [0u8; 4];
        if file.read_exact(&mut magic).is_err() || magic != *b"\x7fELF" {
            return None;
        }
        let mut bytes = Vec::with_capacity(64 * 1024);
        bytes.extend_from_slice(&magic);
        file.read_to_end(&mut bytes).ok()?;
        Some(bytes)
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
        let dir = std::env::temp_dir().join(format!("gsa-abi-truth-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("usr/lib")).unwrap();
        std::fs::write(dir.join("usr/lib/libstock.so.1"), b"payload").unwrap();
        let view = InstalledView::with_root(
            dir.clone(),
            [
                pkg("libfoo-git", &["libfoo.so=1-64"], &["usr/lib/libfoo.so.1"]),
                pkg("stock", &[], &["usr/lib/libstock.so.1"]),
            ],
        );
        assert!(view.provides_cover("libfoo.so.1"));
        assert!(!view.provides_cover("libfoo.so.2"));
        assert!(view.owns_file("libstock.so.1"));
        assert!(view.owns_file("/usr/lib/libstock.so.1"));
        assert!(!view.owns_file("libgone.so.1"));
        assert_eq!(view.providers_of("libfoo.so.1").len(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn lib32_owners_do_not_satisfy_64bit_probes() {
        let dir = std::env::temp_dir().join(format!("gsa-abi-class-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("usr/lib32")).unwrap();
        std::fs::write(dir.join("usr/lib32/libicuuc.so.78"), b"32").unwrap();
        let view = InstalledView::with_root(
            dir.clone(),
            [pkg("lib32-icu", &[], &["usr/lib32/libicuuc.so.78"])],
        );
        // the measured masking: the lib32 basename hid a 64-bit 'not found'
        assert!(!view.owns_file_as("libicuuc.so.78", ElfClass::X64));
        assert!(!view.owns_file("libicuuc.so.78"));
        assert!(view.owns_file_as("libicuuc.so.78", ElfClass::X32));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn dangling_symlinks_are_not_file_truth() {
        let dir = std::env::temp_dir().join(format!("gsa-abi-dangle-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("usr/lib")).unwrap();
        std::os::unix::fs::symlink("libtk9.0.so", dir.join("usr/lib/libtk.so")).unwrap();
        let view = InstalledView::with_root(dir.clone(), [pkg("tk", &[], &["usr/lib/libtk.so"])]);
        // the measured tk class: listed, but dangling — not a resolution
        assert!(!view.owns_file("libtk.so"));
        std::fs::write(dir.join("usr/lib/libtk9.0.so"), b"tk").unwrap();
        assert!(view.owns_file("libtk.so"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_probe_reads_through_the_view_root() {
        let dir = std::env::temp_dir().join(format!("gsa-abi-view-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("usr/lib")).unwrap();
        std::fs::write(
            dir.join("usr/lib/libx.so.1"),
            b"\x7fELF\x02\x01\x01\x00payload",
        )
        .unwrap();
        std::fs::write(dir.join("usr/lib/python-stdlib.py"), b"import os\n").unwrap();
        let view = InstalledView::with_root(
            dir.clone(),
            [
                pkg("x", &[], &["usr/lib/libx.so.1"]),
                pkg("py", &[], &["usr/lib/python-stdlib.py"]),
            ],
        );
        assert_eq!(
            view.read_elf("usr/lib/libx.so.1").unwrap(),
            b"\x7fELF\x02\x01\x01\x00payload"
        );
        assert!(view.read_elf("usr/lib/libmissing.so").is_none());
        // An ELF home is not an ELF file: the magic gate answers without
        // reading the body, and no caller loses a finding to it.
        assert!(view.read_elf("usr/lib/python-stdlib.py").is_none());
        assert_eq!(
            view.probe_path("usr/lib/libx.so.1"),
            dir.join("usr/lib/libx.so.1")
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
