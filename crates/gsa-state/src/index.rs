//! The hash-bound binpkg index (contract §J.4; plan-native-pm.md §5.2,
//! plan-gentoo-qol.md M3): one row per built instance, written by the
//! builder after a successful build, binding the archive bytes
//! (`sha256`+`size`, manifest-v2 style — signed indexes deferred by owner
//! decision). An archive whose bytes disagree with its row is index-invalid:
//! it never installs, and `--local-db-check` reports it (§D.1).
//!
//! Instance model: one successful build is ONE instance and may carry
//! several archives (a split recipe's output set) — the rows of one
//! registration share `instance`, and retention counts instances so a split
//! set is never pruned in half (the texlive 38 GB landmine is the budget
//! argument: N=2 for provider/hub recipes, N=1 elsewhere, owner decision).
//! The ABI token is derived per archive by `gsa-abi`'s ONE computation
//! (contract §J.4: hash of the shipped bare-soname provide set, merged with
//! the recipe's declared `abi-rev=` override) — never re-derived here.

use std::collections::{BTreeMap, BTreeSet};
use std::io::Write;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use gsa_graph::Graph;
use gsa_model::{Group, TopologyRecord};

use crate::ownership::StateError;
use crate::store::{self, CorruptLine};
use crate::StateRoot;

/// One retained built instance's archive row (§J.4's wire fields plus the
/// recipe id the topology knows and the instance the retention budget
/// counts).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct IndexRow {
    pub recipe_id: String,
    pub pkgbase: String,
    /// The pkgname(s) this archive carries — exactly one per makepkg
    /// archive; the list shape is §J.4's `pkgname,…` field.
    pub pkgnames: Vec<String>,
    /// Canonical full version `epoch:pkgver-pkgrel` (rule 27(a) family).
    pub version: String,
    /// The archive, still beside its recipe (§J.2) — referred to by hash,
    /// never moved.
    pub archive: PathBuf,
    pub sha256: String,
    pub size: u64,
    /// Unix epoch seconds of the registration (the build's completion).
    pub built_at: u64,
    /// Derived ABI token (`gsa-abi`: bare-soname provide-set hash merged
    /// with the declared `abi-rev=` override — §J.4).
    pub abi_token: String,
    /// Raw `.PKGINFO` provides as shipped.
    pub provides: Vec<String>,
    /// VCS revision baseline; `-` until the currency phase reads it (§J.4).
    pub vcs_baseline: String,
    /// The build instance this archive belongs to (one successful build =
    /// one instance; retention counts these).
    pub instance: u64,
}

/// The append-only index line vocabulary: rows and prune tombstones.
#[derive(Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "kebab-case")]
enum IndexEntry {
    Row {
        #[serde(flatten)]
        row: IndexRow,
    },
    Prune {
        recipe_id: String,
        instance: u64,
    },
}

/// The §J.4 wire row: `pkgbase|pkgname,…|full-version|archive-filename|
/// sha256|size|abi-token|provides|vcs-baseline|built-at` — what `-Qb`
/// prints.
pub fn wire_row(row: &IndexRow) -> String {
    let names = row.pkgnames.join(",");
    let file = row
        .archive
        .file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| row.archive.to_string_lossy().into_owned());
    let provides = if row.provides.is_empty() {
        "-".to_string()
    } else {
        row.provides.join(",")
    };
    format!(
        "{}|{}|{}|{}|{}|{}|{}|{}|{}|{}",
        row.pkgbase,
        names,
        row.version,
        file,
        row.sha256,
        row.size,
        row.abi_token,
        provides,
        row.vcs_baseline,
        row.built_at
    )
}

/// The index as a fold over the append-only store: live rows in file order,
/// with every reported line kept out (corruption-tolerant reads, §J.5).
pub struct BinpkgIndex {
    pub rows: Vec<IndexRow>,
    pub corrupt: Vec<CorruptLine>,
}

impl BinpkgIndex {
    /// Load the index fold. A missing file is the empty index — a clean
    /// checkout has no built instances recorded yet (§J.4's first build
    /// populates it).
    pub fn load(root: &StateRoot) -> Result<BinpkgIndex, StateError> {
        let read: store::StoreRead<IndexEntry> = store::read_json(&root.index_path(), "index")?;
        let mut live: BTreeMap<(String, u64), IndexRow> = BTreeMap::new();
        let mut order: Vec<(String, u64)> = Vec::new();
        for entry in read.rows {
            match entry {
                IndexEntry::Row { row } => {
                    let key = (row.recipe_id.clone(), row.instance);
                    if !live.contains_key(&key) {
                        order.push(key.clone());
                    }
                    live.insert(key, row);
                }
                IndexEntry::Prune {
                    recipe_id,
                    instance,
                } => {
                    live.remove(&(recipe_id, instance));
                }
            }
        }
        let mut rows = Vec::new();
        for key in order {
            if let Some(row) = live.remove(&key) {
                rows.push(row);
            }
        }
        Ok(BinpkgIndex {
            rows,
            corrupt: read.corrupt,
        })
    }

    /// The rows of one recipe, newest instance first.
    pub fn rows_for(&self, recipe_id: &str) -> Vec<&IndexRow> {
        let mut rows: Vec<&IndexRow> = self
            .rows
            .iter()
            .filter(|r| r.recipe_id == recipe_id)
            .collect();
        rows.sort_by_key(|r| std::cmp::Reverse(r.instance));
        rows
    }

    /// Match one index row for an archive probe (§B.3 `-Qp`): the exact
    /// path first, then the file name when it is unambiguous.
    pub fn find_archive(&self, archive: &Path) -> Option<&IndexRow> {
        if let Some(row) = self.rows.iter().find(|r| r.archive == archive) {
            return Some(row);
        }
        let name = archive.file_name()?;
        let mut hits = self
            .rows
            .iter()
            .filter(|r| r.archive.file_name().map(|n| n == name).unwrap_or(false));
        let row = hits.next()?;
        if hits.next().is_some() {
            return None; // ambiguous file name: never guess (§C.1's rule)
        }
        Some(row)
    }

    /// Live instance ids of one recipe, newest first.
    pub fn instances_for(&self, recipe_id: &str) -> Vec<u64> {
        let mut ids: Vec<u64> = self
            .rows
            .iter()
            .filter(|r| r.recipe_id == recipe_id)
            .map(|r| r.instance)
            .collect();
        ids.sort_unstable();
        ids.dedup();
        ids.reverse();
        ids
    }
}

/// How a row's archive bytes relate to its recorded `sha256`+`size`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Match {
    Agree,
    Disagree,
    Missing,
}

/// The hash/size verification of one row (§J.4: an archive whose bytes
/// disagree with its row is index-invalid).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Verification {
    pub hash: Match,
    pub size: Match,
    /// What the archive's bytes actually say, when they could be read.
    pub actual: Option<(String, u64)>,
}

impl Verification {
    pub fn agrees(&self) -> bool {
        self.hash == Match::Agree && self.size == Match::Agree
    }
}

/// Recompute one archive's `sha256`+`size` from its bytes (one streamed
/// pass — the size is what was hashed, and a file that changed mid-read is
/// a divergence, never a row).
pub fn hash_archive(path: &Path) -> Result<(String, u64), StateError> {
    use std::io::Read;
    let mut file = std::fs::File::open(path)
        .map_err(|e| StateError::Io(format!("cannot read archive {}: {e}", path.display())))?;
    let mut hasher = Sha256::new();
    let mut buf = [0u8; 65536];
    let mut size: u64 = 0;
    loop {
        let n = file
            .read(&mut buf)
            .map_err(|e| StateError::Io(format!("cannot read archive {}: {e}", path.display())))?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
        size += n as u64;
    }
    let digest = hasher.finalize();
    let sha256: String = digest.iter().map(|b| format!("{b:02x}")).collect();
    let on_disk = std::fs::metadata(path)
        .map_err(|e| StateError::Io(format!("cannot stat archive {}: {e}", path.display())))?;
    if on_disk.len() != size {
        return Err(StateError::Diverge(format!(
            "{} changed while hashing (read {size} bytes, stat {}) — row not written",
            path.display(),
            on_disk.len()
        )));
    }
    Ok((sha256, size))
}

/// Verify one row against its archive's current bytes.
pub fn verify_row(row: &IndexRow) -> Verification {
    match hash_archive(&row.archive) {
        Ok((sha256, size)) => Verification {
            hash: if sha256 == row.sha256 {
                Match::Agree
            } else {
                Match::Disagree
            },
            size: if size == row.size {
                Match::Agree
            } else {
                Match::Disagree
            },
            actual: Some((sha256, size)),
        },
        Err(_) => Verification {
            hash: Match::Missing,
            size: Match::Missing,
            actual: None,
        },
    }
}

/// The retention budget (owner decision 2 / §J.4's open decision 2):
/// N=2 built instances for provider/hub recipes — a `core` group member or
/// a recipe with ≥2 direct consumers — and N=1 everywhere else. Derived
/// from the topology through [`Graph`]; no recipe name is ever special.
pub struct Retention {
    keep: BTreeMap<String, usize>,
}

impl Retention {
    /// Derive the per-recipe budget from the build-order graph: hub =
    /// `core` membership or ≥2 direct consumers (records that name the
    /// recipe in their build-order edges).
    pub fn from_graph(graph: &Graph<'_>) -> Retention {
        let mut keep = BTreeMap::new();
        for (idx, record) in graph.records().iter().enumerate() {
            let consumers = (0..graph.len())
                .filter(|&j| graph.prerequisites(j).contains(&idx))
                .count();
            let hub = record.groups.contains(&Group::Core) || consumers >= 2;
            keep.insert(record.id.as_str().to_string(), if hub { 2 } else { 1 });
        }
        Retention { keep }
    }

    /// From raw topology records (the test/synthetic-workspace seam).
    pub fn from_records(records: &[TopologyRecord]) -> Result<Retention, String> {
        let graph = Graph::build(records).map_err(|e| e.to_string())?;
        Ok(Retention::from_graph(&graph))
    }

    /// Instances kept for one recipe; anything not in the topology is
    /// budgeted N=1 (never a name-matched special case).
    pub fn keep_for(&self, recipe_id: &str) -> usize {
        self.keep.get(recipe_id).copied().unwrap_or(1)
    }
}

/// Tombstone one recipe's built instance (the maint doctor's and the prune
/// strengths' side-car repair): its rows die in the fold, exactly like the
/// retention sweep's tombstones. Archive files are the CALLER's business —
/// this never touches bytes on disk. `true` when at least one live row was
/// tombstoned; `false` when the instance was already gone.
pub fn prune_instance(
    root: &StateRoot,
    recipe_id: &str,
    instance: u64,
    err: &mut dyn Write,
) -> Result<bool, StateError> {
    let index = BinpkgIndex::load(root)?;
    let live = index
        .rows
        .iter()
        .any(|r| r.recipe_id == recipe_id && r.instance == instance);
    if !live {
        return Ok(false);
    }
    store::append_json(
        &root.index_path(),
        &IndexEntry::Prune {
            recipe_id: recipe_id.to_string(),
            instance,
        },
        err,
    )?;
    Ok(true)
}

/// Reindex one archive that has no live row (the maint doctor's
/// `reindex-orphans` repair): `.PKGINFO` truth plus `sha256`+`size` from one
/// read of the bytes, fail closed exactly like [`register_instance`]. The
/// archive becomes its OWN instance beyond every instance id ever recorded
/// (tombstoned ones included — an id is never reused) — the doctor cannot
/// recover which build produced which file, and inventing a shared instance
/// would fake a split set. No retention is enforced here: a repair never
/// deletes anything.
pub fn reindex_archives(
    root: &StateRoot,
    recipe_id: &str,
    archives: &[PathBuf],
    err: &mut dyn Write,
) -> Result<Vec<IndexRow>, StateError> {
    let index = BinpkgIndex::load(root)?;
    let read: store::StoreRead<IndexEntry> = store::read_json(&root.index_path(), "index")?;
    let mut instance = read
        .rows
        .iter()
        .filter_map(|entry| match entry {
            IndexEntry::Row { row } if row.recipe_id == recipe_id => Some(row.instance),
            _ => None,
        })
        .max()
        .unwrap_or(0);
    let mut out = Vec::new();
    for archive in archives {
        if index.rows.iter().any(|r| r.archive == *archive) {
            continue;
        }
        let info = gsa_recipe::pkginfo::read_pkginfo(archive).map_err(|e| {
            StateError::Diverge(format!(
                "{}: {e} — no index row without .PKGINFO truth",
                archive.display()
            ))
        })?;
        let (sha256, size) = hash_archive(archive)?;
        instance += 1;
        let row = IndexRow {
            recipe_id: recipe_id.to_string(),
            pkgbase: info.pkgbase,
            pkgnames: vec![info.pkgname],
            version: info.version,
            archive: archive.clone(),
            sha256,
            size,
            built_at: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0),
            abi_token: "-".to_string(),
            provides: info.provides,
            vcs_baseline: "-".to_string(),
            instance,
        };
        store::append_json(
            &root.index_path(),
            &IndexEntry::Row { row: row.clone() },
            err,
        )?;
        out.push(row);
    }
    Ok(out)
}

/// What one registration + retention sweep did (the builder renders these
/// rows as `note:` diagnostics, §K.1's loud reporting).
#[derive(Clone, Debug, Default)]
pub struct RegisterOutcome {
    /// The rows written for this build's instance.
    pub rows: Vec<IndexRow>,
    /// Rows pruned away (their archive files deleted, unless a surviving
    /// row still references the same path — see the delete guard).
    pub pruned: Vec<IndexRow>,
    /// Recipes whose pruning was deferred — their lanes are still in
    /// flight and their archives are in use by the run (§J.4's guard).
    pub deferred: Vec<String>,
    pub notes: Vec<String>,
}

/// Record one successful build's archive set in the index, then enforce the
/// retention budget (§J.4). Fail closed: a row is written only with both
/// `sha256` and `size` known from the same read of the archive bytes, and
/// an instance whose metadata cannot be read is recorded not at all. Each
/// row's `abi_token` comes from `gsa-abi`'s ONE derivation (the archive's
/// `.PKGINFO` provides + shipped ELF `DT_SONAME`, merged with the recipe's
/// declared `abi-rev=` override).
///
/// `in_flight` is the run's set of recipe ids whose lanes are still
/// building (contract §K.1): pruning never deletes an archive a run is
/// currently using, so those recipes are swept later, loudly deferred here.
/// The registering recipe itself is never in that set — its lane is done,
/// and its newest instance is what the pending install will use.
pub fn register_instance(
    root: &StateRoot,
    recipe_id: &str,
    archives: &[PathBuf],
    retention: &Retention,
    in_flight: &BTreeSet<String>,
    abi_rev: Option<u64>,
    err: &mut dyn Write,
) -> Result<RegisterOutcome, StateError> {
    let mut outcome = RegisterOutcome::default();
    let index = BinpkgIndex::load(root)?;
    let instance = index.instances_for(recipe_id).first().copied().unwrap_or(0) + 1;
    let built_at = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);

    // The rows, fail closed (§J.4): metadata truth is the archive's own
    // `.PKGINFO`, hash+size come from one streamed read of the bytes.
    let mut rows = Vec::new();
    for archive in archives {
        let info = gsa_recipe::pkginfo::read_pkginfo(archive).map_err(|e| {
            StateError::Diverge(format!(
                "{}: {e} — no index row without .PKGINFO truth",
                archive.display()
            ))
        })?;
        let (sha256, size) = hash_archive(archive)?;
        // The one shared abi-token derivation (gsa-abi, §J.4): fail closed —
        // no row without token truth, so a later wave can trust every row.
        let token = gsa_abi::token_for_archive(archive, abi_rev).map_err(|e| {
            StateError::Diverge(format!(
                "{}: {e} — no index row without derived abi-token truth",
                archive.display()
            ))
        })?;
        rows.push(IndexRow {
            recipe_id: recipe_id.to_string(),
            pkgbase: info.pkgbase,
            pkgnames: vec![info.pkgname],
            version: info.version,
            archive: archive.clone(),
            sha256,
            size,
            built_at,
            abi_token: token.effective,
            provides: info.provides,
            vcs_baseline: "-".to_string(),
            instance,
        });
    }
    for row in &rows {
        store::append_json(
            &root.index_path(),
            &IndexEntry::Row { row: row.clone() },
            err,
        )?;
    }
    outcome.notes.push(format!(
        "binpkg index: registered {} archive(s) for {recipe_id} (instance {instance})",
        rows.len()
    ));
    outcome.rows = rows;

    // Retention enforcement (owner decision 2): sweep every recipe in the
    // index to its budget, newest instances kept, oldest instances pruned
    // with their archive files deleted. In-flight recipes are never swept.
    let mut by_recipe: BTreeMap<String, Vec<u64>> = BTreeMap::new();
    for row in &index.rows {
        by_recipe
            .entry(row.recipe_id.clone())
            .or_default()
            .push(row.instance);
    }
    // The just-registered instance is part of the sweep too (its recipe's
    // lane is done — see the guard above).
    by_recipe
        .entry(recipe_id.to_string())
        .or_default()
        .push(instance);
    // Decide the whole prune set BEFORE deleting anything. A same-version
    // rebuild writes a new row for the SAME PKGDEST path, so one file can be
    // referenced by rows on both sides of the budget line; deleting a file a
    // kept row references destroys the very evidence a `--skip` claim just
    // used ("the claim consumed its own archive"). The delete half is
    // therefore guarded by path: a file any surviving row references stays.
    let mut drops: Vec<(String, u64)> = Vec::new();
    for (id, instances) in by_recipe {
        let mut instances = instances;
        instances.sort_unstable();
        instances.dedup();
        instances.reverse(); // newest first
        let keep = retention.keep_for(&id);
        if instances.len() <= keep {
            continue;
        }
        if in_flight.contains(&id) {
            outcome.deferred.push(id.clone());
            outcome.notes.push(format!(
                "binpkg index: retention deferred {id} (lane in flight)"
            ));
            continue;
        }
        for dropped in &instances[keep..] {
            drops.push((id.clone(), *dropped));
        }
    }
    let dropped_keys: BTreeSet<(String, u64)> = drops.iter().cloned().collect();
    let mut kept_paths: BTreeSet<PathBuf> = BTreeSet::new();
    for row in &index.rows {
        if !dropped_keys.contains(&(row.recipe_id.clone(), row.instance)) {
            kept_paths.insert(row.archive.clone());
        }
    }
    for row in &outcome.rows {
        kept_paths.insert(row.archive.clone());
    }
    for (id, dropped) in drops {
        for row in index
            .rows
            .iter()
            .filter(|r| r.recipe_id == id && r.instance == dropped)
        {
            store::append_json(
                &root.index_path(),
                &IndexEntry::Prune {
                    recipe_id: id.clone(),
                    instance: dropped,
                },
                err,
            )?;
            let file = row.archive.clone();
            if kept_paths.contains(&file) {
                outcome.notes.push(format!(
                    "binpkg index: retention pruned {id} instance {dropped} (archive kept — a kept row still references it)"
                ));
                outcome.pruned.push(row.clone());
                continue;
            }
            match std::fs::remove_file(&file) {
                Ok(()) => outcome.notes.push(format!(
                    "binpkg index: retention pruned {id} instance {dropped} ({})",
                    file.file_name()
                        .map(|n| n.to_string_lossy().into_owned())
                        .unwrap_or_else(|| file.to_string_lossy().into_owned())
                )),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => outcome.notes.push(format!(
                    "binpkg index: retention pruned {id} instance {dropped} (archive already gone)"
                )),
                Err(e) => outcome.notes.push(format!(
                    "binpkg index: retention could not delete {} ({e}) — remove it by hand",
                    file.display()
                )),
            }
            outcome.pruned.push(row.clone());
        }
    }
    Ok(outcome)
}

#[cfg(test)]
mod tests {
    use super::*;
    use gsa_model::{Group, RecipeId};

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir =
            std::env::temp_dir().join(format!("gsa-state-index-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn record(id: &str, groups: &[Group], edges: &[&str]) -> TopologyRecord {
        TopologyRecord {
            id: RecipeId::new(id).unwrap(),
            path: format!("packages/{id}"),
            groups: groups.to_vec(),
            edges: edges.iter().map(|e| RecipeId::new(*e).unwrap()).collect(),
            tags: Vec::new(),
            source_line: 1,
        }
    }

    fn make_archive(dir: &Path, name: &str, version: &str) -> PathBuf {
        use std::io::Write as _;
        let stage = dir.join(format!("stage-{name}"));
        std::fs::create_dir_all(&stage).unwrap();
        let mut body = Vec::new();
        writeln!(body, "pkgbase = {name}").unwrap();
        writeln!(body, "pkgname = {name}").unwrap();
        writeln!(body, "pkgver = {version}").unwrap();
        writeln!(body, "arch = any").unwrap();
        writeln!(body, "provides = lib{name}.so").unwrap();
        std::fs::write(stage.join(".PKGINFO"), &body).unwrap();
        let out = dir.join(format!("{name}-{version}-any.pkg.tar.zst"));
        let file = std::fs::File::create(&out).unwrap();
        let enc = zstd::stream::Encoder::new(file, 0).unwrap();
        let mut tar = tar::Builder::new(enc);
        tar.append_dir_all(".", &stage).unwrap();
        let enc = tar.into_inner().unwrap();
        enc.finish().unwrap();
        std::fs::remove_dir_all(&stage).unwrap();
        out
    }

    /// Three recipes: `hub` is a `core` member, `fanin` has two direct
    /// consumers, `leaf` has none and is not core.
    fn synthetic_topology() -> Vec<TopologyRecord> {
        vec![
            record("hub", &[Group::Core], &[]),
            record("fanin", &[Group::Git], &[]),
            record("consumer-a", &[Group::Git], &["fanin"]),
            record("consumer-b", &[Group::Git], &["fanin"]),
            record("leaf", &[Group::Misc], &[]),
        ]
    }

    #[test]
    fn retention_decisions_come_from_the_topology() {
        let retention = Retention::from_records(&synthetic_topology()).unwrap();
        assert_eq!(retention.keep_for("hub"), 2, "core member is a hub");
        assert_eq!(retention.keep_for("fanin"), 2, "two consumers is a hub");
        assert_eq!(retention.keep_for("leaf"), 1, "a leaf keeps one instance");
        assert_eq!(
            retention.keep_for("unknown"),
            1,
            "never a name-matched special case"
        );
    }

    #[test]
    fn index_round_trip_binds_the_archive_hash() {
        let dir = scratch("roundtrip");
        let root = StateRoot::open(&dir).unwrap();
        let archive = make_archive(&dir, "leaf", "1.0.0-1");
        let retention = Retention::from_records(&synthetic_topology()).unwrap();
        let mut err = Vec::new();
        let outcome = register_instance(
            &root,
            "leaf",
            &[archive.clone()],
            &retention,
            &BTreeSet::new(),
            None,
            &mut err,
        )
        .unwrap();
        assert_eq!(outcome.rows.len(), 1);
        let row = outcome.rows[0].clone();
        assert_eq!(row.recipe_id, "leaf");
        assert_eq!(row.version, "0:1.0.0-1");
        assert_eq!(row.pkgnames, vec!["leaf".to_string()]);
        // The ABI token is derived truth (§J.4): the shipped bare-soname
        // provide set, computed by gsa-abi — never the `-` placeholder.
        let expected = gsa_abi::token_declared(&["libleaf.so".to_string()], None).effective;
        assert_eq!(
            row.abi_token, expected,
            "derived abi-token lands at registration"
        );
        assert_eq!(row.instance, 1);

        // The store round-trips the row and the hash verifies its bytes.
        let index = BinpkgIndex::load(&root).unwrap();
        assert!(index.corrupt.is_empty());
        assert_eq!(index.rows, vec![row.clone()]);
        let verification = verify_row(&row);
        assert!(verification.agrees(), "{verification:?}");
        assert_eq!(verification.actual.unwrap().0, row.sha256);

        // Tampered bytes are index-invalid (§J.4): the mismatch is loud.
        let mut bytes = std::fs::read(&archive).unwrap();
        bytes.push(0);
        std::fs::write(&archive, &bytes).unwrap();
        let tampered = verify_row(&row);
        assert_eq!(tampered.hash, Match::Disagree);
        assert_eq!(tampered.size, Match::Disagree);
    }

    #[test]
    fn retention_keeps_two_hub_instances_and_one_leaf() {
        let dir = scratch("retention");
        let root = StateRoot::open(&dir).unwrap();
        let retention = Retention::from_records(&synthetic_topology()).unwrap();
        let mut err = Vec::new();
        let in_flight = BTreeSet::new();

        // The leaf: two registrations → the newest instance survives.
        for version in ["1.0.0-1", "1.0.1-1"] {
            let archive = make_archive(&dir, "leaf", version);
            register_instance(
                &root,
                "leaf",
                &[archive],
                &retention,
                &in_flight,
                None,
                &mut err,
            )
            .unwrap();
        }
        // The hub (core): three registrations → two survive.
        for version in ["1.0.0-1", "1.0.1-1", "1.0.2-1"] {
            let archive = make_archive(&dir, "hub", version);
            register_instance(
                &root,
                "hub",
                &[archive],
                &retention,
                &in_flight,
                None,
                &mut err,
            )
            .unwrap();
        }

        let index = BinpkgIndex::load(&root).unwrap();
        assert_eq!(
            index.instances_for("leaf"),
            vec![2],
            "a leaf keeps one built instance"
        );
        assert_eq!(
            index.instances_for("hub"),
            vec![3, 2],
            "a hub keeps two built instances, newest first"
        );
        // Pruned instances are tombstoned AND their archives deleted.
        let leaf_archives: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().starts_with("leaf-"))
            .collect();
        assert_eq!(leaf_archives.len(), 1, "the pruned leaf archive is deleted");
        let hub_archives: Vec<_> = std::fs::read_dir(&dir)
            .unwrap()
            .flatten()
            .filter(|e| e.file_name().to_string_lossy().starts_with("hub-"))
            .collect();
        assert_eq!(hub_archives.len(), 2);
    }

    #[test]
    fn retention_prune_never_deletes_a_path_a_kept_row_references() {
        // A same-version rebuild writes a new row for the SAME PKGDEST name,
        // so one file sits behind two instances. Pruning the older instance
        // must tombstone its row but leave the file: the kept row's evidence
        // (and the `--skip` claim built on it) may never be deleted by
        // retention ("the claim consumed its own archive").
        let dir = scratch("shared-path");
        let root = StateRoot::open(&dir).unwrap();
        let retention = Retention::from_records(&synthetic_topology()).unwrap();
        let mut err = Vec::new();
        let in_flight = BTreeSet::new();

        let mut outcome = None;
        for _ in 0..2 {
            let archive = make_archive(&dir, "leaf", "1.0.0-1");
            outcome = Some(
                register_instance(
                    &root,
                    "leaf",
                    &[archive.clone()],
                    &retention,
                    &in_flight,
                    None,
                    &mut err,
                )
                .unwrap(),
            );
        }
        let outcome = outcome.unwrap();
        assert_eq!(outcome.pruned.len(), 1, "the older instance is pruned");
        assert_eq!(outcome.pruned[0].instance, 1);
        assert!(
            outcome.notes.iter().any(|n| n.contains("archive kept")),
            "the kept file is reported, not deleted: {:?}",
            outcome.notes
        );
        assert!(
            dir.join("leaf-1.0.0-1-any.pkg.tar.zst").exists(),
            "the archive a kept row references survives the sweep"
        );
        let index = BinpkgIndex::load(&root).unwrap();
        assert_eq!(index.instances_for("leaf"), vec![2]);
    }

    #[test]
    fn pruning_never_touches_an_in_flight_recipe() {
        let dir = scratch("inflight");
        let root = StateRoot::open(&dir).unwrap();
        let retention = Retention::from_records(&synthetic_topology()).unwrap();
        let mut err = Vec::new();
        let mut in_flight = BTreeSet::new();
        in_flight.insert("leaf".to_string());

        // Two instances for a leaf (over budget) while its lane is in
        // flight: the sweep defers, loudly, and deletes nothing. The first
        // registration is still within budget — no deferral needed.
        for (n, version) in ["1.0.0-1", "1.0.1-1"].into_iter().enumerate() {
            let archive = make_archive(&dir, "leaf", version);
            let outcome = register_instance(
                &root,
                "leaf",
                &[archive],
                &retention,
                &in_flight,
                None,
                &mut err,
            )
            .unwrap();
            assert!(outcome.pruned.is_empty());
            if n == 0 {
                assert!(
                    outcome.deferred.is_empty(),
                    "within budget needs no deferral"
                );
            } else {
                assert_eq!(outcome.deferred, vec!["leaf".to_string()]);
                assert!(outcome
                    .notes
                    .iter()
                    .any(|n| n.contains("retention deferred leaf (lane in flight)")));
            }
        }
        let index = BinpkgIndex::load(&root).unwrap();
        assert_eq!(
            index.instances_for("leaf"),
            vec![2, 1],
            "over budget, in flight"
        );

        // Once the lane settles, the next sweep converges to the budget.
        in_flight.clear();
        let archive = make_archive(&dir, "leaf", "1.0.2-1");
        let outcome = register_instance(
            &root,
            "leaf",
            &[archive],
            &retention,
            &in_flight,
            None,
            &mut err,
        )
        .unwrap();
        assert!(!outcome.pruned.is_empty());
        let index = BinpkgIndex::load(&root).unwrap();
        assert_eq!(index.instances_for("leaf"), vec![3]);
    }

    #[test]
    fn a_row_is_written_only_with_hash_and_size_known() {
        let dir = scratch("failclosed");
        let root = StateRoot::open(&dir).unwrap();
        let retention = Retention::from_records(&synthetic_topology()).unwrap();
        let mut err = Vec::new();
        let missing = dir.join("no-such-archive.pkg.tar.zst");
        let result = register_instance(
            &root,
            "leaf",
            &[missing.clone()],
            &retention,
            &BTreeSet::new(),
            None,
            &mut err,
        );
        assert!(result.is_err(), "no metadata truth, no row (fail closed)");
        let index = BinpkgIndex::load(&root).unwrap();
        assert!(index.rows.is_empty());
    }

    #[test]
    fn prune_instance_tombstones_rows_and_reindex_rebuilds_them() {
        let dir = scratch("maint");
        let root = StateRoot::open(&dir).unwrap();
        let retention = Retention::from_records(&synthetic_topology()).unwrap();
        let mut err = Vec::new();
        let archive = make_archive(&dir, "leaf", "1.0.0-1");
        register_instance(
            &root,
            "leaf",
            &[archive.clone()],
            &retention,
            &BTreeSet::new(),
            None,
            &mut err,
        )
        .unwrap();

        // Tombstone: the instance dies in the fold; the archive is the
        // caller's business and survives untouched here.
        assert!(prune_instance(&root, "leaf", 1, &mut err).unwrap());
        let index = BinpkgIndex::load(&root).unwrap();
        assert!(index.rows.is_empty(), "the tombstone kills the row");
        assert!(archive.exists(), "prune_instance never touches bytes");
        assert!(
            !prune_instance(&root, "leaf", 1, &mut err).unwrap(),
            "an already-dead instance reports no-op"
        );

        // Reindex: the orphan archive's bytes become a fresh, hash-bound
        // row — fail closed on a missing .PKGINFO, and never a duplicate
        // row for an already-indexed archive.
        let rows = reindex_archives(&root, "leaf", &[archive.clone()], &mut err).unwrap();
        assert_eq!(rows.len(), 1);
        let row = &rows[0];
        assert_eq!(row.instance, 2, "the reindexed archive is its own instance");
        assert!(verify_row(row).agrees(), "the row binds the bytes");
        let again = reindex_archives(&root, "leaf", &[archive.clone()], &mut err).unwrap();
        assert!(again.is_empty(), "an indexed archive is never re-indexed");
        let not_an_archive = dir.join("stray.pkg.tar.zst");
        std::fs::write(&not_an_archive, b"no pkginfo truth").unwrap();
        assert!(
            reindex_archives(&root, "leaf", &[not_an_archive], &mut err).is_err(),
            "no .PKGINFO truth, no row (fail closed)"
        );
        let index = BinpkgIndex::load(&root).unwrap();
        assert_eq!(index.rows.len(), 1, "the failed reindex wrote nothing");
    }
}
