//! The canonical recipe store (plan-gsa-isolation.md W3): the build user's
//! WORKING COPY of the recipe repository at the resolved store root
//! (`gsa_model::config::recipe_root` — `GSA_RECIPES_DIR` > gsa.conf
//! `recipe_dir` > `~/.local/share/gsa/recipes`), fetched on demand and
//! never hand-edited (the user's dev checkout is edit-only; the `project`
//! config key is the dev override). `gsa -Sy` refreshes it.
//!
//! The store is BUILD-USER working data by design (2026-10-17 relocation):
//! build-domain tools (makepkg, `updpkgsums`, `makepkg --printsrcinfo`,
//! recipe-eval bash) run as the build user and must be able to write where
//! they run — a root-owned store under the state root made every one of
//! them refuse (`updpkgsums` → anchoring-refused). So after every root-side
//! git clone/fetch/reset the store tree is handed to the build user
//! recursively, and a legacy `<state>/recipes` is MOVED to the resolved
//! root once (`.git` and any dirty worktree survive the move — production
//! carries uncommitted sync rewrites there). `--state-dir`/`GSA_STATE_DIR`
//! therefore never implies the store location; the state root keeps only
//! engine state. The `recipes.last-fetch` stamp stays in the state root
//! (it is state, not store).
//!
//! Git child processes always carry `GIT_CONFIG_COUNT=0` (agent shells
//! inject git config that breaks git operations).

use std::path::{Path, PathBuf};
use std::process::Command;

/// The resolved store directory (no side effects): `recipe_root` above.
pub fn store_dir() -> Result<PathBuf, String> {
    gsa_model::config::recipe_root(&gsa_model::config::load()?)
}

/// The legacy pre-relocation store below the state root. Migration source
/// only — nothing resolves it as a store any more.
fn legacy_store_dir(state_dir: &Path) -> PathBuf {
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

/// Resolve the store, moving a legacy `<state>/recipes` into place when the
/// resolved root is absent. Returns the store plus ONE note the caller
/// prints (moved / stale-legacy); when neither tree exists the fetch path
/// creates the store at the resolved root.
pub fn ensure_store(state_dir: &Path) -> Result<(PathBuf, Option<String>), String> {
    let store = store_dir()?;
    let legacy = legacy_store_dir(state_dir);
    if !legacy.exists() {
        return Ok((store, None));
    }
    if store.exists() {
        // Never delete the legacy tree — it is the operator's call. The
        // resolved store stays authoritative either way.
        let note = format!(
            "legacy recipe store {} is stale and was left in place — the store lives at {}",
            legacy.display(),
            store.display()
        );
        return Ok((store, Some(note)));
    }
    if let Some(parent) = store.parent() {
        create_owned_levels(parent)?;
    }
    move_tree(&legacy, &store).map_err(|e| {
        format!(
            "cannot move the legacy recipe store {} to {}: {e} — move it manually or run `sudo gsa -Sy` once",
            legacy.display(),
            store.display()
        )
    })?;
    // The store is the build user's working copy by design (module docs):
    // a legacy root-owned tree must come out of the move as build-user data.
    gsa_model::privilege::own_to_build_user(&store)
        .map_err(|e| format!("cannot hand {} to the build user: {e}", store.display()))?;
    let note = format!(
        "recipe store moved to {} (was {}; build-user-owned since 2026-10-17)",
        store.display(),
        legacy.display()
    );
    Ok((store, Some(note)))
}

/// `mv` semantics at the syscall level: rename(2) first (atomic, and a
/// dirty worktree — `.git` and uncommitted sync rewrites alike — survives
/// byte-for-byte), falling back to `mv` where rename cannot reach (a
/// cross-device state root and store).
fn move_tree(from: &Path, to: &Path) -> Result<(), String> {
    if let Err(rename_err) = std::fs::rename(from, to) {
        let out = Command::new("mv")
            .arg("--")
            .arg(from)
            .arg(to)
            .output()
            .map_err(|e| format!("rename: {rename_err}; cannot run mv: {e}"))?;
        if !out.status.success() {
            return Err(format!(
                "rename: {rename_err}; mv: {}",
                String::from_utf8_lossy(&out.stderr).trim()
            ));
        }
    }
    Ok(())
}

/// Create missing levels of `dir` one at a time, handing over only the
/// levels the engine itself brings into existence — never a recursive
/// chown of pre-existing (user-configured) parents (the class-b rule
/// gsa-build's makepkg cache handoff enforces too).
fn create_owned_levels(dir: &Path) -> Result<(), String> {
    let mut missing: Vec<&Path> = Vec::new();
    let mut cursor = dir;
    while !cursor.exists() {
        missing.push(cursor);
        cursor = cursor
            .parent()
            .ok_or_else(|| format!("cannot resolve the parent of {}", dir.display()))?;
    }
    for path in missing.into_iter().rev() {
        match std::fs::create_dir(path) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(format!("cannot create {}: {error}", path.display())),
        }
        gsa_model::privilege::own_to_build_user(path)
            .map_err(|e| format!("cannot hand {} to the build user: {e}", path.display()))?;
    }
    Ok(())
}

/// Fetch the store: clone on first use, `fetch origin HEAD` + hard reset on
/// later calls (the store is never hand-edited, so a hard reset is safe).
/// Returns the store path and the checked-out revision. Callers resolve
/// through [`ensure_store`] first and print its note; this re-ensure is
/// idempotent (the legacy tree is gone after a move) and keeps direct
/// callers safe.
pub fn fetch(state_dir: &Path, recipe_url: &str) -> Result<(PathBuf, String), String> {
    let (store, _note) = ensure_store(state_dir)?;
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
    if let Some(parent) = store.parent() {
        create_owned_levels(parent)?;
    }
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
    // The store is the build user's working copy by design (module docs):
    // this clone runs on the engine side (root under a privileged run) and
    // must not leave the tree root-owned.
    gsa_model::privilege::own_to_build_user(&store)
        .map_err(|e| format!("cannot hand {} to the build user: {e}", store.display()))?;
    let head = git(&store, &["rev-parse", "HEAD"])?;
    touch_stamp(state_dir)?;
    Ok((store, head))
}

/// Refresh an existing store in place. Returns the new HEAD revision.
pub fn refresh(state_dir: &Path, _recipe_url: &str) -> Result<String, String> {
    let (store, _note) = ensure_store(state_dir)?;
    git(&store, &["fetch", "--depth", "1", "origin", "HEAD"])?;
    git(&store, &["reset", "--hard", "FETCH_HEAD"])?;
    // The reset writes as the engine (root under a privileged run): the
    // store is the build user's working copy by design (module docs).
    gsa_model::privilege::own_to_build_user(&store)
        .map_err(|e| format!("cannot hand {} to the build user: {e}", store.display()))?;
    touch_stamp(state_dir)?;
    git(&store, &["rev-parse", "HEAD"])
}
