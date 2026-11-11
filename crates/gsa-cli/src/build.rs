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

use std::collections::{BTreeSet, HashMap};
use std::io::Write;
use std::path::PathBuf;

use gsa_abi::{plan_waves, Subscriptions, TokenMove, WaveInputs};
use gsa_fetch::candidacy::{classify as classify_candidacy, FetchCandidacy};
use gsa_graph::Graph;
use gsa_install::localdb::{pacman_db_root, pacman_db_root_for, LocalDb};
use gsa_install::{preflight_installs, DecideMode, InstallRun};
use gsa_model::{Group, OutcomeRow, PlanAction, PlanRow, RecipeId, RowStatus, RunOutcome};
use gsa_recipe::toolchain;
use gsa_recipe::RecipeDb;
use gsa_sched::budget::{self, Baselines, Budget, Override};
use gsa_sched::lock;
use gsa_sched::machine::Policy;
use gsa_sched::supervisor::{self, InstallStep, PreSettle, PrefetchSetup, RunSetup, SupNode};
use gsa_topo::ProjectConfig;

use crate::args::Invocation;
use crate::exit::{self, Exit, Refusal, RefusalClass};
use crate::prepare;
use crate::select::{self, Ctx, Selection};
use crate::{record, render};

/// The five build-run modifiers (§B.8): real on a `-B` build, deferred on
/// every other spelling (the classifier consults this roster). The two
/// fetch-ahead knobs (owner decision 1) ride along.
pub const REAL_BUILD_FLAGS: [&str; 10] = [
    "--fail-fast",
    "--lanes",
    "--jobs",
    "--intensity",
    "--state-dir",
    "--build-dir",
    "--no-build-dir-prompt",
    "--no-prefetch",
    "--prefetch-ahead",
    "--toolchain",
];

/// What a `-S` build+install run additionally accepts (§B.8): the dynamic
/// IgnorePkg registration switch and the target pacman.conf.
pub const REAL_INSTALL_FLAGS: [&str; 12] = [
    "--fail-fast",
    "--lanes",
    "--jobs",
    "--intensity",
    "--state-dir",
    "--build-dir",
    "--no-build-dir-prompt",
    "--no-prefetch",
    "--prefetch-ahead",
    "--no-register-ignorepkg",
    "--config",
    "--toolchain",
];

/// `gsa -B <targets…> [ranges…]` — run the selection build-only. Returns the
/// process exit code (§G.1) and writes every rendering through `out`/`err`.
pub fn run_build(inv: &Invocation, out: &mut dyn Write, err: &mut dyn Write) -> i32 {
    exit::render(run_build_with(inv, out, err, None), err)
}

/// `gsa -S <targets…> [ranges…]` (contract §B.4): the build pipeline plus
/// install-before-dependents — each package's archives install through the
/// post-build hook BEFORE any consumer compiles (`AGENTS.md` rule 11).
/// Cluster `f` is force install (no same-version skip); cluster `c` prunes
/// strength 1 first. Trailing `-- <pacman args…>` reach every transaction.
pub fn run_build_install(inv: &Invocation, out: &mut dyn Write, err: &mut dyn Write) -> i32 {
    let mode = if inv.modifiers.contains(&'f') {
        DecideMode::Force
    } else {
        DecideMode::Checked
    };
    exit::render(run_build_with(inv, out, err, Some(mode)), err)
}

/// `Ok(code)` is a computed run code (§G.1's outcome classes); `Err(exit)` is
/// a gate that refused before the run existed — the ONE renderer maps it.
fn run_build_with(
    inv: &Invocation,
    out: &mut dyn Write,
    err: &mut dyn Write,
    install: Option<DecideMode>,
) -> Result<i32, Exit> {
    // ── the run's compiler family (§B.11) ────────────────────────────────
    // Pinned before any lane spawns: the supervisor exports it to every lane
    // child, and a typo names the two alternatives here rather than
    // defaulting to gcc silently.
    if let Some(value) = &inv.toolchain {
        let toolchain = gsa_model::toolchain::Toolchain::parse(value)
            .map_err(|message| Exit::Usage(format!("--toolchain: {message}")))?;
        gsa_model::toolchain::set_override(toolchain);
    }
    // The record's wall clock (§H.2 amendment): captured before the first
    // resolution, so a long preflight is inside the run's span.
    let run_started = gsa_model::epoch_now();
    // The build-dir answer (a `--build-dir` flag or the prompt's) is written
    // back into this run's invocation so the run record's continuation
    // restates the tree this run actually built into (§J.2/§H.2).
    let mut owned = inv.clone();
    let inv = &mut owned;
    // ── selection is mandatory (contract §B.1) ───────────────────────────
    if inv.targets.is_empty() {
        return Err(Exit::Usage(
            "selection is mandatory: a build never starts without a selection".to_string(),
        ));
    }
    // ── workspace, topology, selection (usage class: rc 2) ────────────────
    // A standalone-target run staged its own workspace (plan W4); the rest
    // discover the recipe workspace as before.
    let root = crate::resolve_workspace(inv, err)?;
    let project = gsa_topo::load_project(&root).map_err(|error| Exit::Usage(error.to_string()))?;
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
    // ── usage preflight: resolve the selection (§G.1 rc 2 class) ─────────
    let draft = select::resolve_selection(&ctx, &inv.targets, &inv.ranges, inv.leaf)
        .map_err(|error| error.into_exit())?;
    crate::write_notes(err, draft.notes());

    // ── privilege gate (contract §B.10; after every usage preflight) ─────
    if let Some(exit) = crate::privilege_gate(
        &inv.spelling(),
        crate::invocation_privilege(inv, &crate::Command::Build),
        true,
        err,
    ) {
        return Err(exit);
    }

    // ── §C.4 prompt, AFTER the gate: an unprivileged run must refuse
    //    (rc 3) before any interactive input is rendered or consumed ──────
    let mut selection = draft
        .finish_for_build(
            &ctx,
            err,
            crate::prompt::interactive(inv.machine_requested()),
        )
        .map_err(|error| error.into_exit())?;

    // ── build-cache root (§J.2): asked AFTER the selection prompt, before
    //    anything resolves the layout ─────────────────────────────────────
    crate::builddir::resolve(inv, err)?;

    // ── state root (contract §J.3): --state-dir > GSA_STATE_DIR > the
    //    gsa.conf layers (user > system) > /var/lib/gsa ─────────────────
    let state_dir =
        gsa_model::config::resolve_state_dir(inv.state_dir.as_deref()).map_err(Exit::Usage)?;

    // ── missing build-order prerequisites (owner decision 2026-11-11) ────
    // `-S app` planned `ok` and then died in makepkg's "Missing dependencies"
    // for a prerequisite nobody selected. The prerequisites the SYSTEM lacks
    // now join the selection; an installed one is never added and never
    // rebuilt, and `--leaf` builds exactly what was named.
    match missing_prerequisite_additions(&graph, &selection, &db, inv) {
        Ok(additions) => {
            for id in &additions {
                let _ = writeln!(
                    err,
                    "gsa: note: added build-order prerequisite {id} (not installed)"
                );
            }
            merge_prerequisites(&mut selection, &additions, &graph);
        }
        Err(message) => {
            // The additions decide what the run builds, so an unreadable
            // installed DB is a refusal, never "nothing is missing" (which
            // would rebuild, or plan a prerequisite-less run).
            let _ = writeln!(err, "gsa: {message}");
            return Err(refuse_startup(
                inv,
                &selection,
                &state_dir,
                out,
                err,
                RefusalClass::StartupRefused,
                || resolve_budget(inv, &project, selection.listed.len()),
            ));
        }
    }

    // ── the pre-dispatch ABI wave check (docs/plans/plan-native-pm.md §4.3, §E.3) ──
    // A provider whose registered token already moved (newest binpkg index
    // row ≠ what its consumers recorded at install) drags its consumer
    // wave into the plan: wave members outside the selection are added,
    // and an uncovered member refuses the run (rc 3) before anything runs.
    let wave = match wave_check(
        out,
        err,
        &graph,
        &selection,
        &state_dir,
        inv.config.as_deref().map(std::path::Path::new),
        &crate::install::workspace_recipe_of_name(&db),
    ) {
        Ok(wave) => wave,
        Err(WaveStateError(message)) => {
            // Fail closed (§G.1 rc 3): the wave gate has no "unknown" state —
            // it reads unreadable state as a refusal, never as an empty wave,
            // and the refusal owes the full record (§H.1) like every other
            // startup gate.
            let _ = writeln!(err, "gsa: {message}");
            return Err(refuse_startup(
                inv,
                &selection,
                &state_dir,
                out,
                err,
                RefusalClass::StartupRefused,
                || resolve_budget(inv, &project, selection.listed.len()),
            ));
        }
    };
    extend_selection(&mut selection, &wave.additions);

    // ── resource budget (host-derived; the parallelism line is the truth) ─
    let budget = resolve_budget(inv, &project, selection.listed.len()).map_err(Exit::Usage)?;
    // ── fetch-ahead (owner decision 1): default-on, `--no-prefetch` opt-out ─
    let prefetch_ahead = resolve_prefetch(inv).map_err(Exit::Usage)?;

    // ── startup refusals (§G.1 rc 3) ─────────────────────────────────────
    // Under-coverage (§E.3): a wave member the topology cannot build —
    // the refusal rows are already printed; nothing transacts, nothing
    // builds.
    if wave.uncovered {
        return Err(refuse_before_dispatch(
            inv,
            &selection,
            &budget,
            &state_dir,
            out,
            err,
            RefusalClass::AbiConsumerUncovered,
        ));
    }
    // Install preflight (contract §K.3): an install run whose installs
    // cannot succeed non-interactively refuses BEFORE any build (§G.1 rc 3).
    if install.is_some() {
        if let Err(message) = preflight_installs(inv.config.as_deref().map(std::path::Path::new)) {
            let _ = writeln!(err, "gsa: {message}");
            return Err(refuse_before_dispatch(
                inv,
                &selection,
                &budget,
                &state_dir,
                out,
                err,
                RefusalClass::PreflightRefused,
            ));
        }
    }
    if let Err(message) = lock::ensure_state_dirs(&state_dir, err) {
        let _ = writeln!(err, "gsa: {message}");
        return Err(refuse_before_dispatch(
            inv,
            &selection,
            &budget,
            &state_dir,
            out,
            err,
            RefusalClass::StartupRefused,
        ));
    }
    // The PACMAN shim (§K.3): makepkg's own dependency installs share the
    // transaction lock and run through `sudo -n` — the engine never prompts.
    if let Err(message) = gsa_build::shim::ensure_pacman_shim(&state_dir) {
        let _ = writeln!(err, "gsa: {message}");
        return Err(refuse_before_dispatch(
            inv,
            &selection,
            &budget,
            &state_dir,
            out,
            err,
            RefusalClass::StartupRefused,
        ));
    }
    let run_id = supervisor::run_id_now();
    let _run_lock = match lock::acquire_run_lock(&state_dir) {
        Ok(lock) => lock,
        Err(message) => {
            let _ = writeln!(err, "gsa: {message}");
            return Err(refuse_before_dispatch(
                inv,
                &selection,
                &budget,
                &state_dir,
                out,
                err,
                RefusalClass::StartupRefused,
            ));
        }
    };
    // Startup orphan sweep (§K.3): dead runs' lane jobs and stale artifacts.
    lock::sweep_orphans(&state_dir, &run_id, err);

    // ── prune strength 1 first (§B.5 cluster letter `c`) ─────────────────
    if inv.modifiers.contains(&'c') {
        let mut report = gsa_build::clean::CleanReport::default();
        // §J.2/§J.3's one layout error policy: the shared-PKGDEST leg needs
        // the layout, and a failure is fatal for the run — never a silent
        // prune of only the recipe-dir trees (`.ok()` swallowed the error
        // and the prune quietly stopped covering the cache).
        let layout = match gsa_model::config::build_layout_for_run() {
            Ok(layout) => layout,
            Err(message) => {
                let _ = writeln!(err, "gsa: {message}");
                return Err(refuse_before_dispatch(
                    inv,
                    &selection,
                    &budget,
                    &state_dir,
                    out,
                    err,
                    RefusalClass::StartupRefused,
                ));
            }
        };
        for (_, id) in &selection.listed {
            let record = graph.record(graph.index_of(id.as_str()).expect("selection ids resolve"));
            let recipe_dir = root.join(&record.path);
            // W4: the prune also covers the recipe's cache trees and its
            // archives in the shared PKGDEST (names from the committed
            // .SRCINFO — the same truth the gate seeds from).
            let mut pkgbase: String = id.to_string();
            let mut outputs: Vec<String> = Vec::new();
            let srcinfo = recipe_dir.join(".SRCINFO");
            if let Ok(text) = std::fs::read_to_string(&srcinfo) {
                if let Ok(info) = gsa_recipe::parse_srcinfo(&text, &srcinfo.display().to_string()) {
                    if let Some(base) = info.pkgbase {
                        pkgbase = base;
                    }
                    outputs = if info.pkgnames.is_empty() {
                        vec![pkgbase.clone()]
                    } else {
                        info.pkgnames
                    };
                }
            }
            gsa_build::clean::clean_recipe(
                &root,
                &recipe_dir,
                &pkgbase,
                &outputs,
                Some(&layout),
                &mut report,
            );
        }
        for removed in &report.removed {
            let _ = writeln!(err, "gsa: note: pruned {removed}");
        }
        for error in &report.errors {
            let _ = writeln!(err, "gsa: {error}");
        }
    }

    // ── the pre-dispatch decision pass (contract §B.4/§B.8) ──────────────
    // 1. the toolchain PREFLIGHT (owner rule 2026-09-25): a broken rustc
    //    refuses before anything builds (§G.1 rc 3) unless
    //    `--allow-broken-rustc` — that escape hatch is for runs that compile
    //    no Rust, never a way past a real ABI mismatch (the MID-RUN trigger
    //    in the supervisor always engages).
    if !inv.allow_broken_rustc {
        match toolchain::rustc_sanity_probe(&probe_scratch()) {
            toolchain::ProbeStatus::Ok => {}
            toolchain::ProbeStatus::Skipped { reason } => {
                let _ = writeln!(err, "gsa: note: rustc sanity probe skipped ({reason})");
            }
            toolchain::ProbeStatus::Failed { detail } => {
                let _ = writeln!(err, "gsa: {detail}");
                let _ = writeln!(err, "{}", toolchain::remediation_refusal_text());
                return Err(refuse_before_dispatch(
                    inv,
                    &selection,
                    &budget,
                    &state_dir,
                    out,
                    err,
                    RefusalClass::PreflightRefused,
                ));
            }
        }
    }
    // 2. the version-sync + freshness pass (one pass, canonical order).
    let cfg = prepare::pass_config(inv).map_err(Exit::Usage)?;
    for line in &cfg.notes {
        let _ = writeln!(err, "gsa: note: {line}");
    }
    let prepared = prepare::prepare_all(&root, &state_dir, &graph, &selection, &cfg);
    for prep in &prepared.packages {
        for line in &prep.log {
            let _ = writeln!(err, "gsa: note: {line}");
        }
    }
    // 3. a fail-closed refusal (integrity stop / named sync refusal) aborts
    //    BEFORE any makepkg (§G.1 rc 3): the offending row fails, every
    //    other row is `never-started - - startup-refused`, plan rows keep
    //    the planned action.
    if let Some(at) = prepared.first_refusal() {
        return Err(refuse_prepared(
            inv, &selection, &budget, &state_dir, &prepared, at, out, err,
        ));
    }
    // 4. per-node pre-settlements (§B.8) ride the supervisor's nodes: a
    //    `--skip` claim settles at readiness (register+install hooks, no
    //    lane), a deferral settles before dispatch (its cone parks).
    let mut pre: std::collections::BTreeMap<String, crate::prepare::NodePlan> =
        std::collections::BTreeMap::new();
    for (prep, (_, id)) in prepared.packages.iter().zip(&selection.listed) {
        if matches!(
            prep.plan,
            crate::prepare::NodePlan::Skip { .. } | crate::prepare::NodePlan::Defer { .. }
        ) {
            pre.insert(id.as_str().to_string(), prep.plan.clone());
        }
    }
    // 5. the remediation latent set (owner rule 2026-10-02): every possible
    //    remediation target not already in the selection, in force-queue
    //    order — the broken consumer first, then the `core` roster (the
    //    escalated chain's order, fish `_GROUP_core`).
    let core_members: Vec<String> = graph
        .records()
        .iter()
        .filter(|record| record.groups.contains(&Group::Core))
        .map(|record| record.id.as_str().to_string())
        .collect();
    let mut latents: Vec<String> = Vec::new();
    if install.is_some() {
        for id in std::iter::once("rust-git".to_string()).chain(core_members.iter().cloned()) {
            if graph.index_of(id.as_str()).is_some()
                && !selection.listed.iter().any(|(_, sel)| sel.as_str() == id)
                && !latents.contains(&id)
            {
                latents.push(id);
            }
        }
    }

    // ── dispatch nodes: the selection in canonical build order ────────────
    let nodes = build_nodes(&root, &graph, &selection, &pre, &latents);
    let batches = build_batches(&graph, &selection);

    let _ = writeln!(out, "{}", render::parallelism_line(&budget));
    let exe = match std::env::current_exe() {
        Ok(exe) => exe,
        Err(error) => {
            let _ = writeln!(
                err,
                "gsa: cannot locate the engine binary for lane children: {error}"
            );
            return Err(refuse_before_dispatch(
                inv,
                &selection,
                &budget,
                &state_dir,
                out,
                err,
                RefusalClass::StartupRefused,
            ));
        }
    };
    let ids: Vec<RecipeId> = selection.listed.iter().map(|(_, id)| id.clone()).collect();
    // Whether this run installs (the install-time QA report surface rides
    // install runs only — contract §E.4, install-qa-check.d timing).
    let is_install_run = install.is_some();
    // The post-build install hook (install-before-dependents, rule 11):
    // called per package on the supervisor's event loop, before its result
    // reaches the machine. `later_installs` is `later_after`'s order-truth
    // tail (rule 25(d) in-run repair coverage).
    let install_hook: Option<Box<dyn FnMut(&str, &std::path::Path, bool) -> InstallStep + Send>> =
        install.map(|mode| {
            let state_dir = state_dir.clone();
            let conf = inv.config.as_ref().map(PathBuf::from);
            let pacman_args = inv.pacman_args.clone().unwrap_or_default();
            let register_ignorepkg = !inv
                .deferred_flags
                .iter()
                .any(|f| f == "--no-register-ignorepkg");
            let order = build_order_ids(&graph, &ids);
            // Settled-lane ledger for `later_after_settled`: the hook fires
            // per settled lane, so this is the run's landed set.
            let mut settled: Vec<String> = Vec::new();
            let workspace_names: Vec<String> = crate::install::workspace_output_names(&db)
                .into_iter()
                .collect();
            // The canonical repair-marker key map (rule 25(d), §E.3 gap-G1):
            // the run order names recipe ids, link truth names pkgnames —
            // this map is the ONE boundary that lets the ABI gate compare
            // them and stage markers the consume side can read back.
            let recipe_of_name = crate::install::workspace_recipe_of_name(&db);
            Box::new(
                move |pkg: &str, recipe_dir: &std::path::Path, forced: bool| {
                    // Rule 25(d) coverage reads the ORDER, minus what has
                    // already settled (see `later_after_settled`).
                    let later = later_after_settled(&order, pkg, &settled);
                    settled.push(pkg.to_string());
                    // A remediation force build installs in force mode (fish
                    // `lane_force_install=1`): never the same-version skip.
                    let mode = if forced { DecideMode::Force } else { mode };
                    let run = InstallRun {
                        mode,
                        state_dir: state_dir.clone(),
                        conf: conf.clone(),
                        pacman_args: pacman_args.clone(),
                        register_ignorepkg,
                        later_installs: later,
                        recipe_of_name: recipe_of_name.clone(),
                        workspace_names: workspace_names.clone(),
                    };
                    crate::install::install_step_from_result(gsa_install::install_built_package(
                        recipe_dir, &run,
                    ))
                },
            ) as Box<dyn FnMut(&str, &std::path::Path, bool) -> InstallStep + Send>
        });
    // ── the post-build registration hook (contract §J.4) ────────────────
    // Every successful build records its instance in the hash-bound binpkg
    // index and enforces the topology-derived retention budget (N=2 hubs /
    // N=1 elsewhere); the in-flight lane ids the supervisor passes are the
    // guard — pruning never deletes an archive the run is using. The same
    // hook carries the post-BUILD half of "skip and resume"
    // (docs/build-guide.md): the VCS freshness baselines and the GCC
    // identity marker — never for a `--skip` claim (`built = false`), whose
    // existing manifest is the claim's evidence and must not be re-blessed.
    let retention = gsa_state::Retention::from_graph(&graph);
    // The declared `abi-rev=` override per recipe id (§J.4): the registration
    // hook passes it to the one shared token derivation — never re-derives.
    let abi_revs: std::collections::BTreeMap<String, Option<u64>> = graph
        .records()
        .iter()
        .map(|record| {
            (
                record.id.as_str().to_string(),
                gsa_abi::abi_rev_of(&record.tags),
            )
        })
        .collect();
    // The declared `toolchain=` per recipe id (§B.11): the marker hook folds
    // it into the build identity, and the run override still beats it.
    let toolchains: std::collections::BTreeMap<String, Option<gsa_model::toolchain::Toolchain>> =
        graph
            .records()
            .iter()
            .map(|record| (record.id.as_str().to_string(), record.toolchain()))
            .collect();
    let register_hook: Box<
        dyn FnMut(&str, &std::path::Path, &std::collections::BTreeSet<String>, bool) -> Vec<String>
            + Send,
    > = {
        let state_dir = state_dir.clone();
        Box::new(move |pkg, recipe_dir, in_flight, built| {
            let mut notes = Vec::new();
            let mut gate = Vec::new();
            // A finished build registers the outputs it just wrote — the
            // newest-mtime rank (Rank::Mtime), never the version-ranked
            // winner: a stale higher-version archive lying in the scan set
            // must not become this build's row (the retention sweep would
            // then protect the stale file and delete the fresh one). A
            // claim (`built == false`) registers what was claimed, which is
            // exactly the version-ranked discovery winner.
            let found = if built {
                gsa_install::discover_recipe_ranked(recipe_dir, gsa_install::Rank::Mtime)
            } else {
                gsa_install::discover_recipe(recipe_dir)
            };
            let archives = match found {
                Ok(found) => found
                    .candidates
                    .into_iter()
                    .map(|c| c.archive)
                    .collect::<Vec<_>>(),
                Err(error) => {
                    notes.push(format!(
                        "binpkg index: registration failed for {pkg}: cannot discover built archives in {} ({error})",
                        recipe_dir.display()
                    ));
                    return notes;
                }
            };
            let outcome = gsa_state::StateRoot::open(&state_dir).and_then(|state| {
                let abi_rev = abi_revs.get(pkg).copied().flatten();
                gsa_state::register_instance(
                    &state, pkg, &archives, &retention, in_flight, abi_rev, &mut gate,
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
            if built {
                // VCS freshness baselines first, then the toolchain marker —
                // the marker ONLY after the baselines recorded (the module's
                // caller contract: a failed attempt must drift again).
                match gsa_recipe::sync::pkgbuild_array_checked(recipe_dir, "source") {
                    Ok(entries) => {
                        let mut baselines_ok = true;
                        for archive in &archives {
                            match gsa_recipe::freshness::record_vcs_archive_revisions(
                                recipe_dir, archive, &entries,
                            ) {
                                Ok(_) => {}
                                Err(error) => {
                                    baselines_ok = false;
                                    notes.push(format!("vcs baseline: {pkg}: {error}"));
                                }
                            }
                        }
                        if baselines_ok {
                            let source = std::fs::read_to_string(recipe_dir.join("PKGBUILD"))
                                .unwrap_or_default();
                            let declared = toolchains.get(pkg).copied().flatten();
                            let selected = gsa_recipe::toolchain::select(
                                pkg,
                                gsa_model::toolchain::override_value(),
                                declared,
                                &source,
                            )
                            .map(|selected| selected.toolchain)
                            .unwrap_or(
                                gsa_model::toolchain::override_value()
                                    .or(declared)
                                    .unwrap_or(gsa_model::toolchain::Toolchain::DEFAULT),
                            );
                            match gsa_recipe::toolchain::build_identity(selected) {
                                Ok(identity) => {
                                    if let Err(error) = gsa_recipe::toolchain::write_marker(
                                        &state_dir, pkg, &identity,
                                    ) {
                                        notes.push(format!("toolchain marker: {pkg}: {error}"));
                                    }
                                }
                                Err(error) => notes.push(format!(
                                    "toolchain marker: {pkg}: cannot determine the {selected} build identity ({error})"
                                )),
                            }
                        }
                    }
                    Err(error) => notes.push(format!(
                        "vcs baseline: {pkg}: cannot evaluate the PKGBUILD source array ({error})"
                    )),
                }
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
        let _ = std::fs::File::create(&prefetch_log).inspect_err(|error| {
            // Loud, never fatal: one advisory log going missing must never
            // take the run with it — but it must never vanish silently.
            let _ = writeln!(
                err,
                "gsa: warning: cannot truncate prefetch log {}: {error}",
                prefetch_log.display()
            );
        });
        PrefetchSetup {
            ahead,
            candidacy,
            log_path: prefetch_log,
        }
    });
    // The toolchain-remediation wiring (owner rule 2026-10-02): install runs
    // only — the mid-run trigger is a real ABI mismatch and engages even
    // under `--allow-broken-rustc` (that flag is a PREFLIGHT escape hatch,
    // contract §B.8). The topology oracles come from the one graph view.
    let remediation = install.map(|_| supervisor::RemediationSetup {
        scratch_base: probe_scratch(),
        trigger_installs: vec!["llvm-git".to_string(), "llvm-libs-git".to_string()],
        broken_consumer: "rust-git".to_string(),
        known: graph
            .records()
            .iter()
            .map(|record| record.id.as_str().to_string())
            .collect(),
        core_members: core_members.clone(),
        toolchain_consumers: {
            let mut map = std::collections::HashMap::new();
            for trigger in ["llvm-git", "llvm-libs-git"] {
                if let Some(idx) = graph.index_of(trigger) {
                    map.insert(
                        trigger.to_string(),
                        graph
                            .consumer_closure(&[idx])
                            .into_iter()
                            .map(|i| graph.record(i).id.as_str().to_string())
                            .collect::<Vec<_>>(),
                    );
                }
            }
            map
        },
    });
    let record_root = root.clone();
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
        remediation,
    };

    // ── the run: streaming dashboard lines as the machine settles ─────────
    // The event view covers every node the machine carries (the selection
    // plus any activated remediation latent).
    let event_ids: Vec<RecipeId> = setup.nodes.iter().map(|node| node.id.clone()).collect();
    // The live run view (ux): a TTY human run gets the progress box, a human
    // pipe gets the 10 s STATUS hint, the machine stream passes through. The
    // box counts the run's OWN packages — the un-activated remediation
    // latents never inflate a `--leaf` run's total (2026-11-03; §H `order`
    // semantics: a latent joins the run only when activated).
    let latent_ids: Vec<RecipeId> = setup
        .nodes
        .iter()
        .filter(|node| node.latent)
        .map(|node| node.id.clone())
        .collect();
    let mut view = crate::dashboard::View::new(
        crate::output::is_human(),
        state_dir.clone(),
        event_ids.clone(),
        setup.budget.lanes as usize,
        latent_ids,
    );
    let run_result = supervisor::run(
        setup,
        &mut |event| {
            let line = render::render_event(event, &event_ids);
            view.handle(event, &line, out);
        },
        err,
    );
    // The box restores the cursor before any other surface (the run record)
    // prints — on every exit path out of the run.
    view.finish(out);
    let outcome = match run_result {
        Ok(outcome) => outcome,
        Err(message) => {
            let _ = writeln!(err, "gsa: {message}");
            return Err(refuse_before_dispatch(
                inv,
                &selection,
                &budget,
                &state_dir,
                out,
                err,
                RefusalClass::StartupRefused,
            ));
        }
    };
    // The dashboard is a PROJECTION of the run, never a fourth derivation of
    // its state (§H one-record rule): its fold over the event stream must be
    // the record's own rows and plan order. A divergence here is the class of
    // defect that once rendered a `--leaf` one-package run as `1/332`
    // (2026-11-03) — the box and the record disagreeing about the same run.
    let drift = view.progress().drift(&outcome.rows, &outcome.order);
    debug_assert!(
        drift.is_none(),
        "dashboard/record drift (the live view stopped being a projection of the run): {}",
        drift.unwrap_or_default()
    );
    // Post-run orphan sweep (§K.3) — the current run's artifacts survive.
    lock::sweep_orphans(&state_dir, &run_id, err);

    // ── one run record, three renderings (§H) ────────────────────────────
    let rows = outcome.rows;
    let run_order = outcome.order;
    let run_outcome =
        RunOutcome::compute(&rows, inv.fail_fast, outcome.interrupted, outcome.refused);
    let parked_by = parked_by(&graph, &rows);
    // The `prefetch-warnings` scalar (owner decision 5): the advisory count
    // of this run's fetch-ahead. `None` when the run had no fetch-ahead
    // participation (`--no-prefetch`) — never rows, never a format bump.
    let prefetch_warnings =
        prefetch_ahead.map(|_| u32::try_from(outcome.prefetch_warnings.len()).unwrap_or(u32::MAX));
    // Plan rows (§H.2): the pre-dispatch pass's answers (`skip <reason>`
    // for a claim, the family's build action otherwise), then the activated
    // remediation latents appended in `order` — plan, outcome and `order`
    // always key to the same subject list.
    let mut plan = prepared.plan_rows(&ids, install.is_some());
    for id in &run_order {
        if !ids.contains(id) {
            plan.push(PlanRow {
                pkg: id.clone(),
                action: if install.is_some() {
                    PlanAction::BuildInstall
                } else {
                    PlanAction::Build
                },
                reason: "ok".to_string(),
            });
        }
    }
    let mut record = record::build_run_record(
        inv,
        &inv.targets,
        &inv.ranges,
        Some(&budget),
        plan,
        run_order,
        rows,
        &run_outcome,
        prefetch_warnings,
    );
    // Which compiler built this, under which identity, and when (§H.2).
    let (toolchain, toolchain_identity) = record_toolchain(&graph, &record_root, &selection);
    record.stamp = gsa_model::RecordStamp {
        toolchain,
        toolchain_identity,
        started: Some(run_started),
        ended: Some(gsa_model::epoch_now()),
    };
    // The install-time QA report surface (contract §E.4): report-severity
    // findings over the run's subjects appended to the prose summary
    // (prose-only — the §H.2 choice in `gsa-qa::report`). Install runs only
    // (install-qa-check.d timing); the findings never touch the per-package
    // install decisions, which the one decision seam made (rule 20).
    let qa = if is_install_run {
        let qa_targets: Vec<String> = ids.iter().map(|id| id.as_str().to_string()).collect();
        crate::qa::report_lines(&qa_targets, inv.state_dir.as_deref())
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
    Ok(run_outcome.rc)
}

/// The rustc sanity probe scratch for THIS engine process: the module's
/// per-user base ([`toolchain::resolve_probe_scratch`]) plus the pid. Two
/// concurrent runs of the same user must never share the probe's
/// output-named codegen temporaries — they collide on the same
/// `*.rcgu.o` names and fail each other's links (the spurious "cannot open
/// … rcgu.o" / undefined-symbol failures this prefix removes).
fn probe_scratch() -> std::path::PathBuf {
    let base = toolchain::resolve_probe_scratch();
    std::path::PathBuf::from(format!("{}_{}", base.display(), std::process::id()))
}

/// The record's compiler truth (§H.2 amendment): the family the WHOLE
/// selection resolved to — `mixed` when recipes disagree — and that family's
/// build identity when it is uniform. A selection with no resolvable recipe
/// names no compiler. The identity probe runs once per record, never per row.
fn record_toolchain(
    graph: &Graph<'_>,
    root: &std::path::Path,
    selection: &Selection,
) -> (Option<String>, Option<String>) {
    let mut families = std::collections::BTreeSet::new();
    for (_, id) in &selection.listed {
        let Some(idx) = graph.index_of(id.as_str()) else {
            continue;
        };
        let dir = root.join(&graph.record(idx).path);
        families.insert(prepare::selected_toolchain(
            id.as_str(),
            graph.record(idx),
            &dir,
        ));
    }
    match families.len() {
        0 => (None, None),
        1 => {
            let family = *families.iter().next().expect("one family");
            let identity = gsa_recipe::toolchain::build_identity(family).ok();
            (Some(family.as_str().to_string()), identity)
        }
        _ => (Some("mixed".to_string()), None),
    }
}

/// The `-n` plan rendering (contract §B `--dry-run`) shared by `gsa -S
/// --dry-run` and `gsa -Su --dry-run`: the pre-dispatch ABI wave check, the
/// plan prose and the `format: 2` plan record — no mutation, no dispatch.
pub(crate) fn plan_only(
    ctx: &select::Ctx,
    inv: &Invocation,
    project: &ProjectConfig,
    root: &std::path::Path,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<i32, Exit> {
    if inv.targets.is_empty() {
        return Err(Exit::Usage(
            "selection is mandatory: a build never starts without a selection".to_string(),
        ));
    }
    // Same write-back as the real run: a plan answers the build-dir question
    // so its continuation restates the chosen root (§J.2/§H.2).
    let mut owned = inv.clone();
    let inv = &mut owned;
    let mut selection = select::build_selection_for_build(
        ctx,
        &inv.targets,
        &inv.ranges,
        inv.leaf,
        err,
        crate::prompt::interactive(inv.machine_requested()),
    )
    .map_err(|error| error.into_exit())?;
    crate::write_notes(err, &selection.notes);
    // resolve() owns its typed usage exit; the plan's rc is the run's (§H.2).
    if let Err(exit) = crate::builddir::resolve(inv, err) {
        return Ok(exit.render(err));
    }
    // The same pre-dispatch ABI wave check the build pipeline runs (§E.3):
    // the dry-run shows the wave it would build — additions join the plan,
    // and an under-covered member refuses (rc 3).
    let state_dir = gsa_state::resolve_state_root(inv.state_dir.as_deref()).map_err(Exit::Usage)?;
    // The same prerequisite expansion the run performs (owner decision
    // 2026-11-11): a dry run must show the additions it would build. An
    // unreadable installed DB is the run's refusal, so the plan reports that
    // predicted class rather than a false 0.
    let mut prereq_refused = false;
    match missing_prerequisite_additions(ctx.graph, &selection, ctx.db, inv) {
        Ok(additions) => {
            for id in &additions {
                let _ = writeln!(
                    err,
                    "gsa: note: added build-order prerequisite {id} (not installed)"
                );
            }
            merge_prerequisites(&mut selection, &additions, ctx.graph);
        }
        Err(message) => {
            let _ = writeln!(err, "gsa: {message}");
            prereq_refused = true;
        }
    }
    // A dry run still plans: nothing mutates, so the plan is rendered, but an
    // unreadable wave input makes the real run refuse (rc 3), and the plan's
    // `rc` scalar reports that predicted class rather than a false 0.
    let mut wave_refused = false;
    let wave = match wave_check(
        out,
        err,
        ctx.graph,
        &selection,
        &state_dir,
        inv.config.as_deref().map(std::path::Path::new),
        &crate::install::workspace_recipe_of_name(ctx.db),
    ) {
        Ok(wave) => wave,
        Err(WaveStateError(message)) => {
            let _ = writeln!(err, "gsa: {message}");
            wave_refused = true;
            WaveCheck::default()
        }
    };
    extend_selection(&mut selection, &wave.additions);
    // The plan validates the SAME argv the run does: a bad `--lanes`,
    // `--jobs`, `--intensity` or env twin is a usage error here too (the
    // plan used to accept it and then the real run refused it), and the
    // record's `intensity` scalar is the value the run would actually use.
    let budget = resolve_budget(inv, project, selection.listed.len()).map_err(Exit::Usage)?;
    let _intensity = budget.intensity;
    // The note counts the POST-PROMPT closure: the prompt filters the
    // selection before the ordinary pipeline runs (§C.4), so its drops are
    // not consumer expansion and not part of the selected count.
    let expansion_added = selection.expansion_added;
    let _ = write!(
        out,
        "{}",
        render::render_plan_prose(
            &selection.listed,
            expansion_added,
            selection.seeds.len() + expansion_added,
            inv.leaf,
            true
        )
    );
    // §H.2: the record's `rc` scalar is the run's exit code — a refusing
    // plan reports its refusal, never a success.
    let rc = if wave.uncovered || wave_refused || prereq_refused {
        crate::RC_REFUSED
    } else {
        crate::RC_OK
    };
    let mut rec =
        record::build_plan_record(inv, &selection, &inv.targets, &inv.ranges, &budget, rc);
    // A plan names the family it would use; it probes no compiler, so the
    // identity is `-` — the plan did not build.
    let (toolchain, _) = record_toolchain(ctx.graph, root, &selection);
    let now = gsa_model::epoch_now();
    rec.stamp = gsa_model::RecordStamp {
        toolchain,
        toolchain_identity: None,
        started: Some(now),
        ended: Some(now),
    };
    let _ = write!(out, "{}", rec.render_machine());
    Ok(rc)
}

/// A fail-closed startup refusal raised after the plan exists but before the
/// budget does: the refusal record owes its plan scalars, so the budget is
/// resolved here — and a spelling error in it is a usage error that outranks
/// the refusal (§G.1 precedence: usage 2 > refusal 3).
fn refuse_startup(
    inv: &Invocation,
    selection: &Selection,
    state_dir: &std::path::Path,
    out: &mut dyn Write,
    err: &mut dyn Write,
    class: RefusalClass,
    budget: impl FnOnce() -> Result<Budget, String>,
) -> Exit {
    // A budget spelling error outranks the refusal with the usage class
    // (§G.1 precedence: usage 2 > refusal 3) — decided BEFORE any record.
    match budget() {
        Ok(budget) => refuse_before_dispatch(inv, selection, &budget, state_dir, out, err, class),
        Err(message) => Exit::Usage(message),
    }
}

/// The `-Syu` sync step's routing (§B.4): a refusal is a fail-closed STARTUP
/// gate — it owes the same prose summary + `format: 2` record + persisted
/// history as every other refusal (§G.1 rc 3, §H.1) and carries the sync
/// class key, never a bare rc. `None` means "continue to the stale set".
///
/// The deferral half needs no row of its own: a deferred recipe the stale
/// set covers is re-deferred by the pipeline's own idempotent sync
/// (`deferred 99`), and one the stale set does not cover has no build row to
/// carry — the sync pass already said so on stderr, and the run's rc is
/// earned by rows (§G.1).
fn after_sync_phase(
    inv: &Invocation,
    selection: &Selection,
    state_dir: &std::path::Path,
    out: &mut dyn Write,
    err: &mut dyn Write,
    phase: &prepare::SyncPhase,
    budget: impl FnOnce() -> Result<Budget, String>,
) -> Option<Exit> {
    let class = phase.refused?;
    Some(refuse_startup(
        inv, selection, state_dir, out, err, class, budget,
    ))
}

/// `gsa -Su` / `gsa -Syu` (contract §B.4): build+install the stale set.
///
/// `-Syu` runs the sync phase first over the selection (default: every
/// recipe) — its disposition block prints and a sync refusal aborts (§G.1
/// rc 3) before anything builds; the stale set is then computed from the
/// REWRITTEN (tracked) versions against the newest complete built set and
/// handed to the normal build+install pipeline, whose own pre-dispatch pass
/// re-runs the sync for the stale subset (idempotent — `NoChange`), which is
/// what keeps the deferral row shapes (`deferred 99 - <reason>`) intact
/// instead of losing them across a phase boundary. `-Su` is pacman's `-Su`
/// (H9): the same stale-set update with NO sync pass at all — the committed
/// versions and sums build as-is (the pipeline runs `--no-sync`), and the
/// provider is never queried. A `--dry-run` never rewrites recipes and
/// renders the plan record only. An empty stale set is the §E.3 `noop
/// empty-list` row, rc 0.
pub fn run_update(inv: &Invocation, out: &mut dyn Write, err: &mut dyn Write) -> i32 {
    exit::render(run_update_inner(inv, out, err), err)
}

fn run_update_inner(
    inv: &Invocation,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<i32, Exit> {
    let root = crate::resolve_workspace(inv, err)?;
    let project = gsa_topo::load_project(&root).map_err(|error| Exit::Usage(error.to_string()))?;
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
    let selection = prepare::pass_selection(&ctx, inv).map_err(Exit::Usage)?;
    crate::write_notes(err, &selection.notes);

    // ── privilege gate (contract §B.10; after every usage preflight) ─────
    if let Some(exit) = crate::privilege_gate(
        &inv.spelling(),
        crate::invocation_privilege(inv, &crate::Command::Update),
        true,
        err,
    ) {
        return Err(exit);
    }

    let ids: Vec<RecipeId> = selection.listed.iter().map(|(_, id)| id.clone()).collect();
    let state_dir = gsa_state::resolve_state_root(inv.state_dir.as_deref()).map_err(Exit::Usage)?;

    // ── 1. the `-Sy` phase (`gsa -Syu` only — H9: `gsa -Su` updates with no
    //    sync pass). A dry run never rewrites recipes, so it runs no sync at
    //    all; the routing below owns the rc classes.
    if inv.sync_first && !inv.no_sync && !inv.dry_run {
        let phase = prepare::sync_phase(&root, &graph, &selection, out, err);
        if let Some(exit) = after_sync_phase(inv, &selection, &state_dir, out, err, &phase, || {
            resolve_budget(inv, &project, selection.listed.len())
        }) {
            return Err(exit);
        }
    }

    // ── 2. the stale set (§B.3 `-Qu` / §B.4 `-Su`) ────────────────────────
    // The installed record is the reference point whenever one exists: an
    // archive whose install was refused must stay stale, or the update
    // disappears from this verb for good.
    let installed = LocalDb::load(&pacman_db_root()).map_err(Exit::Usage)?;
    let stale: Vec<RecipeId> = prepare::stale_set(&root, &graph, &db, &installed, &ids)
        .into_iter()
        .map(|row| row.id)
        .collect();
    if stale.is_empty() {
        let subject = record::subject_id("-");
        let plan = vec![PlanRow {
            pkg: subject.clone(),
            action: PlanAction::Noop,
            reason: "empty-list".to_string(),
        }];
        let outcomes = vec![OutcomeRow {
            pkg: subject.clone(),
            status: RowStatus::Succeeded,
            rc: Some(0),
            dur: None,
            reason: "empty-list".to_string(),
        }];
        let run_outcome = RunOutcome::compute(&outcomes, inv.fail_fast, false, false);
        let mut record = record::build_run_record(
            inv,
            &inv.targets,
            &inv.ranges,
            None,
            plan,
            vec![subject],
            outcomes,
            &run_outcome,
            None,
        );
        // A dry run renders but never persists (§H.1).
        record.dry_run = inv.dry_run;
        let now = gsa_model::epoch_now();
        record.stamp.started = Some(now);
        record.stamp.ended = Some(now);
        let _ = write!(
            out,
            "{}",
            render::render_run_prose(&record, &state_dir.join("logs"), &[], None)
        );
        record::emit_machine_record(out, &record, &state_dir, err);
        return Ok(run_outcome.rc);
    }

    // ── 3. build+install the stale set through the normal pipeline ───────
    let mut update_inv = inv.clone();
    update_inv.targets = stale.iter().map(|id| id.as_str().to_string()).collect();
    update_inv.ranges = Vec::new();
    if !inv.sync_first {
        // `-Su` (H9): the pipeline must not sneak a sync in through its
        // pre-dispatch pass — the committed versions build as-is.
        update_inv.no_sync = true;
    }
    if inv.dry_run {
        // The dry run's typed exit owns its rc (a declined prompt is rc 3).
        return plan_only(&ctx, &update_inv, &project, &root, out, err);
    }
    let mode = if inv.modifiers.contains(&'f') {
        DecideMode::Force
    } else {
        DecideMode::Checked
    };
    run_build_with(&update_inv, out, err, Some(mode))
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
        // The profile error is `Budget::resolve`'s; a flag-supplied value
        // names its source the way the `--lanes`/`--jobs` ladder does
        // (blind-review finding, 2026-11-11).
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
    Budget::resolve(&intensity, lanes, jobs, baselines, facts, package_count).map_err(|e| {
        if inv.intensity.is_some() {
            format!("--intensity: {e}")
        } else {
            e
        }
    })
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
/// `build-tools` membership from the topology record only (§K.2). The
/// remediation latents (owner rule 2026-10-02) append after the selection in
/// force-queue order — a latent's edges resolve over selection+latent
/// indices (chain-internal order), while a selection node's edges stay
/// selection-local (a latent is never a normal prerequisite). `pre` carries
/// the pre-dispatch settlements (§B.8) per recipe id.
fn build_nodes(
    root: &std::path::Path,
    graph: &Graph<'_>,
    selection: &Selection,
    pre: &std::collections::BTreeMap<String, crate::prepare::NodePlan>,
    latents: &[String],
) -> Vec<SupNode> {
    let mut node_of: HashMap<usize, usize> = HashMap::new();
    for (node_idx, (_, id)) in selection.listed.iter().enumerate() {
        node_of.insert(
            graph.index_of(id.as_str()).expect("selection ids resolve"),
            node_idx,
        );
    }
    let mut latent_of: HashMap<usize, usize> = HashMap::new();
    for (offset, id) in latents.iter().enumerate() {
        if let Some(idx) = graph.index_of(id.as_str()) {
            latent_of.insert(idx, selection.listed.len() + offset);
        }
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
            pre: pre.get(id.as_str()).and_then(pre_settle),
            latent: false,
        });
    }
    for id in latents {
        let Some(idx) = graph.index_of(id.as_str()) else {
            continue;
        };
        let record = graph.record(idx);
        let prereqs: Vec<usize> = graph
            .prerequisites(idx)
            .into_iter()
            .filter_map(|p| node_of.get(&p).or_else(|| latent_of.get(&p)).copied())
            .collect();
        nodes.push(SupNode {
            id: RecipeId::new(id).expect("latents come from the topology"),
            recipe_dir: root.join(&record.path),
            core: record.groups.contains(&Group::Core),
            build_tools: record.groups.contains(&Group::BuildTools),
            prereqs,
            consumers: Vec::new(),
            batch: None,
            pre: None,
            latent: true,
        });
    }
    for node in 0..nodes.len() {
        for prereq in nodes[node].prereqs.clone() {
            nodes[prereq].consumers.push(node);
        }
    }
    nodes
}

/// The pre-dispatch settlement for one prepared node plan (§B.8): claims
/// and deferrals settle without a lane; builds dispatch normally.
fn pre_settle(plan: &crate::prepare::NodePlan) -> Option<PreSettle> {
    match plan {
        crate::prepare::NodePlan::Skip { reason, archives } => Some(PreSettle::Skip {
            reason: reason.clone(),
            archives: archives.clone(),
        }),
        crate::prepare::NodePlan::Defer { reason } => Some(PreSettle::Defer {
            reason: reason.clone(),
        }),
        _ => None,
    }
}

/// Anchor-derived coupled batches with at least two selected members
/// (contract §I.1 open decision 1: a failed member parks its batch mates
/// with reason `coupled-batch`). Each batch is ONE anchor's rebuild set
/// (docs/maintainer-guide.md "Updating coupled stacks"), so a failure parks
/// only its own batch's mates — never mates of an unrelated stack (E2).
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
            .filter_map(|m| node_of.get(m.id.as_str()).copied())
            .collect();
        if members.len() >= 2 {
            batches.push(members);
        }
    }
    batches
}

/// Rule 25(d)'s "run order" is the canonical BUILD order the supervisor
/// sequences installs in — not the plan listing, which `extend_selection`
/// grows by appending wave additions AFTER the ids that consume them.
fn build_order_ids(graph: &Graph<'_>, ids: &[RecipeId]) -> Vec<String> {
    let mut order: Vec<String> = ids.iter().map(|id| id.as_str().to_string()).collect();
    order.sort_by_key(|id| {
        let idx = graph.index_of(id).expect("selection ids resolve");
        graph.position(idx)
    });
    order
}

/// The in-run repair coverage set of one finished provider — the ids
/// strictly after `provider` in canonical build order (the input of
/// [`gsa_install::DecisionContext::later_installs`], rule 25(d) semantics
/// live there). A provider missing from the order covers nothing: fail
/// closed, never a dropped exposure.
fn later_after(order: &[String], provider: &str) -> Vec<String> {
    order
        .iter()
        .position(|subject| subject == provider)
        .map(|at| order[at + 1..].to_vec())
        .unwrap_or_default()
}

/// Rule 25(d) fail-closed refinement of [`later_after`]: an id the run has
/// ALREADY settled built against the PREVIOUS provider generation and can
/// never be repaired in-run, so a settled consumer is not coverage even when
/// it sits after the provider in build order (the landed-consumer hole).
/// Edge-ful consumers can never be settled at their provider's gate — their
/// dispatch waits on that provider's `done-ok` — so this only narrows the
/// edge-less subscriber class, which is exactly the class whose build order
/// is advisory and whose early landing otherwise strands a live link.
fn later_after_settled(order: &[String], provider: &str, settled: &[String]) -> Vec<String> {
    later_after(order, provider)
        .into_iter()
        .filter(|id| !settled.iter().any(|s| s == id))
        .collect()
}

/// The pre-dispatch ABI wave check's outcome (docs/plans/plan-native-pm.md §4.3).
#[derive(Default)]
pub(crate) struct WaveCheck {
    /// Wave members outside the run's selection — appended to the plan.
    pub additions: Vec<String>,
    /// The under-coverage refusal class fired (§E.3): every `refuse
    /// abi-consumer-uncovered …` row is already printed.
    pub uncovered: bool,
}

/// One state-read failure of the pre-dispatch ABI wave input, carried as the
/// refusal message. The gate is fail-closed (§G.1 rc 3): unreadable state
/// means the consumer wave is UNKNOWN, never empty, and a run that examined
/// nothing must not build a provider past its consumers.
pub(crate) struct WaveStateError(pub String);

/// The `-S`/`-B` pre-dispatch ABI wave check (docs/plans/plan-native-pm.md §4.3,
/// contract §E.3) — shared by the build pipeline and the `-n` plan. A
/// provider whose registered token already moved (its newest binpkg index
/// row ≠ what at least one consumer recorded at install) drags its consumer
/// wave into the plan. `abi-wave <provider> <member> <basis>` rows print for
/// EVERY wave member (additive diagnostics, deliberately outside the
/// `format: 2` block); wave members outside the selection come back as
/// `additions`; a wave member the topology cannot build prints its `refuse
/// abi-consumer-uncovered …` row and refuses the run. The wave itself is
/// `gsa-abi`'s one computation (record mismatches ∪ content truth ∪
/// coupled batches, fail-toward-whole-closure when records are missing) —
/// this seam only feeds it the state truth and renders its answer.
pub(crate) fn wave_check(
    out: &mut dyn Write,
    err: &mut dyn Write,
    graph: &Graph<'_>,
    selection: &Selection,
    state_dir: &std::path::Path,
    conf: Option<&std::path::Path>,
    recipe_of_name: &std::collections::BTreeMap<String, String>,
) -> Result<WaveCheck, WaveStateError> {
    // A state root that does not exist is a clean checkout, not unreadable
    // state: nothing was ever recorded, so no OBSERVABLE token move exists
    // and there is nothing to read. A root that EXISTS but cannot be read is
    // the refusal below (§J.1: the startup paths own creation).
    if !state_dir.is_dir() {
        return Ok(WaveCheck::default());
    }
    let state = match gsa_state::StateRoot::open(state_dir) {
        Ok(state) => state,
        Err(error) => {
            return Err(WaveStateError(format!(
                "ABI wave check refused: cannot open the state root {} ({error}) — the consumer wave is unknown, and a provider must never build past its consumers",
                state_dir.display()
            )));
        }
    };
    let index = match gsa_state::BinpkgIndex::load(&state) {
        Ok(index) => index,
        Err(error) => {
            return Err(WaveStateError(format!(
                "ABI wave check refused: cannot read the binpkg index ({error}) — the registered provider tokens are unknown"
            )));
        }
    };
    for corrupt in &index.corrupt {
        let _ = writeln!(
            err,
            "gsa: note: binpkg index: {}:{}: {} {}",
            corrupt.store, corrupt.line, corrupt.name, corrupt.detail
        );
    }
    let subs = match Subscriptions::load(&gsa_abi::subscriptions_path(state_dir)) {
        Ok(subs) => subs,
        Err(error) => {
            return Err(WaveStateError(format!(
                "ABI wave check refused: cannot read the install-time subscription records ({error}) — the consumers' recorded tokens are unknown"
            )));
        }
    };
    for corrupt in &subs.corrupt {
        let _ = writeln!(err, "gsa: note: {corrupt}");
    }

    // A token move: a SELECTED recipe whose newest registered token differs
    // from what at least one consumer recorded (`:=` semantics — the
    // recorded token must track the provider's). No index row or no record
    // is no observable move here; the planner's fail-toward fallback owns
    // the record-less case. The installed-ELF view (the content-truth
    // input) is read ONLY below, once a move exists — the common case
    // costs no installed-DB parse.
    let mut moves: Vec<TokenMove> = Vec::new();
    let mut drift_inputs: Vec<Vec<(String, Vec<String>)>> = Vec::new();
    for (_, id) in &selection.listed {
        let rows = index.rows_for(id.as_str());
        if rows.is_empty() {
            continue;
        }
        let newest_instance = rows[0].instance;
        // The provider's CURRENT token set: every output row of its newest
        // instance. A split provider ships one token per output, and a
        // record is current when ANY shipped output still carries it —
        // comparing against one arbitrary output's row made every rebuild
        // of a split recipe read as a token move (2026-11-03).
        let current: std::collections::BTreeSet<String> = rows
            .iter()
            .filter(|r| r.instance == newest_instance)
            .map(|r| r.abi_token.clone())
            .collect();
        // The one movement verdict (`gsa_abi::records_moved`): a `-`
        // placeholder record is record-less ("No index row or no record is
        // no observable move here") and a multi-output provider is current
        // across its whole token set — never one arbitrary row alone.
        let recorded = subs.for_provider(id.as_str());
        if !gsa_abi::records_moved(&recorded, &current) {
            continue;
        }
        // The content-truth input: one (pkgname, provides) pair per output
        // of the newest instance — a move is a whole-build fact.
        drift_inputs.push(
            rows.iter()
                .filter(|r| r.instance == newest_instance)
                .map(|r| {
                    let pkgname = r
                        .pkgnames
                        .first()
                        .map(|name| name.as_str())
                        .unwrap_or(r.pkgbase.as_str());
                    (pkgname.to_string(), r.provides.clone())
                })
                .collect(),
        );
        moves.push(TokenMove {
            provider: id.as_str().to_string(),
            old: recorded
                .iter()
                .find(|s| s.has_token())
                .map(|s| s.token.clone()),
            current,
            changed_provides: Vec::new(),
        });
    }
    if moves.is_empty() {
        return Ok(WaveCheck::default());
    }

    // The content-truth term's input: the installed-ELF view over the
    // parsed local DB. An unreadable installed DB is UNKNOWN WORLD STATE,
    // not "nothing installed": the record and topology terms still run, the
    // content-truth term goes quiet (and loudly so), and `installed: None`
    // tells the planner to fail closed — dead-record skips need a readable
    // world (rule 25(c): never under-expand). The ROOT is the one the
    // transaction will write (`--config`'s DBPath), and a named
    // configuration whose root cannot be resolved is a refusal: it is a
    // different machine, not unreadable world state (security-auditor F4).
    let db_root = pacman_db_root_for(conf)
        .map_err(|message| WaveStateError(format!("ABI wave check refused: {message}")))?;
    let (db, db_readable) = match LocalDb::load(&db_root) {
        Ok(db) => (db, true),
        Err(error) => {
            let _ = writeln!(
                err,
                "gsa: note: ABI wave check: installed view unavailable ({error}) — content-truth term disabled"
            );
            (LocalDb::default(), false)
        }
    };
    let view = gsa_install::abi_view(&db);
    for (movement, inputs) in moves.iter_mut().zip(drift_inputs) {
        for (pkgname, provides) in inputs {
            for drift in gsa_abi::provide_drift(&pkgname, &provides, &view) {
                if !movement.changed_provides.contains(&drift) {
                    movement.changed_provides.push(drift);
                }
            }
        }
    }

    let planned: BTreeSet<String> = selection
        .listed
        .iter()
        .map(|(_, id)| id.as_str().to_string())
        .collect();
    let plan = plan_waves(&WaveInputs {
        graph,
        subs: &subs,
        moves: &moves,
        installed: db_readable.then_some(&view),
        planned: &planned,
        recipe_of_name,
    });
    for wave in &plan.waves {
        for member in &wave.members {
            let _ = writeln!(
                out,
                "abi-wave {} {} {}",
                wave.provider,
                member.id,
                member.basis.wire()
            );
        }
    }
    for row in plan.refusal_rows() {
        let _ = writeln!(out, "{}", row.render());
    }
    for (provider, consumer) in &plan.stale_records {
        let _ = writeln!(out, "abi-stale-record {provider} {consumer} dead-record");
    }
    Ok(WaveCheck {
        additions: plan.additions,
        uncovered: !plan.uncovered.is_empty(),
    })
}

/// The prerequisite additions one run makes: the selection's transitive
/// build-order prerequisites with no installed output (owner decision
/// 2026-11-11 — expand to what the system is MISSING, never rebuild an
/// installed prerequisite). The installed DB is read only when the selection
/// actually has unselected prerequisites, so the common run pays nothing.
fn missing_prerequisite_additions(
    graph: &Graph<'_>,
    selection: &Selection,
    db: &RecipeDb,
    inv: &Invocation,
) -> Result<Vec<String>, String> {
    let candidates = prepare::prerequisite_candidates(graph, selection, inv.leaf);
    if candidates.is_empty() {
        return Ok(Vec::new());
    }
    let conf = inv.config.as_deref().map(std::path::Path::new);
    let db_root = gsa_install::localdb::pacman_db_root_for(conf)?;
    let installed = gsa_install::LocalDb::load(&db_root)?;
    Ok(prepare::missing_prerequisites(
        graph,
        &candidates,
        db,
        &installed,
    ))
}

/// Merge prerequisite additions into the selection in BUILD ORDER: plan,
/// record and dispatch carry the one topological order (§C.3), so an added
/// prerequisite precedes its consumer instead of trailing the plan. Anchors
/// are renumbered consecutively — they render the plan's row indices, and a
/// range was already resolved against the listing before this point.
fn merge_prerequisites(selection: &mut Selection, additions: &[String], graph: &Graph<'_>) {
    if additions.is_empty() {
        return;
    }
    for id in additions {
        selection.listed.push((
            0,
            RecipeId::new(id).expect("additions come from the topology"),
        ));
    }
    selection
        .listed
        .sort_by_key(|(_, id)| graph.index_of(id.as_str()).map(|idx| graph.position(idx)));
    for (n, (anchor, _)) in selection.listed.iter_mut().enumerate() {
        *anchor = n + 1;
    }
}

/// Append computed wave additions to the plan (anchors continue past the
/// closure: `closure_size + n`). Listing order does not steer dispatch —
/// the supervisor honours the build-order edges — but every anchor stays a
/// distinct 1-based position.
pub(crate) fn extend_selection(selection: &mut Selection, additions: &[String]) {
    // Anchors continue past BOTH the closure and anything already appended
    // (a run can add prerequisites and then wave members): every anchor stays
    // a distinct 1-based position, and no existing anchor renumbers.
    let mut next = selection
        .closure_size
        .max(selection.listed.iter().map(|(a, _)| *a).max().unwrap_or(0));
    for id in additions {
        next += 1;
        selection.listed.push((
            next,
            RecipeId::new(id).expect("additions come from the topology"),
        ));
    }
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
                        batch.members.iter().any(|m| m.id == row.pkg)
                            && batch.members.iter().any(|m| m.id == root.pkg)
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
    class: RefusalClass,
) -> Exit {
    let outcomes: Vec<OutcomeRow> = selection
        .listed
        .iter()
        .map(|(_, id)| OutcomeRow {
            pkg: id.clone(),
            status: RowStatus::NeverStarted,
            rc: None,
            dur: None,
            reason: class.key().to_string(),
        })
        .collect();
    let order: Vec<RecipeId> = selection.listed.iter().map(|(_, id)| id.clone()).collect();
    let plan_action = if inv.family == crate::args::Family::B {
        PlanAction::Build
    } else {
        PlanAction::BuildInstall
    };
    let plan: Vec<PlanRow> = order
        .iter()
        .map(|id| PlanRow {
            pkg: id.clone(),
            action: plan_action.clone(),
            reason: "ok".to_string(),
        })
        .collect();
    emit_refusal_record(inv, plan, order, outcomes, budget, state_dir, out, err);
    Exit::Refuse(Refusal::recorded(class))
}

/// A run the pre-dispatch pass refused (§G.1 rc 3 — integrity stop or a
/// named sync refusal): the offending package is `failed 1 - <reason>`,
/// everything else `never-started - - startup-refused`, and the plan rows
/// keep the planned action (the run-record refusal precedent).
fn refuse_prepared(
    inv: &Invocation,
    selection: &Selection,
    budget: &Budget,
    state_dir: &std::path::Path,
    prepared: &prepare::Prepared,
    at: usize,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Exit {
    let order: Vec<RecipeId> = selection.listed.iter().map(|(_, id)| id.clone()).collect();
    let build_install = inv.family != crate::args::Family::B;
    let plan = prepared.plan_rows(&order, build_install);
    // The row carries the §H.3 reason key verbatim; the class only carries
    // the rc, and falls back to the startup class for keys outside the
    // refusal roster (e.g. `toolchain-identity`).
    let class = match &prepared.packages[at].plan {
        prepare::NodePlan::Refuse { reason } => RefusalClass::from_key(reason),
        _ => None,
    }
    .unwrap_or(RefusalClass::StartupRefused);
    let outcomes: Vec<OutcomeRow> = order
        .iter()
        .enumerate()
        .map(|(index, id)| {
            if index == at {
                let reason = match &prepared.packages[index].plan {
                    prepare::NodePlan::Refuse { reason } => reason.clone(),
                    _ => "startup-refused".to_string(),
                };
                OutcomeRow {
                    pkg: id.clone(),
                    status: RowStatus::Failed,
                    rc: Some(1),
                    dur: None,
                    reason,
                }
            } else {
                OutcomeRow {
                    pkg: id.clone(),
                    status: RowStatus::NeverStarted,
                    rc: None,
                    dur: None,
                    reason: "startup-refused".to_string(),
                }
            }
        })
        .collect();
    emit_refusal_record(inv, plan, order, outcomes, budget, state_dir, out, err);
    Exit::Refuse(Refusal::recorded(class))
}

/// The one refusal-record emitter: plan + order + outcome rows → the three
/// renderings, `refused` outcome (§G.1 rc 3). Every caller returns the
/// typed [`Exit::Refuse`] afterwards — the code is not this function's to
/// pick.
fn emit_refusal_record(
    inv: &Invocation,
    plan: Vec<PlanRow>,
    order: Vec<RecipeId>,
    outcomes: Vec<OutcomeRow>,
    budget: &Budget,
    state_dir: &std::path::Path,
    out: &mut dyn Write,
    err: &mut dyn Write,
) {
    let run_outcome = RunOutcome::compute(&outcomes, inv.fail_fast, false, true);
    debug_assert_eq!(
        run_outcome.rc,
        crate::RC_REFUSED,
        "a refusal record must carry the refusal class (§G.1)"
    );
    // A refused run never reached fetch-ahead participation (owner decision
    // 5: the scalar counts a build run's prefetch advisories only).
    let mut record = record::build_run_record(
        inv,
        &inv.targets,
        &inv.ranges,
        Some(budget),
        plan,
        order,
        outcomes,
        &run_outcome,
        None,
    );
    // A refused run built nothing: no compiler is named, but the record still
    // answers WHEN the refusal happened (§H.2 amendment).
    let now = gsa_model::epoch_now();
    record.stamp.started = Some(now);
    record.stamp.ended = Some(now);
    let _ = write!(
        out,
        "{}",
        render::render_run_prose(&record, &state_dir.join("logs"), &[], None)
    );
    // A refused run is still a completed run record (§H.1) — persisted
    // like every other emission through the one store path.
    record::emit_machine_record(out, &record, state_dir, err);
}

#[cfg(test)]
mod tests {
    use super::{after_sync_phase, build_order_ids, later_after, later_after_settled, wave_check};
    use crate::args::{Family, Invocation};
    use crate::prepare;
    use crate::select::Selection;
    use gsa_model::RecipeId;
    use gsa_sched::budget::Budget;
    use std::path::PathBuf;

    /// A per-process scratch state root, removed again by [`scratch`]'s
    /// caller. Nothing outside it is touched (the fixture-battery rule).
    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "gsa-cli-build-{name}-{}-{}",
            std::process::id(),
            std::thread::current()
                .name()
                .unwrap_or("t")
                .replace(':', "_")
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("scratch dir");
        dir
    }

    fn budget() -> Budget {
        Budget {
            threads: 12,
            memory_gib: 30,
            intensity: "xhigh",
            lanes: 2,
            normal_jobs: 6,
            core_jobs: 4,
        }
    }

    fn selection_of(ids: &[&str]) -> Selection {
        Selection {
            listed: ids
                .iter()
                .enumerate()
                .map(|(n, id)| (n + 1, RecipeId::new(*id).expect("fixture id")))
                .collect(),
            closure_size: ids.len(),
            expansion_added: 0,
            seeds: ids
                .iter()
                .map(|id| RecipeId::new(*id).expect("fixture id"))
                .collect(),
            notes: Vec::new(),
        }
    }

    fn update_inv() -> Invocation {
        Invocation {
            output_mode: None,
            family: Family::S,
            action: None,
            modifiers: Vec::new(),
            sync_first: true,
            dry_run: false,
            leaf: false,
            color: crate::style::ColorChoice::Auto,
            targets: vec!["@git".to_string()],
            ranges: Vec::new(),
            deferred_flags: Vec::new(),
            fail_fast: false,
            lanes: None,
            jobs: None,
            intensity: None,
            state_dir: None,
            toolchain: None,
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
            build_dir: None,
            no_build_dir_prompt: false,
            allow_broken_rustc: false,
            standalone_root: None,
            standalone_tokens: Vec::new(),
        }
    }

    /// `-Syu`'s pre-build sync refusal is a STARTUP gate (§G.1 rc 3) and
    /// owes the same full record every other refusal emits (§H.1): the
    /// `-Syu` path used to return a bare 3 with no prose, no `format: 2`
    /// block and no run history. A deferral-only phase has no such row to
    /// carry and continues to the stale set.
    #[test]
    fn sync_refusal_emits_a_complete_record_and_returns_refused() {
        let dir = scratch("sync-refusal");
        let inv = update_inv();
        let selection = selection_of(&["glib2-git", "gtk4-git"]);
        let mut out: Vec<u8> = Vec::new();
        let mut err: Vec<u8> = Vec::new();
        let exit = after_sync_phase(
            &inv,
            &selection,
            &dir,
            &mut out,
            &mut err,
            &prepare::SyncPhase {
                refused: Some(crate::exit::RefusalClass::SyncRefused),
                deferred: Vec::new(),
            },
            || Ok(budget()),
        )
        .expect("a sync refusal is an exit, not a continue");
        // The refusal site returns the TYPED exit — class and record state —
        // never a bare number the renderer would have to guess about.
        assert!(
            matches!(
                &exit,
                crate::exit::Exit::Refuse(crate::exit::Refusal {
                    class: crate::exit::RefusalClass::SyncRefused,
                    record: crate::exit::RecordOwed::Yes,
                    note,
                }) if note.is_empty()
            ),
            "a -Syu sync refusal is a recorded SyncRefused: {exit:?}"
        );
        assert_eq!(
            exit.render(&mut err),
            3,
            "a sync refusal is the refusal class (§G.1)"
        );
        let text = String::from_utf8(out).expect("utf-8 record");
        for needle in [
            "--- run record begin ---",
            "format: 2",
            "outcome: refused",
            "rc: 3",
            "--- plan ---",
            "glib2-git never-started - - sync-refused",
            "gtk4-git never-started - - sync-refused",
            "--- continuation ---",
            "--- run record end ---",
        ] {
            assert!(text.contains(needle), "missing {needle:?} in:\n{text}");
        }
        // §H.1's amendment: the same record is persisted for `gsa -Mh`.
        let root = gsa_state::StateRoot::open(&dir).expect("state root");
        let (records, corrupt) = gsa_state::RunHistory::read(&root).expect("run history");
        assert!(corrupt.is_empty(), "{corrupt:?}");
        assert_eq!(records.len(), 1, "the refusal was not persisted");
        assert_eq!(records[0].rc, 3);
        assert_eq!(records[0].outcome, "refused");
        // The deferral half is not an exit: the pipeline re-derives the
        // `deferred 99` row for every stale recipe the sync deferred.
        let mut deferred_out: Vec<u8> = Vec::new();
        let mut err: Vec<u8> = Vec::new();
        assert!(after_sync_phase(
            &inv,
            &selection,
            &dir,
            &mut deferred_out,
            &mut err,
            &prepare::SyncPhase {
                refused: None,
                deferred: vec![("gtk4-git".to_string(), "source-unfetchable".to_string())],
            },
            || Ok(budget()),
        )
        .is_none());
        // A bad budget spelling outranks the refusal with the usage class.
        let mut out: Vec<u8> = Vec::new();
        assert_eq!(
            after_sync_phase(
                &inv,
                &selection,
                &dir,
                &mut out,
                &mut err,
                &prepare::SyncPhase {
                    refused: Some(crate::exit::RefusalClass::SyncRefused),
                    deferred: Vec::new(),
                },
                || Err("--lanes: garbage".to_string()),
            ),
            Some(crate::exit::Exit::Usage("--lanes: garbage".to_string()))
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// The ABI wave gate is fail-closed (§G.1 rc 3): a state root that
    /// exists but cannot be read means the consumer wave is UNKNOWN. It used
    /// to note-and-continue with an empty wave, so the run silently skipped
    /// the gate and could build a provider past its consumers.
    #[test]
    fn an_unreadable_state_root_refuses_the_wave_gate_instead_of_carrying_on() {
        let dir = scratch("wave-gate");
        // A directory where the subscription-records FILE belongs: the path
        // exists, so it is not the clean-checkout case, but it is no store.
        std::fs::create_dir_all(dir.join("abi").join("subscriptions")).expect("subscriptions dir");
        let records = vec![record("glib2-git", &[]), record("gtk4-git", &["glib2-git"])];
        let graph = gsa_graph::Graph::build(&records).expect("acyclic fixture");
        let selection = selection_of(&["glib2-git", "gtk4-git"]);
        let mut out: Vec<u8> = Vec::new();
        let mut err: Vec<u8> = Vec::new();
        let result = wave_check(
            &mut out,
            &mut err,
            &graph,
            &selection,
            &dir,
            None,
            &std::collections::BTreeMap::new(),
        );
        let error = match result {
            Ok(_) => panic!("unreadable state must refuse the wave gate, not skip it"),
            Err(error) => error.0,
        };
        assert!(
            error.contains("ABI wave check refused"),
            "the refusal names itself: {error}"
        );
        let note = String::from_utf8(err).expect("utf-8 note");
        assert!(
            !note.contains("skipped"),
            "the gate must never note-and-continue: {note}"
        );
        // A root that does NOT exist stays the clean-checkout case: nothing
        // was ever recorded, so there is no observable token move.
        let absent = dir.join("absent");
        let mut err: Vec<u8> = Vec::new();
        assert!(wave_check(
            &mut out,
            &mut err,
            &graph,
            &selection,
            &absent,
            None,
            &std::collections::BTreeMap::new()
        )
        .is_ok());
        let _ = std::fs::remove_dir_all(&dir);
    }

    fn order(ids: &[&str]) -> Vec<String> {
        ids.iter().map(|s| s.to_string()).collect()
    }

    fn record(id: &str, edges: &[&str]) -> gsa_model::TopologyRecord {
        gsa_model::TopologyRecord {
            id: gsa_model::RecipeId::new(id).expect("fixture id"),
            path: format!("{id}/PKGBUILD"),
            groups: Vec::new(),
            edges: edges
                .iter()
                .map(|e| gsa_model::RecipeId::new(*e).expect("fixture edge"))
                .collect(),
            tags: Vec::new(),
            source_line: 1,
        }
    }

    /// Rule 25(d) is ORDER truth: a consumer strictly after the provider is
    /// covered even when its lane already landed (parallel lanes finish out
    /// of order — the completion-based remainder false-refused icu-git over
    /// exactly this, 2026-10-30).
    #[test]
    fn later_after_covers_every_id_strictly_after_the_provider() {
        let o = order(&["a", "provider", "c", "d"]);
        assert_eq!(later_after(&o, "provider"), order(&["c", "d"]));
    }

    /// The completion-based remainder's opposite bug: an id BEFORE the
    /// provider is never coverage, no matter what has landed.
    #[test]
    fn later_after_never_covers_ids_before_the_provider() {
        let o = order(&["before", "provider", "after"]);
        assert_eq!(later_after(&o, "provider"), order(&["after"]));
    }

    /// The landed-consumer hole (2026-10-31 review): a consumer that
    /// already settled built against the PREVIOUS provider generation and
    /// is un-repairable in-run — order position alone must not cover it,
    /// while a still-queued later consumer stays coverage.
    #[test]
    fn later_after_settled_excludes_already_landed_consumers() {
        let o = order(&["provider", "early", "queued"]);
        assert_eq!(
            later_after_settled(&o, "provider", &order(&["early"])),
            order(&["queued"])
        );
        assert_eq!(
            later_after_settled(&o, "provider", &[]),
            order(&["early", "queued"])
        );
    }

    /// A provider missing from the order covers nothing (fail closed).
    #[test]
    fn later_after_unknown_provider_covers_nothing() {
        let o = order(&["a", "b"]);
        assert!(later_after(&o, "stranger").is_empty());
        assert!(later_after(&[], "a").is_empty());
    }

    /// The additions path: `extend_selection` APPENDS wave additions after
    /// the ids that consume them, while the supervisor dispatches by the
    /// build-order edges — coverage must read the build order, or a
    /// dragged-in provider false-refuses its own listed-earlier consumer
    /// (the icu-git wall class through the additions door).
    #[test]
    fn coverage_reads_build_order_not_listing_order() {
        let records = vec![record("consumer", &["provider"]), record("provider", &[])];
        let graph = gsa_graph::Graph::build(&records).expect("acyclic fixture");
        let listed = order(&["consumer", "provider"]);
        let listed_ids: Vec<gsa_model::RecipeId> = listed
            .iter()
            .map(|id| gsa_model::RecipeId::new(id.as_str()).expect("fixture id"))
            .collect();
        let built = build_order_ids(&graph, &listed_ids);
        assert_eq!(later_after(&built, "provider"), order(&["consumer"]));
    }
}
