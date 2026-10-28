//! `gsa-state` — the side-car state database under the state root
//! (`docs/gsa-contract.md` §J; plan-native-pm.md §5.2, plan-gentoo-qol.md
//! M3). Three stores, all append-only JSONL: the hash-bound binpkg index
//! (`index/binpkg.jsonl`, §J.4), the run history (`runs/history.jsonl`, the
//! §H.1 persistence amendment), and a small key-value (`kv/kv.jsonl`) that
//! is schema-ready for the future subscriptions/world records — JSONL over
//! SQLite because the reads are whole-file folds, corruption tolerance is a
//! line-skip away, and no native dependency may gate `cargo build --offline`
//! (plan-native-pm.md §8: "SQLite or plain append-only files").
//!
//! The side-car never records what `/usr` contains as authority: pacman
//! stays the only installed database (hybrid model, owner decision). Every
//! write passes the write-time ownership gate (rule 19, §J.5) before the
//! file is opened; every read tolerates a truncated tail line without losing
//! the rows before it. Archives stay wherever makepkg wrote them (the W4a
//! shared `PKGDEST`, or beside their recipe in a legacy tree — §J.2); the
//! index refers to them by hash, it never moves them.

pub mod health;
pub mod index;
pub mod kv;
pub mod recipes;
pub mod runs;
pub mod store;

mod ownership;

pub use health::{check, Finding, HealthReport};
pub use index::{
    prune_instance, register_instance, reindex_archives, verify_row, wire_row, BinpkgIndex,
    IndexRow, Match, RegisterOutcome, Retention, Verification,
};
pub use kv::Kv;
// `ownership_gate` is the rule-19 write gate (§J.5) every state-file write
// must open through — re-exported so sibling crates' state-write sites
// (e.g. gsa-install's forced-rebuild markers) share the one seam instead of
// hand-rolling an open the gate would refuse.
pub use ownership::{ownership_gate, StateError};
pub use runs::{wire_run, RunHistory};
pub use store::CorruptLine;

use std::path::{Path, PathBuf};

/// The FHS state root (contract §J.1/J.3): the default is `/var/lib/gsa`
/// from day one (owner decision — root-write accepted), with `--state-dir`
/// and `GSA_STATE_DIR` relocating the entire root. There is never a silent
/// fallback to a workspace-local directory.
pub const DEFAULT_STATE_ROOT: &str = "/var/lib/gsa";

/// Resolve the state root the contract's precedence demands (§J.3):
/// `--state-dir` beats `GSA_STATE_DIR` beats the `gsa.conf` layers'
/// `state_dir` beats [`DEFAULT_STATE_ROOT`]. One ladder, one home: this
/// delegates to `gsa_model::config::resolve_state_dir`, the resolver the
/// build pipeline already uses — a config error is a named error, never a
/// silent fall-through to the default.
pub fn resolve_state_root(flag: Option<&str>) -> Result<PathBuf, String> {
    gsa_model::config::resolve_state_dir(flag)
}

/// An opened state root: the one directory tree every store lives under,
/// with the §J.1 layout this crate owns created on first open.
#[derive(Clone, Debug)]
pub struct StateRoot {
    path: PathBuf,
}

impl StateRoot {
    /// Open (creating if needed) the state root and the store directories
    /// it owns: `index/`, `runs/`, `kv/`. A create failure names
    /// `--state-dir` as the remedy (§J.3); a wrong-owner file is quarantined
    /// loudly before any write path touches it (§J.5).
    pub fn open(path: &Path) -> Result<StateRoot, StateError> {
        for sub in ["index", "runs", "kv"] {
            let dir = path.join(sub);
            std::fs::create_dir_all(&dir).map_err(|e| {
                StateError::Create(format!(
                    "cannot create state directory {} ({e}) — pass --state-dir PATH or set GSA_STATE_DIR",
                    dir.display()
                ))
            })?;
        }
        Ok(StateRoot {
            path: path.to_path_buf(),
        })
    }

    /// A read-only handle for the pure-read surfaces (`--install-decide`'s
    /// §E.5 park report): nothing is created — the store readers treat a
    /// missing file as the empty store — so a read can never mutate state
    /// (§D.1 "touches nothing else").
    pub fn open_readonly(path: &Path) -> StateRoot {
        StateRoot {
            path: path.to_path_buf(),
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// The binpkg index file (§J.4).
    pub fn index_path(&self) -> PathBuf {
        self.path.join("index").join("binpkg.jsonl")
    }

    /// The run-history file (§J.1, the §H.1 amendment).
    pub fn runs_path(&self) -> PathBuf {
        self.path.join("runs").join("history.jsonl")
    }

    /// The key-value store file (schema-ready for subscriptions/world).
    pub fn kv_path(&self) -> PathBuf {
        self.path.join("kv").join("kv.jsonl")
    }
}
