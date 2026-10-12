//! The one-shot fetch child's process shape (plan.md §2.1): `exec`-style
//! `<exe> --fetch-job <pkg> <result>` in its OWN process group, niced and
//! ionice'd, output to the run's `prefetch.log` — killed with the run
//! through the same TERM → grace → SIGKILL discipline as lanes (§K.3).

use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};

/// Unadvertised fixture seam class (`_GSA_STOP_GRACE_S` precedent): the
/// nice/ionice levels, overridable only so tests can run without them.
pub const NICE_LEVEL: &str = "10";
pub const IONICE_CLASS: &str = "3";

fn on_path(program: &str) -> bool {
    std::env::var_os("PATH")
        .map(|paths| {
            std::env::split_paths(&paths).any(|dir| {
                let candidate = dir.join(program);
                candidate.is_file()
                    && std::fs::metadata(&candidate)
                        .map(|m| m.permissions().mode() & 0o111 != 0)
                        .unwrap_or(false)
            })
        })
        .unwrap_or(false)
}

extern "C" {
    #[link_name = "kill"]
    fn kill_syscall(pid: i32, sig: i32) -> i32;
}

/// Signal a fetch child's process group (contract §K.3: children run in
/// their own process group; teardown addresses the group).
pub fn signal_group(leader_pid: u32, sig: i32) {
    unsafe {
        kill_syscall(-(leader_pid as i32), sig);
    }
}

/// Spawn one fetch child: `nice -n 10 ionice -c3 <exe> --fetch-job <pkg>
/// <result>` when those helpers exist (network-bound work must never
/// compete with compiles — owner decision 6), else the bare engine. The
/// child runs in its own process group so teardown sweeps it exactly like a
/// lane.
pub fn spawn(
    exe: &Path,
    root: &Path,
    pkg: &str,
    result_path: &Path,
    log_path: &Path,
) -> std::io::Result<Child> {
    if let Some(parent) = log_path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(log_path)?;
    let log_err = log.try_clone()?;

    let mut cmd = if on_path("nice") {
        let mut cmd = Command::new("nice");
        cmd.arg("-n").arg(NICE_LEVEL);
        if on_path("ionice") {
            cmd.arg("ionice").arg("-c").arg(IONICE_CLASS);
        }
        cmd.arg(exe);
        cmd
    } else {
        Command::new(exe)
    };
    cmd.arg("--fetch-job")
        .arg(pkg)
        .arg(result_path)
        .current_dir(root)
        .env("GIT_CONFIG_COUNT", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::from(log))
        .stderr(Stdio::from(log_err))
        .process_group(0);
    cmd.spawn()
}

/// The result file a dispatcher hands one fetch child (the shape the
/// supervisor and the child share — `gsa-build::lane::lane_result_path`'s
/// fetch twin).
pub fn fetch_result_path(run_dir: &Path, pkg: &str) -> PathBuf {
    run_dir.join(format!("{pkg}.fetch.result"))
}

/// One SIGTERM to the child's process group — the exactly-one-TERM
/// discipline the pacman db.lck incident mandated (§K.3). Callers own the
/// grace window and the SIGKILL sweep (`signal_group(pid, SIGKILL)`).
pub fn terminate(child: &mut Child) {
    signal_group(child.id(), 15);
}

/// The SIGKILL sweep for survivors (grace expiry or second-signal
/// escalation).
pub fn kill(child: &Child) {
    signal_group(child.id(), 9);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn result_path_shape_is_distinct_from_lane_results() {
        let path = fetch_result_path(Path::new("/state/runs/r1"), "mesa-git");
        assert_eq!(path, PathBuf::from("/state/runs/r1/mesa-git.fetch.result"));
        assert!(path.to_string_lossy().ends_with(".fetch.result"));
    }
}
