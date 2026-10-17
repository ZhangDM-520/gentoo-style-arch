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
//! build-failed`. The classification reads the child's own end state first:
//! a makepkg killed by a signal carries its cause (HUP/INT/TERM → the lane
//! codes 129/143/130, §K.3; any other signal → `failed 1
//! build-killed-by-signal-<n>`), and this child's own received signal is
//! the fallback only for a normal makepkg exit — a late signal never
//! downgrades a good build. A park marker published before the build began
//! → `parked 98 <reason>` (§F.1, spawn-to-build race); an unusable state
//! root or build-cache layout fails the lane (`failed 1 state-dir-unusable`
//! / `failed 1 layout-unusable`, §J.3/§J.2) instead of building in the
//! wrong place. A receipt already pending at either spawn boundary never
//! hands a build to a tearing-down run (`interrupted-mid-build` instead) — a
//! makepkg started there escapes the supervisor's one-shot group TERM and
//! lives until the grace SIGKILL, whose death names no cause.

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

/// The lane's state root (contract §J.3): `--state-dir` is supervisor-side;
/// the lane child reads the SAME precedence through the model's one resolver
/// (`GSA_STATE_DIR` — the supervisor's export — then the gsa.conf layers,
/// then `/var/lib/gsa`). A second, simplified copy here once answered
/// env-or-`/var/lib/gsa` only, so a `--lane-job` invoked outside the
/// supervisor silently got the wrong root; a resolution failure is fatal
/// for the lane (§J.3 has no silent fallback).
pub fn lane_state_dir() -> Result<PathBuf, String> {
    gsa_model::config::resolve_state_dir(None)
}

/// Classify one makepkg end state (contract §F.1) from the CHILD's own exit
/// status first: a successful build stays `ok` even when a late signal
/// reached this lane, and a makepkg that died to a signal carries its own
/// cause — HUP/INT/TERM map to the lane codes 129/143/130, anything else
/// (an OOM-killer SIGKILL, a compiler SIGSEGV) is a failed build whose
/// reason NAMES the signal, never plain `build-failed`. A normal child exit
/// under the lane's own received run-stopping signal is an INTERRUPT
/// (§H.3, `signal-abort-lock.sh` phase 2): a lane TERMed mid-build reports
/// `interrupted-mid-build` even when its makepkg happened to finish — the
/// run aborted this package. (The reverse sliver — a signal landing after
/// makepkg exited but before classification — errs the same conservative
/// way: the row says unfinished and the continuation re-runs it, `-s`
/// skipping the rebuild; closing it would need exit-vs-receipt timestamps.)
/// The §H.3 interrupt class of this child's own receipt: a run-stopping
/// signal this lane received settles `interrupted-mid-build` under its lane
/// code (129/143/130, §K.3) — the one vocabulary every interrupt row uses,
/// whether the build ended, never started, or is being torn down here.
fn received_interrupt(received: i32) -> Option<(gsa_model::LaneOutcome, &'static str)> {
    use gsa_model::LaneOutcome;
    match received {
        gsa_sched::signals::SIGHUP => Some((LaneOutcome::Hup, "interrupted-mid-build")),
        gsa_sched::signals::SIGINT => Some((LaneOutcome::Int, "interrupted-mid-build")),
        gsa_sched::signals::SIGTERM => Some((LaneOutcome::Term, "interrupted-mid-build")),
        _ => None,
    }
}

pub fn classify_build_exit(
    exit: gsa_sched::signals::ChildExit,
    received: i32,
) -> (gsa_model::LaneOutcome, String) {
    use gsa_model::LaneOutcome;
    use gsa_sched::signals::ChildExit;
    let received_class = received_interrupt(received);
    match exit {
        ChildExit::Signaled(sig) => match sig {
            gsa_sched::signals::SIGHUP => (LaneOutcome::Hup, "interrupted-mid-build".to_string()),
            gsa_sched::signals::SIGINT => (LaneOutcome::Int, "interrupted-mid-build".to_string()),
            gsa_sched::signals::SIGTERM => (LaneOutcome::Term, "interrupted-mid-build".to_string()),
            other => (
                LaneOutcome::Failed,
                format!("build-killed-by-signal-{other}"),
            ),
        },
        ChildExit::Exited(code) => match received_class {
            Some((outcome, reason)) => (outcome, reason.to_string()),
            None => match code {
                0 => (LaneOutcome::Ok, "ok".to_string()),
                // The deferral stand-in (see the module docs): the only
                // Phase-2 path that emits `defer` (§F.1).
                99 => (LaneOutcome::Defer, "source-unfetchable".to_string()),
                _ => (LaneOutcome::Failed, "build-failed".to_string()),
            },
        },
    }
}

fn usage(message: &str, err: &mut dyn Write) -> i32 {
    let _ = writeln!(err, "gsa --lane-job: {message}");
    2
}

/// A receipt already pending when makepkg is about to be handed the build:
/// the run aborted this package — settle `interrupted-mid-build` under the
/// receipt's own lane code and never spawn. A build started under a pending
/// receipt escapes the supervisor's one-shot group TERM (it did not exist
/// yet) and runs until the grace SIGKILL — a death whose cause cannot be
/// attributed back to the interrupt.
fn settle_pending_receipt(pkg: &str, result_path: &Path, err: &mut dyn Write) -> Option<i32> {
    let (code, reason) = received_interrupt(signals::received_signal())?;
    let result = LaneResult::new(pkg, code, 0, reason).unwrap();
    match codec::publish(result_path, &result) {
        Ok(()) => Some(code.code()),
        Err(message) => {
            let _ = writeln!(err, "gsa --lane-job: {message}");
            Some(LaneOutcome::Lost.code())
        }
    }
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

    let state_dir = match lane_state_dir() {
        Ok(dir) => dir,
        Err(message) => {
            // §J.3: a state root that cannot be resolved is fatal for the
            // lane — never a silent fallback to another root.
            let _ = writeln!(err, "gsa --lane-job: {message}");
            let result = LaneResult::new(pkg, LaneOutcome::Failed, 0, "state-dir-unusable").unwrap();
            return match codec::publish(&result_path, &result) {
                Ok(()) => LaneOutcome::Failed.code(),
                Err(message) => {
                    let _ = writeln!(err, "gsa --lane-job: {message}");
                    LaneOutcome::Lost.code()
                }
            };
        }
    };

    // Signal honesty (§K.3): receipt by this child is reported through the
    // lane codes when the build ends.
    signals::install_receipt_handlers();
    // First spawn boundary: a receipt already on file means the run is
    // tearing down — no build may begin under it.
    if let Some(rc) = settle_pending_receipt(pkg, &result_path, err) {
        return rc;
    }

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
    // Rule 19: forensics appends guard best-effort — a gate refusal is
    // announced, then the attempt continues under the same no-symlink open
    // discipline; only its own failure settles the lane (log-unwritable).
    let log = match gsa_sched::lock::open_state_append(&log_path, err) {
        Ok(file) => file,
        Err(refusal) => {
            let _ = writeln!(err, "gsa --lane-job: {refusal}");
            match gsa_sched::lock::open_state_append_nofollow(&log_path) {
                Ok(file) => file,
                Err(error) => {
                    let _ = writeln!(
                        err,
                        "gsa --lane-job: cannot write build log {}: {error}",
                        log_path.display()
                    );
                    let result =
                        LaneResult::new(pkg, LaneOutcome::Failed, 0, "log-unwritable").unwrap();
                    match codec::publish(&result_path, &result) {
                        Ok(()) => return LaneOutcome::Failed.code(),
                        Err(message) => {
                            let _ = writeln!(err, "gsa --lane-job: {message}");
                            return LaneOutcome::Lost.code();
                        }
                    }
                }
            }
        }
    };

    // ── the build: makepkg in the recipe directory (§K.1) ────────────────
    let start = Instant::now();
    let mut cmd = match crate::makepkg::makepkg_command(&recipe_dir, jobs, flags, &state_dir) {
        Ok(cmd) => cmd,
        Err(message) => {
            // §J.2/§J.3's one layout error policy: fatal for the lane with
            // the message, never a build that lands beside the recipe and
            // reports success.
            let _ = writeln!(err, "gsa --lane-job: {message}");
            let _ = writeln!(&log, "gsa --lane-job: {message}");
            let result = LaneResult::new(pkg, LaneOutcome::Failed, 0, "layout-unusable").unwrap();
            return match codec::publish(&result_path, &result) {
                Ok(()) => LaneOutcome::Failed.code(),
                Err(message) => {
                    let _ = writeln!(err, "gsa --lane-job: {message}");
                    LaneOutcome::Lost.code()
                }
            };
        }
    };
    let log_out = log.try_clone();
    let log_err = log.try_clone();
    cmd.stdin(Stdio::null());
    if let Ok(out) = log_out {
        cmd.stdout(Stdio::from(out));
    }
    if let Ok(err_file) = log_err {
        cmd.stderr(Stdio::from(err_file));
    }
    // Second spawn boundary: startup work (recipe resolution, layout
    // creation) is long enough for a teardown signal to land in it — a
    // receipt here must still keep makepkg from ever starting.
    if let Some(rc) = settle_pending_receipt(pkg, &result_path, err) {
        return rc;
    }
    // Wait in a receipt-aware loop (§K.3), not a bare `status()`: a lane that
    // merely records its signal and then blocks leaves its makepkg building
    // through the whole teardown until the grace SIGKILL. On receipt, a
    // makepkg that ESCAPED the sweep's single group TERM (forked after that
    // TERM was delivered) gets one TERM at its own pid so this package stops
    // now; a makepkg that was already in the group received that TERM and
    // must NOT be re-signalled — a second receipt breaks §K.3's one-TERM
    // discipline (signal-abort-lock.sh counts receipts). The child pid, never
    // the group, targets the straggler alone; anything it leaves behind dies
    // with the grace SIGKILL sweep. Then reap and classify as ever.
    let spawn_at_ns = signals::monotonic_ns();
    let status = match cmd.spawn() {
        Ok(mut child) => loop {
            match child.try_wait() {
                Ok(Some(status)) => break Ok(status),
                Ok(None) => {
                    if signals::received_signal() != 0 {
                        if signals::received_signal_at_ns() < spawn_at_ns {
                            let _ = signals::send_signal(child.id() as i32, signals::SIGTERM);
                        }
                        break child.wait();
                    }
                    std::thread::sleep(std::time::Duration::from_millis(50));
                }
                Err(error) => break Err(error),
            }
        },
        Err(error) => Err(error),
    };
    let dur = start.elapsed().as_secs();

    let (code, reason) = match status {
        Ok(status) => {
            // §F.1's classification is the child's own exit status first
            // (`ChildExit`), with this lane's received signal only as the
            // normal-exit fallback — a late signal never downgrades a good
            // build, and a signal death the lane never received still
            // reports its cause.
            let exit = match std::os::unix::process::ExitStatusExt::signal(&status) {
                Some(sig) => signals::ChildExit::Signaled(sig),
                None => signals::ChildExit::Exited(status.code().unwrap_or(1)),
            };
            classify_build_exit(exit, signals::received_signal())
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

#[cfg(test)]
mod tests {
    use super::*;

    /// Env-mutating tests serialize: `GSA_CONF`/`GSA_STATE_DIR` are
    /// process-global.
    static ENV_TEST_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    #[test]
    fn lane_state_dir_follows_the_j3_precedence() {
        let _guard = ENV_TEST_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let dir = std::env::temp_dir().join(format!("gsa-lane-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let conf = dir.join("gsa.conf");
        let state = dir.join("state");
        std::fs::write(&conf, format!("state_dir = {}\n", state.display())).unwrap();
        let saved_conf = std::env::var("GSA_CONF").ok();
        let saved_state = std::env::var("GSA_STATE_DIR").ok();
        std::env::set_var("GSA_CONF", &conf);
        std::env::remove_var("GSA_STATE_DIR");
        // Without the supervisor's export, the gsa.conf layer decides
        // (§J.3) — never a hard-coded `/var/lib/gsa`.
        let from_conf = lane_state_dir();
        // The supervisor's GSA_STATE_DIR export stays above the config.
        std::env::set_var("GSA_STATE_DIR", "/from-env");
        let from_env = lane_state_dir();
        // Restoration keeps the process-global env as it was found, before
        // any assertion can panic.
        match saved_conf {
            Some(v) => std::env::set_var("GSA_CONF", v),
            None => std::env::remove_var("GSA_CONF"),
        }
        match saved_state {
            Some(v) => std::env::set_var("GSA_STATE_DIR", v),
            None => std::env::remove_var("GSA_STATE_DIR"),
        }
        assert_eq!(
            from_conf.unwrap(),
            state,
            "the gsa.conf state_dir layer must decide when GSA_STATE_DIR is unset"
        );
        assert_eq!(from_env.unwrap(), PathBuf::from("/from-env"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn build_exit_classification_honours_the_interrupt_contract_and_signal_causes() {
        use gsa_model::LaneOutcome;
        use gsa_sched::signals::ChildExit;
        // §H.3: a normal child exit under the lane's received run-stopping
        // signal is an interrupt (signal-abort-lock.sh phase 2 pins rc 143
        // + `interrupted-mid-build` even when makepkg finished).
        assert_eq!(
            classify_build_exit(ChildExit::Exited(0), signals::SIGTERM),
            (LaneOutcome::Term, "interrupted-mid-build".to_string())
        );
        assert_eq!(
            classify_build_exit(ChildExit::Exited(0), signals::SIGINT),
            (LaneOutcome::Int, "interrupted-mid-build".to_string())
        );
        // Without a receipt the child's own status stands: ok / defer /
        // failed.
        assert_eq!(
            classify_build_exit(ChildExit::Exited(0), 0),
            (LaneOutcome::Ok, "ok".to_string())
        );
        assert_eq!(
            classify_build_exit(ChildExit::Exited(99), 0),
            (LaneOutcome::Defer, "source-unfetchable".to_string())
        );
        // A signal death carries its own cause — even one this lane never
        // received (the OOM-killer case is not plain `build-failed`).
        assert_eq!(
            classify_build_exit(ChildExit::Signaled(signals::SIGKILL), 0),
            (
                LaneOutcome::Failed,
                "build-killed-by-signal-9".to_string()
            )
        );
        assert_eq!(
            classify_build_exit(ChildExit::Signaled(signals::SIGTERM), 0),
            (LaneOutcome::Term, "interrupted-mid-build".to_string())
        );
        // The lane's own receipt classifies any normal exit (a teardown
        // SIGTERM that makepkg caught and exited non-zero under is an
        // interrupt, not a build failure).
        assert_eq!(
            classify_build_exit(ChildExit::Exited(1), signals::SIGTERM),
            (LaneOutcome::Term, "interrupted-mid-build".to_string())
        );
        assert_eq!(
            classify_build_exit(ChildExit::Exited(1), 0),
            (LaneOutcome::Failed, "build-failed".to_string())
        );
        assert_eq!(
            classify_build_exit(ChildExit::Exited(99), 0),
            (LaneOutcome::Defer, "source-unfetchable".to_string())
        );
    }
}
