//! Run history (`gsa -Mh`, contract §J.1 `runs/` + the §H.1 persistence
//! amendment): list recorded run records and their continuations, re-render
//! one, and enforce the bounded retention.
//!
//! Retention policy (normative): [`RUN_HISTORY_KEEP`] newest finished
//! records stay; an unfinished record (`remaining:` non-empty) is a resume
//! pointer and is never dropped while it is the NEWEST unfinished record for
//! its selection. A chronic failure appends one unfinished record per retry,
//! so older resume pointers for the same selection are superseded — the
//! newer record already names every package that still needs work.
//! `--prune` compacts `runs/history.jsonl` atomically (temp + rename in
//! `runs/`); unusable lines are reported by the readers and dropped by the
//! compaction.

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
                // `started=` is the record's own wall clock (§H.2): the
                // listing answers "when" without a second side-car.
                format!(
                    "{} {} {} started={}",
                    record.rc,
                    record.continuation.remaining.len(),
                    if record.continuation.command.is_empty() {
                        "-".to_string()
                    } else {
                        record.continuation.command.clone()
                    },
                    record
                        .stamp
                        .started
                        .map(|epoch| epoch.to_string())
                        .unwrap_or_else(|| "-".to_string())
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
    let runs_dir = state.path().join("runs");
    let current = std::fs::read_to_string(runs_dir.join("current"))
        .ok()
        .map(|s| s.trim().to_string());
    let mut runs = unfinished_dirs(state);
    for run in &mut runs {
        if runs_dir.join(&run.id).join("run.died").exists() {
            run.live = false;
            continue;
        }
        let pid_alive = run
            .pid
            .map(|pid| std::path::Path::new(&format!("/proc/{pid}")).exists());
        // If `run.lock` is definitely free (`Some(false)`), nothing holds it;
        // if held or unprobed, require this run's own `run.open` PID to be
        // live (else `runs/current` match only when no PID was recorded).
        run.live = match (held, pid_alive) {
            (Some(false), _) => false,
            (_, Some(alive)) => alive,
            (Some(true), None) => current.as_deref() == Some(run.id.as_str()),
            (None, None) => false,
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
/// The ids a store currently answers, spelled the way a reader types them
/// back: `none`, `1`, `1-7` — never Rust's `1..=7` debug syntax
/// (blind-review 2026-11-11, packaging-novice).
fn recorded_range(len: usize) -> String {
    match len {
        0 => "none".to_string(),
        1 => "1".to_string(),
        n => format!("1-{n}"),
    }
}

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
            recorded_range(records.len())
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
    let (records, corrupt) = records(state)?;
    if let Some(message) = CorruptLine::refusal(&corrupt, "the run history") {
        return Err(message);
    }
    let total = records.len();
    let mut keep: Vec<bool> = vec![false; total];
    let mut budget = RUN_HISTORY_KEEP;
    // Newest-first: one resume pointer per selection survives (the first
    // unfinished record seen for a `selection-source`); every older
    // unfinished record for the same selection is superseded.
    let mut resumed: std::collections::HashSet<&str> = std::collections::HashSet::new();
    for (idx, record) in records.iter().enumerate().rev() {
        let unfinished = !record.continuation.remaining.is_empty();
        if unfinished {
            if resumed.insert(record.selection_source.as_str()) {
                keep[idx] = true;
            }
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
        } else if !record.continuation.remaining.is_empty() {
            rows.push(Row::new(
                id,
                if apply { "pruned" } else { "prune" },
                format!(
                    "superseded-resume-pointer remaining-{}",
                    record.continuation.remaining.len()
                ),
            ));
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

/// Rewrite `runs/history.jsonl` with exactly the kept records through
/// `ownership_gate` (`gsa_state::RunHistory::compact`).
fn compact(state: &StateRoot, records: &[RunRecord], keep: &[bool]) -> Result<(), String> {
    let kept: Vec<RunRecord> = records
        .iter()
        .enumerate()
        .filter(|(idx, _)| keep.get(*idx).copied().unwrap_or(false))
        .map(|(_, record)| record.clone())
        .collect();
    let mut err = Vec::new();
    let res = gsa_state::RunHistory::compact(state, &kept, &mut err);
    if !err.is_empty() {
        eprint!("{}", String::from_utf8_lossy(&err));
    }
    res.map_err(|e| format!("cannot compact run history: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_recorded_range_is_typed_the_way_a_reader_types_it_back() {
        assert_eq!(recorded_range(0), "none");
        assert_eq!(recorded_range(1), "1");
        assert_eq!(recorded_range(2), "1-2");
        assert!(!recorded_range(9).contains("..="));
    }

    #[test]
    fn unfinished_runs_does_not_mark_dead_run_live_while_another_lock_is_held() {
        let dir = std::env::temp_dir().join(format!("gsa-hist-live-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("runs/old-crashed")).unwrap();
        std::fs::write(
            dir.join("runs/old-crashed/run.open"),
            "pid=99999999 epoch=1\n",
        )
        .unwrap();
        let _lock = gsa_sched::lock::try_acquire_run_lock(&dir).unwrap();
        let state = StateRoot::open_readonly(&dir);
        let found = unfinished_runs(&state);
        assert_eq!(found.len(), 1);
        assert!(
            !found[0].live,
            "a dead pid with no run.closed must not look live just because another process holds run.lock"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn prune_refuses_corrupt_history_and_compact_refuses_symlink_target() {
        let dir = std::env::temp_dir().join(format!("gsa-hist-corrupt-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("runs")).unwrap();
        let state = StateRoot::open_readonly(&dir);
        std::fs::write(state.runs_path(), "not-json\n").unwrap();
        let err = prune(&state, true).expect_err("corrupt run history must be refused by prune");
        assert!(
            err.contains("corrupt") || err.contains("run history"),
            "{err}"
        );

        // Symlink protection on compaction: target file must not be overwritten.
        let victim = dir.join("victim");
        std::fs::write(&victim, "untouched\n").unwrap();
        let _ = std::fs::remove_file(state.runs_path());
        std::os::unix::fs::symlink(&victim, state.runs_path()).unwrap();
        let err2 =
            compact(&state, &[], &[]).expect_err("compact must refuse symlink at history.jsonl");
        assert!(
            err2.contains("symlink")
                || err2.contains("Too many")
                || err2.contains("Ownership")
                || err2.contains("gate"),
            "{err2}"
        );
        assert_eq!(std::fs::read_to_string(&victim).unwrap(), "untouched\n");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
