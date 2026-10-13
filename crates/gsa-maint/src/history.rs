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
pub fn list_rows(state: &StateRoot) -> Result<Vec<Row>, String> {
    let (records, _corrupt) = records(state)?;
    Ok(records
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
        .collect())
}

/// Re-render one stored record through the same
/// [`gsa_model::RunRecord::render_machine`] the run emitted (§H.1:
/// persistence is storage of the same structure — the renderings can never
/// drift). `run_id` is 1-based over the history.
pub fn show(state: &StateRoot, run_id: usize) -> Result<String, String> {
    let (records, _corrupt) = records(state)?;
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
    Ok(rows)
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
