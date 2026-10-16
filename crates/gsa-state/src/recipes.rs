//! The canonical recipe store (plan-gsa-isolation.md W3): a gsa-owned
//! checkout of the recipe repository at `<state-dir>/recipes`, fetched on
//! demand and never hand-edited (the user's dev checkout is edit-only; the
//! `project` config key is the dev override). `gsa -Sy` refreshes it.
//!
//! The store follows `resolve_state_dir(None)` — `GSA_STATE_DIR`, the
//! gsa.conf `state_dir` key, then `/var/lib/gsa` — because it is shared
//! content; `--state-dir` is the side-car/runtime-state override and
//! fixtures point `GSA_STATE_DIR` at their scratch root to keep the store
//! hermetic. Git child processes always carry `GIT_CONFIG_COUNT=0` (agent
//! shells inject git config that breaks git operations).

use std::path::{Path, PathBuf};
use std::process::Command;

/// The store directory below a state root.
pub fn store_dir(state_dir: &Path) -> PathBuf {
    state_dir.join("recipes")
}

/// The refresh stamp: touched on every fetch/refresh, read by `stale_hours`.
fn stamp_path(state_dir: &Path) -> PathBuf {
    state_dir.join("recipes.last-fetch")
}

/// Hours since the last store fetch/refresh. `None` when no stamp exists.
pub fn stale_hours(state_dir: &Path) -> Option<u64> {
    let meta = std::fs::metadata(stamp_path(state_dir)).ok()?;
    let age = meta.modified().ok()?.elapsed().ok()?;
    Some(age.as_secs() / 3600)
}

fn git(dir: &Path, args: &[&str]) -> Result<String, String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .env("GIT_CONFIG_COUNT", "0")
        .output()
        .map_err(|e| format!("cannot run git: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "git {} failed: {}",
            args.join(" "),
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    Ok(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

fn touch_stamp(state_dir: &Path) -> Result<(), String> {
    std::fs::write(stamp_path(state_dir), b"")
        .map_err(|e| format!("cannot write {}: {e}", stamp_path(state_dir).display()))
}

/// Fetch the store: clone on first use, `fetch origin HEAD` + hard reset on
/// later calls (the store is never hand-edited, so a hard reset is safe).
/// Returns the store path and the checked-out revision.
pub fn fetch(state_dir: &Path, recipe_url: &str) -> Result<(PathBuf, String), String> {
    let store = store_dir(state_dir);
    if store.join(".git").is_dir() {
        let head = refresh(state_dir, recipe_url)?;
        return Ok((store, head));
    }
    if store.exists() {
        return Err(format!(
            "{} exists but is not a git checkout — refusing to replace it",
            store.display()
        ));
    }
    std::fs::create_dir_all(state_dir)
        .map_err(|e| format!("cannot create {}: {e}", state_dir.display()))?;
    let out = Command::new("git")
        .args(["clone", "--depth", "1", recipe_url])
        .arg(&store)
        .env("GIT_CONFIG_COUNT", "0")
        .output()
        .map_err(|e| format!("cannot run git: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "cannot fetch the recipe store from {recipe_url}: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        ));
    }
    let head = git(&store, &["rev-parse", "HEAD"])?;
    touch_stamp(state_dir)?;
    Ok((store, head))
}

/// Refresh an existing store in place. Returns the new HEAD revision.
pub fn refresh(state_dir: &Path, _recipe_url: &str) -> Result<String, String> {
    let store = store_dir(state_dir);
    git(&store, &["fetch", "--depth", "1", "origin", "HEAD"])?;
    git(&store, &["reset", "--hard", "FETCH_HEAD"])?;
    touch_stamp(state_dir)?;
    git(&store, &["rev-parse", "HEAD"])
}
