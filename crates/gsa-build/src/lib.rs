//! `gsa-build` — makepkg orchestration (`docs/gsa-contract.md` §K.1;
//! plan-native-pm.md §3.1 "gsa-build: makepkg orchestration").
//!
//! - [`lane`]: the `--lane-job` child entry — one package, one result file.
//! - [`makepkg`]: the makepkg argv/env contract (checksums/PGP never
//!   weakened, `GSA_BUILD_JOBS` exported, `MAKEFLAGS`/`NINJAFLAGS` rewritten).
//! - [`shim`]: the `PACMAN` shim routing makepkg's own dependency installs
//!   through one transaction lock and `sudo -n` (the engine never prompts).
//! - [`clean`]: prune strength 1 (`-Bc`/`-Mc`): `src/`/`pkg/`/`build/` trees
//!   and the selection's archives.

pub mod clean;
pub mod lane;
pub mod makepkg;
pub mod shim;

use std::path::{Path, PathBuf};

/// Per-package build log location under the state root (contract §J.1: logs
/// live under the state root; §K.1 writes them through the ownership gate).
pub fn log_path(state_dir: &Path, pkg: &str) -> PathBuf {
    state_dir.join("logs").join(format!("{pkg}.log"))
}

/// Find the recipe repository: walk up from `start` until `config/topology.conf`
/// exists (the strict loader's home).
pub fn find_root(start: &Path) -> Option<PathBuf> {
    let mut dir = start.to_path_buf();
    loop {
        if dir.join("config").join("topology.conf").is_file() {
            return Some(dir);
        }
        if !dir.pop() {
            return None;
        }
    }
}
