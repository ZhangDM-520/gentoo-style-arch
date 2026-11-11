//! `gsa -Sw <targets…> [ranges…]` — the fetch-only run (contract §B.4,
//! docs/adr/0004-prefetch-advisory.md): fetch and verify the selection's
//! sources through `gsa-fetch`'s `makepkg --verifysource` pipeline and
//! nothing else — no build, no install, no pacman call, no sudo. The
//! verdict rows on stdout carry their OWN vocabulary (§D.1:
//! `<pkg> <verdict> <dur> <reason…>`, `ok|failed|skipped` + kebab reason),
//! and the §H run record renders the same outcomes
//! (`record::build_fetch_record`). A fetch verdict is advisory for builds —
//! the run's own rc still follows §G.1 from its rows.

use std::io::Write;

use gsa_fetch::candidacy::FetchCandidacy;
use gsa_fetch::verdict::{self, FetchResult, FetchVerdict};
use gsa_graph::Graph;
use gsa_model::{OutcomeRow, PlanAction, PlanRow, RecipeId, RowStatus, RunOutcome};
use gsa_recipe::RecipeDb;
use gsa_topo::load_project;

use crate::args::Invocation;
use crate::exit::{self, Exit};
use crate::select::{self, Ctx};
use crate::{record, render};

/// `gsa -Sw` — fetch and verify the selection's sources. Returns the
/// process exit code (§G.1: from the verdict rows, `failed` rows included)
/// and writes every rendering through `out`/`err`.
pub fn run_fetch_only(inv: &Invocation, out: &mut dyn Write, err: &mut dyn Write) -> i32 {
    exit::render(run_fetch_only_inner(inv, out, err), err)
}

fn run_fetch_only_inner(
    inv: &Invocation,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<i32, Exit> {
    // ── selection is mandatory (contract §B.1) ───────────────────────────
    if inv.targets.is_empty() {
        return Err(Exit::usage(
            "selection is mandatory: a fetch never starts without a selection",
        ));
    }
    // ── workspace, topology, selection (usage class: rc 2) ────────────────
    let root = crate::resolve_workspace(inv, err)?;
    let project = load_project(&root).map_err(|error| Exit::Usage(error.to_string()))?;
    let graph = Graph::build(&project.topology.records)
        .map_err(|error| Exit::Usage(format!("config/topology.conf: {error}")))?;
    let db =
        RecipeDb::load(&root, graph.records()).map_err(|error| Exit::Usage(error.to_string()))?;
    let ctx = Ctx {
        project: &project,
        graph: &graph,
        db: &db,
        user_sets: select::load_user_sets(inv),
    };
    let selection = select::build_selection(&ctx, &inv.targets, &inv.ranges, inv.leaf)
        .map_err(|error| error.into_exit())?;
    crate::write_notes(err, &selection.notes);

    // ── privilege gate (contract §B.10; after every usage preflight) ─────
    if let Some(exit) = crate::privilege_gate(
        &inv.spelling(),
        crate::invocation_privilege(inv, &crate::Command::Fetch),
        true,
        err,
    ) {
        return Err(exit);
    }

    // ── plan rows: `fetch` for candidates, `skip <reason>` for the rest ──
    // Candidacy is the gsa-recipe source classification (owner decision 3:
    // never grep), decided before anything fetches — so a pure-VCS recipe
    // is planned `skip vcs-only` and a recipe with nothing to fetch
    // `skip not-a-candidate`.
    let mut plan: Vec<PlanRow> = Vec::new();
    for (_, id) in &selection.listed {
        let recipe_dir = graph
            .index_of(id.as_str())
            .map(|idx| root.join(&graph.record(idx).path))
            .unwrap_or_else(|| root.clone());
        let (action, reason) = match db.get(id.as_str()) {
            Some(meta) => plan_row_for(&meta, &recipe_dir),
            // No metadata: nothing can be fetched, and the engine will say
            // why (`eval-failed`) — the plan names the same class.
            None => (PlanAction::Skip, "not-a-candidate".to_string()),
        };
        plan.push(PlanRow {
            pkg: id.clone(),
            action,
            reason,
        });
    }

    if inv.dry_run {
        // `--dry-run` (§B.8): plan rows and nothing else — never fetches,
        // never mutates. Outcomes are `never-started dry-run` (additive
        // reason key, §H.2) and the continuation reissues the real run.
        let outcomes: Vec<OutcomeRow> = selection
            .listed
            .iter()
            .map(|(_, id)| OutcomeRow {
                pkg: id.clone(),
                status: RowStatus::NeverStarted,
                rc: None,
                dur: None,
                reason: "dry-run".to_string(),
            })
            .collect();
        let outcome = RunOutcome {
            outcome: "planned",
            rc: 0,
        };
        let record = record::build_fetch_record(
            inv,
            &selection,
            &inv.targets,
            &inv.ranges,
            plan,
            outcomes,
            &outcome,
        );
        let _ = writeln!(
            out,
            "Fetch run (dry run): {} package(s) — nothing fetched",
            selection.listed.len()
        );
        // A dry-run record mutates nothing: emit renders it, never stores it.
        let rec_state = crate::install::record_state_dir(inv, err);
        record::emit_machine_record(out, &record, &rec_state, err);
        return Ok(outcome.rc);
    }

    // ── the fetches, one verdict row per package in plan order ───────────
    let mut results: Vec<FetchResult> = Vec::new();
    for (_, id) in &selection.listed {
        let result = gsa_fetch::engine::fetch_recipe(id.as_str(), &root, err);
        // H6: the per-package message — the fetch voice on the human
        // surface, the §D.1 verdict row (byte-stable) in machine mode.
        let _ = write!(
            out,
            "{}",
            render::fetch_verdict_line(&result, crate::output::is_human())
        );
        if verdict::is_warning(result.verdict, &result.reason) {
            let _ = writeln!(
                err,
                "gsa: warning: fetch {}: {} {} — advisory; a later build re-fetches",
                result.pkg, result.verdict, result.reason
            );
        }
        results.push(result);
    }
    let outcomes: Vec<OutcomeRow> = selection
        .listed
        .iter()
        .zip(&results)
        .map(|((_, id), result)| verdict_row(id, result))
        .collect();
    // §G.1 from the rows: a `failed` fetch row is a run failure (the
    // advisory rule governs BUILD runs — a fetch run's rows ARE its work).
    let outcome = RunOutcome::compute(&outcomes, false, false, false);
    let record = record::build_fetch_record(
        inv,
        &selection,
        &inv.targets,
        &inv.ranges,
        plan,
        outcomes,
        &outcome,
    );
    let _ = write!(out, "{}", render::render_fetch_prose(&results));
    let rec_state = crate::install::record_state_dir(inv, err);
    record::emit_machine_record(out, &record, &rec_state, err);
    Ok(outcome.rc)
}

/// The plan row of one recipe: `skip <reason>` for a non-candidate
/// (`vcs-only`, `not-a-candidate`), `fetch ok` for a candidate, and
/// `fetch local-source-missing` when a declared local source is absent —
/// that recipe IS attempted, and the attempt fails with the same reason, so
/// the plan foreshadows the outcome instead of promising a clean fetch
/// (blind-review 2026-11-11, airgapped-admin). A recipe whose metadata is
/// missing is a skip, loudly honest rather than a fetch attempt that would
/// fail at eval.
fn plan_row_for(
    meta: &gsa_recipe::RecipeMeta,
    recipe_dir: &std::path::Path,
) -> (PlanAction, String) {
    if !meta.missing_local_sources(recipe_dir).is_empty() {
        return (
            PlanAction::Fetch,
            verdict::REASON_LOCAL_SOURCE_MISSING.to_string(),
        );
    }
    let candidacy = gsa_fetch::candidacy::classify(meta);
    match &candidacy {
        FetchCandidacy::Plain(_) => (PlanAction::Fetch, "ok".to_string()),
        FetchCandidacy::VcsOnly => (PlanAction::Skip, verdict::REASON_VCS_ONLY.to_string()),
        FetchCandidacy::NoFetchable => (
            PlanAction::Skip,
            verdict::REASON_NOT_A_CANDIDATE.to_string(),
        ),
    }
}

/// The §H outcome row of one fetch verdict (record.rs's documented
/// mapping): `ok` → `succeeded`, `failed` → `failed`, `skipped` →
/// `succeeded` with its skip reason (so `remaining:` never re-fetches one).
/// A skipped fetch produced no process code — `rc`/`dur` are `-` (§H.2).
fn verdict_row(id: &RecipeId, result: &FetchResult) -> OutcomeRow {
    let (status, rc, dur) = match result.verdict {
        FetchVerdict::Ok => (RowStatus::Succeeded, Some(0), Some(result.dur as i64)),
        FetchVerdict::Failed => (RowStatus::Failed, Some(1), Some(result.dur as i64)),
        FetchVerdict::Skipped => (RowStatus::Succeeded, None, None),
    };
    OutcomeRow {
        pkg: id.clone(),
        status,
        rc,
        dur,
        reason: result.reason.clone(),
    }
}
