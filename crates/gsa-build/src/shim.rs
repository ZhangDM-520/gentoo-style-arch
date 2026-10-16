//! The `PACMAN` shim (contract §K.3): makepkg's own dependency installs are
//! pacman transactions and must share the engine's transaction lock, run
//! through `sudo -n` only — the engine never prompts, and neither does
//! anything it execs.
//!
//! Read-only pacman queries (`-Q*`, `-T`, search/info listings) run unlocked
//! and unprivileged; every transaction queues on the state-root mutex. The
//! system `db.lck` is never touched by the shim (makepkg/pacman own it).
//!
//! The generated body is a root-executed shell script, so the one piece of
//! engine data baked into it — the mutex path — is rendered through
//! [`shell_single_quote`]: inside `'…'` no byte of a `--state-dir` value is
//! ever shell syntax, so spaces break nothing and `$(…)`/`;`/newlines can
//! never become code execution in the shim.

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

/// POSIX-sh single-quote one value for a generated script: inside `'…'`
/// nothing is interpreted, and the only breakout byte (`'`) is
/// closed-reopened (`'\''`), so the result is always literal data.
fn shell_single_quote(value: &str) -> String {
    format!("'{}'", value.replace('\'', r"'\''"))
}

/// Write the shim once, executable, owned by the privileged runner (rule 19:
/// engine state is root-owned). Idempotent: an existing shim is left as
/// it is (its baked paths never change for one state root).
pub fn ensure_pacman_shim(state_dir: &Path) -> Result<PathBuf, String> {
    let path = shim_path(state_dir);
    if path.is_file() {
        return Ok(path);
    }
    let mutex = shell_single_quote(&mutex_path(state_dir).display().to_string());
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
        mutex = mutex
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

    #[test]
    fn shim_quoting_never_lets_a_state_dir_become_shell_syntax() {
        // A hostile state root: spaces, a command substitution and a quote
        // in the path. The generated shim is root-executed — the path must
        // stay literal data, never shell syntax.
        let base = std::env::temp_dir().join(format!("gsa-shim-inject-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&base);
        std::fs::create_dir_all(&base).unwrap();
        let marker = base.join("pwned");
        let hostile = base.join("state $(touch pwned); 'quote& space");
        std::fs::create_dir_all(hostile.join("locks")).unwrap();
        let path = ensure_pacman_shim(&hostile).unwrap();
        let body = std::fs::read_to_string(&path).unwrap();
        // The generated body must parse as shell at all ...
        let syntax = std::process::Command::new("sh")
            .arg("-n")
            .arg(&path)
            .status()
            .expect("sh runs");
        assert!(syntax.success(), "the generated shim must parse: {body}");
        // ... and a transaction must run without ever executing the
        // substitution embedded in the mutex path.
        let stub = base.join("bin");
        std::fs::create_dir_all(&stub).unwrap();
        let sudo = stub.join("sudo");
        std::fs::write(&sudo, "#!/bin/sh\nprintf '%s|' \"$@\" >>\"$GSA_SHIM_LOG\"\nexit 0\n")
            .unwrap();
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&sudo, std::fs::Permissions::from_mode(0o755)).unwrap();
        }
        let log = base.join("shim.log");
        let status = std::process::Command::new("sh")
            .arg(&path)
            .arg("-S")
            .arg("--noconfirm")
            .arg("pkg")
            .current_dir(&base)
            .env(
                "PATH",
                format!("{}:{}", stub.display(), std::env::var("PATH").unwrap_or_default()),
            )
            .env("GSA_SHIM_LOG", &log)
            .status()
            .expect("sh runs the shim");
        assert!(status.success(), "the shim transaction must succeed");
        assert!(
            !marker.exists(),
            "the state-dir path executed as shell — injection into the root shim!"
        );
        let seen = std::fs::read_to_string(&log).unwrap_or_default();
        assert!(
            seen.contains(&mutex_path(&hostile).display().to_string()),
            "the mutex must reach flock as one literal argv item: {seen}"
        );
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn shell_quoting_escapes_the_only_breakout_byte() {
        assert_eq!(shell_single_quote("/plain/path"), "'/plain/path'");
        assert_eq!(shell_single_quote("a b"), "'a b'");
        assert_eq!(shell_single_quote("a'b"), r"'a'\''b'");
        assert_eq!(shell_single_quote("$(reboot); x"), "'$(reboot); x'");
    }
}
