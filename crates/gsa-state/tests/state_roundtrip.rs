//! End-to-end round trip of the side-car state database (contract §J):
//! one state root, one builder registration, then every read surface —
//! the index fold with hash verification, retention pruning, the run
//! history, the key-value, and the `--local-db-check` oracle — over real
//! `.pkg.tar.zst` archives. Scratch trees live under the harness `$TMPDIR`
//! (fixture convention); nothing here touches a real `/var/lib/gsa`.

use std::collections::BTreeSet;
use std::io::Write as _;
use std::path::{Path, PathBuf};

use gsa_model::{
    Continuation, Group, OutcomeRow, PlanAction, PlanRow, RecipeId, RowStatus, RunOutcome,
    RunRecord, TopologyRecord,
};
use gsa_state::{
    check, register_instance, wire_row, BinpkgIndex, Kv, Match, Retention, RunHistory, StateRoot,
};

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("gsa-state-e2e-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn make_archive(dir: &Path, name: &str, version: &str) -> PathBuf {
    let stage = dir.join(format!("stage-{name}-{version}"));
    std::fs::create_dir_all(&stage).unwrap();
    let mut body = Vec::new();
    writeln!(body, "pkgbase = {name}").unwrap();
    writeln!(body, "pkgname = {name}").unwrap();
    writeln!(body, "pkgver = {version}").unwrap();
    writeln!(body, "arch = any").unwrap();
    std::fs::write(stage.join(".PKGINFO"), &body).unwrap();
    let out = dir.join(format!("{name}-{version}-any.pkg.tar.zst"));
    let file = std::fs::File::create(&out).unwrap();
    let enc = zstd::stream::Encoder::new(file, 0).unwrap();
    let mut tar = tar::Builder::new(enc);
    tar.append_dir_all(".", &stage).unwrap();
    tar.into_inner().unwrap().finish().unwrap();
    std::fs::remove_dir_all(&stage).unwrap();
    out
}

fn record(pkg: &str) -> RunRecord {
    let rows = vec![OutcomeRow {
        pkg: RecipeId::new(pkg).unwrap(),
        status: RowStatus::Succeeded,
        rc: Some(0),
        dur: Some(2),
        reason: "ok".to_string(),
    }];
    RunRecord {
        selection_source: format!("packages={pkg}"),
        order: vec![RecipeId::new(pkg).unwrap()],
        lanes: Some(1),
        normal_jobs: Some(2),
        core_jobs: Some(1),
        intensity: "low".to_string(),
        outcome: RunOutcome::compute(&rows, false, false, false)
            .outcome
            .to_string(),
        rc: 0,
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
            not_mirrored: Vec::new(),
            env_required: Vec::new(),
        },
    }
}

#[test]
fn one_state_root_serves_every_surface() {
    let dir = scratch("e2e");
    let recipe_dir = dir.join("packages").join("leaf");
    std::fs::create_dir_all(&recipe_dir).unwrap();
    let root = StateRoot::open(&dir).unwrap();
    let retention = Retention::from_records(&[TopologyRecord {
        id: RecipeId::new("leaf").unwrap(),
        path: "packages/leaf".to_string(),
        groups: vec![Group::Misc],
        edges: Vec::new(),
        tags: Vec::new(),
        source_line: 1,
    }])
    .unwrap();
    let mut err = Vec::new();

    // Register one build; the row binds the archive's bytes.
    let archive = make_archive(&recipe_dir, "leaf", "1.0.0-1");
    let outcome = register_instance(
        &root,
        "leaf",
        &[archive.clone()],
        &retention,
        &BTreeSet::new(),
        &mut err,
    )
    .unwrap();
    assert_eq!(outcome.rows.len(), 1);

    // The index fold round-trips and the wire row carries the hash + size.
    let index = BinpkgIndex::load(&root).unwrap();
    assert_eq!(index.rows, outcome.rows);
    let wire = wire_row(&index.rows[0]);
    let fields: Vec<&str> = wire.split('|').collect();
    assert_eq!(fields.len(), 10, "the §J.4 wire row has ten fields: {wire}");
    assert_eq!(fields[3], archive.file_name().unwrap().to_str().unwrap());
    assert_eq!(fields[4], index.rows[0].sha256);
    assert_eq!(fields[5], index.rows[0].size.to_string());
    let verification = gsa_state::verify_row(&index.rows[0]);
    assert!(verification.agrees());
    assert_eq!(verification.hash, Match::Agree);

    // Run history: append and read the same structure back.
    let rec = record("leaf");
    RunHistory::append(&root, &rec, &mut err).unwrap();
    let (records, corrupt) = RunHistory::read(&root).unwrap();
    assert!(corrupt.is_empty());
    assert_eq!(records, vec![rec.clone()]);
    assert_eq!(records[0].render_machine(), rec.render_machine());

    // The key-value is schema-ready and folds.
    Kv::set(&root, "world", "leaf", &mut err).unwrap();
    assert_eq!(Kv::get(&root, "world").unwrap(), Some("leaf".into()));

    // The health oracle sees a clean side-car.
    let report = check(&root, &[recipe_dir.clone()]).unwrap();
    assert!(report.clean(), "{:?}", report.findings);
    assert_eq!(report.run_records, 1);
    assert_eq!(report.kv_keys, 1);

    // Tamper the archive: the hash binding fires (§J.4).
    let mut bytes = std::fs::read(&archive).unwrap();
    bytes.push(0);
    std::fs::write(&archive, &bytes).unwrap();
    let report = check(&root, &[recipe_dir]).unwrap();
    assert!(!report.clean());
    assert!(report
        .findings
        .iter()
        .any(|f| f.render().starts_with("hash-mismatch ")));
}

#[test]
fn state_root_creation_failures_name_the_remedy() {
    // A state root whose path is a plain file cannot be created — the error
    // must name `--state-dir` (contract §J.3), never fall back silently.
    let dir = scratch("remedy");
    let blocked = dir.join("not-a-dir");
    std::fs::write(&blocked, "x").unwrap();
    let err = StateRoot::open(&blocked).unwrap_err();
    let message = err.to_string();
    assert!(
        message.contains("--state-dir"),
        "the failure names the remedy: {message}"
    );
}
