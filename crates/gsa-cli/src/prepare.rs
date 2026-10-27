//! Pre-build preparation (contract §B.4/§B.8): the version-sync pass (`gsa
//! -Sy` and the pre-build step of every build run), the GCC toolchain drift
//! gate, the `--skip`/`--skip-built` freshness claims, and the `-Su` stale
//! set. One pass runs per selected recipe in canonical build order BEFORE any
//! lane dispatches, and its answers become the run's plan rows (`skip
//! <reason>`, §H.2) and pre-settled outcomes (deferrals, refusals):
//!
//! 1. **toolchain drift gate** (`gsa_recipe::toolchain`): a missing/changed
//!    GCC build-identity marker forces the one-time clean (trees + archives +
//!    VCS baselines) even under `--skip`. When a skip claim is in play the
//!    freshness decision runs BEFORE the clean (fish `build_package`'s
//!    pre-check) so an unreachable ref still defers with its evidence intact.
//! 2. **version-sync** (`gsa_recipe::sync`, rule 18) unless `--no-sync`:
//!    the Arch provider pass for untagged `packages/stable` recipes, the
//!    nvchecker path for `version-sync=nvchecker` tagged recipes. Rewrite +
//!    anchor, transactional, left UNCOMMITTED. A provider outage is a
//!    deferral (`anchoring-refused` / `source-unfetchable` /
//!    `upstream-unverified`), never an invented version; a published-checksum
//!    disagreement is an integrity stop (run-wide abort, rc 3).
//! 3. **skip claim** (`gsa_recipe::freshness`) under `--skip` / `--skip-built`:
//!    only when the sync established "nothing to do" (`skip_allowed`), and
//!    with `absorb_wait` = the consumer chain can absorb a deferral (fish
//!    `unverifiable_defer_plan`, waiter cap 3).
//!
//! The `-Sy` surface prints the run-level disposition block
//! (`sync::render_disposition`) and commits nothing; `-Su` runs the pass and
//! then builds+installs the stale set. Everything external resolves through
//! `PATH` — including the transport-retry backoff, which shells out to
//! `sleep` so fixtures can cap it (`tests/lib/fixture-lib.bash` `stub_sleep`,
//! the fish-era convention this port keeps).

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use gsa_graph::Graph;
use gsa_model::{PlanAction, PlanRow, RecipeId, Tag};
use gsa_recipe::freshness::{self, Discovery, FreshnessContext, ProbeOptions, SkipMode, Verdict};
use gsa_recipe::sync::{
    self, AnchorOutcome, DispositionRow, NvcheckerRunner, ProviderError, ProviderFamily,
    RefusalClass, SyncOutcome, SyncPolicy, SyncReport, VersionProvider,
};
use gsa_recipe::toolchain;
use gsa_topo::load_project;

use crate::args::Invocation;
use crate::select::{self, Ctx, Selection};

/// How many transitive consumers may wait on one parked recipe before the
/// chain "cannot absorb the wait" (fish `_DEFER_WAITER_CAP`).
pub const DEFER_WAITER_CAP: usize = 3;

/// What the pre-dispatch pass decided for one selected recipe.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum NodePlan {
    /// Build normally (the detail names why, for the package log).
    Build { reason: String },
    /// Claim the built set: no lane, but on `-S` the claimed archives still
    /// install before consumers compile (§B.8 `--skip`).
    Skip {
        /// The §H.3 claim key: `ok` / `skip-built` / `freshness-waived` /
        /// `abi-provider-waived`.
        reason: String,
        /// The claimed archive set.
        archives: Vec<PathBuf>,
    },
    /// Park the recipe (lane rc 99 class): `anchoring-refused` /
    /// `source-unfetchable` / `upstream-unverified` (§H.3).
    Defer { reason: String },
    /// Fail-closed refusal class (§G.1 rc 3): integrity stop or a named sync
    /// refusal. The run aborts before dispatch.
    Refuse { reason: String },
}

/// One recipe's preparation outcome.
pub struct PackagePrep {
    pub plan: NodePlan,
    /// Loud per-recipe lines (waivers, drift notes, provider errors) —
    /// rendered to stderr and never re-derived.
    pub log: Vec<String>,
}

/// The whole pass over one selection, in canonical build order.
pub struct Prepared {
    pub packages: Vec<PackagePrep>,
}

impl Prepared {
    /// Plan rows for the run record (§H.2): `skip <reason>` for a claim,
    /// the family's build action otherwise.
    pub fn plan_rows(&self, ids: &[RecipeId], build_install: bool) -> Vec<PlanRow> {
        let default = if build_install {
            PlanAction::BuildInstall
        } else {
            PlanAction::Build
        };
        ids.iter()
            .zip(&self.packages)
            .map(|(id, prep)| {
                let (action, reason) = match &prep.plan {
                    NodePlan::Skip { reason, .. } => (PlanAction::Skip, reason.clone()),
                    _ => (default, "ok".to_string()),
                };
                PlanRow {
                    pkg: id.clone(),
                    action,
                    reason,
                }
            })
            .collect()
    }

    /// The first refusal, if any (its index into the selection).
    pub fn first_refusal(&self) -> Option<usize> {
        self.packages
            .iter()
            .position(|p| matches!(p.plan, NodePlan::Refuse { .. }))
    }
}

/// The pass configuration the flags resolve to (§B.8).
pub struct PassConfig {
    /// `--skip` / `--skip-built` / none.
    pub skip_mode: Option<SkipMode>,
    /// The resolved `--vcs-skip-tolerance` (flag beats env beats default).
    pub tolerance: u64,
    /// `--no-sync`: no provider query, no anchoring, no rewrite.
    pub no_sync: bool,
    /// Loud resolver notes (a rejected `GSA_VCS_SKIP_TOLERANCE`, …) the
    /// caller must print: a silently ignored knob would make skip decisions
    /// unexplainable.
    pub notes: Vec<String>,
}

/// Resolve the pass configuration from an invocation; `Err` is a usage-class
/// message naming the flag (rc 2).
pub fn pass_config(inv: &Invocation) -> Result<PassConfig, String> {
    let tolerance_flag = match &inv.vcs_skip_tolerance {
        Some(raw) => {
            let parsed: Option<u64> = raw.parse().ok();
            match parsed {
                Some(n) if n >= 1 => Some(n),
                _ => {
                    return Err(format!(
                        "--vcs-skip-tolerance: '{raw}' must be a positive integer"
                    ))
                }
            }
        }
        None => None,
    };
    let resolution = freshness::resolve_vcs_skip_tolerance(tolerance_flag);
    // One skip MODE per run (§B.8): the two claims are different analyses,
    // not combinable. `args::parse` refuses the both-set spelling at parse
    // time; this gate keeps the invariant at the seam itself for callers
    // that construct an Invocation directly — never silent precedence.
    let skip_mode = match (inv.skip, inv.skip_built) {
        (true, true) => {
            return Err(
                "cannot combine --skip with --skip-built (pick one skip claim: --skip is freshness-gated, --skip-built is the built-set claim)"
                    .to_string(),
            )
        }
        (true, false) => Some(SkipMode::Skip),
        (false, true) => Some(SkipMode::SkipBuilt),
        (false, false) => None,
    };
    Ok(PassConfig {
        skip_mode,
        tolerance: resolution.tolerance,
        no_sync: inv.no_sync,
        notes: resolution.warning.into_iter().collect(),
    })
}

/// The PATH-resolved backoff sleeper: fixtures cap latency with a `sleep`
/// stub (fixture-lib.bash `stub_sleep`), the fish-era convention this port
/// keeps — the sleep must therefore be a PATH command, never
/// `std::thread::sleep`. A missing `sleep` binary falls back to a real sleep.
fn path_sleep(d: Duration) {
    let ok = Command::new("sleep")
        .arg(format!("{}", d.as_secs_f64()))
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if !ok {
        std::thread::sleep(d);
    }
}

/// Can this recipe's consumer chain absorb a deferral? (fish
/// `unverifiable_defer_plan`: waiters ≤ [`DEFER_WAITER_CAP`] — a package with
/// no consumers may always park.)
fn absorb_wait(graph: &Graph<'_>, idx: usize) -> bool {
    let closure = graph.consumer_closure(&[idx]);
    closure.len().saturating_sub(1) <= DEFER_WAITER_CAP
}

/// The recipe's expanded `source=()` entries (the way makepkg reads them);
/// `None` when the array cannot be evaluated (eval failure = never claim
/// fresh).
fn recipe_sources(recipe_dir: &Path) -> Result<Vec<String>, sync::EvalError> {
    sync::pkgbuild_array_checked(recipe_dir, "source")
}

/// The nvchecker provider for one opted-in recipe: the tracker section is
/// keyed by the same identity rule [`sync::RecipeInfo::read`] applies —
/// pkgbase first, the single pkgname second (split recipes like
/// `zen-browser-pgo` name the tracker section for their one output), the
/// directory name last — and the identity comes from the SAME section —
/// never guessed.
fn nvchecker_provider(
    recipe_dir: &Path,
    repo_root: &Path,
    pkgbase: &str,
) -> Result<Box<dyn VersionProvider>, String> {
    let runner = NvcheckerRunner {
        config: recipe_dir.join(".nvchecker.toml"),
        repo_root: repo_root.to_path_buf(),
    };
    let dir_name = recipe_dir
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_default();
    let single_pkgname = match sync::pkgbuild_array_checked(recipe_dir, "pkgname") {
        Ok(names) if names.len() == 1 => names.into_iter().next().unwrap_or_default(),
        _ => String::new(),
    };
    let mut keys: Vec<String> = Vec::new();
    for key in [pkgbase.to_string(), single_pkgname, dir_name] {
        if !key.is_empty() && !keys.contains(&key) {
            keys.push(key);
        }
    }
    let mut last_error = String::from("cannot classify the nvchecker provider");
    for key in &keys {
        match runner.provider_identity(key) {
            Ok((ProviderFamily::Aur, id)) => {
                return Ok(Box::new(sync::AurProvider::new(runner, id)))
            }
            Ok((ProviderFamily::Github, id)) => {
                return Ok(Box::new(sync::GithubProvider::new(runner, id)))
            }
            Ok((family, _)) => {
                return Err(format!(
                    "unsupported nvchecker provider family {family:?} (section {key:?})"
                ))
            }
            Err(ProviderError::Unsupported(m)) => return Err(m),
            Err(ProviderError::Invalid(m)) => last_error = m,
            Err(e) => return Err(format!("{e}")),
        }
    }
    Err(last_error)
}

/// One recipe's version-sync pass (`-Sy` and the pre-build step). The recipe
/// is left rewritten and UNCOMMITTED on success, byte-identical on every
/// failure path (rule 18).
pub fn sync_one(recipe_dir: &Path, root: &Path, idx: usize, graph: &Graph<'_>) -> SyncReport {
    let policy = SyncPolicy {
        repo_root: root.to_path_buf(),
    };
    let nvchecker = graph.record(idx).tags.contains(&Tag::VersionSyncNvchecker);
    if !nvchecker {
        return sync::sync_arch(recipe_dir, &sync::ArchOfficial, &policy);
    }
    // Opted-in nvchecker path. The provider identity is read from the
    // recipe's own tracker section; an unclassifiable/unsupported provider is
    // a named refusal — never a guessed mapping.
    let pkgbase = sync::pkgbuild_var(recipe_dir, "pkgbase").unwrap_or_default();
    let pkg = recipe_dir
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_default();
    let pkgbase = if pkgbase.is_empty() {
        pkg.clone()
    } else {
        pkgbase
    };
    let provider = match nvchecker_provider(recipe_dir, root, &pkgbase) {
        Ok(provider) => provider,
        Err(message) => {
            return SyncReport {
                pkg,
                outcome: SyncOutcome::Refused {
                    class: RefusalClass::UnsafeVersionText,
                    message: format!(
                        "cannot classify the nvchecker provider — {message}; version sync cannot rewrite blind"
                    ),
                    restored: sync::RestoreStatus::NothingToRestore,
                },
                anchor: None,
                rows: Vec::new(),
                log: Vec::new(),
            }
        }
    };
    sync::sync_nvchecker(recipe_dir, provider.as_ref(), &policy)
}

/// The typed classification of one sync report for the pre-dispatch pass —
/// the fish `build_package` rc contract (0/1/3/4/99) as data.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum SyncClass {
    /// Nothing to do (or rewritten cleanly): continue.
    Continue,
    /// Version/release moved: continue, but no skip claim may be made.
    Rewritten,
    /// Provider outage/anchoring refusal: park with this §H.3 reason.
    Defer(&'static str),
    /// Fail-closed (integrity stop or named refusal): run-wide abort (§G.1
    /// rc 3) with this row reason.
    Refuse(String),
}

/// Classify one sync report. `absorb` answers whether the consumer chain can
/// wait (only the query-failure path consults it — an anchoring refusal
/// always parks, fish `sync_stable_version`'s rc 99).
pub fn classify_sync(report: &SyncReport, absorb: bool) -> (SyncClass, Vec<String>) {
    // The report's own log is the loud render — owner-labelled anchor lines,
    // integrity message, provider extras note — and is printed verbatim;
    // classification only adds its own context. Re-rendering the anchor here
    // with a guessed owner label doubled the article ("the the provider") and
    // dropped the extras note `SyncReport::log` carried.
    let mut notes: Vec<String> = report.log.clone();
    // Anchor outcomes refine the pass outcome first: an anchoring deferral or
    // integrity stop stands whatever the rewrite said.
    match &report.anchor {
        Some(anchor) => match anchor {
            AnchorOutcome::Defer { reason, .. } => {
                return (SyncClass::Defer(reason.clone().key()), notes);
            }
            AnchorOutcome::IntegrityStop { .. } => {
                return (SyncClass::Refuse("integrity-stop".to_string()), notes);
            }
            AnchorOutcome::Refused { message, .. } => {
                push_once(&mut notes, message.clone());
                return (SyncClass::Refuse("anchor-refused".to_string()), notes);
            }
            _ => {}
        },
        None => {}
    }
    match &report.outcome {
        SyncOutcome::NoChange { .. }
        | SyncOutcome::VersionMoved { .. }
        | SyncOutcome::ReleaseMoved { .. } => {
            let rewritten = !matches!(report.outcome, SyncOutcome::NoChange { .. });
            if rewritten {
                (SyncClass::Rewritten, notes)
            } else {
                (SyncClass::Continue, notes)
            }
        }
        SyncOutcome::QueryFailed { message } => {
            push_once(&mut notes, message.clone());
            if absorb {
                notes.push(format!(
                    "{}: consumer chain can absorb the wait — parking this recipe (deferred)",
                    report.pkg
                ));
                notes.push(
                    "  Nothing was built or installed; dependents wait (waits-on-deferred)."
                        .to_string(),
                );
                (SyncClass::Defer("upstream-unverified"), notes)
            } else {
                notes.push(format!(
                    "{}: consumers cannot wait — building the committed version as-is (its freshness is unverified)",
                    report.pkg
                ));
                (SyncClass::Rewritten, notes)
            }
        }
        SyncOutcome::Deferred {
            reason, message, ..
        } => {
            push_once(&mut notes, message.clone());
            (SyncClass::Defer(reason.clone().key()), notes)
        }
        SyncOutcome::Refused { message, .. } | SyncOutcome::Unsupported { message, .. } => {
            push_once(&mut notes, message.clone());
            (SyncClass::Refuse("sync-refused".to_string()), notes)
        }
    }
}

/// A message the report's log already carries verbatim is never printed twice.
fn push_once(notes: &mut Vec<String>, message: String) {
    if !notes.iter().any(|line| line.contains(&message)) {
        notes.push(message);
    }
}

/// The toolchain-drift clean of one recipe (trees + archives + VCS
/// baselines). Returns loud error lines instead of failing the caller — a
/// clean that cannot remove something is named, never masked.
pub fn drift_clean(recipe_dir: &Path, log: &mut Vec<String>) {
    let targets = match toolchain::clean_targets(recipe_dir) {
        Ok(targets) => targets,
        Err(error) => {
            log.push(format!(
                "cannot compute the drift-clean targets of {}: {error}",
                recipe_dir.display()
            ));
            return;
        }
    };
    for tree in &targets.trees {
        if tree.exists() {
            if let Err(error) = std::fs::remove_dir_all(tree) {
                log.push(format!("cannot remove {}: {error}", tree.display()));
            }
        }
    }
    for file in targets.archives.iter().chain(targets.sidecars.iter()) {
        if let Err(error) = std::fs::remove_file(file) {
            log.push(format!("cannot remove {}: {error}", file.display()));
        }
    }
}

/// The `--skip` / `--skip-built` claim decision for one recipe (the pure
/// port of fish `freshness_skip_decision`, minus the sync interleaving the
/// pass owns). `skip_allowed` is the pass's "nothing to do" answer.
pub fn skip_decision(
    recipe_dir: &Path,
    id: &str,
    state_dir: &Path,
    cfg: &PassConfig,
    skip_allowed: bool,
    graph: &Graph<'_>,
    idx: usize,
    log: &mut Vec<String>,
) -> NodePlan {
    let mode = match cfg.skip_mode {
        Some(mode) => mode,
        None => {
            return NodePlan::Build {
                reason: "ok".to_string(),
            }
        }
    };
    if state_dir.join("abi-repair").join(id).exists() {
        log.push(format!(
            "{id}: pending ABI repair (a provider's soname surface moved) — forcing rebuild, not skip"
        ));
        return NodePlan::Build {
            reason: "abi-repair-pending".to_string(),
        };
    }
    if !skip_allowed {
        return NodePlan::Build {
            reason: "ok".to_string(),
        };
    }
    let mut ctx = FreshnessContext::new(id.to_string(), mode);
    ctx.discovery = match mode {
        SkipMode::Skip => freshness::discover_current_set(recipe_dir),
        SkipMode::SkipBuilt => freshness::discover_newest_complete_set(recipe_dir),
    };
    ctx.tolerance = cfg.tolerance;
    ctx.abi_provider = recipe_dir.join(".gsa-abi-provider").is_file();
    ctx.absorb_wait = absorb_wait(graph, idx);

    let discovery: Discovery = ctx.discovery.clone();
    for archive in &discovery.archives {
        ctx.payload_ok
            .insert(archive.clone(), freshness::archive_payload_ok(archive));
    }
    if mode == SkipMode::Skip {
        // The mtime gate: `test PKGBUILD -nt archive` (nanosecond mtimes).
        match std::fs::metadata(recipe_dir.join("PKGBUILD")).and_then(|m| m.modified()) {
            Ok(recipe_time) => {
                for archive in &discovery.archives {
                    if let Ok(archive_time) = std::fs::metadata(archive).and_then(|m| m.modified())
                    {
                        if recipe_time > archive_time {
                            ctx.pkgbuild_newer_than.push(archive.clone());
                        }
                    }
                }
            }
            Err(_) => {
                // An unreadable PKGBUILD is not evidence for a claim.
                ctx.pkgbuild_newer_than
                    .extend(discovery.archives.iter().cloned());
            }
        }
    } else {
        // `--skip-built`'s recipe-change gate replaces the mtime compare.
        for archive in &discovery.archives {
            if freshness::recipe_changed_since_build(recipe_dir, archive) {
                ctx.recipe_changed_since.push(archive.clone());
            }
        }
    }
    if mode == SkipMode::Skip {
        let entries = match recipe_sources(recipe_dir) {
            Ok(entries) => entries,
            Err(_) => {
                log.push(format!(
                    "{id}: cannot evaluate the PKGBUILD source array — freshness is unverifiable; this run will not skip"
                ));
                return NodePlan::Build {
                    reason: "discovery-unestablished".to_string(),
                };
            }
        };
        let opts = ProbeOptions {
            tolerance: cfg.tolerance,
            abi_provider: ctx.abi_provider,
        };
        for archive in &discovery.archives {
            ctx.archives_probe.push(freshness::probe_archive(
                archive,
                &entries,
                &opts,
                &mut path_sleep,
            ));
        }
    }

    match freshness::decide(&ctx) {
        Verdict::Skip {
            reason,
            waiver_lines,
            archives,
        } => {
            for line in &waiver_lines {
                log.push(line.clone());
            }
            let names: Vec<String> = archives
                .iter()
                .filter_map(|a| a.file_name().map(|s| s.to_string_lossy().to_string()))
                .collect();
            log.push(format!("{id}: already built ({})", names.join(", ")));
            NodePlan::Skip {
                reason: reason.to_string(),
                archives,
            }
        }
        Verdict::Defer { reason } => {
            log.push(format!(
                "{id}: --skip cannot verify upstream VCS freshness — consumer chain can absorb the wait — parking this recipe (deferred)"
            ));
            log.push(
                "  Nothing was built or installed; dependents wait (waits-on-deferred)."
                    .to_string(),
            );
            NodePlan::Defer {
                reason: reason.to_string(),
            }
        }
        Verdict::Build { reason } => {
            // The detail is diagnostics, not a row reason (§H.3 keeps the
            // rows to the named keys) — but it is still the run's explanation
            // for a rebuild and must reach the log.
            log.push(format!("{id}: {reason}"));
            NodePlan::Build {
                reason: build_reason_key(&reason).to_string(),
            }
        }
    }
}

fn build_reason_key(reason: &str) -> &str {
    reason.split(": ").next().unwrap_or(reason)
}

/// Run the pre-dispatch pass over one selection, in canonical build order.
/// `selection` is `select::build_selection`'s answer; `state_dir` gates the
/// ABI-repair markers. Loud lines land in each [`PackagePrep::log`].
pub fn prepare_all(
    root: &Path,
    state_dir: &Path,
    graph: &Graph<'_>,
    selection: &Selection,
    cfg: &PassConfig,
) -> Prepared {
    let mut packages: Vec<PackagePrep> = Vec::new();
    let mut aborted = false;
    for (_, id) in &selection.listed {
        let idx = graph.index_of(id.as_str()).expect("selection ids resolve");
        let recipe_dir = root.join(&graph.record(idx).path);
        if aborted {
            packages.push(PackagePrep {
                plan: NodePlan::Build {
                    reason: "ok".to_string(),
                },
                log: Vec::new(),
            });
            continue;
        }
        let prep = prepare_one(root, state_dir, graph, idx, id, &recipe_dir, cfg);
        if matches!(prep.plan, NodePlan::Refuse { .. }) {
            aborted = true;
        }
        packages.push(prep);
    }
    Prepared { packages }
}

fn prepare_one(
    root: &Path,
    state_dir: &Path,
    graph: &Graph<'_>,
    idx: usize,
    id: &RecipeId,
    recipe_dir: &Path,
    cfg: &PassConfig,
) -> PackagePrep {
    let name = id.as_str();
    let mut log: Vec<String> = Vec::new();
    let mut skip_allowed = true;

    // ── 1. GCC toolchain drift gate (docs/build-guide.md "Skip and resume") ─
    let identity = match toolchain::gcc_identity() {
        Ok(identity) => identity,
        Err(error) => {
            return PackagePrep {
                plan: NodePlan::Refuse {
                    reason: "toolchain-identity".to_string(),
                },
                log: vec![format!(
                    "{name}: could not determine the GCC build identity ({error})"
                )],
            };
        }
    };
    let identity_state = toolchain::check_identity(state_dir, name, &identity);
    let drifted = identity_state.forces_clean_rebuild();
    if drifted && cfg.skip_mode.is_some() {
        // The ordering hard rule: resolve the selected refs BEFORE the drift
        // clean destroys the archive and its baseline — act on the deferral
        // only; a skip verdict falls through to the clean + rebuild.
        let probe = skip_decision(
            recipe_dir,
            name,
            state_dir,
            cfg,
            true,
            graph,
            idx,
            &mut Vec::new(),
        );
        if let NodePlan::Defer { reason } = probe {
            log.push(format!(
                "{name}: --skip cannot verify upstream VCS freshness — parking before the drift clean (deferred)"
            ));
            return PackagePrep {
                plan: NodePlan::Defer { reason },
                log,
            };
        }
    }
    if drifted {
        log.push(identity_state.to_string());
        drift_clean(recipe_dir, &mut log);
    }

    // ── 2. version-sync (unless --no-sync) ─────────────────────────────────
    if !cfg.no_sync {
        let report = sync_one(recipe_dir, root, idx, graph);
        let (class, mut notes) = classify_sync(&report, absorb_wait(graph, idx));
        log.append(&mut notes);
        match class {
            SyncClass::Defer(reason) => {
                return PackagePrep {
                    plan: NodePlan::Defer {
                        reason: reason.to_string(),
                    },
                    log,
                };
            }
            SyncClass::Refuse(reason) => {
                return PackagePrep {
                    plan: NodePlan::Refuse { reason },
                    log,
                };
            }
            SyncClass::Rewritten => skip_allowed = false,
            SyncClass::Continue => {}
        }
    }

    // ── 3. moved sources invalidate any claim too ──────────────────────────
    if !cfg.no_sync {
        if recipe_sources(recipe_dir).is_err() {
            log.push(format!(
                "{name}: cannot evaluate the rewritten PKGBUILD source array — freshness is unverifiable; this run will not skip"
            ));
            skip_allowed = false;
        }
    } else if recipe_sources(recipe_dir).is_err() {
        log.push(format!(
            "{name}: cannot evaluate the PKGBUILD source array — freshness is unverifiable; this run will not skip"
        ));
        skip_allowed = false;
    }

    // ── 4. the skip claim (§B.8) ───────────────────────────────────────────
    let plan = skip_decision(
        recipe_dir,
        name,
        state_dir,
        cfg,
        skip_allowed,
        graph,
        idx,
        &mut log,
    );
    PackagePrep { plan, log }
}

/// The selection a whole-set pass uses (`-Sy`/`-Su`, contract §B.4): the
/// explicit targets/ranges when given, else every recipe in canonical build
/// order.
pub fn pass_selection(ctx: &Ctx<'_>, inv: &Invocation) -> Result<Selection, String> {
    if inv.targets.is_empty() && inv.ranges.is_empty() {
        let mut selection = Selection {
            listed: Vec::new(),
            closure_size: 0,
            seeds: Vec::new(),
            notes: Vec::new(),
        };
        for idx in ctx.graph.order() {
            selection.listed.push((
                selection.listed.len() + 1,
                ctx.graph.record(*idx).id.clone(),
            ));
        }
        selection.closure_size = selection.listed.len();
        Ok(selection)
    } else {
        select::build_selection(ctx, &inv.targets, &inv.ranges, inv.leaf).map_err(|e| e.message)
    }
}

/// The `-Sy` phase shared by `gsa -Sy` and `gsa -Syu`: sync every selected
/// recipe in canonical build order, print each note and the run-level
/// disposition block (recipe rewrites left UNCOMMITTED, rule 18). Returns
/// whether a refusal class fired and whether a deferral class fired.
/// H4 (2026-10-28): the per-recipe status line of the sync pass — every
/// recipe answers with exactly one visible line. This renders the outcomes
/// that were SILENT before (a long `-Sy` pass showed nothing until a rewrite
/// or a failure fired); the refusal/deferral classes keep their own loud
/// per-recipe notes (`None` here, never a second line for them). Human
/// vocabulary is the fish-era prose; the machine mode is one `LEVEL event
/// k=v` line (§L.6).
fn sync_status_line(id: &str, outcome: &SyncOutcome, human: bool) -> Option<String> {
    use crate::output::{kv_line, Level};
    let line = match outcome {
        SyncOutcome::NoChange { reason } => {
            if human {
                format!("· {id}: no change ({})\n", reason.as_str())
            } else {
                format!(
                    "{}\n",
                    kv_line(
                        Level::Info,
                        "sync",
                        &[
                            ("pkg", id.to_string()),
                            ("status", "no-change".to_string()),
                            ("reason", reason.as_str().to_string()),
                        ],
                    )
                )
            }
        }
        SyncOutcome::VersionMoved { old, new, .. } => {
            if human {
                format!("✓ {id}: version moved {old} → {new}\n")
            } else {
                format!(
                    "{}\n",
                    kv_line(
                        Level::Info,
                        "sync",
                        &[
                            ("pkg", id.to_string()),
                            ("status", "version-moved".to_string()),
                            ("old", old.clone()),
                            ("new", new.clone()),
                        ],
                    )
                )
            }
        }
        SyncOutcome::ReleaseMoved { old, new } => {
            if human {
                format!("✓ {id}: release moved {old} → {new}\n")
            } else {
                format!(
                    "{}\n",
                    kv_line(
                        Level::Info,
                        "sync",
                        &[
                            ("pkg", id.to_string()),
                            ("status", "release-moved".to_string()),
                            ("old", old.clone()),
                            ("new", new.clone()),
                        ],
                    )
                )
            }
        }
        _ => return None,
    };
    Some(line)
}

pub fn sync_phase(
    root: &Path,
    graph: &Graph<'_>,
    selection: &Selection,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> (bool, bool) {
    let mut rows: Vec<DispositionRow> = Vec::new();
    let mut refused = false;
    let mut deferred = false;
    for (_, id) in &selection.listed {
        let idx = graph.index_of(id.as_str()).expect("selection ids resolve");
        let recipe_dir = root.join(&graph.record(idx).path);
        let report = sync_one(&recipe_dir, root, idx, graph);
        let (class, notes) = classify_sync(&report, absorb_wait(graph, idx));
        // H4: the per-recipe status line first (the verdict headline), then
        // the loud notes below as its detail.
        if let Some(line) = sync_status_line(id.as_str(), &report.outcome, crate::output::is_human()) {
            let _ = write!(out, "{line}");
        }
        for line in &notes {
            let _ = writeln!(err, "gsa: note: {line}");
        }
        rows.extend(report.rows.iter().cloned());
        match class {
            SyncClass::Defer(key) => {
                let _ = writeln!(
                    err,
                    "gsa: note: {}: deferred ({key}) — nothing was built; retry when provider metadata is available, or use '--no-sync' to build the committed version and sums",
                    id.as_str()
                );
                deferred = true;
            }
            SyncClass::Refuse(reason) => {
                let _ = writeln!(
                    err,
                    "gsa: {}: refusing to rewrite — {reason}; the recipe was restored byte-for-byte",
                    id.as_str()
                );
                refused = true;
            }
            _ => {}
        }
    }
    let block = sync::render_disposition(&rows);
    if !block.is_empty() {
        let _ = write!(out, "{block}");
    } else {
        let _ = writeln!(out, "Version and checksum sync: nothing to do");
    }
    (refused, deferred)
}

/// `gsa -Sy [targets…] [ranges…]` (contract §B.4): the version-sync pass
/// only — provider queries, transactional recipe rewrites left UNCOMMITTED,
/// the run-level disposition block. rc: 0 clean, 3 refusal class (§G.1
/// integrity stop), 5 deferral-only.
pub fn run_sync_pass(inv: &Invocation, out: &mut dyn Write, err: &mut dyn Write) -> i32 {
    let root = match crate::resolve_workspace(inv) {
        Ok(root) => root,
        Err(message) => {
            let _ = writeln!(err, "gsa: {message}");
            return 2;
        }
    };
    // W3 store semantics: `-Sy` refreshes the canonical store alongside the
    // version-sync pass. A `project` override (dev checkout) supersedes the
    // store and is never refreshed; a cwd workspace is the deprecated path
    // and refreshes nothing (the note keeps that visible).
    match gsa_model::config::load() {
        Ok(cfg) if cfg.project.is_some() => {
            let _ = writeln!(
                err,
                "gsa: note: project override active — the recipe store is not refreshed"
            );
        }
        Ok(cfg) => {
            let state = match gsa_model::config::resolve_state_dir(inv.state_dir.as_deref()) {
                Ok(state) => state,
                Err(message) => {
                    let _ = writeln!(err, "gsa: {message}");
                    return 2;
                }
            };
            // The workspace comparison uses the RESOLVED store root (pure);
            // resolve_workspace already ran the ensure/migrate step and
            // printed its note — a second ensure here would double-print.
            let store = match gsa_state::recipes::store_dir() {
                Ok(store) => store,
                Err(message) => {
                    let _ = writeln!(err, "gsa: {message}");
                    return 2;
                }
            };
            if root == store {
                let url = cfg
                    .recipe_url
                    .unwrap_or_else(|| gsa_model::config::DEFAULT_RECIPE_URL.to_string());
                match gsa_state::recipes::refresh(&state, &url) {
                    Ok(head) => {
                        let _ = writeln!(err, "gsa: recipe store refreshed: {head}");
                    }
                    Err(message) => {
                        let _ = writeln!(err, "gsa: {message}");
                        return 2;
                    }
                }
            } else {
                let _ = writeln!(
                    err,
                    "gsa: note: workspace is not the recipe store — nothing to refresh"
                );
            }
        }
        Err(message) => {
            let _ = writeln!(err, "gsa: {message}");
            return 2;
        }
    }
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
    let db = match gsa_recipe::RecipeDb::load(&root, graph.records()) {
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
        user_sets: select::load_user_sets(inv),
    };
    // A selection is optional here (§B.4 spells `gsa -Sy` with no targets):
    // no selection = every recipe, in canonical build order.
    let selection = match pass_selection(&ctx, inv) {
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
        crate::invocation_privilege(inv, &crate::Command::SyncPass),
        true,
        err,
    ) {
        return code;
    }

    let (refused, deferred) = sync_phase(&root, &graph, &selection, out, err);
    if refused {
        return 3;
    }
    if deferred {
        return 5;
    }
    0
}

/// The `-Su` stale set (contract §B.3 `-Qu` / §B.4 `-Su`): recipes whose
/// tracked (committed) version moved past their newest complete built
/// instance. A recipe with no built instance is NOT stale — fresh builds use
/// an explicit selection. `vercmp` disagreement in either direction that
/// cannot be compared is not stale (never invent movement).
pub fn stale_set(root: &Path, graph: &Graph<'_>, ids: &[RecipeId]) -> Vec<RecipeId> {
    let mut stale = Vec::new();
    for id in ids {
        let idx = match graph.index_of(id.as_str()) {
            Some(idx) => idx,
            None => continue,
        };
        let recipe_dir = root.join(&graph.record(idx).path);
        let Ok((pv, pr)) = freshness::current_version_key(&recipe_dir) else {
            continue;
        };
        let tracked = format!("{pv}-{pr}");
        let discovery = freshness::discover_newest_complete_set(&recipe_dir);
        if discovery.status() != freshness::DiscoveryStatus::Complete {
            continue;
        }
        let Some(built) = discovery.version_key else {
            continue;
        };
        if matches!(sync::vercmp(&tracked, &built), Some(n) if n > 0) {
            stale.push(id.clone());
        }
    }
    stale
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::args::{parse, Parsed};

    /// One skip MODE is an invariant of this seam, not only of the parser
    /// (§B.8). `args::parse` refuses the both-set spelling at parse time
    /// (rc 2); an Invocation built directly must be refused with the SAME
    /// wording here — never resolved by silent precedence.
    #[test]
    fn pass_config_refuses_both_skip_claims() {
        let argv: Vec<String> = ["-B", "--skip"].iter().map(|s| s.to_string()).collect();
        let Parsed::Invoke(mut inv) = parse(&argv).expect("--skip alone parses") else {
            panic!("expected an invocation");
        };
        // Construct the parse-unreachable both-set state directly.
        inv.skip_built = true;
        let err = match pass_config(&inv) {
            Err(e) => e,
            Ok(_) => panic!("both skip claims must be refused"),
        };
        assert_eq!(
            err,
            "cannot combine --skip with --skip-built (pick one skip claim: --skip is freshness-gated, --skip-built is the built-set claim)"
        );
    }

    /// H4 (2026-10-28): every recipe answers with one status line — the
    /// silent outcomes now have one, in both vocabularies — and the loud
    /// classes (which already carry their own per-recipe note) never get a
    /// second line.
    #[test]
    fn sync_status_lines_cover_the_silent_outcomes_once() {
        use gsa_recipe::sync::NoChangeReason;
        let id = "mesa-git";
        let nochange = SyncOutcome::NoChange {
            reason: NoChangeReason::Current,
        };
        assert_eq!(
            sync_status_line(id, &nochange, true).as_deref(),
            Some("· mesa-git: no change (current)\n")
        );
        assert_eq!(
            sync_status_line(id, &nochange, false).as_deref(),
            Some("INFO sync pkg=mesa-git status=no-change reason=current\n")
        );
        let moved = SyncOutcome::VersionMoved {
            old: "1.0-1".to_string(),
            new: "2.0-1".to_string(),
            moved_sources: Vec::new(),
        };
        assert_eq!(
            sync_status_line(id, &moved, true).as_deref(),
            Some("✓ mesa-git: version moved 1.0-1 → 2.0-1\n")
        );
        assert_eq!(
            sync_status_line(id, &moved, false).as_deref(),
            Some("INFO sync pkg=mesa-git status=version-moved old=1.0-1 new=2.0-1\n")
        );
        let release = SyncOutcome::ReleaseMoved {
            old: "1.0-1".to_string(),
            new: "1.0-2".to_string(),
        };
        assert_eq!(
            sync_status_line(id, &release, true).as_deref(),
            Some("✓ mesa-git: release moved 1.0-1 → 1.0-2\n")
        );
        // The loud classes keep their own note — no duplicate line.
        let loud = SyncOutcome::QueryFailed {
            message: "provider outage".to_string(),
        };
        assert!(sync_status_line(id, &loud, true).is_none());
        assert!(sync_status_line(id, &loud, false).is_none());
    }
}
