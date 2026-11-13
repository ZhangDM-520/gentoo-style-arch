//! Integration tests for CLI preflight, privilege gating, and store sync ordering
//! (`F-CLI-04`, `F-CLI-05`, `F-CLI-06`): usage errors must fire BEFORE privilege
//! gates and BEFORE mutating the recipe store.

use std::path::{Path, PathBuf};
use std::process::Command;

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("gsa-cli-preflight-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

fn setup_workspace(root: &Path) {
    std::fs::create_dir_all(root.join("config")).unwrap();
    std::fs::create_dir_all(root.join("packages/p1")).unwrap();
    std::fs::write(
        root.join("config/build-defaults.conf"),
        "lanes=1\njobs=1\nintensity=low\nmemory_per_job_gib=3\ncore_memory_per_job_gib=4\nreserved_memory_gib=2\n",
    )
    .unwrap();
    std::fs::write(
        root.join("config/topology.conf"),
        "# id|path|groups|edges\np1|packages/p1|git|\n",
    )
    .unwrap();
    std::fs::write(root.join("config/abi-exclusions.conf"), "# empty\n").unwrap();
    std::fs::write(
        root.join("packages/p1/PKGBUILD"),
        "pkgname=p1\npkgver=1.0.0\npkgrel=1\narch=(any)\nsource=(https://example.invalid/p1-1.0.0.tar.gz)\n",
    )
    .unwrap();
}

fn run_gsa(ws: &Path, state: &Path, build: &Path, args: &[&str]) -> (i32, String, String) {
    let out = Command::new(env!("CARGO_BIN_EXE_gsa"))
        .args(args)
        .env("GSA_RECIPES_DIR", ws)
        .env("GSA_STATE_DIR", state)
        .env("GSA_BUILD_DIR", build)
        .env("GIT_CONFIG_COUNT", "0")
        .output()
        .expect("spawn gsa");
    (
        out.status.code().unwrap_or(-1),
        String::from_utf8_lossy(&out.stdout).into_owned(),
        String::from_utf8_lossy(&out.stderr).into_owned(),
    )
}

#[test]
fn f_cli_04_usage_preflight_runs_before_privilege_gate() {
    if gsa_model::privilege::effective_uid() == 0 {
        return;
    }
    let dir = scratch("cli04");
    let ws = dir.join("recipes");
    let state = dir.join("state");
    let build = dir.join("build");
    std::fs::create_dir_all(&state).unwrap();
    std::fs::create_dir_all(&build).unwrap();
    setup_workspace(&ws);

    for args in [
        &["-B", "--lanes", "0", "p1"][..],
        &["-B", "--prefetch-ahead", "bogus", "p1"][..],
        &["-B", "--vcs-skip-tolerance", "bogus", "p1"][..],
        &["-Su", "--vcs-skip-tolerance", "bogus"][..],
    ] {
        let (rc, _out, err) = run_gsa(&ws, &state, &build, args);
        assert_eq!(
            rc, 2,
            "{args:?} must fail with usage rc 2 before privilege gate, got {rc}: {err}"
        );
    }

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn f_cli_05_sy_validates_selection_and_privilege_before_refreshing_store() {
    if gsa_model::privilege::effective_uid() == 0 {
        return;
    }
    let dir = scratch("cli05");
    let ws = dir.join("recipes");
    let state = dir.join("state");
    let build = dir.join("build");
    std::fs::create_dir_all(&state).unwrap();
    std::fs::create_dir_all(&build).unwrap();
    setup_workspace(&ws);

    // Initialize ws as a git repo pointing at a nonexistent remote so any
    // refresh attempt leaves a telltale error or creates recipes.last-fetch.
    assert!(Command::new("git")
        .args(["init", "-q"])
        .current_dir(&ws)
        .env("GIT_CONFIG_COUNT", "0")
        .status()
        .unwrap()
        .success());
    assert!(Command::new("git")
        .args([
            "remote",
            "add",
            "origin",
            "file:///nonexistent/gsa-remote.git"
        ])
        .current_dir(&ws)
        .env("GIT_CONFIG_COUNT", "0")
        .status()
        .unwrap()
        .success());

    let (rc, _out, err) = run_gsa(&ws, &state, &build, &["-Sy", "nonexistent-pkg"]);
    assert_eq!(
        rc, 2,
        "-Sy unknown package must exit 2 before refresh/privilege gate, got {rc}: {err}"
    );
    assert!(
        !state.join("recipes.last-fetch").exists(),
        "recipes.last-fetch must not be created before privilege gate"
    );

    let (rc, _out, err) = run_gsa(&ws, &state, &build, &["-Sy", "p1"]);
    assert_eq!(
        rc, 3,
        "unprivileged -Sy p1 must hit privilege gate rc 3 without refreshing store, got {rc}: {err}"
    );
    assert!(
        !state.join("recipes.last-fetch").exists(),
        "recipes.last-fetch must not be touched by unprivileged -Sy"
    );
    assert!(
        !err.contains("gsa: failed to fetch") && !err.contains("sync_recipes"),
        "store refresh must not execute before privilege gate: {err}"
    );

    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn f_cli_06_maint_validates_syntax_and_selection_before_privilege_gate() {
    if gsa_model::privilege::effective_uid() == 0 {
        return;
    }
    let dir = scratch("cli06");
    let ws = dir.join("recipes");
    let state = dir.join("state");
    let build = dir.join("build");
    std::fs::create_dir_all(&state).unwrap();
    std::fs::create_dir_all(&build).unwrap();
    setup_workspace(&ws);

    for args in [
        &["-Ml", "--keep", "abc"][..],
        &["-Mh", "--show", "0"][..],
        &["-Ms", "--add", "bad/name", "p1"][..],
        &["-Ms", "--add", "@stale", "p1"][..],
        &["-Mw", "--add"][..],
        &["-Mc", "nonexistent-pkg"][..],
        &["-Ms", "--add", "myset", "nonexistent-pkg"][..],
        &["-Mw", "--remove", "nonexistent-pkg"][..],
    ] {
        let (rc, _out, err) = run_gsa(&ws, &state, &build, args);
        assert_eq!(
            rc, 2,
            "{args:?} must fail with usage rc 2 before privilege gate, got {rc}: {err}"
        );
    }

    let _ = std::fs::remove_dir_all(&dir);
}
