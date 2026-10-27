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

use crate::output::{self, kv_line, squash, Level};
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

/// `-Qi` (§B.3 + H7/H8, merged): one block per output name — the recipe
/// record the package comes from, the installed record (where one exists),
/// the side-car record (abi-token, subscriptions in/out, retained binpkg
/// instances, VCS baseline), and the topology record. `extra` carries the
/// installed + side-car fields (the query owns their derivation).
pub fn render_package_info(
    ctx: &Ctx<'_>,
    record: &gsa_model::TopologyRecord,
    pkgname: &str,
    version: &str,
    extra: &[(String, String)],
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
    if let Some(meta) = meta.as_ref() {
        // The recipe record (the `-Si` content merged in — H7/H8): the
        // committed `.SRCINFO` fields, the pkgver() scan fact and the
        // sources block.
        let info = meta.srcinfo.as_ref();
        let multi = |get: fn(&gsa_recipe::Srcinfo) -> Vec<String>| {
            info.map(|i| join_list(&get(i)))
                .unwrap_or_else(|| "(scan)".to_string())
        };
        out.push_str(&field("URL", info.and_then(|i| i.url.as_deref()).unwrap_or("(none)")));
        out.push('\n');
        out.push_str(&field("Architecture", &multi(|i| i.arch.clone())));
        out.push('\n');
        out.push_str(&field("Licenses", &multi(|i| i.license.clone())));
        out.push('\n');
        out.push_str(&field("Depends On", &multi(|i| i.depends.clone())));
        out.push('\n');
        out.push_str(&field("Make Depends On", &multi(|i| i.makedepends.clone())));
        out.push('\n');
        out.push_str(&field("Check Depends On", &multi(|i| i.checkdepends.clone())));
        out.push('\n');
        out.push_str(&field("Opt Depends On", &multi(|i| i.optdepends.clone())));
        out.push('\n');
        out.push_str(&field("Provides", &multi(|i| i.provides.clone())));
        out.push('\n');
        out.push_str(&field("Conflicts With", &multi(|i| i.conflicts.clone())));
        out.push('\n');
        out.push_str(&field("Replaces", &multi(|i| i.replaces.clone())));
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
        out.push_str(&sources_block(meta));
    }
    for (label, value) in extra {
        out.push_str(&field(label, value));
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

/// `-Qg` (H7/H8: the groups query lives in the `-Q` family): groups/sets
/// and their members. No name: the full group roster with counts (contract
/// §B.3) plus any user sets.
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
    let human = output::is_human();
    if human {
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
    } else {
        out.push_str(&kv_line(
            Level::Info,
            "build-order",
            &[
                ("verb", squash(verb)),
                ("packages", listed.len().to_string()),
            ],
        ));
        out.push('\n');
        if leaf {
            out.push_str(&kv_line(
                Level::Info,
                "selection",
                &[
                    ("expansion", "leaf".to_string()),
                    ("note", "no_consumer_expansion".to_string()),
                ],
            ));
            out.push('\n');
        } else if expansion_added > 0 {
            out.push_str(&kv_line(
                Level::Info,
                "selection",
                &[
                    ("expansion", "consumers".to_string()),
                    ("added", expansion_added.to_string()),
                    ("of", closure_size.to_string()),
                ],
            ));
            out.push('\n');
        }
    }
    out.push('\n');
    for (anchor, id) in listed {
        out.push_str(&format!("{anchor:>4}. {id}\n"));
    }
    out
}

/// The parallelism truth line (budget.rs renders the human prose; the
/// machine mode restates it as leveled kv — same numbers, both worlds).
pub fn parallelism_line(budget: &gsa_sched::budget::Budget) -> String {
    if output::is_human() {
        return format!("{}\n", budget.parallelism_line());
    }
    format!(
        "{}\n",
        kv_line(
            Level::Info,
            "parallelism",
            &[
                ("cpus", budget.threads.to_string()),
                ("mem-gib", budget.memory_gib.to_string()),
                ("intensity", budget.intensity.to_string()),
                ("lanes", budget.lanes.to_string()),
                ("normal-jobs", budget.normal_jobs.to_string()),
                ("core-jobs", budget.core_jobs.to_string()),
            ],
        )
    )
}

/// One streaming dashboard line (contract §H.1: the run record rows in
/// motion). Two vocabularies (owner decision 2026-10-23): the human default
/// is the fish-era readable form (`✓ vtk (3m57s)`); the machine mode is the
/// leveled `LEVEL event k=v` grammar (output::kv_line).
pub fn render_event(event: &SupEvent, ids: &[RecipeId]) -> String {
    let pkg = |index: usize| {
        ids.get(index)
            .map(|id| id.as_str().to_string())
            .unwrap_or_else(|| format!("<{index}>"))
    };
    if output::is_human() {
        return render_event_human(event, &pkg);
    }
    render_event_machine(event, &pkg)
}

/// `3m07s` / `42s` — the fish-era duration shape (`fmt_dur` there).
pub(crate) fn fmt_dur(dur: i64) -> String {
    if dur >= 60 {
        format!("{}m{:02}s", dur / 60, dur % 60)
    } else {
        format!("{dur}s")
    }
}

fn render_event_human(event: &SupEvent, pkg: &dyn Fn(usize) -> String) -> String {
    match event {
        SupEvent::Started { index, jobs, core } => {
            let core = if *core { " (core)" } else { "" };
            format!("→ started {}{core} -j{jobs}\n", pkg(*index))
        }
        SupEvent::Finished { index, row } => {
            let _ = index;
            let rc = row
                .rc
                .map(|rc| rc.to_string())
                .unwrap_or_else(|| "-".to_string());
            let dur = row.dur.map(fmt_dur).unwrap_or_else(|| "-".to_string());
            match row.status {
                RowStatus::Succeeded => format!("✓ {} ({dur})\n", row.pkg),
                RowStatus::Failed => format!(
                    "✗ {}: BUILD FAILED (rc {rc}, {dur}, {}) — see the run's failed rows for the log\n",
                    row.pkg, row.reason
                ),
                RowStatus::Parked => format!("⚠ {}: parked ({})\n", row.pkg, row.reason),
                RowStatus::Deferred => format!("⚠ {}: DEFERRED ({})\n", row.pkg, row.reason),
                RowStatus::NeverStarted => {
                    format!("· {}: never started ({})\n", row.pkg, row.reason)
                }
                RowStatus::Interrupted => {
                    format!("⚠ {}: interrupted (rc {rc}, {dur}, {})\n", row.pkg, row.reason)
                }
            }
        }
        SupEvent::Parked { index, reason } => format!("⚠ {}: parked ({reason})\n", pkg(*index)),
        SupEvent::Signal(sig) => format!("⚠ signal received ({sig}) — the run is winding down\n"),
        SupEvent::Teardown(reason) => format!("⚠ teardown: {reason}\n"),
        SupEvent::Diagnostic(message) => format!("· {message}\n"),
        SupEvent::PrefetchWarning(message) => format!("⚠ {message}\n"),
        // A view heartbeat, never a message (the TTY dashboard redraws on
        // it) — it renders empty in BOTH vocabularies.
        SupEvent::Tick => String::new(),
    }
}

fn render_event_machine(event: &SupEvent, pkg: &dyn Fn(usize) -> String) -> String {
    use Level::{Info, Warning};
    let line = match event {
        SupEvent::Started { index, jobs, core } => kv_line(
            Info,
            "lane-start",
            &[
                ("pkg", pkg(*index)),
                ("core", if *core { "1" } else { "0" }.to_string()),
                ("jobs", jobs.to_string()),
            ],
        ),
        SupEvent::Finished { index, row } => {
            let _ = index;
            let rc = row
                .rc
                .map(|rc| rc.to_string())
                .unwrap_or_else(|| "-".to_string());
            let dur = row
                .dur
                .map(|d| d.to_string())
                .unwrap_or_else(|| "-".to_string());
            let (level, name, action) = match row.status {
                RowStatus::Succeeded => (Info, "lane-done", None),
                RowStatus::Failed => (Warning, "lane-failed", Some("inspect-log")),
                RowStatus::Parked => (Warning, "lane-parked", Some("waits-on-failed")),
                RowStatus::Deferred => (Warning, "lane-deferred", Some("revisit-deferral")),
                RowStatus::NeverStarted => (Warning, "lane-never-started", Some("rerun")),
                RowStatus::Interrupted => (Warning, "lane-interrupted", Some("rerun")),
            };
            let mut pairs = vec![
                ("pkg", row.pkg.to_string()),
                ("status", squash(&row.status.to_string())),
                ("rc", rc),
                ("dur", dur),
                ("reason", squash(&row.reason)),
            ];
            if let Some(action) = action {
                pairs.push(("action", action.to_string()));
            }
            kv_line(level, name, &pairs)
        }
        SupEvent::Parked { index, reason } => kv_line(
            Warning,
            "lane-parked",
            &[
                ("pkg", pkg(*index)),
                ("reason", squash(reason)),
                ("action", "waits-on-failed".to_string()),
            ],
        ),
        SupEvent::Signal(sig) => kv_line(Warning, "signal", &[("sig", sig.to_string())]),
        SupEvent::Teardown(reason) => kv_line(
            Warning,
            "teardown",
            &[
                ("reason", squash(reason)),
                ("action", "wait-for-drain".to_string()),
            ],
        ),
        SupEvent::Diagnostic(message) => kv_line(Info, "note", &[("msg", squash(message))]),
        SupEvent::PrefetchWarning(message) => {
            kv_line(Warning, "prefetch-warning", &[("msg", squash(message))])
        }
        // A view heartbeat, never a message: empty in BOTH vocabularies, so
        // a machine stream gains nothing per tick (early return — the frame
        // below terminates real lines only).
        SupEvent::Tick => return String::new(),
    };
    format!("{line}\n")
}

/// The prose prefetch-warning section (owner decision 5 / docs/adr/
/// 0004-prefetch-advisory.md): a build run's fetch-ahead advisories, loud
/// but never rows — the lanes remain authoritative and retry at build time.
/// Empty when the run had none.
pub fn render_prefetch_notes(warnings: &[gsa_fetch::verdict::FetchResult]) -> String {
    if warnings.is_empty() {
        return String::new();
    }
    let mut out = String::new();
    if output::is_human() {
        out.push_str("Prefetch warnings (advisory — lanes retry at build time):\n");
        for warning in warnings {
            out.push_str(&format!(
                "⚠ {} {} {}\n",
                warning.pkg, warning.verdict, warning.reason
            ));
        }
        return out;
    }
    out.push_str(&kv_line(
        Level::Warning,
        "prefetch-summary",
        &[
            ("advisory", "1".to_string()),
            ("note", "lanes_retry_at_build_time".to_string()),
        ],
    ));
    out.push('\n');
    for warning in warnings {
        out.push_str(&kv_line(
            Level::Warning,
            "prefetch",
            &[
                ("pkg", warning.pkg.clone()),
                ("verdict", squash(&warning.verdict.to_string())),
                ("reason", squash(&warning.reason)),
                ("action", "none-lanes-retry".to_string()),
            ],
        ));
        out.push('\n');
    }
    out
}

/// H6 (2026-10-28): the per-package fetch message. The human surface gets
/// the fetch voice — never the shared `<pkg> <verdict> <dur> <reason>` row
/// template the other actions use. A `skipped` verdict already answers
/// through the engine's own `gsa-fetch:` note (its reason prose is
/// engine-owned), so the human line covers the verdicts that were silent or
/// unclear: `ok` (nothing at all was printed for a clean fetch) and `failed`
/// (whose engine notes are attempt detail, never the verdict itself).
/// Machine mode keeps the §D.1 row vocabulary byte-stable.
pub fn fetch_verdict_line(result: &gsa_fetch::verdict::FetchResult, human: bool) -> String {
    use gsa_fetch::verdict::{FetchVerdict, REASON_OK};
    if !human {
        return format!(
            "{} {} {} {}\n",
            result.pkg, result.verdict, result.dur, result.reason
        );
    }
    let what = match result.verdict {
        FetchVerdict::Ok => "fetched and verified",
        FetchVerdict::Failed => "failed",
        // The engine's skip note IS the message (one line per package).
        FetchVerdict::Skipped => return String::new(),
    };
    if result.reason == REASON_OK {
        format!("gsa-fetch: {}: {what} ({}s)\n", result.pkg, result.dur)
    } else {
        format!(
            "gsa-fetch: {}: {what} ({}, {}s)\n",
            result.pkg, result.reason, result.dur
        )
    }
}

/// The prose summary of a `-Sw` fetch-only run (§I.4): the verdict tally.
/// The verdict rows above it are the per-package surface; the run record
/// below is the machine rendering of the same outcomes.
pub fn render_fetch_prose(results: &[gsa_fetch::verdict::FetchResult]) -> String {
    use gsa_fetch::verdict::FetchVerdict;
    let fetched = results
        .iter()
        .filter(|r| r.verdict == FetchVerdict::Ok)
        .count();
    let failed = results
        .iter()
        .filter(|r| r.verdict == FetchVerdict::Failed)
        .count();
    let skipped = results
        .iter()
        .filter(|r| r.verdict == FetchVerdict::Skipped)
        .count();
    if output::is_human() {
        return format!(
            "Fetch run: {} package(s), {fetched} fetched, {failed} failed, {skipped} skipped\n",
            results.len()
        );
    }
    let level = if failed > 0 { Level::Warning } else { Level::Info };
    format!(
        "{}\n",
        kv_line(
            level,
            "fetch-run",
            &[
                ("packages", results.len().to_string()),
                ("fetched", fetched.to_string()),
                ("failed", failed.to_string()),
                ("skipped", skipped.to_string()),
            ],
        )
    )
}

/// The prose summary (contract §I.4: loud reporting — every failed package
/// with its log path, the full parked cone with each member's park reason
/// and the failure that parked it, every deferred package with its reason).
/// `parked_by` maps each parked package id to the package ids whose event
/// parked it (computed once from the same rows and topology, never here).
/// `qa` appends the install-time QA report surface's `report`-severity
/// findings (contract §E.4) — `None` when the run had no QA surface
/// (build-only and dry runs); the finding lines themselves are computed by
/// `gsa-qa` and never re-derived here.
pub fn render_run_prose(
    record: &RunRecord,
    log_dir: &Path,
    parked_by: &[(String, Vec<String>)],
    qa: Option<&[String]>,
) -> String {
    run_prose(record, log_dir, parked_by, qa, output::is_human())
}

/// The one prose summary in both vocabularies (`human` selects; the mode
/// itself is picked once by [`output::mode`]). Split from
/// [`render_run_prose`] so the human shape is testable without a TTY.
fn run_prose(
    record: &RunRecord,
    log_dir: &Path,
    parked_by: &[(String, Vec<String>)],
    qa: Option<&[String]>,
    human: bool,
) -> String {
    let mut out = String::new();
    let (lanes, normal, core) = match (record.lanes, record.normal_jobs, record.core_jobs) {
        (Some(l), Some(n), Some(c)) => (l.to_string(), n.to_string(), c.to_string()),
        _ => ("-".to_string(), "-".to_string(), "-".to_string()),
    };
    if human {
        // H3 (2026-10-28): the prose summary is the §I.4 loud reporting
        // alone. The lanes/jobs/intensity numbers are answered by the one
        // parallelism line at dispatch and the run record's scalars, the
        // outcome/rc by the record's scalars — restating them here was the
        // duplicated messaging the human report named. Sections are
        // separated by a blank line so a summary never packs against the
        // events above it or the machine record below it.
        out.push('\n');
        out.push_str(&format!("Build run: {} package(s)\n", record.order.len()));
        out.push('\n');
    } else {
        out.push_str(&kv_line(
            Level::Info,
            "build-run",
            &[
                ("packages", record.order.len().to_string()),
                ("lanes", lanes.clone()),
                ("normal-jobs", normal.clone()),
                ("core-jobs", core.clone()),
                ("intensity", squash(&record.intensity)),
            ],
        ));
        out.push('\n');
    }
    for row in &record.outcomes {
        let rc = row
            .rc
            .map(|rc| rc.to_string())
            .unwrap_or_else(|| "-".to_string());
        let log = log_dir
            .join(format!("{}.log", row.pkg))
            .display()
            .to_string();
        match row.status {
            RowStatus::Failed => {
                if human {
                    out.push_str(&format!(
                        "✗ failed: {} (rc {rc}, {}) — log: {log}\n",
                        row.pkg, row.reason
                    ));
                } else {
                    out.push_str(&kv_line(
                        Level::Warning,
                        "lane-outcome",
                        &[
                            ("pkg", row.pkg.to_string()),
                            ("status", "failed".to_string()),
                            ("rc", rc.clone()),
                            ("reason", squash(&row.reason)),
                            ("action", "inspect-log".to_string()),
                            ("log", log.clone()),
                        ],
                    ));
                    out.push('\n');
                }
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
                if human {
                    out.push_str(&format!(
                        "⚠ parked: {} ({}) — parked by {by}\n",
                        row.pkg, row.reason
                    ));
                } else {
                    out.push_str(&kv_line(
                        Level::Warning,
                        "lane-outcome",
                        &[
                            ("pkg", row.pkg.to_string()),
                            ("status", "parked".to_string()),
                            ("reason", squash(&row.reason)),
                            ("parked-by", squash(&by)),
                            ("action", "waits-on-failed".to_string()),
                        ],
                    ));
                    out.push('\n');
                }
            }
            RowStatus::Deferred => {
                if human {
                    out.push_str(&format!("⚠ deferred: {} ({})\n", row.pkg, row.reason));
                } else {
                    out.push_str(&kv_line(
                        Level::Warning,
                        "lane-outcome",
                        &[
                            ("pkg", row.pkg.to_string()),
                            ("status", "deferred".to_string()),
                            ("reason", squash(&row.reason)),
                            ("action", "revisit-deferral".to_string()),
                        ],
                    ));
                    out.push('\n');
                }
            }
            RowStatus::NeverStarted => {
                if human {
                    out.push_str(&format!("· never started: {} ({})\n", row.pkg, row.reason));
                } else {
                    out.push_str(&kv_line(
                        Level::Warning,
                        "lane-outcome",
                        &[
                            ("pkg", row.pkg.to_string()),
                            ("status", "never-started".to_string()),
                            ("reason", squash(&row.reason)),
                            ("action", "rerun".to_string()),
                        ],
                    ));
                    out.push('\n');
                }
            }
            RowStatus::Interrupted => {
                if human {
                    out.push_str(&format!(
                        "⚠ interrupted: {} (rc {rc}, {})\n",
                        row.pkg, row.reason
                    ));
                } else {
                    out.push_str(&kv_line(
                        Level::Warning,
                        "lane-outcome",
                        &[
                            ("pkg", row.pkg.to_string()),
                            ("status", "interrupted".to_string()),
                            ("rc", rc.clone()),
                            ("reason", squash(&row.reason)),
                            ("action", "rerun".to_string()),
                        ],
                    ));
                    out.push('\n');
                }
            }
            RowStatus::Succeeded => {
                if human {
                    out.push_str(&format!("✓ succeeded: {} ({})\n", row.pkg, row.reason));
                } else {
                    out.push_str(&kv_line(
                        Level::Info,
                        "lane-outcome",
                        &[
                            ("pkg", row.pkg.to_string()),
                            ("status", "succeeded".to_string()),
                            ("reason", squash(&row.reason)),
                        ],
                    ));
                    out.push('\n');
                }
            }
        }
    }
    // H3: the human summary stops here — the run record block below carries
    // the `outcome:`/`rc:` scalars (restating them in prose was the
    // duplicated messaging the human report named). The machine stream
    // keeps its `outcome` event: its grammar is pinned (§L.6).
    if !human {
        let (level, action) = match record.outcome.to_string().as_str() {
            "success" | "planned" => (Level::Info, None),
            "deferral" => (Level::Warning, Some("revisit-deferrals")),
            "interrupted" => (Level::Warning, Some("rerun")),
            _ => (Level::Error, Some("inspect-logs")),
        };
        let mut pairs = vec![
            ("status", squash(&record.outcome.to_string())),
            ("rc", record.rc.to_string()),
        ];
        if let Some(action) = action {
            pairs.push(("action", action.to_string()));
        }
        out.push_str(&kv_line(level, "outcome", &pairs));
        out.push('\n');
    }
    // The QA report surface (contract §E.4): report-severity findings
    // appended to the prose summary — additive, prose-only (the §H.2
    // choice recorded in `gsa-qa::report`), never a decision and never a
    // machine row.
    if let Some(findings) = qa {
        if human {
            // Blank-line separation (H3): the QA span is its own section.
            out.push('\n');
            if findings.is_empty() {
                out.push_str("QA report (report-only): clean\n");
            } else {
                out.push_str(&format!(
                    "QA report (report-only): {} finding(s)\n",
                    findings.len()
                ));
                for line in findings {
                    out.push_str(&format!("· {line}\n"));
                }
            }
        } else {
            out.push_str(&kv_line(
                Level::Info,
                "qa-report",
                &[
                    ("mode", "report-only".to_string()),
                    ("findings", findings.len().to_string()),
                ],
            ));
            out.push('\n');
            for line in findings {
                out.push_str(&kv_line(
                    Level::Info,
                    "qa-finding",
                    &[("detail", squash(line))],
                ));
                out.push('\n');
            }
        }
    }
    if human {
        // Trailing blank line (H3): the run record block (or the next run's
        // output) never packs against this summary.
        out.push('\n');
    }
    out
}

#[cfg(test)]
mod tests {
    use gsa_model::OutcomeRow;

    use super::*;

    fn row(pkg: &str, status: RowStatus, rc: Option<i32>, dur: Option<i64>, reason: &str) -> OutcomeRow {
        OutcomeRow {
            pkg: RecipeId::new(pkg).unwrap(),
            status,
            rc,
            dur,
            reason: reason.to_string(),
        }
    }

    fn pkg(index: usize) -> String {
        format!("p{index}")
    }

    /// The machine grammar (§L.6 `LEVEL event k=v`) pins EVERY streaming
    /// event exactly — this is the catalog's machine half, byte-stable so a
    /// consumer can parse it. Each line is newline-terminated ONCE.
    #[test]
    fn every_event_has_a_pinned_machine_line() {
        let cases: Vec<(SupEvent, &str)> = vec![
            (
                SupEvent::Started {
                    index: 0,
                    jobs: 2,
                    core: false,
                },
                "INFO lane-start pkg=p0 core=0 jobs=2\n",
            ),
            (
                SupEvent::Started {
                    index: 1,
                    jobs: 4,
                    core: true,
                },
                "INFO lane-start pkg=p1 core=1 jobs=4\n",
            ),
            (
                SupEvent::Finished {
                    index: 0,
                    row: row("vtk", RowStatus::Succeeded, Some(0), Some(12), "ok"),
                },
                "INFO lane-done pkg=vtk status=succeeded rc=0 dur=12 reason=ok\n",
            ),
            (
                SupEvent::Finished {
                    index: 0,
                    row: row("vtk", RowStatus::Failed, Some(1), Some(3), "build-failed"),
                },
                "WARNING lane-failed pkg=vtk status=failed rc=1 dur=3 reason=build-failed action=inspect-log\n",
            ),
            (
                SupEvent::Finished {
                    index: 0,
                    row: row("vtk", RowStatus::Parked, None, None, "waits-on-failed"),
                },
                "WARNING lane-parked pkg=vtk status=parked rc=- dur=- reason=waits-on-failed action=waits-on-failed\n",
            ),
            (
                SupEvent::Finished {
                    index: 0,
                    row: row("vtk", RowStatus::Deferred, None, None, "source-unfetchable"),
                },
                "WARNING lane-deferred pkg=vtk status=deferred rc=- dur=- reason=source-unfetchable action=revisit-deferral\n",
            ),
            (
                SupEvent::Finished {
                    index: 0,
                    row: row("vtk", RowStatus::NeverStarted, None, None, "interrupted-before-start"),
                },
                "WARNING lane-never-started pkg=vtk status=never-started rc=- dur=- reason=interrupted-before-start action=rerun\n",
            ),
            (
                SupEvent::Finished {
                    index: 0,
                    row: row("vtk", RowStatus::Interrupted, Some(130), Some(7), "interrupted-mid-build"),
                },
                "WARNING lane-interrupted pkg=vtk status=interrupted rc=130 dur=7 reason=interrupted-mid-build action=rerun\n",
            ),
            (
                SupEvent::Parked {
                    index: 0,
                    reason: "waits-on-failed".to_string(),
                },
                "WARNING lane-parked pkg=p0 reason=waits-on-failed action=waits-on-failed\n",
            ),
            (SupEvent::Signal(2), "WARNING signal sig=2\n"),
            (
                SupEvent::Teardown("one SIGTERM per lane, shared grace window"),
                "WARNING teardown reason=one_SIGTERM_per_lane,_shared_grace_window action=wait-for-drain\n",
            ),
            (
                SupEvent::Diagnostic("case-variant match: 'OKP' -> 'okp'".to_string()),
                "INFO note msg=case-variant_match:_'OKP'_->_'okp'\n",
            ),
            (
                SupEvent::PrefetchWarning("prefetch p2: fetch-failed".to_string()),
                "WARNING prefetch-warning msg=prefetch_p2:_fetch-failed\n",
            ),
        ];
        for (event, want) in cases {
            let got = render_event_machine(&event, &pkg);
            assert_eq!(got, want, "machine rendering of {event:?}");
            assert!(
                got.ends_with('\n') && !got.ends_with("\n\n"),
                "one trailing newline, got {got:?}"
            );
        }
        // The view heartbeat is not a message: it renders EMPTY (no line to
        // terminate) so a machine stream gains nothing per tick.
        assert_eq!(render_event_machine(&SupEvent::Tick, &pkg), "");
    }

    /// The human half of the catalog: every event renders in the readable
    /// default vocabulary (the TTY surface the dashboard draws from).
    #[test]
    fn every_event_has_a_pinned_human_line() {
        let cases: Vec<(SupEvent, &str)> = vec![
            (
                SupEvent::Started {
                    index: 0,
                    jobs: 2,
                    core: false,
                },
                "→ started p0 -j2\n",
            ),
            (
                SupEvent::Started {
                    index: 1,
                    jobs: 4,
                    core: true,
                },
                "→ started p1 (core) -j4\n",
            ),
            (
                SupEvent::Finished {
                    index: 0,
                    row: row("vtk", RowStatus::Succeeded, Some(0), Some(12), "ok"),
                },
                "✓ vtk (12s)\n",
            ),
            (
                SupEvent::Finished {
                    index: 0,
                    row: row("vtk", RowStatus::Succeeded, None, Some(125), "ok"),
                },
                "✓ vtk (2m05s)\n",
            ),
            (
                SupEvent::Finished {
                    index: 0,
                    row: row("vtk", RowStatus::Failed, Some(1), Some(3), "build-failed"),
                },
                "✗ vtk: BUILD FAILED (rc 1, 3s, build-failed) — see the run's failed rows for the log\n",
            ),
            (
                SupEvent::Finished {
                    index: 0,
                    row: row("vtk", RowStatus::Parked, None, None, "waits-on-failed"),
                },
                "⚠ vtk: parked (waits-on-failed)\n",
            ),
            (
                SupEvent::Finished {
                    index: 0,
                    row: row("vtk", RowStatus::Deferred, None, None, "source-unfetchable"),
                },
                "⚠ vtk: DEFERRED (source-unfetchable)\n",
            ),
            (
                SupEvent::Finished {
                    index: 0,
                    row: row("vtk", RowStatus::NeverStarted, None, None, "interrupted-before-start"),
                },
                "· vtk: never started (interrupted-before-start)\n",
            ),
            (
                SupEvent::Finished {
                    index: 0,
                    row: row("vtk", RowStatus::Interrupted, Some(130), Some(7), "interrupted-mid-build"),
                },
                "⚠ vtk: interrupted (rc 130, 7s, interrupted-mid-build)\n",
            ),
            (
                SupEvent::Parked {
                    index: 0,
                    reason: "waits-on-failed".to_string(),
                },
                "⚠ p0: parked (waits-on-failed)\n",
            ),
            (
                SupEvent::Signal(2),
                "⚠ signal received (2) — the run is winding down\n",
            ),
            (
                SupEvent::Teardown("one SIGTERM per lane, shared grace window"),
                "⚠ teardown: one SIGTERM per lane, shared grace window\n",
            ),
            (
                SupEvent::Diagnostic("case-variant match: 'OKP' -> 'okp'".to_string()),
                "· case-variant match: 'OKP' -> 'okp'\n",
            ),
            (
                SupEvent::PrefetchWarning("prefetch p2: fetch-failed".to_string()),
                "⚠ prefetch p2: fetch-failed\n",
            ),
        ];
        for (event, want) in cases {
            let got = render_event_human(&event, &pkg);
            assert_eq!(got, want, "human rendering of {event:?}");
            assert!(
                got.ends_with('\n') && !got.ends_with("\n\n"),
                "one trailing newline, got {got:?}"
            );
        }
        // The view heartbeat is not a message here either (the TTY
        // dashboard consumes it directly).
        assert_eq!(render_event_human(&SupEvent::Tick, &pkg), "");
    }

    fn prose_record() -> RunRecord {
        RunRecord {
            selection_source: "sets=umbriel-git leaf=no range=-".to_string(),
            order: vec![RecipeId::new("umbriel-git").unwrap()],
            lanes: Some(1),
            normal_jobs: Some(7),
            core_jobs: Some(4),
            intensity: "xhigh".to_string(),
            outcome: "interrupted".to_string(),
            rc: 130,
            dry_run: false,
            prefetch_warnings: None,
            plan: Vec::new(),
            outcomes: vec![row(
                "umbriel-git",
                RowStatus::Interrupted,
                Some(143),
                Some(2),
                "interrupted-mid-build",
            )],
            continuation: gsa_model::Continuation {
                command: "gsa -S umbriel-git".to_string(),
                remaining: vec![RecipeId::new("umbriel-git").unwrap()],
                not_mirrored: Vec::new(),
                env_required: Vec::new(),
            },
        }
    }

    /// H3 (2026-10-28) — the human summary carries the §I.4 loud reporting
    /// alone: the lanes/jobs/intensity/outcome scalars the parallelism line
    /// and the run record already answer are gone, and sections are
    /// separated by blank lines so nothing packs together. Byte-pinned: the
    /// human surface is a shape fixtures cannot see (a capture is machine
    /// mode), so this test is its pin.
    #[test]
    fn human_prose_dedupes_and_separates_sections() {
        let log_dir = std::path::Path::new("/var/lib/gsa/logs");
        let out = run_prose(&prose_record(), log_dir, &[], None, true);
        assert_eq!(
            out,
            "\nBuild run: 1 package(s)\n\n\
             ⚠ interrupted: umbriel-git (rc 143, interrupted-mid-build)\n\n"
        );
        // The QA report surface is its own section (§E.4).
        let out = run_prose(&prose_record(), log_dir, &[], Some(&[]), true);
        assert_eq!(
            out,
            "\nBuild run: 1 package(s)\n\n\
             ⚠ interrupted: umbriel-git (rc 143, interrupted-mid-build)\n\n\
             QA report (report-only): clean\n\n"
        );
    }

    /// The machine stream is NOT deduped (its grammar is pinned, §L.6) —
    /// guard the exact `build-run`/`outcome` events through the split.
    #[test]
    fn machine_prose_keeps_its_pinned_events() {
        let out = run_prose(
            &prose_record(),
            std::path::Path::new("/var/lib/gsa/logs"),
            &[],
            None,
            false,
        );
        assert!(out.contains(
            "INFO build-run packages=1 lanes=1 normal-jobs=7 core-jobs=4 intensity=xhigh\n"
        ));
        assert!(out.contains("WARNING outcome status=interrupted rc=130 action=rerun\n"));
    }

    /// H6 (2026-10-28): the per-package fetch message — the human surface
    /// speaks the fetch voice (a skip stays the engine note's single line,
    /// never doubled here), the machine surface keeps the §D.1 verdict row
    /// byte-stable.
    #[test]
    fn fetch_verdict_lines_are_per_action_prose_and_stable_rows() {
        use gsa_fetch::verdict::{FetchResult, FetchVerdict, REASON_OK, REASON_VCS_ONLY};
        let ok = FetchResult::new("mesa-git", FetchVerdict::Ok, 3, REASON_OK).unwrap();
        assert_eq!(
            fetch_verdict_line(&ok, true),
            "gsa-fetch: mesa-git: fetched and verified (3s)\n"
        );
        assert_eq!(fetch_verdict_line(&ok, false), "mesa-git ok 3 ok\n");
        let retry = FetchResult::new("mesa-git", FetchVerdict::Ok, 5, "retry-ok").unwrap();
        assert_eq!(
            fetch_verdict_line(&retry, true),
            "gsa-fetch: mesa-git: fetched and verified (retry-ok, 5s)\n"
        );
        let failed = FetchResult::new("mesa-git", FetchVerdict::Failed, 7, "fetch-failed").unwrap();
        assert_eq!(
            fetch_verdict_line(&failed, true),
            "gsa-fetch: mesa-git: failed (fetch-failed, 7s)\n"
        );
        assert_eq!(
            fetch_verdict_line(&failed, false),
            "mesa-git failed 7 fetch-failed\n"
        );
        let skip = FetchResult::new("mesa-git", FetchVerdict::Skipped, 0, REASON_VCS_ONLY).unwrap();
        assert_eq!(fetch_verdict_line(&skip, true), "");
        assert_eq!(fetch_verdict_line(&skip, false), "mesa-git skipped 0 vcs-only\n");
    }
}
