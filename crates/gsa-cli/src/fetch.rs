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
use crate::select::{self, Ctx};
use crate::{record, render};

/// `gsa -Sw` — fetch and verify the selection's sources. Returns the
/// process exit code (§G.1: from the verdict rows, `failed` rows included)
/// and writes every rendering through `out`/`err`.
pub fn run_fetch_only(inv: &Invocation, out: &mut dyn Write, err: &mut dyn Write) -> i32 {
    // ── selection is mandatory (contract §B.1) ───────────────────────────
    if inv.targets.is_empty() {
        let _ = writeln!(
            err,
            "gsa: selection is mandatory: a fetch never starts without a selection"
        );
        return 2;
    }
    // ── workspace, topology, selection (usage class: rc 2) ────────────────
    let root = match crate::find_root() {
        Some(root) => root,
        None => {
            let _ = writeln!(
                err,
                "gsa: cannot find config/topology.conf from the current directory upward (run inside the recipe repository)"
            );
            return 2;
        }
    };
    let project = match load_project(&root) {
        Ok(project) => project,
        Err(error) => {
            let _ = writeln!(err, "gsa: {error}");
            return 2;
        }
    };
    let graph = match Graph::build(&project.topology.records) {
        Ok(graph) => graph,
        Err(error) => {
            let _ = writeln!(err, "gsa: config/topology.conf: {error}");
            return 2;
        }
    };
    let db = match RecipeDb::load(&root, graph.records()) {
        Ok(db) => db,
        Err(error) => {
            let _ = writeln!(err, "gsa: {error}");
            return 2;
        }
    };
    let ctx = Ctx {
        project: &project,
        graph: &graph,
        db: &db,
    };
    let selection = match select::build_selection(&ctx, &inv.targets, &inv.ranges, inv.leaf) {
        Ok(selection) => selection,
        Err(error) => {
            let _ = writeln!(err, "gsa: {}", error.message);
            return 2;
        }
    };
    crate::write_notes(err, &selection.notes);

    // ── plan rows: `fetch` for candidates, `skip <reason>` for the rest ──
    // Candidacy is the gsa-recipe source classification (owner decision 3:
    // never grep), decided before anything fetches — so a pure-VCS recipe
    // is planned `skip vcs-only` and a recipe with nothing to fetch
    // `skip not-a-candidate`.
    let mut plan: Vec<PlanRow> = Vec::new();
    for (_, id) in &selection.listed {
        let skip = db
            .get(id.as_str())
            .map(|meta| classify_skip(&meta))
            .unwrap_or(Some("not-a-candidate".to_string()));
        let (action, reason) = match skip {
            Some(reason) => (PlanAction::Skip, reason),
            None => (PlanAction::Fetch, "ok".to_string()),
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
        let _ = write!(out, "{}", record.render_machine());
        return outcome.rc;
    }

    // ── the fetches, one verdict row per package in plan order ───────────
    let mut results: Vec<FetchResult> = Vec::new();
    for (_, id) in &selection.listed {
        let result = gsa_fetch::engine::fetch_recipe(id.as_str(), &root, err);
        let _ = writeln!(
            out,
            "{} {} {} {}",
            result.pkg, result.verdict, result.dur, result.reason
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
    let _ = write!(out, "{}", record.render_machine());
    outcome.rc
}

/// The non-candidate skip reason of one recipe (`vcs-only`,
/// `not-a-candidate`), `None` when fetch-ahead may fetch it (owner decision
/// 3). A recipe whose metadata is missing is a skip, loudly honest rather
/// than a fetch attempt that would fail at eval.
fn classify_skip(meta: &gsa_recipe::RecipeMeta) -> Option<String> {
    let candidacy = gsa_fetch::candidacy::classify(meta);
    match &candidacy {
        FetchCandidacy::Plain(_) => None,
        FetchCandidacy::VcsOnly => Some(verdict::REASON_VCS_ONLY.to_string()),
        FetchCandidacy::NoFetchable => Some(verdict::REASON_NOT_A_CANDIDATE.to_string()),
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
