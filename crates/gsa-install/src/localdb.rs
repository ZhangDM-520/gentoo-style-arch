//! A native, read-only reader for pacman's local database (the installed DB
//! of record — contract §A.2.2). The decision seam must touch NO pacman
//! subprocess (§D.1), so installed state is read directly from
//! `<db-root>/local/<name>-<ver>/{desc,files,depends}`: `%NAME%`, `%VERSION%`,
//! `%BASE%`, `%PROVIDES%`, `%DEPENDS%`, and the `files` list. The install
//! date is the entry directory's mtime (what `pacman -Qi` reports as
//! "Install Date").

use std::collections::{BTreeMap, BTreeSet};
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
    /// Every owned path (no leading slash) and every owned basename — the
    /// runtime file truth of rule 25(b), indexed once per load.
    paths: BTreeSet<String>,
    basenames: BTreeSet<String>,
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

/// Strip a leading slash so `files`-list paths and query paths compare as
/// pacman records them (the `files` list is rooted, slash-less).
fn normalize_path(path: &str) -> &str {
    path.strip_prefix('/').unwrap_or(path)
}

impl LocalDb {
    /// Read `<db-root>/local/*`. A missing/unreadable entry directory is
    /// skipped loudly (doubt installs — rule 11), never guessed. A db root
    /// without a `local/` directory is an empty DB (synthetic workspaces).
    pub fn load(db_root: &Path) -> Result<LocalDb, String> {
        let local = db_root.join("local");
        let mut db = LocalDb::default();
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
                    eprintln!(
                        "gsa: note: skipping unreadable local-DB entry {}: {e}",
                        dir.display()
                    );
                    continue;
                }
            };
            let sections = parse_sections(&desc);
            let (Some(name), Some(version)) =
                (first(&sections, "NAME"), first(&sections, "VERSION"))
            else {
                eprintln!(
                    "gsa: note: skipping malformed local-DB entry {} (missing %NAME%/%VERSION%)",
                    dir.display()
                );
                continue;
            };
            let provides = sections.get("PROVIDES").cloned().unwrap_or_default();
            let depends = sections.get("DEPENDS").cloned().unwrap_or_default();
            let base = first(&sections, "BASE");
            let mut files: Vec<String> = Vec::new();
            if let Ok(files_text) = std::fs::read_to_string(dir.join("files")) {
                for path in parse_sections(&files_text)
                    .get("FILES")
                    .cloned()
                    .unwrap_or_default()
                {
                    files.push(normalize_path(&path).to_string());
                }
            }
            for path in &files {
                db.paths.insert(path.to_string());
                if let Some(base_name) = path.rsplit('/').next() {
                    db.basenames.insert(base_name.to_string());
                }
            }
            let install_date = std::fs::metadata(&dir).ok().and_then(|m| m.modified().ok());
            db.packages.insert(
                name.clone(),
                InstalledPackage {
                    name,
                    version: canonical_version(&version),
                    base,
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
    /// surface).
    pub fn from_packages(pkgs: Vec<InstalledPackage>) -> LocalDb {
        let mut db = LocalDb::default();
        for pkg in pkgs {
            for path in &pkg.files {
                let normalized = normalize_path(path).to_string();
                if let Some(base_name) = normalized.rsplit('/').next() {
                    db.basenames.insert(base_name.to_string());
                }
                db.paths.insert(normalized);
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

    /// True when some installed package owns a file whose basename or full
    /// path matches (runtime file truth — rule 25(b)).
    pub fn owns_file(&self, path: &str) -> bool {
        let normalized = normalize_path(path);
        self.paths.contains(normalized)
            || self
                .basenames
                .contains(normalized.rsplit('/').next().unwrap_or(""))
    }
}

/// The name half of a provide/depend entry (`libfoo.so=1-64` → `libfoo.so`,
/// `meson>=1.8` → `meson`) — fish `abi_provide_name`.
pub fn provide_name(entry: &str) -> &str {
    entry.split(['=', '<', '>']).next().unwrap_or("").trim()
}

/// The bare soname stem of a provide NAME (`libfoo.so` or `libfoo.so.1.2` →
/// `libfoo.so`); `None` when the name is not soname-shaped — fish
/// `_lint_soname_stem`.
pub fn soname_stem(name: &str) -> Option<&str> {
    if name.ends_with(".so") {
        return Some(name);
    }
    let idx = name.find(".so.")?;
    Some(&name[..idx + 3])
}

/// Does one provide entry cover a dependency string? Bare soname provides
/// (`libfoo.so`, makepkg-auto-versioned to `libfoo.so=<ver>`) cover the
/// `libfoo.so.N` soname family (`docs/MEMORY.md` rule 25(a)); a versioned
/// NAME provide covers the name itself (constraint satisfaction stays
/// pacman's job at transaction time). This is the ONE matcher every
/// resolution source shares (fish `abi_provide_covers`).
/// The auto-versioned form covers only its own generation: `libfoo.so=1-64`
/// covers `libfoo.so` and `libfoo.so.1` (the `-64` pkgrel-ish suffix
/// stripped) but NOT `libfoo.so.2`, so a bumped consumer NEEDED no longer
/// resolves to the old provider and the violation can name both sides.
pub fn provide_covers(provide: &str, dep: &str) -> bool {
    let (name, ver) = match provide.split_once('=') {
        Some((n, v)) => (n.trim(), Some(v.trim())),
        None => (provide.trim(), None),
    };
    if name.is_empty() || dep.is_empty() {
        return false;
    }
    if name == dep {
        return true;
    }
    if soname_stem(dep) == Some(name) {
        let Some(ver) = ver else {
            return true;
        };
        if ver.is_empty() {
            return true;
        }
        // `1-64` → `1`: makepkg's auto-version is `<generation>-<pkgrel-ish>`.
        let generation = match ver.rfind('-') {
            Some(idx) => &ver[..idx],
            None => ver,
        };
        return dep == format!("{name}.{generation}");
    }
    false
}

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
        assert!(db.owns_file("usr/bin/foo"));
        assert!(db.owns_file("/usr/lib/libfoo.so.1"));
        assert!(db.owns_file("libfoo.so.1"));
        assert!(!db.owns_file("libfoo.so.2"));
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
