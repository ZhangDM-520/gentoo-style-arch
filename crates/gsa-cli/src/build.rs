//! Real build execution (`gsa -B <targets…> [ranges…]`, contract §B.5, and
//! `gsa -S <targets…> [ranges…]`, §B.4): the selection runs through
//! `gsa-build` + `gsa-sched` — makepkg children in `exec`'d lane
//! supervisors, topological dispatch over the build-order graph,
//! host-derived budgets (`gsa-sched::budget`, docs/portability.md). `-B` is
//! install-free; `-S` adds the post-build install hook (install-before-
//! dependents, rule 11). Cone-stop is the default failure policy (§I.1);
//! `--fail-fast` is the escape (§I.3).
//!
//! The run record (§H) is computed once after the machine settles and
//! rendered three ways: the streaming dashboard lines during the run
//! ([`render::render_event`]), the prose summary ([`render::render_run_prose`])
//! and the `format: 2` machine block. Exit codes are §G.1's, computed from
//! the same rows (`gsa_model::RunOutcome`).

use std::collections::HashMap;
use std::io::Write;
use std::path::PathBuf;

use gsa_fetch::candidacy::{classify as classify_candidacy, FetchCandidacy};
use gsa_graph::Graph;
use gsa_install::{preflight_installs, DecideMode, InstallRun};
use gsa_model::{Group, OutcomeRow, RecipeId, RowStatus, RunOutcome};
use gsa_recipe::RecipeDb;
use gsa_sched::budget::{self, Baselines, Budget, Override};
use gsa_sched::lock;
use gsa_sched::machine::Policy;
use gsa_sched::supervisor::{self, InstallStep, PrefetchSetup, RunSetup, SupNode};
use gsa_topo::ProjectConfig;

use crate::args::Invocation;
use crate::select::{self, Ctx, Selection};
use crate::{record, render};

/// The five build-run modifiers (§B.8): real on a `-B` build, deferred on
/// every other spelling (the classifier consults this roster). The two
/// fetch-ahead knobs (owner decision 1) ride along.
pub const REAL_BUILD_FLAGS: [&str; 7] = [
    "--fail-fast",
    "--lanes",
    "--jobs",
    "--intensity",
    "--state-dir",
    "--no-prefetch",
    "--prefetch-ahead",
];

/// What a `-S` build+install run additionally accepts (§B.8): the dynamic
/// IgnorePkg registration switch and the target pacman.conf.
pub const REAL_INSTALL_FLAGS: [&str; 9] = [
    "--fail-fast",
    "--lanes",
    "--jobs",
    "--intensity",
    "--state-dir",
    "--no-prefetch",
    "--prefetch-ahead",
    "--no-register-ignorepkg",
    "--config",
];

/// The default state root (contract §J.3): `--state-dir` beats
/// `GSA_STATE_DIR`, and there is never a silent fallback to a workspace
/// directory.
const DEFAULT_STATE_DIR: &str = "/var/lib/gsa";

/// `gsa -B <targets…> [ranges…]` — run the selection build-only. Returns the
/// process exit code (§G.1) and writes every rendering through `out`/`err`.
pub fn run_build(inv: &Invocation, out: &mut dyn Write, err: &mut dyn Write) -> i32 {
    run_build_with(inv, out, err, None)
}

/// `gsa -S <targets…> [ranges…]` (contract §B.4): the build pipeline plus
/// install-before-dependents — each package's archives install through the
/// post-build hook BEFORE any consumer compiles (`docs/MEMORY.md` rule 11).
/// Cluster `f` is force install (no same-version skip); cluster `c` prunes
/// strength 1 first. Trailing `-- <pacman args…>` reach every transaction.
pub fn run_build_install(inv: &Invocation, out: &mut dyn Write, err: &mut dyn Write) -> i32 {
    let mode = if inv.modifiers.contains(&'f') {
        DecideMode::Force
    } else {
        DecideMode::Checked
    };
    run_build_with(inv, out, err, Some(mode))
}

fn run_build_with(
    inv: &Invocation,
    out: &mut dyn Write,
    err: &mut dyn Write,
    install: Option<DecideMode>,
) -> i32 {
    // ── selection is mandatory (contract §B.1) ───────────────────────────
    if inv.targets.is_empty() {
        let _ = writeln!(
            err,
            "gsa: selection is mandatory: a build never starts without a selection"
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
    let project = match gsa_topo::load_project(&root) {
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

    // ── resource budget (host-derived; the parallelism line is the truth) ─
    let budget = match resolve_budget(inv, &project, selection.listed.len()) {
        Ok(budget) => budget,
        Err(message) => {
            let _ = writeln!(err, "gsa: {message}");
            return 2;
        }
    };
    // ── fetch-ahead (owner decision 1): default-on, `--no-prefetch` opt-out ─
    let prefetch_ahead = match resolve_prefetch(inv) {
        Ok(ahead) => ahead,
        Err(message) => {
            let _ = writeln!(err, "gsa: {message}");
            return 2;
        }
    };

    // ── state root (contract §J.3) and startup refusals (§G.1 rc 3) ──────
    let state_dir = inv
        .state_dir
        .as_ref()
        .map(PathBuf::from)
        .or_else(|| {
            std::env::var("GSA_STATE_DIR")
                .ok()
                .filter(|v| !v.is_empty())
                .map(PathBuf::from)
        })
        .unwrap_or_else(|| PathBuf::from(DEFAULT_STATE_DIR));
    // Install preflight (contract §K.3): an install run whose installs
    // cannot succeed non-interactively refuses BEFORE any build (§G.1 rc 3).
    if install.is_some() {
        if let Err(message) = preflight_installs() {
            let _ = writeln!(err, "gsa: {message}");
            return refuse_before_dispatch(
                inv,
                &selection,
                &budget,
                &state_dir,
                out,
                err,
                "preflight-refused",
            );
        }
    }
    if let Err(message) = lock::ensure_state_dirs(&state_dir, err) {
        let _ = writeln!(err, "gsa: {message}");
        return refuse_before_dispatch(
            inv,
            &selection,
            &budget,
            &state_dir,
            out,
            err,
            "startup-refused",
        );
    }
    // The PACMAN shim (§K.3): makepkg's own dependency installs share the
    // transaction lock and run through `sudo -n` — the engine never prompts.
    if let Err(message) = gsa_build::shim::ensure_pacman_shim(&state_dir) {
        let _ = writeln!(err, "gsa: {message}");
        return refuse_before_dispatch(
            inv,
            &selection,
            &budget,
            &state_dir,
            out,
            err,
            "startup-refused",
        );
    }
    let run_id = supervisor::run_id_now();
    let _run_lock = match lock::acquire_run_lock(&state_dir) {
        Ok(lock) => lock,
        Err(message) => {
            let _ = writeln!(err, "gsa: {message}");
            return refuse_before_dispatch(
                inv,
                &selection,
                &budget,
                &state_dir,
                out,
                err,
                "startup-refused",
            );
        }
    };
    // Startup orphan sweep (§K.3): dead runs' lane jobs and stale artifacts.
    lock::sweep_orphans(&state_dir, &run_id, err);

    // ── prune strength 1 first (§B.5 cluster letter `c`) ─────────────────
    if inv.modifiers.contains(&'c') {
        let mut report = gsa_build::clean::CleanReport::default();
        for (_, id) in &selection.listed {
            let record = graph.record(graph.index_of(id.as_str()).expect("selection ids resolve"));
            gsa_build::clean::clean_recipe(&root.join(&record.path), &mut report);
        }
        for removed in &report.removed {
            let _ = writeln!(err, "gsa: note: pruned {removed}");
        }
        for error in &report.errors {
            let _ = writeln!(err, "gsa: {error}");
        }
    }

    // ── dispatch nodes: the selection in canonical build order ────────────
    let nodes = build_nodes(&root, &graph, &selection);
    let batches = build_batches(&graph, &selection);

    let _ = writeln!(out, "{}", budget.parallelism_line());
    let exe = match std::env::current_exe() {
        Ok(exe) => exe,
        Err(error) => {
            let _ = writeln!(
                err,
                "gsa: cannot locate the engine binary for lane children: {error}"
            );
            return refuse_before_dispatch(
                inv,
                &selection,
                &budget,
                &state_dir,
                out,
                err,
                "startup-refused",
            );
        }
    };
    let ids: Vec<RecipeId> = selection.listed.iter().map(|(_, id)| id.clone()).collect();
    // Whether this run installs (the install-time QA report surface rides
    // install runs only — contract §E.4, install-qa-check.d timing).
    let is_install_run = install.is_some();
    // The post-build install hook (install-before-dependents, rule 11):
    // called per package on the supervisor's event loop, before its result
    // reaches the machine. `later_installs` is the run-order remainder
    // (in-run repair coverage, rule 25(d)).
    let install_hook: Option<Box<dyn FnMut(&str, &std::path::Path) -> InstallStep + Send>> =
        install.map(|mode| {
            let state_dir = state_dir.clone();
            let conf = inv.config.as_ref().map(PathBuf::from);
            let pacman_args = inv.pacman_args.clone().unwrap_or_default();
            let register_ignorepkg = !inv
                .deferred_flags
                .iter()
                .any(|f| f == "--no-register-ignorepkg");
            let mut later: Vec<String> = ids.iter().map(|id| id.as_str().to_string()).collect();
            Box::new(move |pkg: &str, recipe_dir: &std::path::Path| {
                later.retain(|subject| subject != pkg);
                let run = InstallRun {
                    mode,
                    state_dir: state_dir.clone(),
                    conf: conf.clone(),
                    pacman_args: pacman_args.clone(),
                    register_ignorepkg,
                    later_installs: later.clone(),
                };
                crate::install::install_step_from_result(gsa_install::install_built_package(
                    recipe_dir, &run,
                ))
            }) as Box<dyn FnMut(&str, &std::path::Path) -> InstallStep + Send>
        });
    // ── the post-build registration hook (contract §J.4) ────────────────
    // Every successful build records its instance in the hash-bound binpkg
    // index and enforces the topology-derived retention budget (N=2 hubs /
    // N=1 elsewhere); the in-flight lane ids the supervisor passes are the
    // guard — pruning never deletes an archive the run is using.
    let retention = gsa_state::Retention::from_graph(&graph);
    let register_hook: Box<
        dyn FnMut(&str, &std::path::Path, &std::collections::BTreeSet<String>) -> Vec<String>
            + Send,
    > = {
        let state_dir = state_dir.clone();
        Box::new(move |pkg, recipe_dir, in_flight| {
            let mut notes = Vec::new();
            let mut gate = Vec::new();
            let outcome = gsa_state::StateRoot::open(&state_dir).and_then(|state| {
                let archives = match gsa_install::discover_recipe(recipe_dir) {
                    Ok(found) => found
                        .candidates
                        .into_iter()
                        .map(|c| c.archive)
                        .collect::<Vec<_>>(),
                    Err(error) => {
                        return Err(gsa_state::StateError::Io(format!(
                            "cannot discover built archives in {} ({error})",
                            recipe_dir.display()
                        )))
                    }
                };
                gsa_state::register_instance(
                    &state, pkg, &archives, &retention, in_flight, &mut gate,
                )
            });
            for line in String::from_utf8_lossy(&gate).lines() {
                notes.push(line.strip_prefix("gsa: note: ").unwrap_or(line).to_string());
            }
            match outcome {
                Ok(done) => notes.extend(done.notes),
                Err(error) => notes.push(format!(
                    "binpkg index: registration failed for {pkg}: {error}"
                )),
            }
            notes
        })
    };
    // ── fetch-ahead setup (owner decisions 1/3/5): the lookahead window's
    // per-node candidacy comes from gsa-recipe's source classification (never
    // grep), and the advisory log is `$STATE_DIR/prefetch.log`, run-scoped
    // and truncated at run start like the run's other state.
    let prefetch_log = state_dir.join("prefetch.log");
    let prefetch = prefetch_ahead.map(|ahead| {
        let candidacy = nodes
            .iter()
            .map(|node| {
                db.get(node.id.as_str())
                    .map(|meta| classify_candidacy(&meta))
                    .unwrap_or(FetchCandidacy::NoFetchable)
            })
            .collect();
        let _ = std::fs::File::create(&prefetch_log);
        PrefetchSetup {
            ahead,
            candidacy,
            log_path: prefetch_log,
        }
    });
    let setup = RunSetup {
        root,
        state_dir: state_dir.clone(),
        run_id: run_id.clone(),
        exe,
        budget,
        policy: if inv.fail_fast {
            Policy::FailFast
        } else {
            Policy::ConeStop
        },
        lane_flags: Vec::new(),
        nodes,
        batches,
        install: install_hook,
        register: Some(register_hook),
        prefetch,
    };

    // ── the run: streaming dashboard lines as the machine settles ─────────
    let outcome = match supervisor::run(
        setup,
        &mut |event| {
            let _ = write!(out, "{}", render::render_event(event, &ids));
        },
        err,
    ) {
        Ok(outcome) => outcome,
        Err(message) => {
            let _ = writeln!(err, "gsa: {message}");
            return refuse_before_dispatch(
                inv,
                &selection,
                &budget,
                &state_dir,
                out,
                err,
                "startup-refused",
            );
        }
    };
    // Post-run orphan sweep (§K.3) — the current run's artifacts survive.
    lock::sweep_orphans(&state_dir, &run_id, err);

    // ── one run record, three renderings (§H) ────────────────────────────
    let rows = outcome.rows;
    let run_outcome =
        RunOutcome::compute(&rows, inv.fail_fast, outcome.interrupted, outcome.refused);
    let parked_by = parked_by(&graph, &rows);
    // The `prefetch-warnings` scalar (owner decision 5): the advisory count
    // of this run's fetch-ahead. `None` when the run had no fetch-ahead
    // participation (`--no-prefetch`) — never rows, never a format bump.
    let prefetch_warnings =
        prefetch_ahead.map(|_| u32::try_from(outcome.prefetch_warnings.len()).unwrap_or(u32::MAX));
    let record = record::build_run_record(
        inv,
        &selection,
        &inv.targets,
        &inv.ranges,
        Some(&budget),
        rows,
        &run_outcome,
        prefetch_warnings,
    );
    // The install-time QA report surface (contract §E.4): report-severity
    // findings over the run's subjects appended to the prose summary
    // (prose-only — the §H.2 choice in `gsa-qa::report`). Install runs only
    // (install-qa-check.d timing); the findings never touch the per-package
    // install decisions, which the one decision seam made (rule 20).
    let qa = if is_install_run {
        let qa_targets: Vec<String> = ids.iter().map(|id| id.as_str().to_string()).collect();
        crate::qa::report_lines(&qa_targets)
    } else {
        None
    };
    let _ = write!(
        out,
        "{}",
        render::render_run_prose(&record, &state_dir.join("logs"), &parked_by, qa.as_deref())
    );
    let _ = write!(
        out,
        "{}",
        render::render_prefetch_notes(&outcome.prefetch_warnings)
    );
    // The machine block AND the side-car run history: the §H.1 amendment
    // stores the same structure, never a fourth derivation.
    record::emit_machine_record(out, &record, &state_dir, err);
    run_outcome.rc
}

/// Fetch-ahead configuration (owner decision 1): prefetch is DEFAULT-ON
/// with `--no-prefetch` opt-out and `--prefetch-ahead N` (default 8). The
/// two flags conflict; a bad N is a usage error naming the flag. `None` is
/// `--no-prefetch`.
fn resolve_prefetch(inv: &Invocation) -> Result<Option<usize>, String> {
    if inv.no_prefetch && inv.prefetch_ahead.is_some() {
        return Err("cannot combine --no-prefetch with --prefetch-ahead".to_string());
    }
    if inv.no_prefetch {
        return Ok(None);
    }
    match &inv.prefetch_ahead {
        Some(raw) => {
            let ahead: usize = raw
                .parse()
                .map_err(|_| format!("--prefetch-ahead: '{raw}' must be a positive integer"))?;
            if ahead == 0 {
                return Err(format!(
                    "--prefetch-ahead: '{raw}' must be a positive integer"
                ));
            }
            Ok(Some(ahead))
        }
        None => Ok(Some(gsa_fetch::window::DEFAULT_PREFETCH_AHEAD)),
    }
}

/// Resolve the host-derived budget (contract §B.8 / docs/portability.md):
/// `--lanes`/`--jobs`/`--intensity` beat their env twins, which beat
/// `config/build-defaults.conf`.
fn resolve_budget(
    inv: &Invocation,
    project: &ProjectConfig,
    package_count: usize,
) -> Result<Budget, String> {
    let intensity = match &inv.intensity {
        Some(value) => value.clone(),
        None => crate::resolve_intensity(project)?,
    };
    let lanes = override_value(inv.lanes.as_deref(), "GSA_LANES", &project.defaults.lanes)?;
    let jobs = override_value(inv.jobs.as_deref(), "GSA_JOBS", &project.defaults.jobs)?;
    let baseline = |raw: &str, name: &str| -> Result<f64, String> {
        raw.trim().parse::<f64>().map_err(|_| {
            format!("config/build-defaults.conf: {name} must be a number (got '{raw}')")
        })
    };
    let baselines = Baselines {
        memory_per_job_gib: baseline(&project.defaults.memory_per_job_gib, "memory_per_job_gib")?,
        core_memory_per_job_gib: baseline(
            &project.defaults.core_memory_per_job_gib,
            "core_memory_per_job_gib",
        )?,
        reserved_memory_gib: baseline(
            &project.defaults.reserved_memory_gib,
            "reserved_memory_gib",
        )?,
    };
    let facts = budget::host_facts()?;
    Budget::resolve(&intensity, lanes, jobs, baselines, facts, package_count)
}

/// One parallelism override: the flag, else its env twin, else the
/// build-defaults value (contract §B.8: a flag beats its env twin).
fn override_value(flag: Option<&str>, env_name: &str, conf: &str) -> Result<Override, String> {
    if let Some(raw) = flag {
        let name = env_name.trim_start_matches("GSA_").to_ascii_lowercase();
        return Override::parse(raw).map_err(|e| format!("--{name}: {e}"));
    }
    if let Ok(raw) = std::env::var(env_name) {
        if !raw.is_empty() {
            return Override::parse(&raw).map_err(|e| format!("{env_name}: {e}"));
        }
    }
    Override::parse(conf.trim()).map_err(|e| format!("config/build-defaults.conf: {e}"))
}

/// The scheduling nodes: the selection in canonical build order, with
/// build-order edges resolved to selection-local indices (prerequisites
/// outside the selection are assumed installed — §C.3), `core` /
/// `build-tools` membership from the topology record only (§K.2).
fn build_nodes(root: &std::path::Path, graph: &Graph<'_>, selection: &Selection) -> Vec<SupNode> {
    let mut node_of: HashMap<usize, usize> = HashMap::new();
    for (node_idx, (_, id)) in selection.listed.iter().enumerate() {
        node_of.insert(
            graph.index_of(id.as_str()).expect("selection ids resolve"),
            node_idx,
        );
    }
    let mut nodes: Vec<SupNode> = Vec::new();
    for (_, id) in &selection.listed {
        let idx = graph.index_of(id.as_str()).expect("selection ids resolve");
        let record = graph.record(idx);
        let prereqs: Vec<usize> = graph
            .prerequisites(idx)
            .into_iter()
            .filter_map(|p| node_of.get(&p).copied())
            .collect();
        nodes.push(SupNode {
            id: id.clone(),
            recipe_dir: root.join(&record.path),
            core: record.groups.contains(&Group::Core),
            build_tools: record.groups.contains(&Group::BuildTools),
            prereqs,
            consumers: Vec::new(),
            batch: None,
        });
    }
    for node in 0..nodes.len() {
        for prereq in nodes[node].prereqs.clone() {
            nodes[prereq].consumers.push(node);
        }
    }
    nodes
}

/// Coupled batches (`abi=must`/`abi=should`) with at least two selected
/// members (contract §I.1 open decision 1: a failed member parks its batch
/// mates with reason `coupled-batch`).
fn build_batches(graph: &Graph<'_>, selection: &Selection) -> Vec<Vec<usize>> {
    let mut node_of: HashMap<&str, usize> = HashMap::new();
    for (node_idx, (_, id)) in selection.listed.iter().enumerate() {
        node_of.insert(id.as_str(), node_idx);
    }
    let mut batches: Vec<Vec<usize>> = Vec::new();
    for batch in graph.coupled_batches() {
        let members: Vec<usize> = batch
            .members
            .iter()
            .filter_map(|id| node_of.get(id.as_str()).copied())
            .collect();
        if members.len() >= 2 {
            batches.push(members);
        }
    }
    batches
}

/// For every parked row, the failed/deferred packages whose event parked it
/// (contract §I.4.1: the prose names the failure that parked each member).
/// Derived once from the same rows plus the topology closure — the prose
/// rendering never re-derives state.
fn parked_by(graph: &Graph<'_>, rows: &[OutcomeRow]) -> Vec<(String, Vec<String>)> {
    rows.iter()
        .filter(|row| row.status == RowStatus::Parked)
        .map(|row| {
            let mut responsible: Vec<String> = Vec::new();
            let idx = graph.index_of(row.pkg.as_str());
            for root in rows {
                let event_matches = match row.reason.as_str() {
                    "waits-on-failed" | "coupled-batch" => root.status == RowStatus::Failed,
                    "waits-on-deferred" => root.status == RowStatus::Deferred,
                    _ => false,
                };
                if !event_matches || root.pkg == row.pkg {
                    continue;
                }
                let root_idx = graph.index_of(root.pkg.as_str());
                let consumes = match (idx, root_idx) {
                    (Some(leaf), Some(seed)) => graph.consumer_closure(&[seed]).contains(&leaf),
                    _ => false,
                };
                let batch_mates = row.reason == "coupled-batch"
                    && idx.is_some()
                    && root_idx.is_some()
                    && graph.coupled_batches().iter().any(|batch| {
                        batch.members.iter().any(|m| m == &row.pkg)
                            && batch.members.iter().any(|m| m == &root.pkg)
                    });
                if consumes || batch_mates {
                    responsible.push(root.pkg.as_str().to_string());
                }
            }
            (row.pkg.as_str().to_string(), responsible)
        })
        .collect()
}

/// A run that refused to start (contract §G.1 rc 3; §H.1: the record is
/// emitted on refusal paths too). Every row is `never-started
/// <reason>` — `preflight-refused` (§H.3) for an install run whose
/// `sudo -n` preflight failed, `startup-refused` (an additive reason key,
/// §H.2) for state/startup refusals.
fn refuse_before_dispatch(
    inv: &Invocation,
    selection: &Selection,
    budget: &Budget,
    state_dir: &std::path::Path,
    out: &mut dyn Write,
    err: &mut dyn Write,
    reason: &str,
) -> i32 {
    let outcomes: Vec<OutcomeRow> = selection
        .listed
        .iter()
        .map(|(_, id)| OutcomeRow {
            pkg: id.clone(),
            status: RowStatus::NeverStarted,
            rc: None,
            dur: None,
            reason: reason.to_string(),
        })
        .collect();
    let run_outcome = RunOutcome::compute(&outcomes, inv.fail_fast, false, true);
    // A refused run never reached fetch-ahead participation (owner decision
    // 5: the scalar counts a build run's prefetch advisories only).
    let record = record::build_run_record(
        inv,
        selection,
        &inv.targets,
        &inv.ranges,
        Some(budget),
        outcomes,
        &run_outcome,
        None,
    );
    let _ = write!(
        out,
        "{}",
        render::render_run_prose(&record, &state_dir.join("logs"), &[], None)
    );
    // A refused run is still a completed run record (§H.1) — persisted
    // like every other emission through the one store path.
    record::emit_machine_record(out, &record, state_dir, err);
    run_outcome.rc
}
