//! Shared fixtures for the `gsa-maint` integration tests. Every test builds
//! its own scratch tree under `std::env::temp_dir()` (the harness `$TMPDIR`)
//! in a uniquely named directory and removes it on drop; nothing here reads
//! or writes `/var/lib/gsa`, `/etc/pacman.conf`, or any path outside the
//! scratch tree.
#![allow(dead_code)]

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Mutex, MutexGuard};
use std::time::{Duration, SystemTime};

use gsa_model::{
    Continuation, OutcomeRow, PlanAction, PlanRow, RecipeId, RowStatus, RunOutcome, RunRecord,
};
use gsa_state::{RunHistory, StateRoot};

use gsa_maint::Row;

static COUNTER: AtomicU32 = AtomicU32::new(0);

/// The build-cache subtree under the fixture root that [`Fixture::with_ctx`]
/// pins `GSA_BUILD_DIR` to (the W4a live homes live below it).
pub const CACHE_DIR: &str = ".gsa-cache";
/// The pulled-source home `Fixture::with_ctx` pins `SRCDEST` to.
pub const SRCDEST_DIR: &str = ".gsa-srcdest";

/// The layout seams (`GSA_CONF`/`GSA_BUILD_DIR`/`SRCDEST`) are resolved from
/// process env, and Rust runs one test binary's tests in parallel threads —
/// so every ctx pass pins them to THIS fixture's scratch under a crate-wide
/// lock (tests/lib/rr-v2.bash's `rr2_invoke` guard, mirrored for unit tests:
/// a scan must never reach the host's real build cache or SRCDEST mirror)
/// and restores the previous values on the way out.
static LAYOUT_LOCK: Mutex<()> = Mutex::new(());

struct LayoutEnv {
    _lock: MutexGuard<'static, ()>,
    saved: Vec<(&'static str, Option<OsString>)>,
}

impl LayoutEnv {
    fn pin(root: &Path) -> LayoutEnv {
        let lock = LAYOUT_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        // Filesystem-silent: the conf file itself is fixture construction
        // (`Fixture::new`), because dry-run tests snapshot the tree across
        // a `with_ctx` pass and must see no change.
        let pinned: [(&'static str, OsString); 3] = [
            ("GSA_CONF", root.join("gsa.conf").into_os_string()),
            ("GSA_BUILD_DIR", root.join(CACHE_DIR).into_os_string()),
            ("SRCDEST", root.join(SRCDEST_DIR).into_os_string()),
        ];
        let mut saved = Vec::new();
        for (key, value) in pinned {
            saved.push((key, std::env::var_os(key)));
            std::env::set_var(key, &value);
        }
        LayoutEnv {
            _lock: lock,
            saved,
        }
    }
}

impl Drop for LayoutEnv {
    fn drop(&mut self) {
        for (key, value) in self.saved.drain(..) {
            match value {
                Some(value) => std::env::set_var(key, value),
                None => std::env::remove_var(key),
            }
        }
    }
}

/// A unique scratch directory under the harness `$TMPDIR`, removed first so
/// a crashed previous run cannot fake a result.
pub fn scratch_dir(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "gsa-maint-test-{name}-{}-{}",
        std::process::id(),
        COUNTER.fetch_add(1, Ordering::SeqCst)
    ));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

/// A synthetic recipe repository + state root. `Drop` removes the tree.
pub struct Fixture {
    pub root: PathBuf,
    pub state_dir: PathBuf,
    topology: Vec<String>,
}

impl Fixture {
    pub fn new(name: &str) -> Fixture {
        let root = scratch_dir(name);
        std::fs::create_dir_all(root.join("config")).unwrap();
        std::fs::create_dir_all(root.join("packages")).unwrap();
        std::fs::write(
            root.join("config").join("build-defaults.conf"),
            "# fixture\n",
        )
        .unwrap();
        let state_dir = root.join(".state");
        // Open the state root up front so its store directories exist in
        // every before/after snapshot (opening is construction, never a
        // verb mutation).
        StateRoot::open(&state_dir).unwrap();
        // The empty gsa.conf the layout pin points GSA_CONF at (also
        // construction: dry-run snapshots must stay stable across a
        // `with_ctx` pass).
        std::fs::write(root.join("gsa.conf"), "# fixture: empty layers\n").unwrap();
        Fixture {
            root,
            state_dir,
            topology: Vec::new(),
        }
    }

    /// Add one recipe (`packages/<cat>/<id>`): a `PKGBUILD` stub, the given
    /// committed `.SRCINFO`, and a topology record `id|path|groups|edges`.
    pub fn add_recipe(
        &mut self,
        id: &str,
        cat: &str,
        groups: &str,
        edges: &str,
        srcinfo: &str,
    ) -> PathBuf {
        let rel = format!("packages/{cat}/{id}");
        let dir = self.root.join(&rel);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join("PKGBUILD"), format!("# fixture stub {id}\n")).unwrap();
        std::fs::write(dir.join(".SRCINFO"), srcinfo).unwrap();
        self.topology.push(format!("{id}|{rel}|{groups}|{edges}"));
        self.write_topology();
        dir
    }

    /// Replace one recipe's `PKGBUILD` text (audit's toolchain scan reads
    /// the raw file).
    pub fn write_pkgbuild(&self, id: &str, cat: &str, text: &str) {
        let dir = self.root.join("packages").join(cat).join(id);
        std::fs::write(dir.join("PKGBUILD"), text).unwrap();
    }

    fn write_topology(&self) {
        let mut body = String::new();
        for line in &self.topology {
            body.push_str(line);
            body.push('\n');
        }
        std::fs::write(self.root.join("config").join("topology.conf"), body).unwrap();
    }

    /// A committed `config/sets/<name>` file (the read-only source).
    pub fn add_set(&self, name: &str, content: &str) {
        let dir = self.root.join("config").join("sets");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(name), content).unwrap();
    }

    /// The state root handle (creates `index/`/`runs/`/`kv/` on first open).
    pub fn state(&self) -> StateRoot {
        StateRoot::open(&self.state_dir).unwrap()
    }

    /// Run one closure with a fully loaded `MaintCtx` over the fixture.
    /// The layout env is pinned to this fixture's scratch for the closure's
    /// duration (see [`LayoutEnv`]), so every maintain scan resolves its
    /// live homes (`<cache>/build|pkg|pkgs`, `SRCDEST`) inside the scratch
    /// tree and can never touch the host's real ones.
    pub fn with_ctx<R>(&self, f: impl FnOnce(&gsa_maint::MaintCtx<'_>) -> R) -> R {
        let _layout_env = LayoutEnv::pin(&self.root);
        let project = gsa_topo::load_project(&self.root).expect("fixture project loads");
        let graph =
            gsa_graph::Graph::build(&project.topology.records).expect("fixture graph builds");
        let db = gsa_recipe::RecipeDb::load(&self.root, &project.topology.records)
            .expect("fixture recipe db loads");
        let state = self.state();
        f(&gsa_maint::MaintCtx {
            root: &self.root,
            project: &project,
            graph: &graph,
            db: &db,
            state: &state,
        })
    }

    /// A recursive `(relative path, size)` snapshot of the scratch tree —
    /// the report-only mutation oracle.
    pub fn snapshot(&self) -> Vec<(String, u64)> {
        snapshot_tree(&self.root)
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

/// A recursive sorted `(relative path, size)` listing; directories are
/// listed with size 0.
pub fn snapshot_tree(root: &Path) -> Vec<(String, u64)> {
    let mut out = Vec::new();
    let mut stack = vec![(root.to_path_buf(), String::new())];
    while let Some((dir, prefix)) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().into_owned();
            let rel = if prefix.is_empty() {
                name.clone()
            } else {
                format!("{prefix}/{name}")
            };
            let path = entry.path();
            let Ok(meta) = std::fs::symlink_metadata(&path) else {
                continue;
            };
            if meta.is_dir() {
                out.push((rel.clone(), 0));
                stack.push((path, rel));
            } else {
                out.push((rel, meta.len()));
            }
        }
    }
    out.sort();
    out
}

/// A committed `.SRCINFO` body: pkgbase, pkgname(s), version, sources.
pub fn srcinfo(
    pkgbase: &str,
    pkgnames: &[&str],
    pkgver: &str,
    pkgrel: &str,
    sources: &[&str],
) -> String {
    let mut out =
        format!("pkgbase = {pkgbase}\npkgver = {pkgver}\npkgrel = {pkgrel}\narch = any\n");
    for name in pkgnames {
        out.push_str(&format!("pkgname = {name}\n"));
    }
    for source in sources {
        out.push_str(&format!("source = {source}\n"));
    }
    out
}

/// A minimal `.pkg.tar.zst` (zstd tar) carrying its `.PKGINFO` truth.
/// `version` is makepkg's `pkgver` value (the full `pkgver-pkgrel`); the
/// canonical recorded version becomes `0:<version>`.
pub fn make_archive(path: &Path, pkgbase: &str, pkgname: &str, version: &str) {
    let body =
        format!("pkgbase = {pkgbase}\npkgname = {pkgname}\npkgver = {version}\narch = any\n");
    let file = std::fs::File::create(path).unwrap();
    let enc = zstd::stream::Encoder::new(file, 0).unwrap();
    let mut tar = tar::Builder::new(enc);
    let data = body.as_bytes();
    let mut header = tar::Header::new_gnu();
    header.set_size(data.len() as u64);
    header.set_mode(0o644);
    header.set_cksum();
    tar.append_data(&mut header, ".PKGINFO", data).unwrap();
    let enc = tar.into_inner().unwrap();
    enc.finish().unwrap();
}

/// One run record. `remaining` is the continuation's resume pointer (the
/// referent guard's input).
pub fn run_record(pkg: &str, remaining: &[&str]) -> RunRecord {
    let rows = vec![OutcomeRow {
        pkg: RecipeId::new(pkg).unwrap(),
        status: RowStatus::Succeeded,
        rc: Some(0),
        dur: Some(1),
        reason: "ok".to_string(),
    }];
    let outcome = RunOutcome::compute(&rows, false, false, false);
    RunRecord {
        selection_source: format!("packages={pkg}"),
        order: vec![RecipeId::new(pkg).unwrap()],
        lanes: Some(1),
        normal_jobs: Some(2),
        core_jobs: Some(1),
        intensity: "low".to_string(),
        outcome: outcome.outcome.to_string(),
        rc: outcome.rc,
        dry_run: false,
        prefetch_warnings: None,
        plan: vec![PlanRow {
            pkg: RecipeId::new(pkg).unwrap(),
            action: PlanAction::Build,
            reason: "ok".to_string(),
        }],
        outcomes: rows,
        continuation: Continuation {
            command: format!("gsa -B {pkg}"),
            remaining: remaining
                .iter()
                .map(|id| RecipeId::new(*id).unwrap())
                .collect(),
            not_mirrored: Vec::new(),
            env_required: Vec::new(),
        },
    }
}

/// Append one run record to the state root's history.
pub fn append_run(state: &StateRoot, record: &RunRecord) {
    let mut err = Vec::new();
    RunHistory::append(state, record, &mut err).unwrap();
}

/// Pin one file's access/modification time (explicit mtimes — no sleeps,
/// no ordering assertions on wall-clock writes).
pub fn set_mtime(path: &Path, seconds_after_epoch: u64) {
    use std::fs::{File, FileTimes};
    let time = SystemTime::UNIX_EPOCH + Duration::from_secs(seconds_after_epoch);
    let times = FileTimes::new().set_accessed(time).set_modified(time);
    File::options()
        .write(true)
        .open(path)
        .unwrap()
        .set_times(times)
        .unwrap();
}

/// Does `rows` carry a row with this subject and action?
pub fn has_row(rows: &[Row], subject: &str, action: &str) -> bool {
    find_row(rows, subject, action).is_some()
}

/// The first row with this subject and action.
pub fn find_row<'a>(rows: &'a [Row], subject: &str, action: &str) -> Option<&'a Row> {
    rows.iter()
        .find(|r| r.subject == subject && r.action == action)
}

/// Every row with this subject and action.
pub fn rows_with<'a>(rows: &'a [Row], subject: &str, action: &str) -> Vec<&'a Row> {
    rows.iter()
        .filter(|r| r.subject == subject && r.action == action)
        .collect()
}

/// Row-grammar oracle (contract §E.2): every row renders
/// `<subject> <action> <reason…>` — non-empty subject and action, and the
/// rendered line exactly `subject action` or `subject action reason`.
pub fn assert_row_grammar(rows: &[Row]) {
    for row in rows {
        assert!(
            !row.subject.is_empty(),
            "row subject must not be empty: {row:?}"
        );
        assert!(
            !row.action.is_empty(),
            "row action must not be empty: {row:?}"
        );
        assert!(
            !row.subject.contains('\n') && !row.action.contains('\n') && !row.reason.contains('\n'),
            "row fields never span lines: {row:?}"
        );
        let expected = if row.reason.is_empty() {
            format!("{} {}", row.subject, row.action)
        } else {
            format!("{} {} {}", row.subject, row.action, row.reason)
        };
        assert_eq!(row.render(), expected, "row grammar broken: {row:?}");
    }
}
