//! IgnorePkg closure repair (`gsa -Mi`, contract §B.7; rule 9's dynamic
//! registration seen from the maintain side — plan-gentoo-qol.md shortlist 7
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

use std::collections::BTreeSet;
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
pub fn installed_names() -> (Option<BTreeSet<String>>, String) {
    let db_root = gsa_install::localdb::pacman_db_root();
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
fn declared_by(ctx: &MaintCtx<'_>, name: &str) -> Option<String> {
    ctx.declared_names()
        .into_iter()
        .find(|(_, names)| names.iter().any(|n| n == name))
        .map(|(id, _)| id)
}

/// The classification of one closure entry: `in-use` (keep) or `stale`
/// (prunable), with its reason.
fn classify(
    ctx: &MaintCtx<'_>,
    name: &str,
    installed: Option<&BTreeSet<String>>,
    shipped: &BTreeSet<String>,
) -> (&'static str, String) {
    if let Some(id) = declared_by(ctx, name) {
        return ("in-use", format!("in-use declared-by {id}"));
    }
    if let Some(installed) = installed {
        if installed.contains(name) {
            return ("in-use", "in-use installed".to_string());
        }
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

/// `-Mi` default: report the closure drift. Full rows over the closure and
/// the wanted universe: `present`/`keep`-class rows for what belongs,
/// `stale` for prunable entries, `missing` for wanted names not covered.
/// Report-only: rc stays 0 (§E.4) and nothing is written.
pub fn report(ctx: &MaintCtx<'_>, conf: &Path) -> Result<Vec<Row>, String> {
    let closure = read_ignorepkg(conf)?;
    let wanted = wanted_names(ctx);
    let shipped = shipped_names(ctx)?;
    let (installed, note) = installed_names();
    let mut rows = vec![Row::new("ignorepkg", "closure", note)];
    for name in &closure.names {
        let (class, reason) = classify(ctx, name, installed.as_ref(), &shipped);
        rows.push(Row::new(name, class, reason));
    }
    for name in &wanted {
        if !closure.names.contains(name) {
            let id = declared_by(ctx, name).unwrap_or_default();
            rows.push(Row::new(name, "missing", format!("declared-by {id}")));
        }
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
/// verb). Rows: `present`/`add`.
pub fn backfill(ctx: &MaintCtx<'_>, conf: &Path, apply: bool) -> Result<Vec<Row>, String> {
    let closure = read_ignorepkg(conf)?;
    let wanted = wanted_names(ctx);
    let mut rows = Vec::new();
    let mut missing: Vec<String> = Vec::new();
    for name in &wanted {
        if closure.names.contains(name) {
            rows.push(Row::new(name, "present", "in-closure"));
        } else {
            missing.push(name.clone());
        }
    }
    if missing.is_empty() {
        return Ok(rows);
    }
    if !apply {
        for name in &missing {
            rows.push(Row::new(name, "add", "planned"));
        }
        return Ok(rows);
    }
    let db_root = gsa_install::localdb::pacman_db_root();
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
    let shipped = shipped_names(ctx)?;
    let (installed, note) = installed_names();
    let mut rows = vec![Row::new("ignorepkg", "closure", note)];
    let mut remove: Vec<String> = Vec::new();
    for name in &closure.names {
        let (class, reason) = classify(ctx, name, installed.as_ref(), &shipped);
        if class == "in-use" {
            rows.push(crate::protect::keep_row(name, &reason));
        } else {
            rows.push(Row::new(name, "remove", reason));
            remove.push(name.clone());
        }
    }
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
    let db_root = gsa_install::localdb::pacman_db_root();
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
