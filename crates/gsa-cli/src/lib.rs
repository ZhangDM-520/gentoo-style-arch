//! `gsa` — the native build-and-install orchestrator for the curated recipe
//! set (`docs/gsa-contract.md`). Phase 2 executes build-only runs: it parses
//! the recipe repository natively (committed `.SRCINFO` + strict topology
//! loading, never bash evaluation) and dispatches makepkg through the lane
//! supervisor (`gsa-sched` + `gsa-build`).
//!
//! Exit codes for this phase are the contract's usage class (§G.1): success
//! 0, usage error 2 — where "usage error" also covers unknown/typo'd
//! references, invalid ranges, malformed configuration records, and every
//! spelling deferred to a later phase.

mod args;
mod build;
mod dashboard;
mod fetch;
mod help;
mod install;
mod maint;
mod output;
mod prepare;
mod qa;
mod query;
mod record;
mod render;
mod select;
mod standalone;

use std::io::Write;
use std::path::PathBuf;

use args::{Family, Hidden, Invocation, Parsed};
use gsa_graph::Graph;
use gsa_recipe::RecipeDb;
use gsa_topo::load_project;
use select::Ctx;

pub(crate) const RC_OK: i32 = 0;
pub(crate) const RC_USAGE: i32 = 2;
/// The refusal class (§G.1): the run computed a plan it will not start —
/// e.g. the ABI wave check's under-coverage (`abi-consumer-uncovered`).
pub(crate) const RC_REFUSED: i32 = 3;

/// What the engine can execute (contract §B; the `-M` maintain surface is
/// live with its phase — `gsa-maint` — and `-S`/`-B`/`-U`/`-Sw` runs carry
/// the build/install/fetch families).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Command {
    Topology,
    List,
    QueryList,
    QueryInfo,
    QuerySearch,
    QueryGroups,
    QueryFiles,
    QueryOwner,
    QueryUpdates,
    QueryBinpkg,
    QueryProbe,
    QueryAbi,
    QueryRevdep,
    Plan,
    Build,
    BuildInstall,
    Fetch,
    SyncPass,
    Update,
    Upgrade,
    Maint,
}

enum Disposition {
    Run(Command),
    Deferred(String),
    Bad(String),
}

/// The five §B.8 sync/freshness/toolchain modifiers made LIVE on every run
/// that builds or installs (`-B`, `-S`, `-Su`): the classifier consults this
/// roster and record.rs's flag-rule table mirrors them in continuations.
pub const SYNC_FLAGS: [&str; 5] = [
    "--skip",
    "--skip-built",
    "--vcs-skip-tolerance",
    "--no-sync",
    "--allow-broken-rustc",
];

pub fn help_text() -> String {
    help::render()
}

/// The recipe workspace of a run (plan-gsa-isolation.md W3). Resolution:
/// 1. `project` from the gsa.conf layers (dev/deployment override);
/// 2. the cwd walk — deprecated (fixtures and dev checkouts still use it;
///    a TTY run notes the deprecation, pipes stay byte-stable);
/// 3. the canonical store — the build user's working copy at
///    `recipe_root` (`GSA_RECIPES_DIR` > `recipe_dir` > the build user's
///    `~/.local/share/gsa/recipes`), fetched by `gsa -Sy` or — for
///    mutating runs — on demand. A legacy `<state>/recipes` is migrated
///    into place on sight (gsa_state::recipes::ensure_store).
/// `fetch` enables that on-demand store fetch; read paths pass `false`.
fn find_root() -> Option<PathBuf> {
    resolve_root(false, None).ok()
}

pub(crate) fn resolve_root(fetch: bool, state_flag: Option<&str>) -> Result<PathBuf, String> {
    let cfg = gsa_model::config::load()?;
    if let Some(project) = &cfg.project {
        return Ok(project.clone());
    }
    if let Some(root) = cwd_workspace() {
        // Demoted, not removed (plan W3): cwd discovery stays for the
        // fixture battery and dev checkouts. The note is TTY-only —
        // fixtures capture combined output and assert on its text.
        use std::io::IsTerminal;
        if std::io::stderr().is_terminal() {
            eprintln!(
                "gsa: note: workspace discovered from cwd (deprecated) — set `project` in gsa.conf or run `sudo gsa -Sy` to use the recipe store"
            );
        }
        return Ok(root);
    }
    let state = gsa_model::config::resolve_state_dir(state_flag)?;
    let (store, note) = gsa_state::recipes::ensure_store(&state)?;
    if let Some(note) = note {
        eprintln!("gsa: note: {note}");
    }
    if store.join("config").join("topology.conf").is_file() {
        return Ok(store);
    }
    if fetch {
        let url = cfg
            .recipe_url
            .clone()
            .unwrap_or_else(|| gsa_model::config::DEFAULT_RECIPE_URL.to_string());
        let (store, head) = gsa_state::recipes::fetch(&state, &url)?;
        eprintln!("gsa: recipe store fetched: {} at {head}", store.display());
        return Ok(store);
    }
    Err(format!(
        "cannot find a recipe workspace: {} (missing config/topology.conf)",
        gsa_model::config::WORKSPACE_HINT
    ))
}

/// The pre-W3 discovery: walk up from the current directory until
/// `config/topology.conf` is found (the strict loader's home).
fn cwd_workspace() -> Option<PathBuf> {
    let mut dir = std::env::current_dir().ok()?;
    loop {
        if dir.join("config").join("topology.conf").is_file() {
            return Some(dir);
        }
        if !dir.pop() {
            return None;
        }
    }
}

/// The workspace a run operates on: the staged standalone workspace when
/// `standalone::apply` staged one (plan-gsa-isolation.md W4), else the
/// normal discovery with its on-demand store fetch.
pub(crate) fn resolve_workspace(inv: &Invocation) -> Result<PathBuf, String> {
    match &inv.standalone_root {
        Some(root) => Ok(root.clone()),
        None => resolve_root(true, inv.state_dir.as_deref()),
    }
}

fn classify(inv: &Invocation) -> Disposition {
    // The build-run modifiers (§B.8) are real on the runs that build or
    // install and still deferred on every other spelling; everything else
    // deferred stays deferred everywhere. A `--dry-run` plan accepts the
    // roster of the run it PLANS (I4, 2026-10-28: §B.8's "combinable with
    // the families that can act" — the plan reads those flags and its
    // `command:` continuation must be replayable).
    let is_build_run = inv.family == Family::B && inv.action.is_none();
    let is_install_run = inv.family == Family::S && inv.action.is_none();
    let is_upgrade_run = inv.family == Family::U;
    // `-Su`/`-Syu` (§B.4, H9): build+install the stale set — `-Syu` syncs
    // first, `-Su` never does. Both take a build run's five §B.8
    // sync/freshness/toolchain modifiers.
    let is_update_run = inv.family == Family::S && inv.action == Some('u');
    // `-Sy` (§B.4): the version-sync pass only; it takes no build modifiers
    // beyond the state root its recipe work resolves through (§J.3).
    let is_sync_pass = inv.family == Family::S && inv.action == Some('y');
    // `-Sw` (§B.4): fetch-only; its run record resolves the state root
    // (§J.4 registration context) — the same `--state-dir` surface.
    let is_fetch_run = inv.family == Family::S && inv.action == Some('w');
    // The queries that read the state root (`-Q`/`-Qi`'s side-car columns,
    // `-Qb`/`-Qp`/`-Qa`/`-Qr`) take `--state-dir` like every other
    // state-root surface (§J.3).
    let is_state_query = inv.family == Family::Q
        && matches!(inv.action, None | Some('i') | Some('b') | Some('p') | Some('a') | Some('r'));
    let is_maint = inv.family == Family::M;
    // A `-M` cluster's accepted flags are per-verb (§B.7's sub-flags); a
    // cluster that spells no verb yet reports its own usage error from
    // `maint::run`, so the flag gate stands down and the cluster error —
    // the root cause — is what the user reads.
    let maint_gate_stands_down = is_maint && maint::verb_of(inv).is_err();
    let accepted: Vec<&str> = if is_build_run {
        let mut flags = build::REAL_BUILD_FLAGS.to_vec();
        flags.extend_from_slice(&SYNC_FLAGS);
        flags
    } else if is_install_run || is_update_run {
        let mut flags = build::REAL_INSTALL_FLAGS.to_vec();
        flags.extend_from_slice(&SYNC_FLAGS);
        flags
    } else if is_upgrade_run {
        install::REAL_UPGRADE_FLAGS.to_vec()
    } else if is_sync_pass || is_fetch_run {
        // I4 (2026-10-28): the §B.8 roster is combinable with the families
        // that act — a sync/fetch run reads the state root and takes the
        // override like every other state-root surface.
        vec!["--state-dir"]
    } else if is_state_query {
        vec!["--state-dir"]
    } else if is_maint {
        maint::verb_of(inv)
            .map(maint::accepted_flags)
            .unwrap_or_default()
    } else {
        Vec::new()
    };
    if let Some(flag) = inv
        .deferred_flags
        .iter()
        .find(|f| !maint_gate_stands_down && !accepted.contains(&f.as_str()))
    {
        return Disposition::Deferred(format!(
            "{flag} (a later phase owns it; a build run accepts --skip, --skip-built, --vcs-skip-tolerance, --no-sync, --allow-broken-rustc, --fail-fast, --lanes, --jobs, --intensity, --state-dir; an install run (-S/-U) additionally accepts --no-register-ignorepkg, --config)"
        ));
    }
    let accepts_pacman_args = matches!(inv.family, Family::S | Family::U) && inv.action.is_none();
    if inv.pacman_args.is_some() && !accepts_pacman_args {
        // `-- <pacman args…>` reaches only install transactions (§B.1).
        return Disposition::Bad(
            "-- <pacman args…> is forwarded to the pacman -U of an install run (-S/-U) only"
                .to_string(),
        );
    }
    // H7/H8 (2026-10-28): the query actions are `-Q`'s, and `-S` keeps only
    // its build+install grammar. A retired spelling is a usage error naming
    // its new home — never silently re-routed.
    if let (Family::S, Some(letter @ ('i' | 's' | 'g'))) = (inv.family, inv.action) {
        return Disposition::Bad(match letter {
            'i' => "-Si is retired (H7): 'gsa -Qi <ref…>' carries the merged info (recipe, topology, side-car, installed)".to_string(),
            's' => "-Ss is retired (H7): 'gsa -Qs <pattern…>' searches installed names/descriptions (pacman -Qs semantics)".to_string(),
            _ => "-Sg is retired (H7): 'gsa -Qg [name…]' lists groups/sets and their members".to_string(),
        });
    }
    let action = inv.action;
    let command = match (inv.family, action) {
        (Family::Q, None) => Command::QueryList,
        (Family::Q, Some('i')) => Command::QueryInfo,
        (Family::Q, Some('s')) => Command::QuerySearch,
        (Family::Q, Some('g')) => Command::QueryGroups,
        (Family::Q, Some('l')) => Command::QueryFiles,
        (Family::Q, Some('o')) => Command::QueryOwner,
        (Family::Q, Some('u')) => Command::QueryUpdates,
        (Family::Q, Some('b')) => Command::QueryBinpkg,
        (Family::Q, Some('p')) => Command::QueryProbe,
        (Family::Q, Some('a')) => Command::QueryAbi,
        (Family::Q, Some('r')) => Command::QueryRevdep,
        (Family::Q, Some('t')) => Command::Topology,
        (Family::S, None) if inv.dry_run => Command::Plan,
        (Family::S, Some('l')) => Command::List,
        (Family::B, None) if inv.dry_run => Command::Plan,
        (Family::B, None) => Command::Build,
        (Family::B, Some('l')) => Command::List,
        (Family::S, None) => Command::BuildInstall,
        (Family::U, None) => Command::Upgrade,
        (Family::M, _) => Command::Maint,
        (Family::S, Some('w')) => Command::Fetch,
        (Family::S, Some('y')) => Command::SyncPass,
        (Family::S, Some('u')) => Command::Update,
        _ => {
            return Disposition::Deferred(format!(
                "{} (later phase; the build-only family -B is what Phase 2 executes)",
                inv.spelling()
            ))
        }
    };
    if inv.dry_run
        && !matches!(
            command,
            Command::Plan | Command::Update | Command::Upgrade | Command::Fetch | Command::Maint
        )
    {
        return Disposition::Bad(
            "--dry-run applies to build/install/fetch/update actions (-S/-B/-U/-Sw/-Su) and the -M maintain verbs; queries are already read-only and `gsa -Sy` is the rewrite pass itself (recipe rewrites left uncommitted — there is no dry form)"
                .to_string(),
        );
    }
    if inv.leaf
        && !matches!(
            command,
            Command::List
                | Command::Plan
                | Command::Build
                | Command::BuildInstall
                | Command::Fetch
                | Command::Update
                | Command::Maint
        )
    {
        return Disposition::Bad(
            "--leaf applies to selections (-S/-B builds and their listings, -Mc's pruning selection)"
                .to_string(),
        );
    }
    Disposition::Run(command)
}

/// The privilege class of one command (plan-gsa-isolation.md W1; contract
/// §B.10): reads run as any user, mutations require root, and `-Mm` alone
/// stays build-user-only. Each run entry gates AFTER its usage preflights —
/// §G.1 ranks usage (2) above refusal (3), so a typo is always reported
/// before privilege.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Privilege {
    ReadOnly,
    Root { needs_build_user: bool },
    BuildUserOnly,
}

/// The privilege of one invocation: dry runs render plans (read-only), `-M`
/// is refined per verb by `maint::privilege`, everything else by command.
pub(crate) fn invocation_privilege(inv: &Invocation, command: &Command) -> Privilege {
    if inv.dry_run {
        return Privilege::ReadOnly;
    }
    match command {
        Command::Maint => maint::privilege(inv),
        other => command_privilege(other),
    }
}

pub(crate) fn command_privilege(command: &Command) -> Privilege {
    match command {
        Command::Topology
        | Command::List
        | Command::QueryList
        | Command::QueryInfo
        | Command::QuerySearch
        | Command::QueryGroups
        | Command::QueryFiles
        | Command::QueryOwner
        | Command::QueryUpdates
        | Command::QueryBinpkg
        | Command::QueryProbe
        | Command::QueryAbi
        | Command::QueryRevdep
        | Command::Plan => Privilege::ReadOnly,
        Command::Build
        | Command::BuildInstall
        | Command::Fetch
        | Command::SyncPass
        | Command::Update => Privilege::Root {
            needs_build_user: true,
        },
        Command::Upgrade => Privilege::Root {
            needs_build_user: false,
        },
        // Refined per verb (and its mutation flags) by `maint::privilege`.
        Command::Maint => Privilege::ReadOnly,
    }
}

/// The transparent privilege gate (contract §B.10): pacman's shape —
/// `you cannot perform this operation unless you are root` — plus one banner
/// line naming who builds. Returns `Some(rc)` when the run must stop here
/// (§G.1 rc 3, "the run refused to start"), before any state is written.
/// `announce` is false for hidden fixture seams, whose output is parsed.
pub(crate) fn privilege_gate(
    spelling: &str,
    privilege: Privilege,
    announce: bool,
    err: &mut dyn Write,
) -> Option<i32> {
    use gsa_model::privilege as p;
    match privilege {
        Privilege::ReadOnly => None,
        Privilege::BuildUserOnly => {
            if p::effective_uid() == 0 {
                let _ = writeln!(
                    err,
                    "gsa: {spelling} rewrites your source-mirror tree and must run as the build user, never under a root supervisor (docs/source-sharing.md)"
                );
                return Some(RC_REFUSED);
            }
            None
        }
        Privilege::Root { needs_build_user } => {
            if p::effective_uid() != 0 {
                let _ = writeln!(
                    err,
                    "gsa: error: you cannot perform this operation unless you are root"
                );
                let _ = writeln!(
                    err,
                    "gsa: hint: rerun as 'sudo gsa {spelling} …' — the engine and pacman run as root; builds run as your user"
                );
                return Some(RC_REFUSED);
            }
            if needs_build_user && p::build_user().is_none() {
                let _ = writeln!(
                    err,
                    "gsa: a build run needs a build user: run 'sudo gsa {spelling} …' from your build user's shell (makepkg cannot run as root, and a root shell has no user to drop to)"
                );
                return Some(RC_REFUSED);
            }
            if announce {
                let _ = writeln!(err, "{}", p::privileged_banner(needs_build_user));
            }
            None
        }
    }
}

/// Build-domain hidden seams run at the INVOKER's identity (fixtures drive
/// them as any user), but a bare root shell must not reach them: there is no
/// build user to drop to and the work — including recipe-shell eval — would
/// run as root (contract §B.10's never-improvise rule; 2026-10-17 sweep).
fn bare_root_refusal(err: &mut dyn Write) -> Option<i32> {
    use gsa_model::privilege as p;
    if p::effective_uid() == 0 && p::build_user().is_none() {
        let _ = writeln!(
            err,
            "gsa: a build-domain entry needs a build user: run 'sudo gsa …' from your build user's shell (a root shell has no user to drop to)"
        );
        return Some(RC_REFUSED);
    }
    None
}

pub(crate) fn resolve_intensity(project: &gsa_topo::ProjectConfig) -> Result<String, String> {    match std::env::var("GSA_INTENSITY") {
        Ok(value) if !value.is_empty() => {
            if gsa_topo::INTENSITY_LEVELS.contains(&value.as_str()) {
                Ok(value)
            } else {
                Err(format!(
                    "GSA_INTENSITY must be one of {} (got '{value}')",
                    gsa_topo::INTENSITY_LEVELS.join(",")
                ))
            }
        }
        _ => Ok(project.defaults.intensity.clone()),
    }
}

fn cmd_error(message: impl Into<String>) -> String {
    message.into()
}

/// One selection note, in the active vocabulary: the human default keeps the
/// readable `gsa: note: …` prose; the machine mode is the leveled kv
/// `note` event (same message, whitespace-squashed — `output::kv_line`'s
/// one-line grammar).
fn write_notes(err: &mut dyn Write, notes: &[String]) {
    for note in notes {
        if output::is_human() {
            let _ = writeln!(err, "gsa: note: {note}");
        } else {
            let _ = writeln!(
                err,
                "{}",
                output::kv_line(output::Level::Info, "note", &[("msg", output::squash(note))])
            );
        }
    }
}

/// Resolve refs to records in canonical build order (deduplicated).
fn resolve_records(
    ctx: &Ctx<'_>,
    targets: &[String],
    err: &mut dyn Write,
) -> Result<Vec<usize>, String> {
    let mut indices = std::collections::BTreeSet::new();
    for token in targets {
        let (found, notes) =
            select::resolve_ref(ctx, token, 0).map_err(|e| cmd_error(e.to_string()))?;
        write_notes(err, &notes);
        indices.extend(found);
    }
    let mut indices: Vec<usize> = indices.into_iter().collect();
    indices.sort_by_key(|&i| ctx.graph.position(i));
    Ok(indices)
}

fn no_ranges(inv: &Invocation) -> Result<(), String> {
    if inv.ranges.is_empty() {
        Ok(())
    } else {
        Err(cmd_error(
            "index ranges address an -S/-B selection (see 'gsa -Sl')".to_string(),
        ))
    }
}

fn execute(
    inv: &Invocation,
    command: Command,
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> Result<i32, String> {
    // `-Ql`/`-Qo` are pacman delegates (H8: "pacman queries stay pacman"):
    // they need no workspace — the argv goes straight to pacman.
    if matches!(command, Command::QueryFiles | Command::QueryOwner) {
        let action = if command == Command::QueryFiles {
            "-Ql"
        } else {
            "-Qo"
        };
        return query::pacman_delegate(action, inv, out, err);
    }
    let root = match &inv.standalone_root {
        // A standalone-target run staged its own workspace (plan W4); the
        // report verbs' own discovery never fetches (read-only, §B.10).
        Some(root) => root.clone(),
        None => find_root().ok_or_else(|| {
            cmd_error(format!(
                "cannot find a recipe workspace: {} (missing config/topology.conf)",
                gsa_model::config::WORKSPACE_HINT
            ))
        })?,
    };
    let project = load_project(&root).map_err(|e| cmd_error(e.to_string()))?;
    let graph = Graph::build(&project.topology.records)
        .map_err(|e| cmd_error(format!("config/topology.conf: {e}")))?;

    if command == Command::Topology {
        let ctx = Ctx {
            project: &project,
            graph: &graph,
            db: &RecipeDb::load(&root, &[]).map_err(|e| cmd_error(e.to_string()))?,
            user_sets: select::load_user_sets(inv),
        };
        let _ = write!(out, "{}", render::render_topology_channel(&ctx));
        return Ok(RC_OK);
    }

    let db = RecipeDb::load(&root, graph.records()).map_err(|e| cmd_error(e.to_string()))?;
    let ctx = Ctx {
        project: &project,
        graph: &graph,
        db: &db,
        user_sets: select::load_user_sets(inv),
    };

    match command {
        Command::Topology
        | Command::QueryFiles
        | Command::QueryOwner
        | Command::Build
        | Command::BuildInstall
        | Command::Fetch
        | Command::SyncPass
        | Command::Update
        | Command::Upgrade
        | Command::Maint => unreachable!(),
        Command::List => {
            let (listed, whole_set) = if inv.targets.is_empty() && inv.ranges.is_empty() {
                (select::whole_set_listing(&ctx), true)
            } else {
                let selection = select::build_selection(&ctx, &inv.targets, &inv.ranges, inv.leaf)
                    .map_err(|e| cmd_error(e.to_string()))?;
                write_notes(err, &selection.notes);
                (selection.listed, false)
            };
            let _ = write!(out, "{}", render::render_listing(&ctx, &listed, whole_set));
        }
        Command::QueryGroups => {
            no_ranges(inv)?;
            let text =
                render::render_groups(&ctx, &inv.targets).map_err(|e| cmd_error(e.to_string()))?;
            let _ = write!(out, "{text}");
        }
        Command::QueryList => {
            query::query_list(inv, out).map_err(cmd_error)?;
        }
        Command::QueryInfo => {
            query::query_info(&ctx, inv, out, err).map_err(cmd_error)?;
        }
        Command::QuerySearch => {
            query::query_search(inv, out).map_err(cmd_error)?;
        }
        Command::QueryUpdates => {
            query::query_updates(&ctx, &root, inv, out).map_err(cmd_error)?;
        }
        Command::QueryBinpkg => {
            query::query_binpkg(&ctx, inv, out, err).map_err(cmd_error)?;
        }
        Command::QueryProbe => {
            query::query_probe(inv, out, err).map_err(cmd_error)?;
        }
        Command::QueryAbi => {
            no_ranges(inv)?;
            query::query_abi(&ctx, inv, out, err).map_err(cmd_error)?;
        }
        Command::QueryRevdep => {
            query::query_revdep(inv, out, err).map_err(cmd_error)?;
        }
        Command::Plan => {
            return Ok(build::plan_only(&ctx, inv, &project, out, err).map_err(cmd_error)?);
        }
    }
    Ok(RC_OK)
}

/// Run one invocation against the current directory's repository. Returns
/// the process exit code and writes all output through `out`/`err`.
pub fn run(argv: &[String], out: &mut dyn Write, err: &mut dyn Write) -> i32 {
    let parsed = args::parse(argv);
    // Pin the output mode before any rendering (output::mode() falls back to
    // stdout's tty-ness when --machine was not given).
    if let Ok(Parsed::Invoke(inv)) = &parsed {
        if let Some(m) = inv.output_mode {
            output::set_mode(m);
        }
    }
    match parsed {
        Ok(Parsed::Help) => {
            let _ = write!(out, "{}", help_text());
            RC_OK
        }
        Ok(Parsed::Hidden(Hidden::LaneJob(args))) => {
            // The lane child entry (contract §D.1): one package, one result
            // file; its exit code IS its lane outcome code (§G.2).
            if let Some(rc) = bare_root_refusal(err) {
                return rc;
            }
            gsa_build::lane::run_lane_job(&args, err)
        }
        Ok(Parsed::Hidden(Hidden::FetchJob(args))) => {
            // The fetch child entry (contract §D.1): one recipe, one typed
            // result file; `failed` is data, not process failure (exit 0).
            if let Some(rc) = bare_root_refusal(err) {
                return rc;
            }
            gsa_fetch::engine::run_fetch_job(&args, err)
        }
        Ok(Parsed::Hidden(Hidden::StaleLockCheck)) => {
            // The production pacman-lock probe without a run (§D.1).
            gsa_sched::lock::pacman_lock_probe(out, err)
        }
        Ok(Parsed::Hidden(Hidden::InstallDecide(args))) => {
            // The one decision seam in isolation (§D.1): rows on stdout,
            // nothing else touched.
            install::run_install_decide(&args, out, err)
        }
        Ok(Parsed::Hidden(Hidden::InstallRegister(args))) => {
            // The IgnorePkg registration write path in isolation (§D.1).
            install::run_install_register(&args, out, err)
        }
        Ok(Parsed::Hidden(Hidden::RegisterIgnorepkg(args))) => {
            // The one-shot backfill (rule 9).
            install::run_register_ignorepkg(&args, out, err)
        }
        Ok(Parsed::Hidden(Hidden::LocalDbCheck(args))) => {
            // The side-car self-check without a run (§D.1), including the
            // run-history read of the §H.1 persistence amendment.
            query::run_local_db_check(&args, out, err)
        }
        Ok(Parsed::Hidden(Hidden::QaCheck(args))) => {
            // The QA check registry's single-entry point (§D.1): one named
            // check, its findings on stdout, rc per §G.
            qa::run_qa_check(&args, out, err)
        }
        Ok(Parsed::Invoke(mut inv)) => match classify(&inv) {
            Disposition::Deferred(why) => {
                let _ = writeln!(err, "gsa: deferred to a later phase: {why}");
                RC_USAGE
            }
            Disposition::Bad(message) => {
                let _ = writeln!(err, "gsa: {message}");
                RC_USAGE
            }
            Disposition::Run(command) => {
                // Standalone targets (plan-gsa-isolation.md W4): stage the
                // shared recipe(s) and rewrite the selection to the staged
                // ids BEFORE dispatch. An ephemeral staging area (a dry run,
                // or a run the privilege gate will refuse) is cleaned up
                // after the entry returns.
                match standalone::apply(&mut inv, &command) {
                    Err(message) => {
                        let _ = writeln!(err, "gsa: {message}");
                        RC_USAGE
                    }
                    Ok(staged) => {
                        let code = match command {
                            Command::Build => build::run_build(&inv, out, err),
                            Command::BuildInstall => build::run_build_install(&inv, out, err),
                            Command::Fetch => fetch::run_fetch_only(&inv, out, err),
                            Command::SyncPass => prepare::run_sync_pass(&inv, out, err),
                            Command::Update => build::run_update(&inv, out, err),
                            Command::Upgrade => install::run_upgrade(&inv, out, err),
                            Command::Maint => maint::run(&inv, out, err),
                            command => match execute(&inv, command, out, err) {
                                Ok(code) => code,
                                Err(message) => {
                                    let _ = writeln!(err, "gsa: {message}");
                                    RC_USAGE
                                }
                            },
                        };
                        if let Some(staged) = staged {
                            staged.cleanup();
                        }
                        code
                    }
                }
            }
        },
        Err(message) => {
            let _ = writeln!(err, "gsa: {message}");
            if message == "no action given" {
                // Contract §B.1: a bare invocation prints the roster.
                let _ = write!(err, "{}", help_text());
            } else {
                let _ = writeln!(err, "try 'gsa --help'");
            }
            RC_USAGE
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn run_capture(args: &[&str]) -> (i32, String, String) {
        let argv: Vec<String> = args.iter().map(|s| s.to_string()).collect();
        let mut out = Vec::new();
        let mut err = Vec::new();
        let code = run(&argv, &mut out, &mut err);
        (
            code,
            String::from_utf8_lossy(&out).into_owned(),
            String::from_utf8_lossy(&err).into_owned(),
        )
    }

    #[test]
    fn deferred_spellings_refuse_with_a_clear_message() {
        // -Ql/-Qo are LIVE pacman delegates (I3, contract §B.3): a misuse
        // is a usage-class error naming the shape, never the deferred
        // refusal. -Qu is live too but reports the whole stale set — assert
        // it at the classifier, never through `run` (it version-evaluates
        // the workspace).
        for spelling in ["-Ql", "-Qo"] {
            let (code, _out, err) = run_capture(&[spelling]);
            assert_eq!(code, 2, "{spelling} must be a usage error");
            assert!(
                !err.contains("deferred to a later phase"),
                "{spelling} is live: {err}"
            );
        }
        for spelling in ["-Qu"] {
            let argv: Vec<String> = [spelling].iter().map(|s| s.to_string()).collect();
            let parsed = args::parse(&argv).expect("a bare spelling parses");
            let Parsed::Invoke(inv) = parsed else {
                panic!("{spelling} must parse as an invocation");
            };
            assert!(
                matches!(classify(&inv), Disposition::Run(_)),
                "{spelling} is live and must not defer"
            );
        }
        // H7/H8: the retired `-S` query spellings answer a named usage
        // error pointing at their new `-Q` homes — never a silent re-route.
        for (spelling, moved_to) in [("-Si", "gsa -Qi"), ("-Ss", "gsa -Qs"), ("-Sg", "gsa -Qg")] {
            let (code, _out, err) = run_capture(&[spelling]);
            assert_eq!(code, 2, "{spelling} must be a usage error");
            assert!(err.contains("retired"), "{spelling}: {err}");
            assert!(
                err.contains(moved_to),
                "{spelling} must name {moved_to}: {err}"
            );
        }
        // -Sy/-Su/-Syu are LIVE (contract §B.4). Assert at the classifier —
        // never through `run`, which would execute a real version-sync pass
        // against whatever repository the test runs in.
        for spelling in ["-Sy", "-Su", "-Syu"] {
            let argv: Vec<String> = [spelling].iter().map(|s| s.to_string()).collect();
            let parsed = args::parse(&argv).expect("a bare spelling parses");
            let Parsed::Invoke(inv) = parsed else {
                panic!("{spelling} must parse as an invocation");
            };
            assert!(
                matches!(classify(&inv), Disposition::Run(_)),
                "{spelling} is live and must not defer"
            );
        }
        // -Qa/-Qr are live (the ABI subsystem's query surface): usage-class
        // errors, never the deferred refusal.
        let (code, _out, err) = run_capture(&["-Qa"]);
        assert_eq!(code, 2, "-Qa without a ref is usage");
        assert!(err.contains("requires at least one reference"), "{err}");
        assert!(!err.contains("deferred to a later phase"), "{err}");
        // Build-run modifiers stay deferred outside a real build.
        let (code, _out, err) = run_capture(&["-Sl", "--lanes", "2"]);
        assert_eq!(code, 2);
        assert!(err.contains("deferred to a later phase"), "{err}");
        // --quiet/--verbose are parse-and-refuse deferred spellings (§B.8):
        // every command answers rc 2 naming the flag — never mirrored (§H.2).
        for spelling in ["--quiet", "--verbose"] {
            let (code, _out, err) = run_capture(&["-Sl", spelling]);
            assert_eq!(code, 2, "{spelling} must be refused rc 2");
            assert!(
                err.contains("deferred to a later phase"),
                "{spelling}: {err}"
            );
            assert!(err.contains(spelling), "{spelling} must be named: {err}");
        }
        // The not-yet-real hidden seams defer; --lane-job/--stale-lock-check
        // /--fetch-job/--local-db-check/--qa-check are live seams
        // (tests/gsa-sched-v2.sh, tests/gsa-fetch-v2.sh,
        // tests/gsa-state-v2.sh, tests/gsa-qa-v2.sh) — the QA seam's bare
        // and unknown-name invocations are usage-class (§G), never deferred.
        let (code, _out, err) = run_capture(&["--qa-check"]);
        assert_eq!(code, 2, "--qa-check without a name is usage (§G)");
        assert!(err.contains("requires a check name"), "{err}");
        let (code, _out, err) = run_capture(&["--qa-check", "no-such-check"]);
        assert_eq!(code, 2, "an unknown check name is usage (§G)");
        assert!(err.contains("unknown check 'no-such-check'"), "{err}");
    }

    #[test]
    fn b8_modifiers_combine_with_the_families_that_act() {
        // I4 (2026-10-28): a `--dry-run` plan accepts the roster of the run
        // it plans, and `-Sw`/`-Sy` take the `--state-dir` their paths read.
        // These are exactly the combinations an §H.2 `command:`
        // continuation restates — a rendered resume must parse and run.
        for argv in [
            vec!["-S", "--dry-run", "--skip", "--state-dir", "/x"],
            vec!["-B", "--dry-run", "--lanes", "2", "--fail-fast"],
            vec!["-S", "--dry-run", "--state-dir", "/x", "--no-sync"],
            vec!["-Sw", "--state-dir", "/x"],
            vec!["-Sy", "--state-dir", "/x"],
            vec!["-Q", "--state-dir", "/x"],
            vec!["-Qi", "--state-dir", "/x", "ref"],
        ] {
            let argv: Vec<String> = argv.iter().map(|s| s.to_string()).collect();
            let parsed = args::parse(&argv).expect("a roster invocation parses");
            let Parsed::Invoke(inv) = parsed else {
                panic!("{argv:?} must parse as an invocation");
            };
            assert!(
                matches!(classify(&inv), Disposition::Run(_)),
                "{argv:?} must be live — the §H.2 continuation restates these flags"
            );
        }
        // `-Sy` keeps its no-dry-form refusal (recipe rewrites left
        // uncommitted — there is no dry form).
        let argv: Vec<String> = ["-Sy", "--dry-run"].iter().map(|s| s.to_string()).collect();
        let parsed = args::parse(&argv).expect("parses");
        let Parsed::Invoke(inv) = parsed else {
            panic!("must parse");
        };
        assert!(
            matches!(classify(&inv), Disposition::Bad(_)),
            "-Sy has no dry form (recipe rewrites left uncommitted)"
        );
    }

    #[test]
    fn side_car_surfaces_are_live_and_usage_checked() {
        // -Qp with a nonexistent archive: rc 2 naming the argument (§D.1's
        // seam shape — bad argv is named before any state is touched).
        let (code, _out, err) = run_capture(&["-Qp", "no-such-archive.pkg.tar.zst"]);
        assert_eq!(code, 2);
        assert!(err.contains("malformed archive argument"), "{err}");
        let (code, _out, err) = run_capture(&["-Qp"]);
        assert_eq!(code, 2);
        assert!(err.contains("requires at least one archive"), "{err}");
        // --local-db-check rejects an unknown verb with rc 2, naming it.
        let (code, _out, err) = run_capture(&["--local-db-check", "bogus"]);
        assert_eq!(code, 2);
        assert!(err.contains("unknown argument 'bogus'"), "{err}");
        // -Qb over an empty scratch state root: rc 0, no rows, and the
        // scratch tree is where every byte landed (§J.3).
        let scratch = std::env::temp_dir().join(format!("gsa-cli-qbin-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&scratch);
        std::fs::create_dir_all(&scratch).unwrap();
        let (code, out, err) = run_capture(&["-Qb", "--state-dir", scratch.to_str().unwrap()]);
        assert_eq!(code, 0, "{err}");
        assert!(out.is_empty(), "an empty index prints no rows: {out}");
    }

    #[test]
    fn fetch_spellings_are_live_and_usage_checked() {
        // `-Sw` without a selection: usage (§B.1), never a deferred spelling.
        let (code, _out, err) = run_capture(&["-Sw"]);
        assert_eq!(code, 2);
        assert!(err.contains("selection is mandatory"), "{err}");
        // `gsa fetch` is exactly `gsa -Sw` (§B.1's one word alias).
        let (code, _out, err) = run_capture(&["fetch"]);
        assert_eq!(code, 2);
        assert!(err.contains("selection is mandatory"), "{err}");
        // The fetch child seam (§D.1) rejects bad payloads with rc 2 and a
        // message naming the argument — before any fetch work runs.
        let (code, _out, err) = run_capture(&["--fetch-job", "only-one"]);
        assert_eq!(code, 2);
        assert!(err.contains("--fetch-job"), "{err}");
        let (code, _out, err) = run_capture(&["--fetch-job", "bad pkg", "x.result"]);
        assert_eq!(code, 2);
        assert!(err.contains("not a valid recipe id"), "{err}");
        // A fetch run never takes build-run knobs (they are build-run fetch-
        // ahead flags and defer elsewhere).
        let (code, _out, err) = run_capture(&["-Sw", "--no-prefetch", "mesa-git"]);
        assert_eq!(code, 2);
        assert!(err.contains("deferred to a later phase"), "{err}");
    }

    #[test]
    fn install_spellings_are_usage_checked_not_deferred() {
        // `gsa -S` without a selection: usage (§B.1), not a deferred spelling.
        let (code, _out, err) = run_capture(&["-S"]);
        assert_eq!(code, 2);
        assert!(err.contains("selection is mandatory"), "{err}");
        // `gsa -U` with an empty resolution: §C.1's exact reason.
        let (code, _out, err) = run_capture(&["-U"]);
        assert_eq!(code, 2);
        assert!(err.contains("selection resolved to no packages"), "{err}");
        // `-- <pacman args…>` reaches install runs only (§B.1).
        let (code, _out, err) = run_capture(&["-B", "--", "--overwrite", "*"]);
        assert_eq!(code, 2);
        assert!(err.contains("-- <pacman args"), "{err}");
    }

    #[test]
    fn install_seams_reject_bad_usage_with_rc_two() {
        // --install-decide: unknown mode / unreadable list / non-file argument
        // (§D.1) — all before any decision code runs.
        let (code, _out, err) = run_capture(&["--install-decide", "bogus", "x.pkg.tar.zst"]);
        assert_eq!(code, 2);
        assert!(err.contains("unknown mode 'bogus'"), "{err}");
        let (code, _out, err) = run_capture(&["--install-decide", "checked"]);
        assert_eq!(code, 2);
        assert!(err.contains("unreadable argument list"), "{err}");
        let (code, _out, err) = run_capture(&["--install-decide"]);
        assert_eq!(code, 2);
        assert!(err.contains("unreadable argument list"), "{err}");
        let (code, _out, err) = run_capture(&[
            "--install-decide",
            "force",
            "definitely-missing.pkg.tar.zst",
        ]);
        assert_eq!(code, 2);
        assert!(err.contains("malformed archive argument"), "{err}");
        // --install-register wants <conf> <subject> <names…>.
        let (code, _out, err) = run_capture(&["--install-register", "a.conf", "subject"]);
        assert_eq!(code, 2);
        assert!(err.contains("--install-register"), "{err}");
        // --register-ignorepkg takes at most one conf argument.
        let (code, _out, err) = run_capture(&["--register-ignorepkg", "a.conf", "extra"]);
        assert_eq!(code, 2);
        assert!(err.contains("--register-ignorepkg"), "{err}");
    }

    #[test]
    fn a_build_without_a_selection_is_a_usage_error() {
        // Selection is mandatory (contract §B.1) — a bare `gsa -B` is a
        // usage error, never a deferred spelling and never a run.
        let (code, _out, err) = run_capture(&["-B"]);
        assert_eq!(code, 2);
        assert!(err.contains("selection is mandatory"), "{err}");
    }

    #[test]
    fn stale_lock_check_rejects_extra_arguments() {
        let (code, _out, err) = run_capture(&["--stale-lock-check", "extra"]);
        assert_eq!(code, 2);
        assert!(err.contains("takes no arguments"), "{err}");
    }

    #[test]
    fn maint_spellings_are_live_and_usage_checked() {
        // A bare -M spells no action (§B.7): usage, never a deferred
        // spelling and never a run.
        let (code, _out, err) = run_capture(&["-M"]);
        assert_eq!(code, 2);
        assert!(err.contains("no default action"), "{err}");
        assert!(!err.contains("deferred to a later phase"), "{err}");
        // An unknown action letter is named by the parser, never
        // auto-corrected.
        let (code, _out, err) = run_capture(&["-Mx"]);
        assert_eq!(code, 2);
        assert!(err.contains("unknown option letter 'x'"), "{err}");
        // The -M cluster's usage fences fire before any state is touched.
        let (code, _out, err) = run_capture(&["-Mi", "--prune", "--backfill"]);
        assert_eq!(code, 2);
        assert!(err.contains("ONE of --prune / --backfill"), "{err}");
        let (code, _out, err) = run_capture(&["-Ms", "--add", "--remove"]);
        assert_eq!(code, 2);
        assert!(err.contains("--add and --remove are alternatives"), "{err}");
        let (code, _out, err) = run_capture(&["-Ml", "mesa-git"]);
        assert_eq!(code, 2);
        assert!(err.contains("-Ml takes no targets"), "{err}");
        // --leaf is a selection modifier: real on -Mc's pruning selection,
        // usage-class everywhere else in the family.
        let (code, _out, err) = run_capture(&["-Ms", "--leaf"]);
        assert_eq!(code, 2);
        assert!(err.contains("--leaf applies to -Mc"), "{err}");
        // A flag outside a verb's roster keeps the deferred refusal —
        // per-verb acceptance is §B.7's, not the family's.
        let (code, _out, err) = run_capture(&["-Mc", "--skip", "mesa-git"]);
        assert_eq!(code, 2);
        assert!(err.contains("deferred to a later phase"), "{err}");
    }

    #[test]
    fn help_and_bare_invocation() {
        let (code, out, _err) = run_capture(&["--help"]);
        assert_eq!(code, 0);
        assert!(out.contains("Command surface"));
        assert!(out.contains("GSA_TARGET_CPU"));
        // Every real flag is in the roster (contract §L.1); hidden seams are
        // excluded from it (§D.1).
        for flag in [
            "--dry-run",
            "--leaf",
            "--fail-fast",
            "--lanes",
            "--jobs",
            "--intensity",
            "--state-dir",
            "--no-prefetch",
            "--prefetch-ahead",
            // The -M sub-flags (§B.7) are real flags and belong in the
            // roster (§L.1: a flag absent from --help does not exist).
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
            assert!(out.contains(flag), "--help must name {flag}");
        }
        for seam in [
            "--lane-job",
            "--stale-lock-check",
            "--install-decide",
            "--fetch-job",
        ] {
            assert!(!out.contains(seam), "--help must hide {seam}");
        }
        let (code, _out, err) = run_capture(&[]);
        assert_eq!(code, 2);
        assert!(err.contains("Usage: gsa"));
    }

    #[test]
    fn mutating_verbs_gate_and_reads_never_do() {
        use gsa_model::privilege as p;
        // The §B.10 classification: reads are never gated, builds need root
        // plus a build user, installs need root only.
        assert_eq!(command_privilege(&Command::QueryList), Privilege::ReadOnly);
        assert_eq!(command_privilege(&Command::Plan), Privilege::ReadOnly);
        assert_eq!(
            command_privilege(&Command::Build),
            Privilege::Root {
                needs_build_user: true
            }
        );
        assert_eq!(
            command_privilege(&Command::Upgrade),
            Privilege::Root {
                needs_build_user: false
            }
        );
        if p::effective_uid() != 0 {
            let mut err = Vec::new();
            assert_eq!(
                privilege_gate(
                    "-B",
                    Privilege::Root {
                        needs_build_user: true
                    },
                    true,
                    &mut err
                ),
                Some(RC_REFUSED)
            );
            let err = String::from_utf8_lossy(&err);
            assert!(
                err.contains("you cannot perform this operation unless you are root"),
                "{err}"
            );
            assert!(err.contains("sudo gsa -B"), "{err}");
            // A read passes untouched and prints nothing.
            let mut quiet = Vec::new();
            assert_eq!(
                privilege_gate("-Q", Privilege::ReadOnly, true, &mut quiet),
                None
            );
            assert!(quiet.is_empty(), "{quiet:?}");
        }
    }

    #[test]
    fn maint_privilege_follows_the_verb_and_its_mutation_flags() {
        fn inv(args: &[&str]) -> Invocation {
            let argv: Vec<String> = args.iter().map(|s| s.to_string()).collect();
            match args::parse(&argv) {
                Ok(Parsed::Invoke(inv)) => inv,
                other => panic!("not an invocation: {other:?}"),
            }
        }
        assert_eq!(maint::privilege(&inv(&["-Ma"])), Privilege::ReadOnly);
        assert_eq!(maint::privilege(&inv(&["-Mm"])), Privilege::BuildUserOnly);
        assert_eq!(maint::privilege(&inv(&["-Md"])), Privilege::ReadOnly);
        assert_eq!(
            maint::privilege(&inv(&["-Md", "--fix"])),
            Privilege::Root {
                needs_build_user: false
            }
        );
        assert_eq!(maint::privilege(&inv(&["-Ml"])), Privilege::ReadOnly);
        assert_eq!(
            maint::privilege(&inv(&["-Ml", "--keep", "2"])),
            Privilege::Root {
                needs_build_user: false
            }
        );
        assert_eq!(
            maint::privilege(&inv(&["-Mc", "mesa-git"])),
            Privilege::Root {
                needs_build_user: false
            }
        );
        // A dry run is a plan: never gated.
        assert_eq!(
            invocation_privilege(&inv(&["-Mc", "--dry-run", "mesa-git"]), &Command::Maint),
            Privilege::ReadOnly
        );
    }
}
