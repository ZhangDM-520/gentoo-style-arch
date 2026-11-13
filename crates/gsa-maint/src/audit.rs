//! The audit report (`gsa -Ma`, contract §B.7 — today's `--audit`, kept
//! report-only by contract (§E.4): it never refuses anything and exits 0,
//! read the report). Families, in report order:
//!
//! 1. `legacy-layout` — surviving pre-Git layout path references
//!    (`.Stable/`, `.Static/`, `.Heavy/`, `.Heavyweight/`, `.Core/`,
//!    `.Misc/`, `.3rdP/`) in maintainer-editable text. Scope mirrors the
//!    fish audit's, with the engine's own source (`crates/`) in
//!    `build-all.fish`'s exclusion slot.
//! 2. `package-drift` — recipe directories with no topology record, and
//!    records whose path is gone (the loader validates records; orphan
//!    directories are the drift it cannot see).
//! 3. `toolchain-edge` — a recipe invoking `cargo`/`rustc` (bare word,
//!    non-comment lines) without a `rust-git` build-order edge (the
//!    2026-09-25 ABI-skew class; `rust-git` excepted).
//! 4. `stale-artifact` — the stale run/error artifact name classes
//!    (§K.3), state root + packages tree.
//! 5. `recipe-contract` — the QA registry's report checks
//!    (provides-versioning, purged-tools, swap-drift, abi-closure,
//!    abi-exposure).
//! 6. `version-sync-skew` — the stale-set skew lint: recipes whose newest
//!    RECORDED built instance version disagrees with the committed
//!    `.SRCINFO` version. Scoped to the side-car (version-sync/provider
//!    machinery is not landed) and saying so in its rows.
//! 7. `installed-pgo` — installed files of PGO-instrumenting recipes still
//!    carrying a baked profiling destination (`.gcda`/`.profraw` bytes).
//! 8. `recipe-integrity` — source claims the recipe cannot honour: a declared
//!    local source absent from the recipe directory, and a REMOTE source
//!    whose integrity sum is `SKIP` (fetched, never verified).
//! 9. `state-integrity` — the side-car's own truth (rule 71): unusable lines
//!    in the binpkg index, the run history and the kv store, plus every index
//!    row whose archive is gone, unreadable or no longer the recorded size.
//!    A store the reader could not use is never "clean", and the audit is the
//!    one report a user reads to decide whether state is trustworthy.
//!
//! Rows: `audit <family> <clean|N finding(s)>` summary, then
//! `<family> <subject> <detail…>` findings.

use gsa_install::localdb::pacman_db_root;
use gsa_qa::input::{collect_archives_checked, load_workspace, QaInput, QaInstalled};

use crate::{hygiene, MaintCtx, Row};

/// The legacy layout stems (assembled so this source never matches its own
/// scanner even when the scope grows).
const LEGACY_DIRS: [&str; 7] = [
    "Stable",
    "Static",
    "Heavy",
    "Heavyweight",
    "Core",
    "Misc",
    "3rdP",
];

/// Directories the workspace walk never descends into (the fish audit's
/// scope: `docs/` is history, `config/` is load-validated, the engine source
/// is `build-all.fish`'s exclusion slot, makepkg trees are prune territory).
fn walk_excluded(name: &str) -> bool {
    matches!(
        name,
        "docs"
            | "config"
            | "crates"
            | ".git"
            | "src"
            | "pkg"
            | "build"
            | "_build"
            | ".state"
            | "target"
    )
}

/// The `legacy-layout` family: one finding per offending line.
fn legacy_layout(root: &std::path::Path) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let mut stack = vec![root.to_path_buf()];
    'walk: while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().into_owned();
            let Ok(meta) = std::fs::symlink_metadata(&path) else {
                continue;
            };
            if meta.is_dir() {
                if !walk_excluded(&name) {
                    stack.push(path);
                }
                continue;
            }
            if meta.len() > 2_000_000 {
                continue;
            }
            let Ok(text) = std::fs::read_to_string(&path) else {
                continue;
            };
            for (idx, line) in text.lines().enumerate() {
                for stem in LEGACY_DIRS {
                    let needle = format!(".{stem}/");
                    for (at, _) in line.match_indices(&needle) {
                        let boundary_ok = at == 0
                            || !line[..at]
                                .chars()
                                .next_back()
                                .map(|c| c.is_ascii_alphanumeric() || c == '_')
                                .unwrap_or(false);
                        if boundary_ok {
                            out.push((format!("{}:{}", path.display(), idx + 1), needle.clone()));
                            if out.len() >= 100 {
                                break 'walk;
                            }
                        }
                    }
                }
            }
        }
    }
    out.sort();
    out
}

/// The `package-drift` family.
fn package_drift(ctx: &MaintCtx<'_>) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let mut recorded: Vec<String> = Vec::new();
    for record in ctx.graph.records() {
        recorded.push(record.path.clone());
        let dir = ctx.root.join(&record.path);
        if !dir.is_dir() {
            out.push((record.id.as_str().to_string(), "missing-path".to_string()));
        }
    }
    let packages = ctx.root.join("packages");
    let mut stack = vec![packages.clone()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if !entry.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                continue;
            }
            let rel = path
                .strip_prefix(ctx.root)
                .map(|p| p.to_string_lossy().into_owned())
                .unwrap_or_default();
            if path.join("PKGBUILD").is_file() && !recorded.iter().any(|r| *r == rel) {
                out.push((rel, "unregistered-recipe-dir".to_string()));
            } else {
                stack.push(path);
            }
        }
    }
    out.sort();
    out
}

/// The `toolchain-edge` family: non-comment PKGBUILD lines naming `cargo`
/// or `rustc` as a bare word.
fn toolchain_edges(ctx: &MaintCtx<'_>) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for record in ctx.graph.records() {
        let id = record.id.as_str();
        if id == "rust-git" {
            continue;
        }
        let pkgbuild = ctx.root.join(&record.path).join("PKGBUILD");
        let text = match gsa_model::read::optional(&pkgbuild) {
            Ok(Some(text)) => text,
            Ok(None) => continue,
            Err(error) => {
                out.push((id.to_string(), format!("unreadable PKGBUILD: {error}")));
                continue;
            }
        };
        let invokes = text.lines().any(|line| {
            let trimmed = line.trim_start();
            if trimmed.starts_with('#') {
                return false;
            }
            trimmed
                .split(|c: char| !c.is_ascii_alphanumeric() && !matches!(c, '-' | '_' | '+' | '.'))
                .any(|word| word == "cargo" || word == "rustc")
        });
        if !invokes {
            continue;
        }
        let has_edge = record.edges.iter().any(|e| e.as_str() == "rust-git");
        if !has_edge {
            out.push((
                id.to_string(),
                "uses-cargo/rustc-but-declares-no-rust-git-edge".to_string(),
            ));
        }
    }
    out
}

/// The `installed-pgo` family: files of installed PGO-instrumenting recipes
/// whose bytes still carry a baked profiling destination.
fn installed_pgo(ctx: &MaintCtx<'_>) -> Vec<(String, String)> {
    let mut out = Vec::new();
    let db = match gsa_install::LocalDb::load(&pacman_db_root()) {
        Ok(db) => db,
        Err(_) => return vec![("(local-db)".to_string(), "unreadable".to_string())],
    };
    let declared = ctx.declared_names();
    for (id, dir) in ctx.recipe_dirs() {
        match gsa_install::gates::pgo_instrumented_recipe(Some(&dir)) {
            Ok(true) => {}
            Ok(false) => continue,
            Err(error) => {
                out.push((id.clone(), format!("unreadable PKGBUILD: {error}")));
                continue;
            }
        }
        let names = declared.get(&id).cloned().unwrap_or_default();
        for name in names {
            let Some(pkg) = db.get(&name) else {
                continue;
            };
            for file in &pkg.files {
                let Ok(bytes) = std::fs::read(file) else {
                    continue;
                };
                if find_bytes(&bytes, b".gcda").is_some()
                    || find_bytes(&bytes, b".profraw").is_some()
                {
                    out.push((name.clone(), format!("{file} baked-profiling-destination")));
                }
            }
        }
    }
    out.sort();
    out
}

fn find_bytes(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|w| w == needle)
}

/// `-Ma`: the whole report. Full rows per family; rc stays 0.
pub fn report(ctx: &MaintCtx<'_>) -> Vec<Row> {
    let mut rows = Vec::new();

    let legacy = legacy_layout(ctx.root);
    push_family(&mut rows, "legacy-layout", legacy);

    let drift = package_drift(ctx);
    push_family(&mut rows, "package-drift", drift);

    let toolchain = toolchain_edges(ctx);
    push_family(&mut rows, "toolchain-edge", toolchain);

    let stale: Vec<(String, String)> = hygiene::stale_artifacts(ctx.state.path(), ctx.root)
        .into_iter()
        .map(|(path, class)| (path.display().to_string(), class.to_string()))
        .collect();
    push_family(&mut rows, "stale-artifact", stale);

    // The recipe-contract lints (the QA registry's report checks).
    let qa: Vec<(String, String)> = match load_workspace(ctx.root) {
        Ok(workspace) => {
            let mut archive_warn = Vec::new();
            let mut rows = Vec::new();
            match collect_archives_checked(&workspace.recipes, &[], &mut archive_warn) {
                Ok(archives) => {
                    if !archive_warn.is_empty() {
                        for line in String::from_utf8_lossy(&archive_warn).lines() {
                            if !line.trim().is_empty() {
                                rows.push(("archive-scan".to_string(), line.to_string()));
                            }
                        }
                    }
                    match gsa_install::LocalDb::load(&pacman_db_root()) {
                        Ok(db) => {
                            let installed: Vec<QaInstalled> = db
                                .packages()
                                .into_iter()
                                .map(|pkg| QaInstalled {
                                    name: pkg.name.clone(),
                                    version: pkg.version.clone(),
                                    provides: pkg.provides.clone(),
                                    depends: pkg.depends.clone(),
                                    files: pkg.files.clone(),
                                })
                                .collect();
                            let input = QaInput {
                                recipes: &workspace.recipes,
                                targets: &[],
                                archives: &archives,
                                installed: &installed,
                                exclusions: &workspace.exclusions,
                            };
                            for finding in gsa_qa::report::report_findings(&input) {
                                rows.push((
                                    format!("{}: {}", finding.check, finding.subject),
                                    finding.detail.clone(),
                                ));
                            }
                        }
                        Err(error) => {
                            rows.push((
                                "(local-db)".to_string(),
                                format!("local DB unreadable: {error}"),
                            ));
                        }
                    }
                }
                Err(error) => {
                    rows.push(("(archives)".to_string(), error));
                }
            }
            // A recipe the lints could not read is NOT a clean recipe.
            for (id, reason) in &workspace.unlintable {
                rows.push((format!("unlintable: {id}"), reason.clone()));
            }
            rows
        }
        Err(error) => vec![("(workspace)".to_string(), error.to_string())],
    };
    push_family(&mut rows, "recipe-contract", qa);

    // The stale-set skew lint (docs/plans/plan-gentoo-qol.md shortlist 6), scoped to
    // what the side-car records know.
    let skew: Vec<(String, String)> = match crate::version_skew_rows(ctx) {
        Ok(items) => items
            .into_iter()
            .map(|(id, built, committed)| (id, format!("built={built} committed={committed}")))
            .collect(),
        Err(error) => vec![("(index)".to_string(), error)],
    };
    push_family(&mut rows, "version-sync-skew", skew);
    rows.push(Row::new(
        "audit",
        "version-sync-skew",
        "scope=side-car-records-only — provider queries land with the version-sync phase",
    ));

    let pgo = installed_pgo(ctx);
    push_family(&mut rows, "installed-pgo", pgo);

    let recipe_integrity = recipe_integrity(ctx);
    push_family(&mut rows, "recipe-integrity", recipe_integrity);

    let integrity = state_integrity(ctx);
    push_family(&mut rows, "state-integrity", integrity);

    rows
}

/// Source claims a recipe cannot honour (blind-review 2026-11-11,
/// airgapped-admin): a `source=()` entry with no transport that is absent
/// from the recipe directory (makepkg will refuse the build), and a REMOTE
/// source the recipe pins as `SKIP` — fetched, never verified, which a clean
/// audit would present as trustworthy. A VCS source with `SKIP` is the
/// normal spelling and is not reported.
fn recipe_integrity(ctx: &MaintCtx<'_>) -> Vec<(String, String)> {
    let mut out = Vec::new();
    for record in ctx.graph.records() {
        let id = record.id.as_str();
        let Some(meta) = ctx.db.get(id) else {
            continue;
        };
        let dir = ctx.root.join(&record.path);
        let missing = meta.missing_local_sources(&dir);
        if !missing.is_empty() {
            out.push((
                id.to_string(),
                format!("local-source-missing {}", missing.join(" ")),
            ));
        }
        let unverified = meta.unverified_remote_sums();
        if !unverified.is_empty() {
            out.push((
                id.to_string(),
                format!("unverified-sums {}", unverified.join(" ")),
            ));
        }
    }
    out
}

/// The side-car's own truth (rule 71). Three silent-loss classes used to pass
/// as clean here while `--local-db-check health` named them exactly
/// (blind-review 2026-11-11, skeptic): a torn `index/binpkg.jsonl` folded as
/// fact, a truncated `runs/history.jsonl` losing runs, and an index row whose
/// archive was deleted or truncated. The audit is report-only (§E.4), so this
/// family REPORTS rather than refuses — but it never calls such a store
/// clean.
fn state_integrity(ctx: &MaintCtx<'_>) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    match gsa_state::BinpkgIndex::load(ctx.state) {
        Ok(index) => {
            for line in &index.corrupt {
                out.push((format!("{}:{}", line.store, line.line), line.render()));
            }
            for row in &index.rows {
                let path = std::path::Path::new(&row.archive);
                match std::fs::metadata(path) {
                    Err(error) => out.push((
                        row.recipe_id.clone(),
                        format!(
                            "archive-unreadable instance={} {} ({error})",
                            row.instance,
                            path.display()
                        ),
                    )),
                    Ok(meta) if meta.len() != row.size => out.push((
                        row.recipe_id.clone(),
                        format!(
                            "archive-size-mismatch instance={} {} recorded={} actual={}",
                            row.instance,
                            path.display(),
                            row.size,
                            meta.len()
                        ),
                    )),
                    Ok(_) => {}
                }
            }
        }
        Err(error) => out.push(("(index)".to_string(), error.to_string())),
    }
    // Rule 71: an UNREADABLE store is a finding, never a clean bill. `-Ma`
    // reported `state-integrity clean` while the run history and the kv
    // store could not be read at all (blind review, 2026-11-11).
    match gsa_state::RunHistory::read(ctx.state) {
        Ok((_records, corrupt)) => {
            for line in &corrupt {
                out.push((format!("{}:{}", line.store, line.line), line.render()));
            }
        }
        Err(error) => out.push((
            "(runs)".to_string(),
            format!("run history is unreadable: {error}"),
        )),
    }
    match gsa_state::Kv::list(ctx.state) {
        Ok((_pairs, corrupt)) => {
            for line in &corrupt {
                out.push((format!("{}:{}", line.store, line.line), line.render()));
            }
        }
        Err(error) => out.push((
            "(kv)".to_string(),
            format!("kv store is unreadable: {error}"),
        )),
    }
    out
}

fn push_family(rows: &mut Vec<Row>, family: &str, findings: Vec<(String, String)>) {
    let count = findings.len();
    rows.push(Row::new(
        "audit",
        family,
        if count == 0 {
            "clean".to_string()
        } else {
            format!("{count} finding(s)")
        },
    ));
    for (subject, detail) in findings {
        rows.push(Row::new(family, subject, detail));
    }
}
