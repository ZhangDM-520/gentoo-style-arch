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
mod fetch;
mod install;
mod maint;
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
    RecipeInfo,
    UniverseSearch,
    Groups,
    QueryList,
    QueryInfo,
    QuerySearch,
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
    "\
gsa — native build-and-install orchestrator for the curated recipe set
(contract docs/gsa-contract.md; build (-B), build+install (-S), fetch-only
(-Sw), install-from-archives (-U) and maintain (-M) runs are live)

Usage: gsa <FAMILY>[cluster] [long-modifiers] [targets…] [ranges…] [-- <pacman args…>]

Privilege (contract §B.10, like pacman): -Q and every report/plan verb run
unprivileged; -S/-B/-U and write-side -M verbs require root — rerun with
sudo. Builds always run as your user (makepkg is dropped from the root run),
and a root shell without a build user is refused with guidance.

Families (exactly one per invocation; lowercase letters form the cluster):
  -Q   query the buildable universe (and, later, pacman's installed database)
  -S   build + install the selection (each package installed before its consumers compile)
  -B   build-only: archives to the build cache (PKGDEST), nothing installed
  -U   install from archives: nothing is built
  -M   maintain engine state: audit, doctor, IgnorePkg closure, logs,
       mirrors, prune strengths, sets/world, run history
  gsa fetch is exactly gsa -Sw

Command surface:
  gsa -Qt                        resolved topology records, one per line:
                                 id|path|groups|edges|tags (the tooling channel)
  gsa -Sl [targets…] [ranges…]   ordered selection listing with range indices (-Bl same)
  gsa -Si <ref…>                 recipe info: metadata, topology record, groups,
                                 build-order edges, tags
  gsa -Ss <pattern…>             search the buildable universe (topology + .SRCINFO)
  gsa -Sg [name…]                groups/sets and their members (all with counts by default)
  gsa -Q [ref…]                  package names with versions over the buildable universe
  gsa -Qi <ref…>                 package info: pacman fields plus the recipe record
  gsa -Qs <pattern…>             search package names/descriptions
  gsa -Qb [ref…]                 binpkg index rows: the retained built instances
                                 the side-car DB records (hash-bound, §J.4)
  gsa -Qp <archive…>             archive probe: the archive's .PKGINFO matched
                                 against its index row, hash/size agreement
                                 reported
  gsa -S <targets…> [ranges…]    build the selection and install each package's
                                 archives before its consumers compile
                                 (install-before-dependents; checked install)
  gsa -Sf …                      force install: always run pacman -U, no
                                 same-version skip
  gsa -Sc …                      prune strength 1 first (src/pkg/build trees and
                                 archives), then build + install
  gsa -B <targets…> [ranges…]    build the selection to archives in the build
                                 cache (PKGDEST; nothing is installed, no
                                 pacman call)
  gsa -U <ref…|archive-path…>    install the named packages' newest complete
                                 archive sets (or the named paths) in ONE
                                 pacman -U transaction; nothing is built
  gsa -Ua                        install every index-complete archive set in the
                                 workspace in one transaction (force mode)
  gsa -Uf                        force: bypass the same-version already-installed skip
  -- <pacman args…>              forwarded verbatim to every pacman -U of an
                                 install run (-S/-U), e.g. -Ua -- --overwrite '*'
  gsa -S --dry-run <targets…> [ranges…]    build-order plan without building
  gsa -B --dry-run <targets…> [ranges…]    the same plan shape for build-only
  gsa -Sw <targets…> [ranges…]   fetch and verify the selection's sources
                                 through makepkg --verifysource — no build,
                                 no install; verdict rows are advisory (§D)
  gsa -Sy [targets…] [ranges…]   version-sync pass only: provider queries,
                                 transactional recipe rewrites left UNCOMMITTED
                                 (review with 'git diff', then commit), and the
                                 run-level disposition block (rule 18 anchoring)
  gsa -Su [targets…] [ranges…]   update: the -Sy pass, then build+install the
                                 stale set (recipes whose tracked version moved
                                 past their newest built instance)
Maintain verbs (contract §B.7; side-car self-healing only — never /usr or
  /var/lib/pacman):
  gsa -Ma                        audit report: legacy paths, package drift,
                                 stale runtime artifacts, recipe-contract
                                 lints (report-only; exit 0, read the report)
  gsa -Md [--fix]                doctor: runtime-state reconciliation report;
                                 --fix applies the named side-car repairs
  gsa -Mi [--prune|--backfill]   IgnorePkg closure of the target pacman.conf:
                                 default reports drift; --prune removes stale
                                 entries, --backfill adds missing ones
  gsa -Ml [--tail <ref>] [--keep N]   per-package log browse/tail; --keep N
                                 is the log-retention prune
  gsa -Mm                        shared-source mirrors: dedupe VCS clones into
                                 canonical mirrors (asks first: prints its
                                 targets and stops rc 3 without --noconfirm)
  gsa -Mc <targets…>             prune strength 1: src/pkg/build trees and
                                 archives of the selection
  gsa -Mcc                       prune strength 2: every built archive in the
                                 workspace plus its VCS-revision sidecar
                                 (symlinks are never deleted or followed)
  gsa -Mccc                      prune strength 3: additionally pulled sources
                                 (prints its target list and asks first)
  gsa -Ms [name…] [--add|--remove <ref…>]   named sets: list sets and members;
                                 user sets are managed in the kv store against
                                 config/sets/ (computed sets are not editable)
  gsa -Mw [--add|--remove <ref…>]   world: the explicitly wanted set
  gsa -Mh [--prune] [--show <run-id>]   run history: list recorded runs and
                                 their continuations; --show re-renders one;
                                 --prune enforces the bounded retention
Every other spelling answers with a 'deferred to a later phase' usage error (rc 2);
nothing is stubbed with fake results.

Selection targets (contract §C; exact lookup only — a typo is never auto-corrected):
  recipe id            mesa-git
  recipe path          packages/git/mesa-git
  case-variant id      Mesa-Git (matched and announced)
  pacman pkgname       zen-browser (split outputs included; announced)
  group / user set     @git, @core, @<set>
  index ranges         22..38, 22.., ..15 — 1-based over the -Sl listing of the
                       same selection; a bare range is a usage error
  standalone PKGBUILD  a PKGBUILD file path, a directory holding one, or a
                       URL of one: staged into its own one-node workspace
                       and built there — gsa + the recipe, no project clone
                       required (build/install/fetch/maintain runs and their
                       --dry-run plan; never mixed with workspace references,
                       and query/report verbs do not take them yet)
A selection expands to its transitive consumers (the reverse build-order
closure); --leaf suppresses the expansion and keeps exactly what you named.

Long modifiers (contract §B.8). A build run accepts: --dry-run, --leaf,
  --skip (skip-if-fresh resume: claim a complete verified-fresh archive set;
  waiver reasons freshness-waived / abi-provider-waived ride the record rows),
  --skip-built (claim anything already built — newest complete set at any
  version, no upstream probes; a recipe commit newer than the set rebuilds),
  --vcs-skip-tolerance N (the --skip waive threshold, positive integers only;
  beats GSA_VCS_SKIP_TOLERANCE), --no-sync (build the committed version and
  sums as-is: no provider query, no anchoring, no rewrite),
  --allow-broken-rustc (skip the rustc sanity probe — escape hatch for runs
  that compile no Rust, never a way past a real ABI mismatch),
  --fail-fast (stop dispatch on the first failure; cone-stop is the default),
  --lanes N|auto, --jobs N|auto, --intensity LEVEL, --state-dir PATH,
  --no-prefetch (opt out of the advisory fetch-ahead), --prefetch-ahead N
  (fetch-ahead window, default 8). --skip and --skip-built are different
  claims and cannot combine.
The side-car queries (-Qb/-Qp) accept --state-dir PATH — the state-root
  override (§J.3): --state-dir beats GSA_STATE_DIR beats the gsa.conf layers
  (/etc/gsa.conf and ~/.config/gsa/gsa.conf, user over system) beats
  /var/lib/gsa.
An install run (-S/-U) additionally accepts: --config PATH (the target
  pacman.conf), --no-register-ignorepkg (skip the dynamic IgnorePkg
  registration, loudly), and -- <pacman args…> (forwarded to every pacman -U).
A maintain run (-M) accepts its verb's sub-flags (§B.7): --fix, --prune,
  --backfill, --tail <ref>, --keep N, --show <run-id>, --add, --remove,
  --noconfirm (the engine's own confirmations — -Mm/-Mccc — never a pacman
  question), and (-Mi) --config PATH; --dry-run renders a mutating verb's
  plan and rows without touching anything.
Deferred (parse and refuse, so the message names them): --quiet, --verbose.

Engine environment inputs: GSA_CONF, GSA_STATE_DIR, GSA_BUILD_DIR, GSA_LANES,
  GSA_JOBS, GSA_INTENSITY, GSA_CPU_THREADS, GSA_MEMORY_GIB, GSA_TARGET_CPU,
  GSA_VCS_SKIP_TOLERANCE. GSA_CONF replaces the auto-read gsa.conf layers
  (/etc/gsa.conf, ~/.config/gsa/gsa.conf) with exactly one file — fixture and
  hermetic control. GSA_BUILD_DIR redirects the build cache (makepkg
  BUILDDIR/PKGDIR/PKGDEST; default: the build user's ~/.cache/gsa).
  GSA_BUILD_JOBS is engine output, never an input.

Exit codes (contract §G): 0 success; 1 build failure under --fail-fast;
  2 usage error (bad flags, unknown reference with nearest candidates, invalid
  range, empty selection, malformed config record, deferred spelling);
  3 refusal (the run refused to start or aborted at a fail-closed gate);
  4 cone-stop run with >=1 failure (the parked cone is in the run record);
  5 deferral-only (>=1 deferred/parked row, no failure); 130 interrupted —
  the full run record (plan, outcomes, continuation) is emitted first.
"
    .to_string()
}

/// The recipe workspace of a run (plan-gsa-isolation.md W3). Resolution:
/// 1. `project` from the gsa.conf layers (dev/deployment override);
/// 2. the cwd walk — deprecated (fixtures and dev checkouts still use it;
///    a TTY run notes the deprecation, pipes stay byte-stable);
/// 3. the canonical store `<state-dir>/recipes` (gsa-owned, fetched by
///    `gsa -Sy` or — for mutating runs — on demand).
/// `fetch` enables that on-demand store fetch; read paths pass `false`.
fn find_root() -> Option<PathBuf> {
    resolve_root(false).ok()
}

pub(crate) fn resolve_root(fetch: bool) -> Result<PathBuf, String> {
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
    let state = gsa_model::config::resolve_state_dir(None)?;
    let store = gsa_state::recipes::store_dir(&state);
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
    Err("cannot find a recipe workspace: set `project` in gsa.conf, run inside the recipe repository, or fetch the store with `sudo gsa -Sy`".to_string())
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
        None => resolve_root(true),
    }
}

fn classify(inv: &Invocation) -> Disposition {
    // The build-run modifiers (§B.8) are real on the runs that build or
    // install and still deferred on every other spelling; everything else
    // deferred stays deferred everywhere.
    let is_build_run = inv.family == Family::B && inv.action.is_none() && !inv.dry_run;
    let is_install_run = inv.family == Family::S && inv.action.is_none() && !inv.dry_run;
    let is_upgrade_run = inv.family == Family::U;
    // `-Su` (§B.4): `-Sy`, then build+install the stale set — a build run
    // plus the five §B.8 sync/freshness/toolchain modifiers.
    let is_update_run = inv.family == Family::S && inv.action == Some('u');
    // `-Sy` (§B.4): the version-sync pass only; it takes no build modifiers.
    let is_sync_pass = inv.family == Family::S && inv.action == Some('y');
    // The side-car queries (§B.3 `-Qb`/`-Qp`) read the state root, so they
    // take `--state-dir` like every other state-root surface (§J.3).
    let is_side_car_query = inv.family == Family::Q
        && matches!(inv.action, Some('b') | Some('p') | Some('a') | Some('r'));
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
    } else if is_sync_pass {
        Vec::new()
    } else if is_side_car_query {
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
    let action = inv.action;
    let command = match (inv.family, action) {
        (Family::Q, None) => Command::QueryList,
        (Family::Q, Some('i')) => Command::QueryInfo,
        (Family::Q, Some('s')) => Command::QuerySearch,
        (Family::Q, Some('b')) => Command::QueryBinpkg,
        (Family::Q, Some('p')) => Command::QueryProbe,
        (Family::Q, Some('a')) => Command::QueryAbi,
        (Family::Q, Some('r')) => Command::QueryRevdep,
        (Family::Q, Some('t')) => Command::Topology,
        (Family::S, None) if inv.dry_run => Command::Plan,
        (Family::S, Some('l')) => Command::List,
        (Family::S, Some('i')) => Command::RecipeInfo,
        (Family::S, Some('s')) => Command::UniverseSearch,
        (Family::S, Some('g')) => Command::Groups,
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
        | Command::RecipeInfo
        | Command::UniverseSearch
        | Command::Groups
        | Command::QueryList
        | Command::QueryInfo
        | Command::QuerySearch
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

pub(crate) fn resolve_intensity(project: &gsa_topo::ProjectConfig) -> Result<String, String> {
    match std::env::var("GSA_INTENSITY") {
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

fn write_notes(err: &mut dyn Write, notes: &[String]) {
    for note in notes {
        let _ = writeln!(err, "gsa: note: {note}");
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
    let root = match &inv.standalone_root {
        // A standalone-target run staged its own workspace (plan W4); the
        // report verbs' own discovery never fetches (read-only, §B.10).
        Some(root) => root.clone(),
        None => find_root().ok_or_else(|| {
            cmd_error(
                "cannot find config/topology.conf from the current directory upward (run inside the recipe repository)",
            )
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
        };
        let _ = write!(out, "{}", render::render_topology_channel(&ctx));
        return Ok(RC_OK);
    }

    let db = RecipeDb::load(&root, graph.records()).map_err(|e| cmd_error(e.to_string()))?;
    let ctx = Ctx {
        project: &project,
        graph: &graph,
        db: &db,
    };

    match command {
        Command::Topology
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
        Command::RecipeInfo => {
            no_ranges(inv)?;
            require_refs(inv, "at least one reference")?;
            let indices = resolve_records(&ctx, &inv.targets, err)?;
            if indices.is_empty() {
                return Err(cmd_error("no recipes resolved".to_string()));
            }
            for (n, &idx) in indices.iter().enumerate() {
                if n > 0 {
                    let _ = writeln!(out);
                }
                let _ = write!(
                    out,
                    "{}",
                    render::render_recipe_info(&ctx, ctx.graph.record(idx))
                );
            }
        }
        Command::UniverseSearch => {
            no_ranges(inv)?;
            require_refs(inv, "at least one search pattern")?;
            let _ = write!(
                out,
                "{}",
                render::render_universe_search(&ctx, &inv.targets)
            );
        }
        Command::Groups => {
            no_ranges(inv)?;
            let text =
                render::render_groups(&ctx, &inv.targets).map_err(|e| cmd_error(e.to_string()))?;
            let _ = write!(out, "{text}");
        }
        Command::QueryList => {
            no_ranges(inv)?;
            let mut entries: Vec<(String, String)> = Vec::new();
            if inv.targets.is_empty() {
                for (name, meta) in db.pkgnames_sorted() {
                    let version = meta.full_version().map_err(|e| cmd_error(e.to_string()))?;
                    entries.push((name, version));
                }
            } else {
                let indices = resolve_records(&ctx, &inv.targets, err)?;
                let mut seen = std::collections::BTreeSet::new();
                for idx in indices {
                    let meta = db
                        .get(ctx.graph.record(idx).id.as_str())
                        .ok_or_else(|| cmd_error("recipe metadata missing".to_string()))?;
                    let version = meta.full_version().map_err(|e| cmd_error(e.to_string()))?;
                    for name in meta.pkgnames() {
                        if seen.insert(name.clone()) {
                            entries.push((name, version.clone()));
                        }
                    }
                }
                entries.sort_by(|a, b| a.0.cmp(&b.0));
            }
            let _ = write!(out, "{}", render::render_query_list(&entries));
        }
        Command::QueryInfo => {
            no_ranges(inv)?;
            require_refs(inv, "at least one reference")?;
            let indices = resolve_records(&ctx, &inv.targets, err)?;
            let mut first = true;
            for idx in indices {
                let record = ctx.graph.record(idx);
                let meta = db
                    .get(record.id.as_str())
                    .ok_or_else(|| cmd_error("recipe metadata missing".to_string()))?;
                let version = meta.full_version().map_err(|e| cmd_error(e.to_string()))?;
                for pkgname in meta.pkgnames() {
                    if !first {
                        let _ = writeln!(out);
                    }
                    first = false;
                    let _ = write!(
                        out,
                        "{}",
                        render::render_package_info(&ctx, record, &pkgname, &version)
                    );
                }
            }
        }
        Command::QuerySearch => {
            no_ranges(inv)?;
            require_refs(inv, "at least one search pattern")?;
            let _ = write!(out, "{}", render::render_query_search(&ctx, &inv.targets));
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

fn require_refs(inv: &Invocation, what: &str) -> Result<(), String> {
    if inv.targets.is_empty() {
        Err(cmd_error(format!("requires {what}")))
    } else {
        Ok(())
    }
}

/// Run one invocation against the current directory's repository. Returns
/// the process exit code and writes all output through `out`/`err`.
pub fn run(argv: &[String], out: &mut dyn Write, err: &mut dyn Write) -> i32 {
    match args::parse(argv) {
        Ok(Parsed::Help) => {
            let _ = write!(out, "{}", help_text());
            RC_OK
        }
        Ok(Parsed::Hidden(Hidden::LaneJob(args))) => {
            // The lane child entry (contract §D.1): one package, one result
            // file; its exit code IS its lane outcome code (§G.2).
            gsa_build::lane::run_lane_job(&args, err)
        }
        Ok(Parsed::Hidden(Hidden::FetchJob(args))) => {
            // The fetch child entry (contract §D.1): one recipe, one typed
            // result file; `failed` is data, not process failure (exit 0).
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
        for spelling in ["-Ql"] {
            let (code, _out, err) = run_capture(&[spelling]);
            assert_eq!(code, 2, "{spelling} must be deferred");
            assert!(
                err.contains("deferred to a later phase"),
                "{spelling}: {err}"
            );
        }
        // -Sy/-Su are LIVE (contract §B.4). Assert at the classifier — never
        // through `run`, which would execute a real version-sync pass against
        // whatever repository the test runs in.
        for spelling in ["-Sy", "-Su"] {
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
