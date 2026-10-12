//! Human renderings for the read-only command surface.
//!
//! The machine rendering of the run record lives in `gsa-model` (its
//! grammar), the plan's prose summary lives here; the live-run view is the
//! streaming dashboard line per supervisor event (ADR 0003: one record,
//! three renderings — dashboard events, prose summary, machine block).

use std::path::Path;

use gsa_model::{Group, RecipeId, RowStatus, RunRecord};
use gsa_recipe::{MetaSource, RecipeMeta, SourceKind};
use gsa_sched::supervisor::SupEvent;

use crate::select::{Ctx, SelectError};

fn join_list(values: &[String]) -> String {
    if values.is_empty() {
        "(none)".to_string()
    } else {
        values.join(", ")
    }
}

fn field(label: &str, value: &str) -> String {
    format!("{label:<18}: {value}")
}

/// The tooling data channel (contract §B.3 `-Qt`): one resolved record per
/// line, `id|path|groups|edges|tags`, no header — the line count is the
/// record count.
pub fn render_topology_channel(ctx: &Ctx<'_>) -> String {
    let mut out = String::new();
    for record in ctx.graph.records() {
        out.push_str(&record.wire());
        out.push('\n');
    }
    out
}

/// The ordered selection listing (`-Sl`/`-Bl`), fish-engine shape: heading,
/// anchored rows, and the footer that says what the indices address.
pub fn render_listing(ctx: &Ctx<'_>, listed: &[(usize, RecipeId)], whole_set: bool) -> String {
    let mut out = String::new();
    if whole_set {
        out.push_str("All packages in build order:\n");
    } else {
        out.push_str(&format!(
            "Selected packages in build order ({}):\n",
            listed.len()
        ));
    }
    out.push('\n');
    for (anchor, id) in listed {
        out.push_str(&format!("{anchor:>4}. {id}\n"));
    }
    out.push('\n');
    if whole_set {
        out.push_str("Groups:\n");
        for group in Group::ROSTER {
            out.push_str(&format!(
                "  {:<12}{} packages\n",
                format!("{}:", group.as_str()),
                ctx.project.topology.members(group).len()
            ));
        }
    } else {
        out.push_str("Ranges index this list: e.g. '22..38' selects entries 22-38 above.\n");
    }
    out
}

fn tags_line(record: &gsa_model::TopologyRecord) -> String {
    if record.tags.is_empty() {
        "(none)".to_string()
    } else {
        record
            .tags
            .iter()
            .map(|t| t.to_wire())
            .collect::<Vec<_>>()
            .join(", ")
    }
}

fn edges_line(record: &gsa_model::TopologyRecord) -> String {
    if record.edges.is_empty() {
        "(none)".to_string()
    } else {
        record
            .edges
            .iter()
            .map(|e| e.as_str().to_string())
            .collect::<Vec<_>>()
            .join(", ")
    }
}

fn sources_block(meta: &RecipeMeta) -> String {
    let sources = meta.sources();
    if sources.is_empty() {
        return format!("{}\n", field("Sources", "(none)"));
    }
    let mut out = format!("{}\n", field("Sources", ""));
    for source in sources {
        let label = match source.kind {
            SourceKind::Vcs(kind) => format!("vcs:{}", kind.as_str()),
            SourceKind::Remote => "remote".to_string(),
            SourceKind::Local => "local".to_string(),
        };
        let name = source.name.map(|n| format!("{n}::")).unwrap_or_default();
        out.push_str(&format!("    [{label}] {name}{}\n", source.location));
    }
    out
}

fn record_fields(record: &gsa_model::TopologyRecord) -> Vec<(String, String)> {
    let groups = record
        .groups
        .iter()
        .map(|g| g.as_str().to_string())
        .collect::<Vec<_>>();
    vec![
        ("Recipe-Id".to_string(), record.id.as_str().to_string()),
        ("Recipe-Path".to_string(), record.path.clone()),
        ("Groups".to_string(), join_list(&groups)),
        ("Build-Order-Edges".to_string(), edges_line(record)),
        ("Tags".to_string(), tags_line(record)),
    ]
}

/// `-Si`: recipe info — metadata, topology record, groups, build-order
/// edges, tags (contract §B.4).
pub fn render_recipe_info(ctx: &Ctx<'_>, record: &gsa_model::TopologyRecord) -> String {
    let meta = ctx.db.get(record.id.as_str());
    let mut out = String::new();
    for (label, value) in record_fields(record) {
        out.push_str(&format!("{label:<18}: {value}\n"));
    }
    match meta {
        Some(meta) => {
            out.push_str(&field("Metadata-Source", meta.source.as_str()));
            out.push('\n');
            out.push_str(&field("Name(s)", &join_list(&meta.pkgnames())));
            out.push('\n');
            out.push_str(&field(
                "Version",
                &meta.full_version().unwrap_or_else(|e| format!("<{e}>")),
            ));
            out.push('\n');
            out.push_str(&field(
                "pkgver() Function",
                // The function table comes from the read-only scan — a fact
                // committed .SRCINFO cannot carry (contract §A.2.3).
                if ctx
                    .db
                    .scan_for(&record.id)
                    .map(|scan| scan.functions.contains("pkgver"))
                    .unwrap_or(false)
                {
                    "present (version derives at build time)"
                } else {
                    "absent"
                },
            ));
            out.push('\n');
            out.push_str(&field(
                "Description",
                meta.pkgdesc().ok().flatten().unwrap_or("(none)"),
            ));
            out.push('\n');
            let info = meta.srcinfo.as_ref();
            let multi = |get: fn(&gsa_recipe::Srcinfo) -> Vec<String>| {
                info.map(|i| join_list(&get(i)))
                    .unwrap_or_else(|| "(scan)".to_string())
            };
            out.push_str(&field(
                "URL",
                info.and_then(|i| i.url.as_deref()).unwrap_or("(none)"),
            ));
            out.push('\n');
            out.push_str(&field("Architecture", &multi(|i| i.arch.clone())));
            out.push('\n');
            out.push_str(&field("Licenses", &multi(|i| i.license.clone())));
            out.push('\n');
            out.push_str(&field("Depends On", &multi(|i| i.depends.clone())));
            out.push('\n');
            out.push_str(&field("Make Depends On", &multi(|i| i.makedepends.clone())));
            out.push('\n');
            out.push_str(&field(
                "Check Depends On",
                &multi(|i| i.checkdepends.clone()),
            ));
            out.push('\n');
            out.push_str(&field("Opt Depends On", &multi(|i| i.optdepends.clone())));
            out.push('\n');
            out.push_str(&field("Provides", &multi(|i| i.provides.clone())));
            out.push('\n');
            out.push_str(&field("Conflicts With", &multi(|i| i.conflicts.clone())));
            out.push('\n');
            out.push_str(&field("Replaces", &multi(|i| i.replaces.clone())));
            out.push('\n');
            out.push_str(&sources_block(&meta));
        }
        None => {
            out.push_str(&field("Metadata-Source", MetaSource::Scan.as_str()));
            out.push('\n');
        }
    }
    out
}

/// `-Qi`: one block per output name — pacman fields plus the recipe record
/// the package comes from. Side-car columns (abi-token, binpkg instances,
/// subscriptions) belong to the side-car database of a later phase and are
/// deliberately absent, not faked.
pub fn render_package_info(
    ctx: &Ctx<'_>,
    record: &gsa_model::TopologyRecord,
    pkgname: &str,
    version: &str,
) -> String {
    let meta = ctx.db.get(record.id.as_str());
    let mut out = String::new();
    out.push_str(&field("Name", pkgname));
    out.push('\n');
    out.push_str(&field("Version", version));
    out.push('\n');
    out.push_str(&field(
        "Description",
        meta.as_ref()
            .and_then(|m| m.pkgdesc().ok().flatten())
            .unwrap_or("(none)"),
    ));
    out.push('\n');
    if let Some(info) = meta.as_ref().and_then(|m| m.srcinfo.as_ref()) {
        out.push_str(&field("URL", info.url.as_deref().unwrap_or("(none)")));
        out.push('\n');
        out.push_str(&field("Architecture", &join_list(&info.arch)));
        out.push('\n');
        out.push_str(&field("Licenses", &join_list(&info.license)));
        out.push('\n');
        out.push_str(&field("Depends On", &join_list(&info.depends)));
        out.push('\n');
        out.push_str(&field("Provides", &join_list(&info.provides)));
        out.push('\n');
        out.push_str(&field("Conflicts With", &join_list(&info.conflicts)));
        out.push('\n');
    }
    for (label, value) in record_fields(record) {
        out.push_str(&format!("{label:<18}: {value}\n"));
    }
    out.push_str(&field(
        "Metadata-Source",
        meta.as_ref()
            .map(|m| m.source.as_str())
            .unwrap_or(MetaSource::Scan.as_str()),
    ));
    out.push('\n');
    out
}

fn matches(patterns: &[String], haystacks: &[String]) -> bool {
    let lowered: Vec<String> = haystacks.iter().map(|h| h.to_ascii_lowercase()).collect();
    patterns.iter().any(|p| {
        let p = p.to_ascii_lowercase();
        lowered.iter().any(|h| h.contains(&p))
    })
}

/// `-Ss`: search the buildable universe (topology + committed `.SRCINFO`).
/// Patterns are case-insensitive literal substrings; multiple patterns OR.
pub fn render_universe_search(ctx: &Ctx<'_>, patterns: &[String]) -> String {
    let mut out = String::new();
    for record in ctx.graph.records() {
        let meta = ctx.db.get(record.id.as_str());
        let mut haystacks = vec![record.id.as_str().to_string()];
        let pkgnames = meta.as_ref().map(|m| m.pkgnames()).unwrap_or_default();
        haystacks.extend(pkgnames.iter().cloned());
        let desc = meta
            .as_ref()
            .and_then(|m| m.pkgdesc().ok().flatten())
            .unwrap_or("")
            .to_string();
        haystacks.push(desc.clone());
        if matches(patterns, &haystacks) {
            let groups = record
                .groups
                .iter()
                .map(|g| g.as_str())
                .collect::<Vec<_>>()
                .join(",");
            let version = meta
                .as_ref()
                .and_then(|m| m.full_version().ok())
                .unwrap_or_else(|| "?".to_string());
            out.push_str(&format!("{groups}/{} {version}\n", record.id));
            out.push_str(&format!("    {desc}\n"));
        }
    }
    out
}

/// `-Qs`: search package names/descriptions over the buildable universe.
pub fn render_query_search(ctx: &Ctx<'_>, patterns: &[String]) -> String {
    let mut out = String::new();
    for (pkgname, meta) in ctx.db.pkgnames_sorted() {
        let desc = meta.pkgdesc().ok().flatten().unwrap_or("").to_string();
        if matches(patterns, &[pkgname.clone(), desc.clone()]) {
            let version = meta.full_version().unwrap_or_else(|_| "?".to_string());
            out.push_str(&format!("{pkgname} {version}\n"));
            out.push_str(&format!("    {desc}\n"));
        }
    }
    out
}

/// `-Sg`: groups/sets and their members. No name: the full group roster
/// with counts (contract §B.4) plus any user sets.
pub fn render_groups(ctx: &Ctx<'_>, names: &[String]) -> Result<String, SelectError> {
    let mut out = String::new();
    if names.is_empty() {
        for group in Group::ROSTER {
            out.push_str(&format!(
                "{:<12} {} packages\n",
                group.as_str(),
                ctx.project.topology.members(group).len()
            ));
        }
        for set in &ctx.project.sets {
            out.push_str(&format!(
                "{:<12} {} packages\n",
                set.name,
                set.members.len()
            ));
        }
        return Ok(out);
    }
    for raw in names {
        let name = raw.strip_prefix('@').unwrap_or(raw);
        if let Some(group) = Group::from_name(name) {
            let members: Vec<RecipeId> = ctx.project.topology.members(group).to_vec();
            out.push_str(&format!("{} ({}):\n", name, members.len()));
            for member in members {
                out.push_str(&format!("  {member}\n"));
            }
            continue;
        }
        if let Some(set) = ctx.project.set(name) {
            out.push_str(&format!("{} ({}):\n", name, set.members.len()));
            for member in &set.members {
                out.push_str(&format!("  {member}\n"));
            }
            continue;
        }
        return Err(match crate::select::nearest_candidates(ctx, raw, true) {
            candidates if candidates.is_empty() => {
                SelectError::new(format!("unknown group or set '{raw}'"))
            }
            candidates => SelectError::new(format!(
                "unknown group or set '{raw}' (nearest candidates: {})",
                candidates.join(", ")
            )),
        });
    }
    Ok(out)
}

/// `-Q`: package names with versions, sorted by name.
pub fn render_query_list(entries: &[(String, String)]) -> String {
    let mut out = String::new();
    for (pkgname, version) in entries {
        out.push_str(&format!("{pkgname} {version}\n"));
    }
    out
}

/// Prose summary of the plan (one of the record's three renderings).
pub fn render_plan_prose(
    listed: &[(usize, RecipeId)],
    expansion_added: usize,
    closure_size: usize,
    leaf: bool,
    dry_run: bool,
) -> String {
    let mut out = String::new();
    let verb = if dry_run { "dry run" } else { "run" };
    out.push_str(&format!(
        "Build order ({verb}): {} packages\n",
        listed.len()
    ));
    if leaf {
        out.push_str("· leaf selection: no consumer expansion (--leaf)\n");
    } else if expansion_added > 0 {
        out.push_str(&format!(
            "· consumer expansion added {expansion_added} of the {closure_size} selected packages (--leaf builds only what you named)\n",
        ));
    }
    out.push('\n');
    for (anchor, id) in listed {
        out.push_str(&format!("{anchor:>4}. {id}\n"));
    }
    out
}

/// One streaming dashboard line (contract §H.1: the run record rows in
/// motion). Plain output — a TTY dashboard renders the same events.
pub fn render_event(event: &SupEvent, ids: &[RecipeId]) -> String {
    let pkg = |index: usize| {
        ids.get(index)
            .map(|id| id.as_str().to_string())
            .unwrap_or_else(|| format!("<{index}>"))
    };
    match event {
        SupEvent::Started { index, jobs, core } => {
            let core = if *core { " (core)" } else { "" };
            format!("lane start {}{core} -j{jobs}\n", pkg(*index))
        }
        SupEvent::Finished { index, row } => {
            let rc = row
                .rc
                .map(|rc| rc.to_string())
                .unwrap_or_else(|| "-".to_string());
            let dur = row
                .dur
                .map(|dur| dur.to_string())
                .unwrap_or_else(|| "-".to_string());
            let _ = index;
            format!(
                "lane done {} {} {} {} {}\n",
                row.pkg, row.status, rc, dur, row.reason
            )
        }
        SupEvent::Parked { index, reason } => format!("park {} {}\n", pkg(*index), reason),
        SupEvent::Signal(sig) => format!("signal {sig}\n"),
        SupEvent::Teardown(reason) => format!("teardown {reason}\n"),
        SupEvent::Diagnostic(message) => format!("note: {message}\n"),
    }
}

/// The prose summary (contract §I.4: loud reporting — every failed package
/// with its log path, the full parked cone with each member's park reason
/// and the failure that parked it, every deferred package with its reason).
/// `parked_by` maps each parked package id to the package ids whose event
/// parked it (computed once from the same rows and topology, never here).
pub fn render_run_prose(
    record: &RunRecord,
    log_dir: &Path,
    parked_by: &[(String, Vec<String>)],
) -> String {
    let mut out = String::new();
    let (lanes, normal, core) = match (record.lanes, record.normal_jobs, record.core_jobs) {
        (Some(l), Some(n), Some(c)) => (l.to_string(), n.to_string(), c.to_string()),
        _ => ("-".to_string(), "-".to_string(), "-".to_string()),
    };
    out.push_str(&format!(
        "Build run: {} package(s), lanes {lanes} (normal -j{normal}, core -j{core}), intensity {}\n",
        record.order.len(),
        record.intensity
    ));
    for row in &record.outcomes {
        let rc = row
            .rc
            .map(|rc| rc.to_string())
            .unwrap_or_else(|| "-".to_string());
        match row.status {
            RowStatus::Failed => {
                out.push_str(&format!(
                    "· failed: {} (rc {rc}, {}) — log: {}\n",
                    row.pkg,
                    row.reason,
                    log_dir.join(format!("{}.log", row.pkg)).display()
                ));
            }
            RowStatus::Parked => {
                let by = parked_by
                    .iter()
                    .find(|(pkg, _)| pkg == row.pkg.as_str())
                    .map(|(_, by)| by.clone())
                    .unwrap_or_default();
                let by = if by.is_empty() {
                    "-".to_string()
                } else {
                    by.join(", ")
                };
                out.push_str(&format!(
                    "· parked: {} ({}) — parked by {}\n",
                    row.pkg, row.reason, by
                ));
            }
            RowStatus::Deferred => {
                out.push_str(&format!("· deferred: {} ({})\n", row.pkg, row.reason));
            }
            RowStatus::NeverStarted => {
                out.push_str(&format!("· never started: {} ({})\n", row.pkg, row.reason));
            }
            RowStatus::Interrupted => {
                out.push_str(&format!(
                    "· interrupted: {} (rc {rc}, {})\n",
                    row.pkg, row.reason
                ));
            }
            RowStatus::Succeeded => {
                out.push_str(&format!("· succeeded: {} ({})\n", row.pkg, row.reason));
            }
        }
    }
    out.push_str(&format!("outcome: {} (rc {})\n", record.outcome, record.rc));
    out
}
