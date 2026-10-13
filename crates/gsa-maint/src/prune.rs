//! The prune strengths (`gsa -Mc`/`-Mcc`/`-Mccc`, contract §B.7 — the
//! pacman `-Sc`/`-Scc` strength idiom): escalating wipes over makepkg's
//! state beside the recipes (§J.2).
//!
//! - **strength 1** (`-Mc`, selection): one recipe's `src/`/`pkg/`/`build/`
//!   trees and its built archives + `.gsa-vcs-revisions` sidecars (the
//!   `-Sc`-as-a-wipe of today's `-c`).
//! - **strength 2** (`-Mcc`, workspace): every built archive
//!   (`*.pkg.tar.zst`) plus its VCS-revision sidecar.
//! - **strength 3** (`-Mccc`, workspace, cumulative per §B.7's
//!   "additionally"): strength 2 plus pulled sources — source VCS clones,
//!   downloaded source files (extension-matched to the root `.gitignore`
//!   set, URL-backed source entries only), their `.sig`/`.asc`/`.sign`/
//!   `.part` companions, and the staging dirs (`src/`/`pkg/`/`build/`/
//!   `_build/`). (Today's fish `-ccc` is not cumulative — it keeps the
//!   archives for `-cc`; §B.7's "additionally" is normative here.)
//!
//! Symlinks are preserved and never followed (the fish `-cc`/`-ccc`
//! contract): a symlinked archive/clone/download earns `keep symlink`; the
//! build trees are removed with `rm -rf` semantics (a symlinked tree is
//! unlinked, never recursed into). Every target is proven to live inside
//! the recipe workspace before it is touched, every archive removal is
//! recorded in the binpkg index (tombstones), and the pruning-safety guards
//! of [`crate::protect`] apply: recipes referenced by the newest run
//! record's `remaining:` keep their files (`keep referenced-by-run`).

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use gsa_recipe::{RecipeMeta, SourceKind};
use gsa_state::{prune_instance, BinpkgIndex};

use crate::{protect, MaintCtx, Row};

/// The download-companion suffixes the fish nuclear cleanup deletes with
/// their source file (`.sig`/`.asc`/`.sign`/`.part`).
const COMPANION_SUFFIXES: [&str; 4] = ["sig", "asc", "sign", "part"];

/// The root `.gitignore` download-extension set: its `*.<ext…>` patterns,
/// matched against URL-backed source file names only. Local patches, hooks
/// and keyrings are never URL-backed and therefore never match.
pub fn download_patterns(repo_root: &Path) -> Vec<String> {
    let mut out = Vec::new();
    if let Ok(text) = std::fs::read_to_string(repo_root.join(".gitignore")) {
        for line in text.lines() {
            let line = line.trim();
            if let Some(rest) = line.strip_prefix("*.") {
                if !rest.is_empty() && !rest.contains('/') {
                    out.push(line.to_string());
                }
            }
        }
    }
    out
}

/// `*`-glob match (the `.gitignore` extension patterns use `*` only).
fn glob_match(pattern: &str, name: &str) -> bool {
    let mut parts = pattern.split('*');
    let first = parts.next().unwrap_or("");
    if !name.starts_with(first) {
        return false;
    }
    let mut cursor = first.len();
    let mut last = None;
    for part in parts {
        if part.is_empty() {
            continue;
        }
        match name[cursor..].find(part) {
            Some(at) => {
                cursor += at + part.len();
                last = Some(cursor);
            }
            None => return false,
        }
    }
    match last {
        Some(end) => pattern.ends_with('*') || end == name.len(),
        None => name.len() == cursor,
    }
}

/// One recipe's makepkg-state targets for one strength. `(path, kind,
/// symlink)` in deterministic order.
#[derive(Clone, Debug)]
struct Target {
    path: PathBuf,
    kind: &'static str,
    symlink: bool,
}

/// Built archives + VCS-revision sidecars at one recipe's top level (the
/// makepkg state §J.2 keeps beside the recipe).
fn archive_targets(dir: &Path) -> Vec<Target> {
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir(dir) else {
        return out;
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let is_archive = name.ends_with(".pkg.tar.zst");
        let is_sidecar = name.ends_with(".pkg.tar.zst.gsa-vcs-revisions");
        if !is_archive && !is_sidecar {
            continue;
        }
        let symlink = entry.file_type().map(|t| t.is_symlink()).unwrap_or(false);
        out.push(Target {
            path: entry.path(),
            kind: if is_sidecar { "vcs-sidecar" } else { "archive" },
            symlink,
        });
    }
    out.sort_by(|a, b| a.path.cmp(&b.path));
    out
}

/// The staging dirs (strength 1: `src`/`pkg`/`build`; strength 3 also
/// `_build`). A symlinked tree is a target too — removed AS A LINK, never
/// recursed (that is `rm -rf` semantics, not "followed").
fn staging_targets(dir: &Path, strength3: bool) -> Vec<Target> {
    let names: &[&str] = if strength3 {
        &["src", "pkg", "build", "_build"]
    } else {
        &["src", "pkg", "build"]
    };
    let mut out = Vec::new();
    for &name in names.iter() {
        let path = dir.join(name);
        let Ok(meta) = std::fs::symlink_metadata(&path) else {
            continue;
        };
        if meta.is_dir() || meta.file_type().is_symlink() {
            out.push(Target {
                path,
                kind: "staging",
                symlink: meta.file_type().is_symlink(),
            });
        }
    }
    out
}

/// One recipe's pulled-source targets (strength 3): VCS clones named by the
/// `source=()` array, downloaded URL-backed files in the download-extension
/// set, and their companions. Symlinks are collected separately (preserved).
fn source_targets(
    ctx: &MaintCtx<'_>,
    dir: &Path,
    meta: &RecipeMeta,
    patterns: &[String],
) -> Vec<Target> {
    let mut out = Vec::new();
    for source in meta.sources() {
        let name = match source.kind {
            SourceKind::Vcs(_) => {
                let mut name = gsa_fetch::candidacy::source_filename(&source);
                if name.ends_with(".git") {
                    name.truncate(name.len() - 4);
                }
                name
            }
            SourceKind::Remote => gsa_fetch::candidacy::source_filename(&source),
            SourceKind::Local => continue,
        };
        if name.is_empty() || name == "." || name == ".." {
            continue;
        }
        let path = dir.join(&name);
        if !path.starts_with(ctx.root) {
            continue;
        }
        match source.kind {
            SourceKind::Vcs(_) => {
                if path.is_dir() {
                    let symlink = std::fs::symlink_metadata(&path)
                        .map(|m| m.file_type().is_symlink())
                        .unwrap_or(false);
                    out.push(Target {
                        path,
                        kind: "source-clone",
                        symlink,
                    });
                }
            }
            SourceKind::Remote => {
                let is_download = patterns.iter().any(|p| glob_match(p, &name));
                if is_download && path.exists() {
                    let symlink = std::fs::symlink_metadata(&path)
                        .map(|m| m.file_type().is_symlink())
                        .unwrap_or(false);
                    out.push(Target {
                        path: path.clone(),
                        kind: "source-download",
                        symlink,
                    });
                    for suffix in COMPANION_SUFFIXES {
                        let companion = PathBuf::from(format!("{}.{}", path.display(), suffix));
                        if companion.exists() {
                            let symlink = std::fs::symlink_metadata(&companion)
                                .map(|m| m.file_type().is_symlink())
                                .unwrap_or(false);
                            out.push(Target {
                                path: companion,
                                kind: "source-companion",
                                symlink,
                            });
                        }
                    }
                }
            }
            SourceKind::Local => {}
        }
    }
    out.sort_by(|a, b| a.path.cmp(&b.path));
    out
}

/// Apply one strength's target list under the pruning-safety guards. Shared
/// by all three strengths: referenced-by-run recipes keep their files, file
/// symlinks are preserved, and every deletion is proven to be inside the
/// workspace first. `apply == false` renders the plan (present-tense
/// `prune` actions) and touches nothing. Returns the rows and the
/// recipe→deleted-archive map for the index tombstones.
fn run_targets(
    ctx: &MaintCtx<'_>,
    targets: &[(String, Target)],
    apply: bool,
) -> (Vec<Row>, Vec<(String, PathBuf)>) {
    let protected = protect::referenced_by_run(ctx.state);
    let mut rows = Vec::new();
    let mut deleted: Vec<(String, PathBuf)> = Vec::new();
    for (recipe, target) in targets {
        let shown = target.path.display().to_string();
        if protected.contains(recipe) {
            rows.push(protect::keep_row(&shown, "referenced-by-run"));
            continue;
        }
        if !target.path.starts_with(ctx.root) {
            rows.push(protect::keep_row(&shown, "outside-workspace"));
            continue;
        }
        if target.symlink && target.kind != "staging" {
            rows.push(protect::keep_row(&shown, "symlink"));
            continue;
        }
        if !apply {
            rows.push(Row::new(shown, "prune", target.kind));
            continue;
        }
        // A symlinked staging tree is unlinked, never followed; directory
        // targets (staging trees, source clones) are removed recursively;
        // everything else is a plain file.
        let removed = if target.symlink {
            std::fs::remove_file(&target.path)
        } else if target.path.is_dir() {
            std::fs::remove_dir_all(&target.path)
        } else {
            std::fs::remove_file(&target.path)
        };
        match removed {
            Ok(()) => {
                rows.push(Row::new(shown, "pruned", target.kind));
                if matches!(target.kind, "archive" | "vcs-sidecar") {
                    deleted.push((recipe.clone(), target.path.clone()));
                }
            }
            Err(error) => rows.push(Row::new(
                shown,
                "failed",
                format!("{kind}: {error}", kind = target.kind),
            )),
        }
    }
    (rows, deleted)
}

/// Tombstone every binpkg-index instance whose archives this prune deleted
/// in full (a split set is never tombstoned in half): an instance dies only
/// when ALL of its rows' archives are gone.
fn tombstone_deleted(ctx: &MaintCtx<'_>, deleted: &[(String, PathBuf)]) -> Vec<Row> {
    let gone: BTreeSet<&Path> = deleted.iter().map(|(_, p)| p.as_path()).collect();
    let Ok(index) = BinpkgIndex::load(ctx.state) else {
        return Vec::new();
    };
    let mut rows = Vec::new();
    let mut seen: BTreeSet<(String, u64)> = BTreeSet::new();
    for row in &index.rows {
        let key = (row.recipe_id.clone(), row.instance);
        if seen.contains(&key) {
            continue;
        }
        let siblings: Vec<_> = index
            .rows
            .iter()
            .filter(|r| r.recipe_id == row.recipe_id && r.instance == row.instance)
            .collect();
        if !siblings
            .iter()
            .all(|r| gone.contains(r.archive.as_path()) || !r.archive.exists())
        {
            continue;
        }
        seen.insert(key.clone());
        let mut err = Vec::new();
        match prune_instance(ctx.state, &row.recipe_id, row.instance, &mut err) {
            Ok(true) => rows.push(Row::new(
                format!("{}:{}", row.recipe_id, row.instance),
                "tombstoned",
                "index-instance pruned with its archives",
            )),
            Ok(false) => {}
            Err(error) => rows.push(Row::new(
                format!("{}:{}", row.recipe_id, row.instance),
                "failed",
                format!("tombstone refused: {error}"),
            )),
        }
    }
    rows
}

/// `-Mc` (strength 1): the selection's recipes. `recipes` are recipe ids in
/// build order (the CLI resolved the selection); `apply == false` renders
/// the plan.
pub fn strength1(ctx: &MaintCtx<'_>, recipes: &[String], apply: bool) -> Vec<Row> {
    let mut targets = Vec::new();
    for id in recipes {
        let dir = ctx.root.join(
            ctx.graph
                .records()
                .iter()
                .find(|r| r.id.as_str() == id)
                .map(|r| r.path.clone())
                .unwrap_or_default(),
        );
        for target in staging_targets(&dir, false) {
            targets.push((id.clone(), target));
        }
        for target in archive_targets(&dir) {
            targets.push((id.clone(), target));
        }
    }
    let (mut rows, deleted) = run_targets(ctx, &targets, apply);
    if apply {
        rows.extend(tombstone_deleted(ctx, &deleted));
    }
    rows
}

/// `-Mcc` (strength 2): every built archive in the workspace plus its
/// VCS-revision sidecar.
pub fn strength2(ctx: &MaintCtx<'_>, apply: bool) -> Vec<Row> {
    let mut targets = Vec::new();
    for (id, dir) in ctx.recipe_dirs() {
        for target in archive_targets(&dir) {
            targets.push((id.clone(), target));
        }
    }
    let (mut rows, deleted) = run_targets(ctx, &targets, apply);
    if apply {
        rows.extend(tombstone_deleted(ctx, &deleted));
    }
    rows
}

/// `-Mccc` (strength 3, cumulative): strength 2's archives plus pulled
/// sources and staging dirs across the workspace.
pub fn strength3(ctx: &MaintCtx<'_>, apply: bool) -> Vec<Row> {
    let patterns = download_patterns(ctx.root);
    let mut targets = Vec::new();
    for (id, dir) in ctx.recipe_dirs() {
        let Some(meta) = ctx.db.get(&id) else {
            continue;
        };
        for target in archive_targets(&dir) {
            targets.push((id.clone(), target));
        }
        for target in staging_targets(&dir, true) {
            targets.push((id.clone(), target));
        }
        for target in source_targets(ctx, &dir, &meta, &patterns) {
            targets.push((id.clone(), target));
        }
    }
    let (mut rows, deleted) = run_targets(ctx, &targets, apply);
    if apply {
        rows.extend(tombstone_deleted(ctx, &deleted));
    }
    rows
}
