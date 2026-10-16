//! The makepkg invocation contract (contract §A.3.4, §K.1).
//!
//! The argv shape is the fish lanes' (`build-all.fish` `build_package`:
//! `makepkg -sf --noconfirm` in the recipe directory, output to the
//! per-package log). Verification is makepkg's and is NEVER weakened: there
//! is no `--skipchecksums`, no `--skippgpcheck`, no `--skipinteg` anywhere —
//! the lane argv-check rejects those tokens loudly (§A.3.4, §L.8).
//!
//! The engine exports the lane's job count as `GSA_BUILD_JOBS` and rewrites
//! `MAKEFLAGS`/`NINJAFLAGS` without discarding the caller's other flags
//! (§K.1): each `-jN` / `-j N` is stripped and the rest is preserved.

use std::path::{Path, PathBuf};

/// The base makepkg argv every lane uses (fish lane shape).
pub const MAKEPKG_BASE_ARGS: [&str; 2] = ["-sf", "--noconfirm"];

/// Paths handed to makepkg must be absolute: makepkg runs with the RECIPE's
/// cwd (§K.1), so a relative path resolves against the recipe directory —
/// a relative `PACMAN` shim then does not exist there and makepkg's
/// dependency handling dies with a bare "An unknown error has occurred".
pub(crate) fn absolute_for_child(path: &Path) -> PathBuf {
    std::path::absolute(path).unwrap_or_else(|_| path.to_path_buf())
}

/// Verification-bypass tokens that must never appear anywhere in `gsa`
/// (contract §A.3.4 / §L.8): a lane argv carrying one is a usage error, not a
/// build.
pub const FORBIDDEN_ARGS: [&str; 3] = ["--skipchecksums", "--skippgpcheck", "--skipinteg"];

/// Reject a `--lane-job` flags payload that is malformed, carries control
/// characters, or names a verification bypass (contract §D.1: invalid flags
/// are rc 2 and the message names the argument).
pub fn check_flag_payload(flags: &[String]) -> Result<(), String> {
    for flag in flags {
        if flag.is_empty() {
            return Err("empty flag in lane payload".to_string());
        }
        if flag.chars().any(|c| c.is_control()) {
            return Err(format!("flag '{flag}' contains a control character"));
        }
        if FORBIDDEN_ARGS.contains(&flag.as_str()) {
            return Err(format!(
                "flag '{flag}' is forbidden: makepkg verification is never weakened (contract §A.3.4)"
            ));
        }
        let shape_ok = match flag.strip_prefix("--") {
            Some(body) => {
                let (name, value) = match body.split_once('=') {
                    Some((n, v)) => (n, Some(v)),
                    None => (body, None),
                };
                !name.is_empty()
                    && name.chars().all(|c| c.is_ascii_lowercase() || c == '-')
                    && value
                        .map(|v| !v.chars().any(|c| c.is_control()))
                        .unwrap_or(true)
            }
            None => match flag.strip_prefix('-') {
                Some(body) => !body.is_empty() && body.chars().all(|c| c.is_ascii_alphanumeric()),
                None => false,
            },
        };
        if !shape_ok {
            return Err(format!("flag '{flag}' is not a makepkg flag token"));
        }
    }
    Ok(())
}

/// Strip `-jN` / `-j N` job flags from a `MAKEFLAGS`/`NINJAFLAGS` value,
/// preserving every other flag (§K.1).
pub fn strip_job_flags(value: &str) -> String {
    let tokens: Vec<&str> = value.split_whitespace().collect();
    let mut out: Vec<&str> = Vec::new();
    let mut skip_next = false;
    for token in &tokens {
        if skip_next {
            skip_next = false;
            continue;
        }
        if *token == "-j" {
            // `-j N` form: drop the separate number operand too.
            skip_next = true;
            continue;
        }
        if token.len() >= 2
            && token.starts_with("-j")
            && token[2..].chars().all(|c| c.is_ascii_digit())
        {
            continue;
        }
        out.push(token);
    }
    out.join(" ")
}

/// Build the makepkg command for one lane: recipe-directory cwd, the base
/// argv plus the validated payload, `GSA_BUILD_JOBS` exported, job flags
/// stripped from `MAKEFLAGS`/`NINJAFLAGS` (caller's other flags preserved),
/// `GIT_CONFIG_COUNT=0` so agent-shell git config can never break VCS
/// sources, and the `PACMAN` shim so makepkg's own dependency installs share
/// the transaction lock (§K.1/K.3).
pub fn makepkg_command(
    recipe_dir: &Path,
    jobs: u32,
    payload_flags: &[String],
    state_dir: &Path,
) -> std::process::Command {
    // Build-domain command: under a privileged run makepkg is dropped to the
    // build user (makepkg refuses root; plan-gsa-isolation.md W1).
    let mut cmd = gsa_model::privilege::build_command("makepkg");
    cmd.args(MAKEPKG_BASE_ARGS)
        .args(payload_flags)
        .current_dir(recipe_dir)
        .env("GSA_BUILD_JOBS", jobs.to_string())
        .env("GIT_CONFIG_COUNT", "0");
    for var in ["MAKEFLAGS", "NINJAFLAGS"] {
        if let Ok(value) = std::env::var(var) {
            let stripped = strip_job_flags(&value);
            if stripped.is_empty() {
                cmd.env_remove(var);
            } else {
                cmd.env(var, stripped);
            }
        }
    }
    // W4 build cache: makepkg's build trees, staging and archives land in
    // the build user's cache (plan-gsa-isolation.md), never beside the
    // recipe. The dirs are created (and chowned back) here — build-side
    // writes into build-user paths are owned by the build user (W1).
    if let Ok(layout) = gsa_model::config::load().and_then(|c| gsa_model::config::build_layout(&c)) {
        for dir in [&layout.builddir, &layout.pkgdir, &layout.pkgdest] {
            if std::fs::create_dir_all(dir).is_ok() {
                let _ = gsa_model::privilege::own_to_build_user(dir);
            }
        }
        cmd.env("BUILDDIR", absolute_for_child(&layout.builddir));
        cmd.env("PKGDIR", absolute_for_child(&layout.pkgdir));
        cmd.env("PKGDEST", absolute_for_child(&layout.pkgdest));
    }
    let shim = crate::shim::shim_path(state_dir);
    if shim.is_file() {
        cmd.env("PACMAN", absolute_for_child(&shim));
    }
    cmd
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn paths_handed_to_makepkg_are_absolute() {
        // makepkg runs with the RECIPE's cwd (§K.1): a relative PACMAN shim
        // path resolves against the recipe directory and does not exist
        // there — the lane's `makepkg -sf` then dies with a bare
        // "An unknown error has occurred" (real smoke, 2026-10-14).
        let abs = absolute_for_child(Path::new("relative/state/locks/pacman-shim"));
        assert!(abs.is_absolute(), "{abs:?}");
        assert!(abs.ends_with("relative/state/locks/pacman-shim"), "{abs:?}");
    }

    #[test]
    fn verification_bypass_tokens_are_rejected_naming_the_argument() {
        for bad in FORBIDDEN_ARGS {
            let err = check_flag_payload(&[bad.to_string()]).unwrap_err();
            assert!(err.contains(bad), "{err}");
            assert!(err.contains("never weakened"), "{err}");
        }
    }

    #[test]
    fn flag_payload_shape_is_checked() {
        assert!(check_flag_payload(&[
            "-sf".into(),
            "--noconfirm".into(),
            "--asdeps".into(),
            "--clean".into()
        ])
        .is_ok());
        for bad in [
            "",
            "makepkg",
            "--Bad",
            "-x y",
            "--skip=1\n2",
            "--weird$flag",
        ] {
            let flags: Vec<String> = vec![bad.to_string()];
            assert!(
                check_flag_payload(&flags).is_err(),
                "{bad:?} must be refused"
            );
        }
    }

    #[test]
    fn job_flags_are_stripped_and_others_preserved() {
        assert_eq!(strip_job_flags("-j4 -O2"), "-O2");
        assert_eq!(
            strip_job_flags("-O2 -j 8 --no-print-directory"),
            "-O2 --no-print-directory"
        );
        assert_eq!(strip_job_flags("-j4"), "");
        assert_eq!(
            strip_job_flags("--warn-undefined-variables"),
            "--warn-undefined-variables"
        );
    }

    #[test]
    fn makepkg_argv_keeps_the_lane_shape_and_never_weakens_verification() {
        let cmd = makepkg_command(Path::new("/recipes/mesa-git"), 6, &[], Path::new("/state"));
        let argv: Vec<String> = cmd
            .get_args()
            .map(|a| a.to_string_lossy().into_owned())
            .collect();
        assert_eq!(argv, vec!["-sf", "--noconfirm"]);
        // No forbidden token can be constructed through the base argv.
        for forbidden in FORBIDDEN_ARGS {
            assert!(!argv.iter().any(|a| a == forbidden));
        }
    }
}
