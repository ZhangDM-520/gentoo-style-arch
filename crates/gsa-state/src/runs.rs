//! The run history (contract §J.1 `runs/`, the §H.1 amendment): every
//! completed or interrupted run's `format: 2` run record is appended here —
//! persistence is storage of the SAME structure the machine block renders,
//! never a fourth derivation. Reads re-render through
//! [`gsa_model::RunRecord::render_machine`], so the stored record and the
//! emitted block can never drift.

use std::io::Write;
use std::path::PathBuf;

use gsa_model::RunRecord;
use serde::{Deserialize, Serialize};

use crate::ownership::StateError;
use crate::store::{self, CorruptLine};
use crate::StateRoot;

#[derive(Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "kebab-case")]
enum RunEntry {
    Run { record: RunRecord },
}

/// The append-only line one stored run occupies (the §H.1 line vocabulary).
/// The compaction (`-Mh --prune`) re-emits exactly the lines
/// [`RunHistory::append`] writes, so the two can never drift.
pub fn wire_run(record: &RunRecord) -> String {
    serde_json::to_string(&RunEntry::Run {
        record: record.clone(),
    })
    .expect("a run record always serializes")
}

/// The side-car run history store. Bounded retention (`-Mh --prune`) is the
/// maint verb's compaction (contract §B.7); the store itself is append-only.
pub struct RunHistory;

impl RunHistory {
    /// Append one run record (§H.1). Dry-run plan records never reach this:
    /// `--dry-run` mutates nothing (§B.8).
    pub fn append(
        root: &StateRoot,
        record: &RunRecord,
        err: &mut dyn Write,
    ) -> Result<(), StateError> {
        store::append_json(
            &root.runs_path(),
            &RunEntry::Run {
                record: record.clone(),
            },
            err,
        )
    }

    /// Every stored run record in append order, plus every line that could
    /// not be used (corruption-tolerant reads, §J.5).
    pub fn read(root: &StateRoot) -> Result<(Vec<RunRecord>, Vec<CorruptLine>), StateError> {
        let read: store::StoreRead<RunEntry> = store::read_json(&root.runs_path(), "runs")?;
        let records = read
            .rows
            .into_iter()
            .map(|RunEntry::Run { record }| record)
            .collect();
        Ok((records, read.corrupt))
    }

    /// The run-history file path (for tests and reports).
    pub fn path(root: &StateRoot) -> PathBuf {
        root.runs_path()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gsa_model::{
        Continuation, OutcomeRow, PlanAction, PlanRow, RecipeId, RowStatus, RunOutcome,
    };

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir =
            std::env::temp_dir().join(format!("gsa-state-runs-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn record(pkg: &str, rc: i32) -> RunRecord {
        let rows = vec![OutcomeRow {
            pkg: RecipeId::new(pkg).unwrap(),
            status: RowStatus::Succeeded,
            rc: Some(0),
            dur: Some(3),
            reason: "ok".to_string(),
        }];
        let run_outcome = RunOutcome::compute(&rows, false, false, false);
        RunRecord {
            selection_source: format!("packages={pkg}"),
            order: vec![RecipeId::new(pkg).unwrap()],
            lanes: Some(2),
            normal_jobs: Some(4),
            core_jobs: Some(2),
            intensity: "xhigh".to_string(),
            outcome: run_outcome.outcome.to_string(),
            rc,
            dry_run: false,
            prefetch_warnings: None,
            plan: vec![PlanRow {
                pkg: RecipeId::new(pkg).unwrap(),
                action: PlanAction::Build,
                reason: "ok".to_string(),
            }],
            outcomes: rows,
            continuation: Continuation {
                command: format!("gsa -B {pkg}"),
                remaining: Vec::new(),
                not_mirrored: vec!["-Mcc".to_string()],
                env_required: Vec::new(),
            },
        }
    }

    #[test]
    fn run_history_round_trips_the_same_structure() {
        let dir = scratch("roundtrip");
        let root = StateRoot::open(&dir).unwrap();
        let mut err = Vec::new();
        let first = record("alpha", 0);
        let second = record("beta", 4);
        RunHistory::append(&root, &first, &mut err).unwrap();
        RunHistory::append(&root, &second, &mut err).unwrap();
        let (records, corrupt) = RunHistory::read(&root).unwrap();
        assert!(corrupt.is_empty());
        assert_eq!(records, vec![first.clone(), second]);
        // Storage of the same structure: the read-back record renders the
        // exact machine block the run emitted.
        assert_eq!(records[0].render_machine(), first.render_machine());
    }

    #[test]
    fn a_truncated_tail_never_loses_earlier_records() {
        let dir = scratch("truncated");
        let root = StateRoot::open(&dir).unwrap();
        let mut err = Vec::new();
        RunHistory::append(&root, &record("alpha", 0), &mut err).unwrap();
        RunHistory::append(&root, &record("beta", 0), &mut err).unwrap();
        let path = RunHistory::path(&root);
        let bytes = std::fs::read(&path).unwrap();
        std::fs::write(&path, &bytes[..bytes.len() - 5]).unwrap();
        let (records, corrupt) = RunHistory::read(&root).unwrap();
        assert_eq!(
            records.len(),
            1,
            "the complete record before the truncation survives"
        );
        assert_eq!(records[0].order[0].as_str(), "alpha");
        assert_eq!(corrupt.len(), 1);
        assert!(corrupt[0].detail.contains("truncated tail"));
    }
}
