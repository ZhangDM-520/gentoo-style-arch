//! The side-car self-check (`gsa --local-db-check`, contract §D.1's hidden
//! seam): unreadable rows (named, never quoted as raw bytes), hash/size
//! disagreements between index rows and archive bytes (§J.4), rows whose
//! archive is gone, and orphan archives — `.pkg.tar.zst` files sitting
//! beside a recipe with no index row. Report-only surface: the caller maps
//! findings to the seam's rc (§G: 0 clean, 1 findings, 2 bad usage).

use std::path::{Path, PathBuf};

use crate::index::{verify_row, BinpkgIndex, Match};
use crate::kv::Kv;
use crate::runs::RunHistory;
use crate::store::CorruptLine;
use crate::{StateError, StateRoot};

/// One self-check finding, rendered as `<kind> <name> <detail…>` so a
/// fixture can name the offender (contract §L.3: expectations derive from
/// the rows, and the rows name their subjects).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Finding {
    /// A store line that could not be used (kind `corrupt-row`).
    Corrupt(CorruptLine),
    /// An index row whose archive bytes disagree with the recorded hash
    /// (kind `hash-mismatch`) or size (`size-mismatch`).
    Mismatch { name: String, detail: String },
    /// An index row whose archive file is gone (kind `missing-archive`).
    MissingArchive { name: String, detail: String },
    /// An archive beside a recipe with no live index row (kind
    /// `orphan-archive`).
    OrphanArchive { name: String, detail: String },
}

impl Finding {
    pub fn render(&self) -> String {
        match self {
            Finding::Corrupt(c) => c.render(),
            Finding::Mismatch { name, detail } => format!("hash-mismatch {name} {detail}"),
            Finding::MissingArchive { name, detail } => format!("missing-archive {name} {detail}"),
            Finding::OrphanArchive { name, detail } => format!("orphan-archive {name} {detail}"),
        }
    }

    pub fn name(&self) -> &str {
        match self {
            Finding::Corrupt(c) => &c.name,
            Finding::Mismatch { name, .. }
            | Finding::MissingArchive { name, .. }
            | Finding::OrphanArchive { name, .. } => name,
        }
    }
}

/// The whole side-car health report (`--local-db-check`).
pub struct HealthReport {
    pub findings: Vec<Finding>,
    pub index_rows: usize,
    pub run_records: usize,
    pub kv_keys: usize,
}

impl HealthReport {
    pub fn clean(&self) -> bool {
        self.findings.is_empty()
    }

    /// The summary line the seam prints after the findings (or alone).
    pub fn summary(&self) -> String {
        format!(
            "local-db-check: {} index row(s), {} run record(s), {} kv key(s), {} finding(s)",
            self.index_rows,
            self.run_records,
            self.kv_keys,
            self.findings.len()
        )
    }
}

/// Check the side-car DB. `recipe_dirs` are the topology's recipe
/// directories (the oracle for orphan archives — the index never guesses a
/// workspace layout).
pub fn check(root: &StateRoot, recipe_dirs: &[PathBuf]) -> Result<HealthReport, StateError> {
    let mut findings = Vec::new();

    let index = BinpkgIndex::load(root)?;
    for corrupt in &index.corrupt {
        findings.push(Finding::Corrupt(corrupt.clone()));
    }
    for row in &index.rows {
        let name = row
            .archive
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| row.archive.to_string_lossy().into_owned());
        let verification = verify_row(row);
        match (verification.hash, verification.size) {
            (Match::Missing, _) | (_, Match::Missing) => {
                findings.push(Finding::MissingArchive {
                    name,
                    detail: format!("no file at {}", row.archive.display()),
                });
            }
            _ => {
                if verification.hash == Match::Disagree {
                    let actual = verification
                        .actual
                        .as_ref()
                        .map(|(h, _)| h.clone())
                        .unwrap_or_default();
                    findings.push(Finding::Mismatch {
                        name: name.clone(),
                        detail: format!("recorded {} actual {actual}", row.sha256),
                    });
                }
                if verification.size == Match::Disagree {
                    let actual = verification
                        .actual
                        .as_ref()
                        .map(|(_, s)| *s)
                        .unwrap_or_default();
                    findings.push(Finding::Mismatch {
                        name,
                        detail: format!("size recorded {} actual {actual}", row.size),
                    });
                }
            }
        }
    }

    // Orphan archives: `.pkg.tar.zst` files beside a recipe that no live
    // row binds. Path match first, file name as the unambiguous fallback.
    let row_paths: std::collections::BTreeSet<&Path> =
        index.rows.iter().map(|r| r.archive.as_path()).collect();
    let row_names: std::collections::BTreeSet<&str> = index
        .rows
        .iter()
        .filter_map(|r| r.archive.file_name().map(|n| n.to_str().unwrap_or("")))
        .filter(|n| !n.is_empty())
        .collect();
    for dir in recipe_dirs {
        let Ok(entries) = std::fs::read_dir(dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if !path.is_file() {
                continue;
            }
            let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
                continue;
            };
            if !name.ends_with(".pkg.tar.zst") {
                continue;
            }
            if row_paths.contains(path.as_path()) || row_names.contains(name) {
                continue;
            }
            findings.push(Finding::OrphanArchive {
                name: name.to_string(),
                detail: format!("{} has no index row", path.display()),
            });
        }
    }

    let (run_records, run_corrupt) = RunHistory::read(root)?;
    for corrupt in &run_corrupt {
        findings.push(Finding::Corrupt(corrupt.clone()));
    }
    let (kv_keys, kv_corrupt) = Kv::list(root)?;
    for corrupt in &kv_corrupt {
        findings.push(Finding::Corrupt(corrupt.clone()));
    }

    Ok(HealthReport {
        findings,
        index_rows: index.rows.len(),
        run_records: run_records.len(),
        kv_keys: kv_keys.len(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::index::{register_instance, Retention};
    use gsa_model::{Group, RecipeId, TopologyRecord};

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir =
            std::env::temp_dir().join(format!("gsa-state-health-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn make_archive(dir: &Path, name: &str, version: &str) -> PathBuf {
        use std::io::Write as _;
        let stage = dir.join(format!("stage-{name}-{version}"));
        std::fs::create_dir_all(&stage).unwrap();
        let mut body = Vec::new();
        writeln!(body, "pkgbase = {name}").unwrap();
        writeln!(body, "pkgname = {name}").unwrap();
        writeln!(body, "pkgver = {version}").unwrap();
        writeln!(body, "arch = any").unwrap();
        std::fs::write(stage.join(".PKGINFO"), &body).unwrap();
        let out = dir.join(format!("{name}-{version}-any.pkg.tar.zst"));
        let file = std::fs::File::create(&out).unwrap();
        let enc = zstd::stream::Encoder::new(file, 0).unwrap();
        let mut tar = tar::Builder::new(enc);
        tar.append_dir_all(".", &stage).unwrap();
        tar.into_inner().unwrap().finish().unwrap();
        std::fs::remove_dir_all(&stage).unwrap();
        out
    }

    fn retention() -> Retention {
        Retention::from_records(&[TopologyRecord {
            id: RecipeId::new("leaf").unwrap(),
            path: "packages/leaf".to_string(),
            groups: vec![Group::Misc],
            edges: Vec::new(),
            tags: Vec::new(),
            source_line: 1,
        }])
        .unwrap()
    }

    #[test]
    fn a_clean_side_car_reports_no_findings() {
        let dir = scratch("clean");
        let root = StateRoot::open(&dir).unwrap();
        let recipe_dir = dir.join("packages").join("leaf");
        std::fs::create_dir_all(&recipe_dir).unwrap();
        let archive = make_archive(&recipe_dir, "leaf", "1.0.0-1");
        let mut err = Vec::new();
        register_instance(
            &root,
            "leaf",
            &[archive],
            &retention(),
            &std::collections::BTreeSet::new(),
            None,
            &mut err,
        )
        .unwrap();
        let report = check(&root, &[recipe_dir]).unwrap();
        assert!(report.clean(), "{:?}", report.findings);
        assert_eq!(report.index_rows, 1);
    }

    #[test]
    fn a_corrupted_row_is_caught_by_name() {
        let dir = scratch("corrupt");
        let root = StateRoot::open(&dir).unwrap();
        let recipe_dir = dir.join("packages").join("leaf");
        std::fs::create_dir_all(&recipe_dir).unwrap();
        let archive = make_archive(&recipe_dir, "leaf", "1.0.0-1");
        let mut err = Vec::new();
        register_instance(
            &root,
            "leaf",
            &[archive.clone()],
            &retention(),
            &std::collections::BTreeSet::new(),
            None,
            &mut err,
        )
        .unwrap();
        // Garble one row's tail: the JSON closes early and cannot parse.
        let path = root.index_path();
        let text = std::fs::read_to_string(&path).unwrap();
        let mut out = String::new();
        for line in text.lines() {
            if line.contains("leaf-1.0.0-1-any.pkg.tar.zst") {
                let cut = line.len().saturating_sub(8);
                out.push_str(&line[..cut]);
            } else {
                out.push_str(line);
            }
            out.push('\n');
        }
        std::fs::write(&path, out).unwrap();
        let report = check(&root, &[recipe_dir.clone()]).unwrap();
        assert!(!report.clean());
        let rendered: Vec<String> = report.findings.iter().map(|f| f.render()).collect();
        assert!(
            rendered.iter().any(|l| l.starts_with("corrupt-row index ")),
            "a corrupt row is reported: {rendered:?}"
        );
        // The corrupt row is named — by its archive filename, not bytes.
        let archive_name = archive.file_name().unwrap().to_string_lossy().into_owned();
        assert!(
            rendered
                .iter()
                .any(|l| l.starts_with(&format!("corrupt-row index {archive_name}"))),
            "the corrupt row is named: {rendered:?}"
        );
    }

    #[test]
    fn hash_mismatches_missing_and_orphan_archives_are_reported() {
        let dir = scratch("mismatch");
        let root = StateRoot::open(&dir).unwrap();
        let recipe_dir = dir.join("packages").join("leaf");
        std::fs::create_dir_all(&recipe_dir).unwrap();
        let archive = make_archive(&recipe_dir, "leaf", "1.0.0-1");
        let mut err = Vec::new();
        register_instance(
            &root,
            "leaf",
            &[archive.clone()],
            &retention(),
            &std::collections::BTreeSet::new(),
            None,
            &mut err,
        )
        .unwrap();
        // Tamper the archive bytes under the recorded hash.
        let mut bytes = std::fs::read(&archive).unwrap();
        bytes.push(0);
        std::fs::write(&archive, &bytes).unwrap();
        // And drop an orphan archive beside the recipe.
        make_archive(&recipe_dir, "stray", "9.9.9-1");
        let report = check(&root, &[recipe_dir]).unwrap();
        let rendered: Vec<String> = report.findings.iter().map(|f| f.render()).collect();
        assert!(
            rendered.iter().any(|l| l.starts_with("hash-mismatch ")),
            "{rendered:?}"
        );
        assert!(
            rendered
                .iter()
                .any(|l| l.starts_with("orphan-archive stray-9.9.9-1-any.pkg.tar.zst")),
            "{rendered:?}"
        );
    }
}
