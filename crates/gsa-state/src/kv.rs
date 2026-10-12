//! The small key-value store (contract §J.1's `abi/` and `world`/`sets/`
//! records are its future tenants): schema-ready, not featureful — set,
//! delete and list with last-write-wins folding over the append-only log.
//! Nothing in the engine reads it yet; it exists so subscriptions and the
//! world set land on a store that already has its ownership gate and
//! corruption tolerance.

use std::io::Write;

use serde::{Deserialize, Serialize};

use crate::ownership::StateError;
use crate::store::{self, CorruptLine};
use crate::StateRoot;

#[derive(Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "kebab-case")]
enum KvEntry {
    Set { key: String, value: String },
    Del { key: String },
}

/// The key-value façade over `kv/kv.jsonl`. Values are opaque strings;
/// keys are validated (non-empty, no control characters) so one can never
/// poison the line format.
pub struct Kv;

impl Kv {
    fn check_key(key: &str) -> Result<(), StateError> {
        if key.is_empty() {
            return Err(StateError::Io("kv key must not be empty".to_string()));
        }
        if key.chars().any(|c| c.is_control()) {
            return Err(StateError::Io(format!(
                "kv key '{key}' carries control characters"
            )));
        }
        Ok(())
    }

    /// Set one key (last write wins on read).
    pub fn set(
        root: &StateRoot,
        key: &str,
        value: &str,
        err: &mut dyn Write,
    ) -> Result<(), StateError> {
        Self::check_key(key)?;
        store::append_json(
            &root.kv_path(),
            &KvEntry::Set {
                key: key.to_string(),
                value: value.to_string(),
            },
            err,
        )
    }

    /// Delete one key (a tombstone; the key disappears from [`Kv::list`]).
    pub fn delete(root: &StateRoot, key: &str, err: &mut dyn Write) -> Result<(), StateError> {
        Self::check_key(key)?;
        store::append_json(
            &root.kv_path(),
            &KvEntry::Del {
                key: key.to_string(),
            },
            err,
        )
    }

    /// One key's current value (last write wins), if it is live.
    pub fn get(root: &StateRoot, key: &str) -> Result<Option<String>, StateError> {
        Self::check_key(key)?;
        let read: store::StoreRead<KvEntry> = store::read_json(&root.kv_path(), "kv")?;
        let mut value = None;
        for entry in read.rows {
            match entry {
                KvEntry::Set { key: k, value: v } if k == key => value = Some(v),
                KvEntry::Del { key: k } if k == key => value = None,
                _ => {}
            }
        }
        Ok(value)
    }

    /// Every live key in first-set order, plus every unreadable line.
    pub fn list(root: &StateRoot) -> Result<(Vec<(String, String)>, Vec<CorruptLine>), StateError> {
        let read: store::StoreRead<KvEntry> = store::read_json(&root.kv_path(), "kv")?;
        let mut live: Vec<(String, String)> = Vec::new();
        for entry in read.rows {
            match entry {
                KvEntry::Set { key, value } => {
                    live.retain(|(k, _)| k != &key);
                    live.push((key, value));
                }
                KvEntry::Del { key } => {
                    live.retain(|(k, _)| k != &key);
                }
            }
        }
        Ok((live, read.corrupt))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("gsa-state-kv-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn set_get_delete_fold_last_write_wins() {
        let dir = scratch("fold");
        let root = StateRoot::open(&dir).unwrap();
        let mut err = Vec::new();
        Kv::set(&root, "world", "alpha", &mut err).unwrap();
        Kv::set(&root, "world", "beta", &mut err).unwrap();
        assert_eq!(Kv::get(&root, "world").unwrap(), Some("beta".into()));
        Kv::delete(&root, "world", &mut err).unwrap();
        assert_eq!(Kv::get(&root, "world").unwrap(), None);
        Kv::set(&root, "sub", "x", &mut err).unwrap();
        let (live, corrupt) = Kv::list(&root).unwrap();
        assert!(corrupt.is_empty());
        assert_eq!(live, vec![("sub".to_string(), "x".to_string())]);
    }

    #[test]
    fn a_poisoned_key_is_refused() {
        let dir = scratch("keys");
        let root = StateRoot::open(&dir).unwrap();
        let mut err = Vec::new();
        assert!(Kv::set(&root, "", "v", &mut err).is_err());
        assert!(Kv::set(&root, "a\nb", "v", &mut err).is_err());
    }
}
