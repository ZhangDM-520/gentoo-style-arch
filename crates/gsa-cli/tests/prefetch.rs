//! Fetch-ahead integration through the real engine binary (contract §B.8
//! `--prefetch-ahead`/`--no-prefetch`, §D.1 `--fetch-job`, docs/adr/
//! 0004-prefetch-advisory.md). Everything synthetic: a `$TMPDIR`-style
//! workspace under `std::env::temp_dir()`, stub `makepkg` on PATH — no
//! network, no pacman, no sudo, no host state.
//!
//! Pinned here:
//!   a. advisory semantics: a prefetch `failed` never gates the run — the
//!      build rows succeed, the run exits 0, and the warning surfaces in the
//!      prose section plus the `prefetch-warnings: 1` scalar (owner decision
//!      5: never rows, never a format bump).
//!   b. SIGINT teardown (§K.3): a stalled fetch child dies with the run —
//!      rc 130, the full run record still renders, and no `--fetch-job`
//!      process survives.

use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("gsa-cli-prefetch-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// The synthetic workspace: `p1` with consumer `p2` (one build-order edge),
/// literal-PKGBUILD recipes the strict scan reads, a stub `makepkg` that
/// logs FETCH/BUILD events with nanosecond timestamps.
fn workspace(name: &str) -> PathBuf {
    let ws = scratch(name);
    std::fs::create_dir_all(ws.join("config")).unwrap();
    std::fs::create_dir_all(ws.join("packages/p1")).unwrap();
    std::fs::create_dir_all(ws.join("packages/p2")).unwrap();
    std::fs::create_dir_all(ws.join("bin")).unwrap();
    std::fs::create_dir_all(ws.join("srcdest")).unwrap();
    std::fs::write(
        ws.join("config/build-defaults.conf"),
        "lanes=1\njobs=1\nintensity=low\nmemory_per_job_gib=3\ncore_memory_per_job_gib=4\nreserved_memory_gib=2\nstate_dir=auto\n",
    )
    .unwrap();
    std::fs::write(
        ws.join("config/topology.conf"),
        "# One record per package: id|path|groups|edges[|tags]\np1|packages/p1|git|\np2|packages/p2|git|p1\n",
    )
    .unwrap();
    std::fs::write(ws.join("config/abi-exclusions.conf"), "# empty registry\n").unwrap();
    for pkg in ["p1", "p2"] {
        std::fs::write(
            ws.join(format!("packages/{pkg}/PKGBUILD")),
            format!(
                "pkgname={pkg}\npkgver=1.0.0\npkgrel=1\narch=(any)\nsource=(https://example.invalid/{pkg}-1.0.0.tar.gz)\n"
            ),
        )
        .unwrap();
    }
    let stub = ws.join("bin/makepkg");
    std::fs::write(
        &stub,
        r#"#!/usr/bin/env bash
set -u
log=${GSA_FAKE_FETCH_LOG:?}
id=$(basename "$PWD")
if [[ " $* " == *" --verifysource "* ]]; then
    printf '%s FETCH_START %s\n' "$(date +%s%N)" "$id" >>"$log"
    if [[ ${GSA_FAKE_FETCH_STALL:-} == "$id" ]]; then sleep 30; fi
    if [[ ${GSA_FAKE_FETCH_FAIL:-} == "$id" ]]; then
        printf '%s FETCH_END %s\n' "$(date +%s%N)" "$id" >>"$log"
        echo "stub: verify failure" >&2
        exit 1
    fi
    printf '%s FETCH_END %s\n' "$(date +%s%N)" "$id" >>"$log"
    exit 0
fi
printf '%s BUILD_START %s\n' "$(date +%s%N)" "$id" >>"$log"
sleep "${GSA_FAKE_BUILD_SECONDS:-0}"
printf '%s BUILD_END %s\n' "$(date +%s%N)" "$id" >>"$log"
: >"$PWD/$id-1.0.0-1-any.pkg.tar.zst"
exit 0
"#,
    )
    .unwrap();
    std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o755)).unwrap();
    ws
}

/// The engine as root through real `sudo -n` (contract §B.10: `-B` is a
/// mutating verb and requires root). `env` carries PATH, the stubs and every
/// knob explicitly so they survive sudo's env_reset; the engine then drops
/// its build-side commands back to the build user via `setpriv`, so the
/// stubs run as the test user and write their logs unprivileged.
fn engine_command(ws: &Path, extra: &[(&str, &str)]) -> Command {
    let mut cmd = Command::new("sudo");
    cmd.arg("-n").arg("env");
    cmd.arg(format!(
        "PATH={}/bin:{}",
        ws.display(),
        std::env::var("PATH").unwrap()
    ));
    cmd.arg(format!("SRCDEST={}", ws.join("srcdest").display()));
    cmd.arg(format!("GSA_FAKE_FETCH_LOG={}", ws.join("fetch.log").display()));
    cmd.arg("_GSA_FETCH_RETRY_S=0");
    for (key, value) in extra {
        cmd.arg(format!("{key}={value}"));
    }
    cmd.current_dir(ws)
        .arg(env!("CARGO_BIN_EXE_gsa"))
        .args([
            "-B",
            "--state-dir",
            &ws.join("state").display().to_string(),
            "p1",
        ]);
    cmd
}

/// Root-owned scratch teardown (a sudo run leaves root-owned state behind).
fn cleanup(ws: &Path) {
    let _ = std::process::Command::new("sudo")
        .args(["-n", "rm", "-rf", "--"])
        .arg(ws)
        .output();
}

/// Live processes of THIS workspace whose argv still carries `extra` (the
/// fetch-child identity: `--fetch-job`). Scoped to the workspace path so two
/// tests running in one process never see each other's children.
fn survivors(ws: &Path, extra: &str) -> Vec<u32> {
    let mut pids = Vec::new();
    let Ok(entries) = std::fs::read_dir("/proc") else {
        return pids;
    };
    let ws = ws.to_str().unwrap_or_default();
    for entry in entries.flatten() {
        let name = entry.file_name();
        let Some(pid) = name.to_str().and_then(|s| s.parse::<u32>().ok()) else {
            continue;
        };
        if pid == std::process::id() {
            continue;
        }
        let Ok(cmdline) = std::fs::read(entry.path().join("cmdline")) else {
            continue;
        };
        let text = String::from_utf8_lossy(&cmdline).replace('\0', " ");
        if text.contains(ws) && text.contains(extra) {
            pids.push(pid);
        }
    }
    pids
}

#[test]
fn a_prefetch_failure_is_advisory_and_never_gates_the_run() {
    let ws = workspace("advisory");
    let mut cmd = engine_command(
        &ws,
        &[("GSA_FAKE_FETCH_FAIL", "p2"), ("GSA_FAKE_BUILD_SECONDS", "1")],
    );
    let out = cmd.output().expect("engine must run");
    let stdout = String::from_utf8_lossy(&out.stdout);
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert_eq!(
        out.status.code(),
        Some(0),
        "advisory prefetch failure must not gate the run\nstdout: {stdout}\nstderr: {stderr}"
    );
    // Both builds succeeded — the lane is authoritative (§H.3 `ok`).
    assert!(stdout.contains("p1 succeeded"), "{stdout}");
    assert!(stdout.contains("p2 succeeded"), "{stdout}");
    // Owner decision 5: the advisory summary surface + scalar, never rows.
    // The captured run is machine mode, so the surface is the leveled kv
    // summary (render_prefetch_notes), not the human `Prefetch warnings …`
    // frame — the human frame is a TTY surface.
    assert!(
        stdout.contains("WARNING prefetch-summary advisory=1 note=lanes_retry_at_build_time"),
        "{stdout}"
    );
    assert!(
        stdout.contains("WARNING prefetch pkg=p2 verdict=failed reason=fetch-failed"),
        "{stdout}"
    );
    assert!(stdout.contains("prefetch-warnings: 1"), "{stdout}");
    assert!(
        !stdout.contains("p2 failed 1"),
        "never a run-record row: {stdout}"
    );
    // The advisory log exists and names the failure (owner decision 5).
    let log = std::fs::read_to_string(ws.join("state/prefetch.log")).unwrap_or_default();
    assert!(log.contains("attempt 1 failed"), "prefetch.log: {log}");
    cleanup(&ws);
}

#[test]
fn b_sigint_tears_down_the_fetch_child_with_the_run() {
    let ws = workspace("sigint");
    let mut cmd = engine_command(
        &ws,
        &[("GSA_FAKE_FETCH_STALL", "p2"), ("GSA_FAKE_BUILD_SECONDS", "30")],
    );
    cmd.stdout(Stdio::from(
        std::fs::File::create(ws.join("stdout.txt")).unwrap(),
    ))
    .stderr(Stdio::from(
        std::fs::File::create(ws.join("stderr.txt")).unwrap(),
    ));
    let mut child = cmd.spawn().expect("engine must spawn");

    // Wait until the fetch child is demonstrably in flight.
    let log_path = ws.join("fetch.log");
    let deadline = Instant::now() + Duration::from_secs(15);
    let mut fetch_in_flight = false;
    while Instant::now() < deadline {
        if let Ok(log) = std::fs::read_to_string(&log_path) {
            if log.contains("FETCH_START p2") {
                fetch_in_flight = true;
                break;
            }
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(
        fetch_in_flight,
        "the fetch child must start before the signal"
    );

    // SIGINT the engine: the run must tear down lanes AND the fetch child.
    let status = Command::new("kill")
        .args(["-INT", &child.id().to_string()])
        .status()
        .expect("kill must run");
    assert!(status.success(), "kill -INT must deliver");

    let deadline = Instant::now() + Duration::from_secs(30);
    let mut code = None;
    while Instant::now() < deadline {
        if let Ok(Some(status)) = child.try_wait() {
            code = status.code();
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    assert_eq!(code, Some(130), "an interrupted run exits 130 (§G.1)");

    // The full run record renders on the interrupt path (§H.1), and the
    // teardown rows are honest (§I.3): p1 settled as the interrupt — never
    // as `failed 125 - lane-lost` — while the run's rc stays 130.
    let stdout = std::fs::read_to_string(ws.join("stdout.txt")).unwrap_or_default();
    assert!(stdout.contains("--- run record begin ---"), "{stdout}");
    assert!(stdout.contains("rc: 130"), "{stdout}");
    assert!(stdout.contains("p1 interrupted"), "{stdout}");
    assert!(
        !stdout.contains("lane-lost"),
        "a teardown never settles a lost reap anomaly: {stdout}"
    );

    // No orphan fetch child, no orphan makepkg of one (§K.3). The fetch
    // child's argv carries this workspace's result path, so the workspace
    // needle finds `--fetch-job` processes and their stub children alike.
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut left = survivors(&ws, "--fetch-job");
    while Instant::now() < deadline && !left.is_empty() {
        std::thread::sleep(Duration::from_millis(100));
        left = survivors(&ws, "--fetch-job");
    }
    assert!(left.is_empty(), "orphan fetch children: {left:?}");
    let left = survivors(&ws, "");
    assert!(
        left.is_empty(),
        "orphan processes of this workspace: {left:?}"
    );
    cleanup(&ws);
}
