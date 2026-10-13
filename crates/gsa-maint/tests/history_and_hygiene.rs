//! Run history and log hygiene (contract §J.1/§B.7): run ids are 1-based
//! history positions, `show` re-renders the stored record unchanged, the
//! bounded retention keeps unfinished runs forever, and log retention keeps
//! the newest N files per `<pkg>.log*` stem.

mod common;

use common::{append_run, run_record, Fixture};
use gsa_maint::{history, hygiene};
use gsa_state::RunHistory;

#[test]
fn run_ids_are_one_based_history_positions() {
    let fx = Fixture::new("history-ids");
    let state = fx.state();
    for pkg in ["alpha", "beta", "gamma"] {
        append_run(&state, &run_record(pkg, &[]));
    }

    let rows = history::list_rows(&state).unwrap();
    common::assert_row_grammar(&rows);
    let ids: Vec<&str> = rows.iter().map(|r| r.subject.as_str()).collect();
    assert_eq!(ids, vec!["1", "2", "3"]);
    assert!(
        rows[0].reason.contains("gsa -B alpha"),
        "{}",
        rows[0].reason
    );
    assert!(
        rows[2].reason.contains("gsa -B gamma"),
        "{}",
        rows[2].reason
    );

    let error = history::show(&state, 0).expect_err("run ids start at 1");
    assert!(error.contains("unknown run id 0"), "{error}");
    let error = history::show(&state, 4).expect_err("out of range");
    assert!(error.contains("unknown run id 4"), "{error}");
    assert!(error.contains("1..=3"), "{error}");
}

#[test]
fn show_rerenders_the_stored_record_unchanged() {
    let fx = Fixture::new("history-show");
    let state = fx.state();
    let record = run_record("alpha", &["alpha", "beta"]);
    append_run(&state, &record);
    append_run(&state, &run_record("gamma", &[]));

    // What was stored is what is re-rendered: the same render_machine the
    // run emitted (contract §H.1).
    assert_eq!(history::show(&state, 1).unwrap(), record.render_machine());
    assert_eq!(
        history::show(&state, 2).unwrap(),
        run_record("gamma", &[]).render_machine()
    );
}

#[test]
fn history_retention_keeps_unfinished_runs() {
    let fx = Fixture::new("history-retention");
    let state = fx.state();
    // Record 1 is UNFINISHED (its continuation still owes `alpha`); the
    // 51 records after it are finished.
    append_run(&state, &run_record("alpha", &["alpha"]));
    for n in 2..=52 {
        append_run(&state, &run_record(&format!("done-{n}"), &[]));
    }
    let before = std::fs::read(state.runs_path()).unwrap();

    // Dry-run: the plan names every decision and compacts nothing.
    let plan = history::prune(&state, false).unwrap();
    common::assert_row_grammar(&plan);
    let kept = common::find_row(&plan, "1", "keep").expect("unfinished run kept");
    assert_eq!(kept.reason, "resume-pointer remaining-unfinished");
    assert!(common::find_row(&plan, "2", "prune").is_some());
    assert_eq!(
        std::fs::read(state.runs_path()).unwrap(),
        before,
        "a dry-run never compacts the store"
    );

    // Applied: RUN_HISTORY_KEEP newest finished records + every unfinished
    // record survive; only the oldest finished record (id 2) is dropped.
    let rows = history::prune(&state, true).unwrap();
    assert!(common::find_row(&rows, "2", "pruned").is_some());
    let (records, corrupt) = RunHistory::read(&state).unwrap();
    assert!(corrupt.is_empty());
    assert_eq!(records.len(), history::RUN_HISTORY_KEEP + 1);
    let commands: Vec<String> = records
        .iter()
        .map(|r| r.continuation.command.clone())
        .collect();
    assert!(
        commands[0].contains("gsa -B alpha"),
        "the unfinished record survives at the head"
    );
    assert!(
        commands.iter().any(|c| c == "gsa -B done-52"),
        "the newest finished record survives"
    );
    assert!(
        !commands.iter().any(|c| c == "gsa -B done-2"),
        "the oldest finished record is dropped"
    );
    // The ids renumber over the compacted history.
    let rows = history::list_rows(&state).unwrap();
    assert_eq!(rows.len(), history::RUN_HISTORY_KEEP + 1);
    assert_eq!(rows.last().unwrap().subject, "51");
}

#[test]
fn log_retention_keeps_the_newest_per_stem() {
    let fx = Fixture::new("hygiene-logs");
    let logs = fx.state_dir.join("logs");
    std::fs::create_dir_all(&logs).unwrap();
    // Explicit mtimes (no sleeps): newer files get larger timestamps.
    for (name, stamp) in [
        ("alpha.log", 400),
        ("alpha.log.1", 300),
        ("alpha.log.2", 200),
        ("alpha.log.3", 100),
        ("alpha.log.4", 50),
        ("beta.log", 150),
    ] {
        let path = logs.join(name);
        std::fs::write(&path, format!("content of {name}\n")).unwrap();
        common::set_mtime(&path, stamp);
    }
    std::fs::write(logs.join("notes.txt"), "not a log\n").unwrap();

    let entries = hygiene::log_entries(&fx.state_dir);
    let names: Vec<String> = entries
        .iter()
        .map(|e| e.path.file_name().unwrap().to_string_lossy().into_owned())
        .collect();
    assert_eq!(
        names,
        vec![
            "alpha.log",
            "alpha.log.1",
            "alpha.log.2",
            "alpha.log.3",
            "alpha.log.4",
            "beta.log",
        ],
        "rotated siblings share the stem; newest first; non-logs excluded"
    );
    assert!(entries.iter().all(|e| e.pkg == "alpha" || e.pkg == "beta"));

    // Dry-run plans per file and removes nothing.
    let plan = hygiene::prune_logs(&fx.state_dir, 2, false);
    common::assert_row_grammar(&plan);
    assert_eq!(
        common::rows_with(&plan, &logs.join("alpha.log").display().to_string(), "keep").len(),
        1
    );
    assert_eq!(
        common::rows_with(
            &plan,
            &logs.join("alpha.log.2").display().to_string(),
            "prune"
        )
        .len(),
        1
    );
    assert!(logs.join("alpha.log.4").exists(), "dry-run removes nothing");

    // Applied: the two newest per stem survive.
    let rows = hygiene::prune_logs(&fx.state_dir, 2, true);
    assert!(common::has_row(
        &rows,
        &logs.join("alpha.log").display().to_string(),
        "keep"
    ));
    assert!(common::has_row(
        &rows,
        &logs.join("alpha.log.2").display().to_string(),
        "pruned"
    ));
    for kept in ["alpha.log", "alpha.log.1", "beta.log"] {
        assert!(logs.join(kept).exists(), "{kept} kept");
    }
    for gone in ["alpha.log.2", "alpha.log.3", "alpha.log.4"] {
        assert!(!logs.join(gone).exists(), "{gone} pruned");
    }
    assert!(
        logs.join("notes.txt").exists(),
        "non-logs are never touched"
    );
}

#[test]
fn tail_lines_reads_the_tail() {
    let fx = Fixture::new("hygiene-tail");
    let logs = fx.state_dir.join("logs");
    std::fs::create_dir_all(&logs).unwrap();
    let log = logs.join("alpha.log");
    let body: String = (1..=30).map(|n| format!("line-{n}\n")).collect();
    std::fs::write(&log, body).unwrap();

    let tail = hygiene::tail_lines(&log).unwrap();
    let expected: String = (11..=30)
        .map(|n| format!("line-{n}"))
        .collect::<Vec<_>>()
        .join("\n");
    assert_eq!(tail, expected, "the last {} lines", hygiene::TAIL_LINES);
    assert_eq!(hygiene::LOG_KEEP_DEFAULT, 3);

    let error = hygiene::tail_lines(&logs.join("absent.log")).expect_err("missing log");
    assert!(error.contains("cannot read"), "{error}");
}
