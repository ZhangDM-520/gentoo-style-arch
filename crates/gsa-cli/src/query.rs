//! The side-car query surface (contract §B.3 `-Qb`/`-Qp`, §D.1
//! `--local-db-check`): everything here reads the side-car DB and the
//! archives' own `.PKGINFO` — never pacman's installed database (the hybrid
//! model's rule: pacman is the only installed-DB authority) and never a
//! re-derived filename guess (§J.4: the index row is authoritative).
//!
//! Row shapes are derived from the stored records (rule 25(j) / §L.3):
//! `-Qb` prints the §J.4 wire row verbatim, `-Qp` prints one probe row per
//! archive whose fields come from the matched index row and the archive's
//! `.PKGINFO`, and `--local-db-check` prints `<kind> <name> <detail…>`
//! findings that NAME the offender.

use std::io::Write;
use std::path::Path;

use gsa_install::localdb::{pacman_db_root, LocalDb};
use gsa_recipe::pkginfo::read_pkginfo;

use crate::args::Invocation;
use crate::select::Ctx;
use gsa_state::{verify_row, wire_row, BinpkgIndex, Match, StateRoot};

/// `gsa -Qb [ref…]` — the binpkg index rows (retained built instances,
/// §B.3/§J.4). With no ref every live row prints; refs resolve like every
/// other query (§C.1) and filter to their recipes. Rows print in index
/// order (registration order), so the surface is stable and parseable.
pub fn query_binpkg(
    ctx: &Ctx<'_>,
    inv: &Invocation,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<(), String> {
    if !inv.ranges.is_empty() {
        return Err("index ranges address an -S/-B selection (see 'gsa -Sl')".to_string());
    }
    let wanted: Option<std::collections::BTreeSet<String>> = if inv.targets.is_empty() {
        None
    } else {
        let indices = crate::resolve_records(ctx, &inv.targets, err)?;
        Some(
            indices
                .iter()
                .map(|&i| ctx.graph.record(i).id.as_str().to_string())
                .collect(),
        )
    };
    let root = StateRoot::open(&gsa_state::resolve_state_root(inv.state_dir.as_deref()))
        .map_err(|e| e.to_string())?;
    let index = BinpkgIndex::load(&root).map_err(|e| e.to_string())?;
    for row in &index.rows {
        if let Some(wanted) = &wanted {
            if !wanted.contains(&row.recipe_id) {
                continue;
            }
        }
        let _ = writeln!(out, "{}", wire_row(row));
    }
    Ok(())
}

/// `gsa -Qp <archive…>` — archive probe (§B.3): read the archive's own
/// `.PKGINFO` (rule 9's first name authority), match its binpkg index row,
/// and report hash/size agreement (§J.4). One row per archive:
///
/// `<archive> <status> pkginfo=… pkgbase=… pkgname=… version=… index=… hash=… size=…`
///
/// `status` is `agrees` (row and bytes agree), `mismatch` (row found but
/// hash/size or metadata disagree), `unindexed` (no row — never guessed
/// from a filename), or `unreadable` (no `.PKGINFO` truth, rule 25(h)).
/// Report-only: the probe never mutates and its rc is 0 unless the argv is
/// bad (§G.1 rc 2).
pub fn query_probe(
    inv: &Invocation,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<(), String> {
    let _ = err;
    if !inv.ranges.is_empty() {
        return Err("index ranges address an -S/-B selection (see 'gsa -Sl')".to_string());
    }
    if inv.targets.is_empty() {
        return Err("requires at least one archive path".to_string());
    }
    for arg in &inv.targets {
        let path = Path::new(arg);
        if !path.is_file() {
            return Err(format!("malformed archive argument {arg}"));
        }
    }
    let root = StateRoot::open(&gsa_state::resolve_state_root(inv.state_dir.as_deref()))
        .map_err(|e| e.to_string())?;
    let index = BinpkgIndex::load(&root).map_err(|e| e.to_string())?;
    for arg in &inv.targets {
        let path = Path::new(arg);
        let row = index.find_archive(path);
        let index_field = if row.is_some() { "match" } else { "absent" };
        let info = match read_pkginfo(path) {
            Ok(info) => info,
            Err(error) => {
                let _ = writeln!(out, "{arg} unreadable pkginfo={error} index={index_field}");
                continue;
            }
        };
        let (hash, size, agrees) = match row {
            Some(row) => {
                let verification = verify_row(row);
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
                let meta_agrees = row.pkgbase == info.pkgbase
                    && row.pkgnames.contains(&info.pkgname)
                    && row.version == info.version;
                (hash, size, verification.agrees() && meta_agrees)
            }
            None => ("unrecorded", "unrecorded", false),
        };
        let status = match row {
            None => "unindexed",
            Some(_) if agrees => "agrees",
            Some(_) => "mismatch",
        };
        let _ = writeln!(
            out,
            "{arg} {status} pkginfo=ok pkgbase={} pkgname={} version={} index={index_field} hash={hash} size={size}",
            info.pkgbase, info.pkgname, info.version
        );
    }
    Ok(())
}

/// `gsa --local-db-check [health|runs]` (§D.1, extended with the run-history
/// read of the §H.1 amendment): the side-car self-check without a run.
///
/// - `health` (default): unreadable rows (named), hash/size mismatches,
///   rows whose archive vanished, orphan archives — rc 0 clean, 1 findings,
///   3 when the state root itself is unusable (§G.1's refusal class).
/// - `runs`: render every stored `format: 2` run record (the same
///   structure, re-rendered — never re-derived); a skipped corrupt line is
///   a finding (rc 1).
///
/// rc 2 is bad usage (an unknown verb). §G has no dedicated "check
/// findings" class, so `health`'s findings use rc 1 in the §E.5 seam shape
/// (findings present, full report still printed).
pub fn run_local_db_check(args: &[String], out: &mut dyn Write, err: &mut dyn Write) -> i32 {
    const USAGE: &str = "gsa --local-db-check [health|runs]: unknown argument";
    let verb = match args {
        [] => "health",
        [one] if one == "health" || one == "runs" => one.as_str(),
        [one] => {
            let _ = writeln!(
                err,
                "gsa --local-db-check: unknown argument '{one}' (want health|runs)"
            );
            let _ = writeln!(err, "{USAGE}");
            return 2;
        }
        _ => {
            let _ = writeln!(err, "{USAGE}");
            return 2;
        }
    };
    let root_path = gsa_state::resolve_state_root(None);
    let root = match StateRoot::open(&root_path) {
        Ok(root) => root,
        Err(error) => {
            let _ = writeln!(err, "gsa: {error}");
            return 3;
        }
    };
    match verb {
        "runs" => match gsa_state::RunHistory::read(&root) {
            Ok((records, corrupt)) => {
                for line in &corrupt {
                    let _ = writeln!(err, "gsa: note: {}", line.render());
                }
                for record in &records {
                    let _ = write!(out, "{}", record.render_machine());
                }
                if corrupt.is_empty() {
                    0
                } else {
                    1
                }
            }
            Err(error) => {
                let _ = writeln!(err, "gsa: {error}");
                3
            }
        },
        _ => {
            // The orphan-archive oracle: every recipe directory the
            // topology knows (§J.2's layout — archives beside recipes).
            let recipe_dirs = match crate::find_root() {
                Some(root) => match gsa_topo::load_project(&root) {
                    Ok(project) => project
                        .topology
                        .records
                        .iter()
                        .map(|r| root.join(&r.path))
                        .collect::<Vec<_>>(),
                    Err(error) => {
                        let _ = writeln!(err, "gsa: {error}");
                        return 2;
                    }
                },
                None => Vec::new(),
            };
            match gsa_state::check(&root, &recipe_dirs) {
                Ok(report) => {
                    for finding in &report.findings {
                        let _ = writeln!(out, "{}", finding.render());
                    }
                    let _ = writeln!(out, "{}", report.summary());
                    if report.clean() {
                        0
                    } else {
                        1
                    }
                }
                Err(error) => {
                    let _ = writeln!(err, "gsa: {error}");
                    3
                }
            }
        }
    }
}

/// `gsa -Qa <ref…>` — the ABI report (contract §B.3): the derived
/// abi-token, the `abi-rev=` override state, and the subscription records
/// in/out (`consumer|version|provider|token`, plan-native-pm.md §4.1).
/// One row per fact: `<id> <kind> <detail…>`, deterministic order.
///
/// Token sources, best first: the newest binpkg index row's recorded token,
/// the recipe's newest built archive (`gsa-abi`'s derivation over
/// `.PKGINFO` provides + shipped ELF `DT_SONAME`), else the committed
/// `.SRCINFO` declared provides (`source=declared` — no shipped payload was
/// scanned). Read-only; rc 0.
pub fn query_abi(
    ctx: &Ctx<'_>,
    inv: &Invocation,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<(), String> {
    if !inv.ranges.is_empty() {
        return Err("index ranges address an -S/-B selection (see 'gsa -Sl')".to_string());
    }
    if inv.targets.is_empty() {
        return Err("requires at least one reference".to_string());
    }
    let indices = crate::resolve_records(&ctx, &inv.targets, err)?;
    let root = StateRoot::open(&gsa_state::resolve_state_root(inv.state_dir.as_deref()))
        .map_err(|e| e.to_string())?;
    let index = BinpkgIndex::load(&root).map_err(|e| e.to_string())?;
    let subs = gsa_abi::Subscriptions::load(&gsa_abi::subscriptions_path(root.path()))
        .map_err(|e| e.to_string())?;
    for line in &subs.corrupt {
        let _ = writeln!(err, "gsa: note: {line}");
    }
    let repo = crate::find_root();
    for &idx in &indices {
        let record = ctx.graph.record(idx);
        let id = record.id.as_str();
        let rev = gsa_abi::abi_rev_of(&record.tags);
        let recipe_dir = repo.as_ref().map(|r| r.join(&record.path));

        // Token truth: archive-derived when an archive exists (the shipped
        // surface), declared otherwise; the index row's recorded token is
        // reported alongside.
        let (token, source) = match recipe_dir
            .as_deref()
            .and_then(|dir| gsa_install::discover_recipe(dir).ok())
            .and_then(|found| found.candidates.into_iter().map(|c| c.archive).next_back())
        {
            Some(archive) => match gsa_abi::token_for_archive(&archive, rev) {
                Ok(token) => (token, "archive"),
                Err(error) => {
                    let _ = writeln!(err, "gsa: note: {id}: archive unreadable ({error})");
                    let declared = declared_provides(recipe_dir.as_deref());
                    (gsa_abi::token_declared(&declared, rev), "declared")
                }
            },
            None => {
                let declared = declared_provides(recipe_dir.as_deref());
                (gsa_abi::token_declared(&declared, rev), "declared")
            }
        };
        let _ = writeln!(
            out,
            "{id} token {} source={source} derived={} {}",
            token.effective,
            token.derived,
            token.override_state()
        );
        if let Some(row) = index.rows_for(id).first() {
            let _ = writeln!(out, "{id} index-token {}", row.abi_token);
        }
        for sub in subs.for_provider(id) {
            let _ = writeln!(
                out,
                "{id} subscription-in {} {} {}",
                sub.consumer, sub.version, sub.token
            );
        }
        for sub in subs.for_consumer(id) {
            let _ = writeln!(out, "{id} subscription-out {} {}", sub.provider, sub.token);
        }
    }
    Ok(())
}

/// The committed `.SRCINFO` provides of one recipe (the declared fallback).
fn declared_provides(recipe_dir: Option<&Path>) -> Vec<String> {
    let Some(dir) = recipe_dir else {
        return Vec::new();
    };
    let path = dir.join(".SRCINFO");
    let Ok(text) = std::fs::read_to_string(&path) else {
        return Vec::new();
    };
    gsa_recipe::parse_srcinfo(&text, &path.to_string_lossy())
        .map(|info| info.provides)
        .unwrap_or_default()
}

/// `gsa -Qr` — the revdep report over the installed-ELF view (contract
/// §B.3): unresolved `DT_NEEDED`, preserved-lib survivors, exact-pin
/// leftovers (`gsa_abi::revdep`). Read-only; rc 0 — report-only like every
/// query (§E.4: a query never refuses).
pub fn query_revdep(
    inv: &Invocation,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<(), String> {
    if !inv.ranges.is_empty() {
        return Err("index ranges address an -S/-B selection (see 'gsa -Sl')".to_string());
    }
    if !inv.targets.is_empty() {
        return Err(
            "gsa -Qr takes no references (it reports the whole installed view)".to_string(),
        );
    }
    let db = LocalDb::load(&pacman_db_root()).map_err(|e| e.to_string())?;
    let view =
        gsa_abi::InstalledView::new(db.packages().into_iter().map(|pkg| gsa_abi::InstalledPkg {
            name: pkg.name.clone(),
            version: pkg.version.clone(),
            provides: pkg.provides.clone(),
            depends: pkg.depends.clone(),
            files: pkg.files.clone(),
        }));
    let root = StateRoot::open(&gsa_state::resolve_state_root(inv.state_dir.as_deref()))
        .map_err(|e| e.to_string())?;
    let (report, corrupt) =
        gsa_abi::revdep_report_with_state(&view, root.path()).map_err(|e| e.to_string())?;
    for line in corrupt {
        let _ = writeln!(err, "gsa: note: {line}");
    }
    for row in gsa_abi::render_revdep(&report) {
        let _ = writeln!(out, "{row}");
    }
    Ok(())
}
