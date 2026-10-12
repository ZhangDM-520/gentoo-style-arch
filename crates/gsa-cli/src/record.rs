//! The dry-run run record: plan rows, outcome rows and the continuation,
//! built from one flag-rule table (contract §H).
//!
//! Phase 1 records are dry-run records: the plan section is the deliverable
//! (§B `--dry-run`), the outcome section records that nothing was dispatched
//! (`never-started dry-run` — an additive reason key, allowed without a
//! format bump), and the continuation restates the run to do for real.

use gsa_model::{Continuation, OutcomeRow, PlanAction, PlanRow, RecipeId, RowStatus, RunRecord};

use crate::args::{Family, Invocation};
use crate::select::Selection;

/// The engine environment input roster (`gsa --help` must print it).
/// `GSA_BUILD_JOBS` is engine output and deliberately absent.
pub const ENV_ROSTER: [&str; 8] = [
    "GSA_STATE_DIR",
    "GSA_LANES",
    "GSA_JOBS",
    "GSA_INTENSITY",
    "GSA_CPU_THREADS",
    "GSA_MEMORY_GIB",
    "GSA_TARGET_CPU",
    "GSA_VCS_SKIP_TOLERANCE",
];

/// The continuation flag-rule table's explicit not-mirrored list (§H.2):
/// prune strengths, one-shot actions, query/maintain verbs and hidden seams
/// are never replayed. Everything else a continuation may carry is mirrored
/// as an explicit flag (`--dry-run`, `--leaf`, `--skip`, `--skip-built`,
/// `--vcs-skip-tolerance`, `--no-sync`, `--allow-broken-rustc`, `--fail-fast`,
/// and the resolved `--lanes`/`--jobs`/`--intensity` values; the cluster
/// letter `c` is a prune strength and never mirrors, `f` mirrors).
pub const NOT_MIRRORED: &[&str] = &[
    "-Q",
    "-Ss",
    "-Si",
    "-Sl",
    "-Sg",
    "-Sw",
    "-Sy",
    "-Su",
    "-Ua",
    "-Mc",
    "-Mcc",
    "-Mccc",
    "-Ma",
    "-Md",
    "-Mi",
    "-Ml",
    "-Mm",
    "-Ms",
    "-Mw",
    "-Mh",
    "--install-decide",
    "--lane-job",
    "--fetch-job",
    "--stale-lock-check",
    "--local-db-check",
    "--install-register",
    "--qa-check",
];

/// Build the one run record for a `--dry-run` plan (contract §H).
pub fn build_plan_record(
    inv: &Invocation,
    selection: &Selection,
    targets: &[String],
    ranges: &[String],
    intensity: &str,
) -> RunRecord {
    let selection_source = selection_source(targets, inv.leaf, ranges);

    let plan_action = match inv.family {
        Family::B => PlanAction::Build,
        _ => PlanAction::BuildInstall,
    };
    let plan: Vec<PlanRow> = selection
        .listed
        .iter()
        .map(|(_, id)| PlanRow {
            pkg: id.clone(),
            action: plan_action,
            reason: "ok".to_string(),
        })
        .collect();
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

    // Restated invocation: family + action + mirrored modifiers (a prune
    // strength is never mirrored), the §H.2 flag values spelled explicitly,
    // then the remaining package ids (a dry run leaves everything remaining).
    let mut command = String::from("gsa ");
    command.push_str(inv.family.as_str());
    if let Some(action) = inv.action {
        command.push(action);
    }
    if inv.modifiers.contains(&'f') {
        command.push('f');
    }
    command.push_str(" --dry-run");
    command.push_str(if inv.leaf {
        " --leaf=yes"
    } else {
        " --leaf=no"
    });
    for (_, id) in &selection.listed {
        command.push(' ');
        command.push_str(id.as_str());
    }

    RunRecord {
        selection_source,
        order: selection.listed.iter().map(|(_, id)| id.clone()).collect(),
        // Lanes and job budgets are computed by the scheduler (gsa-sched,
        // later phase); a dry run dispatches nothing and does not predict a
        // plan ("never predict a plan — read the parallelism: line").
        lanes: None,
        normal_jobs: None,
        core_jobs: None,
        intensity: intensity.to_string(),
        outcome: "planned".to_string(),
        rc: 0,
        dry_run: true,
        plan,
        outcomes,
        continuation: Continuation {
            command,
            remaining: selection.listed.iter().map(|(_, id)| id.clone()).collect(),
            not_mirrored: NOT_MIRRORED.iter().map(|s| s.to_string()).collect(),
            env_required: env_required(inv),
        },
    }
}

/// Build the one run record for a real build run (contract §H): plan rows
/// from the selection, outcome rows as the dispatch machine settled them
/// (never re-derived here), and a continuation that restates the resume.
/// The same structure is rendered three ways by the caller (streaming
/// dashboard events during the run, prose summary, machine block).
pub fn build_run_record(
    inv: &Invocation,
    selection: &Selection,
    targets: &[String],
    ranges: &[String],
    budget: Option<&gsa_sched::budget::Budget>,
    outcomes: Vec<OutcomeRow>,
    outcome: &gsa_model::RunOutcome,
) -> RunRecord {
    let selection_source = selection_source(targets, inv.leaf, ranges);
    let plan: Vec<PlanRow> = selection
        .listed
        .iter()
        .map(|(_, id)| PlanRow {
            pkg: id.clone(),
            action: PlanAction::Build,
            reason: "ok".to_string(),
        })
        .collect();

    // Restated invocation (contract §H.2): family + action, mirrored flags
    // only — `--leaf`, `--fail-fast`, and the resolved `--lanes`/`--jobs`/
    // `--intensity` values. Prune strengths (`c`) and `--state-dir` are never
    // mirrored (the state root is an environment concern: `env-required`).
    let mut command = String::from("gsa ");
    command.push_str(inv.family.as_str());
    if let Some(action) = inv.action {
        command.push(action);
    }
    if inv.leaf {
        command.push_str(" --leaf");
    }
    if inv.fail_fast {
        command.push_str(" --fail-fast");
    }
    if let Some(budget) = budget {
        command.push_str(&format!(" --lanes {}", budget.lanes));
        command.push_str(&format!(" --jobs {}", budget.normal_jobs));
        command.push_str(&format!(" --intensity {}", budget.intensity));
    }

    // `remaining:` — every row not `succeeded`, in row order (§H.2).
    let remaining: Vec<RecipeId> = outcomes
        .iter()
        .filter(|row| row.status != RowStatus::Succeeded)
        .map(|row| row.pkg.clone())
        .collect();
    for id in &remaining {
        command.push(' ');
        command.push_str(id.as_str());
    }

    RunRecord {
        selection_source,
        order: selection.listed.iter().map(|(_, id)| id.clone()).collect(),
        lanes: budget.map(|b| b.lanes),
        normal_jobs: budget.map(|b| b.normal_jobs),
        core_jobs: budget.map(|b| b.core_jobs),
        intensity: budget
            .map(|b| b.intensity.to_string())
            .unwrap_or_else(|| "-".to_string()),
        outcome: outcome.outcome.to_string(),
        rc: outcome.rc,
        dry_run: false,
        plan,
        outcomes,
        continuation: Continuation {
            command,
            remaining,
            not_mirrored: NOT_MIRRORED.iter().map(|s| s.to_string()).collect(),
            env_required: env_required(inv),
        },
    }
}

/// The `selection-source:` scalar (contract §H.2).
fn selection_source(targets: &[String], leaf: bool, ranges: &[String]) -> String {
    format!(
        "sets={} leaf={} range={}",
        if targets.is_empty() {
            "-".to_string()
        } else {
            targets.join(",")
        },
        if leaf { "yes" } else { "no" },
        if ranges.is_empty() {
            "-".to_string()
        } else {
            ranges.join(",")
        }
    )
}

/// The continuation's `env-required:` list (contract §H.2: environment
/// inputs are warned about, never baked in) — the roster variables actually
/// set in the environment, plus `GSA_STATE_DIR` when the run relocated the
/// state root by flag (the resume needs the same root).
fn env_required(inv: &Invocation) -> Vec<String> {
    let mut env: Vec<String> = ENV_ROSTER
        .iter()
        .filter(|name| {
            std::env::var_os(name)
                .map(|v| !v.is_empty())
                .unwrap_or(false)
        })
        .map(|name| name.to_string())
        .collect();
    if inv.state_dir.is_some() && !env.iter().any(|n| n == "GSA_STATE_DIR") {
        env.push("GSA_STATE_DIR".to_string());
    }
    env
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::args::Family;
    use gsa_model::RecipeId;

    fn selection(n: usize) -> Selection {
        Selection {
            listed: (1..=n)
                .map(|i| (i, RecipeId::new(format!("pkg{i}")).unwrap()))
                .collect(),
            closure_size: n,
            seeds: vec![RecipeId::new("pkg1").unwrap()],
            notes: Vec::new(),
        }
    }

    #[test]
    fn dry_run_record_carries_plan_and_continuation() {
        let inv = Invocation {
            family: Family::S,
            action: None,
            modifiers: vec!['c'],
            dry_run: true,
            leaf: false,
            targets: vec!["@git".to_string()],
            ranges: Vec::new(),
            deferred_flags: Vec::new(),
            fail_fast: false,
            lanes: None,
            jobs: None,
            intensity: None,
            state_dir: None,
            pacman_args: None,
        };
        let record = build_plan_record(&inv, &selection(2), &["@git".to_string()], &[], "xhigh");
        assert_eq!(record.outcome, "planned");
        assert_eq!(record.rc, 0);
        assert_eq!(record.plan.len(), 2);
        assert_eq!(record.plan[0].action, PlanAction::BuildInstall);
        // The prune strength 'c' is never mirrored; --dry-run and --leaf are.
        assert_eq!(
            record.continuation.command,
            "gsa -S --dry-run --leaf=no pkg1 pkg2"
        );
        assert!(record.continuation.not_mirrored.iter().any(|f| f == "-Mcc"));
        let block = record.render_machine();
        assert!(block.contains("selection-source: sets=@git leaf=no range=-"));
        assert!(block.contains("pkg1 never-started - - dry-run"));
        assert_eq!(block.matches("dry-run: yes").count(), 1);
    }

    #[test]
    fn build_family_plans_build_rows() {
        let inv = Invocation {
            family: Family::B,
            action: None,
            modifiers: Vec::new(),
            dry_run: true,
            leaf: true,
            targets: vec!["mesa-git".to_string()],
            ranges: Vec::new(),
            deferred_flags: Vec::new(),
            fail_fast: false,
            lanes: None,
            jobs: None,
            intensity: None,
            state_dir: None,
            pacman_args: None,
        };
        let record = build_plan_record(
            &inv,
            &selection(1),
            &["mesa-git".to_string()],
            &["1..1".to_string()],
            "high",
        );
        assert_eq!(record.plan[0].action, PlanAction::Build);
        assert_eq!(
            record.continuation.command,
            "gsa -B --dry-run --leaf=yes pkg1"
        );
        assert_eq!(record.selection_source, "sets=mesa-git leaf=yes range=1..1");
    }

    #[test]
    fn run_record_mirrors_the_resolved_budget_and_restates_remaining() {
        let inv = Invocation {
            family: Family::B,
            action: None,
            modifiers: Vec::new(),
            dry_run: false,
            leaf: false,
            targets: vec!["@git".to_string()],
            ranges: Vec::new(),
            deferred_flags: Vec::new(),
            fail_fast: true,
            lanes: None,
            jobs: None,
            intensity: None,
            state_dir: Some("/scratch/state".to_string()),
            pacman_args: None,
        };
        let outcomes = vec![
            OutcomeRow {
                pkg: RecipeId::new("pkg1").unwrap(),
                status: RowStatus::Failed,
                rc: Some(1),
                dur: Some(3),
                reason: "build-failed".to_string(),
            },
            OutcomeRow {
                pkg: RecipeId::new("pkg2").unwrap(),
                status: RowStatus::Parked,
                rc: None,
                dur: None,
                reason: "waits-on-failed".to_string(),
            },
            OutcomeRow {
                pkg: RecipeId::new("pkg3").unwrap(),
                status: RowStatus::Succeeded,
                rc: Some(0),
                dur: Some(5),
                reason: "ok".to_string(),
            },
        ];
        let run_outcome = gsa_model::RunOutcome::compute(&outcomes, true, false, false);
        assert_eq!((run_outcome.outcome, run_outcome.rc), ("failed", 1));
        let record = build_run_record(
            &inv,
            &selection(3),
            &["@git".to_string()],
            &[],
            None,
            outcomes,
            &run_outcome,
        );
        assert_eq!(record.rc, 1);
        assert_eq!(record.outcome, "failed");
        // Remaining is every row not succeeded, in row order (§H.2).
        assert_eq!(
            record
                .continuation
                .remaining
                .iter()
                .map(|id| id.as_str())
                .collect::<Vec<_>>(),
            vec!["pkg1", "pkg2"]
        );
        assert_eq!(record.continuation.command, "gsa -B --fail-fast pkg1 pkg2");
        // Hidden seams and one-shot actions are never mirrored (§H.2).
        for seam in ["--lane-job", "--stale-lock-check", "--install-decide"] {
            assert!(record.continuation.not_mirrored.iter().any(|f| f == seam));
        }
        // --state-dir is never baked in; the resume is warned instead.
        assert!(!record.continuation.command.contains("--state-dir"));
        assert!(record
            .continuation
            .env_required
            .iter()
            .any(|n| n == "GSA_STATE_DIR"));
    }
}
