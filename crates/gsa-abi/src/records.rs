//! Subscription records — the `:=` analogue (plan-native-pm.md §4.2,
//! contract §J.1 `/var/lib/gsa/abi/`): `consumer|version|provider|token`,
//! written at install time ("the installed-ABI record"), read by the wave
//! planner and `-Qa`. One row per (consumer, provider) pair, latest wins.
//!
//! Storage is a line store under the state root (`abi/subscriptions`),
//! append-only; the load is corruption-tolerant (a malformed line is
//! reported and skipped — never guessed) and latest-wins per key.

use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};

/// One recorded `:=` subscription: at `consumer` `version`'s build/install,
/// `provider`'s abi-token was `token`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Subscription {
    pub consumer: String,
    pub version: String,
    pub provider: String,
    pub token: String,
}

impl Subscription {
    /// The §J.1 wire line.
    pub fn wire(&self) -> String {
        format!(
            "{}|{}|{}|{}",
            self.consumer, self.version, self.provider, self.token
        )
    }

    /// Parse one wire line strictly: exactly four non-empty fields.
    pub fn parse(line: &str) -> Option<Subscription> {
        let fields: Vec<&str> = line.split('|').collect();
        if fields.len() != 4 {
            return None;
        }
        let [consumer, version, provider, token] = [fields[0], fields[1], fields[2], fields[3]];
        if [consumer, version, provider, token]
            .iter()
            .any(|f| f.trim().is_empty() || f.contains('\n'))
        {
            return None;
        }
        Some(Subscription {
            consumer: consumer.to_string(),
            version: version.to_string(),
            provider: provider.to_string(),
            token: token.to_string(),
        })
    }
}

/// The subscription store: live rows (latest per `(consumer, provider)` in
/// file order) plus the corrupt lines the load reported.
#[derive(Clone, Debug, Default)]
pub struct Subscriptions {
    rows: Vec<Subscription>,
    pub corrupt: Vec<String>,
}

impl Subscriptions {
    pub fn empty() -> Subscriptions {
        Subscriptions::default()
    }

    /// Load the store. A missing file is the empty store (a clean checkout
    /// has no installed-ABI records yet); malformed lines are reported in
    /// `corrupt` and never guessed.
    pub fn load(path: &Path) -> Result<Subscriptions, String> {
        let text = match std::fs::read_to_string(path) {
            Ok(text) => text,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Subscriptions::empty()),
            Err(e) => return Err(format!("cannot read {}: {e}", path.display())),
        };
        let mut store = Subscriptions::empty();
        for (idx, line) in text.lines().enumerate() {
            if line.trim().is_empty() {
                continue;
            }
            match Subscription::parse(line) {
                Some(sub) => store.upsert(sub),
                None => store.corrupt.push(format!(
                    "{}:{}: malformed subscription line",
                    path.display(),
                    idx + 1
                )),
            }
        }
        Ok(store)
    }

    /// Insert or replace the `(consumer, provider)` row (latest wins).
    pub fn upsert(&mut self, sub: Subscription) {
        self.rows
            .retain(|r| !(r.consumer == sub.consumer && r.provider == sub.provider));
        self.rows.push(sub);
    }

    /// Append one row to the store file (creating the parent directory
    /// first). The line is a single append write — readers never see half a
    /// row.
    pub fn append(path: &Path, sub: &Subscription) -> Result<(), String> {
        if let Some(dir) = path.parent() {
            std::fs::create_dir_all(dir)
                .map_err(|e| format!("cannot create {}: {e}", dir.display()))?;
        }
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .map_err(|e| format!("cannot open {}: {e}", path.display()))?;
        writeln!(file, "{}", sub.wire())
            .map_err(|e| format!("cannot write {}: {e}", path.display()))
    }

    pub fn rows(&self) -> &[Subscription] {
        &self.rows
    }

    /// What `consumer` recorded for `provider` at its last install.
    pub fn token_for(&self, consumer: &str, provider: &str) -> Option<&str> {
        self.rows
            .iter()
            .find(|r| r.consumer == consumer && r.provider == provider)
            .map(|r| r.token.as_str())
    }

    /// Every row naming `provider` (the `-Qa` "in" side).
    pub fn for_provider(&self, provider: &str) -> Vec<&Subscription> {
        self.rows
            .iter()
            .filter(|r| r.provider == provider)
            .collect()
    }

    /// Every row `consumer` recorded (the `-Qa` "out" side).
    pub fn for_consumer(&self, consumer: &str) -> Vec<&Subscription> {
        self.rows
            .iter()
            .filter(|r| r.consumer == consumer)
            .collect()
    }

    /// Do any recorded rows name this provider (the wave planner's
    /// "records exist for P" test)?
    pub fn has_records_for(&self, provider: &str) -> bool {
        self.rows.iter().any(|r| r.provider == provider)
    }

    /// Merge another store's rows (latest of `other` wins).
    pub fn merge(&mut self, other: Subscriptions) {
        for row in other.rows {
            self.upsert(row);
        }
        self.corrupt.extend(other.corrupt);
    }

    /// Group rows by provider (BTreeMap for deterministic iteration).
    pub fn by_provider(&self) -> BTreeMap<String, Vec<&Subscription>> {
        let mut map: BTreeMap<String, Vec<&Subscription>> = BTreeMap::new();
        for row in &self.rows {
            map.entry(row.provider.clone()).or_default().push(row);
        }
        map
    }
}

/// The store path under a state root (contract §J.1).
pub fn subscriptions_path(state_root: &Path) -> PathBuf {
    state_root.join("abi").join("subscriptions")
}

/// The `:=` subscription rows one installed consumer records (the
/// installed-ABI record of plan §4.1): each `DT_NEEDED` of the consumer
/// archive that resolves through an installed provider records
/// `consumer|version|provider|<provider's current abi-token>`.
/// `resolve` maps an installed provider package to `(provider id, token)` —
/// the caller's one token computation (binpkg index row when a built
/// instance is recorded, else the derived installed-surface token).
/// `Err` = the archive could not be probed; the caller fails closed toward
/// the wave planner's whole-closure fallback (records missing ⇒ rebuild).
pub fn subscriptions_for_install(
    consumer: &str,
    version: &str,
    consumer_archive: &std::path::Path,
    view: &crate::view::InstalledView,
    resolve: &dyn Fn(&crate::view::InstalledPkg) -> Option<(String, String)>,
) -> Result<Vec<Subscription>, String> {
    use crate::provides::base_lib_ok;
    let members = gsa_recipe::pkginfo::members_with_needed(consumer_archive)?;
    let mut needed: Vec<String> = Vec::new();
    for (_, names) in members {
        for name in names {
            if !base_lib_ok(&name) && !needed.contains(&name) {
                needed.push(name);
            }
        }
    }
    let mut rows = Vec::new();
    for name in needed {
        let provider = view
            .providers_of(&name)
            .into_iter()
            .chain(view.file_owners(&name))
            .next();
        let Some(provider) = provider else {
            continue; // nothing to subscribe to (an unresolved need is the
                      // revdep surface's finding, not a record)
        };
        let Some((provider_id, token)) = resolve(provider) else {
            continue; // no trustworthy token: record nothing (fail toward)
        };
        rows.push(Subscription {
            consumer: consumer.to_string(),
            version: version.to_string(),
            provider: provider_id,
            token,
        });
    }
    rows.sort_by(|a, b| a.provider.cmp(&b.provider));
    rows.dedup_by(|a, b| a.provider == b.provider);
    Ok(rows)
}

/// Record one freshly installed consumer's subscriptions into the state
/// root's store (the installed-ABI record at install time, §J.1). Returns
/// the rows written; `Err` = the store could not be written (the caller
/// reports loudly — the wave planner fails toward whole-closure on missing
/// records, never under).
pub fn record_install(
    state_root: &std::path::Path,
    consumer: &str,
    version: &str,
    consumer_archive: &std::path::Path,
    view: &crate::view::InstalledView,
    resolve: &dyn Fn(&crate::view::InstalledPkg) -> Option<(String, String)>,
) -> Result<Vec<Subscription>, String> {
    let rows = subscriptions_for_install(consumer, version, consumer_archive, view, resolve)?;
    let path = subscriptions_path(state_root);
    for row in &rows {
        Subscriptions::append(&path, row)?;
    }
    Ok(rows)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sub(c: &str, p: &str, t: &str) -> Subscription {
        Subscription {
            consumer: c.to_string(),
            version: "0:1.0.0-1".to_string(),
            provider: p.to_string(),
            token: t.to_string(),
        }
    }

    #[test]
    fn wire_and_parse_round_trip() {
        let s = sub("c1", "p1", "rev2-abc");
        assert_eq!(Subscription::parse(&s.wire()), Some(s));
        assert_eq!(Subscription::parse("a|b|c"), None, "three fields");
        assert_eq!(Subscription::parse("a||c|d"), None, "empty field");
    }

    #[test]
    fn latest_wins_per_consumer_provider_pair() {
        let dir = std::env::temp_dir().join(format!("gsa-abi-records-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let path = subscriptions_path(&dir);
        Subscriptions::append(&path, &sub("c1", "p1", "old")).unwrap();
        Subscriptions::append(&path, &sub("c1", "p1", "new")).unwrap();
        Subscriptions::append(&path, &sub("c2", "p1", "tok")).unwrap();
        let store = Subscriptions::load(&path).unwrap();
        assert!(store.corrupt.is_empty());
        assert_eq!(store.token_for("c1", "p1"), Some("new"));
        assert_eq!(store.token_for("c2", "p1"), Some("tok"));
        assert_eq!(store.token_for("c1", "p2"), None);
        assert_eq!(store.for_provider("p1").len(), 2);
        assert_eq!(store.for_consumer("c1").len(), 1);
        assert!(store.has_records_for("p1"));
        assert!(!store.has_records_for("p9"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn malformed_lines_are_reported_never_guessed() {
        let dir = std::env::temp_dir().join(format!("gsa-abi-records-bad-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let path = subscriptions_path(&dir);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(
            &path,
            "c1|0:1-1|p1|tok\nnot-a-row\nc2|0:1-1|p2|\nc3|0:1-1|p3|tok3\n",
        )
        .unwrap();
        let store = Subscriptions::load(&path).unwrap();
        assert_eq!(store.corrupt.len(), 2, "two malformed lines reported");
        assert_eq!(store.rows().len(), 2);
        assert_eq!(store.token_for("c1", "p1"), Some("tok"));
        assert_eq!(store.token_for("c3", "p3"), Some("tok3"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
