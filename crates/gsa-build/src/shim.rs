//! The `PACMAN` shim (contract §K.3): makepkg's own dependency installs are
//! pacman transactions and must share the engine's transaction lock, run
//! through `sudo -n` only — the engine never prompts, and neither does
//! anything it execs.
//!
//! Read-only pacman queries (`-Q*`, `-T`, search/info listings) run unlocked
//! and unprivileged; every transaction queues on the state-root mutex. The
//! system `db.lck` is never touched by the shim (makepkg/pacman own it).

use std::path::{Path, PathBuf};

/// The shim path under the state root. A fixture or run without it (Phase 2
/// build-only runs need no pacman) simply never exports `PACMAN`.
pub fn shim_path(state_dir: &Path) -> PathBuf {
    state_dir.join("locks").join("pacman-shim")
}

/// The transaction mutex the shim serializes on (§K.3: one `pacman` at a
/// time).
pub fn mutex_path(state_dir: &Path) -> PathBuf {
    state_dir.join("locks").join("pacman-mutex")
}

/// Write the shim once, executable, owned by the privileged runner (rule 19:
/// engine state is root-owned). Idempotent: an existing shim is left as
/// it is (its baked paths never change for one state root).
pub fn ensure_pacman_shim(state_dir: &Path) -> Result<PathBuf, String> {
    let path = shim_path(state_dir);
    if path.is_file() {
        return Ok(path);
    }
    let mutex = mutex_path(state_dir);
    let body = format!(
        "#!/bin/sh\n\
         # gsa PACMAN shim — generated; makepkg dependency installs share the\n\
         # engine transaction lock and run through sudo -n (never prompts).\n\
         P=/usr/bin/pacman\n\
         q=\n\
         t=\n\
         for a in \"$@\"; do\n\
         \x20   case $a in\n\
         \x20       -Q*|-T|-Ss|-Si|-Sg|-Sl|-Sp|--query|--deptest) q=1 ;;\n\
         \x20       -S*|-U*|-R*|-D*|-F*|--sync|--remove|--upgrade|--database|--files) t=1 ;;\n\
         \x20   esac\n\
         done\n\
         if [ -n \"$q\" ] && [ -z \"$t\" ]; then\n\
         \x20   exec \"$P\" \"$@\"\n\
         fi\n\
         sudo -n flock -x -w 600 {mutex} \"$P\" \"$@\"\n\
         rc=$?\n\
         if [ \"$rc\" -eq 1 ]; then\n\
         \x20   echo \"gsa pacman shim: transaction failed (sudo -n never prompts)\" >&2\n\
         fi\n\
         exit \"$rc\"\n",
        mutex = mutex.display()
    );
    std::fs::write(&path, body).map_err(|e| format!("cannot write {}: {e}", path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755))
            .map_err(|e| format!("cannot chmod {}: {e}", path.display()))?;
    }
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shim_is_written_once_and_executable() {
        let dir = std::env::temp_dir().join(format!("gsa-shim-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("locks")).unwrap();
        let path = ensure_pacman_shim(&dir).unwrap();
        assert!(path.is_file());
        let body = std::fs::read_to_string(&path).unwrap();
        assert!(body.contains("sudo -n"), "the shim must never prompt");
        assert!(body.contains("flock -x"));
        assert!(
            body.contains("db.lck") == false,
            "the shim never names db.lck"
        );
        // Idempotent: a second call leaves the file alone.
        std::fs::write(&path, "#!/bin/sh\ntrue\n").unwrap();
        ensure_pacman_shim(&dir).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "#!/bin/sh\ntrue\n");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
