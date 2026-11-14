//! The `PACMAN` shim (contract §K.3): makepkg's own dependency installs are
//! pacman transactions and must share the engine's transaction lock, run
//! through `sudo -n` only — the engine never prompts, and neither does
//! anything it execs.
//!
//! Read-only pacman queries (`-Q*`, `-T`, search/info listings) run unlocked
//! and unprivileged; every transaction queues on the state-root mutex. The
//! system `db.lck` is never touched by the shim (makepkg/pacman own it).
//!
//! The generated body is a root-executed shell script, so the two pieces of
//! engine data baked into it — the mutex path and the target pacman
//! configuration — are rendered through [`shell_single_quote`]: inside `'…'`
//! no byte of a `--state-dir` or `--config` value is ever shell syntax, so
//! spaces break nothing and `$(…)`/`;`/newlines can never become code
//! execution in the shim.
//!
//! The `--config` pair exists because the shim is the ONLY choke point for
//! makepkg's own database reads: `/usr/bin/makepkg` resolves `PACMAN_PATH`
//! from `$PACMAN` and routes every `run_pacman` call through it, so a shim
//! that forgets the configuration made `-T` (the dependency test) and
//! `-S --asdeps` (the missing-dependency install) judge the HOST database
//! while the engine's gates judged the named one — a satisfiable build was
//! refused with "error: target not found" for a package installed in the DB
//! the user named (round-1 review, `I1-sol-4`).

use std::io::{Read, Seek, SeekFrom, Write};
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

/// The generated shim body. `conf` is the run's target pacman configuration
/// (`--config`): when it is `None` the body is byte-identical to the
/// pre-`--config` shim, because an unnamed configuration means the host's
/// database and pacman's own default already names it.
fn shim_body(state_dir: &Path, conf: Option<&Path>) -> String {
    let mutex = shell_single_quote(&mutex_path(state_dir).display().to_string());
    let (bind, apply) = match conf {
        None => (String::new(), String::new()),
        Some(conf) => (
            format!("C={}\n", shell_single_quote(&conf.display().to_string())),
            "# The named configuration rides every call: makepkg's own\n\
             # dependency test (-T) and dependency install (-S --asdeps) are\n\
             # pacman reads/writes too, and they must judge the database the\n\
             # engine's gates judge (§B.8, `--config`).\n\
             set -- --config \"$C\" \"$@\"\n"
                .to_string(),
        ),
    };
    format!(
        "#!/bin/sh\n\
         # gsa PACMAN shim — generated; makepkg dependency installs share the\n\
         # engine transaction lock and run through sudo -n (never prompts).\n\
         P=/usr/bin/pacman\n\
         {bind}\
         q=\n\
         t=\n\
         for a in \"$@\"; do\n\
         \x20   case $a in\n\
         \x20       -Q*|-T|-Ss|-Si|-Sg|-Sl|-Sp|--query|--deptest) q=1 ;;\n\
         \x20       -S*|-U*|-R*|-D*|-F*|--sync|--remove|--upgrade|--database|--files) t=1 ;;\n\
         \x20   esac\n\
         done\n\
         {apply}\
         if [ -n \"$q\" ] && [ -z \"$t\" ]; then\n\
         \x20   exec \"$P\" \"$@\"\n\
         fi\n\
         sudo -n flock -x -w 600 {mutex} \"$P\" \"$@\"\n\
         rc=$?\n\
         if [ \"$rc\" -eq 1 ]; then\n\
         \x20   echo \"gsa pacman shim: transaction failed (sudo -n never prompts)\" >&2\n\
         fi\n\
         exit \"$rc\"\n",
        bind = bind,
        apply = apply,
        mutex = mutex
    )
}

/// Write the shim, executable, owned by the privileged runner (rule 19:
/// engine state is root-owned). Idempotent on the BODY, never on the size: a
/// run that names a different `--config` must not keep reading the previous
/// database through a shim an earlier run left behind. `conf` is made
/// absolute here because makepkg runs with the RECIPE's cwd (§K.1), exactly
/// like every other path handed to it.
pub fn ensure_pacman_shim(state_dir: &Path, conf: Option<&Path>) -> Result<PathBuf, String> {
    let path = shim_path(state_dir);
    let conf = conf.map(gsa_model::config::absolute_for_child);
    let body = shim_body(state_dir, conf.as_deref());
    let mut opts = std::fs::OpenOptions::new();
    opts.read(true).write(true).create(true);
    let mut file = gsa_model::state_gate::open_state_file_with_uid(
        &path,
        &mut opts,
        gsa_model::state_gate::current_uid(),
        &mut std::io::stderr(),
    )
    .map_err(|e| e.to_string())?;
    let mut existing = Vec::new();
    file.read_to_end(&mut existing)
        .map_err(|e| format!("cannot read {}: {e}", path.display()))?;
    if existing == body.as_bytes() {
        return Ok(path);
    }
    file.seek(SeekFrom::Start(0))
        .map_err(|e| format!("cannot rewind {}: {e}", path.display()))?;
    file.set_len(0)
        .map_err(|e| format!("cannot truncate {}: {e}", path.display()))?;
    file.write_all(body.as_bytes())
        .map_err(|e| format!("cannot write {}: {e}", path.display()))?;
    file.flush()
        .map_err(|e| format!("cannot flush {}: {e}", path.display()))?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        file.set_permissions(std::fs::Permissions::from_mode(0o755))
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
        let path = ensure_pacman_shim(&dir, None).unwrap();
        assert!(path.is_file());
        let body = std::fs::read_to_string(&path).unwrap();
        assert!(body.contains("sudo -n"), "the shim must never prompt");
        assert!(body.contains("flock -x"));
        assert!(
            body.contains("db.lck") == false,
            "the shim never names db.lck"
        );
        // A run that names no configuration keeps the host's database, so
        // its shim carries no `--config` at all (byte-identical to the
        // pre-`--config` body).
        assert!(
            !body.contains("--config"),
            "an unnamed configuration must not bake one: {body}"
        );
        // Idempotent on the BODY: a second call leaves a matching file alone.
        ensure_pacman_shim(&dir, None).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), body);
        // ... and a body that drifted is repaired, never trusted by size.
        std::fs::write(&path, "#!/bin/sh\ntrue\n").unwrap();
        ensure_pacman_shim(&dir, None).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), body);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn shim_carries_the_named_configuration_on_every_call() {
        // makepkg routes `-T` and `-S --asdeps` through `$PACMAN`, so the
        // shim is the only place the named database can reach them: without
        // it a dependency installed in `--config`'s DB read as missing
        // (round-1 review, `I1-sol-4`).
        let dir = std::env::temp_dir().join(format!("gsa-shim-conf-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("locks")).unwrap();
        // A name that would be shell syntax unquoted, plus a relative one
        // (made absolute for makepkg's recipe cwd).
        let conf = dir.join("odd $(touch pwned); 'q.conf");
        std::fs::write(&conf, "[options]\n").unwrap();
        let path = ensure_pacman_shim(&dir, Some(&conf)).unwrap();
        let body = std::fs::read_to_string(&path).unwrap();
        let syntax = std::process::Command::new("sh")
            .arg("-n")
            .arg(&path)
            .status()
            .expect("sh runs");
        assert!(syntax.success(), "the generated shim must parse: {body}");
        assert!(
            body.contains("set -- --config \"$C\" \"$@\""),
            "the configuration must be prepended to every call: {body}"
        );
        assert!(
            body.contains(&format!(
                "C={}",
                shell_single_quote(&conf.display().to_string())
            )),
            "the configuration path must be one quoted literal: {body}"
        );
        // A different configuration REWRITES the shim: leaving the previous
        // body in place kept reading the previous database.
        let other = dir.join("other.conf");
        std::fs::write(&other, "[options]\n").unwrap();
        ensure_pacman_shim(&dir, Some(&other)).unwrap();
        let rewritten = std::fs::read_to_string(&path).unwrap();
        assert!(
            rewritten.contains(&other.display().to_string()),
            "{rewritten}"
        );
        assert!(!rewritten.contains("odd $(touch pwned)"), "{rewritten}");
        // Back to the host's database: the pair leaves the body again.
        ensure_pacman_shim(&dir, None).unwrap();
        let restored = std::fs::read_to_string(&path).unwrap();
        assert!(!restored.contains("--config"), "{restored}");
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
        let path = ensure_pacman_shim(&hostile, None).unwrap();
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
        std::fs::write(
            &sudo,
            "#!/bin/sh\nprintf '%s|' \"$@\" >>\"$GSA_SHIM_LOG\"\nexit 0\n",
        )
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
                format!(
                    "{}:{}",
                    stub.display(),
                    std::env::var("PATH").unwrap_or_default()
                ),
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

    #[test]
    fn shim_gate_refuses_symlink_and_never_clobbers_target() {
        let dir = std::env::temp_dir().join(format!("gsa-shim-symlink-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("locks")).unwrap();
        let target = dir.join("victim");
        std::fs::write(&target, "untouched\n").unwrap();
        let shim = shim_path(&dir);
        std::os::unix::fs::symlink(&target, &shim).unwrap();

        let err = ensure_pacman_shim(&dir, None).unwrap_err();
        assert!(
            err.contains("symlink") || err.contains("ownership"),
            "symlink refusal expected, got: {err}"
        );
        assert_eq!(std::fs::read_to_string(&target).unwrap(), "untouched\n");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
