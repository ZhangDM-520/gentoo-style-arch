//! A native, read-only reader for pacman's local database (the installed DB
//! of record — contract §A.2.2). The decision seam must touch NO pacman
//! subprocess (§D.1), so installed state is read directly from
//! `<db-root>/local/<name>-<ver>/{desc,files,depends}`: `%NAME%`, `%VERSION%`,
//! `%BASE%`, `%PROVIDES%`, `%DEPENDS%`, and the `files` list. The install
//! date is the entry directory's mtime (what `pacman -Qi` reports as
//! "Install Date").

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::time::SystemTime;

use gsa_recipe::pkginfo::canonical_version;

/// One installed package as pacman's local DB records it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct InstalledPackage {
    pub name: String,
    /// `%VERSION%`, canonically `epoch:pkgver-pkgrel` (epoch 0 included).
    pub version: String,
    pub base: Option<String>,
    /// `%DESC%` — the one-line description (`pacman -Qs` searches it).
    pub desc: Option<String>,
    pub provides: Vec<String>,
    pub depends: Vec<String>,
    /// Absolute owned paths (from the `files` list).
    pub files: Vec<String>,
    /// The entry directory's mtime — the install date.
    pub install_date: Option<SystemTime>,
}

/// The parsed installed DB, memoized for one decision.
#[derive(Clone, Debug, Default)]
pub struct LocalDb {
    packages: BTreeMap<String, InstalledPackage>,
    /// basename -> the owned paths carrying it (class + liveness filtering
    /// needs the paths, not just the names). This is the ONE file index:
    /// an exact-path set beside it was a second copy of every owned path for
    /// no answer it could not give (a path is in `basenames` under its own
    /// basename by construction, so membership is an equality test on that
    /// entry) — 936 K allocations and a BTree node per path on this host.
    basenames: BTreeMap<String, Vec<String>>,
    /// Where owned files are probed for existence (production: `/`).
    root: PathBuf,
    /// Entries this read could not establish: an unreadable `desc`, a missing
    /// `%NAME%`/`%VERSION%`, a `files` list that is not a readable file. Rule
    /// 71: an unreadable file is NOT an absent one — an installed consumer
    /// this read cannot see silently narrowed the ABI gate's world (a moving
    /// soname with its linked consumer hidden installed clean and broke the
    /// link; blind review, 2026-11-11). Listings note them and continue; a
    /// gate that decides on the installed view must refuse.
    pub unreadable: Vec<String>,
}

/// Parse one pacman local-DB entry file (`desc`/`files`): `%KEY%` headers,
/// values until the next blank line or header.
fn parse_sections(text: &str) -> BTreeMap<String, Vec<String>> {
    let mut sections: BTreeMap<String, Vec<String>> = BTreeMap::new();
    let mut current: Option<String> = None;
    for raw_line in text.lines() {
        let line = raw_line.trim();
        if line.is_empty() {
            current = None;
            continue;
        }
        if line.starts_with('%') && line.ends_with('%') && line.len() >= 2 {
            current = Some(line[1..line.len() - 1].to_string());
            continue;
        }
        if let Some(key) = &current {
            sections
                .entry(key.clone())
                .or_default()
                .push(line.to_string());
        }
    }
    sections
}

fn first(sections: &BTreeMap<String, Vec<String>>, key: &str) -> Option<String> {
    sections.get(key).and_then(|v| v.first().cloned())
}

/// One `%KEY%` section's values as borrowed lines — `parse_sections` for a
/// caller that wants exactly one key. The `files` list is 936 K lines on a
/// desktop host, and materializing the whole `BTreeMap<String, Vec<String>>`
/// to read one of them cost two allocations per owned path (measured: 1.87 M
/// of `gsa -Q`'s 5.08 M allocations, `heaptrack`). The body is not copied and
/// the section is never built.
fn section_lines<'a>(text: &'a str, key: &'a str) -> impl Iterator<Item = &'a str> {
    let mut inside = false;
    text.lines().filter_map(move |raw| {
        let line = raw.trim();
        if line.is_empty() {
            inside = false;
            return None;
        }
        if line.starts_with('%') && line.ends_with('%') && line.len() >= 2 {
            inside = &line[1..line.len() - 1] == key;
            return None;
        }
        inside.then_some(line)
    })
}

/// Strip a leading slash so `files`-list paths and query paths compare as
/// pacman records them (the `files` list is rooted, slash-less).
fn normalize_path(path: &str) -> &str {
    path.strip_prefix('/').unwrap_or(path)
}

impl LocalDb {
    /// Read `<db-root>/local/*`. A missing/unreadable entry directory is
    /// skipped loudly (doubt installs — rule 11), never guessed. A db root
    /// without a `local/` directory is an empty DB (synthetic workspaces).
    ///
    /// Probe-root override for fixtures: `_GSA_TEST_PROBE_ROOT` redirects
    /// the liveness half of rule 25(b) to a synthetic root (the
    /// `from_packages_at` twin) so fixtures can pin BOTH halves of file
    /// truth. Unset (production) = `/`. The leading underscore keeps it out
    /// of the engine's advertised `GSA_` namespace: an unadvertised override
    /// must never look like an operator knob (the `_GSA_STOP_GRACE_S`
    /// convention).
    pub fn load(db_root: &Path) -> Result<LocalDb, String> {
        let probe_root = std::env::var_os("_GSA_TEST_PROBE_ROOT")
            .map(PathBuf::from)
            .unwrap_or_default();
        Self::load_at(probe_root, db_root)
    }

    /// `load` with an explicit owned-file probe root (empty = production
    /// `/`): fixtures materialize owned files under a synthetic root to pin
    /// BOTH halves of rule 25(b) file truth — the `from_packages_at` twin.
    pub fn load_at(probe_root: PathBuf, db_root: &Path) -> Result<LocalDb, String> {
        let local = db_root.join("local");
        let mut db = LocalDb {
            root: probe_root,
            ..LocalDb::default()
        };
        let entries = match std::fs::read_dir(&local) {
            Ok(entries) => entries,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(db),
            Err(e) => return Err(format!("cannot read {}: {e}", local.display())),
        };
        for entry in entries.flatten() {
            let dir = entry.path();
            if !dir.is_dir() {
                continue;
            }
            let desc = match std::fs::read_to_string(dir.join("desc")) {
                Ok(text) => text,
                Err(e) => {
                    let note = format!("{}: {e}", dir.display());
                    eprintln!("gsa: note: skipping unreadable local-DB entry {note}");
                    db.unreadable.push(note);
                    continue;
                }
            };
            let sections = parse_sections(&desc);
            let (Some(name), Some(version)) =
                (first(&sections, "NAME"), first(&sections, "VERSION"))
            else {
                let note = format!("{}: missing %NAME%/%VERSION%", dir.display());
                eprintln!("gsa: note: skipping malformed local-DB entry ({note})");
                db.unreadable.push(note);
                continue;
            };
            let provides = sections.get("PROVIDES").cloned().unwrap_or_default();
            let depends = sections.get("DEPENDS").cloned().unwrap_or_default();
            let base = first(&sections, "BASE");
            let package_desc = first(&sections, "DESC");
            let mut files: Vec<String> = Vec::new();
            match std::fs::read_to_string(dir.join("files")) {
                Ok(files_text) => {
                    for path in section_lines(&files_text, "FILES") {
                        files.push(normalize_path(path).to_string());
                    }
                }
                // No `files` file is legal (a package owning nothing); a
                // `files` that exists and cannot be read is an unknown owned
                // set, which is exactly what the link and soname gates read.
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
                Err(e) => {
                    let note = format!("{}/files: {e}", dir.display());
                    eprintln!("gsa: note: unreadable local-DB file list {note}");
                    db.unreadable.push(note);
                }
            }
            for path in &files {
                if let Some(base_name) = path.rsplit('/').next() {
                    db.basenames
                        .entry(base_name.to_string())
                        .or_default()
                        .push(path.to_string());
                }
            }
            let install_date = std::fs::metadata(&dir).ok().and_then(|m| m.modified().ok());
            db.packages.insert(
                name.clone(),
                InstalledPackage {
                    name,
                    version: canonical_version(&version),
                    base,
                    desc: package_desc,
                    provides,
                    depends,
                    files,
                    install_date,
                },
            );
        }
        Ok(db)
    }

    pub fn get(&self, name: &str) -> Option<&InstalledPackage> {
        self.packages.get(name)
    }

    pub fn packages(&self) -> Vec<&InstalledPackage> {
        self.packages.values().collect()
    }

    /// Build a DB directly from parsed entries (fixture seam: a synthetic
    /// installed state without a `<db>/local/` tree — additive to the fixed
    /// surface). File truth probes at `/`.
    pub fn from_packages(pkgs: Vec<InstalledPackage>) -> LocalDb {
        Self::from_packages_at(PathBuf::from("/"), pkgs)
    }

    /// The `from_packages` twin whose file truth probes under `root`
    /// (synthetic probe roots in tests — `gsa-abi::view::with_root` twin).
    pub fn from_packages_at(root: PathBuf, pkgs: Vec<InstalledPackage>) -> LocalDb {
        let mut db = LocalDb {
            root,
            ..LocalDb::default()
        };
        for pkg in pkgs {
            for path in &pkg.files {
                let normalized = normalize_path(path).to_string();
                if let Some(base_name) = normalized.rsplit('/').next() {
                    db.basenames
                        .entry(base_name.to_string())
                        .or_default()
                        .push(normalized);
                }
            }
            db.packages.insert(pkg.name.clone(), pkg);
        }
        db
    }

    /// True when some installed package's name or provide set covers `dep`
    /// (soname auto-version semantics via `provide_covers`).
    pub fn provides_cover(&self, dep: &str) -> bool {
        let name = provide_name(dep);
        if name.is_empty() {
            return false;
        }
        self.packages
            .values()
            .any(|pkg| pkg.name == name || pkg.provides.iter().any(|p| provide_covers(p, name)))
    }

    /// Where owned files are probed (empty root = production `/`).
    fn probe_root(&self) -> &Path {
        if self.root.as_os_str().is_empty() {
            Path::new("/")
        } else {
            &self.root
        }
    }

    /// True when some installed package owns a file whose basename or full
    /// path matches AND that file is really present at the probe root in the
    /// requested ELF class (rule 25(b) runtime file truth — the
    /// `gsa-abi::view::owns_file_as` twin: a lib32 basename must not resolve
    /// a 64-bit need, and a listed-but-dangling symlink is not file truth).
    pub fn owns_file_as(&self, path: &str, class: ElfClass) -> bool {
        let base = normalize_path(path).rsplit('/').next().unwrap_or("");
        let Some(candidates) = self.basenames.get(base) else {
            return false;
        };
        candidates.iter().any(|candidate| {
            path_class(candidate) == class && self.probe_root().join(candidate).exists()
        })
    }

    /// Strict file truth for the dominant class of the probe path itself
    /// (bare sonames probe as 64-bit).
    pub fn owns_file(&self, path: &str) -> bool {
        self.owns_file_as(path, path_class(path))
    }
}

// The provide/soname semantics are SHARED with the ABI subsystem — the
// ONE matcher lives in `gsa-abi::provides` (rule 25(a)/(b)); these
// re-exports keep the local-DB surface stable without forking the logic.
pub use gsa_abi::view::{path_class, ElfClass};
pub use gsa_abi::{provide_covers, provide_name, soname_stem};

/// The pacman DB root (`pacman-conf DBPath`, falling back to
/// `/var/lib/pacman`). `pacman-conf` is a read-only configuration reader,
/// never pacman and never a transaction — the seam stays pacman-free (§D.1).
pub fn pacman_db_root() -> PathBuf {
    if let Ok(output) = std::process::Command::new("pacman-conf")
        .arg("DBPath")
        .output()
    {
        if output.status.success() {
            let text = String::from_utf8_lossy(&output.stdout).trim().to_string();
            if !text.is_empty() {
                return PathBuf::from(text);
            }
        }
    }
    PathBuf::from("/var/lib/pacman")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::time::Duration;

    fn scratch(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("gsa-localdb-test-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn write_entry(root: &Path, dir_name: &str, desc: &str, files: &str) -> PathBuf {
        let dir = root.join("local").join(dir_name);
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join("desc"), desc).unwrap();
        fs::write(dir.join("files"), files).unwrap();
        dir
    }

    #[test]
    fn the_unadvertised_probe_root_override_steers_load() {
        // `_GSA_TEST_PROBE_ROOT` (leading underscore = not an advertised
        // `GSA_` operator knob) redirects the liveness half of rule 25(b)
        // for fixtures; `load_at` remains the direct seam.
        let root = scratch("probe-root-env");
        let probe = root.join("root");
        fs::create_dir_all(probe.join("usr/lib")).unwrap();
        fs::write(probe.join("usr/lib/libprobe.so.1"), b"\x7fELF").unwrap();
        write_entry(
            &root,
            "probe-0:1-1",
            "%NAME%\nprobe\n\n%VERSION%\n1-1\n\n",
            "%FILES%\nusr/lib/libprobe.so.1\n",
        );

        let saved = std::env::var_os("_GSA_TEST_PROBE_ROOT");
        std::env::set_var("_GSA_TEST_PROBE_ROOT", &probe);
        let db = LocalDb::load(&root);
        match saved {
            Some(value) => std::env::set_var("_GSA_TEST_PROBE_ROOT", value),
            None => std::env::remove_var("_GSA_TEST_PROBE_ROOT"),
        }
        let db = db.unwrap();
        assert!(db.get("probe").is_some(), "the synthetic entry parses");
        assert!(
            db.owns_file("usr/lib/libprobe.so.1"),
            "the override steers the file-truth probe root"
        );
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn load_parses_desc_files_and_install_date() {
        let root = scratch("load");
        write_entry(
            &root,
            "foo-0:1.2-1",
            "%NAME%\nfoo\n\n%VERSION%\n1.2-1\n\n%BASE%\nfoo\n\n%PROVIDES%\nlibfoo.so=1-64\nbar=1.0\n\n%DEPENDS%\nglibc>=2.28\n",
            "%FILES%\nusr/bin/foo\nusr/lib/libfoo.so.1\n",
        );
        let before = SystemTime::now() - Duration::from_secs(3600);
        let db = LocalDb::load(&root).unwrap();
        let pkg = db.get("foo").unwrap();
        assert_eq!(pkg.version, "0:1.2-1");
        assert_eq!(pkg.base.as_deref(), Some("foo"));
        assert_eq!(pkg.provides, vec!["libfoo.so=1-64", "bar=1.0"]);
        assert_eq!(pkg.depends, vec!["glibc>=2.28"]);
        assert_eq!(pkg.files, vec!["usr/bin/foo", "usr/lib/libfoo.so.1"]);
        assert!(pkg.install_date.unwrap() > before);
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn load_skips_malformed_entries_and_tolerates_a_missing_local_dir() {
        let root = scratch("skip");
        write_entry(&root, "bad-1-1", "%VERSION%\n1-1\n", "");
        let db = LocalDb::load(&root).unwrap();
        assert!(db.get("bad").is_none());

        let empty_root = scratch("empty");
        let db = LocalDb::load(&empty_root).unwrap();
        assert!(db.packages().is_empty());
        let _ = fs::remove_dir_all(&root);
        let _ = fs::remove_dir_all(&empty_root);
    }

    #[test]
    fn file_truth_is_class_aware_and_existence_checked() {
        let probe = scratch("truth");
        fs::create_dir_all(probe.join("usr/lib32")).unwrap();
        fs::create_dir_all(probe.join("usr/lib")).unwrap();
        fs::write(probe.join("usr/lib32/libicuuc.so.78"), b"\x7fELF").unwrap();
        let lib32_icu = InstalledPackage {
            name: "lib32-icu".to_string(),
            version: "0:78-1".to_string(),
            base: Some("lib32-icu".to_string()),
            desc: None,
            provides: vec![],
            depends: vec![],
            files: vec!["usr/lib32/libicuuc.so.78".to_string()],
            install_date: None,
        };
        let db = LocalDb::from_packages_at(probe.clone(), vec![lib32_icu]);
        assert!(db.owns_file("usr/lib32/libicuuc.so.78"));
        assert!(db.owns_file_as("libicuuc.so.78", ElfClass::X32));
        assert!(
            !db.owns_file("libicuuc.so.78"),
            "a lib32 owner must not resolve a bare (64-bit) soname probe"
        );

        // A listed-but-dangling path (the `tk` `libtk.so` class) is not
        // file truth: `usr/lib/libtk.so` is owned but absent at the root.
        let tk = InstalledPackage {
            name: "tk".to_string(),
            version: "0:9-1".to_string(),
            base: Some("tk".to_string()),
            desc: None,
            provides: vec![],
            depends: vec![],
            files: vec!["usr/lib/libtk.so".to_string()],
            install_date: None,
        };
        let db = LocalDb::from_packages_at(probe.clone(), vec![tk]);
        assert!(!db.owns_file("libtk.so"));
        fs::write(probe.join("usr/lib/libtk.so"), b"\x7fELF").unwrap();
        assert!(db.owns_file("libtk.so"));
        let _ = fs::remove_dir_all(&probe);
    }

    #[test]
    fn provides_cover_uses_the_soname_family() {
        let root = scratch("cover");
        write_entry(
            &root,
            "foo-0:1-1",
            "%NAME%\nfoo\n\n%VERSION%\n1-1\n\n%PROVIDES%\nlibfoo.so=1-64\nmeson=1.8\n",
            "",
        );
        let db = LocalDb::load(&root).unwrap();
        assert!(db.provides_cover("libfoo.so.1"));
        assert!(db.provides_cover("libfoo.so"));
        assert!(!db.provides_cover("libfoo.so.2"));
        assert!(db.provides_cover("meson"));
        assert!(db.provides_cover("meson>=1.0"));
        assert!(!db.provides_cover("libbar.so.3"));
        assert!(db.provides_cover("foo"));
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn provide_covers_matches_families_and_exact_names() {
        assert!(provide_covers("libfoo.so", "libfoo.so.1.2"));
        assert!(provide_covers("libfoo.so=1-64", "libfoo.so.1"));
        assert!(!provide_covers("libfoo.so=1-64", "libfoo.so.2"));
        assert!(provide_covers("libfoo.so=1-64", "libfoo.so"));
        assert!(provide_covers("meson", "meson"));
        assert!(provide_covers("meson=1.8", "meson"));
        assert!(!provide_covers("meson", "mesoon"));
        assert!(!provide_covers("", "libfoo.so.1"));
    }

    #[test]
    fn soname_stem_shapes() {
        assert_eq!(soname_stem("libfoo.so"), Some("libfoo.so"));
        assert_eq!(soname_stem("libfoo.so.1.2"), Some("libfoo.so"));
        assert_eq!(soname_stem("meson"), None);
    }
}
