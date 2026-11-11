//! Run history (`gsa -Mh`, contract §J.1 `runs/` + the §H.1 persistence
//! amendment): list recorded run records and their continuations, re-render
//! one, and enforce the bounded retention.
//!
//! Retention policy (normative): [`RUN_HISTORY_KEEP`] newest records stay;
//! a record whose continuation still has `remaining:` work is NEVER pruned —
//! it is the resume pointer (`command:` + `remaining:`), and dropping it
//! would strand a failed run. `--prune` compacts `runs/history.jsonl`
//! atomically (temp + rename in `runs/`); unusable lines are reported by the
//! readers and dropped by the compaction.

use std::path::PathBuf;

use gsa_model::RunRecord;
use gsa_state::{CorruptLine, RunHistory, StateRoot};

use crate::{protect, Row};

/// The bounded run-history retention (`-Mh --prune`).
pub const RUN_HISTORY_KEEP: usize = 50;

/// Every stored run record in append order, plus unreadable lines.
pub fn records(state: &StateRoot) -> Result<(Vec<RunRecord>, Vec<CorruptLine>), String> {
    RunHistory::read(state).map_err(|e| e.to_string())
}

/// The listing rows: `<run-id> <outcome> <rc> <remaining-count> <command…>`.
/// The run id is the record's 1-based position in the history (append
/// order) — the store has no separate id field, and inventing one would be a
/// format change (§L.2).
///
/// A run that never reached the store is listed AFTER the recorded ones, by
/// its own `runs/<id>` name: `in-progress` while its supervisor is alive,
/// `died` once it is not (contract §J.1's `run.open`/`run.closed`/`run.died`
/// stamps). That is the recovery user's only answer to "was a run in flight
/// when I lost the terminal?" — the history alone cannot answer it.
pub fn list_rows(state: &StateRoot) -> Result<Vec<Row>, String> {
    list_rows_with_corrupt(state).map(|(rows, _corrupt)| rows)
}

/// [`list_rows`] carrying the unusable lines the store reader found: an
/// unreadable line is not an absent one (rule 71), so a listing must never
/// present the surviving runs as the whole history (blind-review 2026-11-11:
/// a truncated `runs/history.jsonl` silently lost three runs).
pub fn list_rows_with_corrupt(state: &StateRoot) -> Result<(Vec<Row>, Vec<CorruptLine>), String> {
    let (records, corrupt) = records(state)?;
    let mut rows: Vec<Row> = records
        .iter()
        .enumerate()
        .map(|(idx, record)| {
            Row::new(
                (idx + 1).to_string(),
                &record.outcome,
                format!(
                    "{} {} {}",
                    record.rc,
                    record.continuation.remaining.len(),
                    record.continuation.command
                ),
            )
        })
        .collect();
    for run in unfinished_runs(state) {
        rows.push(Row::new(
            run.id.clone(),
            if run.live { "in-progress" } else { "died" },
            format!(
                "epoch={} lanes={} settled={} markers=runs/{}",
                run.epoch
                    .map(|e| e.to_string())
                    .unwrap_or_else(|| "-".to_string()),
                run.lanes,
                run.settled,
                run.id
            ),
        ));
    }
    Ok((rows, corrupt))
}

/// The one run on disk with no history row: `runs/current` names it, its
/// directory carries `run.open`, and no `run.closed` proves it finished
/// (contract §J.1). `live` is the `run.open` supervisor pid answering in
/// `/proc` with a `gsa` command line — a recycled pid that happens to be
/// another `gsa` process is the only false positive, and it costs a reader
/// one "in progress" claim that the missing record already contradicts.
pub struct Unfinished {
    pub id: String,
    pub live: bool,
    pub pid: Option<u32>,
    pub epoch: Option<u64>,
    pub lanes: usize,
    pub settled: usize,
}

fn unfinished_runs(state: &StateRoot) -> Vec<Unfinished> {
    let held = gsa_sched::lock::run_lock_held(state.path());
    let mut runs = unfinished_dirs(state);
    for run in &mut runs {
        // The run lock is the exact answer (the supervisor holds it for the
        // whole run); the `run.open` pid is the fallback when the lock file
        // is absent or unreadable (a state root seeded without one).
        run.live = match held {
            Some(held) => held,
            None => {
                run.pid
                    .map(|pid| std::path::Path::new(&format!("/proc/{pid}")).exists())
                    == Some(true)
            }
        };
    }
    runs
}

/// The on-disk half of [`unfinished_run`], without a liveness verdict: the
/// `-Mh --prune` path holds the run lock itself, so a live run cannot be
/// present there and the probe would only see its own hold.
fn unfinished_dirs(state: &StateRoot) -> Vec<Unfinished> {
    let runs_dir = state.path().join("runs");
    let Ok(entries) = std::fs::read_dir(&runs_dir) else {
        return Vec::new();
    };
    let mut ids: Vec<String> = entries
        .flatten()
        .filter(|entry| entry.path().is_dir())
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .filter(|id| {
            let dir = runs_dir.join(id);
            dir.join("run.open").exists() && !dir.join("run.closed").exists()
        })
        .collect();
    // `runs/current` names the live/last run: list it first, then the rest in
    // name order (a died run outlives the run that replaced it as `current`).
    if let Ok(current) = std::fs::read_to_string(runs_dir.join("current")) {
        let current = current.trim().to_string();
        if let Some(pos) = ids.iter().position(|id| *id == current) {
            let id = ids.remove(pos);
            ids.insert(0, id);
        }
    }
    ids.iter()
        .filter_map(|id| unfinished_dir(state, id))
        .collect()
}

fn unfinished_dir(state: &StateRoot, id: &str) -> Option<Unfinished> {
    let dir = state.path().join("runs").join(id);
    let open = std::fs::read_to_string(dir.join("run.open")).ok()?;
    let mut pid = None;
    let mut epoch = None;
    for field in open.split_whitespace() {
        if let Some(value) = field.strip_prefix("pid=") {
            pid = value.parse::<u32>().ok();
        } else if let Some(value) = field.strip_prefix("epoch=") {
            epoch = value.parse::<u64>().ok();
        }
    }
    let Ok(files) = std::fs::read_dir(&dir) else {
        return None;
    };
    let mut lanes = 0;
    let mut settled = 0;
    for file in files.flatten() {
        let name = file.file_name().to_string_lossy().into_owned();
        if name.ends_with(".started") {
            lanes += 1;
        } else if name.ends_with(".result") {
            settled += 1;
        }
    }
    Some(Unfinished {
        id: id.to_string(),
        live: false,
        pid,
        epoch,
        lanes,
        settled,
    })
}

/// Re-render one stored record through the same
/// [`gsa_model::RunRecord::render_machine`] the run emitted (§H.1:
/// persistence is storage of the same structure — the renderings can never
/// drift). `run_id` is 1-based over the history.
pub fn show(state: &StateRoot, run_id: usize) -> Result<String, String> {
    let (records, corrupt) = records(state)?;
    // Run ids are positions over the history, so an unusable line shifts
    // every id after it: re-rendering "run 7" from a damaged store could
    // show a different run (rule 71).
    if let Some(message) = CorruptLine::refusal(&corrupt, "the run history") {
        return Err(message);
    }
    match records.get(run_id.wrapping_sub(1)) {
        Some(record) if run_id > 0 => Ok(record.render_machine()),
        _ => Err(format!(
            "unknown run id {run_id} (recorded: {})",
            if records.is_empty() {
                "none".to_string()
            } else {
                format!("1..={}", records.len())
            }
        )),
    }
}

/// The bounded retention (§B.7 `-Mh --prune`): drop every record beyond the
/// newest [`RUN_HISTORY_KEEP`] EXCEPT unfinished ones (non-empty
/// `remaining:`), which are kept as resume pointers. Rows:
/// `<run-id> <prune|pruned|kept> <reason…>`. Compaction rewrites the store
/// atomically; a rewrite failure is `Err` and leaves the file untouched.
/// `apply == false` is the dry-run plan.
pub fn prune(state: &StateRoot, apply: bool) -> Result<Vec<Row>, String> {
    let (records, _corrupt) = records(state)?;
    let total = records.len();
    let mut keep: Vec<bool> = vec![false; total];
    let mut budget = RUN_HISTORY_KEEP;
    for (idx, record) in records.iter().enumerate().rev() {
        let unfinished = !record.continuation.remaining.is_empty();
        if unfinished {
            keep[idx] = true;
            continue;
        }
        if budget > 0 {
            keep[idx] = true;
            budget -= 1;
        }
    }
    let mut rows = Vec::new();
    for (idx, record) in records.iter().enumerate() {
        let id = (idx + 1).to_string();
        if keep[idx] {
            let reason = if !record.continuation.remaining.is_empty() {
                "resume-pointer remaining-unfinished"
            } else {
                "retention newest"
            };
            rows.push(protect::keep_row(&id, reason));
        } else {
            rows.push(Row::new(
                id,
                if apply { "pruned" } else { "prune" },
                format!(
                    "retention keep={RUN_HISTORY_KEEP} remaining-{}",
                    record.continuation.remaining.len()
                ),
            ));
        }
    }
    if apply && rows.iter().any(|r| r.action == "pruned") {
        compact(state, &records, &keep)?;
    }
    retire_unfinished(state, apply, &mut rows)?;
    Ok(rows)
}

/// `runs/<id>`'s kept evidence is bounded like the history: `-Mh --prune`
/// retires a DIED run's directory (its markers) once the reader has had its
/// chance to see it. A live run is never touched — its markers are in use.
fn retire_unfinished(state: &StateRoot, apply: bool, rows: &mut Vec<Row>) -> Result<(), String> {
    // No liveness probe here: `-Mh --prune` already HOLDS the run lock (a
    // live run would have refused the verb with `run-in-flight`), so an
    // unfinished directory present under this lock is a dead one.
    for run in unfinished_dirs(state) {
        rows.push(Row::new(
            run.id.clone(),
            if apply { "pruned" } else { "prune" },
            "died-run markers",
        ));
        if apply {
            let dir = state.path().join("runs").join(&run.id);
            std::fs::remove_dir_all(&dir)
                .map_err(|e| format!("cannot remove {}: {e}", dir.display()))?;
        }
    }
    Ok(())
}

/// Rewrite `runs/history.jsonl` with exactly the kept records, atomically
/// (temp name in `runs/`, `rename(2)` over the store — an interrupt never
/// leaves a half-history).
fn compact(state: &StateRoot, records: &[RunRecord], keep: &[bool]) -> Result<(), String> {
    let path: PathBuf = state.runs_path();
    let mut body = String::new();
    for (idx, record) in records.iter().enumerate() {
        if !keep[idx] {
            continue;
        }
        body.push_str(&gsa_state::wire_run(record));
        body.push('\n');
    }
    let tmp = path.with_file_name(format!("history.jsonl.tmp.{}", std::process::id()));
    std::fs::write(&tmp, body)
        .map_err(|e| format!("cannot stage the run-history compaction: {e}"))?;
    std::fs::rename(&tmp, &path).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        format!("cannot publish the run-history compaction: {e}")
    })?;
    Ok(())
}
