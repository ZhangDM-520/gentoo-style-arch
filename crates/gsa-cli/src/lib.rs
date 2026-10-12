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
mod record;
mod render;
mod select;

use std::io::Write;
use std::path::PathBuf;

use args::{Family, Hidden, Invocation, Parsed};
use gsa_graph::Graph;
use gsa_recipe::RecipeDb;
use gsa_topo::load_project;
use select::Ctx;

const RC_OK: i32 = 0;
const RC_USAGE: i32 = 2;

/// What the engine can execute (contract §B; `-S`/`-U`/`-M` remain deferred
/// to their phases — Phase 2 adds real `-B` build runs).
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
    Plan,
    Build,
}

enum Disposition {
    Run(Command),
    Deferred(String),
    Bad(String),
}

pub fn help_text() -> String {
    "\
gsa — native build-and-install orchestrator for the curated recipe set
(contract docs/gsa-contract.md; Phase 2: build-only runs)

Usage: gsa <FAMILY>[cluster] [long-modifiers] [targets…] [ranges…] [-- <pacman args…>]

Families (exactly one per invocation; lowercase letters form the cluster):
  -Q   query the buildable universe (and, later, pacman's installed database)
  -S   build + install the selection (each package installed before its consumers compile)
  -B   build-only: archives beside the recipes, nothing installed
  -U   install from archives (deferred)
  -M   maintain engine state (deferred)
  gsa fetch is exactly gsa -Sw (deferred)

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
  gsa -B <targets…> [ranges…]    build the selection to archives beside the recipes
                                 (Phase 2; nothing is installed, no pacman call)
  gsa -S --dry-run <targets…> [ranges…]    build-order plan without building
  gsa -B --dry-run <targets…> [ranges…]    the same plan shape for build-only
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
A selection expands to its transitive consumers (the reverse build-order
closure); --leaf suppresses the expansion and keeps exactly what you named.

Long modifiers (contract §B.8). A build run accepts: --dry-run, --leaf,
  --fail-fast (stop dispatch on the first failure; cone-stop is the default),
  --lanes N|auto, --jobs N|auto, --intensity LEVEL, --state-dir PATH.
Deferred (parse and refuse, so the message names them): --skip, --skip-built,
  --vcs-skip-tolerance N, --no-sync, --allow-broken-rustc, --no-register-ignorepkg,
  --config PATH, --noconfirm, --quiet, --verbose, -- <pacman args…>.

Engine environment inputs: GSA_STATE_DIR, GSA_LANES, GSA_JOBS, GSA_INTENSITY,
  GSA_CPU_THREADS, GSA_MEMORY_GIB, GSA_TARGET_CPU, GSA_VCS_SKIP_TOLERANCE.
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

/// Find the recipe repository: walk up from the current directory until
/// `config/topology.conf` is found (the strict loader's home).
fn find_root() -> Option<PathBuf> {
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

fn classify(inv: &Invocation) -> Disposition {
    // The five build-run modifiers (§B.8) are real on a `-B` build and
    // still deferred on every other spelling; everything else deferred
    // stays deferred everywhere.
    let is_build_run = inv.family == Family::B && inv.action.is_none() && !inv.dry_run;
    if let Some(flag) = inv
        .deferred_flags
        .iter()
        .find(|f| !(is_build_run && build::REAL_BUILD_FLAGS.contains(&f.as_str())))
    {
        return Disposition::Deferred(format!(
            "{flag} (a later phase owns it; a build run accepts --fail-fast, --lanes, --jobs, --intensity, --state-dir)"
        ));
    }
    if inv.pacman_args.is_some() {
        return Disposition::Deferred(
            "-- <pacman args> (forwarded to a pacman -U transaction — the install phase)"
                .to_string(),
        );
    }
    let action = inv.action;
    let command = match (inv.family, action) {
        (Family::Q, None) => Command::QueryList,
        (Family::Q, Some('i')) => Command::QueryInfo,
        (Family::Q, Some('s')) => Command::QuerySearch,
        (Family::Q, Some('t')) => Command::Topology,
        (Family::S, None) if inv.dry_run => Command::Plan,
        (Family::S, Some('l')) => Command::List,
        (Family::S, Some('i')) => Command::RecipeInfo,
        (Family::S, Some('s')) => Command::UniverseSearch,
        (Family::S, Some('g')) => Command::Groups,
        (Family::B, None) if inv.dry_run => Command::Plan,
        (Family::B, None) => Command::Build,
        (Family::B, Some('l')) => Command::List,
        (Family::S, None) => return Disposition::Deferred(
            "gsa -S without --dry-run (install-before-dependents arrives with the install phase)"
                .to_string(),
        ),
        (Family::S, Some('w')) => {
            return Disposition::Deferred("gsa -Sw fetch-only (Phase 4)".to_string())
        }
        (Family::S, Some('y')) => {
            return Disposition::Deferred("gsa -Sy version-sync pass (later phase)".to_string())
        }
        (Family::S, Some('u')) => {
            return Disposition::Deferred("gsa -Su update (Phase 4)".to_string())
        }
        _ => {
            return Disposition::Deferred(format!(
                "{} (later phase; the build-only family -B is what Phase 2 executes)",
                inv.spelling()
            ))
        }
    };
    if inv.dry_run && command != Command::Plan {
        return Disposition::Bad(
            "--dry-run applies to build actions (-S/-B); queries are already read-only".to_string(),
        );
    }
    if inv.leaf && !matches!(command, Command::List | Command::Plan | Command::Build) {
        return Disposition::Bad(
            "--leaf applies to selections (-S/-B builds and their listings)".to_string(),
        );
    }
    Disposition::Run(command)
}

fn resolve_intensity(project: &gsa_topo::ProjectConfig) -> Result<String, String> {
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
) -> Result<(), String> {
    let root = find_root().ok_or_else(|| {
        cmd_error(
            "cannot find config/topology.conf from the current directory upward (run inside the recipe repository)",
        )
    })?;
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
        return Ok(());
    }

    let db = RecipeDb::load(&root, graph.records()).map_err(|e| cmd_error(e.to_string()))?;
    let ctx = Ctx {
        project: &project,
        graph: &graph,
        db: &db,
    };

    match command {
        Command::Topology | Command::Build => unreachable!(),
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
        Command::Plan => {
            if inv.targets.is_empty() {
                return Err(cmd_error(
                    "selection is mandatory: a build never starts without a selection".to_string(),
                ));
            }
            let selection = select::build_selection(&ctx, &inv.targets, &inv.ranges, inv.leaf)
                .map_err(|e| cmd_error(e.to_string()))?;
            write_notes(err, &selection.notes);
            let intensity = resolve_intensity(&project).map_err(cmd_error)?;
            let expansion_added = selection.closure_size.saturating_sub(selection.seeds.len());
            let _ = write!(
                out,
                "{}",
                render::render_plan_prose(
                    &selection.listed,
                    expansion_added,
                    selection.closure_size,
                    inv.leaf,
                    true,
                )
            );
            let rec =
                record::build_plan_record(inv, &selection, &inv.targets, &inv.ranges, &intensity);
            let _ = write!(out, "{}", rec.render_machine());
        }
    }
    Ok(())
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
        Ok(Parsed::Hidden(Hidden::StaleLockCheck)) => {
            // The production pacman-lock probe without a run (§D.1).
            gsa_sched::lock::pacman_lock_probe(out, err)
        }
        Ok(Parsed::Hidden(hidden)) => {
            let _ = writeln!(
                err,
                "gsa: deferred to a later phase: {} (fixture seam of a later phase)",
                hidden.spelling()
            );
            RC_USAGE
        }
        Ok(Parsed::Invoke(inv)) => match classify(&inv) {
            Disposition::Deferred(why) => {
                let _ = writeln!(err, "gsa: deferred to a later phase: {why}");
                RC_USAGE
            }
            Disposition::Bad(message) => {
                let _ = writeln!(err, "gsa: {message}");
                RC_USAGE
            }
            Disposition::Run(Command::Build) => build::run_build(&inv, out, err),
            Disposition::Run(command) => match execute(&inv, command, out, err) {
                Ok(()) => RC_OK,
                Err(message) => {
                    let _ = writeln!(err, "gsa: {message}");
                    RC_USAGE
                }
            },
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
        for spelling in [
            "-Ql", "-Qr", "-Qb", "-Sw", "-Sy", "-Su", "-U", "-Ua", "-Ma", "-Mcc", "-S",
        ] {
            let (code, _out, err) = run_capture(&[spelling]);
            assert_eq!(code, 2, "{spelling} must be deferred");
            assert!(
                err.contains("deferred to a later phase"),
                "{spelling}: {err}"
            );
        }
        // Build-run modifiers stay deferred outside a real build.
        let (code, _out, err) = run_capture(&["-Sl", "--lanes", "2"]);
        assert_eq!(code, 2);
        assert!(err.contains("deferred to a later phase"), "{err}");
        // The not-yet-real hidden seams defer; --lane-job/--stale-lock-check
        // are live seams and are exercised by tests/gsa-sched-v2.sh.
        for seam in ["--fetch-job", "--local-db-check", "--qa-check"] {
            let (code, _out, err) = run_capture(&[seam]);
            assert_eq!(code, 2, "{seam} must be deferred");
            assert!(err.contains("deferred to a later phase"), "{seam}: {err}");
        }
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
        ] {
            assert!(out.contains(flag), "--help must name {flag}");
        }
        for seam in ["--lane-job", "--stale-lock-check", "--install-decide"] {
            assert!(!out.contains(seam), "--help must hide {seam}");
        }
        let (code, _out, err) = run_capture(&[]);
        assert_eq!(code, 2);
        assert!(err.contains("Usage: gsa"));
    }
}
