//! The prune strengths (`gsa -Mc`/`-Mcc`/`-Mccc`, contract §B.7 — the
//! pacman `-Sc`/`-Scc` strength idiom): escalating wipes over makepkg's
//! state, in the TWO homes it lives in since W4a — the build user's cache
//! (`build_layout`: `<cache>/build|pkg|pkgs`, pulled sources in the
//! resolved `SRCDEST`) AND the legacy home beside the recipes (§J.2 keeps
//! those scans: old trees and fixture stubs still write there).
//!
//! - **strength 1** (`-Mc`, selection): one recipe's `src/`/`pkg/`/`build/`
//!   trees (legacy) or its per-pkgbase `<builddir>/<pkgbase>` +
//!   `<pkgdir>/<pkgbase>` trees (live), and its built archives +
//!   `.gsa-vcs-revisions` sidecars (the shared PKGDEST or the recipe dir).
//! - **strength 2** (`-Mcc`, workspace): every built archive
//!   (`*.pkg.tar.zst`) plus its VCS-revision sidecar, in both homes.
//! - **strength 3** (`-Mccc`, workspace, cumulative per §B.7's
//!   "additionally"): strength 2 plus pulled sources — source VCS clones,
//!   downloaded source files (extension-matched to the root `.gitignore`
//!   set, URL-backed source entries only), their `.sig`/`.asc`/`.sign`/
//!   `.part` companions, and the staging dirs (legacy `src/`/`pkg/`/
//!   `build/`/`_build/`, live `<builddir>/<pkgbase>` + `<pkgdir>/<pkgbase>`;
//!   the live pulled-source home is the resolved `SRCDEST`). (Today's fish
//!   `-ccc` is not cumulative — it keeps the archives for `-cc`; §B.7's
//!   "additionally" is normative here.)
//!
//! Symlinks are preserved and never followed (the fish `-cc`/`-ccc`
//! contract): a symlinked archive/clone/download earns `keep symlink`; the
//! build trees are removed with `rm -rf` semantics (a symlinked tree is
//! unlinked, never recursed into). Every target is proven to live inside
//! ITS home (the recipe workspace, the build-cache root, or the SRCDEST
//! root) before it is touched, every archive removal is recorded in the
//! binpkg index (tombstones), and the pruning-safety guards of
//! [`crate::protect`] apply: recipes referenced by the newest run record's
//! `remaining:` keep their files (`keep referenced-by-run`). A shared-home
//! entry no recipe can be proven to own (rule 11's truth filter) earns
//! `keep unattributed` — never deleted.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use gsa_model::config::{build_layout_for_run, resolve_srcdest, BuildLayout};
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
/// symlink)` in deterministic order; `root` is the home root the target
/// must be proven inside of before it is touched, and `guard` is a forced
/// `keep` reason (an unattributed shared-home entry).
#[derive(Clone, Debug)]
struct Target {
    path: PathBuf,
    kind: &'static str,
    symlink: bool,
    root: PathBuf,
    guard: Option<&'static str>,
}

impl Target {
    fn new(path: PathBuf, kind: &'static str, symlink: bool, root: PathBuf) -> Target {
        Target {
            path,
            kind,
            symlink,
            root,
            guard: None,
        }
    }
}

/// Built archives + VCS-revision sidecars at one home directory's top level
/// (the recipe dir is §J.2's legacy home; the shared PKGDEST goes through
/// [`pkgdest_targets`] instead, which attributes by truth).
fn archive_targets(dir: &Path, root: PathBuf) -> Vec<Target> {
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
        out.push(Target::new(
            entry.path(),
            if is_sidecar { "vcs-sidecar" } else { "archive" },
            symlink,
            root.clone(),
        ));
    }
    out.sort_by(|a, b| a.path.cmp(&b.path));
    out
}

/// The staging dirs (strength 1: `src`/`pkg`/`build`; strength 3 also
/// `_build`). A symlinked tree is a target too — removed AS A LINK, never
/// recursed (that is `rm -rf` semantics, not "followed").
fn staging_targets(dir: &Path, strength3: bool, root: PathBuf) -> Vec<Target> {
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
            out.push(Target::new(
                path,
                "staging",
                meta.file_type().is_symlink(),
                root.clone(),
            ));
        }
    }
    out
}

/// The live per-pkgbase makepkg trees (W4a): `<builddir>/<pkgbase>` (the
/// `src`/`pkg`/`build` trees' home) and `<pkgdir>/<pkgbase>` (staging).
/// One `staging` target each, removed with the same `rm -rf` semantics as
/// the legacy trees. `pkgbase` must come from the recipe's own metadata —
/// an unknown pkgbase scans nothing (a guessed name could be somebody
/// else's tree).
fn live_staging_targets(layout: &BuildLayout, pkgbase: &str) -> Vec<Target> {
    let mut out = Vec::new();
    for dir in [
        layout.builddir.join(pkgbase),
        layout.pkgdir.join(pkgbase),
    ] {
        let Ok(meta) = std::fs::symlink_metadata(&dir) else {
            continue;
        };
        if meta.is_dir() || meta.file_type().is_symlink() {
            out.push(Target::new(
                dir,
                "staging",
                meta.file_type().is_symlink(),
                layout.root.clone(),
            ));
        }
    }
    out
}

/// Rule 11's truth filter for a shared-home entry: which recipe does this
/// archive belong to? [`crate::archive_owner`] (shared with the doctor).
fn owner_of(
    index: &BinpkgIndex,
    declared: &BTreeMap<String, Vec<String>>,
    path: &Path,
) -> Option<String> {
    crate::archive_owner(index, declared, path)
}

/// The shared-PKGDEST half of the archive scan (the live home since W4a):
/// every `*.pkg.tar.zst` + its `.gsa-vcs-revisions` sidecar, attributed to
/// its recipe by [`owner_of`] (a sidecar inherits its archive's owner). An
/// entry no recipe can be proven to own is returned owner-less with a
/// forced `keep unattributed` guard: the `referenced-by-run` guard cannot
/// be evaluated for it, so it is never deleted.
fn pkgdest_targets(
    layout: &BuildLayout,
    index: &BinpkgIndex,
    declared: &BTreeMap<String, Vec<String>>,
) -> Vec<(String, Target)> {
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir(&layout.pkgdest) else {
        return out;
    };
    for entry in entries.flatten() {
        let name = entry.file_name().to_string_lossy().into_owned();
        let is_archive = name.ends_with(".pkg.tar.zst");
        let is_sidecar = name.ends_with(".pkg.tar.zst.gsa-vcs-revisions");
        if !is_archive && !is_sidecar {
            continue;
        }
        let path = entry.path();
        let symlink = entry.file_type().map(|t| t.is_symlink()).unwrap_or(false);
        let owner = if is_sidecar {
            owner_of(index, declared, &path.with_extension(""))
        } else {
            owner_of(index, declared, &path)
        };
        let mut target = Target::new(
            path,
            if is_sidecar { "vcs-sidecar" } else { "archive" },
            symlink,
            layout.root.clone(),
        );
        if owner.is_none() {
            target.guard = Some("unattributed");
        }
        out.push((owner.unwrap_or_default(), target));
    }
    out.sort_by(|a, b| a.1.path.cmp(&b.1.path));
    out
}

/// One recipe's pulled-source targets (strength 3): VCS clones named by the
/// `source=()` array, downloaded URL-backed files in the download-extension
/// set, and their companions — in ONE home (`home`, either the legacy
/// recipe dir or the resolved `SRCDEST`), proven inside `root` before being
/// collected. Symlinks are collected separately (preserved).
fn source_targets(
    home: &Path,
    root: &Path,
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
        let path = home.join(&name);
        if !path.starts_with(root) {
            continue;
        }
        match source.kind {
            SourceKind::Vcs(_) => {
                if path.is_dir() {
                    let symlink = std::fs::symlink_metadata(&path)
                        .map(|m| m.file_type().is_symlink())
                        .unwrap_or(false);
                    out.push(Target::new(
                        path,
                        "source-clone",
                        symlink,
                        root.to_path_buf(),
                    ));
                }
            }
            SourceKind::Remote => {
                let is_download = patterns.iter().any(|p| glob_match(p, &name));
                if is_download && path.exists() {
                    let symlink = std::fs::symlink_metadata(&path)
                        .map(|m| m.file_type().is_symlink())
                        .unwrap_or(false);
                    out.push(Target::new(
                        path.clone(),
                        "source-download",
                        symlink,
                        root.to_path_buf(),
                    ));
                    for suffix in COMPANION_SUFFIXES {
                        let companion = PathBuf::from(format!("{}.{}", path.display(), suffix));
                        if companion.exists() {
                            let symlink = std::fs::symlink_metadata(&companion)
                                .map(|m| m.file_type().is_symlink())
                                .unwrap_or(false);
                            out.push(Target::new(
                                companion,
                                "source-companion",
                                symlink,
                                root.to_path_buf(),
                            ));
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
/// by all three strengths: a forced guard (`keep unattributed`) keeps a
/// target, referenced-by-run recipes keep their files, file symlinks are
/// preserved, and every deletion is proven to be inside ITS home root
/// (recipe workspace / build cache / SRCDEST) first. `apply == false`
/// renders the plan (present-tense `prune` actions) and touches nothing.
/// Returns the rows and the recipe→deleted-archive map for the index
/// tombstones.
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
        if let Some(reason) = target.guard {
            rows.push(protect::keep_row(&shown, reason));
            continue;
        }
        if protected.contains(recipe) {
            rows.push(protect::keep_row(&shown, "referenced-by-run"));
            continue;
        }
        if !target.path.starts_with(&target.root) {
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

/// The live build-cache layout for one strength, under the engine's ONE
/// layout error policy (`build_layout_for_run`): `Err` is fatal for the
/// calling operation and becomes the §E.2 failure row — a strength without
/// its live homes must not silently wipe only the legacy half.
fn strength_layout() -> Result<BuildLayout, Vec<Row>> {
    build_layout_for_run().map_err(|error| vec![Row::new("build-layout", "failed", error)])
}

/// Collect one strength's targets, deduplicated by path (a path is deleted
/// once and reported once even when two scans could reach it).
fn push_unique(
    targets: &mut Vec<(String, Target)>,
    seen: &mut BTreeSet<PathBuf>,
    new: Vec<(String, Target)>,
) {
    for (id, target) in new {
        if seen.insert(target.path.clone()) {
            targets.push((id, target));
        }
    }
}

/// The recipe's own pkgbase, only from its committed metadata — an unknown
/// pkgbase scans no live tree (a guessed name could be somebody else's).
fn pkgbase_of(meta: &RecipeMeta) -> Option<String> {
    meta.srcinfo
        .as_ref()
        .and_then(|info| info.pkgbase.clone())
        .filter(|base| !base.is_empty())
}

/// `-Mc` (strength 1): the selection's recipes. `recipes` are recipe ids in
/// build order (the CLI resolved the selection); `apply == false` renders
/// the plan. Live homes: the recipe's per-pkgbase staging trees and its
/// own (truth-filtered) PKGDEST archives; legacy home: the recipe dir.
pub fn strength1(ctx: &MaintCtx<'_>, recipes: &[String], apply: bool) -> Vec<Row> {
    let layout = match strength_layout() {
        Ok(layout) => layout,
        Err(rows) => return rows,
    };
    let declared = ctx.declared_names();
    let index = BinpkgIndex::load(ctx.state).unwrap_or(BinpkgIndex {
        rows: Vec::new(),
        corrupt: Vec::new(),
    });
    let pkgdest = pkgdest_targets(&layout, &index, &declared);
    let mut targets: Vec<(String, Target)> = Vec::new();
    let mut seen = BTreeSet::new();
    for id in recipes {
        let dir = ctx.root.join(
            ctx.graph
                .records()
                .iter()
                .find(|r| r.id.as_str() == id)
                .map(|r| r.path.clone())
                .unwrap_or_default(),
        );
        let mut mine: Vec<(String, Target)> = Vec::new();
        for target in staging_targets(&dir, false, ctx.root.to_path_buf()) {
            mine.push((id.clone(), target));
        }
        for target in archive_targets(&dir, ctx.root.to_path_buf()) {
            mine.push((id.clone(), target));
        }
        if let Some(meta) = ctx.db.get(id) {
            if let Some(base) = pkgbase_of(&meta) {
                for target in live_staging_targets(&layout, &base) {
                    mine.push((id.clone(), target));
                }
            }
        }
        for (owner, target) in &pkgdest {
            if owner == id {
                mine.push((id.clone(), target.clone()));
            }
        }
        push_unique(&mut targets, &mut seen, mine);
    }
    let (mut rows, deleted) = run_targets(ctx, &targets, apply);
    if apply {
        rows.extend(tombstone_deleted(ctx, &deleted));
    }
    rows
}

/// `-Mcc` (strength 2): every built archive plus its VCS-revision sidecar,
/// in both homes (the shared PKGDEST and the legacy recipe dirs).
pub fn strength2(ctx: &MaintCtx<'_>, apply: bool) -> Vec<Row> {
    let layout = match strength_layout() {
        Ok(layout) => layout,
        Err(rows) => return rows,
    };
    let declared = ctx.declared_names();
    let index = BinpkgIndex::load(ctx.state).unwrap_or(BinpkgIndex {
        rows: Vec::new(),
        corrupt: Vec::new(),
    });
    let mut targets: Vec<(String, Target)> = Vec::new();
    let mut seen = BTreeSet::new();
    for (id, dir) in ctx.recipe_dirs() {
        let mine: Vec<(String, Target)> = archive_targets(&dir, ctx.root.to_path_buf())
            .into_iter()
            .map(|target| (id.clone(), target))
            .collect();
        push_unique(&mut targets, &mut seen, mine);
    }
    push_unique(&mut targets, &mut seen, pkgdest_targets(&layout, &index, &declared));
    let (mut rows, deleted) = run_targets(ctx, &targets, apply);
    if apply {
        rows.extend(tombstone_deleted(ctx, &deleted));
    }
    rows
}

/// `-Mccc` (strength 3, cumulative): strength 2's archives plus pulled
/// sources and staging dirs across the workspace — in the live homes
/// (per-pkgbase staging trees, the resolved `SRCDEST`) and the legacy
/// recipe dirs alike.
pub fn strength3(ctx: &MaintCtx<'_>, apply: bool) -> Vec<Row> {
    let layout = match strength_layout() {
        Ok(layout) => layout,
        Err(rows) => return rows,
    };
    let declared = ctx.declared_names();
    let index = BinpkgIndex::load(ctx.state).unwrap_or(BinpkgIndex {
        rows: Vec::new(),
        corrupt: Vec::new(),
    });
    let patterns = download_patterns(ctx.root);
    let srcdest = resolve_srcdest();
    let mut targets: Vec<(String, Target)> = Vec::new();
    let mut seen = BTreeSet::new();
    for (id, dir) in ctx.recipe_dirs() {
        let Some(meta) = ctx.db.get(&id) else {
            continue;
        };
        let mut mine: Vec<(String, Target)> = Vec::new();
        for target in archive_targets(&dir, ctx.root.to_path_buf()) {
            mine.push((id.clone(), target));
        }
        for target in staging_targets(&dir, true, ctx.root.to_path_buf()) {
            mine.push((id.clone(), target));
        }
        for target in source_targets(&dir, ctx.root, &meta, &patterns) {
            mine.push((id.clone(), target));
        }
        if let Some(base) = pkgbase_of(&meta) {
            for target in live_staging_targets(&layout, &base) {
                mine.push((id.clone(), target));
            }
        }
        if let Some(srcdest) = &srcdest {
            for target in source_targets(srcdest, srcdest, &meta, &patterns) {
                mine.push((id.clone(), target));
            }
        }
        push_unique(&mut targets, &mut seen, mine);
    }
    push_unique(&mut targets, &mut seen, pkgdest_targets(&layout, &index, &declared));
    let (mut rows, deleted) = run_targets(ctx, &targets, apply);
    if apply {
        rows.extend(tombstone_deleted(ctx, &deleted));
    }
    rows
}
