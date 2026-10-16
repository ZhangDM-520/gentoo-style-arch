//! The transparent privilege handle (plan-gsa-isolation.md W1; contract §B.10).
//!
//! gsa is pacman-shaped: read-only verbs run as any user, mutating runs run as
//! root, and every build-side command (the makepkg family, recipe-code evals)
//! runs in the **build-user domain**. Under `sudo` the build user is
//! `SUDO_UID`/`SUDO_GID`; the drop goes through `setpriv` so the environment
//! survives intact — stub `PATH`s in fixtures, `GSA_BUILD_JOBS`, `MAKEFLAGS`,
//! `SRCDEST` all reach the dropped command unchanged — EXCEPT the identity
//! vars (`HOME`/`USER`/`LOGNAME`), which follow the drop (a leaked root `HOME`
//! sent cargo to `/root/.cargo`, 2026-10-16 smoke).
//!
//! A bare root shell has no build user: build-touching verbs are refused there
//! (the CLI gate owns that message) and this module never improvises a user.
//! Engine-side writes into build-user paths (recipe-tree publishes) are
//! chowned back to the build user so the workspace is never poisoned
//! root-owned — the incident this module exists to prevent.

use std::ffi::OsStr;
use std::path::Path;
use std::process::Command;

extern "C" {
    fn geteuid() -> u32;
}

/// The effective uid of this process (0 = a privileged engine run).
pub fn effective_uid() -> u32 {
    unsafe { geteuid() }
}

/// The build user a privileged run drops its build-side commands to.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BuildUser {
    pub uid: u32,
    pub gid: u32,
    pub name: String,
}

/// The build user from the sudo environment (`plan-gsa-isolation.md`:
/// `~/.cache/gsa` and every dropped command target this user). None outside
/// sudo.
pub fn build_user() -> Option<BuildUser> {
    build_user_from_env(
        &std::env::var("SUDO_UID").ok()?,
        &std::env::var("SUDO_GID").ok()?,
        std::env::var("SUDO_USER").ok(),
    )
}

/// The parse seam (testable without touching process env).
fn build_user_from_env(uid: &str, gid: &str, name: Option<String>) -> Option<BuildUser> {
    let uid: u32 = uid.parse().ok()?;
    let gid: u32 = gid.parse().ok()?;
    let name = name.filter(|n| !n.is_empty()).unwrap_or_else(|| uid.to_string());
    Some(BuildUser { uid, gid, name })
}

/// A `Command` for a build-side program. Under a privileged run (root with a
/// known build user) the program is wrapped in `setpriv` so it runs as the
/// build user; otherwise the command is plain. Callers append args/env/cwd as
/// usual — the wrap happens at construction so nothing configured afterwards
/// is lost.
pub fn build_command<S: AsRef<OsStr>>(program: S) -> Command {
    let cmd = Command::new(program);
    if effective_uid() != 0 {
        return cmd;
    }
    let Some(bu) = build_user() else {
        // Root shell with no build user: the CLI gate refuses build-touching
        // verbs before this is reached; pass the command through unwrapped.
        return cmd;
    };
    let inner = cmd.get_program().to_os_string();
    let mut wrapped = Command::new("setpriv");
    wrapped
        .arg("--reuid")
        .arg(bu.uid.to_string())
        .arg("--regid")
        .arg(bu.gid.to_string())
        .arg("--init-groups")
        .arg(inner);
    drop_identity_env(&mut wrapped, &bu, crate::config::build_user_home().ok());
    wrapped
}

/// Identity follows the drop; everything else survives it. The root
/// supervisor's `HOME`/`USER`/`LOGNAME` leak otherwise — 2026-10-16 smoke:
/// the dropped makepkg kept `HOME=/root`, so cargo wrote to `/root/.cargo`
/// and `~/.makepkg.conf` (the user's `SRCDEST`) was never read. PATH,
/// `GSA_*`, `MAKEFLAGS`, `SRCDEST`, fixture stubs and the rest pass through
/// unchanged (the module contract above).
fn drop_identity_env(cmd: &mut Command, bu: &BuildUser, home: Option<std::path::PathBuf>) {
    if let Some(home) = home {
        cmd.env("HOME", home);
    }
    cmd.env("USER", &bu.name);
    cmd.env("LOGNAME", &bu.name);
}

/// One banner line for a privileged run (the "transparent handle"): who the
/// engine/pacman run as, and who every build-side command runs as.
pub fn privileged_banner(needs_build_user: bool) -> String {
    match (needs_build_user, build_user()) {
        (true, Some(bu)) => format!(
            "gsa: privileged run: engine and pacman as root; makepkg and build-cache writes as {} (uid {})",
            bu.name, bu.uid
        ),
        _ => "gsa: privileged run: engine and pacman as root".to_string(),
    }
}

/// Chown a build-domain path (recursively) to the build user after an
/// engine-side write. No-op when not privileged. Errors are real: a
/// root-owned file left in the workspace is exactly the poisoning this module
/// exists to prevent.
pub fn own_to_build_user(path: &Path) -> Result<(), String> {
    if effective_uid() != 0 {
        return Ok(());
    }
    let Some(bu) = build_user() else {
        return Ok(());
    };
    own_recursive(path, &bu)
}

fn own_recursive(path: &Path, bu: &BuildUser) -> Result<(), String> {
    let meta =
        std::fs::symlink_metadata(path).map_err(|e| format!("cannot stat {}: {e}", path.display()))?;
    if meta.file_type().is_symlink() {
        return std::os::unix::fs::lchown(path, Some(bu.uid), Some(bu.gid))
            .map_err(|e| format!("cannot lchown {}: {e}", path.display()));
    }
    if meta.is_dir() {
        let entries =
            std::fs::read_dir(path).map_err(|e| format!("cannot read {}: {e}", path.display()))?;
        for entry in entries.flatten() {
            own_recursive(&entry.path(), bu)?;
        }
    }
    std::os::unix::fs::chown(path, Some(bu.uid), Some(bu.gid))
        .map_err(|e| format!("cannot chown {}: {e}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::OsString;

    #[test]
    fn build_user_parses_the_sudo_triplet_and_defaults_the_name() {
        let bu = build_user_from_env("1000", "1000", Some("zhangdm".into())).unwrap();
        assert_eq!(
            bu,
            BuildUser {
                uid: 1000,
                gid: 1000,
                name: "zhangdm".into()
            }
        );
        let bu = build_user_from_env("1000", "100", None).unwrap();
        assert_eq!(bu.name, "1000", "the uid stands in for a missing name");
    }

    #[test]
    fn build_user_rejects_junk_rather_than_improvising_a_user() {
        assert!(build_user_from_env("root", "root", None).is_none());
        assert!(build_user_from_env("-1", "0", None).is_none());
        assert!(build_user_from_env("1000", "", None).is_none());
    }

    #[test]
    fn unprivileged_build_command_is_a_plain_command() {
        // The test binary is never root, so no wrap may happen here.
        let cmd = build_command("makepkg");
        assert_eq!(cmd.get_program(), OsStr::new("makepkg"));
    }

    #[test]
    fn drop_identity_moves_home_and_login_to_the_build_user() {
        let bu = BuildUser {
            uid: 1000,
            gid: 1000,
            name: "builder".into(),
        };
        let mut cmd = Command::new("makepkg");
        cmd.env("MAKEFLAGS", "-j2"); // caller env must survive
        drop_identity_env(&mut cmd, &bu, Some(std::path::PathBuf::from("/home/builder")));
        let env: Vec<(OsString, OsString)> = cmd.get_envs().map(|(k, v)| {
            (
                k.to_os_string(),
                v.map(|v| v.to_os_string()).unwrap_or_default(),
            )
        }).collect();
        assert!(env.contains(&(OsString::from("HOME"), OsString::from("/home/builder"))));
        assert!(env.contains(&(OsString::from("USER"), OsString::from("builder"))));
        assert!(env.contains(&(OsString::from("LOGNAME"), OsString::from("builder"))));
        assert!(env.contains(&(OsString::from("MAKEFLAGS"), OsString::from("-j2"))),
            "non-identity env must survive the drop");
    }

    #[test]
    fn banner_names_the_split() {
        let banner = privileged_banner(false);
        assert!(banner.contains("engine and pacman as root"), "{banner}");
    }

    #[test]
    fn own_to_build_user_is_a_noop_for_the_test_user() {
        let dir = std::env::temp_dir().join(format!("gsa-priv-own-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("f"), "x").unwrap();
        own_to_build_user(&dir).unwrap();
        let _ = std::fs::remove_dir_all(&dir);
    }
}
