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
use gsa_install::localdb::{pacman_db_root, LocalDb};
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
use crate::prepare;
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
    // A standalone-target run staged its own workspace (plan W4); the rest
    // discover the recipe workspace as before.
    let root = match crate::resolve_workspace(inv) {
        Ok(root) => root,
        Err(message) => {
            let _ = writeln!(err, "gsa: {message}");
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
    let mut selection = match select::build_selection(&ctx, &inv.targets, &inv.ranges, inv.leaf) {
        Ok(selection) => selection,
        Err(error) => {
            let _ = writeln!(err, "gsa: {}", error.message);
            return 2;
        }
    };
    crate::write_notes(err, &selection.notes);

    // ── privilege gate (contract §B.10; after every usage preflight) ─────
    if let Some(code) = crate::privilege_gate(
        &inv.spelling(),
        crate::invocation_privilege(inv, &crate::Command::Build),
        true,
        err,
    ) {
        return code;
    }

    // ── state root (contract §J.3): --state-dir > GSA_STATE_DIR > the
    //    gsa.conf layers (user > system) > /var/lib/gsa ─────────────────
    let state_dir = match gsa_model::config::resolve_state_dir(inv.state_dir.as_deref()) {
        Ok(dir) => dir,
        Err(message) => {
            let _ = writeln!(err, "gsa: {message}");
            return 2;
        }
    };

    // ── the pre-dispatch ABI wave check (plan-native-pm.md §4.3, §E.3) ──
    // A provider whose registered token already moved (newest binpkg index
    // row ≠ what its consumers recorded at install) drags its consumer
    // wave into the plan: wave members outside the selection are added,
    // and an uncovered member refuses the run (rc 3) before anything runs.
    let wave = match wave_check(out, err, &graph, &selection, &state_dir) {
        Ok(wave) => wave,
        Err(message) => {
            let _ = writeln!(err, "gsa: {message}");
            return 2;
        }
    };
    extend_selection(&mut selection, &wave.additions);

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

    // ── startup refusals (§G.1 rc 3) ─────────────────────────────────────
    // Under-coverage (§E.3): a wave member the topology cannot build —
    // the refusal rows are already printed; nothing transacts, nothing
    // builds.
    if wave.uncovered {
        return refuse_before_dispatch(
            inv,
            &selection,
            &budget,
            &state_dir,
            out,
            err,
            "abi-consumer-uncovered",
        );
    }
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
        // §J.2/§J.3's one layout error policy: the shared-PKGDEST leg needs
        // the layout, and a failure is fatal for the run — never a silent
        // prune of only the recipe-dir trees (`.ok()` swallowed the error
        // and the prune quietly stopped covering the cache).
        let layout = match gsa_model::config::build_layout_for_run() {
            Ok(layout) => layout,
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
    }
    // 2. the version-sync + freshness pass (one pass, canonical order).
    let cfg = match prepare::pass_config(inv) {
        Ok(cfg) => cfg,
        Err(message) => {
            let _ = writeln!(err, "gsa: {message}");
            return 2;
        }
    };
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
        return refuse_prepared(
            inv, &selection, &budget, &state_dir, &prepared, at, out, err,
        );
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
    let install_hook: Option<Box<dyn FnMut(&str, &std::path::Path, bool) -> InstallStep + Send>> =
        install.map(|mode| {
            let state_dir = state_dir.clone();
            let conf = inv.config.as_ref().map(PathBuf::from);
            let pacman_args = inv.pacman_args.clone().unwrap_or_default();
            let register_ignorepkg = !inv
                .deferred_flags
                .iter()
                .any(|f| f == "--no-register-ignorepkg");
            let mut later: Vec<String> = ids.iter().map(|id| id.as_str().to_string()).collect();
            Box::new(
                move |pkg: &str, recipe_dir: &std::path::Path, forced: bool| {
                    later.retain(|subject| subject != pkg);
                    // A remediation force build installs in force mode (fish
                    // `lane_force_install=1`): never the same-version skip.
                    let mode = if forced { DecideMode::Force } else { mode };
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
                            match gsa_recipe::toolchain::gcc_identity() {
                                Ok(identity) => {
                                    if let Err(error) = gsa_recipe::toolchain::write_marker(
                                        &state_dir, pkg, &identity,
                                    ) {
                                        notes.push(format!("toolchain marker: {pkg}: {error}"));
                                    }
                                }
                                Err(error) => notes.push(format!(
                                    "toolchain marker: {pkg}: cannot determine the GCC build identity ({error})"
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
    let outcome = match supervisor::run(
        setup,
        &mut |event| {
            let _ = write!(out, "{}", render::render_event(event, &event_ids));
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
    let record = record::build_run_record(
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

/// The `-n` plan rendering (contract §B `--dry-run`) shared by `gsa -S
/// --dry-run` and `gsa -Su --dry-run`: the pre-dispatch ABI wave check, the
/// plan prose and the `format: 2` plan record — no mutation, no dispatch.
pub(crate) fn plan_only(
    ctx: &select::Ctx,
    inv: &Invocation,
    project: &ProjectConfig,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<i32, String> {
    if inv.targets.is_empty() {
        return Err("selection is mandatory: a build never starts without a selection".to_string());
    }
    let mut selection = select::build_selection(ctx, &inv.targets, &inv.ranges, inv.leaf)
        .map_err(|error| error.message)?;
    crate::write_notes(err, &selection.notes);
    // The same pre-dispatch ABI wave check the build pipeline runs (§E.3):
    // the dry-run shows the wave it would build — additions join the plan,
    // and an under-covered member refuses (rc 3).
    let state_dir = gsa_state::resolve_state_root(inv.state_dir.as_deref());
    let wave = wave_check(out, err, ctx.graph, &selection, &state_dir)?;
    extend_selection(&mut selection, &wave.additions);
    let intensity = crate::resolve_intensity(project)?;
    let expansion_added = selection.closure_size.saturating_sub(selection.seeds.len());
    let _ = write!(
        out,
        "{}",
        render::render_plan_prose(
            &selection.listed,
            expansion_added,
            selection.closure_size,
            inv.leaf,
            true
        )
    );
    let rec = record::build_plan_record(inv, &selection, &inv.targets, &inv.ranges, &intensity);
    let _ = write!(out, "{}", rec.render_machine());
    if wave.uncovered {
        return Ok(crate::RC_REFUSED);
    }
    Ok(crate::RC_OK)
}

/// `gsa -Su` (contract §B.4): `-Sy`, then build+install the stale set.
///
/// The sync phase runs first over the selection (default: every recipe) —
/// its disposition block prints and a sync refusal aborts (§G.1 rc 3)
/// before anything builds. The stale set is then computed from the
/// REWRITTEN (tracked) versions against the newest complete built set and
/// handed to the normal build+install pipeline; that pipeline's own
/// pre-dispatch pass re-runs the sync for the stale subset (idempotent —
/// `NoChange`), which is what keeps the deferral row shapes (`deferred 99 -
/// <reason>`) intact instead of losing them across a phase boundary. A
/// `--dry-run` never rewrites recipes and renders the plan record only. An
/// empty stale set is the §E.3 `noop empty-list` row, rc 0.
pub fn run_update(inv: &Invocation, out: &mut dyn Write, err: &mut dyn Write) -> i32 {
    let root = match crate::resolve_workspace(inv) {
        Ok(root) => root,
        Err(message) => {
            let _ = writeln!(err, "gsa: {message}");
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
    let selection = match prepare::pass_selection(&ctx, inv) {
        Ok(selection) => selection,
        Err(error) => {
            let _ = writeln!(err, "gsa: {error}");
            return 2;
        }
    };
    crate::write_notes(err, &selection.notes);

    // ── privilege gate (contract §B.10; after every usage preflight) ─────
    if let Some(code) = crate::privilege_gate(
        &inv.spelling(),
        crate::invocation_privilege(inv, &crate::Command::Update),
        true,
        err,
    ) {
        return code;
    }

    let ids: Vec<RecipeId> = selection.listed.iter().map(|(_, id)| id.clone()).collect();
    let state_dir = gsa_state::resolve_state_root(inv.state_dir.as_deref());

    // ── 1. the `-Sy` phase. A dry run never rewrites recipes, so it runs
    //    no sync at all; a sync refusal aborts before anything builds, and
    //    a deferral is reported and carried into the build rows below.
    if !inv.dry_run {
        let (refused, _deferred) = prepare::sync_phase(&root, &graph, &selection, out, err);
        if refused {
            return crate::RC_REFUSED;
        }
    }

    // ── 2. the stale set (§B.3 `-Qu` / §B.4 `-Su`) ────────────────────────
    let stale = prepare::stale_set(&root, &graph, &ids);
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
        let _ = write!(
            out,
            "{}",
            render::render_run_prose(&record, &state_dir.join("logs"), &[], None)
        );
        record::emit_machine_record(out, &record, &state_dir, err);
        return run_outcome.rc;
    }

    // ── 3. build+install the stale set through the normal pipeline ───────
    let mut update_inv = inv.clone();
    update_inv.targets = stale.iter().map(|id| id.as_str().to_string()).collect();
    update_inv.ranges = Vec::new();
    if inv.dry_run {
        return plan_only(&ctx, &update_inv, &project, out, err).unwrap_or_else(|message| {
            let _ = writeln!(err, "gsa: {message}");
            2
        });
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

/// The pre-dispatch ABI wave check's outcome (plan-native-pm.md §4.3).
#[derive(Default)]
pub(crate) struct WaveCheck {
    /// Wave members outside the run's selection — appended to the plan.
    pub additions: Vec<String>,
    /// The under-coverage refusal class fired (§E.3): every `refuse
    /// abi-consumer-uncovered …` row is already printed.
    pub uncovered: bool,
}

/// The `-S`/`-B` pre-dispatch ABI wave check (plan-native-pm.md §4.3,
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
) -> Result<WaveCheck, String> {
    // State truth, read-only and best-effort: the binpkg index (the
    // registered tokens) and the install-time `:=` subscription records.
    // This seam never creates state and never fails the run — no readable
    // state means no OBSERVABLE token move (loudly noted where it matters),
    // and the run's own startup paths own state-root refusals (§G.1 rc 3).
    if !state_dir.is_dir() {
        return Ok(WaveCheck::default());
    }
    let state = match gsa_state::StateRoot::open(state_dir) {
        Ok(state) => state,
        Err(error) => {
            let _ = writeln!(err, "gsa: note: ABI wave check skipped ({error})");
            return Ok(WaveCheck::default());
        }
    };
    let index = match gsa_state::BinpkgIndex::load(&state) {
        Ok(index) => index,
        Err(error) => {
            let _ = writeln!(err, "gsa: note: ABI wave check skipped: {error}");
            return Ok(WaveCheck::default());
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
            let _ = writeln!(err, "gsa: note: ABI wave check skipped: {error}");
            return Ok(WaveCheck::default());
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
    let mut drift_inputs: Vec<(String, Vec<String>)> = Vec::new();
    for (_, id) in &selection.listed {
        let rows = index.rows_for(id.as_str());
        let Some(row) = rows.first().copied() else {
            continue;
        };
        let recorded = subs.for_provider(id.as_str());
        if recorded.is_empty() || recorded.iter().all(|s| s.token == row.abi_token) {
            continue;
        }
        let pkgname = row
            .pkgnames
            .first()
            .map(|name| name.as_str())
            .unwrap_or(row.pkgbase.as_str());
        drift_inputs.push((pkgname.to_string(), row.provides.clone()));
        moves.push(TokenMove {
            provider: id.as_str().to_string(),
            old: recorded.first().map(|s| s.token.clone()),
            new: row.abi_token.clone(),
            changed_provides: Vec::new(),
        });
    }
    if moves.is_empty() {
        return Ok(WaveCheck::default());
    }

    // The content-truth term's input: the installed-ELF view over the
    // parsed local DB. An unreadable installed DB is "nothing installed":
    // the record terms still run, only the content-truth term goes quiet
    // (and loudly so).
    let db = match LocalDb::load(&pacman_db_root()) {
        Ok(db) => db,
        Err(error) => {
            let _ = writeln!(
                err,
                "gsa: note: ABI wave check: installed view unavailable ({error}) — content-truth term disabled"
            );
            LocalDb::default()
        }
    };
    let view = gsa_install::abi_view(&db);
    for (movement, (pkgname, provides)) in moves.iter_mut().zip(drift_inputs) {
        movement.changed_provides = gsa_abi::provide_drift(&pkgname, &provides, &view)
            .into_iter()
            .map(|drift| drift.name)
            .collect();
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
        installed: Some(&view),
        planned: &planned,
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
    Ok(WaveCheck {
        additions: plan.additions,
        uncovered: !plan.uncovered.is_empty(),
    })
}

/// Append computed wave additions to the plan (anchors continue past the
/// closure: `closure_size + n`). Listing order does not steer dispatch —
/// the supervisor honours the build-order edges — but every anchor stays a
/// distinct 1-based position.
pub(crate) fn extend_selection(selection: &mut Selection, additions: &[String]) {
    for (n, id) in additions.iter().enumerate() {
        selection.listed.push((
            selection.closure_size + n + 1,
            RecipeId::new(id).expect("wave additions come from the topology"),
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
    emit_refusal_record(inv, plan, order, outcomes, budget, state_dir, out, err)
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
) -> i32 {
    let order: Vec<RecipeId> = selection.listed.iter().map(|(_, id)| id.clone()).collect();
    let build_install = inv.family != crate::args::Family::B;
    let plan = prepared.plan_rows(&order, build_install);
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
    emit_refusal_record(inv, plan, order, outcomes, budget, state_dir, out, err)
}

/// The one refusal-record emitter: plan + order + outcome rows → the three
/// renderings, `refused` outcome (§G.1 rc 3).
fn emit_refusal_record(
    inv: &Invocation,
    plan: Vec<PlanRow>,
    order: Vec<RecipeId>,
    outcomes: Vec<OutcomeRow>,
    budget: &Budget,
    state_dir: &std::path::Path,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> i32 {
    let run_outcome = RunOutcome::compute(&outcomes, inv.fail_fast, false, true);
    // A refused run never reached fetch-ahead participation (owner decision
    // 5: the scalar counts a build run's prefetch advisories only).
    let record = record::build_run_record(
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
