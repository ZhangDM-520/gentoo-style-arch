//! The lane's pending-receipt guard (contract §K.3/§H.3): a `--lane-job`
//! whose run-stopping receipt is already on file at the spawn boundary never
//! hands a build to makepkg — it settles `interrupted-mid-build` under the
//! receipt's own lane code. Before the guard, the build started AFTER the
//! supervisor's one-shot group TERM, escaped it, and ran untouched until the
//! grace SIGKILL — a death whose cause names no signal.
//!
//! The hold is a FIFO at the per-package log path: the lane opens that log
//! between the guard's two checkpoints and blocks there until a reader
//! exists, and the test opens the reader only AFTER the receipt is recorded —
//! so whichever checkpoint fires, makepkg cannot have been spawned before
//! the signal. One test in this binary on purpose: it installs process-global
//! signal handlers and moves the process cwd.

use std::ffi::CString;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::PathBuf;
use std::time::{Duration, Instant};

use gsa_build::lane::run_lane_job;
use gsa_model::LaneOutcome;
use gsa_sched::signals;

extern "C" {
    fn mkfifo(path: *const std::ffi::c_char, mode: u32) -> i32;
}

/// Scratch tree under the harness `$TMPDIR` (fixture convention).
fn scratch() -> PathBuf {
    let dir = std::env::temp_dir().join(format!("gsa-lane-interrupt-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    for sub in ["config", "packages/p1", "bin", "state/logs"] {
        std::fs::create_dir_all(dir.join(sub)).unwrap();
    }
    dir
}

/// The synthetic workspace plus the stub `makepkg` whose only job is to
/// prove it was (not) spawned: it drops a marker and exits cleanly.
fn workspace() -> (PathBuf, PathBuf) {
    let ws = scratch();
    std::fs::write(
        ws.join("config/build-defaults.conf"),
        "lanes=1\njobs=1\nintensity=low\nmemory_per_job_gib=3\ncore_memory_per_job_gib=4\nreserved_memory_gib=2\n",
    )
    .unwrap();
    std::fs::write(
        ws.join("config/topology.conf"),
        "# One record per package: id|path|groups|edges[|tags]\np1|packages/p1|git|\n",
    )
    .unwrap();
    std::fs::write(ws.join("config/abi-exclusions.conf"), "# empty registry\n").unwrap();
    std::fs::write(
        ws.join("packages/p1/PKGBUILD"),
        "pkgname=p1\npkgver=1.0.0\npkgrel=1\narch=(any)\nsource=(https://example.invalid/p1-1.0.0.tar.gz)\n",
    )
    .unwrap();
    let marker = ws.join("makepkg-spawned");
    let stub = ws.join("bin/makepkg");
    std::fs::write(
        &stub,
        format!(
            "#!/usr/bin/env bash\nprintf 'spawned\\n' >'{}'\nexit 0\n",
            marker.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o755)).unwrap();
    (ws, marker)
}

#[test]
fn a_pending_receipt_never_spawns_makepkg_and_settles_interrupted() {
    let (ws, marker) = workspace();
    let result_path = ws.join("state/runs/test/p1.result");
    std::fs::create_dir_all(result_path.parent().unwrap()).unwrap();
    // The FIFO hold: the lane's log open blocks here until a reader exists.
    let log_path = ws.join("state/logs/p1.log");
    let fifo = CString::new(log_path.display().to_string()).unwrap();
    assert_eq!(
        unsafe { mkfifo(fifo.as_ptr(), 0o644) },
        0,
        "mkfifo must create the log hold"
    );

    std::env::set_var("GSA_STATE_DIR", ws.join("state"));
    std::env::set_var("GSA_BUILD_DIR", ws.join("cache"));
    std::env::set_var(
        "PATH",
        format!("{}:{}", ws.join("bin").display(), std::env::var("PATH").unwrap()),
    );
    std::env::set_current_dir(&ws).unwrap();
    // Install the receipt handlers BEFORE any signal can be sent: a default
    // disposition SIGTERM would take the test harness with it.
    signals::install_receipt_handlers();

    let args: Vec<String> = vec![
        "p1".to_string(),
        result_path.display().to_string(),
        "1".to_string(),
    ];
    let lane = std::thread::spawn(move || {
        let mut err: Vec<u8> = Vec::new();
        let rc = run_lane_job(&args, &mut err);
        (rc, err)
    });

    // The receipt is recorded while the lane is held at the log open — past
    // the first checkpoint, before the spawn boundary's second one.
    std::thread::sleep(Duration::from_millis(300));
    assert!(
        signals::send_signal(std::process::id() as i32, signals::SIGTERM),
        "self-signal must deliver"
    );
    let deadline = Instant::now() + Duration::from_secs(5);
    while signals::received_signal() == 0 && Instant::now() < deadline {
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(
        signals::received_signal(),
        signals::SIGTERM,
        "the receipt must be on file before the lane is released"
    );
    // Release the lane's log open — O_NONBLOCK so a lane that stood down
    // before reaching the FIFO can never wedge the reader.
    let hold = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(0o4000)
        .open(&log_path)
        .expect("the FIFO hold must open");

    let (rc, err) = lane.join().expect("the lane thread must finish");
    let err = String::from_utf8_lossy(&err);
    assert_eq!(
        rc,
        LaneOutcome::Term.code(),
        "a pending receipt settles under its own lane code (§K.3): {err}"
    );
    assert!(
        !marker.exists(),
        "makepkg must never spawn under a pending receipt (§K.3)"
    );
    let result = gsa_sched::codec::read_published(&result_path, "p1").expect("the row must publish");
    assert_eq!(
        (result.code, result.reason.as_str()),
        (LaneOutcome::Term, "interrupted-mid-build"),
        "the interrupted row vocabulary: {result:?}"
    );
    drop(hold);
    let _ = std::fs::remove_dir_all(&ws);
}
