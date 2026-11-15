//! IgnorePkg closure repair (`gsa -Mi`, contract §B.7; rule 9's dynamic
//! registration seen from the maintain side — docs/plans/plan-gentoo-qol.md shortlist 7
//! `emaint cleanconfmem` analogue). The closure semantics are exactly the
//! registration's (cumulative `IgnorePkg =` inside `[options]` only) — this
//! module plans, `gsa-install::register` writes; the two share one walker
//! and can never disagree on what pacman reads.
//!
//! Pruning safety (the `keep in-use` guard): an entry is STALE only when no
//! committed recipe declares it and no readable installed package carries
//! it — "archives gone or superseded" in either case. A name some recipe
//! still declares (pkgbase/pkgname of the committed metadata) or some
//! installed package owns/ships is in use and never leaves the closure.

use std::collections::{BTreeMap, BTreeSet};
use std::path::Path;

use gsa_install::register::{prune_ignorepkg, read_ignorepkg, register_ignorepkg};

use crate::{MaintCtx, Row};

/// The declared-name universe: every recipe's `pkgbase` + `pkgname`s (the
/// registration's SECOND authority) — what the closure should cover.
pub fn wanted_names(ctx: &MaintCtx<'_>) -> BTreeSet<String> {
    ctx.declared_names().into_values().flatten().collect()
}

/// The names on-disk archives actually ship (`.PKGINFO` truth, the
/// registration's FIRST authority) — read-only context for the stale
/// reason. Scans the TWO homes archives live in: the shared PKGDEST (walked
/// once — every name it ships belongs to the universe) and every recipe
/// dir (§J.2's legacy home). An unreadable archive is skipped, never
/// probed (rule 25(h)). The engine's ONE layout error policy applies: an
/// unusable build-cache layout is fatal for the calling operation.
pub fn shipped_names(ctx: &MaintCtx<'_>) -> Result<BTreeSet<String>, String> {
    let layout = gsa_model::config::build_layout_for_run()?;
    let mut dirs = vec![layout.pkgdest];
    dirs.extend(ctx.recipe_dirs().into_iter().map(|(_, dir)| dir));
    let mut names = BTreeSet::new();
    for dir in dirs {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.extension().and_then(|e| e.to_str()) != Some("zst")
                || !path
                    .file_name()
                    .map(|n| n.to_string_lossy().contains(".pkg.tar."))
                    .unwrap_or(false)
            {
                continue;
            }
            if let Ok(info) = gsa_recipe::pkginfo::read_pkginfo(&path) {
                names.insert(info.pkgbase);
                names.insert(info.pkgname);
            }
        }
    }
    Ok(names)
}

/// The names a readable installed database carries (package names and bare
/// provide names). `None` + a note when the local DB cannot be read — the
/// prune then stays conservative and says so, never pretending nothing is
/// installed.
pub fn installed_names(conf: Option<&Path>) -> (Option<BTreeSet<String>>, String) {
    let db_root = match gsa_install::localdb::pacman_db_root_for(conf) {
        Ok(root) => root,
        Err(message) => return (None, format!("installed-db unavailable ({message})")),
    };
    match gsa_install::LocalDb::load(&db_root) {
        Ok(db) => {
            let mut names = BTreeSet::new();
            for pkg in db.packages() {
                names.insert(pkg.name.clone());
                for provide in &pkg.provides {
                    names.insert(gsa_install::localdb::provide_name(provide).to_string());
                }
            }
            let count = names.len();
            (Some(names), format!("installed-db {count} package(s)"))
        }
        Err(error) => (
            None,
            format!("installed-db unreadable ({error}) — installed names not consulted"),
        ),
    }
}

/// Which recipe declares a wanted name (for the `in-use` detail).
fn declared_by<'a>(declared: &'a BTreeMap<String, Vec<String>>, name: &str) -> Option<&'a str> {
    declared
        .iter()
        .find(|(_, names)| names.iter().any(|n| n == name))
        .map(|(id, _)| id.as_str())
}

/// The classification of one closure entry: `in-use` (keep) or `stale`
/// (prunable), with its reason.
fn classify(
    declared: &BTreeMap<String, Vec<String>>,
    name: &str,
    installed: &BTreeSet<String>,
    shipped: &BTreeSet<String>,
) -> (&'static str, String) {
    if let Some(id) = declared_by(declared, name) {
        return ("in-use", format!("in-use declared-by {id}"));
    }
    // `report`/`prune` both refuse before this seam when the installed DB is
    // unreadable, so "installed-db unavailable" never reaches it (round-2
    // audit, F-R2-B-06).
    if installed.contains(name) {
        return ("in-use", "in-use installed".to_string());
    }
    if shipped.contains(name) {
        (
            "stale",
            "stale superseded — only archive .PKGINFO ships it".to_string(),
        )
    } else {
        ("stale", "stale archives-gone".to_string())
    }
}

/// The wanted universe split against the closure — the ONE derivation the
/// report and `--backfill` share (R2-vera-1), so the numbers the report
/// prints ARE the sets the repair would act on. Three counts for one closure
/// (a consulted installed-DB census, a `missing` row per declared name, and a
/// backfill header) once left an operator unable to tell whether the answer
/// was 2 entries or 941.
struct WantedSplit {
    /// Wanted names the closure already covers.
    present: Vec<String>,
    /// Wanted names the closure misses AND an archive ships: `--backfill`
    /// appends these (a house package exists to protect).
    addable: Vec<String>,
    /// Wanted names the closure misses because nothing was ever built:
    /// `--backfill` never adds them, because registering a declared-but-never-
    /// built name would pin the STOCK package of that name (blind review
    /// 2026-11-11, F9).
    unbuilt: Vec<String>,
}

impl WantedSplit {
    fn of(
        wanted: &BTreeSet<String>,
        closure: &[String],
        shipped: &BTreeSet<String>,
    ) -> WantedSplit {
        let mut split = WantedSplit {
            present: Vec::new(),
            addable: Vec::new(),
            unbuilt: Vec::new(),
        };
        for name in wanted {
            if closure.contains(name) {
                split.present.push(name.clone());
            } else if shipped.contains(name) {
                split.addable.push(name.clone());
            } else {
                split.unbuilt.push(name.clone());
            }
        }
        split
    }

    /// Wanted names the closure misses, in wanted order — the `missing` rows
    /// the report prints, and `addable + unbuilt` by construction.
    fn missing(&self) -> usize {
        self.addable.len() + self.unbuilt.len()
    }
}

/// The `-Mi` header: what the closure HOLDS, and what the installed-DB census
/// was consulted FOR. The census is a classification input, never the closure
/// itself — a header counting it read as the closure size (R2-vera-1).
fn closure_header(entries: usize, in_use: usize, stale: usize, census: &str) -> String {
    format!(
        "entries={entries} in-use={in_use} stale={stale}; {census} consulted for classification"
    )
}

/// `-Mi` default: report the closure drift. Full rows over the closure and
/// the wanted universe: `present`/`keep`-class rows for what belongs,
/// `stale` for prunable entries, `missing` for wanted names not covered, and
/// ONE `drift` summary that reconciles them with the repair's plan
/// (`missing = addable + unbuilt`). Report-only: rc stays 0 (§E.4) and
/// nothing is written.
pub fn report(ctx: &MaintCtx<'_>, conf: &Path) -> Result<Vec<Row>, String> {
    let closure = read_ignorepkg(conf)?;
    let declared = ctx.declared_names();
    let wanted = wanted_names(ctx);
    let shipped = shipped_names(ctx)?;
    let (installed, note) = installed_names(Some(conf));
    let Some(installed_set) = installed else {
        return Err(note);
    };
    let split = WantedSplit::of(&wanted, &closure.names, &shipped);
    let classified: Vec<(String, &'static str, String)> = closure
        .names
        .iter()
        .map(|name| {
            let (class, reason) = classify(&declared, name, &installed_set, &shipped);
            (name.clone(), class, reason)
        })
        .collect();
    let in_use = classified.iter().filter(|(_, c, _)| *c == "in-use").count();
    let stale = classified.len() - in_use;
    let mut rows = vec![Row::new(
        "ignorepkg",
        "closure",
        closure_header(closure.names.len(), in_use, stale, &note),
    )];
    for (name, class, reason) in classified {
        rows.push(Row::new(name, class, reason));
    }
    if split.missing() > 0 {
        for name in &wanted {
            if split.present.contains(name) {
                continue;
            }
            let id = declared_by(&declared, name).unwrap_or_default();
            rows.push(Row::new(name, "missing", format!("declared-by {id}")));
        }
        rows.push(Row::new(
            "ignorepkg",
            "drift",
            format!(
                "missing={} addable={} unbuilt={}",
                split.missing(),
                split.addable.len(),
                split.unbuilt.len()
            ),
        ));
    }
    if closure.names.is_empty() && wanted.is_empty() {
        rows.push(Row::new(
            "ignorepkg",
            "clean",
            "no entries, no wanted names",
        ));
    }
    Ok(rows)
}

/// `-Mi --backfill`: add every wanted name the closure is missing (today's
/// hidden `--register-ignorepkg`, rule 9's one-shot backfill, now a public
/// verb). Rows: `present`/`add`, plus one summary row when declared names
/// were skipped.
///
/// Only names an ARCHIVE actually shipped (`.PKGINFO` truth, the same first
/// authority the acceptance-time registration reads) are added: a declared
/// name that was never built has no house package to protect, and putting it
/// in `IgnorePkg` pins whatever STOCK package carries the name — an update
/// the operator never asked to hold (blind review 2026-11-11, F9).
pub fn backfill(ctx: &MaintCtx<'_>, conf: &Path, apply: bool) -> Result<Vec<Row>, String> {
    let closure = read_ignorepkg(conf)?;
    let wanted = wanted_names(ctx);
    let shipped = shipped_names(ctx)?;
    // The SAME partition the report prints counts from (R2-vera-1): an
    // `addable=` in the report and an `add planned` here can never disagree.
    let split = WantedSplit::of(&wanted, &closure.names, &shipped);
    let mut rows = Vec::new();
    for name in &split.present {
        rows.push(Row::new(name, "present", "in-closure"));
    }
    if !split.unbuilt.is_empty() {
        rows.push(Row::new(
            "ignorepkg",
            "backfill",
            format!(
                "{} declared name(s) never built — not registered",
                split.unbuilt.len()
            ),
        ));
    }
    let missing = split.addable;
    if missing.is_empty() {
        return Ok(rows);
    }
    if !apply {
        for name in &missing {
            rows.push(Row::new(name, "add", "planned"));
        }
        return Ok(rows);
    }
    let db_root = gsa_install::localdb::pacman_db_root_for(Some(conf))?;
    let report = register_ignorepkg(conf, "workspace", &missing, &db_root)?;
    for name in &missing {
        if report.added.contains(name) {
            rows.push(Row::new(name, "add", "appended"));
        }
    }
    Ok(rows)
}

/// `-Mi --prune`: remove exactly the stale entries (archives gone or
/// superseded) and KEEP every in-use entry, loudly. The write goes through
/// `gsa-install::register::prune_ignorepkg` — the documented closure
/// semantics, a dated pre-image backup, atomic rewrite. Rows:
/// `keep in-use …` / `remove <reason>` over the whole closure; `apply ==
/// false` is the dry-run plan (no write).
pub fn prune(ctx: &MaintCtx<'_>, conf: &Path, apply: bool) -> Result<Vec<Row>, String> {
    let closure = read_ignorepkg(conf)?;
    let declared = ctx.declared_names();
    let shipped = shipped_names(ctx)?;
    let (installed, note) = installed_names(Some(conf));
    let Some(installed_set) = installed else {
        return Err(note);
    };
    let mut rows = vec![Row::new("ignorepkg", "closure", "deferred")];
    let mut remove: Vec<String> = Vec::new();
    let mut in_use = 0usize;
    for name in &closure.names {
        let (class, reason) = classify(&declared, name, &installed_set, &shipped);
        if class == "in-use" {
            in_use += 1;
            rows.push(crate::protect::keep_row(name, &reason));
        } else {
            rows.push(Row::new(name, "remove", reason));
            remove.push(name.clone());
        }
    }
    // The same header `report` prints (one derivation, R2-vera-1): the
    // closure it classifies, split by in-use and stale.
    rows[0] = Row::new(
        "ignorepkg",
        "closure",
        closure_header(closure.names.len(), in_use, remove.len(), &note),
    );
    if remove.is_empty() {
        return Ok(rows);
    }
    if !apply {
        rows.push(Row::new(
            "ignorepkg",
            "prune",
            format!("{} stale name(s) planned", remove.len()),
        ));
        return Ok(rows);
    }
    let db_root = gsa_install::localdb::pacman_db_root_for(Some(conf))?;
    let report = prune_ignorepkg(conf, "maintain", &remove, &db_root)?;
    rows.push(Row::new(
        "ignorepkg",
        "pruned",
        format!(
            "{} name(s) removed backup={}",
            report.removed.len(),
            report.backup.is_some()
        ),
    ));
    Ok(rows)
}
