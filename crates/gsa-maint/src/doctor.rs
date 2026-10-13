//! The doctor (`gsa -Md`, contract §B.7): runtime-state reconciliation over
//! the side-car and the state root — log ownership, stale lane/run
//! artifacts, the pacman local-DB health report, binpkg index
//! `sha256+size` consistency, side-car rows with no pacman counterpart.
//! Default reports; `--fix` applies the NAMED repairs and nothing else
//! (deliverable fence: side-car self-healing only — reindex from archives,
//! prune orphans; never `/usr`, never `/var/lib/pacman`).

use std::path::PathBuf;

use gsa_state::{prune_instance, reindex_archives, verify_row, BinpkgIndex, IndexRow, Match};

use crate::{hygiene, MaintCtx, Row};

/// What one doctor pass found. The report renders it; the fix consumes it.
#[derive(Default)]
pub struct Findings {
    pub wrong_owner: Vec<Row>,
    pub stale: Vec<(PathBuf, &'static str)>,
    /// The pacman local-DB health line's reason (report-only either way).
    pub local_db: String,
    pub mismatch: Vec<(IndexRow, String)>,
    pub orphan_rows: Vec<IndexRow>,
    pub orphan_archives: Vec<(String, PathBuf)>,
    pub no_pacman: Vec<(String, String)>,
    /// True when the installed view was readable (the no-pacman family only
    /// means something then).
    pub installed_known: bool,
}

/// Gather every doctor family in one read-only pass.
pub fn findings(ctx: &MaintCtx<'_>) -> Findings {
    let mut out = Findings::default();
    out.wrong_owner = hygiene::ownership_rows(ctx.state.path());
    out.stale = hygiene::stale_artifacts(ctx.state.path(), ctx.root);
    out.local_db = match gsa_install::LocalDb::load(&gsa_install::localdb::pacman_db_root()) {
        Ok(db) => {
            out.installed_known = true;
            format!("ok packages={}", db.packages().len())
        }
        Err(error) => format!("unreadable {error}"),
    };

    let index = BinpkgIndex::load(ctx.state).unwrap_or(BinpkgIndex {
        rows: Vec::new(),
        corrupt: Vec::new(),
    });
    for row in &index.rows {
        if !row.archive.exists() {
            out.orphan_rows.push(row.clone());
            continue;
        }
        let verification = verify_row(row);
        if !verification.agrees() {
            let hash = match verification.hash {
                Match::Agree => "agree",
                Match::Disagree => "disagree",
                Match::Missing => "unrecorded",
            };
            let size = match verification.size {
                Match::Agree => "agree",
                Match::Disagree => "disagree",
                Match::Missing => "unrecorded",
            };
            out.mismatch
                .push((row.clone(), format!("hash={hash} size={size}")));
        }
        if out.installed_known {
            let db = gsa_install::LocalDb::load(&gsa_install::localdb::pacman_db_root())
                .expect("the local DB loaded above");
            let mut counterpart = db.get(&row.pkgbase).is_some();
            for name in &row.pkgnames {
                counterpart = counterpart || db.get(name).is_some();
            }
            if !counterpart {
                out.no_pacman
                    .push((row.pkgbase.clone(), row.version.clone()));
            }
        }
    }

    // Orphan archives: beside a recipe, no live index row.
    for (id, dir) in ctx.recipe_dirs() {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if !path
                .file_name()
                .map(|n| n.to_string_lossy().contains(".pkg.tar."))
                .unwrap_or(false)
                || path.extension().and_then(|e| e.to_str()) != Some("zst")
            {
                continue;
            }
            if index.find_archive(&path).is_none() {
                out.orphan_archives.push((id.clone(), path));
            }
        }
    }
    out
}

/// `-Md` default: the report. Rows: `doctor report <N> finding(s)` (or
/// `doctor clean`) plus one row per finding. Report-only — findings never
/// change rc (§E.4).
pub fn report(ctx: &MaintCtx<'_>) -> Vec<Row> {
    let found = findings(ctx);
    let mut rows = Vec::new();
    rows.extend(found.wrong_owner.clone());
    for (path, class) in &found.stale {
        rows.push(Row::new(
            path.display().to_string(),
            "stale-artifact",
            class.to_string(),
        ));
    }
    rows.push(Row::new("local-db", "health", &found.local_db));
    for (row, detail) in &found.mismatch {
        rows.push(Row::new(
            row.archive.display().to_string(),
            "index-mismatch",
            detail,
        ));
    }
    for row in &found.orphan_rows {
        rows.push(Row::new(
            row.archive.display().to_string(),
            "orphan-row",
            format!("archive-gone {} instance={}", row.recipe_id, row.instance),
        ));
    }
    for (id, path) in &found.orphan_archives {
        rows.push(Row::new(
            path.display().to_string(),
            "orphan-archive",
            format!("no-index-row {id}"),
        ));
    }
    if found.installed_known {
        for (base, version) in &found.no_pacman {
            rows.push(Row::new(
                base,
                "side-car-no-pacman",
                format!("version={version}"),
            ));
        }
    }
    let findings = rows.len();
    let mut out = vec![if findings == 0 {
        Row::new("doctor", "clean", "")
    } else {
        Row::new("doctor", "report", format!("{findings} finding(s)"))
    }];
    out.append(&mut rows);
    out
}

/// What one `--fix` pass did.
pub struct FixOutcome {
    pub rows: Vec<Row>,
    /// Repair failures — a failed repair is the refusal class (rc 3).
    pub failed: usize,
}

/// `-Md --fix`: the named repairs only. `apply == false` is the dry-run
/// plan (present-tense actions, nothing touched).
///
/// - `prune-orphan-rows` — a binpkg index row whose archive is GONE is
///   tombstoned. A row whose archive exists is never pruned (the archive is
///   the row's referent).
/// - `reindex-orphans` — an archive beside a recipe with no row is
///   re-indexed from its own `.PKGINFO` + bytes (fail closed, no retention).
/// - `prune-stale-artifacts` — the state root's dead temporaries (§K.3's
///   sweep class) are removed; packages-tree artifacts are kept and named
///   (a maintain repair never writes outside the state root).
///
/// Log ownership is report-only even here (§J.5: the root supervisor's
/// startup repair owns that remedy), and the pacman local DB is never
/// touched.
pub fn fix(ctx: &MaintCtx<'_>, apply: bool) -> Result<FixOutcome, String> {
    let found = findings(ctx);
    let mut rows = Vec::new();
    let mut failed = 0;

    for row in &found.orphan_rows {
        if !apply {
            rows.push(Row::new(
                row.archive.display().to_string(),
                "tombstone",
                format!("orphan-row {} instance={}", row.recipe_id, row.instance),
            ));
            continue;
        }
        let mut err = Vec::new();
        match prune_instance(ctx.state, &row.recipe_id, row.instance, &mut err) {
            Ok(true) => rows.push(Row::new(
                row.archive.display().to_string(),
                "tombstoned",
                format!("orphan-row {} instance={}", row.recipe_id, row.instance),
            )),
            Ok(false) => rows.push(crate::protect::keep_row(
                &row.archive.display().to_string(),
                "orphan-row already-tombstoned",
            )),
            Err(error) => {
                failed += 1;
                rows.push(Row::new(
                    row.archive.display().to_string(),
                    "failed",
                    format!("orphan-row cannot tombstone: {error}"),
                ));
            }
        }
    }

    // One reindex call per recipe keeps the instance numbering coherent.
    let mut by_recipe: Vec<(String, Vec<PathBuf>)> = Vec::new();
    for (id, path) in &found.orphan_archives {
        match by_recipe.iter_mut().find(|(r, _)| r == id) {
            Some((_, list)) => list.push(path.clone()),
            None => by_recipe.push((id.clone(), vec![path.clone()])),
        }
    }
    for (id, archives) in by_recipe {
        if !apply {
            for archive in &archives {
                rows.push(Row::new(
                    archive.display().to_string(),
                    "reindex",
                    format!("orphan-archive {id}"),
                ));
            }
            continue;
        }
        let mut err = Vec::new();
        match reindex_archives(ctx.state, &id, &archives, &mut err) {
            Ok(added) => {
                for row in &added {
                    rows.push(Row::new(
                        row.archive.display().to_string(),
                        "reindexed",
                        format!("{id} instance={}", row.instance),
                    ));
                }
            }
            Err(error) => {
                failed += 1;
                for archive in &archives {
                    rows.push(Row::new(
                        archive.display().to_string(),
                        "failed",
                        format!("reindex refused: {error}"),
                    ));
                }
            }
        }
    }

    let hygiene_rows = hygiene::prune_stale_artifacts(ctx.state.path(), ctx.root, apply);
    failed += hygiene_rows.iter().filter(|r| r.action == "failed").count();
    rows.extend(hygiene_rows);
    for row in &found.wrong_owner {
        rows.push(crate::protect::keep_row(
            &row.subject,
            "wrong-owner — root repairs owners at startup (§J.5)",
        ));
    }
    Ok(FixOutcome { rows, failed })
}
