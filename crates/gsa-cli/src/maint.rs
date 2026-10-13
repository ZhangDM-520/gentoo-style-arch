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

use gsa_maint::{MaintCtx, Row, RC_OK, RC_REFUSAL, RC_USAGE};
use gsa_recipe::RecipeDb;
use gsa_state::StateRoot;
use gsa_topo::load_project;

use crate::args::Invocation;
use crate::install::DEFAULT_CONF;
use crate::select::{self, Ctx};
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
    match inv.action {
        Some('a') => Ok(MaintVerb::Audit),
        Some('d') => Ok(MaintVerb::Doctor),
        Some('i') => Ok(MaintVerb::IgnorePkg),
        Some('l') => Ok(MaintVerb::Logs),
        Some('m') => Ok(MaintVerb::Mirrors),
        Some('c') => Ok(MaintVerb::Prune(strength)),
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
pub fn run(inv: &Invocation, out: &mut dyn Write, err: &mut dyn Write) -> i32 {
    let verb = match verb_of(inv) {
        Ok(verb) => verb,
        Err(message) => {
            let _ = writeln!(err, "gsa: {message}");
            return RC_USAGE;
        }
    };

    // Per-verb usage fences (§B.7's shapes).
    match verb {
        MaintVerb::Audit | MaintVerb::Mirrors if !inv.targets.is_empty() => {
            let _ = writeln!(err, "gsa: {} takes no targets", inv.spelling());
            return RC_USAGE;
        }
        MaintVerb::Doctor | MaintVerb::IgnorePkg | MaintVerb::History
            if !inv.targets.is_empty() =>
        {
            let _ = writeln!(
                err,
                "gsa: {} takes no targets (its arguments are flags: --fix / --prune --backfill / --show)",
                inv.spelling()
            );
            return RC_USAGE;
        }
        MaintVerb::Logs if !inv.targets.is_empty() => {
            let _ = writeln!(
                err,
                "gsa: -Ml takes no targets (browse with --tail <ref>, prune with --keep N)"
            );
            return RC_USAGE;
        }
        MaintVerb::Prune(2) | MaintVerb::Prune(3) if !inv.targets.is_empty() => {
            let _ = writeln!(
                err,
                "gsa: {} takes no targets (it is a workspace-wide wipe)",
                inv.spelling()
            );
            return RC_USAGE;
        }
        _ => {}
    }
    if !inv.ranges.is_empty() && !matches!(verb, MaintVerb::Prune(1)) {
        let _ = writeln!(
            err,
            "gsa: index ranges address an -S/-B selection (see 'gsa -Sl')"
        );
        return RC_USAGE;
    }
    if inv.leaf && !matches!(verb, MaintVerb::Prune(1)) {
        let _ = writeln!(err, "gsa: --leaf applies to -Mc's pruning selection");
        return RC_USAGE;
    }
    if has_flag(inv, "--add") && has_flag(inv, "--remove") {
        let _ = writeln!(
            err,
            "gsa: --add and --remove are alternatives (one per invocation)"
        );
        return RC_USAGE;
    }
    if has_flag(inv, "--prune") && has_flag(inv, "--backfill") {
        let _ = writeln!(err, "gsa: -Mi takes ONE of --prune / --backfill");
        return RC_USAGE;
    }

    let root = match crate::find_root() {
        Some(root) => root,
        None => {
            let _ = writeln!(
                err,
                "gsa: cannot find config/topology.conf from the current directory upward (run inside the recipe repository)"
            );
            return RC_USAGE;
        }
    };
    let project = match load_project(&root) {
        Ok(project) => project,
        Err(error) => {
            let _ = writeln!(err, "gsa: {}", cmd_error(error.to_string()));
            return RC_USAGE;
        }
    };
    let graph = match gsa_graph::Graph::build(&project.topology.records) {
        Ok(graph) => graph,
        Err(error) => {
            let _ = writeln!(err, "gsa: config/topology.conf: {error}");
            return RC_USAGE;
        }
    };
    let db = match RecipeDb::load(&root, graph.records()) {
        Ok(db) => db,
        Err(error) => {
            let _ = writeln!(err, "gsa: {}", cmd_error(error.to_string()));
            return RC_USAGE;
        }
    };
    let state_dir = gsa_state::resolve_state_root(inv.state_dir.as_deref());
    let state = match StateRoot::open(&state_dir) {
        Ok(state) => state,
        Err(error) => {
            let _ = writeln!(err, "gsa: {error}");
            return RC_REFUSAL;
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
                        (outcome.rows, rc)
                    })
                });
                return finish(result, out, err, "-Md --fix");
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
            return finish(result, out, err, "-Mi");
        }
        MaintVerb::Logs => {
            if let Some(spec) = &inv.tail {
                match resolve_one(&sel_ctx, spec, err) {
                    Ok(id) => {
                        let path = state.path().join("logs").join(format!("{id}.log"));
                        if path.is_file() {
                            rows.push(Row::new(
                                &id,
                                "log",
                                format!("{} bytes {}", file_size(&path), path.display()),
                            ));
                            match gsa_maint::hygiene::tail_lines(&path) {
                                Ok(text) => {
                                    rows.push(Row::new(&id, "tail", text.replace('\n', " ⏎ ")))
                                }
                                Err(message) => rows.push(Row::new(&id, "failed", message)),
                            }
                        } else {
                            rows.push(Row::new(&id, "log-missing", path.display().to_string()));
                        }
                    }
                    Err(rc) => return rc,
                }
            }
            if let Some(spec) = &inv.keep {
                let keep: usize = match spec.parse() {
                    Ok(keep) => keep,
                    Err(_) => {
                        let _ = writeln!(err, "gsa: --keep wants a number (got '{spec}')");
                        return RC_USAGE;
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
                            let _ = write!(out, "{}", gsa_maint::render_rows(&rows));
                            return prune_rc;
                        }
                    }
                    Err(message) => {
                        if !message.is_empty() {
                            let _ = writeln!(err, "gsa: -Ml --keep: {message}");
                        }
                        return RC_REFUSAL;
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
                match gsa_maint::mirrors::run(&ctx, false) {
                    Ok(plan) => {
                        let _ = write!(out, "{}", gsa_maint::render_rows(&plan));
                    }
                    Err(message) => {
                        let _ = writeln!(err, "gsa: -Mm: {message}");
                        return RC_REFUSAL;
                    }
                }
                let _ = writeln!(err, "gsa: -Mm {}", gsa_maint::CONFIRMATION_REQUIRED);
                return RC_REFUSAL;
            }
            let apply = !inv.dry_run;
            let _lock = if apply {
                match hold_lock(&state_dir, err, "mirrors") {
                    Ok(lock) => Some(lock),
                    Err(rc) => return rc,
                }
            } else {
                None
            };
            match gsa_maint::mirrors::run(&ctx, apply) {
                Ok(plan) => rows.extend(plan),
                Err(message) => {
                    let _ = writeln!(err, "gsa: -Mm: {message}");
                    return RC_REFUSAL;
                }
            }
        }
        MaintVerb::Prune(strength) => {
            let recipes: Vec<String> = if strength == 1 {
                if inv.targets.is_empty() {
                    let _ = writeln!(err, "gsa: -Mc requires a selection (targets or @set)");
                    return RC_USAGE;
                }
                let selection =
                    match select::build_selection(&sel_ctx, &inv.targets, &inv.ranges, inv.leaf) {
                        Ok(selection) => selection,
                        Err(error) => {
                            let _ = writeln!(err, "gsa: {}", cmd_error(error.to_string()));
                            return RC_USAGE;
                        }
                    };
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
                Ok((
                    match strength {
                        1 => gsa_maint::prune::strength1(&ctx, &recipes, apply),
                        2 => gsa_maint::prune::strength2(&ctx, apply),
                        _ => gsa_maint::prune::strength3(&ctx, apply),
                    },
                    RC_OK,
                ))
            };
            // -Mccc prints its target list and asks first (§B.7): without
            // --noconfirm the PLAN is printed and the run stops rc 3 —
            // nothing is deleted (the engine never prompts, §K.3).
            let confirming = strength >= 3 && !inv.dry_run && !has_flag(inv, "--noconfirm");
            if confirming {
                match run_strength(false) {
                    Ok((plan_rows, _)) => {
                        let _ = write!(out, "{}", gsa_maint::render_rows(&plan_rows));
                    }
                    Err(message) => {
                        let _ = writeln!(err, "gsa: {}: {message}", inv.spelling());
                        return RC_REFUSAL;
                    }
                }
                let _ = writeln!(err, "gsa: -Mccc {}", gsa_maint::CONFIRMATION_REQUIRED);
                return RC_REFUSAL;
            }
            let result = mutating_rows(&state_dir, inv, out, err, "prune", run_strength);
            return finish(result, out, err, inv.spelling().as_str());
        }
        MaintVerb::Sets => {
            let add = has_flag(inv, "--add");
            let remove = has_flag(inv, "--remove");
            if add || remove {
                // --add/--remove need exactly one set name and ≥1 ref.
                let (name, refs) = match inv.targets.split_first() {
                    Some((name, refs)) => (name.clone(), refs),
                    None => {
                        let _ = writeln!(
                            err,
                            "gsa: -Ms --add/--remove wants one set name and its references"
                        );
                        return RC_USAGE;
                    }
                };
                // A name that is not an editable user set (computed set or
                // bad id class) is a USAGE error (§G.1), before any kv work;
                // what remains after this gate are write failures (rc 3).
                if let Err(message) = gsa_maint::sets::user_set_name(&name) {
                    let _ = writeln!(err, "gsa: {message}");
                    return RC_USAGE;
                }
                let mut ids = Vec::new();
                for spec in refs {
                    match resolve_one(&sel_ctx, spec, err) {
                        Ok(id) => ids.push(id),
                        Err(rc) => return rc,
                    }
                }
                if ids.is_empty() {
                    let _ = writeln!(err, "gsa: -Ms --add/--remove wants at least one reference");
                    return RC_USAGE;
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
                return finish(result, out, err, "-Ms");
            }
            match gsa_maint::sets::set_rows(&ctx, &state, &inv.targets) {
                Ok(listed) => rows.extend(listed),
                Err(message) => {
                    let _ = writeln!(err, "gsa: {message}");
                    return RC_USAGE;
                }
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
                        Err(rc) => return rc,
                    }
                }
                if ids.is_empty() {
                    let _ = writeln!(err, "gsa: -Mw --add/--remove wants at least one reference");
                    return RC_USAGE;
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
                return finish(result, out, err, "-Mw");
            }
            match gsa_maint::sets::world_rows(&ctx, &state) {
                Ok(listed) => rows.extend(listed),
                Err(message) => {
                    let _ = writeln!(err, "gsa: {message}");
                    return RC_USAGE;
                }
            }
        }
        MaintVerb::History => {
            if let Some(spec) = &inv.show {
                let id: usize = match spec.parse() {
                    Ok(id) if id > 0 => id,
                    _ => {
                        let _ = writeln!(
                            err,
                            "gsa: --show wants a run id (1-based over the recorded history)"
                        );
                        return RC_USAGE;
                    }
                };
                match gsa_maint::history::show(&state, id) {
                    Ok(block) => {
                        let _ = write!(out, "{block}");
                    }
                    Err(message) => {
                        let _ = writeln!(err, "gsa: -Mh --show: {message}");
                        return RC_USAGE;
                    }
                }
            }
            if has_flag(inv, "--prune") {
                let result = mutating_rows(&state_dir, inv, out, err, "history", |apply| {
                    gsa_maint::history::prune(&state, apply).map(|rows| (rows, RC_OK))
                });
                return finish(result, out, err, "-Mh --prune");
            }
            if inv.show.is_none() {
                match gsa_maint::history::list_rows(&state) {
                    Ok(listed) => rows.extend(listed),
                    Err(message) => {
                        let _ = writeln!(err, "gsa: -Mh: {message}");
                        return RC_REFUSAL;
                    }
                }
                if rows.is_empty() {
                    rows.push(Row::new("runs", "empty", "no recorded runs"));
                }
            }
        }
    }
    let _ = write!(out, "{}", gsa_maint::render_rows(&rows));
    rc
}

/// Resolve one §C.1 reference to its recipe id (typo = usage error with
/// nearest candidates, from the ordinary selection layer).
fn resolve_one(ctx: &Ctx<'_>, spec: &str, err: &mut dyn Write) -> Result<String, i32> {
    let (found, notes) = select::resolve_ref(ctx, spec, 0).map_err(|e| {
        let _ = writeln!(err, "gsa: {}", cmd_error(e.to_string()));
        RC_USAGE
    })?;
    write_notes(err, &notes);
    match found.first() {
        Some(&idx) => Ok(ctx.graph.record(idx).id.as_str().to_string()),
        None => {
            let _ = writeln!(err, "gsa: selection resolved to no packages");
            Err(RC_USAGE)
        }
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

fn finish(
    result: Result<(Vec<Row>, i32), String>,
    out: &mut dyn Write,
    err: &mut dyn Write,
    what: &str,
) -> i32 {
    match result {
        Ok((rows, rc)) => {
            let _ = write!(out, "{}", gsa_maint::render_rows(&rows));
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
