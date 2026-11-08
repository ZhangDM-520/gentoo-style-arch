//! The build-cache root choice in front of a build run (contract §J.2).
//!
//! A build-shaped run (`-S`/`-B`, their `--dry-run` plans, and the `-Su`/
//! `-Syu` stale-set builds) asks which root makepkg's `BUILDDIR`/`PKGDIR`/
//! `PKGDEST` live under BEFORE anything resolves the layout:
//!
//! - `--build-dir PATH` answers it as a flag (and mirrors into the run
//!   record's continuation, so a resume rebuilds into the same tree);
//! - `GSA_BUILD_DIR` in the environment answers it silently — an explicit
//!   environment override is an answer, not a default, and this is what keeps
//!   fixtures and scripted runs non-interactive;
//! - `--no-build-dir-prompt` restores the pre-prompt behaviour: resolve
//!   silently from `gsa.conf`, `GSA_BUILD_DIR` or the built-in default;
//! - otherwise a TTY asks, showing the resolved root WITH its provenance, so
//!   a stale `gsa.conf` path or a stray environment override is visible before
//!   it is accepted. Enter keeps it; a path replaces it for this run only.
//!
//! The answer is pinned for the process ([`gsa_model::config::
//! set_build_root_override`]) and exported to lane/fetch children through
//! `GSA_BUILD_DIR`, because a child re-resolves the layout in its own process.

use std::io::{IsTerminal, Write};
use std::path::PathBuf;

use crate::args::Invocation;
use crate::exit::Exit;
use crate::prompt::{prompt_build_dir, BuildDirOutcome};

/// Resolve the run's build root, prompting on a TTY when nothing named it.
/// `Ok(())` means every later `build_layout_for_run()` call agrees; `Err(exit)`
/// is the typed usage-class failure the caller returns unchanged.
pub fn resolve(inv: &mut Invocation, err: &mut dyn Write) -> Result<(), Exit> {
    if let Some(raw) = inv.build_dir.clone() {
        let root = operator_path(&raw)
            .map_err(|message| Exit::Usage(format!("--build-dir: {message}")))?;
        apply(inv, root);
        return Ok(());
    }
    if inv.no_build_dir_prompt || gsa_model::config::env_build_root().is_some() {
        return Ok(());
    }
    let stdin = std::io::stdin();
    if !stdin.is_terminal() {
        return Ok(());
    }
    let cfg = gsa_model::config::load().map_err(Exit::Usage)?;
    let (default, source) = gsa_model::config::build_root_with_source(&cfg).map_err(Exit::Usage)?;
    let home = gsa_model::config::build_user_home().unwrap_or_else(|_| PathBuf::from("/"));
    match prompt_build_dir(&default, source, &home, err, &mut stdin.lock()) {
        Ok(BuildDirOutcome::Default) => Ok(()),
        Ok(BuildDirOutcome::Chosen(root)) => {
            apply(inv, root);
            Ok(())
        }
        Ok(BuildDirOutcome::Abort(reason)) => Err(Exit::Usage(reason.to_string())),
        Err(error) => Err(Exit::Usage(format!(
            "cannot read the build-dir answer: {error}"
        ))),
    }
}

/// `~` expansion plus the one validation a root needs before it becomes
/// makepkg's `BUILDDIR`: an absolute path. A relative one would resolve
/// against each lane's recipe directory.
fn operator_path(raw: &str) -> Result<PathBuf, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err("a path is required".to_string());
    }
    let home = gsa_model::config::build_user_home()?;
    let path = gsa_model::config::expand_home(trimmed, &home);
    if !path.is_absolute() {
        return Err(format!("'{raw}' is not absolute — give /path or ~/path"));
    }
    if path.exists() && !path.is_dir() {
        return Err(format!("{} is not a directory", path.display()));
    }
    Ok(path)
}

/// Pin the root for this process and hand it to child processes (lanes and
/// fetch children resolve the layout themselves). The record's `--build-dir`
/// mirror reads the invocation, so the answer lands there too.
fn apply(inv: &mut Invocation, root: PathBuf) {
    gsa_model::config::set_build_root_override(root.clone());
    std::env::set_var("GSA_BUILD_DIR", &root);
    inv.build_dir = Some(root.display().to_string());
}
