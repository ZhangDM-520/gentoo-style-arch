//! The run history (contract §J.1 `runs/`, the §H.1 amendment): every
//! completed or interrupted run's `format: 2` run record is appended here —
//! persistence is storage of the SAME structure the machine block renders,
//! never a fourth derivation. Reads re-render through
//! [`gsa_model::RunRecord::render_machine`], so the stored record and the
//! emitted block can never drift.

use std::io::Write;
use std::path::PathBuf;

use gsa_model::{RunRecord, RECORD_FORMAT};
use serde::{Deserialize, Serialize};

use crate::ownership::StateError;
use crate::store::{self, CorruptLine};
use crate::StateRoot;

/// The grammar a stored run row was WRITTEN in (R2-vera-11). The store used
/// to carry no marker at all, so after a `format` bump a stored row could not
/// be told from a damaged one, and [`RunRecord::render_machine`] would
/// silently re-render an old row through the new grammar — a guess presented
/// as a re-render.
///
/// Deserialization is the gate: a row naming a grammar this build does not
/// render fails to parse, so the store's existing corruption tolerance names
/// it and the readers that must not guess (`-Mh --show`, `--prune`) refuse
/// (rule 71) instead of reinterpreting its fields.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct StoredFormat;

impl Serialize for StoredFormat {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_u32(RECORD_FORMAT)
    }
}

impl<'de> Deserialize<'de> for StoredFormat {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let found = u32::deserialize(deserializer)?;
        if found == RECORD_FORMAT {
            Ok(StoredFormat)
        } else {
            Err(serde::de::Error::custom(format!(
                "record format {found}, this build writes and renders {RECORD_FORMAT} \
                 — upgrade gsa before reading this row"
            )))
        }
    }
}

#[derive(Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "kebab-case")]
enum RunEntry {
    Run {
        /// Absent only on rows written before the marker existed. Those rows
        /// are format 2 by construction — the history store was created at
        /// `format: 2` and no other grammar has ever written to it (§H.1's
        /// adoption width) — so an absent marker reads as the current
        /// grammar, never as an unknown one.
        #[serde(default, skip_serializing_if = "Option::is_none")]
        format: Option<StoredFormat>,
        record: RunRecord,
    },
}

impl RunEntry {
    /// The ONE wire form of a stored run: every writer ([`RunHistory::append`]
    /// and [`wire_run`], hence the `-Mh --prune` compaction) goes through it,
    /// so a row can never be written without its grammar marker.
    fn of(record: &RunRecord) -> Self {
        RunEntry::Run {
            format: Some(StoredFormat),
            record: record.clone(),
        }
    }
}

/// The append-only line one stored run occupies (the §H.1 line vocabulary).
/// The compaction (`-Mh --prune`) re-emits exactly the lines
/// [`RunHistory::append`] writes, so the two can never drift.
pub fn wire_run(record: &RunRecord) -> String {
    serde_json::to_string(&RunEntry::of(record)).expect("a run record always serializes")
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
        store::append_json(&root.runs_path(), &RunEntry::of(record), err)
    }

    /// Every stored run record in append order, plus every line that could
    /// not be used (corruption-tolerant reads, §J.5).
    pub fn read(root: &StateRoot) -> Result<(Vec<RunRecord>, Vec<CorruptLine>), StateError> {
        let read: store::StoreRead<RunEntry> = store::read_json(&root.runs_path(), "runs")?;
        let records = read
            .rows
            .into_iter()
            .map(|RunEntry::Run { record, .. }| record)
            .collect();
        Ok((records, read.corrupt))
    }

    /// Replace `runs/history.jsonl` with exactly `records` through the
    /// ownership gate (`F-MNT-03`).
    pub fn compact(
        root: &StateRoot,
        records: &[RunRecord],
        err: &mut dyn Write,
    ) -> Result<(), StateError> {
        let lines: Vec<String> = records.iter().map(wire_run).collect();
        store::replace_lines(&root.runs_path(), &lines, err)
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
            stamp: gsa_model::RecordStamp::default(),
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
    fn a_stored_row_names_its_record_format() {
        let dir = scratch("format-marker");
        let root = StateRoot::open(&dir).unwrap();
        let mut err = Vec::new();
        RunHistory::append(&root, &record("alpha", 0), &mut err).unwrap();
        let line = std::fs::read_to_string(RunHistory::path(&root)).unwrap();
        assert!(
            line.contains(&format!("\"format\":{RECORD_FORMAT}")),
            "a stored row must name the grammar it was written in: {line}"
        );
        // The marker is the SAME number the live block prints, so a reader
        // reconciling a stored line against the rendering has one authority.
        assert!(
            record("alpha", 0)
                .render_machine()
                .contains(&format!("format: {RECORD_FORMAT}\n")),
            "the live block and the stored marker must agree"
        );
        // And the round trip still answers the record unchanged.
        let (records, corrupt) = RunHistory::read(&root).unwrap();
        assert!(corrupt.is_empty(), "{corrupt:?}");
        assert_eq!(records.len(), 1);
    }

    #[test]
    fn a_row_written_in_another_grammar_is_reported_never_reinterpreted() {
        let dir = scratch("format-foreign");
        let root = StateRoot::open(&dir).unwrap();
        let mut err = Vec::new();
        RunHistory::append(&root, &record("alpha", 0), &mut err).unwrap();
        let path = RunHistory::path(&root);
        let line = std::fs::read_to_string(&path).unwrap();
        let renamed = line.replace(&format!("\"format\":{RECORD_FORMAT}"), "\"format\":3");
        assert_ne!(
            renamed, line,
            "the fixture must actually rewrite the marker"
        );
        std::fs::write(&path, renamed).unwrap();

        // An unreadable row is not an absent one (rule 71): the store reports
        // it by name and does NOT hand back a record re-rendered through the
        // wrong grammar.
        let (records, corrupt) = RunHistory::read(&root).unwrap();
        assert!(records.is_empty(), "a foreign grammar yields no record");
        assert_eq!(corrupt.len(), 1, "{corrupt:?}");
        assert!(
            corrupt[0].detail.contains("record format 3"),
            "the report names the grammar it found: {}",
            corrupt[0].detail
        );
        assert!(!corrupt[0].name.is_empty(), "the offender is named");
    }

    #[test]
    fn a_row_written_before_the_marker_reads_as_the_current_grammar() {
        let dir = scratch("format-legacy");
        let root = StateRoot::open(&dir).unwrap();
        // The pre-marker wire shape: `op` + `record`, no `format` key at all.
        let legacy = serde_json::json!({
            "op": "run",
            "record": serde_json::from_str::<serde_json::Value>(
                serde_json::to_string(&record("alpha", 0)).unwrap().as_str()
            ).unwrap(),
        });
        std::fs::write(RunHistory::path(&root), format!("{legacy}\n")).unwrap();
        let (records, corrupt) = RunHistory::read(&root).unwrap();
        assert!(corrupt.is_empty(), "{corrupt:?}");
        assert_eq!(records.len(), 1);
        assert_eq!(records[0], record("alpha", 0));
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
