//! The `--lane-job` child entry (contract §D.1): one package, one result
//! file. Positional payload `<pkg> <result-path> <jobs> <flags…>`; control
//! characters rejected, invalid flag/job rejected with rc 2 and a message
//! naming the argument. Exactly one result row crosses the boundary, written
//! through the typed codec with atomic publication (§F.2).
//!
//! Outcome mapping (§F.1): makepkg success → `ok 0`; makepkg exit 99 →
//! `defer 99 source-unfetchable` (the Phase-2 stand-in for the fetch and
//! anchoring gates, which land with `gsa-fetch`/version-sync and are the only
//! other paths allowed to emit deferral); any other exit → `failed 1
//! build-failed`; signal receipt by this child is reported through the lane
//! codes 129/143/130 (§K.3); a park marker published before the build began
//! → `parked 98 <reason>` (§F.1, spawn-to-build race).

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Instant;

use gsa_model::LaneOutcome;
use gsa_sched::codec::{self, LaneResult};
use gsa_sched::signals;

use crate::makepkg::check_flag_payload;

/// The topology id charset asserted at the seam's producer side (a drifted
/// identity must never reach the wire).
fn valid_pkg(s: &str) -> bool {
    !s.is_empty()
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-' | '+'))
}

fn usage(message: &str, err: &mut dyn Write) -> i32 {
    let _ = writeln!(err, "gsa --lane-job: {message}");
    2
}

/// `gsa --lane-job <pkg> <result-path> <jobs> <flags…>` — the lane child.
/// Returns the lane's outcome code (§G.2: a lane's exit code IS its outcome
/// code) or 2 for a bad payload.
pub fn run_lane_job(args: &[String], err: &mut dyn Write) -> i32 {
    // ── argv check (contract §D.1) ────────────────────────────────────────
    if args.len() < 3 {
        return usage(
            "usage: gsa --lane-job <pkg> <result-path> <jobs> <flags…> (missing positionals)",
            err,
        );
    }
    let pkg = &args[0];
    let result_path = PathBuf::from(&args[1]);
    let jobs_raw = &args[2];
    let flags = &args[3..];

    if !valid_pkg(pkg) {
        return usage(&format!("package '{pkg}' is not a valid recipe id"), err);
    }
    if args[1].is_empty() || args[1].chars().any(|c| c.is_control()) {
        return usage(
            &format!(
                "result path '{}' is empty or carries control characters",
                args[1]
            ),
            err,
        );
    }
    let jobs: u32 = match jobs_raw.parse::<u32>() {
        Ok(n) if n >= 1 => n,
        _ => {
            return usage(
                &format!("jobs '{jobs_raw}' must be a positive integer"),
                err,
            )
        }
    };
    if let Err(message) = check_flag_payload(flags) {
        return usage(&message, err);
    }

    // ── workspace + recipe resolution (read-only) ─────────────────────────
    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let Some(root) = crate::find_root(&cwd) else {
        return usage(
            "cannot find config/topology.conf from the current directory upward",
            err,
        );
    };
    let project = match gsa_topo::load_project(&root) {
        Ok(project) => project,
        Err(error) => return usage(&format!("configuration error: {error}"), err),
    };
    let Some(record) = project.topology.get(pkg) else {
        return usage(&format!("unknown recipe '{pkg}'"), err);
    };
    let recipe_dir = root.join(&record.path);

    let state_dir = match std::env::var("GSA_STATE_DIR") {
        Ok(v) if !v.is_empty() => PathBuf::from(v),
        _ => PathBuf::from("/var/lib/gsa"),
    };

    // Signal honesty (§K.3): receipt by this child is reported through the
    // lane codes when the build ends.
    signals::install_receipt_handlers();

    // ── the spawn-to-build race (contract §F.1 `parked 98`) ──────────────
    let marker = PathBuf::from(format!("{}.park", result_path.display()));
    if marker.is_file() {
        let reason = std::fs::read_to_string(&marker)
            .map(|s| s.trim().to_string())
            .unwrap_or_default();
        let reason = if reason.is_empty() || reason.chars().any(|c| c.is_control()) {
            "waits-on-failed".to_string()
        } else {
            reason
        };
        let result = LaneResult::new(pkg, LaneOutcome::Parked, 0, &reason).unwrap();
        return match codec::publish(&result_path, &result) {
            Ok(()) => LaneOutcome::Parked.code(),
            Err(message) => {
                let _ = writeln!(err, "gsa --lane-job: {message}");
                LaneOutcome::Lost.code()
            }
        };
    }

    // ── per-package log (contract §J.1/§K.1: under the state root) ───────
    let log_path = crate::log_path(&state_dir, pkg);
    if let Some(parent) = log_path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    if let Err(message) = gsa_sched::lock::ownership_gate(&log_path, err) {
        let _ = writeln!(err, "gsa --lane-job: {message}");
    }
    let log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path);
    let log = match log {
        Ok(file) => file,
        Err(error) => {
            let _ = writeln!(
                err,
                "gsa --lane-job: cannot write build log {}: {error}",
                log_path.display()
            );
            let result = LaneResult::new(pkg, LaneOutcome::Failed, 0, "log-unwritable").unwrap();
            match codec::publish(&result_path, &result) {
                Ok(()) => return LaneOutcome::Failed.code(),
                Err(message) => {
                    let _ = writeln!(err, "gsa --lane-job: {message}");
                    return LaneOutcome::Lost.code();
                }
            }
        }
    };

    // ── the build: makepkg in the recipe directory (§K.1) ────────────────
    let start = Instant::now();
    let mut cmd = crate::makepkg::makepkg_command(&recipe_dir, jobs, flags, &state_dir);
    let log_out = log.try_clone();
    let log_err = log.try_clone();
    cmd.stdin(Stdio::null());
    if let Ok(out) = log_out {
        cmd.stdout(Stdio::from(out));
    }
    if let Ok(err_file) = log_err {
        cmd.stderr(Stdio::from(err_file));
    }
    let status = cmd.status();
    let dur = start.elapsed().as_secs();

    let (code, reason) = match status {
        Ok(status) => {
            let received = signals::received_signal();
            if received != 0 {
                (
                    match received {
                        signals::SIGHUP => LaneOutcome::Hup,
                        signals::SIGINT => LaneOutcome::Int,
                        _ => LaneOutcome::Term,
                    },
                    "interrupted-mid-build".to_string(),
                )
            } else if status.success() {
                (LaneOutcome::Ok, "ok".to_string())
            } else if status.code() == Some(99) {
                // The deferral stand-in (see the module docs): the only
                // Phase-2 path that emits `defer` (§F.1).
                (LaneOutcome::Defer, "source-unfetchable".to_string())
            } else {
                (LaneOutcome::Failed, "build-failed".to_string())
            }
        }
        Err(error) => {
            let _ = writeln!(err, "gsa --lane-job: cannot run makepkg: {error}");
            (LaneOutcome::Failed, "build-failed".to_string())
        }
    };

    let result = LaneResult::new(pkg, code, dur, &reason).unwrap();
    match codec::publish(&result_path, &result) {
        Ok(()) => code.code(),
        Err(message) => {
            let _ = writeln!(err, "gsa --lane-job: {message}");
            LaneOutcome::Lost.code()
        }
    }
}

/// The `--lane-job` result file a supervisor hands a lane (the shape the
/// supervisor and the child share).
pub fn lane_result_path(run_dir: &Path, pkg: &str) -> PathBuf {
    run_dir.join(format!("{pkg}.result"))
}
