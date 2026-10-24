//! The install surface: `gsa -U` (install from archives, contract §B.6) and
//! the hidden install seams (`--install-decide`, `--install-register`,
//! `--register-ignorepkg`, §D.1).
//!
//! One decision, one seam (`docs/MEMORY.md` rule 20): `gsa_install::decide`
//! computes the plan once as typed `DecisionRow`s; this module renders them
//! (the `--install-decide` stdout, the run-record plan rows, the prose
//! summary) and executes them — never re-deciding. Every refusal is
//! fail-closed (rule 25(h)): a `refuse` row means the run is pacman-free end
//! to end — no registration, no `pacman`, no flock.
//!
//! Process contract (§K.3): `sudo -n` only (via the executor's preflight),
//! one `pacman -U` at a time through the state-root mutex, and the system
//! `db.lck` is never deleted (rule 23). The transaction runs as a child in
//! its own process group so the first signal can SIGTERM that group, hold a
//! bounded grace window (`signals::stop_grace_seconds`), then SIGKILL —
//! exit 130 with the full run record (§I.3).

use std::collections::{BTreeMap, BTreeSet};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use gsa_abi::{plan_waves, stage_swap, Subscriptions, TokenMove, WaveInputs, WavePlan};
use gsa_graph::Graph;
use gsa_install::localdb::pacman_db_root;
use gsa_install::{
    decide, decide_mode, discover_recipe, execute_txn, names_for_archive, preflight_installs,
    register_ignorepkg, render_rows, rows_rc, workspace_exclusions, Candidate, DecideMode,
    DecisionContext, EmptyListPolicy, LocalDb, RegisterReport, TxnOutcome, TxnRequest,
};
use gsa_model::{Decision, DecisionRow, OutcomeRow, PlanRow, RecipeId, RowStatus, RunOutcome};
use gsa_recipe::pkginfo::read_pkginfo;
use gsa_recipe::RecipeDb;
use gsa_sched::signals::{self, ChildExit, Forked};
use gsa_sched::supervisor::InstallStep;
use gsa_topo::load_project;

use crate::args::Invocation;
use crate::select::{self, Ctx};
use crate::{record, render};

/// The long flags a `-U` install run accepts (contract §B.8): the
/// install-related modifiers that are real here. The classifier consults
/// this roster; everything else stays deferred.
pub const REAL_UPGRADE_FLAGS: [&str; 4] = [
    "--fail-fast",
    "--state-dir",
    "--config",
    "--no-register-ignorepkg",
];

/// The default target pacman.conf (rule 9).
pub(crate) const DEFAULT_CONF: &str = "/etc/pacman.conf";

// ---------------------------------------------------------------------------
// Pure mappings (unit-tested; no gsa-install behaviour is touched here)
// ---------------------------------------------------------------------------

/// The IgnorePkg write set one `-U` registration made (rule 9), kept for the
/// failed-transaction rollback (rule 9's complement).
struct RegisteredNames {
    /// The exact names this run appended — names already in the closure
    /// before the run are never un-registered.
    added: Vec<String>,
    /// Names of install-bearing archives (`install` rows).
    install_names: Vec<String>,
    /// Per install-bearing archive, the names it establishes — a landed
    /// archive's names join the keep side below.
    archive_names: Vec<(PathBuf, Vec<String>)>,
    /// Names a skip (already-current) archive also protects: they ARE
    /// installed, so they stay registered whatever the transactions did.
    skip_names: Vec<String>,
}

impl RegisteredNames {
    /// What to un-register once the staged transactions have settled:
    /// `added ∩ install-bearing \ keep`, with `keep` extended by every name
    /// whose archive actually landed. A landed wave IS installed, so a
    /// multi-wave partial success keeps its landed registrations while the
    /// failed, held or never-started waves' names roll back.
    fn names_to_rollback(&self, fates: &BTreeMap<PathBuf, GroupFate>) -> Vec<String> {
        let mut keep: Vec<String> = self.skip_names.clone();
        for (archive, names) in &self.archive_names {
            if matches!(fates.get(archive), Some(GroupFate::Landed)) {
                keep.extend(names.iter().cloned());
            }
        }
        gsa_install::rollback_registration_names(&self.added, &self.install_names, &keep)
    }
}

/// Fold one `-S` install step's result into the supervisor's [`InstallStep`]
/// (contract §E rows → §G.1 classes):
///
/// * any `refuse` row → `Halt { install-refused <first refuse reason>, stop
///   dispatch }` — the refusal class (§G.1 rc 3; rule 25(h) kept the plan
///   pacman-free);
/// * transaction failure / mutex timeout → `Halt install-failed …` — the
///   cone-stop failure class (§G.1 rc 4; rc 1 under `--fail-fast`);
/// * `SudoLost` → `Halt install-failed sudo credential expired …` with
///   dispatch stopped exactly once (§K.3);
/// * otherwise the decision stood: `Done(ok | <skip reason> | <park reason>)`.
pub fn install_step(rows: &[DecisionRow], txn: Option<&TxnOutcome>) -> InstallStep {
    if let Some(first) = rows.iter().find(|r| r.decision == Decision::Refuse) {
        return InstallStep::Halt {
            reason: format!("install-refused {}", first.reason),
            stop_dispatch: true,
        };
    }
    match txn {
        Some(TxnOutcome::Failed { message, .. }) => InstallStep::Halt {
            reason: format!("install-failed {message}"),
            stop_dispatch: false,
        },
        Some(TxnOutcome::MutexTimeout) => InstallStep::Halt {
            reason: "install-failed mutex-timeout".to_string(),
            stop_dispatch: false,
        },
        Some(TxnOutcome::SudoLost) => InstallStep::Halt {
            reason: "install-failed sudo credential expired and cannot be refreshed".to_string(),
            stop_dispatch: true,
        },
        Some(TxnOutcome::Ok) | None => {
            if rows.iter().any(|r| r.decision == Decision::Install) {
                InstallStep::Done("ok".to_string())
            } else if let Some(row) = rows.iter().find(|r| r.decision == Decision::Skip) {
                InstallStep::Done(nonempty_reason(&row.reason, "already-current"))
            } else if let Some(row) = rows.iter().find(|r| r.decision == Decision::Parked) {
                InstallStep::Done(nonempty_reason(&row.reason, "parked"))
            } else if let Some(row) = rows.iter().find(|r| r.decision == Decision::Noop) {
                InstallStep::Done(nonempty_reason(&row.reason, "empty-list"))
            } else {
                InstallStep::Done("ok".to_string())
            }
        }
    }
}

/// The same mapping for `install_built_package`'s `Result` (contract §E.3:
/// `Err` is the "plan failed without a row" class → `refuse plan-failed`).
pub fn install_step_from_result(
    result: Result<(Vec<DecisionRow>, Option<TxnOutcome>), String>,
) -> InstallStep {
    match result {
        Ok((rows, txn)) => install_step(&rows, txn.as_ref()),
        Err(message) => InstallStep::Halt {
            reason: format!("install-refused plan-failed {message}"),
            stop_dispatch: true,
        },
    }
}

fn nonempty_reason(reason: &str, fallback: &str) -> String {
    if reason.is_empty() {
        fallback.to_string()
    } else {
        reason.to_string()
    }
}

/// Outcome rows for a completed `-U` transaction (contract §H.3): install
/// rows carry the transaction's fate (`ok` / `install-failed …`), skip and
/// noop rows keep their decision reason (`already-current`, `empty-list`),
/// and a parked row stays a park (§E.5: parking is never a safety refusal).
/// Refusal rows never reach a transaction (rule 25(h)) but stay total here.
pub fn txn_outcome_rows(rows: &[DecisionRow], txn: &TxnOutcome, dur: i64) -> Vec<OutcomeRow> {
    rows.iter()
        .map(|row| {
            let pkg = record::subject_id(&row.subject);
            match row.decision {
                Decision::Install => {
                    let (status, rc, reason) = match txn {
                        TxnOutcome::Ok => (RowStatus::Succeeded, 0, "ok".to_string()),
                        TxnOutcome::Failed { message, .. } => {
                            (RowStatus::Failed, 1, format!("install-failed {message}"))
                        }
                        TxnOutcome::MutexTimeout => (
                            RowStatus::Failed,
                            1,
                            "install-failed mutex-timeout".to_string(),
                        ),
                        TxnOutcome::SudoLost => (
                            RowStatus::Failed,
                            1,
                            "install-failed sudo credential expired and cannot be refreshed"
                                .to_string(),
                        ),
                    };
                    OutcomeRow {
                        pkg,
                        status,
                        rc: Some(rc),
                        dur: Some(dur),
                        reason,
                    }
                }
                Decision::Skip | Decision::Noop => OutcomeRow {
                    pkg,
                    status: RowStatus::Succeeded,
                    rc: Some(0),
                    dur: None,
                    reason: nonempty_reason(&row.reason, "already-current"),
                },
                Decision::Parked => OutcomeRow {
                    pkg,
                    status: RowStatus::Parked,
                    rc: None,
                    dur: None,
                    reason: nonempty_reason(&row.reason, "parked"),
                },
                Decision::Refuse => OutcomeRow {
                    pkg,
                    status: RowStatus::NeverStarted,
                    rc: None,
                    dur: None,
                    reason: format!("install-refused {}", row.reason),
                },
            }
        })
        .collect()
}

/// Outcome rows for a plan that refused before any `pacman` call (rule
/// 25(h)): refused subjects are `install-refused …` (their own decision
/// reason, or the `overrides` reason keyed by subject), every other row
/// records why the plan stayed pacman-free.
pub fn refusal_outcome_rows(
    rows: &[DecisionRow],
    overrides: &[(String, String)],
    others_reason: &str,
) -> Vec<OutcomeRow> {
    rows.iter()
        .map(|row| {
            let pkg = record::subject_id(&row.subject);
            let reason = if row.decision == Decision::Refuse {
                format!("install-refused {}", row.reason)
            } else if let Some((_, reason)) = overrides
                .iter()
                .find(|(subject, _)| *subject == row.subject)
            {
                format!("install-refused {reason}")
            } else {
                others_reason.to_string()
            };
            OutcomeRow {
                pkg,
                status: RowStatus::NeverStarted,
                rc: None,
                dur: None,
                reason,
            }
        })
        .collect()
}

// ---------------------------------------------------------------------------
// The ABI wave + staged swap (plan-native-pm.md §4.3/§4.5)
// ---------------------------------------------------------------------------

/// One staged-swap transaction's fate (§H.3, per group).
#[derive(Clone, Debug)]
enum GroupFate {
    Landed,
    /// The transaction's failure reason already in `install-failed …` form.
    Failed(String),
    /// A later group after an earlier failure — never transacted.
    Held,
}

/// The recipe id of one candidate ("record matched via recipe dir name"):
/// the recipe directory's name when it names a topology record or a record
/// path, else that name as-is, else the archive's pkgname.
fn candidate_id(graph: &Graph<'_>, candidate: &Candidate, pkgname: &str) -> String {
    let Some(name) = candidate
        .recipe_dir
        .as_deref()
        .and_then(|d| d.file_name())
        .map(|n| n.to_string_lossy().into_owned())
    else {
        return pkgname.to_string();
    };
    if graph.records().iter().any(|r| r.id.as_str() == name) {
        return name;
    }
    if let Some(record) = graph.records().iter().find(|r| {
        std::path::Path::new(&r.path)
            .file_name()
            .map(|f| f.to_string_lossy() == name)
            .unwrap_or(false)
    }) {
        return record.id.as_str().to_string();
    }
    name
}

/// The `-U` wave computation (plan-native-pm.md §4.3): which candidate
/// provider's token moved against its consumers' recorded `:=` tokens, and
/// the swap waves that movement demands. The wave itself is `gsa-abi`'s one
/// planner (record mismatches ∪ content truth ∪ coupled batches,
/// fail-toward-whole-closure when records are missing); this seam only
/// feeds it the candidate tokens (each merged with the recipe's declared
/// `abi-rev=`) and the installed-ELF view. Reads only — pacman-free.
fn compute_swap(
    graph: &Graph<'_>,
    candidates: &[Candidate],
    localdb: &LocalDb,
    state_dir: &Path,
) -> Result<WavePlan, String> {
    let subs = Subscriptions::load(&gsa_abi::subscriptions_path(state_dir))?;
    let view = gsa_install::abi_view(localdb);
    let mut moves: Vec<TokenMove> = Vec::new();
    let mut seen: BTreeSet<String> = BTreeSet::new();
    let mut planned: BTreeSet<String> = BTreeSet::new();
    for candidate in candidates {
        // An unreadable archive stays out of the wave input; the decision
        // seam refuses it by name (rule 25(h)).
        let Ok(info) = read_pkginfo(&candidate.archive) else {
            continue;
        };
        let id = candidate_id(graph, candidate, &info.pkgname);
        planned.insert(id.clone());
        if !seen.insert(id.clone()) {
            continue;
        }
        let rev = graph
            .records()
            .iter()
            .find(|r| r.id.as_str() == id)
            .and_then(|r| gsa_abi::abi_rev_of(&r.tags));
        let Ok(token) = gsa_abi::token_for_archive(&candidate.archive, rev) else {
            continue;
        };
        let recorded = subs.for_provider(&id);
        if recorded.is_empty() || recorded.iter().all(|s| s.token == token.effective) {
            continue;
        }
        moves.push(TokenMove {
            provider: id,
            old: recorded.first().map(|s| s.token.clone()),
            new: token.effective.clone(),
            changed_provides: gsa_abi::provide_drift(&info.pkgname, &info.provides, &view)
                .into_iter()
                .map(|drift| drift.name)
                .collect(),
        });
    }
    if moves.is_empty() {
        return Ok(WavePlan::default());
    }
    Ok(plan_waves(&WaveInputs {
        graph,
        subs: &subs,
        moves: &moves,
        installed: Some(&view),
        planned: &planned,
    }))
}

/// Stage the swap transactions (plan-native-pm.md §4.5): ONE group per wave
/// carrying every wave archive (the provider first), then one leftover
/// group for the non-wave install archives. With no computed wave this is
/// exactly today's single transaction. `Err` carries the §E.3 refusal rows
/// of a wave whose member archive cannot resolve — a wave is never
/// transacted half-covered.
fn stage_groups(
    plan: &WavePlan,
    install_archives: &[(String, PathBuf)],
) -> Result<Vec<Vec<(String, PathBuf)>>, Vec<DecisionRow>> {
    let archive_of = |id: &str| -> Option<PathBuf> {
        install_archives
            .iter()
            .find(|(rid, _)| rid == id)
            .map(|(_, archive)| archive.clone())
    };
    let swap = stage_swap(&plan.waves, &archive_of);
    if !swap.refusals.is_empty() {
        return Err(swap.refusals);
    }
    let id_of = |archive: &Path| -> Option<String> {
        install_archives
            .iter()
            .find(|(_, a)| a == archive)
            .map(|(id, _)| id.clone())
    };
    let mut groups: Vec<Vec<(String, PathBuf)>> = swap
        .transactions
        .iter()
        .map(|group| {
            group
                .iter()
                .filter_map(|archive| id_of(archive).map(|id| (id, archive.clone())))
                .collect()
        })
        .collect();
    // Split outputs beyond `stage_swap`'s one-archive-per-id contract join
    // their wave's group; everything else rides the leftover group.
    let mut leftover: Vec<(String, PathBuf)> = Vec::new();
    for (id, archive) in install_archives {
        if groups.iter().any(|g| g.iter().any(|(_, a)| a == archive)) {
            continue;
        }
        let wave = plan
            .waves
            .iter()
            .position(|w| w.provider == *id || w.members.iter().any(|m| &m.id == id));
        match wave {
            Some(wi) if wi < groups.len() => groups[wi].push((id.clone(), archive.clone())),
            _ => leftover.push((id.clone(), archive.clone())),
        }
    }
    if !leftover.is_empty() {
        groups.push(leftover);
    }
    Ok(groups)
}

/// Outcome rows for a grouped staged swap (§H.3 per group): install rows
/// carry their group's fate (`ok` / `install-failed …` / held after an
/// earlier failure), every other row keeps its decision mapping.
fn grouped_txn_outcome_rows(
    paired: &[(DecisionRow, Option<Candidate>)],
    fates: &BTreeMap<PathBuf, GroupFate>,
    dur: i64,
) -> Vec<OutcomeRow> {
    paired
        .iter()
        .map(|(row, candidate)| {
            let pkg = record::subject_id(&row.subject);
            if row.decision != Decision::Install {
                return txn_outcome_rows(std::slice::from_ref(row), &TxnOutcome::Ok, dur)
                    .into_iter()
                    .next()
                    .expect("one row in, one row out");
            }
            let fate = candidate
                .as_ref()
                .and_then(|c| fates.get(&c.archive))
                .unwrap_or(&GroupFate::Held);
            let (status, rc, reason) = match fate {
                GroupFate::Landed => (RowStatus::Succeeded, Some(0), "ok".to_string()),
                GroupFate::Failed(message) => (RowStatus::Failed, Some(1), message.to_string()),
                GroupFate::Held => (
                    RowStatus::NeverStarted,
                    None,
                    "held-after-install-failed".to_string(),
                ),
            };
            OutcomeRow {
                pkg,
                status,
                rc,
                dur: if matches!(fate, GroupFate::Held) {
                    None
                } else {
                    Some(dur)
                },
                reason,
            }
        })
        .collect()
}

/// The wave's same-version-skip suppression set (plan §4.5): the wave's
/// provider and members, in recipe ids AND the names the decision seam's
/// name chain carries (pkgbase/pkgname of the candidate archives).
fn wave_heal_names(graph: &Graph<'_>, plan: &WavePlan, candidates: &[Candidate]) -> Vec<String> {
    let mut ids: BTreeSet<String> = BTreeSet::new();
    for wave in &plan.waves {
        ids.insert(wave.provider.clone());
        ids.extend(wave.members.iter().map(|m| m.id.clone()));
    }
    let mut names = ids.clone();
    for candidate in candidates {
        let Ok(info) = read_pkginfo(&candidate.archive) else {
            continue;
        };
        if ids.contains(&candidate_id(graph, candidate, &info.pkgname)) {
            names.insert(info.pkgbase);
            names.insert(info.pkgname);
        }
    }
    names.into_iter().collect()
}

/// The transaction's reason vocabulary (§H.3), shared by the group fates.
fn txn_reason(txn: &TxnOutcome) -> GroupFate {
    match txn {
        TxnOutcome::Ok => GroupFate::Landed,
        TxnOutcome::Failed { message, .. } => {
            GroupFate::Failed(format!("install-failed {message}"))
        }
        TxnOutcome::MutexTimeout => GroupFate::Failed("install-failed mutex-timeout".to_string()),
        TxnOutcome::SudoLost => GroupFate::Failed(
            "install-failed sudo credential expired and cannot be refreshed".to_string(),
        ),
    }
}

// ---------------------------------------------------------------------------
// gsa -U (contract §B.6)
// ---------------------------------------------------------------------------

/// One input of a `-U` plan, in the order the user named it (or canonical
/// recipe order under `-Ua`).
enum Item {
    /// An explicit archive path argument: a candidate directly, with the
    /// archive's parent as its recipe directory.
    Direct(Candidate),
    /// A resolved reference: one recipe's discovered archive set.
    Recipe(Vec<Candidate>),
    /// Fail-closed discovery trouble (rule 25(h)): synthesized `refuse` rows.
    Rejected(Vec<DecisionRow>),
}

/// `gsa -U <ref…|archive…>`, `gsa -Ua`, `gsa -Uf` (contract §B.6): install
/// named archives/refs from disk in one transaction; nothing is built.
/// Returns the process exit code (§G.1).
pub fn run_upgrade(inv: &Invocation, out: &mut dyn Write, err: &mut dyn Write) -> i32 {
    let all = inv.modifiers.contains(&'a');
    if all && !inv.targets.is_empty() {
        let _ = writeln!(
            err,
            "gsa: -Ua installs the whole workspace and takes no targets"
        );
        return 2;
    }
    if !inv.ranges.is_empty() {
        let _ = writeln!(
            err,
            "gsa: index ranges address an -S/-B selection (see 'gsa -Sl')"
        );
        return 2;
    }
    if !all && inv.targets.is_empty() {
        let _ = writeln!(err, "gsa: selection resolved to no packages");
        return 2;
    }

    // ── workspace, topology (usage class: rc 2) ─────────────────────────
    let root = match crate::resolve_workspace(inv) {
        Ok(root) => root,
        Err(message) => {
            let _ = writeln!(err, "gsa: {message}");
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

    // ── privilege gate (contract §B.10; after every usage preflight) ─────
    if let Some(code) = crate::privilege_gate(
        &inv.spelling(),
        crate::invocation_privilege(inv, &crate::Command::Upgrade),
        true,
        err,
    ) {
        return code;
    }

    // ── items in plan order: archives, discovered sets, refusals ─────────
    let mut items: Vec<Item> = Vec::new();
    if all {
        for record in graph.records() {
            let recipe_dir = root.join(&record.path);
            match discover_recipe(&recipe_dir) {
                Ok(found) => {
                    if found.candidates.is_empty() {
                        // Not eligible: the recipe has no archives at all
                        // (`-Ua` installs the workspace's built archives).
                        continue;
                    }
                    if !found.missing.is_empty() || found.mixed_versions {
                        items.push(Item::Rejected(vec![partial_set_row(
                            record.id.as_str(),
                            &recipe_dir,
                            &found.missing,
                            found.mixed_versions,
                        )]));
                    } else {
                        items.push(Item::Recipe(found.candidates));
                    }
                }
                Err(message) => items.push(Item::Rejected(vec![DecisionRow {
                    subject: record.id.as_str().to_string(),
                    decision: Decision::Refuse,
                    reason: format!("discover-failed {message}"),
                }])),
            }
        }
    } else {
        for token in &inv.targets {
            let path = PathBuf::from(token);
            if path.is_file() {
                items.push(Item::Direct(Candidate {
                    recipe_dir: path.parent().map(|p| p.to_path_buf()),
                    archive: path,
                }));
                continue;
            }
            if token.ends_with(".pkg.tar.zst") {
                let _ = writeln!(err, "gsa: malformed archive argument '{token}'");
                return 2;
            }
            let (found, notes) = match select::resolve_ref(&ctx, token, 0) {
                Ok(found) => found,
                Err(error) => {
                    let _ = writeln!(err, "gsa: {error}");
                    return 2;
                }
            };
            crate::write_notes(err, &notes);
            for idx in found {
                let record = graph.record(idx);
                let recipe_dir = root.join(&record.path);
                match discover_recipe(&recipe_dir) {
                    Ok(found) => {
                        if !found.missing.is_empty() || found.mixed_versions {
                            items.push(Item::Rejected(vec![partial_set_row(
                                record.id.as_str(),
                                &recipe_dir,
                                &found.missing,
                                found.mixed_versions,
                            )]));
                        } else {
                            items.push(Item::Recipe(found.candidates));
                        }
                    }
                    Err(message) => items.push(Item::Rejected(vec![DecisionRow {
                        subject: record.id.as_str().to_string(),
                        decision: Decision::Refuse,
                        reason: format!("discover-failed {message}"),
                    }])),
                }
            }
        }
    }

    // ── the one decision seam (contract §E.1) ────────────────────────────
    let mut candidates: Vec<Candidate> = items
        .iter()
        .flat_map(|item| match item {
            Item::Direct(candidate) => vec![candidate.clone()],
            Item::Recipe(candidates) => candidates.clone(),
            Item::Rejected(_) => Vec::new(),
        })
        .collect();
    // `-Ua` is force inherently (no same-version skip), matching today's
    // `-ia`; `-Uf` forces too (§B.6).
    let mode = if all || inv.modifiers.contains(&'f') {
        DecideMode::Force
    } else {
        DecideMode::Checked
    };

    // ── the ABI wave + staged swap (plan-native-pm.md §4.3/§4.5) ────────
    // BEFORE the decision seam (§E.3): a candidate provider whose token
    // moved against its consumers' recorded `:=` tokens drags its consumer
    // wave into this plan — the additions become candidates and each wave
    // stages into ONE `pacman -U` carrying all of its archives. Under-
    // coverage refuses pacman-free (rc 3). `-Ua` is exempt: it installs
    // the whole workspace, so its single transaction already carries every
    // consumer (contract §B.6).
    let state_dir = match state_dir_of(inv) {
        Ok(dir) => dir,
        Err(message) => {
            let _ = writeln!(err, "gsa: {message}");
            return 2;
        }
    };
    let log_dir = state_dir.join("logs");
    let db_root = pacman_db_root();
    let localdb = match LocalDb::load(&db_root) {
        Ok(localdb) => localdb,
        Err(message) => {
            return finish_refused(
                inv,
                out,
                err,
                vec![plan_failed_row(&message)],
                &[],
                "refused-plan-pacman-free",
                &log_dir,
            );
        }
    };
    let swap_plan = if all {
        WavePlan::default()
    } else {
        match compute_swap(&graph, &candidates, &localdb, &state_dir) {
            Ok(plan) => plan,
            Err(message) => {
                return finish_refused(
                    inv,
                    out,
                    err,
                    vec![plan_failed_row(&message)],
                    &[],
                    "refused-plan-pacman-free",
                    &log_dir,
                );
            }
        }
    };
    if !swap_plan.uncovered.is_empty() {
        return finish_refused(
            inv,
            out,
            err,
            swap_plan.refusal_rows(),
            &[],
            "refused-plan-pacman-free",
            &log_dir,
        );
    }
    // Wave members the user did not name join the plan as candidates —
    // their archive sets must resolve, or the wave cannot land wholly and
    // the member is named `refuse abi-consumer-uncovered` (§E.3).
    for id in &swap_plan.additions {
        let provider = swap_plan
            .waves
            .iter()
            .find(|w| w.members.iter().any(|m| &m.id == id))
            .map(|w| w.provider.clone())
            .unwrap_or_else(|| "-".to_string());
        let recipe_dir = match graph.index_of(id) {
            Some(idx) => root.join(&graph.record(idx).path),
            None => {
                items.push(Item::Rejected(vec![gsa_abi::abi_uncovered_row(
                    &provider, id,
                )]));
                continue;
            }
        };
        match discover_recipe(&recipe_dir) {
            Ok(found)
                if !found.candidates.is_empty()
                    && found.missing.is_empty()
                    && !found.mixed_versions =>
            {
                items.push(Item::Recipe(found.candidates));
            }
            _ => items.push(Item::Rejected(vec![gsa_abi::abi_uncovered_row(
                &provider, id,
            )])),
        }
    }
    candidates = items
        .iter()
        .flat_map(|item| match item {
            Item::Direct(candidate) => vec![candidate.clone()],
            Item::Recipe(candidates) => candidates.clone(),
            Item::Rejected(_) => Vec::new(),
        })
        .collect();
    // A wave must land wholly (plan §4.5): its members' (and provider's)
    // same-version skip is suppressed so the swap cannot half-land.
    let wave_heal = wave_heal_names(&graph, &swap_plan, &candidates);
    let decision_ctx = DecisionContext {
        mode,
        empty_list: if mode == DecideMode::Force {
            EmptyListPolicy::Noop
        } else {
            EmptyListPolicy::Refuse
        },
        later_installs: Vec::new(),
        parks: Vec::new(),
        abi_exclusions: workspace_exclusions(&root),
        wave_heal,
    };
    // A plan whose rows already explain themselves — every item rejected
    // before the seam (a shrunken split set, a failed discovery) — never
    // synthesizes the `empty-list` row: §E.3's `empty-list` belongs to a
    // GENUINELY empty candidate plan (a named ref that produced no eligible
    // archive still refuses through it). This is the cutover gap-(a) fix for
    // the phantom `refused empty-list` row of a `-U <ref>` refusal record.
    let self_explaining = candidates.is_empty()
        && !items.is_empty()
        && items.iter().all(|item| matches!(item, Item::Rejected(_)));
    let decided = if self_explaining {
        Vec::new()
    } else {
        match decide(&candidates, &decision_ctx, &localdb) {
            Ok(rows) => rows,
            Err(message) => {
                return finish_refused(
                    inv,
                    out,
                    err,
                    vec![plan_failed_row(&message)],
                    &[],
                    "refused-plan-pacman-free",
                    &log_dir,
                );
            }
        }
    };

    // Splice the seam's rows back into plan order: one row per candidate in
    // candidate order (§E.2), the synthesized refusals where they belong.
    let mut paired: Vec<(DecisionRow, Option<Candidate>)> = Vec::new();
    let mut cursor = 0usize;
    for item in &items {
        match item {
            Item::Direct(candidate) => {
                for row in take_rows(&decided, &mut cursor, 1) {
                    paired.push((row, Some(candidate.clone())));
                }
            }
            Item::Recipe(candidates) => {
                for (row, candidate) in take_rows(&decided, &mut cursor, candidates.len())
                    .into_iter()
                    .zip(candidates.iter().cloned())
                {
                    paired.push((row, Some(candidate)));
                }
            }
            Item::Rejected(rows) => {
                for row in rows.clone() {
                    paired.push((row, None));
                }
            }
        }
    }
    if cursor < decided.len() {
        let _ = writeln!(
            err,
            "gsa: note: {} decision row(s) beyond the candidates — kept in plan order",
            decided.len() - cursor
        );
        for row in &decided[cursor..] {
            paired.push((row.clone(), None));
        }
    }
    let rows: Vec<DecisionRow> = paired.iter().map(|(row, _)| row.clone()).collect();
    let plan: Vec<PlanRow> = rows.iter().map(record::decision_plan_row).collect();
    note_subject_substitutions(&rows, err);

    // ── --dry-run: the rows and the record, execute nothing (§B.8) ──────
    if inv.dry_run {
        let _ = write!(out, "{}", render_rows(&rows));
        let outcomes = rows
            .iter()
            .map(|row| OutcomeRow {
                pkg: record::subject_id(&row.subject),
                status: RowStatus::NeverStarted,
                rc: None,
                dur: None,
                reason: "dry-run".to_string(),
            })
            .collect();
        let run_outcome = RunOutcome {
            outcome: "planned",
            rc: 0,
        };
        let record = record::build_txn_record(inv, &inv.targets, plan, outcomes, &run_outcome);
        // A dry run executes nothing: the install-time QA report surface
        // (contract §E.4) belongs to a run that reached its record finish.
        let _ = write!(
            out,
            "{}",
            render::render_run_prose(&record, &log_dir, &[], None)
        );
        let _ = write!(out, "{}", record.render_machine());
        return 0;
    }

    // ── a refusing plan is pacman-free end to end (rule 25(h)) ──────────
    if rows.iter().any(|row| row.decision == Decision::Refuse) {
        return finish_refused(
            inv,
            out,
            err,
            rows.clone(),
            &[],
            "refused-plan-pacman-free",
            &log_dir,
        );
    }

    // ── preflight, run lock (§K.3) ──────────────────────────────────────
    if let Err(message) = preflight_installs() {
        let _ = writeln!(err, "gsa: {message}");
        let outcomes = rows
            .iter()
            .map(|row| OutcomeRow {
                pkg: record::subject_id(&row.subject),
                status: RowStatus::NeverStarted,
                rc: None,
                dur: None,
                reason: "preflight-refused".to_string(),
            })
            .collect();
        return finish_record(inv, out, err, plan, outcomes, true, false, &log_dir);
    }
    if let Err(message) = gsa_sched::lock::ensure_state_dirs(&state_dir, err) {
        let _ = writeln!(err, "gsa: {message}");
        return finish_refused(
            inv,
            out,
            err,
            rows.clone(),
            &[],
            "startup-refused",
            &log_dir,
        );
    }
    let run_id = gsa_sched::supervisor::run_id_now();
    let _run_lock = match gsa_sched::lock::acquire_run_lock(&state_dir) {
        Ok(lock) => lock,
        Err(message) => {
            let _ = writeln!(err, "gsa: {message}");
            return finish_refused(
                inv,
                out,
                err,
                rows.clone(),
                &[],
                "startup-refused",
                &log_dir,
            );
        }
    };

    // ── dynamic IgnorePkg registration (rule 9) ─────────────────────────
    let conf = inv
        .config
        .as_ref()
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(DEFAULT_CONF));
    let register = !inv
        .deferred_flags
        .iter()
        .any(|f| f == "--no-register-ignorepkg");
    // The registration's write set, kept for the failed-transaction
    // rollback (rule 9's complement): what this run added, split by
    // transaction role.
    let mut registered: Option<RegisteredNames> = None;
    if !register {
        let _ = writeln!(
            err,
            "gsa: note: --no-register-ignorepkg: skipping the dynamic IgnorePkg registration"
        );
    } else {
        // Names for every ACCEPTED archive (install AND skip rows — rule 9),
        // partitioned the way the rollback below needs them.
        let mut names: BTreeSet<String> = BTreeSet::new();
        let mut install_names: BTreeSet<String> = BTreeSet::new();
        let mut skip_names: BTreeSet<String> = BTreeSet::new();
        let mut archive_names: Vec<(PathBuf, Vec<String>)> = Vec::new();
        let mut accepted: Vec<String> = Vec::new();
        for (row, candidate) in &paired {
            if !matches!(row.decision, Decision::Install | Decision::Skip) {
                continue;
            }
            let Some(candidate) = candidate else { continue };
            let pkginfo = read_pkginfo(&candidate.archive).ok();
            match names_for_archive(pkginfo.as_ref(), candidate.recipe_dir.as_deref()) {
                Ok(found) => {
                    if row.decision == Decision::Install {
                        install_names.extend(found.iter().cloned());
                        archive_names.push((candidate.archive.clone(), found.clone()));
                    } else {
                        skip_names.extend(found.iter().cloned());
                    }
                    names.extend(found);
                    accepted.push(row.subject.clone());
                }
                Err(message) => {
                    let _ = writeln!(
                        err,
                        "gsa: install-refused names-unestablished {}: {message}",
                        row.subject
                    );
                    let overrides = vec![(
                        row.subject.clone(),
                        format!("names-unestablished {message}"),
                    )];
                    return finish_refused(
                        inv,
                        out,
                        err,
                        rows.clone(),
                        &overrides,
                        "refused-plan-pacman-free",
                        &log_dir,
                    );
                }
            }
        }
        let names: Vec<String> = names.into_iter().collect();
        let subject_label = accepted.join(",");
        let subject_label = if subject_label.is_empty() {
            "transaction".to_string()
        } else {
            subject_label
        };
        match register_ignorepkg(&conf, &subject_label, &names, &db_root) {
            Ok(report) => {
                let _ = writeln!(
                    err,
                    "gsa: note: {}",
                    register_report_line(&subject_label, &conf, &report)
                );
                // The exact write set (`added`) — the only names the
                // rollback below may ever un-register.
                registered = Some(RegisteredNames {
                    added: report.added,
                    install_names: install_names.into_iter().collect(),
                    archive_names,
                    skip_names: skip_names.into_iter().collect(),
                });
            }
            Err(message) => {
                let _ = writeln!(err, "gsa: install-refused register-failed: {message}");
                let overrides: Vec<(String, String)> = accepted
                    .iter()
                    .map(|subject| (subject.clone(), format!("register-failed {message}")))
                    .collect();
                return finish_refused(
                    inv,
                    out,
                    err,
                    rows.clone(),
                    &overrides,
                    "refused-plan-pacman-free",
                    &log_dir,
                );
            }
        }
    }

    // ── the staged transactions (§K.3, plan §4.5): ONE `pacman -U` per
    //    wave carrying ALL of the wave's archives (the provider first),
    //    then the leftover group for the non-wave install archives. With
    //    no wave computed this is exactly today's single transaction ─────
    let install_archives: Vec<(String, PathBuf)> = paired
        .iter()
        .filter(|(row, candidate)| row.decision == Decision::Install && candidate.is_some())
        .map(|(row, candidate)| {
            let candidate = candidate.as_ref().expect("checked");
            let id = read_pkginfo(&candidate.archive)
                .map(|info| candidate_id(&graph, candidate, &info.pkgname))
                .unwrap_or_else(|_| record::subject_id(&row.subject).as_str().to_string());
            (id, candidate.archive.clone())
        })
        .collect();
    let groups = match stage_groups(&swap_plan, &install_archives) {
        Ok(groups) => groups,
        Err(refusals) => {
            // A wave that cannot land wholly is a refusal (§E.3) — and a
            // refusing plan is pacman-free end to end (rule 25(h)). Nothing
            // transacted, so every name this run registered is uninstalled:
            // rule 9's complement prunes the whole write set (nothing has a
            // `Landed` fate yet).
            if let Some(registered) = &registered {
                rollback_uninstalled(err, &conf, &db_root, registered, &BTreeMap::new());
            }
            let mut all_rows = rows.clone();
            all_rows.extend(refusals);
            return finish_refused(
                inv,
                out,
                err,
                all_rows,
                &[],
                "refused-plan-pacman-free",
                &log_dir,
            );
        }
    };
    let started = Instant::now();
    let mut fates: BTreeMap<PathBuf, GroupFate> = BTreeMap::new();
    let mut interrupted = false;
    let mut signal = 0;
    let mut halted = false;
    for group in &groups {
        let archives: Vec<PathBuf> = group.iter().map(|(_, archive)| archive.clone()).collect();
        let fate = if halted {
            // An earlier group failed: this one never starts (§H.3).
            GroupFate::Held
        } else {
            let request = TxnRequest {
                state_dir: state_dir.clone(),
                conf: Some(conf.clone()),
                archives: archives.clone(),
                pacman_args: inv.pacman_args.clone().unwrap_or_default(),
            };
            let (txn, was_interrupted, sig) =
                execute_supervised(&request, &state_dir, &run_id, out, err);
            if was_interrupted {
                interrupted = true;
                signal = sig;
                break;
            }
            let fate = txn_reason(&txn);
            if !matches!(fate, GroupFate::Landed) {
                halted = true;
            }
            fate
        };
        for archive in &archives {
            fates.insert(archive.clone(), fate.clone());
        }
    }
    let dur = started.elapsed().as_secs() as i64;

    // Rule 9's complement: whatever did not land — a failed transaction, a
    // group held behind one, or (an interrupt) a group that never started
    // or whose in-flight transaction the teardown tore down (its fate is
    // never recorded) — must never leave names registered that pacman did
    // not install, or future `-Syu` silently skips them forever. The landed
    // waves keep theirs: they ARE installed. A hard crash between the
    // registration and this point stays the accepted residual — the dated
    // pre-image backup (`<conf>.bak-<YYYYMMDD>`) is the manual recovery.
    if let Some(registered) = &registered {
        rollback_uninstalled(err, &conf, &db_root, registered, &fates);
    }

    // ── record the `:=` subscriptions of what landed (plan §4.1) ─────────
    // Loud on failure, never aborting: the wave planner fails toward
    // whole-closure on missing records (never under).
    for (row, candidate) in &paired {
        if row.decision != Decision::Install {
            continue;
        }
        let Some(candidate) = candidate else { continue };
        if !matches!(fates.get(&candidate.archive), Some(GroupFate::Landed)) {
            continue;
        }
        let Ok(info) = read_pkginfo(&candidate.archive) else {
            continue;
        };
        let id = candidate_id(&graph, candidate, &info.pkgname);
        if let Err(error) = gsa_install::record_subscriptions(
            &state_dir,
            &id,
            &info.version,
            &candidate.archive,
            &localdb,
        ) {
            let _ = writeln!(
                err,
                "gsa: note: subscription record failed for {id}: {error} (wave planning will fail toward whole-closure)"
            );
        }
    }

    if interrupted {
        // §I.3: the full record still runs; the run exits 130.
        let signal_code = signals::signal_lane_code(signal);
        let outcomes = rows
            .iter()
            .map(|row| {
                let pkg = record::subject_id(&row.subject);
                if row.decision == Decision::Install {
                    OutcomeRow {
                        pkg,
                        status: RowStatus::Interrupted,
                        rc: Some(signal_code),
                        dur: None,
                        reason: "interrupted-mid-build".to_string(),
                    }
                } else {
                    OutcomeRow {
                        pkg,
                        status: RowStatus::NeverStarted,
                        rc: None,
                        dur: None,
                        reason: "interrupted-before-start".to_string(),
                    }
                }
            })
            .collect();
        return finish_record(inv, out, err, plan, outcomes, false, true, &log_dir);
    }

    let outcomes = grouped_txn_outcome_rows(&paired, &fates, dur);
    finish_record(inv, out, err, plan, outcomes, false, false, &log_dir)
}

/// One `refuse` row for the "plan failed without a row" class (§E.3).
fn plan_failed_row(message: &str) -> DecisionRow {
    DecisionRow {
        subject: "-".to_string(),
        decision: Decision::Refuse,
        reason: format!("plan-failed {message}"),
    }
}

/// The fail-closed `partial-set` refusal of one discovered recipe (rule
/// 25(h): a shrunken set is never installed).
fn partial_set_row(
    subject: &str,
    recipe_dir: &Path,
    missing: &[String],
    mixed_versions: bool,
) -> DecisionRow {
    let mut reason = format!("partial-set {}", recipe_dir.display());
    for name in missing {
        reason.push(' ');
        reason.push_str(name);
    }
    if mixed_versions {
        reason.push_str(" mixed-versions");
    }
    DecisionRow {
        subject: subject.to_string(),
        decision: Decision::Refuse,
        reason,
    }
}

/// Take up to `n` rows from the seam's output (one row per candidate, §E.2).
fn take_rows(rows: &[DecisionRow], cursor: &mut usize, n: usize) -> Vec<DecisionRow> {
    let end = (*cursor + n).min(rows.len());
    let taken = rows[*cursor..end].to_vec();
    *cursor = end;
    taken
}

fn note_subject_substitutions(rows: &[DecisionRow], err: &mut dyn Write) {
    for row in rows {
        if RecipeId::new(&row.subject).is_err() {
            let _ = writeln!(
                err,
                "gsa: note: decision row subject '{}' is not a recipe id — recorded as '{}'",
                row.subject,
                record::subject_id(&row.subject)
            );
        }
    }
}

/// The state root of a run (contract §J.3): `--state-dir` beats
/// `GSA_STATE_DIR` beats the gsa.conf layers beats `/var/lib/gsa`; never a
/// silent workspace fallback. Run entries resolve this fail-fast (rc 2 on a
/// malformed config); record emission uses `record_state_dir`.
pub(crate) fn state_dir_of(inv: &Invocation) -> Result<PathBuf, String> {
    gsa_model::config::resolve_state_dir(inv.state_dir.as_deref())
}

/// The state root for best-effort record persistence: a config error here
/// is loud but cannot stop the rendering (the run entries already failed
/// fast on the same error before any record exists), so it falls back to
/// the built-in root with a note.
pub(crate) fn record_state_dir(inv: &Invocation, err: &mut dyn std::io::Write) -> PathBuf {
    match state_dir_of(inv) {
        Ok(dir) => dir,
        Err(message) => {
            let _ = writeln!(err, "gsa: note: {message}");
            PathBuf::from(gsa_model::config::DEFAULT_STATE_DIR)
        }
    }
}

/// Finish a refused run (contract §G.1 rc 3): the record is still emitted
/// (§H.1) and the run is pacman-free end to end (rule 25(h)). Refused
/// subjects carry `install-refused …`; everything else records why the plan
/// stayed pacman-free.
fn finish_refused(
    inv: &Invocation,
    out: &mut dyn Write,
    err: &mut dyn Write,
    rows: Vec<DecisionRow>,
    overrides: &[(String, String)],
    others: &str,
    log_dir: &Path,
) -> i32 {
    let outcomes = refusal_outcome_rows(&rows, overrides, others);
    let plan: Vec<PlanRow> = rows.iter().map(record::decision_plan_row).collect();
    finish_record(inv, out, err, plan, outcomes, true, false, log_dir)
}

/// Render the one run record three ways (§H) and return its rc. The machine
/// block and the side-car run history are one emission (§H.1's amendment).
fn finish_record(
    inv: &Invocation,
    out: &mut dyn Write,
    err: &mut dyn Write,
    plan: Vec<PlanRow>,
    outcomes: Vec<OutcomeRow>,
    refused: bool,
    interrupted: bool,
    log_dir: &Path,
) -> i32 {
    let run_outcome = RunOutcome::compute(&outcomes, inv.fail_fast, interrupted, refused);
    // The install-time QA report surface (contract §E.4): every
    // report-severity check over the run's subjects, appended to the prose
    // summary (prose-only — the §H.2 choice in `gsa-qa::report`). It never
    // touches the decision rows above: those were computed once, by the one
    // decision seam (rule 20).
    // Unique subjects (a multi-row candidate is one QA subject), first
    // appearance order.
    let mut qa_targets: Vec<String> = Vec::new();
    for row in &plan {
        let target = row.pkg.as_str().to_string();
        if !qa_targets.contains(&target) {
            qa_targets.push(target);
        }
    }
    let qa = crate::qa::report_lines(&qa_targets);
    let record = record::build_txn_record(inv, &inv.targets, plan, outcomes, &run_outcome);
    let _ = write!(
        out,
        "{}",
        render::render_run_prose(&record, log_dir, &[], qa.as_deref())
    );
    let rec_state = record_state_dir(inv, err);
    record::emit_machine_record(out, &record, &rec_state, err);
    run_outcome.rc
}

// ---------------------------------------------------------------------------
// The supervised transaction (contract §K.3, §I.3)
// ---------------------------------------------------------------------------

enum TxnEvent {
    Child(Result<ChildExit, String>),
    Signal(i32),
    GraceExpired,
}

/// Run the ONE `pacman -U` transaction as a child in its own process group:
/// the first signal SIGTERMs that group, a bounded grace window follows
/// (`signals::stop_grace_seconds`), then SIGKILL; a second signal escalates
/// immediately. Returns (transaction outcome, interrupted, signal).
fn execute_supervised(
    request: &TxnRequest,
    state_dir: &Path,
    run_id: &str,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> (TxnOutcome, bool, i32) {
    let result_path = state_dir.join("runs").join(run_id).join("txn.outcome");
    let pipe = match signals::install_handlers() {
        Ok(pipe) => pipe,
        Err(error) => {
            let _ = writeln!(
                err,
                "gsa: note: cannot install signal handlers ({error}) — transaction runs unsupervised"
            );
            return (execute_txn(request), false, 0);
        }
    };
    let forked = match signals::fork_process_group() {
        Ok(forked) => forked,
        Err(error) => {
            return (
                TxnOutcome::Failed {
                    rc: -1,
                    message: format!("cannot fork the transaction child: {error}"),
                },
                false,
                0,
            );
        }
    };
    if let Forked::Child = forked {
        // The child: exactly the executor (rule 20 — never a second
        // transaction path), then an atomic result line for the parent.
        let outcome = execute_txn(request);
        let _ = write_txn_outcome(&result_path, &outcome);
        std::process::exit(0);
    }
    let pid = match forked {
        Forked::Parent { pid } => pid,
        Forked::Child => unreachable!("the child exited above"),
    };

    let (tx, rx) = mpsc::channel::<TxnEvent>();
    {
        let tx = tx.clone();
        std::thread::spawn(move || {
            let _ = tx.send(TxnEvent::Child(signals::wait_child(pid)));
        });
    }
    {
        let tx = tx.clone();
        std::thread::spawn(move || {
            use std::io::Read;
            let mut read = pipe.read;
            let mut buf = [0u8; 64];
            loop {
                match read.read(&mut buf) {
                    Ok(0) | Err(_) => return,
                    Ok(n) => {
                        for byte in &buf[..n] {
                            if tx.send(TxnEvent::Signal(*byte as i32)).is_err() {
                                return;
                            }
                        }
                    }
                }
            }
        });
    }

    let mut interrupted: Option<i32> = None;
    let mut grace_started = false;
    let mut exit: Option<Result<ChildExit, String>> = None;
    loop {
        match rx.recv_timeout(Duration::from_secs(3600)) {
            Ok(TxnEvent::Child(status)) => {
                exit = Some(status);
                break;
            }
            Ok(TxnEvent::Signal(sig)) => {
                let _ = writeln!(out, "signal {sig}");
                if interrupted.is_none() {
                    interrupted = Some(sig);
                    let _ = writeln!(
                        out,
                        "teardown one SIGTERM to the transaction group, shared grace window"
                    );
                    signals::signal_group(pid, signals::SIGTERM);
                    if !grace_started {
                        grace_started = true;
                        let tx = tx.clone();
                        let grace = signals::stop_grace_seconds();
                        std::thread::spawn(move || {
                            std::thread::sleep(Duration::from_secs(grace));
                            let _ = tx.send(TxnEvent::GraceExpired);
                        });
                    }
                } else {
                    let _ = writeln!(out, "teardown second signal — SIGKILL sweep");
                    signals::signal_group(pid, signals::SIGKILL);
                }
            }
            Ok(TxnEvent::GraceExpired) => {
                if interrupted.is_some() && exit.is_none() {
                    let _ = writeln!(out, "teardown grace expired — SIGKILL sweep");
                    signals::signal_group(pid, signals::SIGKILL);
                }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => continue,
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }

    if let Some(sig) = interrupted {
        // The teardown owns the rows (§I.3): exit 130 with the full record.
        return (TxnOutcome::Ok, true, sig);
    }
    let exit = exit.unwrap_or(Err("transaction child vanished".to_string()));
    match read_txn_outcome(&result_path) {
        Some(outcome) => (outcome, false, 0),
        None => {
            let message = match exit {
                Ok(ChildExit::Exited(rc)) => {
                    format!("transaction child exited {rc} without a result")
                }
                Ok(ChildExit::Signaled(sig)) => {
                    format!("transaction child died on signal {sig} without a result")
                }
                Err(error) => error,
            };
            (TxnOutcome::Failed { rc: -1, message }, false, 0)
        }
    }
}

/// The child's result line, written atomically (temp + rename) so an
/// interrupt never leaves a half-written outcome behind (§F.2 discipline).
fn write_txn_outcome(path: &Path, outcome: &TxnOutcome) -> std::io::Result<()> {
    let line = match outcome {
        TxnOutcome::Ok => "ok".to_string(),
        TxnOutcome::Failed { rc, message } => format!("failed {rc} {message}"),
        TxnOutcome::MutexTimeout => "mutex-timeout".to_string(),
        TxnOutcome::SudoLost => "sudo-lost".to_string(),
    };
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let temp = path.with_extension(format!("tmp.{}", std::process::id()));
    std::fs::write(&temp, format!("{line}\n"))?;
    std::fs::rename(&temp, path)
}

/// Parse the child's result line back into the outcome vocabulary.
fn read_txn_outcome(path: &Path) -> Option<TxnOutcome> {
    let content = std::fs::read_to_string(path).ok()?;
    let line = content.trim_end();
    let (head, rest) = line.split_once(' ').unwrap_or((line, ""));
    match head {
        "ok" => Some(TxnOutcome::Ok),
        "mutex-timeout" => Some(TxnOutcome::MutexTimeout),
        "sudo-lost" => Some(TxnOutcome::SudoLost),
        "failed" => {
            let (rc, message) = rest.split_once(' ').unwrap_or((rest, "pacman -U failed"));
            Some(TxnOutcome::Failed {
                rc: rc.parse().unwrap_or(-1),
                message: message.to_string(),
            })
        }
        _ => None,
    }
}

/// The one-line registration report (the `--install-register` seam prints it).
fn register_report_line(subject: &str, conf: &Path, report: &RegisterReport) -> String {
    if report.skipped {
        return format!("{subject}: IgnorePkg registration skipped");
    }
    let backup = report
        .backup
        .as_ref()
        .map(|p| format!(" (backup {})", p.display()))
        .unwrap_or_default();
    format!(
        "{subject}: registered {} IgnorePkg name(s) into {}{backup}",
        report.added.len(),
        conf.display()
    )
}

/// Roll back one `-U` run's uninstalled IgnorePkg registrations (rule 9's
/// complement) through the same computation and writer as the `-S` step. A
/// hard crash between the registration and this point stays the accepted
/// residual — the dated pre-image backup (`<conf>.bak-<YYYYMMDD>`) is the
/// manual recovery.
fn rollback_uninstalled(
    err: &mut dyn Write,
    conf: &Path,
    db_root: &Path,
    registered: &RegisteredNames,
    fates: &BTreeMap<PathBuf, GroupFate>,
) {
    let rollback = registered.names_to_rollback(fates);
    if rollback.is_empty() {
        return;
    }
    match gsa_install::register::prune_ignorepkg(
        conf,
        "rollback: the install transaction did not succeed",
        &rollback,
        db_root,
    ) {
        Ok(pruned) => {
            let _ = writeln!(
                err,
                "gsa: note: rolled back IgnorePkg registration of {} name(s) never installed ({})",
                pruned.removed.len(),
                pruned.removed.join(", ")
            );
        }
        Err(error) => {
            let _ = writeln!(
                err,
                "gsa: warning: IgnorePkg rollback failed in {} ({error}) — {} stay registered although the transaction did not install them (pre-image backup: {}.bak-<YYYYMMDD>)",
                conf.display(),
                rollback.join(", "),
                conf.display()
            );
        }
    }
}

// ---------------------------------------------------------------------------
// Hidden seams (contract §D.1)
// ---------------------------------------------------------------------------

/// `gsa --install-decide <checked|force> <archive…>` (§D.1): the one
/// decision seam's rows on stdout, nothing else — no pacman, sudo, flock or
/// makepkg. By construction this path reaches only `decide_mode`, the
/// local-DB directory read and `decide`; the register/exec modules that
/// spawn processes are never called here.
pub fn run_install_decide(args: &[String], out: &mut dyn Write, err: &mut dyn Write) -> i32 {
    let Some((mode_word, archives)) = args.split_first() else {
        let _ = writeln!(err, "gsa: --install-decide: unreadable argument list");
        return 2;
    };
    let mode = match decide_mode(mode_word) {
        Ok(mode) => mode,
        Err(message) => {
            let _ = writeln!(err, "gsa: {message}");
            return 2;
        }
    };
    if archives.is_empty() {
        let _ = writeln!(err, "gsa: --install-decide: unreadable argument list");
        return 2;
    }
    let mut candidates = Vec::new();
    for archive in archives {
        let path = PathBuf::from(archive);
        if !path.is_file() {
            let _ = writeln!(err, "gsa: malformed archive argument '{archive}'");
            return 2;
        }
        candidates.push(Candidate {
            recipe_dir: path.parent().map(|p| p.to_path_buf()),
            archive: path,
        });
    }
    let ctx = DecisionContext {
        mode,
        empty_list: match mode {
            DecideMode::Checked => EmptyListPolicy::Refuse,
            DecideMode::Force => EmptyListPolicy::Noop,
        },
        later_installs: Vec::new(),
        parks: Vec::new(),
        abi_exclusions: crate::resolve_root(false)
            .ok()
            .as_deref()
            .and_then(workspace_exclusions),
        wave_heal: Vec::new(),
    };
    let rows = match LocalDb::load(&pacman_db_root()) {
        Ok(localdb) => match decide(&candidates, &ctx, &localdb) {
            Ok(rows) => rows,
            Err(message) => vec![plan_failed_row(&message)],
        },
        Err(message) => vec![plan_failed_row(&message)],
    };
    let _ = write!(out, "{}", render_rows(&rows));
    rows_rc(&rows)
}

/// `gsa --install-register <conf> <subject> <names…>` (§D.1): the IgnorePkg
/// registration write path in isolation, including its bounded `db.lck`
/// wait (never a deletion — rule 23).
pub fn run_install_register(args: &[String], out: &mut dyn Write, err: &mut dyn Write) -> i32 {
    if args.len() < 3 {
        let _ = writeln!(
            err,
            "gsa: --install-register: wants <conf> <subject> <names…> (got {} argument(s))",
            args.len()
        );
        return 2;
    }
    let conf = Path::new(&args[0]);
    let subject = &args[1];
    let names = &args[2..];
    // Privilege gate (contract §B.10) AFTER the usage fence — §G.1 ranks
    // usage (2) above refusal (3).
    if let Some(code) = crate::privilege_gate(
        "--install-register",
        crate::Privilege::Root {
            needs_build_user: false,
        },
        false,
        err,
    ) {
        return code;
    }
    match register_ignorepkg(conf, subject, names, &pacman_db_root()) {
        Ok(report) => {
            let _ = writeln!(out, "{}", register_report_line(subject, conf, &report));
            0
        }
        Err(message) => {
            let _ = writeln!(err, "gsa: --install-register: {message}");
            1
        }
    }
}

/// `gsa --register-ignorepkg [conf]` (rule 9): the one-shot backfill of an
/// existing conf from the workspace's pkgbase+pkgname universe, computed
/// from the committed `.SRCINFO`s through `gsa-recipe`'s parsed metadata —
/// never a PKGBUILD grep.
pub fn run_register_ignorepkg(args: &[String], out: &mut dyn Write, err: &mut dyn Write) -> i32 {
    if args.len() > 1 {
        let _ = writeln!(
            err,
            "gsa: --register-ignorepkg: takes at most one <conf> argument (got {})",
            args.len()
        );
        return 2;
    }
    let conf = PathBuf::from(
        args.first()
            .cloned()
            .unwrap_or_else(|| DEFAULT_CONF.to_string()),
    );
    let root = match crate::resolve_root(true) {
        Ok(root) => root,
        Err(message) => {
            let _ = writeln!(err, "gsa: {message}");
            return 2;
        }
    };
    let db = match RecipeDb::load(&root, &[]) {
        Ok(db) => db,
        Err(error) => {
            let _ = writeln!(err, "gsa: {error}");
            return 2;
        }
    };
    // Privilege gate (contract §B.10) AFTER the usage fences — §G.1 ranks
    // usage (2) above refusal (3).
    if let Some(code) = crate::privilege_gate(
        "--register-ignorepkg",
        crate::Privilege::Root {
            needs_build_user: false,
        },
        false,
        err,
    ) {
        return code;
    }
    let mut names: BTreeSet<String> = BTreeSet::new();
    for id in &db.order {
        let Some(meta) = db.get(id.as_str()) else {
            continue;
        };
        match &meta.srcinfo {
            Some(info) => {
                names.insert(
                    info.pkgbase
                        .clone()
                        .unwrap_or_else(|| id.as_str().to_string()),
                );
                names.extend(info.pkgnames.iter().cloned());
            }
            None => {
                names.insert(id.as_str().to_string());
                names.extend(meta.pkgnames());
            }
        }
    }
    let names: Vec<String> = names.into_iter().collect();
    match register_ignorepkg(&conf, "workspace", &names, &pacman_db_root()) {
        Ok(report) => {
            let _ = writeln!(out, "{}", register_report_line("workspace", &conf, &report));
            0
        }
        Err(message) => {
            let _ = writeln!(err, "gsa: --register-ignorepkg: {message}");
            1
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(subject: &str, decision: Decision, reason: &str) -> DecisionRow {
        DecisionRow {
            subject: subject.to_string(),
            decision,
            reason: reason.to_string(),
        }
    }

    #[test]
    fn refuse_rows_halt_as_the_refusal_class() {
        let rows = vec![
            row("a", Decision::Install, "ok"),
            row("b", Decision::Refuse, "pgo-hit .gcda"),
        ];
        match install_step(&rows, Some(&TxnOutcome::Ok)) {
            InstallStep::Halt {
                reason,
                stop_dispatch,
            } => {
                assert_eq!(reason, "install-refused pgo-hit .gcda");
                assert!(stop_dispatch);
            }
            other => panic!("expected halt, got {other:?}"),
        }
    }

    #[test]
    fn transaction_failures_map_to_install_failed_classes() {
        let rows = vec![row("a", Decision::Install, "ok")];
        match install_step(
            &rows,
            Some(&TxnOutcome::Failed {
                rc: 1,
                message: "boom".into(),
            }),
        ) {
            InstallStep::Halt {
                reason,
                stop_dispatch,
            } => {
                assert_eq!(reason, "install-failed boom");
                assert!(!stop_dispatch, "cone-stop keeps dispatching (§G.1 rc 4)");
            }
            other => panic!("expected halt, got {other:?}"),
        }
        match install_step(&rows, Some(&TxnOutcome::MutexTimeout)) {
            InstallStep::Halt { reason, .. } => assert_eq!(reason, "install-failed mutex-timeout"),
            other => panic!("expected halt, got {other:?}"),
        }
        match install_step(&rows, Some(&TxnOutcome::SudoLost)) {
            InstallStep::Halt {
                reason,
                stop_dispatch,
            } => {
                assert!(reason.starts_with("install-failed sudo credential expired"));
                assert!(stop_dispatch, "a lost credential stops dispatch (§K.3)");
            }
            other => panic!("expected halt, got {other:?}"),
        }
    }

    #[test]
    fn settled_decisions_carry_their_reason() {
        assert_eq!(
            install_step(&[row("a", Decision::Install, "ok")], Some(&TxnOutcome::Ok)),
            InstallStep::Done("ok".to_string())
        );
        assert_eq!(
            install_step(
                &[row("a", Decision::Skip, "already-current")],
                Some(&TxnOutcome::Ok)
            ),
            InstallStep::Done("already-current".to_string())
        );
        assert_eq!(
            install_step(&[row("a", Decision::Skip, "already-current")], None),
            InstallStep::Done("already-current".to_string())
        );
        match install_step_from_result(Err("disk on fire".to_string())) {
            InstallStep::Halt {
                reason,
                stop_dispatch,
            } => {
                assert_eq!(reason, "install-refused plan-failed disk on fire");
                assert!(stop_dispatch);
            }
            other => panic!("expected halt, got {other:?}"),
        }
    }

    #[test]
    fn txn_rows_map_rc_per_the_vocabulary() {
        let rows = vec![
            row("a", Decision::Install, "ok"),
            row("b", Decision::Skip, "already-current"),
            row("c", Decision::Parked, "waits-on-deferred"),
        ];
        // Clean transaction: the install row is `succeeded … ok`, the skip
        // row keeps its reason; the park alone is the deferral class (§G.1
        // rc 5).
        let out = txn_outcome_rows(&rows, &TxnOutcome::Ok, 3);
        assert_eq!(out[0].reason, "ok");
        assert_eq!(out[0].dur, Some(3));
        assert_eq!(out[1].reason, "already-current");
        assert_eq!(out[2].status, RowStatus::Parked);
        let outcome = RunOutcome::compute(&out, false, false, false);
        assert_eq!((outcome.outcome, outcome.rc), ("deferral", 5));

        // Failure: cone-stop class 4, fail-fast class 1 (§G.1).
        let out = txn_outcome_rows(
            &rows,
            &TxnOutcome::Failed {
                rc: 1,
                message: "boom".into(),
            },
            3,
        );
        assert_eq!(out[0].status, RowStatus::Failed);
        assert_eq!(out[0].reason, "install-failed boom");
        assert_eq!(RunOutcome::compute(&out, false, false, false).rc, 4);
        assert_eq!(RunOutcome::compute(&out, true, false, false).rc, 1);
    }

    #[test]
    fn refusal_rows_are_pacman_free_and_rc_three() {
        let rows = vec![
            row("a", Decision::Refuse, "partial-set /x missing-pkg"),
            row("b", Decision::Install, "ok"),
        ];
        let out = refusal_outcome_rows(&rows, &[], "refused-plan-pacman-free");
        assert_eq!(out[0].reason, "install-refused partial-set /x missing-pkg");
        assert_eq!(out[1].reason, "refused-plan-pacman-free");
        assert_eq!(RunOutcome::compute(&out, false, false, true).rc, 3);
        // Overridden refusals (names-unestablished / register-failed).
        let out = refusal_outcome_rows(
            &rows,
            &[(
                "b".to_string(),
                "names-unestablished no authority".to_string(),
            )],
            "refused-plan-pacman-free",
        );
        assert_eq!(
            out[1].reason,
            "install-refused names-unestablished no authority"
        );
    }

    #[test]
    fn txn_outcome_round_trips_through_the_result_line() {
        let cases = [
            TxnOutcome::Ok,
            TxnOutcome::MutexTimeout,
            TxnOutcome::SudoLost,
            TxnOutcome::Failed {
                rc: 7,
                message: "pacman said no".to_string(),
            },
        ];
        // Scratch inside the workspace's git-ignored target dir (fixtures
        // use $TMPDIR; a unit test must not write outside the repo).
        let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("target")
            .join("gsa-txn-round-trip");
        let path = dir.join("txn.outcome");
        for outcome in cases {
            write_txn_outcome(&path, &outcome).expect("write outcome");
            assert_eq!(read_txn_outcome(&path), Some(outcome.clone()));
        }
        let _ = std::fs::remove_file(&path);
        let _ = std::fs::remove_dir(&dir);
    }

    fn reg(
        added: &[&str],
        install: &[&str],
        archive_names: &[(&str, &[&str])],
        skip: &[&str],
    ) -> RegisteredNames {
        let strs = |list: &[&str]| -> Vec<String> {
            list.iter().map(|s| s.to_string()).collect()
        };
        RegisteredNames {
            added: strs(added),
            install_names: strs(install),
            archive_names: archive_names
                .iter()
                .map(|(archive, names)| (PathBuf::from(archive), strs(names)))
                .collect(),
            skip_names: strs(skip),
        }
    }

    fn fate_map(rows: &[(&str, GroupFate)]) -> BTreeMap<PathBuf, GroupFate> {
        rows.iter()
            .map(|(archive, fate)| (PathBuf::from(archive), fate.clone()))
            .collect()
    }

    #[test]
    fn rollback_of_a_multi_wave_partial_success_keeps_the_landed_names() {
        // Wave 1 (lib1←app1) landed, wave 2 (lib2←app2) failed and the
        // leftover (solo) was held: only the names that never installed
        // roll back. A name shared by a landed and a failed archive stays
        // too — it IS installed via the landed one.
        let registered = reg(
            &["lib1", "app1", "shared", "lib2", "app2", "solo", "skipper"],
            &["lib1", "app1", "shared", "lib2", "app2", "solo"],
            &[
                ("lib1.arch", &["lib1"]),
                ("app1.arch", &["app1"]),
                ("lib2.arch", &["lib2", "shared"]),
                ("app2.arch", &["app2"]),
                ("solo.arch", &["solo"]),
                ("ok.arch", &["shared"]),
            ],
            &["skipper"],
        );
        let fates = fate_map(&[
            ("lib1.arch", GroupFate::Landed),
            ("app1.arch", GroupFate::Landed),
            ("ok.arch", GroupFate::Landed),
            ("lib2.arch", GroupFate::Failed("install-failed boom".into())),
            ("app2.arch", GroupFate::Failed("install-failed boom".into())),
            ("solo.arch", GroupFate::Held),
        ]);
        let rollback = registered.names_to_rollback(&fates);
        assert_eq!(rollback, vec!["lib2", "app2", "solo"]);
    }

    #[test]
    fn rollback_of_the_interrupt_set_drops_only_what_never_installed() {
        // Interrupt with nothing landed: the whole install-bearing write
        // set rolls back while a skip (already-current) name stays — it IS
        // installed. The interrupted group's fate is never recorded, which
        // is exactly what an empty map (or a map without that archive)
        // expresses.
        let registered = reg(
            &["alpha", "alpha-out", "skipper"],
            &["alpha", "alpha-out"],
            &[("alpha.arch", &["alpha", "alpha-out"])],
            &["skipper"],
        );
        assert_eq!(
            registered.names_to_rollback(&fate_map(&[])),
            vec!["alpha", "alpha-out"]
        );
        // Interrupt mid-multi-wave: the wave that landed keeps its names.
        let registered = reg(
            &["lib1", "app1", "lib2", "app2"],
            &["lib1", "app1", "lib2", "app2"],
            &[
                ("lib1.arch", &["lib1"]),
                ("app1.arch", &["app1"]),
                ("lib2.arch", &["lib2"]),
                ("app2.arch", &["app2"]),
            ],
            &[],
        );
        let fates = fate_map(&[
            ("lib1.arch", GroupFate::Landed),
            ("app1.arch", GroupFate::Landed),
        ]);
        assert_eq!(registered.names_to_rollback(&fates), vec!["lib2", "app2"]);
    }
}
