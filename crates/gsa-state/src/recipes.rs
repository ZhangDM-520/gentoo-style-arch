//! The canonical recipe store (docs/plans/plan-gsa-isolation.md W3): the build user's
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
//! inject git config that breaks git operations). A refresh also re-points
//! the store's `origin` at the requested `recipe_url` when the two disagree
//! (only the first-use clone ever honoured that URL, so a repointed
//! `DEFAULT_RECIPE_URL` or `recipe_url` would otherwise keep fetching the old
//! repository); a matching origin runs the plain fetch/hard-reset silently.

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
    // The state root may not exist yet on a first `-Sy` (a fresh
    // `--state-dir`): create it root-owned (when privileged) via
    // `create_dir_all`, never handing the state root to the build user, and
    // open `recipes.last-fetch` through `ownership_gate` (rule 19 / §J.5).
    std::fs::create_dir_all(state_dir)
        .map_err(|e| format!("cannot create {}: {e}", state_dir.display()))?;
    let stamp = stamp_path(state_dir);
    let mut err = Vec::new();
    let file = crate::ownership_gate(&stamp, &mut err)
        .map_err(|e| format!("cannot gate {}: {e}", stamp.display()))?;
    if !err.is_empty() {
        eprint!("{}", String::from_utf8_lossy(&err));
    }
    file.set_modified(std::time::SystemTime::now())
        .map_err(|e| format!("cannot timestamp {}: {e}", stamp.display()))
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
        // The retarget note is the `-Sy` surface's: an on-demand fetch already
        // announces itself ("recipe store fetched: … at <head>") and the
        // caller of this function has no note channel.
        let (head, _note) = refresh(state_dir, recipe_url)?;
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

/// Refresh an existing store in place. Returns the new HEAD revision plus the
/// one note the caller prints (origin retargeted / origin added), if any —
/// `None` when the store's origin already answers `recipe_url`.
pub fn refresh(state_dir: &Path, recipe_url: &str) -> Result<(String, Option<String>), String> {
    let (store, _note) = ensure_store(state_dir)?;
    let note = match retarget_origin(&store, recipe_url) {
        Ok(note) => note,
        Err(error) => Some(format!("warning: cannot retarget origin: {error}")),
    };
    git(&store, &["fetch", "--depth", "1", "origin", "HEAD"])?;
    git(&store, &["reset", "--hard", "FETCH_HEAD"])?;
    // The reset writes as the engine (root under a privileged run): the
    // store is the build user's working copy by design (module docs).
    gsa_model::privilege::own_to_build_user(&store)
        .map_err(|e| format!("cannot hand {} to the build user: {e}", store.display()))?;
    touch_stamp(state_dir)?;
    let head = git(&store, &["rev-parse", "HEAD"])?;
    Ok((head, note))
}

/// Point the store's `origin` at `recipe_url` when it disagrees. Only the
/// first-use clone ever honoured that URL, so a repointed
/// `DEFAULT_RECIPE_URL` (or a `recipe_url` config change) kept fetching the
/// old repository — silently. Returns the note the caller prints; `None` when
/// the origin already matches, and an empty `recipe_url` is ignored rather
/// than written.
fn retarget_origin(store: &Path, recipe_url: &str) -> Result<Option<String>, String> {
    let wanted = recipe_url.trim();
    if wanted.is_empty() {
        return Ok(None);
    }
    let current = origin_url(store)?;
    if current.as_deref() == Some(wanted) {
        return Ok(None);
    }
    match current {
        // A store with no origin at all gets one through the same seam.
        Some(_) => git(store, &["remote", "set-url", "origin", wanted])?,
        None => git(store, &["remote", "add", "origin", wanted])?,
    };
    Ok(Some(format!(
        "recipe store origin retargeted: {} → {wanted}",
        current.as_deref().unwrap_or("(none)")
    )))
}

/// `remote.origin.url`, or `None` when the store has no origin configured.
fn origin_url(store: &Path) -> Result<Option<String>, String> {
    let out = Command::new("git")
        .arg("-C")
        .arg(store)
        .args(["config", "--get", "remote.origin.url"])
        .env("GIT_CONFIG_COUNT", "0")
        .output()
        .map_err(|e| format!("cannot run git: {e}"))?;
    match out.status.code() {
        Some(0) => Ok(Some(
            String::from_utf8_lossy(&out.stdout).trim().to_string(),
        )),
        // `git config --get` exits 1 for an unset key: no origin, not an error.
        Some(1) => Ok(None),
        _ => Err(format!(
            "git config --get remote.origin.url failed: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("gsa-state-recipes-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn touch_stamp_refuses_symlink_at_stamp_path() {
        let dir = scratch("touch-symlink");
        let state = dir.join("state");
        std::fs::create_dir_all(&state).unwrap();
        let victim = dir.join("victim");
        std::fs::write(&victim, b"untouched").unwrap();
        std::os::unix::fs::symlink(&victim, stamp_path(&state)).unwrap();

        let err = touch_stamp(&state).expect_err("symlinked recipes.last-fetch must be refused");
        assert!(
            err.contains("gate") || err.contains("symlink") || err.contains("Too many"),
            "{err}"
        );
        assert_eq!(std::fs::read(&victim).unwrap(), b"untouched");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn refresh_warns_on_retarget_failure_and_continues_fetch() {
        let dir = scratch("retarget-warn");
        let upstream = dir.join("upstream.git");
        let seed = dir.join("seed");
        let state = dir.join("state");
        let store_target = dir.join("store");
        std::fs::create_dir_all(&upstream).unwrap();
        std::fs::create_dir_all(&seed).unwrap();
        std::fs::create_dir_all(&state).unwrap();

        let prev_recipes_dir = std::env::var_os("GSA_RECIPES_DIR");
        std::env::set_var("GSA_RECIPES_DIR", &store_target);
        struct EnvGuard(Option<std::ffi::OsString>);
        impl Drop for EnvGuard {
            fn drop(&mut self) {
                match self.0.take() {
                    Some(v) => std::env::set_var("GSA_RECIPES_DIR", v),
                    None => std::env::remove_var("GSA_RECIPES_DIR"),
                }
            }
        }
        let _guard = EnvGuard(prev_recipes_dir);

        let run_git = |cwd: &Path, args: &[&str]| {
            let out = Command::new("git")
                .arg("-C")
                .arg(cwd)
                .args(args)
                .env("GIT_CONFIG_COUNT", "0")
                .env("GIT_AUTHOR_NAME", "t")
                .env("GIT_AUTHOR_EMAIL", "t@t")
                .env("GIT_COMMITTER_NAME", "t")
                .env("GIT_COMMITTER_EMAIL", "t@t")
                .output()
                .unwrap();
            assert!(
                out.status.success(),
                "git {:?} failed: {}",
                args,
                String::from_utf8_lossy(&out.stderr)
            );
            String::from_utf8_lossy(&out.stdout).trim().to_string()
        };

        run_git(&upstream, &["init", "--bare", "--initial-branch=main"]);
        run_git(&seed, &["init", "--initial-branch=main"]);
        std::fs::write(seed.join("f"), "v1\n").unwrap();
        run_git(&seed, &["add", "f"]);
        run_git(&seed, &["commit", "-m", "c1"]);
        run_git(
            &seed,
            &["remote", "add", "origin", &upstream.display().to_string()],
        );
        run_git(&seed, &["push", "-u", "origin", "main"]);
        run_git(&upstream, &["symbolic-ref", "HEAD", "refs/heads/main"]);

        // Seed store at c1.
        let (store, c1) = fetch(&state, &upstream.display().to_string()).unwrap();
        assert_eq!(store, store_target);

        // Advance upstream to c2.
        std::fs::write(seed.join("f"), "v2\n").unwrap();
        run_git(&seed, &["commit", "-am", "c2"]);
        run_git(&seed, &["push", "origin", "main"]);

        // Place a git config lock so `remote set-url` fails when a different URL
        // is requested, while `origin` in `.git/config` still fetches from `upstream`.
        std::fs::write(store.join(".git/config.lock"), b"").unwrap();
        let bogus_url = format!("{}/other.git", dir.display());
        let (head, note) =
            refresh(&state, &bogus_url).expect("retarget failure must warn and continue fetch");
        let note = note.expect("retarget warning expected");
        assert!(note.contains("warning"), "{note}");
        assert_ne!(head, c1, "fetch still advanced HEAD");
        let _ = std::fs::remove_file(store.join(".git/config.lock"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
