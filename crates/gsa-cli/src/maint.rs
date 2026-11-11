//! The `-M` maintain surface wiring (contract §B.7): the verb a cluster
//! spells, the per-verb flag acceptance (§B.8 + §B.7 sub-flags), and the
//! two gates every mutating verb passes — the run lock (`run-in-flight`
//! refusal while another engine run holds the state root, §K.3) and the
//! confirmation gate (`confirmation-required` for `-Mm`/`-Mccc` without
//! `--noconfirm`; the engine never prompts, §K.3). The verbs themselves and
//! their rows live in `gsa-maint`; this module resolves selections and
//! references through the ordinary §C.1 layer and maps rows to §G.1 rc.

use std::io::Write;
use std::path::PathBuf;

use gsa_maint::{MaintCtx, Row, RC_OK, RC_REFUSAL};
use gsa_recipe::RecipeDb;
use gsa_state::StateRoot;
use gsa_topo::load_project;

use crate::args::Invocation;
use crate::exit::{self, Exit};
use crate::install::DEFAULT_CONF;
use crate::select::{self, Ctx};
use crate::style;
use crate::{cmd_error, write_notes};

/// The verb one `-M` cluster spells (§B.7). The `c` action carries its
/// prune strength (1/2/3 from `c`/`cc`/`ccc`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MaintVerb {
    Audit,
    Doctor,
    IgnorePkg,
    Logs,
    Mirrors,
    Prune(u8),
    Sets,
    World,
    History,
}

/// The cluster → verb mapping. A bare `-M` is a usage error: §B.7 defines
/// no default action for the family.
pub fn verb_of(inv: &Invocation) -> Result<MaintVerb, String> {
    let strength = 1 + inv.modifiers.iter().filter(|m| **m == 'c').count() as u8;
    verb_from_letter(inv.action, strength)
}

/// The letters a `-M` cluster can carry, in the §B.7 roster order.
pub const VERB_LETTERS: [char; 9] = ['a', 'd', 'i', 'l', 'm', 'c', 's', 'w', 'h'];

/// [`verb_of`] from its letter alone (the flag-ownership answer needs to ask
/// every sibling which flags it accepts).
pub fn verb_from_letter(action: Option<char>, prune_strength: u8) -> Result<MaintVerb, String> {
    match action {
        Some('a') => Ok(MaintVerb::Audit),
        Some('d') => Ok(MaintVerb::Doctor),
        Some('i') => Ok(MaintVerb::IgnorePkg),
        Some('l') => Ok(MaintVerb::Logs),
        Some('m') => Ok(MaintVerb::Mirrors),
        Some('c') => Ok(MaintVerb::Prune(prune_strength.max(1))),
        Some('s') => Ok(MaintVerb::Sets),
        Some('w') => Ok(MaintVerb::World),
        Some('h') => Ok(MaintVerb::History),
        None => Err(
            "-M has no default action (letters: a d i l m c s w h — 'gsa --help' lists them)"
                .to_string(),
        ),
        Some(other) => Err(format!("unknown -M action letter '{other}'")),
    }
}

/// The long modifiers one verb accepts (§B.8's global roster minus the
/// build-run flags, plus §B.7's sub-flags). Everything else keeps the
/// classifier's deferred refusal.
pub fn accepted_flags(verb: MaintVerb) -> Vec<&'static str> {
    let mut flags = vec!["--state-dir"];
    match verb {
        MaintVerb::Audit => {}
        MaintVerb::Doctor => flags.push("--fix"),
        MaintVerb::IgnorePkg => flags.extend(["--prune", "--backfill", "--config"]),
        MaintVerb::Logs => flags.extend(["--tail", "--keep"]),
        MaintVerb::Mirrors => flags.push("--noconfirm"),
        MaintVerb::Prune(strength) => {
            if strength >= 3 {
                flags.push("--noconfirm");
            }
        }
        MaintVerb::Sets | MaintVerb::World => flags.extend(["--add", "--remove"]),
        MaintVerb::History => flags.extend(["--prune", "--show"]),
    }
    flags
}

fn has_flag(inv: &Invocation, name: &str) -> bool {
    inv.deferred_flags.iter().any(|f| f == name)
}

/// Run one `-M` invocation. rc is §G.1's: 0 reported/applied, 2 usage,
/// 3 refusal (confirmation, run-in-flight, failed write).
/// The privilege class of one `-M` invocation (contract §B.10): report forms
/// are reads, each mutation flag upgrades the verb to root, and `-Mm` alone
/// stays build-user-only (it rewrites the user's source-mirror tree).
pub(crate) fn privilege(inv: &Invocation) -> super::Privilege {
    use super::Privilege::*;
    if inv.dry_run {
        return ReadOnly;
    }
    let Ok(verb) = verb_of(inv) else {
        // The cluster error is what the user reads (§B.7); no privilege
        // opinion is needed.
        return ReadOnly;
    };
    let mutates = has_flag(inv, "--fix")
        || has_flag(inv, "--prune")
        || has_flag(inv, "--backfill")
        || has_flag(inv, "--add")
        || has_flag(inv, "--remove")
        || inv.keep.is_some();
    match verb {
        MaintVerb::Audit => ReadOnly,
        MaintVerb::Mirrors => BuildUserOnly,
        MaintVerb::Prune(_) => Root {
            needs_build_user: false,
        },
        MaintVerb::Doctor
        | MaintVerb::IgnorePkg
        | MaintVerb::Logs
        | MaintVerb::History
        | MaintVerb::Sets
        | MaintVerb::World => {
            if mutates {
                Root {
                    needs_build_user: false,
                }
            } else {
                ReadOnly
            }
        }
    }
}

pub fn run(inv: &Invocation, out: &mut dyn Write, err: &mut dyn Write) -> i32 {
    exit::render(run_inner(inv, out, err), err)
}

/// `Ok(code)` carries the §G.1 outcome rc the verb computed (0/1/3);
/// `Err(exit)` is a usage-class gate the ONE renderer maps.
fn run_inner(inv: &Invocation, out: &mut dyn Write, err: &mut dyn Write) -> Result<i32, Exit> {
    let verb = verb_of(inv).map_err(Exit::Usage)?;

    // Per-verb usage fences (§B.7's shapes).
    match verb {
        MaintVerb::Audit | MaintVerb::Mirrors if !inv.targets.is_empty() => {
            return Err(Exit::Usage(format!("{} takes no targets", inv.spelling())));
        }
        MaintVerb::Doctor | MaintVerb::IgnorePkg | MaintVerb::History
            if !inv.targets.is_empty() =>
        {
            return Err(Exit::Usage(format!(
                "{} takes no targets (its arguments are flags: --fix / --prune --backfill / --show)",
                inv.spelling()
            )));
        }
        MaintVerb::Logs if !inv.targets.is_empty() => {
            return Err(Exit::Usage(
                "-Ml takes no targets (browse with --tail <ref>, prune with --keep N)".to_string(),
            ));
        }
        MaintVerb::Prune(2) | MaintVerb::Prune(3) if !inv.targets.is_empty() => {
            return Err(Exit::Usage(format!(
                "{} takes no targets (it is a workspace-wide wipe)",
                inv.spelling()
            )));
        }
        _ => {}
    }
    if !inv.ranges.is_empty() && !matches!(verb, MaintVerb::Prune(1)) {
        return Err(Exit::Usage(
            "index ranges address an -S/-B selection (see 'gsa -Sl')".to_string(),
        ));
    }
    if inv.leaf && !matches!(verb, MaintVerb::Prune(1)) {
        return Err(Exit::Usage(
            "--leaf applies to -Mc's pruning selection".to_string(),
        ));
    }
    if has_flag(inv, "--add") && has_flag(inv, "--remove") {
        return Err(Exit::Usage(
            "--add and --remove are alternatives (one per invocation)".to_string(),
        ));
    }
    if has_flag(inv, "--prune") && has_flag(inv, "--backfill") {
        return Err(Exit::Usage(
            "-Mi takes ONE of --prune / --backfill".to_string(),
        ));
    }

    // A REPORT-ONLY maintain verb never fetches the recipe store: `gsa -Sy`
    // is the one refresh, and a first-run `-Ma` used to clone the whole
    // repository from the network and then die on the unwritable
    // `recipes.last-fetch` stamp — a permission failure wearing a usage
    // error's rc (2026-11-11 blind review). Read-only resolution answers the
    // same guidance `-Sl` does when no workspace exists.
    let read_only = matches!(privilege(inv), super::Privilege::ReadOnly);
    let root = if read_only {
        crate::resolve_root(false, inv.state_dir.as_deref())
            .map_err(|e| Exit::Usage(e.message()))?
    } else {
        crate::resolve_workspace(inv, err)?
    };
    let project = load_project(&root).map_err(|error| Exit::Usage(cmd_error(error.to_string())))?;
    let graph = gsa_graph::Graph::build(&project.topology.records)
        .map_err(|error| Exit::Usage(format!("config/topology.conf: {error}")))?;
    let db = RecipeDb::load(&root, graph.records())
        .map_err(|error| Exit::Usage(cmd_error(error.to_string())))?;
    // ── privilege gate (contract §B.10; after every usage preflight and
    //    before the first state access) ──────────────────────────────────
    if let Some(exit) = crate::privilege_gate(&inv.spelling(), privilege(inv), true, err) {
        return Err(exit);
    }

    let state_dir = gsa_state::resolve_state_root(inv.state_dir.as_deref()).map_err(Exit::Usage)?;
    let state = match StateRoot::open(&state_dir) {
        Ok(state) => state,
        Err(error) => {
            let _ = writeln!(err, "gsa: {error}");
            return Ok(RC_REFUSAL);
        }
    };
    let ctx = MaintCtx {
        root: &root,
        project: &project,
        graph: &graph,
        db: &db,
        state: &state,
    };
    let sel_ctx = Ctx {
        project: &project,
        graph: &graph,
        db: &db,
        user_sets: select::load_user_sets(inv),
    };

    let mut rows: Vec<Row> = Vec::new();
    let rc = RC_OK;
    match verb {
        MaintVerb::Audit => rows.extend(gsa_maint::audit::report(&ctx)),
        MaintVerb::Doctor => {
            if has_flag(inv, "--fix") {
                let result = mutating_rows(&state_dir, inv, out, err, "doctor", |apply| {
                    gsa_maint::doctor::fix(&ctx, apply).map(|outcome| {
                        let rc = if outcome.failed > 0 {
                            RC_REFUSAL
                        } else {
                            RC_OK
                        };
                        let mut rows = outcome.rows;
                        // A repair pass that repaired nothing must SAY so:
                        // an empty capture read as "did it even run?"
                        // (2026-11-11 blind review).
                        if rows.is_empty() {
                            rows.push(Row::new("doctor", "clean", "nothing to repair"));
                        }
                        (rows, rc)
                    })
                });
                return Ok(finish(result, out, err, "-Md --fix"));
            }
            rows.extend(gsa_maint::doctor::report(&ctx));
        }
        MaintVerb::IgnorePkg => {
            let conf = PathBuf::from(inv.config.as_deref().unwrap_or(DEFAULT_CONF));
            let result = if has_flag(inv, "--backfill") {
                mutating_rows(&state_dir, inv, out, err, "ignorepkg", |apply| {
                    gsa_maint::ignorepkg::backfill(&ctx, &conf, apply).map(|rows| (rows, RC_OK))
                })
            } else if has_flag(inv, "--prune") {
                mutating_rows(&state_dir, inv, out, err, "ignorepkg", |apply| {
                    gsa_maint::ignorepkg::prune(&ctx, &conf, apply).map(|rows| (rows, RC_OK))
                })
            } else {
                gsa_maint::ignorepkg::report(&ctx, &conf).map(|rows| (rows, RC_OK))
            };
            return Ok(finish(result, out, err, "-Mi"));
        }
        MaintVerb::Logs => {
            if let Some(spec) = &inv.tail {
                // The log listing is GLOBAL (one `logs/` tree per state root)
                // while a workspace ref resolves over the CURRENT topology:
                // a log the listing showed must stay tail-able, including one
                // a sibling workspace built (2026-11-11 blind review). A bare
                // name with no separator indexes `logs/<name>.log` directly;
                // anything path-shaped still goes through ref resolution.
                let direct = !spec.is_empty()
                    && !spec.contains('/')
                    && !spec.contains('\\')
                    && spec != ".."
                    && spec != ".";
                let id = match resolve_one(&sel_ctx, spec, err) {
                    Ok(id) => id,
                    Err(exit) => {
                        if direct
                            && state
                                .path()
                                .join("logs")
                                .join(format!("{spec}.log"))
                                .is_file()
                        {
                            spec.clone()
                        } else {
                            return Err(exit);
                        }
                    }
                };
                let path = state.path().join("logs").join(format!("{id}.log"));
                if path.is_file() {
                    rows.push(Row::new(
                        &id,
                        "log",
                        format!("{} bytes {}", file_size(&path), path.display()),
                    ));
                    match gsa_maint::hygiene::tail_lines(&path) {
                        // ONE ROW PER LOG LINE: a tail exists to be read, and
                        // folding the whole file into one `⏎`-separated row
                        // made the verb the tool points at on failure
                        // unreadable (2026-11-11 blind review).
                        Ok(text) => {
                            let mut any = false;
                            for line in text.lines() {
                                any = true;
                                rows.push(Row::new(&id, "tail", line.to_string()));
                            }
                            if !any {
                                rows.push(Row::new(&id, "tail", "(empty log)"));
                            }
                        }
                        Err(message) => rows.push(Row::new(&id, "failed", message)),
                    }
                } else {
                    rows.push(Row::new(&id, "log-missing", path.display().to_string()));
                }
            }
            if let Some(spec) = &inv.keep {
                let keep: usize = match spec.parse() {
                    Ok(keep) => keep,
                    Err(_) => {
                        return Err(Exit::Usage(format!("--keep wants a number (got '{spec}')")));
                    }
                };
                match mutating_rows(&state_dir, inv, out, err, "logs", |apply| {
                    Ok((
                        gsa_maint::hygiene::prune_logs(state.path(), keep, apply),
                        RC_OK,
                    ))
                }) {
                    Ok((prune_rows, prune_rc)) => {
                        rows.extend(prune_rows);
                        if prune_rc != RC_OK {
                            let _ = write!(out, "{}", render_rows(&rows));
                            return Ok(prune_rc);
                        }
                    }
                    Err(message) => {
                        if !message.is_empty() {
                            let _ = writeln!(err, "gsa: -Ml --keep: {message}");
                        }
                        return Ok(RC_REFUSAL);
                    }
                }
            } else if inv.tail.is_none() {
                for entry in gsa_maint::hygiene::log_entries(state.path()) {
                    rows.push(Row::new(
                        entry.pkg,
                        "log",
                        format!(
                            "{} bytes {} {}",
                            entry.size,
                            entry
                                .mtime
                                .duration_since(std::time::UNIX_EPOCH)
                                .map(|d| d.as_secs())
                                .unwrap_or(0),
                            entry.path.display()
                        ),
                    ));
                }
                if rows.is_empty() {
                    rows.push(Row::new(
                        "logs",
                        "empty",
                        "no build logs under the state root",
                    ));
                }
            }
        }
        MaintVerb::Mirrors => {
            let confirming = !inv.dry_run && !has_flag(inv, "--noconfirm");
            if confirming {
                let plan = match gsa_maint::mirrors::run(&ctx, false) {
                    Ok(plan) => plan,
                    Err(message) => {
                        let _ = writeln!(err, "gsa: -Mm: {message}");
                        return Ok(RC_REFUSAL);
                    }
                };
                let _ = write!(out, "{}", render_rows(&plan));
                // Nothing to apply is a SUCCESS, not a confirmation: a
                // healthy tree printed `mirrors clean …` and then demanded
                // --noconfirm at rc 3, so `gsa -Mm` failed on exactly the
                // trees a script runs it on (2026-11-11 blind review). Only
                // a plan with pending work asks for consent.
                if !plan.iter().any(|row| row.action != "clean") {
                    return Ok(RC_OK);
                }
                let _ = writeln!(err, "gsa: -Mm {}", gsa_maint::CONFIRMATION_REQUIRED);
                return Ok(RC_REFUSAL);
            }
            let apply = !inv.dry_run;
            let _lock = if apply {
                match hold_lock(&state_dir, err, "mirrors") {
                    Ok(lock) => Some(lock),
                    Err(rc) => return Ok(rc),
                }
            } else {
                None
            };
            match gsa_maint::mirrors::run(&ctx, apply) {
                Ok(plan) => rows.extend(plan),
                Err(message) => {
                    let _ = writeln!(err, "gsa: -Mm: {message}");
                    return Ok(RC_REFUSAL);
                }
            }
        }
        MaintVerb::Prune(strength) => {
            let recipes: Vec<String> = if strength == 1 {
                if inv.targets.is_empty() {
                    return Err(Exit::Usage(
                        "-Mc requires a selection (targets or @set)".to_string(),
                    ));
                }
                let selection =
                    select::build_selection(&sel_ctx, &inv.targets, &inv.ranges, inv.leaf)
                        .map_err(|error| Exit::Usage(cmd_error(error.to_string())))?;
                write_notes(err, &selection.notes);
                selection
                    .listed
                    .iter()
                    .map(|(_, id)| id.as_str().to_string())
                    .collect()
            } else {
                Vec::new()
            };
            let run_strength = |apply: bool| -> Result<(Vec<Row>, i32), String> {
                let rows = match strength {
                    1 => gsa_maint::prune::strength1(&ctx, &recipes, apply),
                    2 => gsa_maint::prune::strength2(&ctx, apply),
                    _ => gsa_maint::prune::strength3(&ctx, apply),
                };
                // A strength that aborted on a state read emits a named
                // `failed` row (e.g. an unreadable binpkg index) and mutates
                // nothing: the rc must carry that refusal, or the row is the
                // only place the damage is visible.
                let rc = if rows.iter().any(|row| row.action == "failed") {
                    RC_REFUSAL
                } else {
                    RC_OK
                };
                Ok((rows, rc))
            };
            // -Mccc prints its target list and stops rc 3 (§B.7): without
            // --noconfirm the PLAN is printed and the run stops — the
            // engine never prompts (§K.3), nothing is deleted.
            let confirming = strength >= 3 && !inv.dry_run && !has_flag(inv, "--noconfirm");
            if confirming {
                match run_strength(false) {
                    Ok((plan_rows, _)) => {
                        let _ = write!(out, "{}", render_rows(&plan_rows));
                    }
                    Err(message) => {
                        let _ = writeln!(err, "gsa: {}: {message}", inv.spelling());
                        return Ok(RC_REFUSAL);
                    }
                }
                let _ = writeln!(err, "gsa: -Mccc {}", gsa_maint::CONFIRMATION_REQUIRED);
                return Ok(RC_REFUSAL);
            }
            let result = mutating_rows(&state_dir, inv, out, err, "prune", run_strength);
            return Ok(finish(result, out, err, inv.spelling().as_str()));
        }
        MaintVerb::Sets => {
            let add = has_flag(inv, "--add");
            let remove = has_flag(inv, "--remove");
            if add || remove {
                // --add/--remove need exactly one set name and ≥1 ref.
                let (name, refs) = match inv.targets.split_first() {
                    Some((name, refs)) => (name.clone(), refs),
                    None => {
                        return Err(Exit::Usage(
                            "-Ms --add/--remove wants one set name and its references".to_string(),
                        ));
                    }
                };
                // A name that is not an editable user set (computed set or
                // bad id class) is a USAGE error (§G.1), before any kv work;
                // what remains after this gate are write failures (rc 3).
                gsa_maint::sets::user_set_name(&name).map_err(Exit::Usage)?;
                let mut ids = Vec::new();
                for spec in refs {
                    match resolve_one(&sel_ctx, spec, err) {
                        Ok(id) => ids.push(id),
                        Err(exit) => return Err(exit),
                    }
                }
                if ids.is_empty() {
                    return Err(Exit::Usage(
                        "-Ms --add/--remove wants at least one reference".to_string(),
                    ));
                }
                let result = mutating_rows(&state_dir, inv, out, err, "sets", |apply| {
                    gsa_maint::sets::edit_set(
                        &ctx,
                        &state,
                        &name,
                        if add { &ids } else { &[] },
                        if remove { &ids } else { &[] },
                        apply,
                    )
                    .map(|rows| (rows, RC_OK))
                });
                return Ok(finish(result, out, err, "-Ms"));
            }
            match gsa_maint::sets::set_rows(&ctx, &state, &inv.targets) {
                Ok(listed) => rows.extend(listed),
                Err(message) => return Err(Exit::Usage(message)),
            }
        }
        MaintVerb::World => {
            let add = has_flag(inv, "--add");
            let remove = has_flag(inv, "--remove");
            if add || remove {
                let mut ids = Vec::new();
                for spec in &inv.targets {
                    match resolve_one(&sel_ctx, spec, err) {
                        Ok(id) => ids.push(id),
                        Err(exit) => return Err(exit),
                    }
                }
                if ids.is_empty() {
                    return Err(Exit::Usage(
                        "-Mw --add/--remove wants at least one reference".to_string(),
                    ));
                }
                let result = mutating_rows(&state_dir, inv, out, err, "world", |apply| {
                    gsa_maint::sets::edit_world(
                        &ctx,
                        &state,
                        if add { &ids } else { &[] },
                        if remove { &ids } else { &[] },
                        apply,
                    )
                    .map(|rows| (rows, RC_OK))
                });
                return Ok(finish(result, out, err, "-Mw"));
            }
            match gsa_maint::sets::world_rows(&ctx, &state) {
                Ok(listed) => rows.extend(listed),
                Err(message) => return Err(Exit::Usage(message)),
            }
        }
        MaintVerb::History => {
            if let Some(spec) = &inv.show {
                let id: usize = match spec.parse() {
                    Ok(id) if id > 0 => id,
                    _ => {
                        return Err(Exit::Usage(
                            "--show wants a run id (1-based over the recorded history)".to_string(),
                        ));
                    }
                };
                match gsa_maint::history::show(&state, id) {
                    Ok(block) => {
                        let _ = write!(out, "{block}");
                    }
                    Err(message) => {
                        return Err(Exit::Usage(format!("-Mh --show: {message}")));
                    }
                }
            }
            if has_flag(inv, "--prune") {
                let result = mutating_rows(&state_dir, inv, out, err, "history", |apply| {
                    gsa_maint::history::prune(&state, apply).map(|rows| (rows, RC_OK))
                });
                return Ok(finish(result, out, err, "-Mh --prune"));
            }
            if inv.show.is_none() {
                match gsa_maint::history::list_rows_with_corrupt(&state) {
                    Ok((listed, corrupt)) => {
                        for line in &corrupt {
                            let _ = writeln!(err, "gsa: note: {}", line.render());
                        }
                        rows.extend(listed)
                    }
                    Err(message) => {
                        let _ = writeln!(err, "gsa: -Mh: {message}");
                        return Ok(RC_REFUSAL);
                    }
                }
                if rows.is_empty() {
                    rows.push(Row::new("runs", "empty", "no recorded runs"));
                }
            }
        }
    }
    let _ = write!(out, "{}", render_rows(&rows));
    Ok(rc)
}

/// Resolve one §C.1 reference to its recipe id (typo = usage error with
/// nearest candidates, from the ordinary selection layer).
fn resolve_one(ctx: &Ctx<'_>, spec: &str, err: &mut dyn Write) -> Result<String, Exit> {
    let (found, notes) =
        select::resolve_ref(ctx, spec, 0).map_err(|e| Exit::Usage(cmd_error(e.to_string())))?;
    write_notes(err, &notes);
    match found.first() {
        Some(&idx) => Ok(ctx.graph.record(idx).id.as_str().to_string()),
        None => Err(Exit::Usage("selection resolved to no packages".to_string())),
    }
}

fn file_size(path: &std::path::Path) -> u64 {
    std::fs::metadata(path).map(|m| m.len()).unwrap_or(0)
}

fn hold_lock(
    state_dir: &std::path::Path,
    err: &mut dyn Write,
    what: &str,
) -> Result<gsa_sched::lock::RunLock, i32> {
    match gsa_maint::hold_run_lock(state_dir) {
        Ok(lock) => Ok(lock),
        Err(message) => {
            let _ = writeln!(err, "gsa: -M {what}: {message}");
            Err(RC_REFUSAL)
        }
    }
}

/// Run one mutating verb under the gates: dry-run → plan only; otherwise
/// hold the run lock and apply. The closure receives `apply`.
fn mutating_rows(
    state_dir: &std::path::Path,
    inv: &Invocation,
    _out: &mut dyn Write,
    err: &mut dyn Write,
    what: &str,
    f: impl FnOnce(bool) -> Result<(Vec<Row>, i32), String>,
) -> Result<(Vec<Row>, i32), String> {
    let apply = !inv.dry_run;
    if apply {
        let _lock = hold_lock(state_dir, err, what).map_err(|_| {
            // The refusal was already reported; surface as an error the
            // finish() path will not reprint.
            String::new()
        })?;
        f(true)
    } else {
        f(false)
    }
}

/// The rows of one `-M` verb, every one through [`render_row`] — one
/// renderer, so a `clean` or a `failed` reads the same wherever it appears.
fn render_rows(rows: &[Row]) -> String {
    let mut out = String::new();
    for row in rows {
        out.push_str(&render_row(row));
        out.push('\n');
    }
    out
}

/// One `-M` row, byte-identical to `gsa_maint::Row::render` with colour
/// off. The row vocabulary is `gsa-maint`'s; this maps the states a reader
/// hunts for onto a role — `clean` green, `failed` red, a drift or a gap
/// yellow — and leaves everything else plain.
fn render_row(row: &Row) -> String {
    // gsa-maint puts the audit verdict in the REASON (`audit <family>` +
    // `clean`/`N finding(s)`), a prune outcome in the ACTION; both fields are
    // read here so `-Ma`, `-Md` and the mutating verbs agree.
    let verdict = |text: &str| match text {
        "clean" => Some(style::Role::Ok),
        "failed" => Some(style::Role::Fail),
        "drift" | "missing" | "absent" => Some(style::Role::Warn),
        value if value.ends_with("finding(s)") && value != "0 finding(s)" => {
            Some(style::Role::Warn)
        }
        _ => None,
    };
    let role = verdict(&row.action).or_else(|| verdict(&row.reason));
    let action = match role {
        Some(role) => style::styled(role, row.action.clone()),
        None => row.action.clone(),
    };
    if row.reason.is_empty() {
        format!("{} {action}", row.subject)
    } else {
        format!("{} {action} {}", row.subject, row.reason)
    }
}

fn finish(
    result: Result<(Vec<Row>, i32), String>,
    out: &mut dyn Write,
    err: &mut dyn Write,
    what: &str,
) -> i32 {
    match result {
        Ok((rows, rc)) => {
            let _ = write!(out, "{}", render_rows(&rows));
            rc
        }
        Err(message) if message.is_empty() => {
            let _ = what;
            RC_REFUSAL
        }
        Err(message) => {
            let _ = writeln!(err, "gsa: {what}: {message}");
            RC_REFUSAL
        }
    }
}
