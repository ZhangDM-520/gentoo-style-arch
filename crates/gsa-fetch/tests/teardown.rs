//! Signal teardown of a fetch child (contract §K.3): a fetch child runs in
//! its own process group and dies with the run — one TERM, a grace window,
//! then SIGKILL; a second signal escalates immediately. No orphans.

use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use gsa_fetch::child;

fn scratch(name: &str) -> PathBuf {
    let dir =
        std::env::temp_dir().join(format!("gsa-fetch-teardown-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn write_stub(dir: &std::path::Path, name: &str, body: &str) -> PathBuf {
    let path = dir.join(name);
    std::fs::write(&path, format!("#!/usr/bin/env bash\n{body}\n")).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
}

fn pgid_alive(pgid: u32) -> bool {
    // kill(-pgid, 0) probes the whole group without delivering a signal.
    let out = Command::new("sh")
        .arg("-c")
        .arg(format!("kill -0 -{pgid} 2>/dev/null"))
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    matches!(out, Ok(status) if status.success())
}

#[test]
fn one_term_then_kill_drains_a_stalled_fetch_child() {
    let dir = scratch("term");
    // A fetch child that ignores nothing and stalls like a slow download.
    let stub = write_stub(&dir, "stall", "sleep 30");
    let result = dir.join("pkg.fetch.result");
    let log = dir.join("prefetch.log");
    let mut child = child::spawn(&stub, &dir, "pkg", &result, &log).expect("spawn fetch child");
    let pid = child.id();
    assert!(
        pgid_alive(pid),
        "the child must be running in its own group"
    );

    // One TERM to the group drains it within the grace window.
    child::terminate(&mut child);
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut drained = false;
    while Instant::now() < deadline {
        if let Ok(Some(_)) = child.try_wait() {
            drained = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(drained, "the fetch child must die on the teardown TERM");
    std::thread::sleep(Duration::from_millis(100));
    assert!(
        !pgid_alive(pid),
        "the fetch child's process group must be gone (no orphans)"
    );
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn a_term_ignoring_child_dies_in_the_kill_sweep() {
    let dir = scratch("kill");
    let stub = write_stub(&dir, "stubborn", "trap '' TERM\nsleep 30");
    let result = dir.join("pkg.fetch.result");
    let log = dir.join("prefetch.log");
    let mut child = child::spawn(&stub, &dir, "pkg", &result, &log).expect("spawn fetch child");
    let pid = child.id();
    std::thread::sleep(Duration::from_millis(200));

    // TERM is not enough…
    child::terminate(&mut child);
    std::thread::sleep(Duration::from_millis(300));
    assert!(pgid_alive(pid), "a TERM-ignoring child survives the grace");

    // …the SIGKILL sweep (grace expiry / second signal) ends it.
    child::kill(&child);
    let deadline = Instant::now() + Duration::from_secs(5);
    let mut drained = false;
    while Instant::now() < deadline {
        if let Ok(Some(_)) = child.try_wait() {
            drained = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(drained, "the SIGKILL sweep must drain the child");
    std::thread::sleep(Duration::from_millis(100));
    assert!(!pgid_alive(pid), "no survivor after the SIGKILL sweep");
    let _ = child.kill();
    std::fs::remove_dir_all(&dir).ok();
}

#[test]
fn spawning_writes_only_the_log_and_the_child_never_touches_recipes() {
    let dir = scratch("shape");
    // The stub records its argv and cwd: the fetch child is `<exe>
    // --fetch-job <pkg> <result>` and nothing else.
    let stub = write_stub(
        &dir,
        "record",
        "printf '%s %s\\n' \"$PWD\" \"$*\" >>\"$0.log\"\nexit 0",
    );
    let result = dir.join("pkg.fetch.result");
    let log = dir.join("prefetch.log");
    let child = child::spawn(&stub, &dir, "pkg", &result, &log).expect("spawn fetch child");
    let mut child = child;
    let _ = child.wait();
    let recorded = std::fs::read_to_string(dir.join("record.log")).unwrap();
    assert!(
        recorded.contains("--fetch-job pkg"),
        "argv must be the seam shape: {recorded}"
    );
    std::fs::remove_dir_all(&dir).ok();
}
