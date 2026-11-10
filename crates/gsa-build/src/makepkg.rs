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

use gsa_model::toolchain::Toolchain;

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

/// The GSA_LANE_* value and the plain var value for one job-flag variable
/// (§K.1): the caller's non-job flags are preserved on the plain var, and
/// the lane's `-jN` wins over any caller/config `-j`.
fn lane_flags(jobs: u32, caller: &str) -> (String, String) {
    let stripped = strip_job_flags(caller);
    let lane = if stripped.is_empty() {
        format!("-j{jobs}")
    } else {
        format!("{stripped} -j{jobs}")
    };
    (lane, stripped)
}

/// Build the makepkg command for one lane: recipe-directory cwd, the base
/// argv plus the validated payload, `GSA_BUILD_JOBS` exported, job flags
/// stripped from `MAKEFLAGS`/`NINJAFLAGS` (caller's other flags preserved),
/// `GIT_CONFIG_COUNT=0` so agent-shell git config can never break VCS
/// sources, and the `PACMAN` shim so makepkg's own dependency installs share
/// the transaction lock (§K.1/K.3).
///
/// Errors are FATAL for the calling lane (contract §J.2/§J.3's one layout
/// error policy): an unusable build-cache layout, a cache directory that
/// cannot be created, or one that cannot be handed to the build user all
/// refuse the build — never a silent degrade to `src/`/`pkg/`/archives
/// beside the recipe (the pre-W4 shape §J.2 forbids), and never a
/// root-owned cache dir the dropped makepkg cannot write.
pub fn makepkg_command(
    recipe_dir: &Path,
    jobs: u32,
    payload_flags: &[String],
    state_dir: &Path,
    toolchain: Toolchain,
) -> Result<std::process::Command, String> {
    let layout = gsa_model::config::build_layout_for_run()?;
    makepkg_command_in(recipe_dir, jobs, payload_flags, state_dir, &layout, toolchain)
}

/// [`makepkg_command`] against an already-resolved [`BuildLayout`] (the
/// fixture seam; the public entry resolves the layout under the one error
/// policy).
pub fn makepkg_command_in(
    recipe_dir: &Path,
    jobs: u32,
    payload_flags: &[String],
    state_dir: &Path,
    layout: &gsa_model::config::BuildLayout,
    toolchain: Toolchain,
) -> Result<std::process::Command, String> {
    // Build-domain command: under a privileged run makepkg is dropped to the
    // build user (makepkg refuses root; plan-gsa-isolation.md W1).
    let mut cmd = gsa_model::privilege::build_command("makepkg");
    cmd.args(MAKEPKG_BASE_ARGS)
        .args(payload_flags)
        .current_dir(recipe_dir)
        .env("GSA_BUILD_JOBS", jobs.to_string())
        .env("GIT_CONFIG_COUNT", "0");
    for var in ["MAKEFLAGS", "NINJAFLAGS"] {
        // The lane's job flags ride GSA_LANE_* (consumed by the generated
        // composite below — a config-file assignment would clobber these);
        // the caller's non-job flags stay on the plain vars (§K.1).
        let (lane, stripped) = lane_flags(jobs, &std::env::var(var).unwrap_or_default());
        cmd.env(format!("GSA_LANE_{var}"), lane);
        if stripped.is_empty() {
            cmd.env_remove(var);
        } else {
            cmd.env(var, stripped);
        }
    }
    // W4 build cache: makepkg's build trees, staging and archives land in
    // the build user's cache (plan-gsa-isolation.md), never beside the
    // recipe. The dirs are created here — fatal on failure with the remedy
    // named: a half-created layout writes beside the recipe.
    for dir in [&layout.builddir, &layout.pkgdir, &layout.pkgdest] {
        gsa_model::config::create_owned_dir(dir).map_err(|error| {
            format!(
                "cannot create build-cache directory {}: {error} — point build_dir (gsa.conf) or GSA_BUILD_DIR at a writable cache",
                dir.display()
            )
        })?;
    }
    // Ownership scope: only the levels [`create_owned_dir`] brings into
    // existence are handed to the build user. The cache root is
    // user-configured (`build_dir`/`GSA_BUILD_DIR` can name any tree), so
    // the pre-2026-10-18 recursive handoff of `layout.root` swept unrelated
    // user content to the build user wholesale. A pre-existing cache
    // directory is the operator's own: fix its ownership or point
    // build_dir (gsa.conf) / GSA_BUILD_DIR at the build user's cache.
    cmd.env("BUILDDIR", absolute_for_child(&layout.builddir));
    cmd.env("PKGDIR", absolute_for_child(&layout.pkgdir));
    cmd.env("PKGDEST", absolute_for_child(&layout.pkgdest));
    // The composite re-asserts these AFTER any site file (§B.11), so a config
    // file can never re-point the cache the engine resolved.
    cmd.env("GSA_LANE_BUILDDIR", absolute_for_child(&layout.builddir));
    cmd.env("GSA_LANE_PKGDIR", absolute_for_child(&layout.pkgdir));
    cmd.env("GSA_LANE_PKGDEST", absolute_for_child(&layout.pkgdest));
    if let Some(srcdest) = gsa_model::config::resolve_srcdest() {
        // makepkg creates SRCDEST on demand; only an existing parent can be
        // handed to the build user here, so the mirrored path itself is left
        // to makepkg (the fetch path has always worked this way).
        cmd.env("GSA_LANE_SRCDEST", absolute_for_child(&srcdest));
    }
    let shim = crate::shim::shim_path(state_dir);
    if shim.is_file() {
        cmd.env("PACMAN", absolute_for_child(&shim));
    }
    // §B.11: the engine owns the makepkg configuration. The generated
    // composite carries the built-in universal + per-compiler bodies, then
    // the site's files (baseline before the build user's clone), then the
    // engine-owned paths and job flags — makepkg sources it via `--config`,
    // so the host's /etc/makepkg.conf is never consulted.
    let lane_conf = gsa_model::makepkg_conf::install(&layout.root, toolchain)?;
    cmd.args([
        "--config",
        lane_conf
            .to_str()
            .ok_or_else(|| format!("{} is not valid UTF-8", lane_conf.display()))?,
    ]);
    Ok(cmd)
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
    fn the_lane_budget_beats_caller_job_flags_without_losing_them() {
        // Caller -j is stripped (the lane owns the budget), other flags
        // survive, and the lane -jN is appended on GSA_LANE_* (§K.1).
        assert_eq!(lane_flags(6, ""), ("-j6".to_string(), String::new()));
        assert_eq!(
            lane_flags(6, "-j99 --warn-undefined-variables"),
            (
                "--warn-undefined-variables -j6".to_string(),
                "--warn-undefined-variables".to_string()
            )
        );
    }

    #[test]
    fn the_lane_composite_owns_the_config_and_reasserts_the_budget() {
        let dir = std::env::temp_dir().join(format!("gsa-makepkg-shim-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let layout = gsa_model::config::BuildLayout {
            builddir: dir.join("build"),
            pkgdir: dir.join("pkg"),
            pkgdest: dir.join("pkgs"),
            root: dir.clone(),
        };
        let cmd = makepkg_command_in(
            Path::new("/recipes/llvm-git"),
            7,
            &[],
            Path::new("/state"),
            &layout,
            gsa_model::toolchain::Toolchain::Gcc,
        )
        .expect("the layout is usable");
        let body = std::fs::read_to_string(
            dir.join(gsa_model::makepkg_conf::lane_conf_name(
                gsa_model::toolchain::Toolchain::Gcc,
            )),
        )
        .expect("the composite is installed under the cache root");
        // §B.11: the host's config layering is GONE — the engine owns the
        // flags, so no /etc/makepkg.conf, no drop-ins, no user override.
        assert!(!body.contains("source /etc/makepkg.conf"));
        assert!(!body.contains("/etc/makepkg.conf.d/"));
        assert!(!body.contains(".makepkg.conf"));
        assert!(body.contains("gsa universal makepkg settings"));
        assert!(body.contains("gsa gcc makepkg settings"));
        // …and the engine re-asserts its own paths and budget LAST.
        assert!(body.contains("GSA_LANE_BUILDDIR"));
        assert!(body.contains("GSA_LANE_MAKEFLAGS"));
        // …and the budget re-assertion comes last.
        assert!(body.contains("NINJAFLAGS="));
        assert!(
            body.rfind("GSA_LANE_").unwrap() > body.find("gsa gcc makepkg settings").unwrap(),
            "the re-assertion must come after the compiler body"
        );
        // The values ride the env: the lane's job count, nothing else.
        let env = cmd
            .get_envs()
            .find(|(k, _)| k.to_string_lossy() == "GSA_LANE_NINJAFLAGS")
            .and_then(|(_, v)| v.map(|v| v.to_string_lossy().into_owned()))
            .unwrap_or_default();
        assert_eq!(env, "-j7");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn makepkg_argv_keeps_the_lane_shape_and_never_weakens_verification() {
        let dir = std::env::temp_dir().join(format!("gsa-makepkg-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let layout = gsa_model::config::BuildLayout {
            builddir: dir.join("build"),
            pkgdir: dir.join("pkg"),
            pkgdest: dir.join("pkgs"),
            root: dir.clone(),
        };
        let cmd = makepkg_command_in(
            Path::new("/recipes/mesa-git"),
            6,
            &[],
            Path::new("/state"),
            &layout,
            gsa_model::toolchain::Toolchain::Gcc,
        )
        .expect("the layout is usable");
        let argv: Vec<String> = cmd
            .get_args()
            .map(|a| a.to_string_lossy().into_owned())
            .collect();
        // Base args + the §K.1 --config shim; nothing else may appear.
        assert_eq!(argv.len(), 4, "unexpected argv: {argv:?}");
        assert_eq!(&argv[..2], ["-sf", "--noconfirm"]);
        assert_eq!(argv[2], "--config");
        assert!(
            argv[3].ends_with(&gsa_model::makepkg_conf::lane_conf_name(
                gsa_model::toolchain::Toolchain::Gcc
            )),
            "the --config target must be the lane shim: {argv:?}"
        );
        // No forbidden token can be constructed through the base argv.
        for forbidden in FORBIDDEN_ARGS {
            assert!(!argv.iter().any(|a| a == forbidden));
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn makepkg_writes_only_into_the_w4_build_cache() {
        let dir = std::env::temp_dir().join(format!("gsa-makepkg-layout-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let layout = gsa_model::config::BuildLayout {
            builddir: dir.join("build"),
            pkgdir: dir.join("pkg"),
            pkgdest: dir.join("pkgs"),
            root: dir.clone(),
        };
        let cmd = makepkg_command_in(
            Path::new("/recipes/mesa-git"),
            6,
            &[],
            Path::new("/state"),
            &layout,
            gsa_model::toolchain::Toolchain::Gcc,
        )
        .expect("the layout is usable");
        // The cache dirs exist and makepkg is pointed at them — never at
        // the recipe directory (§J.2).
        for (key, dir) in [
            ("BUILDDIR", &layout.builddir),
            ("PKGDIR", &layout.pkgdir),
            ("PKGDEST", &layout.pkgdest),
        ] {
            assert!(dir.is_dir(), "{key} dir {} was not created", dir.display());
            let env = cmd
                .get_envs()
                .find(|(k, _)| k.to_string_lossy() == key)
                .and_then(|(_, v)| v.map(|v| v.to_string_lossy().into_owned()))
                .unwrap_or_default();
            assert_eq!(env, dir.display().to_string(), "{key} must point at the cache");
        }
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn makepkg_refuses_a_layout_it_cannot_create() {
        let dir = std::env::temp_dir().join(format!("gsa-makepkg-bad-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        // A regular file where the cache root must be: create_dir_all fails
        // and the failure is fatal, never a silent recipe-dir fallback.
        std::fs::write(dir.join("occupied"), "not a directory").unwrap();
        let layout = gsa_model::config::BuildLayout {
            builddir: dir.join("occupied").join("build"),
            pkgdir: dir.join("pkg"),
            pkgdest: dir.join("pkgs"),
            root: dir.clone(),
        };
        let error = makepkg_command_in(
            Path::new("/recipes/mesa-git"),
            6,
            &[],
            Path::new("/state"),
            &layout,
            gsa_model::toolchain::Toolchain::Gcc,
        )
        .unwrap_err();
        assert!(error.contains("build-cache directory"), "{error}");
        assert!(
            error.contains("GSA_BUILD_DIR"),
            "the remedy must be named: {error}"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }
}
