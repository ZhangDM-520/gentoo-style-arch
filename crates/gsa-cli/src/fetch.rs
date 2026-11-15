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
use crate::exit::{self, Exit, Refusal, RefusalClass};
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
    // `--toolchain` is a fetch input (I1-ren-2): `--verifysource` is given the
    // engine-owned makepkg composite, and the family picks WHICH composite, so
    // a fetch must pin the same override the following build will — otherwise
    // the two runs fetch and build under different configurations.
    crate::build::pin_toolchain(inv)?;
    // ── read-only probe + usage preflight, then the gate (§B.10, §G.1) ───
    // A host with no workspace yet preflights nothing, so the gate answers
    // rc 3 instead of an unprivileged state write (round-2 audit,
    // F-R2-C-01).
    let mut preflight: Option<select::Selection> = None;
    let probe = match &inv.standalone_root {
        Some(root) => Ok(root.clone()),
        None => crate::resolve_root(false, inv.state_dir.as_deref()),
    };
    match probe {
        Ok(root) => {
            let project = load_project(&root).map_err(|error| Exit::Usage(error.to_string()))?;
            let graph = Graph::build(&project.topology.records)
                .map_err(|error| Exit::Usage(format!("config/topology.conf: {error}")))?;
            let db = RecipeDb::load(&root, graph.records())
                .map_err(|error| Exit::Usage(error.to_string()))?;
            let ctx = Ctx {
                project: &project,
                graph: &graph,
                db: &db,
                user_sets: select::load_user_sets(inv).map_err(select::user_sets_exit)?,
            };
            let resolved = select::build_selection(&ctx, &inv.targets, &inv.ranges, inv.leaf)
                .map_err(|error| error.into_exit())?;
            crate::write_notes(err, &resolved.notes);
            preflight = Some(resolved);
        }
        Err(crate::RootFailure::Usage(message)) => return Err(Exit::Usage(message)),
        Err(crate::RootFailure::NotFound(_) | crate::RootFailure::NeedsRoot) => {}
    }
    // ── privilege gate (contract §B.10; after every usage preflight) ─────
    if let Some(exit) = crate::privilege_gate(
        &inv.spelling(),
        crate::invocation_privilege(inv, &crate::Command::Fetch),
        true,
        err,
    ) {
        return Err(exit);
    }

    // ── the run's workspace: a mutating run may fetch the store ──────────
    let root = crate::resolve_workspace_for_run(inv, err)?;
    let project = load_project(&root).map_err(|error| Exit::Usage(error.to_string()))?;
    let graph = Graph::build(&project.topology.records)
        .map_err(|error| Exit::Usage(format!("config/topology.conf: {error}")))?;
    let db =
        RecipeDb::load(&root, graph.records()).map_err(|error| Exit::Usage(error.to_string()))?;
    let ctx = Ctx {
        project: &project,
        graph: &graph,
        db: &db,
        user_sets: select::load_user_sets(inv).map_err(select::user_sets_exit)?,
    };
    let mut selection = match preflight {
        Some(selection) => selection,
        None => {
            let resolved = select::build_selection(&ctx, &inv.targets, &inv.ranges, inv.leaf)
                .map_err(|error| error.into_exit())?;
            crate::write_notes(err, &resolved.notes);
            resolved
        }
    };
    // ── missing build-order prerequisites (contract §C.3) ────────────────
    // Fetch is the "before you disconnect" verb: a build run expands to the
    // prerequisites the system lacks and then needs THEIR sources, so fetching
    // only the named targets left the run to discover a missing source later
    // with no network (external review, 2026-11-12). The same seam decides and
    // the same note announces it; `--leaf` stays exact.
    if let Err(message) =
        crate::prepare::apply_missing_prerequisites(&mut selection, &graph, &db, inv, err)
    {
        // An unreadable installed DB cannot answer "what is missing", and
        // guessing would fetch a set the build will not reproduce.
        return Err(Exit::Refuse(Refusal::noted(
            RefusalClass::StartupRefused,
            vec![format!("gsa: {message}")],
        )));
    }

    // ── plan rows: `fetch` for candidates, `skip <reason>` for the rest ──
    // Candidacy is the gsa-recipe source classification (owner decision 3:
    // never grep), decided before anything fetches — so a pure-VCS recipe
    // is planned `skip vcs-only` and a recipe with nothing to fetch
    // `skip not-a-candidate`. The disk floor is the ONE complication the
    // plan can know before fetching, and it is decided by the same seam the
    // fetch uses, so a plan can never promise a fetch the run will refuse
    // (R2-juno-6: `plan tcl fetch ok` for a package the same run reported as
    // `skipped disk-floor`).
    let cache = gsa_fetch::engine::resolve_srcdest();
    let mut plan: Vec<PlanRow> = Vec::new();
    for (_, id) in &selection.listed {
        let recipe_dir = graph
            .index_of(id.as_str())
            .map(|idx| root.join(&graph.record(idx).path))
            .unwrap_or_else(|| root.clone());
        let floor_paused =
            gsa_fetch::engine::floor_pause_for(cache.as_deref(), &recipe_dir).is_some();
        let (action, reason) = match db.get(id.as_str()) {
            Some(meta) => plan_row_for(&meta, &recipe_dir, floor_paused),
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
            // A fetch run's rows ARE its work (a build run's fetch-ahead is
            // the advisory one, docs/adr/0004-prefetch-advisory.md), so the
            // line must not call this verdict advisory while the same run
            // exits non-zero on it — R2-juno-5 read the contradiction as
            // "either it is advisory and the rc should say so, or the word
            // should go". The word goes; what a later build does is stated
            // as fact instead.
            let _ = writeln!(
                err,
                "gsa: warning: fetch {}: {} {} — a later build retries the fetch",
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
    let named: Vec<RecipeId> = selection
        .listed
        .iter()
        .map(|(_, id)| id.clone())
        .filter(|id| !selection.prerequisites_added.contains(id))
        .collect();
    let _ = write!(
        out,
        "{}",
        render::render_fetch_prose_with(
            &results,
            &selection.prerequisites_added,
            &named,
            crate::output::is_human(),
        )
    );
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
///
/// A plan row states the intended action and the complications it ALREADY
/// knows, never the outcome: a candidate that then fails is `fetch ok` in
/// the plan and `failed` in the outcome. The one complication knowable up
/// front is the disk floor, and naming it is what keeps the plan from
/// promising 34 fetches on a filesystem that will refuse them (R2-juno-6).
fn plan_row_for(
    meta: &gsa_recipe::RecipeMeta,
    recipe_dir: &std::path::Path,
    floor_paused: bool,
) -> (PlanAction, String) {
    if !meta.missing_local_sources(recipe_dir).is_empty() {
        return (
            PlanAction::Fetch,
            verdict::REASON_LOCAL_SOURCE_MISSING.to_string(),
        );
    }
    let candidacy = gsa_fetch::candidacy::classify(meta);
    match &candidacy {
        FetchCandidacy::Plain(_) if floor_paused => {
            (PlanAction::Skip, verdict::REASON_DISK_FLOOR.to_string())
        }
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
/// `succeeded` with its skip reason *only when the skip is routine*
/// (`vcs-only`, `not-a-candidate`: nothing was to be fetched, so
/// `remaining:` must never re-fetch it). A skip the RUN imposed —
/// `disk-floor` — is a `deferred` row instead: the fetch never happened, so
/// a `succeeded` would claim an action the floor prevented, and the deferral
/// is what puts it back in the continuation (R2-juno-6: `tcl succeeded - -
/// disk-floor` read as a completed fetch). A skipped/deferred fetch produced
/// no process code — `rc`/`dur` are `-` (§H.2).
fn verdict_row(id: &RecipeId, result: &FetchResult) -> OutcomeRow {
    let (status, rc, dur) = match result.verdict {
        FetchVerdict::Ok => (RowStatus::Succeeded, Some(0), Some(result.dur as i64)),
        FetchVerdict::Failed => (RowStatus::Failed, Some(1), Some(result.dur as i64)),
        FetchVerdict::Skipped if verdict::is_routine_skip(&result.reason) => {
            (RowStatus::Succeeded, None, None)
        }
        FetchVerdict::Skipped => (RowStatus::Deferred, None, None),
    };
    OutcomeRow {
        pkg: id.clone(),
        status,
        rc,
        dur,
        reason: result.reason.clone(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gsa_fetch::verdict::{REASON_DISK_FLOOR, REASON_NOT_A_CANDIDATE, REASON_VCS_ONLY};

    fn row(pkg: &str, verdict: FetchVerdict, reason: &str) -> OutcomeRow {
        verdict_row(
            &RecipeId::new(pkg).expect("a literal id"),
            &FetchResult::new(pkg, verdict, 0, reason).expect("a literal reason"),
        )
    }

    /// R2-juno-6: the run record said `succeeded` for a fetch the disk floor
    /// stopped, so a script read "the sources are cached" from a package the
    /// same run reported as skipped. A skip the RUN imposed is a deferral;
    /// only a routine skip (nothing to fetch) is a success, because only that
    /// one must stay out of `remaining:`.
    #[test]
    fn a_paused_fetch_is_deferred_while_a_routine_skip_stays_succeeded() {
        let paused = row("tcl", FetchVerdict::Skipped, REASON_DISK_FLOOR);
        assert_eq!(paused.status, RowStatus::Deferred);
        assert_eq!(paused.reason, REASON_DISK_FLOOR);
        assert_eq!(paused.rc, None, "a paused fetch ran no process");
        assert_eq!(paused.dur, None, "a paused fetch has no duration");

        for reason in [REASON_VCS_ONLY, REASON_NOT_A_CANDIDATE] {
            let skipped = row("mesa-git", FetchVerdict::Skipped, reason);
            assert_eq!(
                skipped.status,
                RowStatus::Succeeded,
                "a routine skip ({reason}) must never re-fetch"
            );
        }
    }

    /// The run-level rc follows the same rows (§G.1): a deferral-only fetch
    /// run exits 5 and never claims success, which is what makes the record
    /// and the rc agree.
    #[test]
    fn a_deferral_only_fetch_run_exits_five() {
        let rows = vec![
            row("tcl", FetchVerdict::Skipped, REASON_DISK_FLOOR),
            row("tk", FetchVerdict::Skipped, REASON_DISK_FLOOR),
        ];
        let outcome = RunOutcome::compute(&rows, false, false, false);
        assert_eq!(outcome.outcome, "deferral");
        assert_eq!(outcome.rc, 5);
    }
}
