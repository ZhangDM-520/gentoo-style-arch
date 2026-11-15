//! The state of a `SRCDEST` mirror directory.
//!
//! makepkg keeps a bare git mirror per VCS source under `SRCDEST`. Three
//! states matter and two of them used to be conflated (2026-11-15): a
//! directory that is ABSENT is missing evidence, but a directory that is
//! present and not a git repository is CORRUPT evidence, and only the first
//! is fixed by fetching. A bare mirror whose `refs/` directory was removed
//! (an empty-directory sweep, not git) answers `fatal: not a git repository`
//! to every question, which the snapshot pass reported as a bad ref spelling.
//!
//! One definition, asked by the sync pass, the doctor and the build side, so
//! the three cannot drift (`AGENTS.md` §5: a gate in one language drifts from
//! the gate in the other).

use std::path::Path;
use std::process::Command;

/// The three states a mirror directory can be in.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum MirrorState {
    /// No such directory: the mirror was never fetched.
    Absent,
    /// A directory git refuses to read as a repository.
    Unusable {
        /// Git's own last stderr line, for the operator.
        detail: String,
    },
    /// A readable repository.
    Usable,
}

/// Classify `path` by asking git the same question every consumer asks.
///
/// `rev-parse --absolute-git-dir` is the probe because it is exactly what
/// `safe.bareRepository` gates: a bare repository is only readable when git
/// agrees it is one, which is the failure a missing `refs/` produces.
pub fn mirror_state(path: &Path) -> MirrorState {
    if !path.is_dir() {
        return MirrorState::Absent;
    }
    let output = Command::new("git")
        // The env is load-bearing and must not be "simplified": agent and
        // root shells inject `safe.bareRepository=explicit` (which alone
        // makes a bare mirror unreadable) plus filter config that changes
        // archived bytes. `GIT_CONFIG_COUNT=0` drops the whole injected set,
        // and the explicit `-c` below then re-enables bare reads. A probe
        // that dropped either would report every healthy mirror as broken.
        .env("GIT_CONFIG_COUNT", "0")
        .env("GIT_TERMINAL_PROMPT", "0")
        .arg("-c")
        .arg("safe.bareRepository=all")
        // `safe.directory=*` is the OWNER-AGNOSTIC rung, and it is what makes
        // this probe answer the mirror's shape instead of the caller's
        // identity: the mirrors are build-user data and the pass runs as
        // root, so git's `dubious ownership` guard refuses them — EXCEPT when
        // `SUDO_UID` is set and matches the owner (measured 2026-11-15).
        // Without this, `sudo -i gsa -Sy` and `sudo -i gsa -Md --fix` would
        // report EVERY healthy mirror unusable and then "repair" them all.
        // The flag is scoped to this one read-only invocation.
        .arg("-c")
        .arg("safe.directory=*")
        .arg("-C")
        .arg(path)
        .args(["rev-parse", "--absolute-git-dir"])
        .output();
    match output {
        Ok(o) if o.status.success() => MirrorState::Usable,
        Ok(o) => MirrorState::Unusable {
            detail: verdict_line(&o.stderr),
        },
        // The probe could not run at all: that is not evidence the mirror is
        // corrupt, and guessing either way stands a gate down. Report the
        // spawn failure verbatim so the operator sees the real cause.
        Err(error) => MirrorState::Unusable {
            detail: format!("cannot run git: {error}"),
        },
    }
}

/// Git's most useful stderr line — the sentence a human reads.
///
/// Git emits its verdict FIRST and then advice (`Stopping at filesystem
/// boundary …`), so the last line is the noise and the first is the answer.
/// A `fatal:`/`error:` line wins outright when one exists.
fn verdict_line(stderr: &[u8]) -> String {
    let text = String::from_utf8_lossy(stderr);
    let lines: Vec<&str> = text
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .collect();
    lines
        .iter()
        .find(|line| line.starts_with("fatal:") || line.starts_with("error:"))
        .or_else(|| lines.first())
        .map(|line| line.to_string())
        .unwrap_or_else(|| "git reported no detail".to_string())
}

#[cfg(test)]
mod tests {
    use super::{mirror_state, MirrorState};

    fn scratch(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "gsa-mirror-{tag}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_nanos())
                .unwrap_or(0)
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn git(dir: &std::path::Path, args: &[&str]) -> bool {
        std::process::Command::new("git")
            .env("GIT_CONFIG_COUNT", "0")
            .arg("-C")
            .arg(dir)
            .args(args)
            .output()
            .map(|o| o.status.success())
            .unwrap_or(false)
    }

    #[test]
    fn mirror_state_absent_for_a_missing_dir() {
        let dir = scratch("absent");
        let missing = dir.join("never-fetched");
        assert_eq!(mirror_state(&missing), MirrorState::Absent);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn mirror_state_usable_for_a_real_bare_repo() {
        let dir = scratch("usable");
        let repo = dir.join("mirror");
        assert!(git(&dir, &["init", "--quiet", "--bare", "mirror"]));
        assert_eq!(mirror_state(&repo), MirrorState::Usable);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn mirror_state_is_owner_agnostic() {
        // The mirrors are build-user data and the snapshot pass runs as root,
        // so git's `dubious ownership` guard is the DEFAULT verdict for every
        // healthy mirror — it only steps aside when `SUDO_UID` matches the
        // owner. The probe must therefore read the MIRROR, never the caller:
        // pinned here by inheritance, because the root case itself is pinned
        // where real sudo exists (`tests/gsa-privilege.sh` §i).
        use std::process::{Command, Stdio};
        let dir = scratch("owner");
        let repo = dir.join("mirror");
        assert!(git(&dir, &["init", "--quiet", "--bare", "mirror"]));
        // `safe.directory=*` is the owner-agnostic rung; without it this
        // invocation fails with `dubious ownership` for a foreign owner.
        let output = Command::new("git")
            .env("GIT_CONFIG_COUNT", "0")
            .env("SUDO_UID", "0")
            .env("SUDO_GID", "0")
            .arg("-c")
            .arg("safe.bareRepository=all")
            .arg("-c")
            .arg("safe.directory=*")
            .arg("-C")
            .arg(&repo)
            .args(["rev-parse", "--absolute-git-dir"])
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .expect("git runs");
        assert!(
            output.success(),
            "the probe's argv must carry safe.directory=* or a foreign-owner mirror is unreadable"
        );
        assert_eq!(mirror_state(&repo), MirrorState::Usable);
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn mirror_state_unusable_when_refs_is_swept() {
        // The 2026-11-15 production shape: objects, packed-refs, HEAD and
        // config all intact, `refs/` gone. Git refuses the whole repository,
        // which is why every candidate ref failed.
        let dir = scratch("unusable");
        let repo = dir.join("mirror");
        assert!(git(&dir, &["init", "--quiet", "--bare", "mirror"]));
        assert_eq!(mirror_state(&repo), MirrorState::Usable);
        std::fs::remove_dir_all(repo.join("refs")).unwrap();
        match mirror_state(&repo) {
            MirrorState::Unusable { detail } => assert!(
                detail.contains("not a git repository"),
                "the detail must carry git's own words, got: {detail}"
            ),
            other => panic!("a refs-less mirror must be Unusable, got {other:?}"),
        }
        std::fs::remove_dir_all(&dir).ok();
    }
}
