//! The dry-run run record: plan rows, outcome rows and the continuation,
//! built from one flag-rule table (contract §H).
//!
//! Phase 1 records are dry-run records: the plan section is the deliverable
//! (§B `--dry-run`), the outcome section records that nothing was dispatched
//! (`never-started dry-run` — an additive reason key, allowed without a
//! format bump), and the continuation restates the run to do for real.

use gsa_model::{
    Continuation, DecisionRow, OutcomeRow, PlanAction, PlanRow, RecipeId, RowStatus, RunRecord,
};

use crate::args::{Family, Invocation};
use crate::select::Selection;

/// Emit the `format: 2` machine block AND persist the same record into the
/// side-car run history (contract §H.1's amendment): persistence is storage
/// of the one structure, never a fourth derivation. A dry-run record
/// mutates nothing (§B.8) — it renders but is never stored. A persistence
/// failure is loud (naming `--state-dir` as the remedy, §J.3) and never
/// changes the record or its rc.
pub fn emit_machine_record(
    out: &mut dyn std::io::Write,
    record: &RunRecord,
    state_dir: &std::path::Path,
    err: &mut dyn std::io::Write,
) {
    let _ = write!(out, "{}", record.render_machine());
    if record.dry_run {
        return;
    }
    let mut notes = Vec::new();
    let result = gsa_state::StateRoot::open(state_dir)
        .and_then(|root| gsa_state::RunHistory::append(&root, record, &mut notes));
    if !notes.is_empty() {
        let _ = err.write_all(&notes);
    }
    if let Err(error) = result {
        let _ = writeln!(err, "gsa: error: run history not persisted: {error}");
    }
}

/// The engine environment input roster (`gsa --help` must print it).
/// `GSA_BUILD_JOBS` is engine output and deliberately absent.
pub const ENV_ROSTER: [&str; 10] = [
    "GSA_BUILD_DIR",
    "GSA_CONF",
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
/// `--state-dir`, `--config`, `--no-register-ignorepkg`, `--no-prefetch`,
/// `--prefetch-ahead N`, and the resolved `--lanes`/`--jobs`/`--intensity`
/// values; the cluster letter `c` is a prune strength and never mirrors, `f`
/// mirrors). `-Sw` is mirrorable on purpose: a fetch run's continuation
/// reissues the fetch action for its remaining packages (docs/adr/
/// 0004-prefetch-advisory.md).
pub const NOT_MIRRORED: &[&str] = &[
    "-Q",
    "-Ss",
    "-Si",
    "-Sl",
    "-Sg",
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
    // The -M sub-flags (§B.7): one-shot action modifiers, never replayed.
    "--fix",
    "--prune",
    "--backfill",
    "--tail",
    "--keep",
    "--show",
    "--add",
    "--remove",
    "--noconfirm",
    // Parse-deferred globals (§B.8) — absent from any live spelling, so a
    // continuation must never carry them either.
    "--quiet",
    "--verbose",
    // Output-mode globals (presentation only — a resume picks its own):
    // never replayed.
    "--machine",
    "--human",
    "--install-decide",
    "--lane-job",
    "--fetch-job",
    "--stale-lock-check",
    "--local-db-check",
    "--install-register",
    "--register-ignorepkg",
    "--qa-check",
];

/// The run-record package id for a decision-row subject (contract §E.2 —
/// subjects are pkgbase strings, `-` for rows with no subject). A subject
/// [`RecipeId`] rejects is sanitized rather than dropped; the caller notes
/// the substitution (a record row is never lost).
pub fn subject_id(subject: &str) -> RecipeId {
    if let Ok(id) = RecipeId::new(subject) {
        return id;
    }
    let sanitized: String = subject
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-' | '+') {
                c
            } else {
                '-'
            }
        })
        .collect();
    let sanitized = if sanitized.is_empty() {
        "unnamed".to_string()
    } else {
        sanitized
    };
    RecipeId::new(sanitized)
        .unwrap_or_else(|_| RecipeId::new("unnamed").expect("'unnamed' is a valid id"))
}

/// The decision rows' second rendering (contract §E.1 — one decision, one
/// seam, three renderings): the run-record plan row for one decision row.
pub fn decision_plan_row(row: &DecisionRow) -> PlanRow {
    PlanRow {
        pkg: subject_id(&row.subject),
        action: row.clone().plan_action(),
        reason: row.reason.clone(),
    }
}

/// The mirrored flags of a continuation's `command:` line (contract §H.2) —
/// everything the run made real restated as explicit flags: the five
/// §B.8 sync/freshness/toolchain modifiers (`--skip`, `--skip-built`,
/// `--vcs-skip-tolerance N`, `--no-sync`, `--allow-broken-rustc`), `--fail-fast`,
/// `--state-dir`, `--config`, `--no-register-ignorepkg`, `--no-prefetch`,
/// `--prefetch-ahead` (mirrored when non-default, per the flag-rule table —
/// docs/adr/0004-prefetch-advisory.md), and the resolved
/// `--lanes`/`--jobs`/`--intensity` values.
fn mirror_flags(inv: &Invocation, budget: Option<&gsa_sched::budget::Budget>) -> String {
    let mut out = String::new();
    if inv.skip {
        out.push_str(" --skip");
    }
    if inv.skip_built {
        out.push_str(" --skip-built");
    }
    if let Some(tolerance) = &inv.vcs_skip_tolerance {
        out.push_str(&format!(" --vcs-skip-tolerance {tolerance}"));
    }
    if inv.no_sync {
        out.push_str(" --no-sync");
    }
    if inv.allow_broken_rustc {
        out.push_str(" --allow-broken-rustc");
    }
    if inv.fail_fast {
        out.push_str(" --fail-fast");
    }
    if let Some(dir) = &inv.state_dir {
        out.push_str(&format!(" --state-dir {dir}"));
    }
    if let Some(conf) = &inv.config {
        out.push_str(&format!(" --config {conf}"));
    }
    if inv
        .deferred_flags
        .iter()
        .any(|f| f == "--no-register-ignorepkg")
    {
        out.push_str(" --no-register-ignorepkg");
    }
    // Prefetch knobs (owner decision 1): non-default values only — a
    // default-on prefetch run's continuation needs no flag.
    if inv.no_prefetch {
        out.push_str(" --no-prefetch");
    }
    if let Some(ahead) = &inv.prefetch_ahead {
        out.push_str(&format!(" --prefetch-ahead {ahead}"));
    }
    if let Some(budget) = budget {
        out.push_str(&format!(" --lanes {}", budget.lanes));
        out.push_str(&format!(" --jobs {}", budget.normal_jobs));
        out.push_str(&format!(" --intensity {}", budget.intensity));
    }
    out
}

/// The trailing `-- <pacman args…>` of a run, mirrored verbatim (contract
/// §B.1: forwarded to the `pacman -U` invocation of an install transaction).
fn mirror_pacman_args(inv: &Invocation) -> String {
    match &inv.pacman_args {
        Some(args) if !args.is_empty() => {
            let mut out = String::from(" --");
            for arg in args {
                out.push(' ');
                out.push_str(arg);
            }
            out
        }
        _ => String::new(),
    }
}

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
    // `--leaf` is mirrored ONLY in its true form (contract §H.2's flag-rule
    // table): a leaf=no run mirrors nothing — the absence of the flag IS the
    // negation, and `--leaf=no`/`--leaf=yes` are not replayable spellings
    // (§B.8 defines the bare boolean; gap G4's replay hazard).
    if inv.leaf {
        command.push_str(" --leaf");
    }
    command.push_str(&mirror_flags(inv, None));
    for (_, id) in &selection.listed {
        command.push(' ');
        command.push_str(id.as_str());
    }
    command.push_str(&mirror_pacman_args(inv));

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
        prefetch_warnings: None,
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
/// and `order` from the pre-dispatch pass and the dispatch machine
/// (§H.2 — the supervisor's carried nodes: the selection plus any activated
/// remediation latent), outcome rows as the machine settled them (never
/// re-derived here), and a continuation that restates the resume. The same
/// structure is rendered three ways by the caller (streaming dashboard
/// events during the run, prose summary, machine block).
pub fn build_run_record(
    inv: &Invocation,
    targets: &[String],
    ranges: &[String],
    budget: Option<&gsa_sched::budget::Budget>,
    plan: Vec<PlanRow>,
    order: Vec<RecipeId>,
    outcomes: Vec<OutcomeRow>,
    outcome: &gsa_model::RunOutcome,
    prefetch_warnings: Option<u32>,
) -> RunRecord {
    let selection_source = selection_source(targets, inv.leaf, ranges);

    // Restated invocation (contract §H.2): family + action + mirrored
    // cluster letters (`f` mirrors, the prune strength `c` never does), the
    // mirrored flags (`--leaf`, `--fail-fast`, `--state-dir`, `--config`,
    // `--no-register-ignorepkg`, the resolved `--lanes`/`--jobs`/
    // `--intensity` values), then the remaining package ids and the
    // `-- <pacman args…>` an install run forwards to its transactions.
    let mut command = String::from("gsa ");
    command.push_str(inv.family.as_str());
    if let Some(action) = inv.action {
        command.push(action);
    }
    if inv.modifiers.contains(&'f') {
        command.push('f');
    }
    if inv.leaf {
        command.push_str(" --leaf");
    }
    command.push_str(&mirror_flags(inv, budget));

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
    command.push_str(&mirror_pacman_args(inv));

    RunRecord {
        selection_source,
        order,
        lanes: budget.map(|b| b.lanes),
        normal_jobs: budget.map(|b| b.normal_jobs),
        core_jobs: budget.map(|b| b.core_jobs),
        intensity: budget
            .map(|b| b.intensity.to_string())
            .unwrap_or_else(|| "-".to_string()),
        outcome: outcome.outcome.to_string(),
        rc: outcome.rc,
        dry_run: false,
        prefetch_warnings,
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

/// The one run record for a `-Sw` fetch-only run (contract §B.4/§H): the
/// plan rows are `fetch` for fetch candidates and `skip <reason>` for
/// non-candidates, the outcome rows are the verdict rows' `format: 2`
/// rendering (`ok` → `succeeded`, `failed` → `failed`, `skipped` →
/// `succeeded` with its skip reason so `remaining:` never re-fetches one),
/// and the continuation restates `gsa -Sw` for whatever did not settle.
/// Fetch verdicts carry their OWN vocabulary on stdout (§D.1); this record
/// is the §H rendering of the same outcomes.
pub fn build_fetch_record(
    inv: &Invocation,
    selection: &Selection,
    targets: &[String],
    ranges: &[String],
    plan: Vec<PlanRow>,
    outcomes: Vec<OutcomeRow>,
    outcome: &gsa_model::RunOutcome,
) -> RunRecord {
    let selection_source = selection_source(targets, inv.leaf, ranges);

    let mut command = String::from("gsa -Sw");
    if inv.dry_run {
        // §H.2: `--dry-run` is mirrored — a fetch run's continuation for a
        // dry run reissues the fetch plan, never a surprise real fetch.
        command.push_str(" --dry-run");
    }
    if inv.leaf {
        command.push_str(" --leaf");
    }
    command.push_str(&mirror_flags(inv, None));
    // `remaining:` — every row not `succeeded`, in row order (§H.2): the
    // fetches to re-run.
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
        // A fetch run dispatches no lanes and no build jobs (contract §H.2:
        // the machine block values are the run's, and a fetch-only run has
        // none — 0, not a predicted plan).
        lanes: Some(0),
        normal_jobs: Some(0),
        core_jobs: Some(0),
        intensity: "-".to_string(),
        outcome: outcome.outcome.to_string(),
        rc: outcome.rc,
        dry_run: inv.dry_run,
        // The `prefetch-warnings` scalar belongs to build-run fetch-ahead
        // (owner decision 5); a fetch-only run's verdicts are its rows.
        prefetch_warnings: None,
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

/// The `-U` record's per-subject collapse (contract §H.2: "Rows are full —
/// one per selected package"): a multi-row candidate — several PGO hits, a
/// stacked PGO+ABI refusal, a split output set — is ONE package in the run
/// record, so `order`, the plan rows and the outcome rows stay one-to-one
/// under the strict `format: 2` grammar (duplicate rows and duplicate
/// `order` entries are rejected). The seam's per-candidate rows are
/// untouched: they are the FIRST rendering (§E.1), this is the second.
///
/// Merge rules (the record never re-decides — it aggregates what the one
/// decision computed): the plan action is the strongest of the group
/// (`refused` > `parked` > `install` > `skip` > `noop`), the outcome status
/// the worst (`failed` > `interrupted` > `deferred` > `parked` >
/// `never-started` > `succeeded` — so `remaining:` keeps any subject that
/// did not fully succeed), `rc`/`dur` come from the winning outcome row,
/// and the reason is every row's reason in row order joined by single
/// spaces with exact repeats dropped (the reason is the remainder of the
/// line, §H.2 — a join stays grammatical and lossless).
fn collapse_txn_rows(
    plan: Vec<PlanRow>,
    outcomes: Vec<OutcomeRow>,
) -> (Vec<PlanRow>, Vec<OutcomeRow>) {
    fn plan_rank(action: PlanAction) -> u8 {
        match action {
            PlanAction::Refused => 5,
            PlanAction::Parked => 4,
            PlanAction::Install | PlanAction::BuildInstall | PlanAction::Build => 3,
            PlanAction::Skip | PlanAction::Fetch => 2,
            PlanAction::Noop => 1,
        }
    }
    fn status_rank(status: RowStatus) -> u8 {
        match status {
            RowStatus::Failed => 6,
            RowStatus::Interrupted => 5,
            RowStatus::Deferred => 4,
            RowStatus::Parked => 3,
            RowStatus::NeverStarted => 2,
            RowStatus::Succeeded => 1,
        }
    }
    fn join_reasons(reasons: impl Iterator<Item = String>) -> String {
        let mut seen: Vec<String> = Vec::new();
        for reason in reasons {
            if reason.is_empty() || seen.contains(&reason) {
                continue;
            }
            seen.push(reason);
        }
        seen.join(" ")
    }

    let mut plan_order: Vec<RecipeId> = Vec::new();
    let mut plan_groups: Vec<Vec<PlanRow>> = Vec::new();
    for row in plan {
        match plan_order.iter().position(|pkg| *pkg == row.pkg) {
            Some(idx) => plan_groups[idx].push(row),
            None => {
                plan_order.push(row.pkg.clone());
                plan_groups.push(vec![row]);
            }
        }
    }
    let plan: Vec<PlanRow> = plan_groups
        .into_iter()
        .map(|group| {
            let best = group
                .iter()
                .max_by_key(|row| plan_rank(row.action))
                .expect("non-empty group");
            PlanRow {
                pkg: best.pkg.clone(),
                action: best.action,
                reason: join_reasons(group.into_iter().map(|row| row.reason)),
            }
        })
        .collect();

    let mut out_order: Vec<RecipeId> = Vec::new();
    let mut out_groups: Vec<Vec<OutcomeRow>> = Vec::new();
    for row in outcomes {
        match out_order.iter().position(|pkg| *pkg == row.pkg) {
            Some(idx) => out_groups[idx].push(row),
            None => {
                out_order.push(row.pkg.clone());
                out_groups.push(vec![row]);
            }
        }
    }
    let outcomes: Vec<OutcomeRow> = out_groups
        .into_iter()
        .map(|group| {
            let worst = group
                .iter()
                .max_by_key(|row| status_rank(row.status))
                .expect("non-empty group");
            OutcomeRow {
                pkg: worst.pkg.clone(),
                status: worst.status,
                rc: worst.rc,
                dur: worst.dur,
                reason: join_reasons(group.into_iter().map(|row| row.reason)),
            }
        })
        .collect();
    (plan, outcomes)
}

/// The one run record for a `-U` install-from-archives run (contract §H):
/// the plan rows ARE the decision rows' run-record rendering (§E.1 — one
/// decision, one seam; the `--install-decide` stdout is the first rendering,
/// this is the second, the prose summary the third), collapsed per subject
/// ([`collapse_txn_rows`]) so the block is strict-`format: 2`-parseable, the
/// outcome rows come from the transaction result, and the continuation
/// restates the remaining subjects. `-Ua` is one-shot and never mirrored:
/// the continuation reissues `-U` with the remaining subjects named
/// explicitly. A transaction run dispatches no lanes: its budget scalars
/// render `0` (§H.2's strict grammar).
pub fn build_txn_record(
    inv: &Invocation,
    targets: &[String],
    plan: Vec<PlanRow>,
    outcomes: Vec<OutcomeRow>,
    outcome: &gsa_model::RunOutcome,
) -> RunRecord {
    let (plan, outcomes) = collapse_txn_rows(plan, outcomes);
    let source_targets: Vec<String> = if targets.is_empty() && inv.modifiers.contains(&'a') {
        vec!["all".to_string()]
    } else {
        targets.to_vec()
    };
    // A `-U` run installs exactly what it names — no consumer expansion.
    let selection_source = selection_source(&source_targets, true, &[]);

    let mut command = String::from("gsa ");
    command.push_str(inv.family.as_str());
    if inv.modifiers.contains(&'f') {
        command.push('f');
    }
    command.push_str(&mirror_flags(inv, None));

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
    command.push_str(&mirror_pacman_args(inv));

    let order: Vec<RecipeId> = plan.iter().map(|row| row.pkg.clone()).collect();
    RunRecord {
        selection_source,
        order,
        lanes: None,
        normal_jobs: None,
        core_jobs: None,
        intensity: "-".to_string(),
        outcome: outcome.outcome.to_string(),
        rc: outcome.rc,
        dry_run: inv.dry_run,
        prefetch_warnings: None,
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
            output_mode: None,
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
            config: None,
            tail: None,
            keep: None,
            show: None,
            pacman_args: None,
            no_prefetch: false,
            prefetch_ahead: None,
            skip: false,
            skip_built: false,
            vcs_skip_tolerance: None,
            no_sync: false,
            allow_broken_rustc: false,
            standalone_root: None,
        };
        let record = build_plan_record(&inv, &selection(2), &["@git".to_string()], &[], "xhigh");
        assert_eq!(record.outcome, "planned");
        assert_eq!(record.rc, 0);
        assert_eq!(record.plan.len(), 2);
        assert_eq!(record.plan[0].action, PlanAction::BuildInstall);
        // The prune strength 'c' is never mirrored; --dry-run is; --leaf only
        // in its true form (G4 — absence IS the negation).
        assert_eq!(record.continuation.command, "gsa -S --dry-run pkg1 pkg2");
        assert!(record.continuation.not_mirrored.iter().any(|f| f == "-Mcc"));
        let block = record.render_machine();
        assert!(block.contains("selection-source: sets=@git leaf=no range=-"));
        assert!(block.contains("pkg1 never-started - - dry-run"));
        assert_eq!(block.matches("dry-run: yes").count(), 1);
    }

    #[test]
    fn build_family_plans_build_rows() {
        let inv = Invocation {
            output_mode: None,
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
            config: None,
            tail: None,
            keep: None,
            show: None,
            pacman_args: None,
            no_prefetch: false,
            prefetch_ahead: None,
            skip: false,
            skip_built: false,
            vcs_skip_tolerance: None,
            no_sync: false,
            allow_broken_rustc: false,
            standalone_root: None,
        };
        let record = build_plan_record(
            &inv,
            &selection(1),
            &["mesa-git".to_string()],
            &["1..1".to_string()],
            "high",
        );
        assert_eq!(record.plan[0].action, PlanAction::Build);
        assert_eq!(record.continuation.command, "gsa -B --dry-run --leaf pkg1");
        assert_eq!(record.selection_source, "sets=mesa-git leaf=yes range=1..1");
    }

    #[test]
    fn run_record_mirrors_the_resolved_budget_and_restates_remaining() {
        let inv = Invocation {
            output_mode: None,
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
            config: None,
            tail: None,
            keep: None,
            show: None,
            pacman_args: None,
            no_prefetch: false,
            prefetch_ahead: None,
            skip: false,
            skip_built: false,
            vcs_skip_tolerance: None,
            no_sync: false,
            allow_broken_rustc: false,
            standalone_root: None,
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
        let (plan, order) = plan_and_order(&selection(3), PlanAction::Build);
        let record = build_run_record(
            &inv,
            &["@git".to_string()],
            &[],
            None,
            plan,
            order,
            outcomes,
            &run_outcome,
            None,
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
        assert_eq!(
            record.continuation.command,
            "gsa -B --fail-fast --state-dir /scratch/state pkg1 pkg2"
        );
        // Hidden seams and one-shot actions are never mirrored (§H.2).
        for seam in ["--lane-job", "--stale-lock-check", "--install-decide"] {
            assert!(record.continuation.not_mirrored.iter().any(|f| f == seam));
        }
        // --state-dir is mirrored as an explicit flag and the ambient env
        // is warned about too (§H.2).
        assert!(record
            .continuation
            .command
            .contains("--state-dir /scratch/state"));
        assert!(record
            .continuation
            .env_required
            .iter()
            .any(|n| n == "GSA_STATE_DIR"));
    }

    /// The plan/order pair a plain run would carry (one build row per
    /// selection id, in selection order).
    fn plan_and_order(selection: &Selection, action: PlanAction) -> (Vec<PlanRow>, Vec<RecipeId>) {
        let mut plan = Vec::new();
        let mut order = Vec::new();
        for (_, id) in &selection.listed {
            plan.push(PlanRow {
                pkg: id.clone(),
                action: match action {
                    PlanAction::Build => PlanAction::Build,
                    _ => PlanAction::BuildInstall,
                },
                reason: "ok".to_string(),
            });
            order.push(id.clone());
        }
        (plan, order)
    }

    fn inv_for(family: Family) -> Invocation {
        Invocation {
            output_mode: None,
            family,
            action: None,
            modifiers: Vec::new(),
            dry_run: false,
            leaf: false,
            targets: Vec::new(),
            ranges: Vec::new(),
            deferred_flags: Vec::new(),
            fail_fast: false,
            lanes: None,
            jobs: None,
            intensity: None,
            state_dir: None,
            config: None,
            tail: None,
            keep: None,
            show: None,
            pacman_args: None,
            no_prefetch: false,
            prefetch_ahead: None,
            skip: false,
            skip_built: false,
            vcs_skip_tolerance: None,
            no_sync: false,
            allow_broken_rustc: false,
            standalone_root: None,
        }
    }

    #[test]
    fn decision_rows_map_to_plan_rows() {
        use gsa_model::Decision;
        let cases = [
            (Decision::Install, "install", PlanAction::Install),
            (Decision::Skip, "already-current", PlanAction::Skip),
            (Decision::Refuse, "pgo-hit", PlanAction::Refused),
            (Decision::Noop, "empty-list", PlanAction::Noop),
            (Decision::Parked, "waits-on-deferred", PlanAction::Parked),
        ];
        for (decision, reason, action) in cases {
            let row = DecisionRow {
                subject: "mesa-git".to_string(),
                decision,
                reason: reason.to_string(),
            };
            let plan = decision_plan_row(&row);
            assert_eq!(plan.pkg.as_str(), "mesa-git");
            assert_eq!(plan.action, action, "{decision:?}");
            assert_eq!(plan.reason, reason);
        }
        // A `-` subject maps fine (contract §E.3 `empty-list` rows).
        let row = DecisionRow {
            subject: "-".to_string(),
            decision: Decision::Noop,
            reason: "empty-list".to_string(),
        };
        assert_eq!(decision_plan_row(&row).pkg.as_str(), "-");
    }

    #[test]
    fn subjects_that_are_not_recipe_ids_are_sanitized_not_dropped() {
        assert_eq!(subject_id("mesa-git").as_str(), "mesa-git");
        let id = subject_id("weird subject/with:symbols");
        assert!(RecipeId::new(id.as_str()).is_ok());
        assert!(!id.as_str().contains('/'));
        assert_eq!(subject_id("").as_str(), "unnamed");
    }

    #[test]
    fn install_run_flags_mirror_and_hidden_seams_never_do() {
        let mut inv = inv_for(Family::S);
        inv.fail_fast = true;
        inv.config = Some("/etc/pacman.conf".to_string());
        inv.deferred_flags = vec![
            "--no-register-ignorepkg".to_string(),
            "--register-ignorepkg".to_string(),
        ];
        inv.pacman_args = Some(vec!["--overwrite".to_string(), "*".to_string()]);
        let outcomes = vec![OutcomeRow {
            pkg: RecipeId::new("pkg1").unwrap(),
            status: RowStatus::Succeeded,
            rc: Some(0),
            dur: Some(1),
            reason: "ok".to_string(),
        }];
        let run_outcome = gsa_model::RunOutcome::compute(&outcomes, true, false, false);
        let (plan, order) = plan_and_order(&selection(1), PlanAction::BuildInstall);
        let record = build_run_record(
            &inv,
            &["pkg1".to_string()],
            &[],
            None,
            plan,
            order,
            outcomes,
            &run_outcome,
            None,
        );
        let command = record.continuation.command.clone();
        assert!(command.contains("--fail-fast"), "{command}");
        assert!(command.contains("--config /etc/pacman.conf"), "{command}");
        assert!(command.contains("--no-register-ignorepkg"), "{command}");
        assert!(command.contains(" -- --overwrite *"), "{command}");
        // Hidden seams are classified not-mirrored (§H.2).
        assert!(record
            .continuation
            .not_mirrored
            .iter()
            .any(|f| f == "--register-ignorepkg"));
    }

    #[test]
    fn txn_record_collapses_multi_row_candidates_and_keeps_budgets_integer() {
        use gsa_model::Decision;
        // One candidate refusing on two PGO hits plus a stacked ABI row —
        // three decision rows, ONE package in the record (§H.2).
        let rows = [
            ("mesa-git", Decision::Refuse, "pgo-hit /train/a.gcda"),
            ("mesa-git", Decision::Refuse, "pgo-hit /train/b.gcda"),
            (
                "mesa-git",
                Decision::Refuse,
                "abi-soname /a libfoo.so=1-64 1 2",
            ),
        ];
        let plan: Vec<PlanRow> = rows
            .iter()
            .map(|(subject, decision, reason)| {
                decision_plan_row(&DecisionRow {
                    subject: subject.to_string(),
                    decision: *decision,
                    reason: reason.to_string(),
                })
            })
            .collect();
        let outcomes = vec![
            OutcomeRow {
                pkg: RecipeId::new("mesa-git").unwrap(),
                status: RowStatus::NeverStarted,
                rc: None,
                dur: None,
                reason: "install-refused pgo-hit /train/a.gcda".to_string(),
            },
            OutcomeRow {
                pkg: RecipeId::new("mesa-git").unwrap(),
                status: RowStatus::Succeeded,
                rc: Some(0),
                dur: Some(1),
                reason: "ok".to_string(),
            },
        ];
        let mut inv = inv_for(Family::U);
        inv.modifiers = vec!['a'];
        let run_outcome = gsa_model::RunOutcome::compute(&outcomes, false, false, true);
        let record = build_txn_record(&inv, &[], plan, outcomes, &run_outcome);

        assert_eq!(record.order.len(), 1, "order must not repeat a subject");
        assert_eq!(record.plan.len(), 1);
        assert_eq!(record.plan[0].action, PlanAction::Refused);
        assert_eq!(
            record.plan[0].reason,
            "pgo-hit /train/a.gcda pgo-hit /train/b.gcda abi-soname /a libfoo.so=1-64 1 2"
        );
        assert_eq!(record.outcomes.len(), 1);
        // The worst row wins, so a partly-succeeded subject stays in
        // `remaining:` — and one subject appears there once.
        assert_eq!(record.outcomes[0].status, RowStatus::NeverStarted);
        assert_eq!(record.continuation.remaining.len(), 1);

        // Strict §H.2 grammar: budget scalars are integers, rows agree with
        // the order scalar one position each.
        let block = record.render_machine();
        for line in ["lanes: 0", "normal-jobs: 0", "core-jobs: 0"] {
            assert!(block.contains(line), "{line} missing:\n{block}");
        }
        assert!(!block.contains("lanes: -"), "{block}");
    }

    #[test]
    fn plan_record_mirrors_leaf_only_in_its_true_form() {
        // G4: `--leaf=no`/`--leaf=yes` are not replayable spellings — a
        // continuation mirrors `--leaf` or nothing (absence IS the negation).
        let mut inv = inv_for(Family::S);
        inv.leaf = true;
        let record = build_plan_record(&inv, &selection(1), &["pkg1".to_string()], &[], "xhigh");
        assert!(
            record
                .continuation
                .command
                .split(' ')
                .any(|tok| tok == "--leaf"),
            "{}",
            record.continuation.command
        );

        inv.leaf = false;
        let record = build_plan_record(&inv, &selection(1), &["pkg1".to_string()], &[], "xhigh");
        assert!(
            !record.continuation.command.contains("--leaf"),
            "{}",
            record.continuation.command
        );
    }

    #[test]
    fn txn_record_renders_decision_rows_and_one_shot_u_a_is_not_mirrored() {
        use gsa_model::Decision;
        let mut inv = inv_for(Family::U);
        inv.modifiers = vec!['a', 'f'];
        inv.targets = Vec::new();
        let plan = vec![decision_plan_row(&DecisionRow {
            subject: "mesa-git".to_string(),
            decision: Decision::Install,
            reason: "ok".to_string(),
        })];
        let outcomes = vec![OutcomeRow {
            pkg: RecipeId::new("mesa-git").unwrap(),
            status: RowStatus::Succeeded,
            rc: Some(0),
            dur: Some(2),
            reason: "ok".to_string(),
        }];
        let run_outcome = gsa_model::RunOutcome::compute(&outcomes, false, false, false);
        let record = build_txn_record(&inv, &[], plan, outcomes, &run_outcome);
        assert_eq!(record.plan[0].action, PlanAction::Install);
        assert_eq!(record.selection_source, "sets=all leaf=yes range=-");
        assert_eq!(record.rc, 0);
        // `-Ua` is one-shot (never mirrored); `f` mirrors.
        assert!(record.continuation.not_mirrored.iter().any(|f| f == "-Ua"));
        assert!(
            record.continuation.command.starts_with("gsa -Uf"),
            "{}",
            record.continuation.command
        );
        assert!(!record.continuation.command.contains("-Ua"));
    }

    #[test]
    fn maint_spellings_and_sub_flags_are_never_mirrored() {
        // §L.1's three places: every `-M` spelling and every §B.7 sub-flag
        // lands in the continuation flag-rule table as not-mirrored — a
        // maintain action is one-shot and a continuation must never replay
        // one.
        for spelling in [
            "-Ma",
            "-Mc",
            "-Mcc",
            "-Mccc",
            "-Md",
            "-Mi",
            "-Ml",
            "-Mm",
            "-Ms",
            "-Mw",
            "-Mh",
            "--fix",
            "--prune",
            "--backfill",
            "--tail",
            "--keep",
            "--show",
            "--add",
            "--remove",
            "--noconfirm",
        ] {
            assert!(
                NOT_MIRRORED.contains(&spelling),
                "{spelling} must be in the not-mirrored list"
            );
        }
        // A build continuation's `command:` carries no -M token at all.
        let mut inv = inv_for(Family::B);
        inv.targets = vec!["pkg1".to_string()];
        let record = build_plan_record(&inv, &selection(1), &["pkg1".to_string()], &[], "xhigh");
        let command = record.continuation.command.clone();
        assert!(
            !command.split_whitespace().any(|tok| tok.starts_with("-M")),
            "{command}"
        );
    }
}
