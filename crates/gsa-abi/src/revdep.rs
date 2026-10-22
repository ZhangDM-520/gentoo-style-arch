//! Revdep queries (contract §B.3 `-Qr`, plan-native-pm.md §4.4): the
//! installed-ELF view answers three questions, all read-only —
//!
//! * **unresolved `DT_NEEDED`**: an installed ELF member needs a soname no
//!   installed provide, owned file, or base-system library resolves (rule
//!   25(b)'s resolution sources minus the transaction's own bytes).
//! * **preserved-lib survivors**: `preserve-libs` emulation (plan §4.4
//!   step 3b) retains a removed soname's file at a recorded path; a
//!   retained entry with ≥1 surviving consumer is a survivor. The registry
//!   is `<state>/abi/preserved-libs`, `soname|path|owner|version` per line.
//!   Detection of NEW candidates is the unresolved set: a consumer that
//!   keeps running on a deleted inode shows up as unresolved + missing file.
//! * **exact-pin leftovers**: an installed `name=version` depend whose pin
//!   no longer resolves to that exact version (rule 29: swap waves retire
//!   these, never rebuild them).

use std::path::{Path, PathBuf};

use crate::provides::{base_lib_ok, provide_name};
use crate::view::{path_class, InstalledPkg, InstalledView};

/// One unresolved `DT_NEEDED` of one installed ELF member.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct UnresolvedNeed {
    pub consumer: String,
    /// The owned file that carries the reference.
    pub member: String,
    pub soname: String,
}

/// One preserved-lib registry entry (plan §4.4 step 3b).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PreservedEntry {
    pub soname: String,
    /// Where the retained file lives (the recorded preserve path).
    pub path: String,
    pub owner: String,
    pub version: String,
}

/// A retained library still needed by at least one installed consumer —
/// the "survivor" the operator must heal with a rebuild wave.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PreservedSurvivor {
    pub entry: PreservedEntry,
    pub consumers: Vec<String>,
}

/// One exact-version depend pin that no longer holds (rule 29's leftovers).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ExactPin {
    pub consumer: String,
    /// The raw depend entry (`lib32foo=1.2.3-1`).
    pub dep: String,
    /// `dangling` (nothing provides the name) or `stale <installed>` (the
    /// provider is there at another version).
    pub status: String,
}

/// The `-Qr` report over one installed-ELF view.
#[derive(Clone, Debug, Default)]
pub struct RevdepReport {
    pub unresolved: Vec<UnresolvedNeed>,
    pub preserved: Vec<PreservedSurvivor>,
    pub exact_pins: Vec<ExactPin>,
}

impl RevdepReport {
    pub fn is_empty(&self) -> bool {
        self.unresolved.is_empty() && self.preserved.is_empty() && self.exact_pins.is_empty()
    }
}

/// The preserved-lib registry path under a state root (contract §J.1).
pub fn preserved_registry_path(state_root: &Path) -> PathBuf {
    state_root.join("abi").join("preserved-libs")
}

/// Load the preserved-lib registry: `soname|path|owner|version` lines.
/// A missing file is the empty registry; malformed lines are reported
/// through `corrupt` and never guessed.
pub fn load_preserved(path: &Path) -> Result<(Vec<PreservedEntry>, Vec<String>), String> {
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok((Vec::new(), Vec::new())),
        Err(e) => return Err(format!("cannot read {}: {e}", path.display())),
    };
    let mut entries = Vec::new();
    let mut corrupt = Vec::new();
    for (idx, line) in text.lines().enumerate() {
        if line.trim().is_empty() {
            continue;
        }
        let fields: Vec<&str> = line.split('|').collect();
        if fields.len() != 4 || fields.iter().any(|f| f.trim().is_empty()) {
            corrupt.push(format!(
                "{}:{}: malformed preserved-lib line",
                path.display(),
                idx + 1
            ));
            continue;
        }
        entries.push(PreservedEntry {
            soname: fields[0].to_string(),
            path: fields[1].to_string(),
            owner: fields[2].to_string(),
            version: fields[3].to_string(),
        });
    }
    Ok((entries, corrupt))
}

/// One exact pin: `name=version` (single `=`, no range operators).
fn exact_pin_of(dep: &str) -> Option<(&str, &str)> {
    if dep.contains(['<', '>']) {
        return None;
    }
    let (name, ver) = dep.split_once('=')?;
    if name.trim().is_empty() || ver.trim().is_empty() {
        return None;
    }
    Some((name.trim(), ver.trim()))
}

/// Version equality modulo the `0:` default epoch (`0:1.0-1` ≡ `1.0-1`);
/// every other difference is real drift.
fn versions_equivalent(a: &str, b: &str) -> bool {
    fn strip(v: &str) -> &str {
        v.strip_prefix("0:").unwrap_or(v)
    }
    strip(a) == strip(b)
}

/// The pin surfaces one provider offers for `name`, each as
/// `(version to compare, display string)`. A matching provide entry is the
/// pin surface (a soname provide moves with its ENTRY version, not the
/// provider's pkgver); without one, the package version itself is the
/// surface.
fn pin_surfaces<'a>(pkg: &'a InstalledPkg, name: &str) -> Vec<(String, &'a str)> {
    let entries: Vec<&str> = pkg
        .provides
        .iter()
        .filter(|e| provide_name(e) == name)
        .map(|s| s.as_str())
        .collect();
    if entries.is_empty() {
        return vec![(pkg.version.clone(), pkg.version.as_str())];
    }
    entries
        .into_iter()
        .map(|e| match e.split_once('=') {
            Some((_, v)) if !v.trim().is_empty() => (v.trim().to_string(), e),
            _ => (pkg.version.clone(), e),
        })
        .collect()
}

/// Does this provider hold the exact pin `name=version`?
fn pin_holds(pkg: &InstalledPkg, name: &str, ver: &str) -> bool {
    pin_surfaces(pkg, name)
        .into_iter()
        .any(|(surface, _)| versions_equivalent(ver, &surface))
}

/// The revdep report: unresolved needs, preserved-lib survivors, exact-pin
/// leftovers — all derived from the view and the registry (rule 25(j):
/// expectations are computed, never pinned).
pub fn revdep_report(view: &InstalledView, preserved: &[PreservedEntry]) -> RevdepReport {
    let mut report = RevdepReport::default();

    // (1) unresolved DT_NEEDED + (2) preserved survivor consumers.
    let mut needed_by: Vec<(String, String, String)> = Vec::new(); // (consumer, member, soname)
    for pkg in view.packages() {
        for file in &pkg.files {
            let Some(bytes) = view.read_file(file) else {
                continue; // missing/unreadable files are skipped, never guessed
            };
            for soname in gsa_recipe::elf::needed_libs(&bytes) {
                if base_lib_ok(&soname) {
                    continue;
                }
                needed_by.push((pkg.name.clone(), file.clone(), soname.clone()));
                // File truth resolves in the CONSUMER member's ELF class:
                // a lib32 member's need is satisfied by lib32-owned files.
                if view.provides_cover(&soname) || view.owns_file_as(&soname, path_class(file)) {
                    continue;
                }
                report.unresolved.push(UnresolvedNeed {
                    consumer: pkg.name.clone(),
                    member: file.clone(),
                    soname,
                });
            }
        }
    }
    for entry in preserved {
        let mut consumers: Vec<String> = needed_by
            .iter()
            .filter(|(_, _, soname)| {
                soname == &entry.soname
                    || (soname.starts_with(entry.soname.as_str()) && !view.provides_cover(soname))
            })
            .map(|(consumer, _, _)| consumer.clone())
            .collect();
        consumers.sort();
        consumers.dedup();
        if !consumers.is_empty() {
            report.preserved.push(PreservedSurvivor {
                entry: entry.clone(),
                consumers,
            });
        }
    }

    // (3) exact-pin leftovers.
    for pkg in view.packages() {
        for dep in &pkg.depends {
            let Some((name, ver)) = exact_pin_of(dep) else {
                continue;
            };
            let providers = view.providers_of(name);
            if providers.is_empty() {
                report.exact_pins.push(ExactPin {
                    consumer: pkg.name.clone(),
                    dep: dep.clone(),
                    status: "dangling".to_string(),
                });
                continue;
            }
            if !providers.iter().any(|p| pin_holds(p, name, ver)) {
                let installed = providers
                    .iter()
                    .flat_map(|p| pin_surfaces(p, name))
                    .map(|(_, display)| display)
                    .collect::<Vec<_>>()
                    .join(",");
                report.exact_pins.push(ExactPin {
                    consumer: pkg.name.clone(),
                    dep: dep.clone(),
                    status: format!("stale {installed}"),
                });
            }
        }
    }

    report
}

/// The `-Qr` row rendering (one line per finding, `<kind> …`).
pub fn render(report: &RevdepReport) -> Vec<String> {
    let mut rows = Vec::new();
    for u in &report.unresolved {
        rows.push(format!(
            "unresolved {} {} {}",
            u.consumer, u.member, u.soname
        ));
    }
    for s in &report.preserved {
        rows.push(format!(
            "preserved {} {} {} {} {}",
            s.entry.soname,
            s.entry.path,
            s.entry.owner,
            s.entry.version,
            s.consumers.join(",")
        ));
    }
    for p in &report.exact_pins {
        rows.push(format!("exact-pin {} {} {}", p.consumer, p.dep, p.status));
    }
    rows
}

/// The `-Qr` report from a state root's preserved registry plus the view
/// (the query surface's one call).
pub fn revdep_report_with_state(
    view: &InstalledView,
    state_root: &Path,
) -> Result<(RevdepReport, Vec<String>), String> {
    let (entries, corrupt) = load_preserved(&preserved_registry_path(state_root))?;
    Ok((revdep_report(view, &entries), corrupt))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support;
    use crate::view::InstalledPkg;

    fn pkg(name: &str, provides: &[&str], depends: &[&str], files: &[&str]) -> InstalledPkg {
        InstalledPkg {
            name: name.to_string(),
            version: "0:1.0.0-1".to_string(),
            provides: provides.iter().map(|s| s.to_string()).collect(),
            depends: depends.iter().map(|s| s.to_string()).collect(),
            files: files.iter().map(|s| s.to_string()).collect(),
        }
    }

    #[test]
    fn unresolved_needed_names_consumer_member_and_soname() {
        let dir = std::env::temp_dir().join(format!("gsa-abi-revdep-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("usr/lib")).unwrap();
        std::fs::write(
            dir.join("usr/lib/libapp.so.1"),
            test_support::elf64(Some("libapp.so.1"), &["libgone.so.9", "libc.so.6"]),
        )
        .unwrap();
        let view = InstalledView::with_root(
            dir.clone(),
            [pkg("app", &[], &[], &["usr/lib/libapp.so.1"])],
        );
        let report = revdep_report(&view, &[]);
        assert_eq!(report.unresolved.len(), 1, "libc.so.6 is base, resolved");
        let u = &report.unresolved[0];
        assert_eq!(
            (&u.consumer[..], &u.member[..], &u.soname[..]),
            ("app", "usr/lib/libapp.so.1", "libgone.so.9")
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn preserved_survivors_need_such_a_record_and_a_consumer() {
        let dir = std::env::temp_dir().join(format!("gsa-abi-preserved-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("usr/lib")).unwrap();
        std::fs::write(
            dir.join("usr/lib/libapp.so.1"),
            test_support::elf64(Some("libapp.so.1"), &["libgone.so.9"]),
        )
        .unwrap();
        let view = InstalledView::with_root(
            dir.clone(),
            [pkg("app", &[], &[], &["usr/lib/libapp.so.1"])],
        );
        let entries = vec![
            PreservedEntry {
                soname: "libgone.so.9".to_string(),
                path: "/var/lib/gsa/abi-preserved/libgone.so.9".to_string(),
                owner: "oldpkg".to_string(),
                version: "0:1.0-1".to_string(),
            },
            PreservedEntry {
                soname: "libunused.so.1".to_string(),
                path: "/var/lib/gsa/abi-preserved/libunused.so.1".to_string(),
                owner: "oldpkg2".to_string(),
                version: "0:1.0-1".to_string(),
            },
        ];
        let report = revdep_report(&view, &entries);
        assert_eq!(report.preserved.len(), 1, "only survivors are reported");
        assert_eq!(report.preserved[0].entry.soname, "libgone.so.9");
        assert_eq!(report.preserved[0].consumers, vec!["app".to_string()]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn exact_pin_leftovers_are_dangling_or_stale() {
        let view = InstalledView::new([
            pkg(
                "lib32-app",
                &[],
                &["lib64-app=2.0-1", "gone=1.0-1", "tool>=1"],
                &[],
            ),
            pkg("lib64-app", &[], &[], &[]),
        ]);
        let report = revdep_report(&view, &[]);
        assert_eq!(report.exact_pins.len(), 2);
        let dangling = report
            .exact_pins
            .iter()
            .find(|p| p.status == "dangling")
            .unwrap();
        assert_eq!(dangling.dep, "gone=1.0-1");
        let stale = report
            .exact_pins
            .iter()
            .find(|p| p.status.starts_with("stale"))
            .unwrap();
        assert_eq!(stale.dep, "lib64-app=2.0-1");
        assert_eq!(stale.status, "stale 0:1.0.0-1");
    }

    fn pkgv(
        name: &str,
        version: &str,
        provides: &[&str],
        depends: &[&str],
        files: &[&str],
    ) -> InstalledPkg {
        InstalledPkg {
            name: name.to_string(),
            version: version.to_string(),
            provides: provides.iter().map(|s| s.to_string()).collect(),
            depends: depends.iter().map(|s| s.to_string()).collect(),
            files: files.iter().map(|s| s.to_string()).collect(),
        }
    }

    #[test]
    fn an_epoch_only_difference_is_never_a_stale_pin() {
        let view = InstalledView::new([
            pkgv("consumer", "0:1-1", &[], &["app=1.0.0-1"], &[]),
            pkgv("app", "0:1.0.0-1", &[], &[], &[]),
        ]);
        let report = revdep_report(&view, &[]);
        assert!(
            report.exact_pins.is_empty(),
            "0:1.0.0-1 ≡ 1.0.0-1, got {:?}",
            report.exact_pins
        );
    }

    #[test]
    fn a_soname_pin_matches_the_provide_entry_not_the_pkgver() {
        let view = InstalledView::new([
            pkgv("consumer", "0:1-1", &[], &["libfoo.so.1=1.2.3"], &[]),
            pkgv("foo", "0:9.9-1", &["libfoo.so.1=1.2.3"], &[], &[]),
        ]);
        let report = revdep_report(&view, &[]);
        assert!(
            report.exact_pins.is_empty(),
            "the provide entry is the pin surface, got {:?}",
            report.exact_pins
        );
    }

    #[test]
    fn a_moved_soname_provide_is_stale_and_names_the_entry() {
        let view = InstalledView::new([
            pkgv("consumer", "0:1-1", &[], &["libfoo.so.1=1.2.3"], &[]),
            pkgv("foo", "0:9.9-1", &["libfoo.so.1=2.0.0"], &[], &[]),
        ]);
        let report = revdep_report(&view, &[]);
        assert_eq!(report.exact_pins.len(), 1);
        assert_eq!(report.exact_pins[0].dep, "libfoo.so.1=1.2.3");
        assert_eq!(
            report.exact_pins[0].status, "stale libfoo.so.1=2.0.0",
            "the stale display names the provide entries"
        );
    }

    #[test]
    fn real_version_drift_is_stale() {
        let view = InstalledView::new([
            pkgv("consumer", "0:1-1", &[], &["app=1.0.0-1"], &[]),
            pkgv("app", "1.0.1-1", &[], &[], &[]),
        ]);
        let report = revdep_report(&view, &[]);
        assert_eq!(report.exact_pins.len(), 1);
        assert_eq!(report.exact_pins[0].status, "stale 1.0.1-1");
    }

    #[test]
    fn a_lib32_consumer_resolves_against_lib32_owners() {
        let dir = std::env::temp_dir().join(format!("gsa-abi-revdep32-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("usr/lib32")).unwrap();
        std::fs::write(
            dir.join("usr/lib32/libapp.so.1"),
            test_support::elf64(Some("libapp.so.1"), &["libgone.so.1"]),
        )
        .unwrap();
        std::fs::write(dir.join("usr/lib32/libgone.so.1"), b"\x7fELF").unwrap();
        let view = InstalledView::with_root(
            dir.clone(),
            [
                pkgv("lib32-app", "0:1-1", &[], &[], &["usr/lib32/libapp.so.1"]),
                pkgv("lib32-gone", "0:1-1", &[], &[], &["usr/lib32/libgone.so.1"]),
            ],
        );
        let report = revdep_report(&view, &[]);
        assert!(
            report.unresolved.is_empty(),
            "the lib32 member's need resolves in its own class, got {:?}",
            report.unresolved
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn registry_lines_round_trip() {
        let dir = std::env::temp_dir().join(format!("gsa-abi-presreg-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let path = preserved_registry_path(&dir);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(&path, "libx.so.1|/p/libx.so.1|pkg|0:1-1\nbad line\n").unwrap();
        let (entries, corrupt) = load_preserved(&path).unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(corrupt.len(), 1);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
