//! Host-state hygiene (plan-gentoo-qol.md shortlist 7): per-package log
//! browse/tail with a documented retention policy, the stale run-artifact
//! name classes, and the log-ownership report — all under the state root
//! (contract §J.1: logs live with the rest of the engine's state, one root,
//! one override, one prune story).
//!
//! Log policy (normative): build logs are `<state>/logs/<pkg>.log`, one per
//! package per run (a build truncates its own log). Retention (`-Ml --keep
//! N`) keeps the N NEWEST files per package among the `<pkg>.log*` name set
//! (rotated siblings share the stem) and removes the rest, loudly. The
//! default when a verb prunes without an explicit N is [`LOG_KEEP_DEFAULT`].

use std::path::{Path, PathBuf};
use std::time::SystemTime;

use crate::{protect, Row};

/// Files kept per package when a retention prune gives no N.
pub const LOG_KEEP_DEFAULT: usize = 3;

/// Lines printed by `-Ml --tail`.
pub const TAIL_LINES: usize = 20;

/// One log file under `<state>/logs/`.
#[derive(Clone, Debug)]
pub struct LogEntry {
    /// The package stem: the file name before its `.log` suffix chain.
    pub pkg: String,
    pub path: PathBuf,
    pub size: u64,
    pub mtime: SystemTime,
}

/// Every log file in `<state>/logs/`, sorted by package then newest first.
/// Unreadable entries are skipped, never guessed at.
pub fn log_entries(state: &Path) -> Vec<LogEntry> {
    let logs = state.join("logs");
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir(&logs) else {
        return out;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        let Ok(meta) = std::fs::symlink_metadata(&path) else {
            continue;
        };
        if !meta.is_file() {
            continue;
        }
        let name = entry.file_name().to_string_lossy().into_owned();
        let Some(pkg) = log_pkg_stem(&name) else {
            continue;
        };
        out.push(LogEntry {
            pkg,
            path,
            size: meta.len(),
            mtime: meta.modified().unwrap_or(SystemTime::UNIX_EPOCH),
        });
    }
    out.sort_by(|a, b| a.pkg.cmp(&b.pkg).then(b.mtime.cmp(&a.mtime)));
    out
}

/// The package stem of a log file name: `alpha.log`, `alpha.log.1` →
/// `alpha`; anything not in the `<stem>.log…` family is not a log.
fn log_pkg_stem(name: &str) -> Option<String> {
    let stem = name.split(".log").next().unwrap_or("");
    if stem.is_empty() || !name.contains(".log") {
        return None;
    }
    Some(stem.to_string())
}

/// The last [`TAIL_LINES`] lines of one log (the browse surface's tail).
pub fn tail_lines(path: &Path) -> Result<String, String> {
    let text = std::fs::read_to_string(path)
        .map_err(|e| format!("cannot read {}: {e}", path.display()))?;
    let lines: Vec<&str> = text.lines().collect();
    let start = lines.len().saturating_sub(TAIL_LINES);
    Ok(lines[start..].join("\n"))
}

/// Log retention (§B.7 `-Ml --keep N`): keep the N newest files per
/// package, remove the rest. A package with ≤N files is untouched (its rows
/// say `kept`); nothing outside `<state>/logs/` is ever considered. Rows:
/// `<path> <prune|pruned|kept> log-retention keep=<N>` — present-tense
/// actions are the dry-run plan, past-tense the applied mutation (the
/// [`crate`] row convention).
pub fn prune_logs(state: &Path, keep: usize, apply: bool) -> Vec<Row> {
    let mut rows = Vec::new();
    let entries = log_entries(state);
    let mut by_pkg: Vec<(String, Vec<LogEntry>)> = Vec::new();
    for entry in entries {
        match by_pkg.iter_mut().find(|(pkg, _)| *pkg == entry.pkg) {
            Some((_, list)) => list.push(entry),
            None => by_pkg.push((entry.pkg.clone(), vec![entry])),
        }
    }
    for (_, list) in by_pkg {
        for (idx, entry) in list.iter().enumerate() {
            if idx < keep {
                rows.push(protect::keep_row(
                    &entry.path.display().to_string(),
                    &format!("log-retention keep={keep}"),
                ));
                continue;
            }
            if !apply {
                rows.push(Row::new(
                    entry.path.display().to_string(),
                    "prune",
                    format!("log-retention keep={keep}"),
                ));
                continue;
            }
            match std::fs::remove_file(&entry.path) {
                Ok(()) => rows.push(Row::new(
                    entry.path.display().to_string(),
                    "pruned",
                    format!("log-retention keep={keep}"),
                )),
                Err(error) => rows.push(Row::new(
                    entry.path.display().to_string(),
                    "failed",
                    format!("log-retention cannot remove: {error}"),
                )),
            }
        }
    }
    rows.sort_by(|a, b| a.subject.cmp(&b.subject));
    rows
}

/// The stale run-artifact name classes (contract §K.3's orphan sweep and
/// the fish audit's "Stale runtime/error artifacts" — the scopes must never
/// drift): `.lane*.result`, `*.tmp.*`, `*.srcinfo.err` recursively under the
/// state root; `.srcinfo.err`, `*.gsa-vcs-revisions.tmp.*` in the packages
/// tree outside `src/`/`pkg/`/`build/`. Returns `(path, class)`.
pub fn stale_artifacts(state: &Path, repo_root: &Path) -> Vec<(PathBuf, &'static str)> {
    let mut out = Vec::new();
    let mut stack = vec![state.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(meta) = std::fs::symlink_metadata(&path) else {
                continue;
            };
            if meta.is_dir() {
                stack.push(path);
                continue;
            }
            let name = entry.file_name().to_string_lossy().into_owned();
            if let Some(class) = stale_class(&name) {
                out.push((path, class));
            }
        }
    }
    let packages = repo_root.join("packages");
    let mut stack = vec![packages.clone()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(meta) = std::fs::symlink_metadata(&path) else {
                continue;
            };
            let name = entry.file_name().to_string_lossy().into_owned();
            if meta.is_dir() {
                // makepkg's own trees are prune-strength territory, never
                // the stale-artifact sweep's.
                if name != "src" && name != "pkg" && name != "build" {
                    stack.push(path);
                }
                continue;
            }
            if name == ".srcinfo.err" {
                out.push((path, "srcinfo-err"));
            } else if name.ends_with(".gsa-vcs-revisions.tmp.")
                || name.contains(".gsa-vcs-revisions.tmp.")
            {
                out.push((path, "vcs-revisions-tmp"));
            }
        }
    }
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out
}

fn stale_class(name: &str) -> Option<&'static str> {
    if name.ends_with(".tmp.") || name.contains(".tmp.") {
        // `*.tmp.*` (a temp name mid-publication) — but not the quarantine
        // form `<path>.stale.<epoch>.<pid>`, which §J.5 preserves.
        if name.contains(".stale.") {
            return None;
        }
        return Some("tmp-artifact");
    }
    if name.starts_with(".lane") && name.ends_with(".result") {
        return Some("lane-result");
    }
    if name.ends_with(".srcinfo.err") {
        return Some("srcinfo-err");
    }
    None
}

/// Ownership report (rule 19 / §J.5): state-root files not owned by the
/// build user. Report-only even under `--fix` — the root supervisor's
/// startup repair owns the remedy, and an unprivileged run's quarantine is
/// a write-time gate, not a doctor repair.
pub fn ownership_rows(state: &Path) -> Vec<Row> {
    let mut rows = Vec::new();
    let uid = gsa_sched::signals::current_uid();
    let mut stack = vec![state.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(meta) = std::fs::symlink_metadata(&path) else {
                continue;
            };
            use std::os::unix::fs::MetadataExt;
            if meta.uid() != uid {
                rows.push(Row::new(
                    path.display().to_string(),
                    "wrong-owner",
                    format!(
                        "uid={} want={uid} — root repairs owners at startup (§J.5)",
                        meta.uid()
                    ),
                ));
            }
            if meta.is_dir() {
                stack.push(path);
            }
        }
    }
    rows.sort_by(|a, b| a.subject.cmp(&b.subject));
    rows
}

/// The stale-artifact repair: state-root artifacts are removed (they are
/// the engine's own dead temporaries, §K.3's sweep class); packages-tree
/// artifacts are REPORTED and left alone — a maintain repair never writes
/// outside the state root. Rows:
/// `<path> <prune|pruned|kept> stale-artifact <class>`.
pub fn prune_stale_artifacts(state: &Path, repo_root: &Path, apply: bool) -> Vec<Row> {
    let mut rows = Vec::new();
    for (path, class) in stale_artifacts(state, repo_root) {
        let in_state = path.starts_with(state);
        if !in_state {
            rows.push(protect::keep_row(
                &path.display().to_string(),
                &format!("stale-artifact {class} outside-state-root"),
            ));
            continue;
        }
        if !apply {
            rows.push(Row::new(
                path.display().to_string(),
                "prune",
                format!("stale-artifact {class}"),
            ));
            continue;
        }
        match std::fs::remove_file(&path) {
            Ok(()) => rows.push(Row::new(
                path.display().to_string(),
                "pruned",
                format!("stale-artifact {class}"),
            )),
            Err(error) => rows.push(Row::new(
                path.display().to_string(),
                "failed",
                format!("stale-artifact cannot remove: {error}"),
            )),
        }
    }
    rows
}
