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
    SyncOutcome, SyncPolicy, SyncReport, VersionProvider,
};
use gsa_recipe::toolchain;
use gsa_recipe::RecipeDb;
use gsa_topo::load_project;

use crate::args::Invocation;
use crate::exit::{self, Exit, Refusal, RefusalClass};
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
    /// The resolved `SRCDEST` mirror root (`config::resolve_srcdest`), the one
    /// place the snapshot-pin pass reads a recipe's own bare clone from.
    /// `None` when the ladder cannot answer: a pinned recipe then defers
    /// instead of guessing a path.
    pub srcdest: Option<PathBuf>,
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
        srcdest: gsa_model::config::resolve_srcdest(),
    })
}

/// The short form of a commit sha for a message (the pass's own `-Sy` render
/// keeps its 12-character spelling in `gsa_recipe::sync`).
fn short_sha_text(sha: &str) -> String {
    sha.chars().take(12).collect()
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
///
/// The PROVIDER is chosen by the recipe's shape, one dispatch site:
/// `#commit=`-pinned primary source → the snapshot-pin pass (W5); otherwise the
/// `version-sync=nvchecker` tag → the nvchecker path; otherwise the Arch repo
/// provider (which no-ops outside `packages/stable`).
pub fn sync_one(
    recipe_dir: &Path,
    root: &Path,
    idx: usize,
    graph: &Graph<'_>,
    srcdest: Option<&Path>,
) -> SyncReport {
    let policy = SyncPolicy {
        repo_root: root.to_path_buf(),
    };
    // The snapshot pass owns a `#commit=` pin EXCEPT under `packages/stable`,
    // which the Arch provider owns (its placement gate is `sync_arch`'s, and
    // its pins are release anchors — `#commit=` at a tag — rather than the
    // weekly snapshots this pass advances). `snapshot_source` answers
    // `NotASnapshot` for everything else, so the recipe's own source plus
    // this one placement exclusion is the whole dispatch: no tag, no group
    // and no name decides it.
    let stable_staged = recipe_dir.starts_with(root.join("packages").join("stable"));
    if let Some(snapshot) = (!stable_staged)
        .then(|| sync::snapshot_source(recipe_dir))
        .and_then(Result::ok)
    {
        let Some(srcdest) = srcdest else {
            // Absent EVIDENCE, the same arm `mirror-missing` takes: no SRCDEST
            // means no mirror could be read, which is fetchable state, not a
            // defective recipe. Folding it into a refusal would abort a
            // full-set `-Sy` on a host whose ladder answers nothing.
            let pkg = recipe_dir
                .file_name()
                .map(|s| s.to_string_lossy().to_string())
                .unwrap_or_default();
            return SyncReport {
                pkg: pkg.clone(),
                outcome: SyncOutcome::Deferred {
                    reason: sync::DeferReason::SourceUnfetchable,
                    message: format!(
                        "{pkg}: snapshot pin {} cannot be advanced — no SRCDEST resolved, so the source mirror is unreachable",
                        short_sha_text(&snapshot.commit)
                    ),
                    restored: sync::RestoreStatus::NothingToRestore,
                },
                anchor: None,
                rows: Vec::new(),
                log: Vec::new(),
            };
        };
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_secs() as i64)
            .unwrap_or(0);
        let boundary = sync::monday_boundary(now);
        return sync::sync_snapshot(recipe_dir, root, srcdest, &boundary);
    }
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
                    class: sync::RefusalClass::UnsafeVersionText,
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
    /// rc 3) with this refusal class.
    Refuse(RefusalClass),
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
                return (SyncClass::Refuse(RefusalClass::IntegrityStop), notes);
            }
            AnchorOutcome::Refused { message, .. } => {
                push_once(&mut notes, message.clone());
                return (SyncClass::Refuse(RefusalClass::AnchorRefused), notes);
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
            (SyncClass::Refuse(RefusalClass::SyncRefused), notes)
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
        if !tree.exists() {
            continue;
        }
        // The build cache may be shared by another state root's run, whose
        // own run lock this process cannot see: a live process inside the
        // tree is the only ownership proof, and removing it there kills an
        // in-flight makepkg (blind-review 2026-11-11, data-center-ops). The
        // identity is per state root, so a fresh root re-triggers this clean
        // against a cache nobody there built.
        if let Some(pid) = gsa_model::proc::tree_in_use(tree) {
            log.push(format!(
                "not cleaning {} — a live process (pid {pid}) is working inside it",
                tree.display()
            ));
            continue;
        }
        if let Err(error) = std::fs::remove_dir_all(tree) {
            log.push(format!("cannot remove {}: {error}", tree.display()));
        }
    }
    for file in targets.archives.iter().chain(targets.sidecars.iter()) {
        if let Err(error) = std::fs::remove_file(file) {
            log.push(format!("cannot remove {}: {error}", file.display()));
        }
    }
}

/// Apply the missing build-order prerequisite expansion to a selection and
/// announce it (contract §C.3, owner decision 2026-11-11). ONE seam for the
/// three verbs that must agree on what a selection means: the build run, its
/// dry-run plan, and the fetch run (`-Sw`, which must fetch the sources the
/// build will need). `Err` carries the unreadable installed-DB message; the
/// caller picks the refusal class its surface owes.
pub fn apply_missing_prerequisites(
    selection: &mut Selection,
    graph: &Graph<'_>,
    db: &RecipeDb,
    inv: &Invocation,
    err: &mut dyn Write,
) -> Result<(), String> {
    let candidates = prerequisite_candidates(graph, selection, inv.leaf);
    if candidates.is_empty() {
        return Ok(());
    }
    let conf = inv.config.as_deref().map(Path::new);
    let db_root = gsa_install::localdb::pacman_db_root_for(conf)?;
    let installed = gsa_install::LocalDb::load(&db_root)?;
    let additions = missing_prerequisites(graph, &candidates, db, &installed);
    for id in &additions {
        let _ = writeln!(
            err,
            "gsa: note: added build-order prerequisite {id} (not installed)"
        );
    }
    merge_prerequisites(selection, &additions, graph);
    Ok(())
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
        // The recipe gate is CONTENT first (blind review 2026-11-11, F): the
        // archive records the PKGBUILD hash it was built from (`.BUILDINFO`
        // `pkgbuild_sha256sum`), so a restored or copied recipe with an older
        // mtime no longer skips a genuine change, and a content-identical
        // rewrite no longer forces a rebuild. Only an archive with no record
        // (older makepkg, a foreign archive) falls back to the mtime compare
        // `test PKGBUILD -nt archive` (nanosecond mtimes).
        let current_hash = freshness::pkgbuild_content_hash(recipe_dir);
        let recipe_time = std::fs::metadata(recipe_dir.join("PKGBUILD")).and_then(|m| m.modified());
        for archive in &discovery.archives {
            let recorded = gsa_recipe::pkginfo::buildinfo_field(archive, "pkgbuild_sha256sum");
            if let (Some(current), Some(built)) = (current_hash.as_deref(), recorded.as_deref()) {
                if current != built {
                    ctx.recipe_changed_since.push(archive.clone());
                }
                continue;
            }
            match recipe_time {
                Ok(recipe_time) => {
                    if let Ok(archive_time) = std::fs::metadata(archive).and_then(|m| m.modified())
                    {
                        if recipe_time > archive_time {
                            ctx.pkgbuild_newer_than.push(archive.clone());
                        }
                    }
                }
                // An unreadable PKGBUILD is not evidence for a claim.
                Err(_) => ctx.pkgbuild_newer_than.push(archive.clone()),
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
/// The privileged-PATH hint an absent-compiler refusal owes. A privileged run
/// inherits `sudo`'s PATH (`secure_path`), so a compiler the operator's own
/// shell finds outside those directories is invisible to the engine AND to
/// every lane. Without the hint the message reads "not installed" and sends
/// the operator to reinstall a compiler that is already there.
pub(crate) fn secure_path_hint() -> &'static str {
    if gsa_model::privilege::build_user().is_some() {
        "; a privileged run inherits sudo's PATH (secure_path), so a compiler installed outside those directories is invisible here even when your own shell finds it — install it under /usr/bin or another secure_path directory"
    } else {
        ""
    }
}

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

    // ── 1. compiler toolchain drift gate (docs/build-guide.md "Skip and
    //       resume"; the identity folds in the engine's config bytes, rule 6) ─
    let toolchain = selected_toolchain(id.as_str(), graph.record(idx), recipe_dir);
    let identity = match toolchain::build_identity(toolchain) {
        Ok(identity) => identity,
        Err(error) => {
            return PackagePrep {
                plan: NodePlan::Refuse {
                    reason: "toolchain-identity".to_string(),
                },
                log: vec![format!(
                    "{name}: could not determine the {toolchain} build identity ({error})"
                )],
            };
        }
    };
    // A compiler that is not installed is not a toolchain: the identity's
    // sentinel is DATA for the drift comparison (installing the compiler
    // later reads as drift), but WRITING that marker after a build certifies
    // a phantom — and the build itself cannot succeed. The family named on
    // the command line is a claim the host must be able to honour (blind
    // review, 2026-11-11).
    if let Some(unavailable) = toolchain::unavailable_sentinel(toolchain) {
        if identity.starts_with(&format!("{toolchain}|{unavailable}|")) {
            log.push(format!(
                "{name}: the {toolchain} compiler is not installed ({unavailable}) — install it or pick another --toolchain{}",
                secure_path_hint()
            ));
            return PackagePrep {
                plan: NodePlan::Refuse {
                    reason: "toolchain-unavailable".to_string(),
                },
                log,
            };
        }
    }
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
        // The clean is PER RECIPE (one marker each): name the recipe, or N
        // cold recipes read as one global event reported N times
        // (2026-11-11 blind-review finding).
        log.push(format!("{name}: {identity_state}"));
        drift_clean(recipe_dir, &mut log);
    }

    // ── 2. version-sync (unless --no-sync) ─────────────────────────────────
    if !cfg.no_sync {
        let report = sync_one(recipe_dir, root, idx, graph, cfg.srcdest.as_deref());
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
            SyncClass::Refuse(class) => {
                return PackagePrep {
                    plan: NodePlan::Refuse {
                        reason: class.key().to_string(),
                    },
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
            expansion_added: 0,
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

/// The transitive build-order prerequisites of a selection that the
/// selection does not already contain, in canonical build order.
///
/// A build selection expands toward its CONSUMERS (§C.2); nothing used to
/// expand it toward its prerequisites, so `gsa -S app` planned
/// `app build-install ok` and then died in makepkg's
/// `Missing dependencies: -> lib` after the run had promised "each package
/// installed before its consumers compile" (blind-review 2026-11-11,
/// packaging-novice). `--leaf` is exempt by definition: it builds exactly
/// what was named.
pub fn prerequisite_candidates(graph: &Graph<'_>, selection: &Selection, leaf: bool) -> Vec<usize> {
    if leaf || selection.listed.is_empty() {
        return Vec::new();
    }
    let selected: std::collections::BTreeSet<usize> = selection
        .listed
        .iter()
        .filter_map(|(_, id)| graph.index_of(id.as_str()))
        .collect();
    let mut wanted = selected.clone();
    let mut frontier: Vec<usize> = selected.iter().copied().collect();
    while let Some(idx) = frontier.pop() {
        for prereq in graph.prerequisites(idx) {
            if wanted.insert(prereq) {
                frontier.push(prereq);
            }
        }
    }
    let mut out: Vec<usize> = wanted.difference(&selected).copied().collect();
    out.sort_by_key(|idx| graph.position(*idx));
    out
}

/// Every pacman name one recipe can be installed under: its id (`pkgbase`
/// fallback), the committed `.SRCINFO` pkgbase, and its declared pkgnames.
fn recipe_names(db: &RecipeDb, record: &gsa_model::TopologyRecord) -> Vec<String> {
    let mut names = vec![record.id.as_str().to_string()];
    if let Some(meta) = db.get(record.id.as_str()) {
        if let Some(info) = &meta.srcinfo {
            if let Some(base) = &info.pkgbase {
                names.push(base.clone());
            }
        }
        names.extend(meta.pkgnames());
    }
    names.sort();
    names.dedup();
    names
}

/// The prerequisite additions a run actually makes: a candidate is added
/// only when the SYSTEM has NONE of its output names installed.
///
/// Owner decision 2026-11-11: expand to what is missing, never rebuild. A
/// partially installed split recipe is left alone for the same reason (the
/// missing output is an install, not a build).
pub fn missing_prerequisites(
    graph: &Graph<'_>,
    candidates: &[usize],
    db: &RecipeDb,
    installed: &gsa_install::LocalDb,
) -> Vec<String> {
    candidates
        .iter()
        .filter(|&&idx| {
            let record = graph.record(idx);
            !recipe_names(db, record)
                .iter()
                .any(|name| installed.get(name).is_some())
        })
        .map(|&idx| graph.record(idx).id.as_str().to_string())
        .collect()
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

/// The answer of one `sync_phase` pass. A refusal aborts the run (§G.1 rc 3)
/// and carries its `classify_sync` reason key (`integrity-stop` /
/// `anchor-refused` / `sync-refused`) so the refusal record names the same
/// key the build pipeline's rows use; a deferral is reported per recipe and
/// re-derived as a row by the pipeline's own idempotent sync.
pub struct SyncPhase {
    /// The first refusing recipe's class, `None` when nothing refused.
    pub refused: Option<RefusalClass>,
    /// Every deferred recipe with its §H.3 reason key.
    pub deferred: Vec<(String, String)>,
}

pub fn sync_phase(
    root: &Path,
    graph: &Graph<'_>,
    selection: &Selection,
    srcdest: Option<&Path>,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> SyncPhase {
    let mut rows: Vec<DispositionRow> = Vec::new();
    let mut refused: Option<RefusalClass> = None;
    let mut deferred: Vec<(String, String)> = Vec::new();
    for (_, id) in &selection.listed {
        let idx = graph.index_of(id.as_str()).expect("selection ids resolve");
        let recipe_dir = root.join(&graph.record(idx).path);
        let report = sync_one(&recipe_dir, root, idx, graph, srcdest);
        let (class, notes) = classify_sync(&report, absorb_wait(graph, idx));
        // H4: the per-recipe status line first (the verdict headline), then
        // the loud notes below as its detail.
        if let Some(line) =
            sync_status_line(id.as_str(), &report.outcome, crate::output::is_human())
        {
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
                deferred.push((id.as_str().to_string(), key.to_string()));
            }
            SyncClass::Refuse(class) => {
                let _ = writeln!(
                    err,
                    "gsa: {}: refusing to rewrite — {}; the recipe was restored byte-for-byte",
                    id.as_str(),
                    class.key()
                );
                // The first refusal is the run's class (§G.1: an integrity
                // stop or a named sync refusal aborts before dispatch).
                refused.get_or_insert(class);
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
    SyncPhase { refused, deferred }
}

/// `gsa -Sy [targets…] [ranges…]` (contract §B.4): the version-sync pass
/// only — provider queries, transactional recipe rewrites left UNCOMMITTED,
/// the run-level disposition block. rc: 0 clean, 3 refusal class (§G.1
/// integrity stop), 5 deferral-only.
pub fn run_sync_pass(inv: &Invocation, out: &mut dyn Write, err: &mut dyn Write) -> i32 {
    exit::render(run_sync_pass_inner(inv, out, err), err)
}

fn run_sync_pass_inner(
    inv: &Invocation,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<i32, Exit> {
    let root = crate::resolve_workspace(inv, err)?;
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
            let state = gsa_model::config::resolve_state_dir(inv.state_dir.as_deref())
                .map_err(Exit::Usage)?;
            // The workspace comparison uses the RESOLVED store root (pure);
            // resolve_workspace already ran the ensure/migrate step and
            // printed its note — a second ensure here would double-print.
            let store = gsa_state::recipes::store_dir().map_err(Exit::Usage)?;
            if root == store {
                let url = cfg
                    .recipe_url
                    .unwrap_or_else(|| gsa_model::config::DEFAULT_RECIPE_URL.to_string());
                let (head, note) =
                    gsa_state::recipes::refresh(&state, &url).map_err(Exit::Usage)?;
                if let Some(note) = note {
                    let _ = writeln!(err, "gsa: {note}");
                }
                let _ = writeln!(err, "gsa: recipe store refreshed: {head}");
            } else {
                let _ = writeln!(
                    err,
                    "gsa: note: workspace is not the recipe store — nothing to refresh"
                );
            }
        }
        Err(message) => return Err(Exit::Usage(message)),
    }
    let project = load_project(&root).map_err(|error| Exit::Usage(error.to_string()))?;
    let graph = Graph::build(&project.topology.records)
        .map_err(|error| Exit::Usage(format!("config/topology.conf: {error}")))?;
    let db = gsa_recipe::RecipeDb::load(&root, graph.records())
        .map_err(|error| Exit::Usage(error.to_string()))?;
    let ctx = Ctx {
        project: &project,
        graph: &graph,
        db: &db,
        user_sets: select::load_user_sets(inv),
    };
    // A selection is optional here (§B.4 spells `gsa -Sy` with no targets):
    // no selection = every recipe, in canonical build order.
    let selection = pass_selection(&ctx, inv).map_err(Exit::Usage)?;
    crate::write_notes(err, &selection.notes);

    // ── privilege gate (contract §B.10; after every usage preflight) ─────
    if let Some(exit) = crate::privilege_gate(
        &inv.spelling(),
        crate::invocation_privilege(inv, &crate::Command::SyncPass),
        true,
        err,
    ) {
        return Err(exit);
    }

    let srcdest = gsa_model::config::resolve_srcdest();
    let phase = sync_phase(&root, &graph, &selection, srcdest.as_deref(), out, err);
    if let Some(class) = phase.refused {
        // A one-shot `-Sy` renders the disposition block only: the contract
        // (§H.1/H.2) owes a run record to build-shaped runs, and `-Sy` is
        // never mirrored into a continuation — the refusal class is the rc,
        // and the per-recipe refusal line was already printed by the pass.
        return Err(Exit::Refuse(Refusal::silent(class)));
    }
    if !phase.deferred.is_empty() {
        return Ok(5);
    }
    Ok(0)
}

/// One stale-set row: the decision AND the evidence it was made on, computed
/// once so `-Qu` renders exactly what `-Su` planned (rule 72 — a view never
/// re-derives the decision).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StaleRow {
    pub id: RecipeId,
    /// The recipe's canonical tracked version (`[epoch:]pkgver-pkgrel`).
    pub tracked: String,
    /// The oldest INSTALLED output's version, when any output is installed.
    pub installed: Option<String>,
    /// The newest complete built instance's key, when one exists.
    pub built: Option<String>,
}

/// The `-Su` stale set (contract §B.3 `-Qu` / §B.4 `-Su`): recipes whose
/// tracked (committed) version moved past what the host actually HAS.
///
/// The reference point is the INSTALLED record whenever any of the recipe's
/// outputs is installed, and only then the newest complete built instance:
/// measuring against the archive alone let a refused install vanish from
/// `-Qu`/`-Su` — the archive read as "built", so no row ever asked for the
/// install that was refused and the host stayed behind for good. A recipe
/// with no installed output and no built instance is NOT stale (fresh builds
/// use an explicit selection). `vercmp` disagreement — in either direction —
/// is not stale (never invent movement).
pub fn stale_set(
    root: &Path,
    graph: &Graph<'_>,
    db: &gsa_recipe::RecipeDb,
    installed: &gsa_install::localdb::LocalDb,
    ids: &[RecipeId],
) -> Vec<StaleRow> {
    let mut stale = Vec::new();
    for id in ids {
        let idx = match graph.index_of(id.as_str()) {
            Some(idx) => idx,
            None => continue,
        };
        // The tracked version is read from the recipe AT CALL TIME, never
        // from a `RecipeDb` loaded before the `-Syu` sync phase — that pass
        // rewrites `pkgver` in place, and a pre-sync view would measure the
        // stale set against the version that was just replaced.
        let recipe_dir = root.join(&graph.record(idx).path);
        let Ok((pv, pr)) = freshness::current_version_key(&recipe_dir) else {
            continue;
        };
        let tracked = format!("{pv}-{pr}");
        let Some(meta) = db.get(id.as_str()) else {
            continue;
        };
        let mut installed_version: Option<String> = None;
        for pkgname in meta.pkgnames() {
            let Some(pkg) = installed.get(&pkgname) else {
                continue;
            };
            // The OLDEST installed output is the row's evidence and the
            // comparison's operand: one output left behind is the recipe
            // being behind, and split outputs share a version in practice.
            let older = match &installed_version {
                None => true,
                Some(current) => {
                    matches!(sync::vercmp(&pkg.version, current), Some(n) if n < 0)
                }
            };
            if older {
                installed_version = Some(pkg.version.clone());
            }
        }
        let discovery = freshness::discover_newest_complete_set(&recipe_dir);
        let built = if discovery.status() == freshness::DiscoveryStatus::Complete {
            discovery.version_key
        } else {
            None
        };
        let is_stale = match &installed_version {
            Some(installed) => {
                matches!(sync::vercmp(&tracked, installed), Some(n) if n > 0)
            }
            // No installed output: the built set is the only evidence. A
            // recipe with neither is never stale (explicit selection).
            None => match &built {
                Some(built) => matches!(sync::vercmp(&tracked, built), Some(n) if n > 0),
                None => false,
            },
        };
        if is_stale {
            stale.push(StaleRow {
                id: id.clone(),
                tracked,
                installed: installed_version,
                built,
            });
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

    /// Split-output pin (rule 25(d), §E.3 gap-G1 `<consumer-id>`): the
    /// forced-rebuild marker rides the RECIPE-id key the write side stages
    /// (a consumer whose ELF-owning pkgname differs from its recipe id) —
    /// the freshness gate reads exactly that key, so the pending repair
    /// outranks every freshness claim instead of leaking unseen.
    #[test]
    fn a_pending_abi_repair_marker_forces_the_rebuild_by_recipe_id() {
        use gsa_model::TopologyRecord;
        let dir =
            std::env::temp_dir().join(format!("gsa-cli-prepare-marker-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let state = dir.join("state");
        std::fs::create_dir_all(state.join("abi-repair")).unwrap();
        std::fs::write(
            state.join("abi-repair").join("consumer-app"),
            "provider=libs-git\n",
        )
        .unwrap();
        let records = vec![TopologyRecord {
            id: RecipeId::new("consumer-app").unwrap(),
            path: "git/consumer-app".to_string(),
            groups: Vec::new(),
            edges: Vec::new(),
            tags: Vec::new(),
            source_line: 1,
        }];
        let graph = Graph::build(&records).unwrap();
        let cfg = PassConfig {
            skip_mode: Some(SkipMode::Skip),
            tolerance: 1,
            no_sync: true,
            notes: Vec::new(),
            srcdest: None,
        };
        let mut log = Vec::new();
        let plan = skip_decision(
            &dir.join("recipe"),
            "consumer-app",
            &state,
            &cfg,
            true,
            &graph,
            0,
            &mut log,
        );
        assert_eq!(
            plan,
            NodePlan::Build {
                reason: "abi-repair-pending".to_string()
            },
            "a recipe-id-keyed pending marker outranks every freshness claim: {log:?}"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}

/// The recipe's compiler family at planning time (§B.11): the run's
/// `--toolchain`, else the record's tag, else the PKGBUILD scan, else the
/// default — the same ladder the lane child walks, so the identity the
/// planner compares is the one the build will produce. An ambiguous recipe
/// resolves to the default here; the LANE refuses it with the named message,
/// which is the surface that can stop a build.
pub(crate) fn selected_toolchain(
    pkg: &str,
    record: &gsa_model::TopologyRecord,
    recipe_dir: &Path,
) -> gsa_model::toolchain::Toolchain {
    let source = std::fs::read_to_string(recipe_dir.join("PKGBUILD")).unwrap_or_default();
    gsa_recipe::toolchain::select(
        pkg,
        gsa_model::toolchain::override_value(),
        record.toolchain(),
        &source,
    )
    .map(|selected| selected.toolchain)
    .unwrap_or_else(|_| {
        gsa_model::toolchain::override_value()
            .or_else(|| record.toolchain())
            .unwrap_or(gsa_model::toolchain::Toolchain::DEFAULT)
    })
}
