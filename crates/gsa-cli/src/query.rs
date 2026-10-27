//! The side-car and installed-DB query surface (contract §B.3, §D.1
//! `--local-db-check`): everything here reads the side-car DB, pacman's
//! installed database through the native read-only `LocalDb` reader (the
//! hybrid model's rule: pacman is the only installed-DB AUTHORITY; its
//! local DB is read, never written, and never via a pacman subprocess in a
//! decision seam), and the archives' own `.PKGINFO` — never a re-derived
//! filename guess (§J.4: the index row is authoritative).
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
use crate::render;
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
    let state_dir = gsa_state::resolve_state_root(inv.state_dir.as_deref())?;
    let root = StateRoot::open(&state_dir).map_err(|e| e.to_string())?;
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
    let state_dir = gsa_state::resolve_state_root(inv.state_dir.as_deref())?;
    let root = StateRoot::open(&state_dir).map_err(|e| e.to_string())?;
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
    // `--state-dir PATH` is the §J.3 modifier this seam accepts (stripped
    // before verb matching so the flag tier behaves like on public verbs).
    let mut positional: Vec<String> = Vec::with_capacity(args.len());
    let mut state_flag: Option<&str> = None;
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        if arg == "--state-dir" {
            state_flag = iter.next().map(String::as_str);
            continue;
        }
        positional.push(arg.clone());
    }
    let args: &[String] = &positional;
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
    let root_path = match gsa_state::resolve_state_root(state_flag) {
        Ok(path) => path,
        Err(message) => {
            let _ = writeln!(err, "gsa: {message}");
            return 2;
        }
    };
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
            // The orphan-archive oracle scans the two homes archives
            // actually live in: every recipe directory the topology knows
            // (§J.2's legacy home) AND the W4a shared PKGDEST the index
            // rows point at. The layout is resolved here — the caller owns
            // the workspace knowledge, `gsa_state::check` just scans what
            // it is given — under the engine's ONE layout error policy: an
            // unusable layout is fatal for the operation, never a silent
            // home switch.
            let mut scan_dirs = match crate::find_root() {
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
            match gsa_model::config::build_layout_for_run() {
                Ok(layout) => scan_dirs.push(layout.pkgdest),
                Err(error) => {
                    let _ = writeln!(err, "gsa: {error}");
                    return 3;
                }
            }
            match gsa_state::check(&root, &scan_dirs) {
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
    let state_dir = gsa_state::resolve_state_root(inv.state_dir.as_deref())?;
    let root = StateRoot::open(&state_dir).map_err(|e| e.to_string())?;
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
    let state_dir = gsa_state::resolve_state_root(inv.state_dir.as_deref())?;
    let root = StateRoot::open(&state_dir).map_err(|e| e.to_string())?;
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

/// The side-car read of the `-Q` family (I1): the binpkg index of the state
/// root. A state root that does not exist carries no rows — the surface
/// simply shows no side-car columns ("where a side-car row exists", §B.3);
/// a corrupt index is an error, never a silent skip.
fn side_car_index(inv: &Invocation) -> Result<Option<BinpkgIndex>, String> {
    let state_dir = gsa_state::resolve_state_root(inv.state_dir.as_deref())?;
    if !state_dir.exists() {
        return Ok(None);
    }
    let root = StateRoot::open(&state_dir).map_err(|e| e.to_string())?;
    Ok(Some(BinpkgIndex::load(&root).map_err(|e| e.to_string())?))
}

/// The newest index row for one recipe (rows are registration order = the
/// build-instance order, so the last row is the newest instance).
fn newest_row<'i>(index: &'i Option<BinpkgIndex>, id: &str) -> Option<&'i gsa_state::IndexRow> {
    index
        .as_ref()
        .and_then(|i| i.rows_for(id).into_iter().next_back())
}

/// `gsa -Q` (§B.3, I1): list the INSTALLED packages — pacman's local DB,
/// read natively (`LocalDb`; pacman stays the only installed-DB authority)
/// — with the side-car columns (abi-token, built version, binpkg instances)
/// where a side-car row exists. No references: the whole installed view.
/// Rows: `name version [abi=… built=… instances=…]`, sorted by name.
pub fn query_list(inv: &Invocation, out: &mut dyn Write) -> Result<(), String> {
    if !inv.ranges.is_empty() {
        return Err("index ranges address an -S/-B selection (see 'gsa -Sl')".to_string());
    }
    if !inv.targets.is_empty() {
        return Err("gsa -Q takes no references (it reports the whole installed view)".to_string());
    }
    let db = LocalDb::load(&pacman_db_root()).map_err(|e| e.to_string())?;
    let index = side_car_index(inv)?;
    let mut side: std::collections::BTreeMap<String, &gsa_state::IndexRow> =
        std::collections::BTreeMap::new();
    if let Some(index) = &index {
        for row in &index.rows {
            for name in &row.pkgnames {
                side.insert(name.clone(), row);
            }
        }
    }
    for pkg in db.packages() {
        let mut line = format!("{} {}", pkg.name, pkg.version);
        if let Some(row) = side.get(pkg.name.as_str()) {
            let instances = index
                .as_ref()
                .map(|i| i.instances_for(&row.recipe_id).len())
                .unwrap_or(0);
            line.push_str(&format!(
                " abi={} built={} instances={}",
                row.abi_token, row.version, instances
            ));
        }
        writeln!(out, "{line}").map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// `gsa -Qs <pattern…>` (§B.3, I1): search installed names/descriptions
/// (pacman `-Qs` semantics — the installed database, not the buildable
/// universe). Patterns are case-insensitive literal substrings; multiple
/// patterns OR. Rows: `name version` + indented description.
pub fn query_search(inv: &Invocation, out: &mut dyn Write) -> Result<(), String> {
    if !inv.ranges.is_empty() {
        return Err("index ranges address an -S/-B selection (see 'gsa -Sl')".to_string());
    }
    if inv.targets.is_empty() {
        return Err("requires at least one search pattern".to_string());
    }
    let db = LocalDb::load(&pacman_db_root()).map_err(|e| e.to_string())?;
    for pkg in db.packages() {
        let desc = pkg.desc.clone().unwrap_or_default();
        if matches(&inv.targets, &[pkg.name.clone(), desc.clone()]) {
            writeln!(out, "{} {}", pkg.name, pkg.version).map_err(|e| e.to_string())?;
            writeln!(out, "    {desc}").map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}

fn matches(patterns: &[String], haystacks: &[String]) -> bool {
    let lowered: Vec<String> = haystacks.iter().map(|h| h.to_ascii_lowercase()).collect();
    patterns.iter().any(|p| {
        let p = p.to_ascii_lowercase();
        lowered.iter().any(|h| h.contains(&p))
    })
}

fn join_or_none(values: &[String]) -> String {
    if values.is_empty() {
        "(none)".to_string()
    } else {
        values.join(", ")
    }
}

/// `gsa -Qi <ref…>` (§B.3 + H7/H8, merged): one block per output name —
/// the recipe record the package comes from, the installed record (where
/// one exists), the side-car record (abi-token, subscriptions in/out,
/// retained binpkg instances, VCS baseline) and the topology record.
pub fn query_info(
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
    let indices = crate::resolve_records(ctx, &inv.targets, err)?;
    if indices.is_empty() {
        return Err("no recipes resolved".to_string());
    }
    let db = LocalDb::load(&pacman_db_root()).map_err(|e| e.to_string())?;
    let index = side_car_index(inv)?;
    let state_dir = gsa_state::resolve_state_root(inv.state_dir.as_deref())?;
    let subs = gsa_abi::Subscriptions::load(&gsa_abi::subscriptions_path(&state_dir))
        .map_err(|e| e.to_string())?;
    let mut first = true;
    for &idx in &indices {
        let record = ctx.graph.record(idx);
        let id = record.id.as_str();
        let row = newest_row(&index, id);
        let instances = index
            .as_ref()
            .map(|i| i.instances_for(id).len())
            .unwrap_or(0);
        let meta = ctx
            .db
            .get(id)
            .ok_or_else(|| "recipe metadata missing".to_string())?;
        let version = meta.full_version().map_err(|e| e.to_string())?;
        for pkgname in meta.pkgnames() {
            if !first {
                let _ = writeln!(out);
            }
            first = false;
            let mut extra: Vec<(String, String)> = Vec::new();
            match db.get(&pkgname) {
                Some(pkg) => {
                    extra.push(("Installed-Version".to_string(), pkg.version.clone()));
                    extra.push((
                        "Installed-Provides".to_string(),
                        join_or_none(&pkg.provides),
                    ));
                    extra.push((
                        "Installed-Depends-On".to_string(),
                        join_or_none(&pkg.depends),
                    ));
                }
                None => {
                    extra.push(("Installed-Version".to_string(), "(not installed)".to_string()));
                }
            }
            match row {
                Some(row) => {
                    extra.push(("ABI-Token".to_string(), row.abi_token.clone()));
                    extra.push(("Built-Version".to_string(), row.version.clone()));
                    extra.push(("Binpkg-Instances".to_string(), instances.to_string()));
                    extra.push(("VCS-Baseline".to_string(), row.vcs_baseline.clone()));
                }
                None => {
                    extra.push(("ABI-Token".to_string(), "(no side-car row)".to_string()));
                    extra.push(("Binpkg-Instances".to_string(), "0".to_string()));
                }
            }
            let subs_in: Vec<String> = subs
                .for_provider(id)
                .into_iter()
                .map(|s| format!("{} {} {}", s.consumer, s.version, s.token))
                .collect();
            let subs_out: Vec<String> = subs
                .for_consumer(id)
                .into_iter()
                .map(|s| format!("{} {}", s.provider, s.token))
                .collect();
            extra.push((
                "Subscriptions-In".to_string(),
                if subs_in.is_empty() {
                    "(none)".to_string()
                } else {
                    subs_in.join("; ")
                },
            ));
            extra.push((
                "Subscriptions-Out".to_string(),
                if subs_out.is_empty() {
                    "(none)".to_string()
                } else {
                    subs_out.join("; ")
                },
            ));
            let _ = write!(
                out,
                "{}",
                render::render_package_info(ctx, record, &pkgname, &version, &extra)
            );
        }
    }
    Ok(())
}

/// `gsa -Qu` (§B.3, I3): the stale set — recipes whose tracked (committed)
/// version moved past their newest complete built instance
/// (`prepare::stale_set`'s definition). Rows:
/// `id tracked=<pv-pr> built=<pv-pr>`.
pub fn query_updates(
    ctx: &Ctx<'_>,
    root: &Path,
    inv: &Invocation,
    out: &mut dyn Write,
) -> Result<(), String> {
    if !inv.ranges.is_empty() {
        return Err("index ranges address an -S/-B selection (see 'gsa -Sl')".to_string());
    }
    if !inv.targets.is_empty() {
        return Err("gsa -Qu takes no references (it reports the whole stale set)".to_string());
    }
    let ids: Vec<gsa_model::RecipeId> = ctx.graph.records().iter().map(|r| r.id.clone()).collect();
    for id in crate::prepare::stale_set(root, ctx.graph, &ids) {
        let idx = ctx
            .graph
            .index_of(id.as_str())
            .expect("stale ids resolve to records");
        let recipe_dir = root.join(&ctx.graph.record(idx).path);
        let tracked = gsa_recipe::freshness::current_version_key(&recipe_dir)
            .map(|(pv, pr)| format!("{pv}-{pr}"))
            .unwrap_or_else(|_| "?".to_string());
        let built = gsa_recipe::freshness::discover_newest_complete_set(&recipe_dir)
            .version_key
            .unwrap_or_else(|| "-".to_string());
        writeln!(out, "{} tracked={tracked} built={built}", id.as_str())
            .map_err(|e| e.to_string())?;
    }
    Ok(())
}

/// `-Ql`/`-Qo` (§B.3, I3 + H8: "pacman queries stay pacman"): pacman
/// delegates — the query IS pacman's own, so the engine runs the pacman
/// argv verbatim and passes its stdout, stderr and exit code through.
pub fn pacman_delegate(
    pacman_action: &str,
    inv: &Invocation,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<i32, String> {
    if !inv.ranges.is_empty() {
        return Err("index ranges address an -S/-B selection (see 'gsa -Sl')".to_string());
    }
    if inv.targets.is_empty() {
        return Err(format!(
            "requires at least one {}",
            if pacman_action == "-Ql" {
                "reference"
            } else {
                "path"
            }
        ));
    }
    let output = std::process::Command::new("pacman")
        .arg(pacman_action)
        .args(&inv.targets)
        .output()
        .map_err(|e| format!("cannot run pacman {pacman_action}: {e}"))?;
    out.write_all(&output.stdout).map_err(|e| e.to_string())?;
    err.write_all(&output.stderr).map_err(|e| e.to_string())?;
    Ok(output.status.code().unwrap_or(1))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Pin the process-global layout/state seams to one scratch tree for
    /// the closure (env is process-global and test threads share it), and
    /// restore whatever was there before on the way out.
    struct EnvPin {
        _lock: std::sync::MutexGuard<'static, ()>,
        saved: Vec<(&'static str, Option<std::ffi::OsString>)>,
    }

    impl EnvPin {
        fn take(root: &Path) -> EnvPin {
            static LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());
            let lock = LOCK.lock().unwrap_or_else(|e| e.into_inner());
            let conf = root.join("gsa.conf");
            std::fs::write(&conf, "# fixture: empty layers\n").unwrap();
            let pinned: [(&'static str, std::ffi::OsString); 3] = [
                ("GSA_CONF", conf.into_os_string()),
                ("GSA_BUILD_DIR", root.join("cache").into_os_string()),
                ("GSA_STATE_DIR", root.join("state").into_os_string()),
            ];
            let mut saved = Vec::new();
            for (key, value) in pinned {
                saved.push((key, std::env::var_os(key)));
                std::env::set_var(key, &value);
            }
            EnvPin { _lock: lock, saved }
        }
    }

    impl Drop for EnvPin {
        fn drop(&mut self) {
            for (key, value) in self.saved.drain(..) {
                match value {
                    Some(value) => std::env::set_var(key, value),
                    None => std::env::remove_var(key),
                }
            }
        }
    }

    /// The orphan-archive oracle must see the two homes archives actually
    /// live in: the topology's recipe dirs (§J.2's legacy home) AND the
    /// W4a PKGDEST the index rows point at — a PKGDEST orphan with no row
    /// is a finding, named.
    #[test]
    fn local_db_check_scans_the_pkgdest_home_for_orphans() {
        let scratch = std::env::temp_dir().join(format!("gsa-cli-query-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&scratch);
        std::fs::create_dir_all(&scratch).unwrap();
        let _env = EnvPin::take(&scratch);

        // A clean state root; one orphan archive in the live PKGDEST home.
        let pkgdest = scratch.join("cache").join("pkgs");
        std::fs::create_dir_all(&pkgdest).unwrap();
        let orphan = pkgdest.join("stray-1.0-1-any.pkg.tar.zst");
        std::fs::write(&orphan, b"not a real archive (the oracle is name-shaped)\n").unwrap();

        let mut out = Vec::new();
        let mut err = Vec::new();
        let rc = run_local_db_check(&[], &mut out, &mut err);
        let text = String::from_utf8_lossy(&out).into_owned();
        assert_eq!(rc, 1, "a PKGDEST orphan is a finding: {text}");
        assert!(
            text.contains("orphan-archive stray-1.0-1-any.pkg.tar.zst"),
            "the PKGDEST orphan is named: {text}"
        );

        let _ = std::fs::remove_dir_all(&scratch);
    }
}
