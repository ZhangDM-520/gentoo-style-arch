//! Shared-source mirrors (`gsa -Mm`, contract §B.7 — today's
//! `--link-sources`, `docs/source-sharing.md`): dedupe the VCS source clones
//! makepkg keeps beside the recipes into one canonical mirror per effective
//! URL. Duplicate local names are symlinked to the canonical clone (a
//! missing canonical leaves a dangling symlink until its first build
//! populates it — makepkg clones through the link); a real canonical clone
//! gets its `remote.origin.url`/`fetch` refspec repaired when safe; a
//! populated non-Git directory is never overwritten.
//!
//! Canonical selection prefers an existing valid mirror, then `packages/core/`
//! paths, then the rest (the fish ranking). Symlinks are never deleted or
//! followed beyond what this verb itself creates. This verb MUST run as the
//! build user (never a root supervisor — `docs/source-sharing.md`), and it
//! is confirmation-gated: without `--noconfirm` it prints its plan and stops
//! (`confirmation-required`), never prompting (§K.3).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;

use gsa_recipe::SourceKind;

use crate::{MaintCtx, Row};

/// One duplicate-clone group member: a recipe's local source name beside
/// its recipe directory.
#[derive(Clone, Debug)]
struct Member {
    recipe: String,
    dir: PathBuf,
    path: PathBuf,
}

/// `git` with the agent-shell hardening neutralised (bare-repo safe) and no
/// inherited config — mirrors the fixture convention (`GIT_CONFIG_COUNT=0`).
/// `None` is COMMAND failure only (spawn error or non-zero exit): a
/// successful command that prints nothing (`git remote set-url`,
/// `git config remote.origin.fetch …`) answers `Some("")`, never a false
/// failure. Read-style `--get` callers still see `None` for "unset", because
/// git itself exits non-zero there.
fn git(dir: &Path, args: &[&str]) -> Option<String> {
    let output = Command::new("git")
        .env("GIT_CONFIG_COUNT", "0")
        .arg("-c")
        .arg("safe.bareRepository=all")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .ok()?;
    if !output.status.success() {
        return None;
    }
    Some(String::from_utf8_lossy(&output.stdout).trim().to_string())
}

/// Is this path a real Git working clone or bare mirror (the only shapes
/// `docs/source-sharing.md` accepts as an existing canonical source)?
fn valid_source_mirror(path: &Path) -> bool {
    if !path.is_dir() {
        return false;
    }
    let Ok(abs) = std::fs::canonicalize(path) else {
        return false;
    };
    let Some(git_dir) = git(path, &["rev-parse", "--absolute-git-dir"]) else {
        return false;
    };
    let Ok(git_dir) = std::fs::canonicalize(git_dir) else {
        return false;
    };
    if git_dir == abs {
        return git(path, &["rev-parse", "--is-bare-repository"]).as_deref() == Some("true");
    }
    match git(path, &["rev-parse", "--show-toplevel"]) {
        Some(top) => std::fs::canonicalize(top)
            .map(|t| t == abs)
            .unwrap_or(false),
        None => false,
    }
}

/// A path relative to `from`'s parent for a symlink target (both under the
/// workspace: a relative link survives a workspace move).
fn relpath(from: &Path, to: &Path) -> PathBuf {
    let from_parent = from.parent().unwrap_or(from);
    let mut from_parts: Vec<_> = from_parent.components().collect();
    let to_parts: Vec<_> = to.components().collect();
    let common = from_parts
        .iter()
        .zip(to_parts.iter())
        .take_while(|(a, b)| a == b)
        .count();
    let mut out = PathBuf::new();
    for _ in common..from_parts.len() {
        from_parts.pop();
        out.push("..");
    }
    for part in &to_parts[common..] {
        out.push(part);
    }
    out
}

/// Group every `git+` source by effective URL (fragment/query stripped —
/// one mirror serves several refs), exactly as the fish scan does.
fn groups(ctx: &MaintCtx<'_>) -> BTreeMap<String, Vec<Member>> {
    let mut out: BTreeMap<String, Vec<Member>> = BTreeMap::new();
    for (id, dir) in ctx.recipe_dirs() {
        let Some(meta) = ctx.db.get(&id) else {
            continue;
        };
        for source in meta.sources() {
            if source.kind != SourceKind::Vcs(gsa_recipe::VcsKind::Git) {
                continue;
            }
            let location = source
                .location
                .split_once('?')
                .map(|(before, _)| before)
                .unwrap_or(&source.location);
            let location = location
                .split_once('#')
                .map(|(before, _)| before)
                .unwrap_or(location);
            let effective = location.trim_end_matches('/').to_string();
            let name = match &source.name {
                Some(name) => name.clone(),
                None => {
                    let mut base = effective
                        .rsplit('/')
                        .next()
                        .unwrap_or(&effective)
                        .to_string();
                    if base.ends_with(".git") {
                        base.truncate(base.len() - 4);
                    }
                    base
                }
            };
            if name.is_empty() || name == "." || name == ".." {
                continue;
            }
            let path = dir.join(&name);
            out.entry(effective).or_default().push(Member {
                recipe: id.clone(),
                dir: dir.clone(),
                path,
            });
        }
    }
    out
}

/// The rank key of one member (lower wins): valid real mirror 0, valid
/// symlink mirror 1, missing 2, populated non-git 3; core paths win ties
/// (fish `link_sources` ranking).
fn rank(path: &Path, core_preferred: bool) -> u32 {
    let base = if valid_source_mirror(path) {
        if std::fs::symlink_metadata(path)
            .map(|m| m.file_type().is_symlink())
            .unwrap_or(false)
        {
            1
        } else {
            0
        }
    } else if path.is_dir()
        && std::fs::read_dir(path)
            .map(|mut e| e.next().is_some())
            .unwrap_or(false)
    {
        3
    } else {
        2
    };
    base * 10 + if core_preferred { 0 } else { 1 }
}

/// `-Mm`'s plan/applied rows. `apply` performs the mutations; without it the
/// same rows describe the plan (`planned`/`would` wording in the reason).
/// Every mutation goes through git (origin repair) or `symlink(2)`/`unlink`
/// on paths proven to live inside the recipe directory tree.
pub fn run(ctx: &MaintCtx<'_>, apply: bool) -> Result<Vec<Row>, String> {
    if gsa_sched::signals::current_uid() == 0 {
        return Err(
            "must run as the build user, never under a root supervisor (docs/source-sharing.md)"
                .to_string(),
        );
    }
    let mut rows = Vec::new();
    let mut groups = groups(ctx);
    groups.retain(|_, members| members.len() >= 2);
    if groups.is_empty() {
        rows.push(Row::new("mirrors", "clean", "no duplicated git sources"));
        return Ok(rows);
    }
    for (url, members) in groups {
        let mut ranked: Vec<(u32, &Member)> = members
            .iter()
            .map(|m| {
                let core = m.dir.starts_with(ctx.root.join("packages/core"));
                (rank(&m.path, core), m)
            })
            .collect();
        ranked.sort_by_key(|(key, m)| (*key, m.path.clone()));
        let (_, canonical) = ranked[0];
        rows.push(Row::new(
            canonical.path.display().to_string(),
            "canonical",
            format!("mirror {url}"),
        ));

        // Repair an existing canonical mirror (origin URL and refspec).
        if valid_source_mirror(&canonical.path) {
            let origin = git(&canonical.path, &["config", "--get", "remote.origin.url"]);
            if origin.as_deref() != Some(url.as_str()) {
                let reason = format!("origin {} -> {url}", origin.as_deref().unwrap_or("(none)"));
                if apply {
                    if git(&canonical.path, &["remote", "set-url", "origin", &url]).is_none() {
                        rows.push(Row::new(
                            canonical.path.display().to_string(),
                            "failed",
                            format!("repair-origin {reason}"),
                        ));
                    } else {
                        rows.push(Row::new(
                            canonical.path.display().to_string(),
                            "repair-origin",
                            format!("applied {reason}"),
                        ));
                    }
                } else {
                    rows.push(Row::new(
                        canonical.path.display().to_string(),
                        "repair-origin",
                        format!("planned {reason}"),
                    ));
                }
            }
            let refspec = git(
                &canonical.path,
                &["config", "--get-all", "remote.origin.fetch"],
            );
            if refspec.is_none() {
                if apply {
                    if git(
                        &canonical.path,
                        &["config", "remote.origin.fetch", "+refs/*:refs/*"],
                    )
                    .is_none()
                    {
                        rows.push(Row::new(
                            canonical.path.display().to_string(),
                            "failed",
                            "repair-refspec add +refs/*:refs/*",
                        ));
                    } else {
                        rows.push(Row::new(
                            canonical.path.display().to_string(),
                            "repair-refspec",
                            "applied add +refs/*:refs/*",
                        ));
                    }
                } else {
                    rows.push(Row::new(
                        canonical.path.display().to_string(),
                        "repair-refspec",
                        "planned add +refs/*:refs/*",
                    ));
                }
            }
        }

        for (_, member) in ranked.iter().skip(1) {
            let shown = member.path.display().to_string();
            let link_to = relpath(&member.path, &canonical.path);
            if std::fs::symlink_metadata(&member.path)
                .map(|m| m.file_type().is_symlink())
                .unwrap_or(false)
            {
                let target = std::fs::read_link(&member.path).unwrap_or_default();
                if target == link_to {
                    rows.push(crate::protect::keep_row(&shown, "already-linked"));
                } else {
                    rows.push(crate::protect::keep_row(
                        &shown,
                        &format!("symlink-to {}", target.display()),
                    ));
                }
                continue;
            }
            if member.path.is_dir() {
                let populated = std::fs::read_dir(&member.path)
                    .map(|mut e| e.next().is_some())
                    .unwrap_or(false);
                if populated {
                    rows.push(Row::new(
                        shown,
                        "skip",
                        format!("populated-non-git {}", member.recipe),
                    ));
                    continue;
                }
                // A stale empty source directory is replaced by the link.
                if apply {
                    if let Err(error) = std::fs::remove_dir(&member.path) {
                        rows.push(Row::new(shown, "failed", format!("replace-empty: {error}")));
                        continue;
                    }
                }
            } else if member.path.exists() {
                rows.push(Row::new(
                    shown,
                    "skip",
                    format!("not-a-clone {}", member.recipe),
                ));
                continue;
            }
            if apply {
                match std::os::unix::fs::symlink(&link_to, &member.path) {
                    Ok(()) => rows.push(Row::new(
                        shown,
                        "link",
                        format!("applied -> {}", link_to.display()),
                    )),
                    Err(error) => rows.push(Row::new(shown, "failed", format!("link: {error}"))),
                }
            } else {
                rows.push(Row::new(
                    shown,
                    "link",
                    format!("planned -> {}", link_to.display()),
                ));
            }
        }
    }
    Ok(rows)
}
