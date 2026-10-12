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
