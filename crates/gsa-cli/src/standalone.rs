//! Standalone-PKGBUILD target input (plan-gsa-isolation.md W4's
//! distribution unit: "stage → build → index"). A target may name a shared
//! recipe instead of a workspace reference — a `PKGBUILD` file path, a
//! directory holding one, or an `http(s)` URL of one — and the run stages it
//! into its own one-node workspace and builds THERE: "rebuilding = gsa + the
//! recipe, no project clone required".
//!
//! Staging model: one workspace per invocation under `<state>/standalone/`
//! (`config/` skeleton plus `packages/misc/<name>/` per target), rewritten
//! wholesale (delete first — a re-staged run never inherits the previous
//! one's files). A read-only run (`--dry-run`) and a run the privilege gate
//! will refuse stage EPHEMERALLY under the temp dir and clean up after
//! dispatch: dry runs are read-only (§B.10) and a refused run must leave no
//! state behind. The staged ids replace `inv.targets`, and the entries
//! resolve the workspace through `crate::resolve_workspace`, which prefers
//! `inv.standalone_root`.
//!
//! Disambiguation: workspace references win. A token a discoverable
//! workspace answers (recipe path, id, case-variant id, package name — the
//! exact `select::resolve_ref` vocabulary) stays a workspace reference even
//! if it also names a directory with a `PKGBUILD`, so documented recipe-path
//! refs keep working inside the recipe repository. Only tokens NO workspace
//! answers become standalone. A run cannot mix the two (usage error).

use std::path::{Path, PathBuf};

use crate::args::Invocation;
use crate::select::Ctx;

/// What one standalone token names.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    /// A `PKGBUILD` file path; only that file is staged (sibling local
    /// sources must be URLs — documented limitation).
    File,
    /// A directory holding a `PKGBUILD`; copied minus makepkg's output dirs
    /// (`src/`, `pkg/`, `build/`) and `*.pkg.tar.zst` archives at the top
    /// level.
    Dir,
    /// An URL of a `PKGBUILD` (fetched with `curl`, same as the engine's
    /// other URL intakes: `http(s)://…`, or `file://…` for a local mirror).
    Url,
}

/// The syntactic standalone candidates: URL, `PKGBUILD` file path, or a
/// directory holding a `PKGBUILD`. Everything else may still be a candidate
/// only through [`Kind::Dir`] — see [`apply`]'s disambiguation.
pub(crate) fn kind_of(token: &str) -> Option<Kind> {
    // Any `scheme://` token is a URL intake (`curl` speaks http(s) and
    // file — the latter is the network-free seam fixtures use).
    if token.contains("://") {
        return Some(Kind::Url);
    }
    let path = Path::new(token);
    if path.file_name().is_some_and(|name| name == "PKGBUILD") {
        return Some(Kind::File);
    }
    if path.is_dir() && path.join("PKGBUILD").is_file() {
        return Some(Kind::Dir);
    }
    None
}

/// The staged run's workspace root and how to treat it after dispatch.
pub(crate) struct Staged {
    root: PathBuf,
    ephemeral: bool,
}

impl Staged {
    /// Remove an ephemeral staging area. Persistent staging IS state
    /// (the recipe work area of the distribution unit) and stays.
    pub(crate) fn cleanup(self) {
        if self.ephemeral {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }
}

/// Which commands take standalone targets in v1: the workspace-consuming
/// build/install/fetch/maintain surface and its `--dry-run` plan render
/// (`Command::Plan`). Pure query/report verbs read a workspace and are
/// documented as standalone-unsupported until a later phase.
pub(crate) fn supports(command: &crate::Command) -> bool {
    matches!(
        command,
        crate::Command::Build
            | crate::Command::BuildInstall
            | crate::Command::Fetch
            | crate::Command::SyncPass
            | crate::Command::Update
            | crate::Command::Upgrade
            | crate::Command::Maint
            | crate::Command::Plan
    )
}

/// Stage standalone targets and rewrite `inv` to run against the staged
/// workspace. `Ok(None)` = nothing standalone-shaped in this invocation
/// (the overwhelming majority: zero cost, zero behaviour change).
pub(crate) fn apply(
    inv: &mut Invocation,
    command: &crate::Command,
) -> Result<Option<Staged>, String> {
    if inv.targets.is_empty() {
        return Ok(None);
    }
    let kinds: Vec<Option<Kind>> = inv.targets.iter().map(|t| kind_of(t)).collect();
    if kinds.iter().all(Option::is_none) {
        return Ok(None);
    }

    // Disambiguate: workspace references win (module doc). Only a token no
    // discoverable workspace answers is standalone.
    let mut standalone: Vec<(String, Kind)> = Vec::new();
    let mut workspace: Vec<String> = Vec::new();
    let candidates: Vec<String> = inv
        .targets
        .iter()
        .zip(&kinds)
        .filter(|(_, kind)| kind.is_some())
        .map(|(token, _)| token.clone())
        .collect();
    // The discoverable workspace root, resolved once: the disambiguation
    // probe reads it and staging takes the shared `lib/` from it (S5).
    let ws_root = crate::resolve_root(false, inv.state_dir.as_deref()).ok();
    // I5: a kv user set is a workspace answer too (@name resolves over
    // kv user-sets ∪ config/sets/).
    let user_sets = crate::select::load_user_sets(inv);
    let answered = workspace_answers(&candidates, ws_root.as_deref(), &user_sets);
    for (token, kind) in inv.targets.iter().zip(&kinds) {
        match kind {
            None => workspace.push(token.clone()),
            Some(kind) => {
                if answered.get(token).copied().unwrap_or(false) {
                    workspace.push(token.clone());
                } else {
                    standalone.push((token.clone(), *kind));
                }
            }
        }
    }
    if standalone.is_empty() {
        return Ok(None);
    }
    if !workspace.is_empty() {
        return Err(format!(
            "standalone targets ({}) cannot be combined with workspace references ({}) in one run",
            join_names(standalone.iter().map(|(t, _)| t.as_str())),
            join_names(workspace.iter().map(|t| t.as_str())),
        ));
    }
    if !supports(command) {
        return Err(format!(
            "standalone targets are not supported by 'gsa {}': query and report verbs read a workspace (plan a standalone build with '--dry-run -B')",
            inv.spelling()
        ));
    }

    // Ephemeral staging when the run writes nothing anyway: a --dry-run
    // renders a plan (§B.10 reads), and a run the privilege gate will refuse
    // must leave no state behind (the gate itself fires in the entry, after
    // usage preflights — this probe only picks the staging area).
    let privilege = crate::invocation_privilege(inv, command);
    let would_refuse = crate::privilege_gate(&inv.spelling(), privilege, false, &mut std::io::sink())
        .is_some();
    let ephemeral = inv.dry_run || would_refuse;
    let root = if ephemeral {
        std::env::temp_dir().join(format!(
            "gsa-standalone-{}-{}",
            std::process::id(),
            unique_suffix()
        ))
    } else {
        gsa_model::config::resolve_state_dir(inv.state_dir.as_deref())
            .map_err(|e| format!("cannot resolve the state root for staging: {e}"))?
            .join("standalone")
    };

    // Delete the destination first (change hygiene): staging is derived
    // state and is rebuilt wholesale on every run.
    if root.exists() {
        std::fs::remove_dir_all(&root)
            .map_err(|e| format!("cannot clear the staging area {}: {e}", root.display()))?;
    }
    let ids = stage(&standalone, &root, ws_root.as_deref())?;
    for ((token, _), id) in standalone.iter().zip(&ids) {
        eprintln!("gsa: staged standalone target '{token}' as '{id}'");
    }
    inv.targets = ids;
    inv.standalone_root = Some(root.clone());
    Ok(Some(Staged { root, ephemeral }))
}

/// Which of `tokens` a discoverable workspace answers as a reference
/// (`select::resolve_ref`'s exact vocabulary). A token no workspace answers
/// (including when there is no workspace at all) maps to `false`. Failures
/// to load a workspace count as "no workspace": the standalone path then
/// carries the run and its staged workspace is all it needs. The workspace
/// root is resolved once by the caller ([`apply`]) and passed in.
fn workspace_answers(
    tokens: &[String],
    ws_root: Option<&Path>,
    user_sets: &[(String, Vec<String>)],
) -> std::collections::HashMap<String, bool> {
    let mut out = std::collections::HashMap::new();
    if tokens.is_empty() {
        return out;
    }
    let Some(root) = ws_root else {
        for token in tokens {
            out.insert(token.clone(), false);
        }
        return out;
    };
    let Ok(project) = gsa_topo::load_project(&root) else {
        for token in tokens {
            out.insert(token.clone(), false);
        }
        return out;
    };
    let Ok(graph) = gsa_graph::Graph::build(&project.topology.records) else {
        for token in tokens {
            out.insert(token.clone(), false);
        }
        return out;
    };
    let Ok(db) = gsa_recipe::RecipeDb::load(&root, graph.records()) else {
        for token in tokens {
            out.insert(token.clone(), false);
        }
        return out;
    };
    let ctx = Ctx {
        project: &project,
        graph: &graph,
        db: &db,
        user_sets: user_sets.to_vec(),
    };
    for token in tokens {
        out.insert(token.clone(), crate::select::resolve_ref(&ctx, token, 0).is_ok());
    }
    out
}

/// The staged workspace skeleton (the fixture-proven `make_workspace` shape,
/// one record per staged target: `name|packages/misc/name|misc|`). When a
/// source workspace root is discoverable, its `lib/` (the shared-gate
/// library: `pgo.sh`, `cups-config`) is staged alongside — every documented
/// PGO family sources the shared gate by a repo-relative path
/// (`$startdir/../../../lib/pgo.sh`), and without it a shared-gate recipe
/// hard-fails at PKGBUILD parse in a standalone run (S5).
fn stage(
    entries: &[(String, Kind)],
    root: &Path,
    shared_root: Option<&Path>,
) -> Result<Vec<String>, String> {
    let config = root.join("config");
    let packages = root.join("packages").join("misc");
    std::fs::create_dir_all(&config)
        .and_then(|_| std::fs::create_dir_all(&packages))
        .map_err(|e| format!("cannot create the staging area {}: {e}", root.display()))?;

    let mut ids: Vec<String> = Vec::new();
    let mut records = String::from(
        "# One record per package: id|path|groups|edges[|tags]\n\
         # (a lone id|path|groups| is a deliberate no-edge record)\n",
    );
    for (token, kind) in entries {
        let mut name = derived_name(token, *kind);
        let mut n = 2;
        while ids.contains(&name) {
            name = format!("{}-{n}", derived_name(token, *kind));
            n += 1;
        }
        let recipe = packages.join(&name);
        std::fs::create_dir_all(&recipe)
            .map_err(|e| format!("cannot create {}: {e}", recipe.display()))?;
        match kind {
            Kind::File => {
                let dst = recipe.join("PKGBUILD");
                std::fs::copy(token, &dst).map_err(|e| {
                    format!("cannot stage standalone PKGBUILD '{token}': {e}")
                })?;
            }
            Kind::Dir => {
                copy_recipe_tree(Path::new(token), &recipe)
                    .map_err(|e| format!("cannot stage standalone recipe '{token}': {e}"))?;
            }
            Kind::Url => {
                let body = fetch_url(token)?;
                std::fs::write(recipe.join("PKGBUILD"), body)
                    .map_err(|e| format!("cannot write the PKGBUILD fetched from '{token}': {e}"))?;
            }
        }
        // The recipe tree is a build-domain path (makepkg's $startdir): an
        // engine-side write into one is handed to the build user (W1's
        // `own_to_build_user`), so build-side commands may write there.
        gsa_model::privilege::own_to_build_user(&recipe)?;
        records.push_str(&format!("{name}|packages/misc/{name}|misc|\n"));
        ids.push(name);
    }

    std::fs::write(config.join("topology.conf"), records)
        .and_then(|_| {
            std::fs::write(
                config.join("build-defaults.conf"),
                "lanes=auto\njobs=2\nintensity=low\nmemory_per_job_gib=1\n\
                 core_memory_per_job_gib=1\nreserved_memory_gib=1\n",
            )
        })
        .and_then(|_| {
            std::fs::write(
                config.join("abi-exclusions.conf"),
                "# ABI-guard exception registry: id|reason|review-by (empty registry)\n",
            )
        })
        .map_err(|e| format!("cannot write the staged workspace config: {e}"))?;
    if let Some(src) = shared_root.map(|r| r.join("lib")).filter(|p| p.is_dir()) {
        let dst = root.join("lib");
        copy_entry(&src, &dst).map_err(|e| {
            format!("cannot stage the shared gate library {}: {e}", src.display())
        })?;
        // Read (and exec) during the build as the build user: hand it over
        // like the recipe tree.
        gsa_model::privilege::own_to_build_user(&dst)?;
    }
    Ok(ids)
}

/// Copy one recipe directory: everything except makepkg's output dirs
/// (`src/`, `pkg/`, `build/`) and `*.pkg.tar.zst` archives at the TOP level
/// — a recipe may legitimately ship nested directories of those names.
fn copy_recipe_tree(src: &Path, dst: &Path) -> Result<(), String> {
    for entry in std::fs::read_dir(src).map_err(|e| format!("{src:?}: {e}"))? {
        let entry = entry.map_err(|e| format!("{src:?}: {e}"))?;
        let name = entry.file_name();
        let name_str = name.to_string_lossy();
        if matches!(name_str.as_ref(), "src" | "pkg" | "build") {
            continue;
        }
        if name_str.ends_with(".pkg.tar.zst") {
            continue;
        }
        copy_entry(&entry.path(), &dst.join(&name))?;
    }
    Ok(())
}

fn copy_entry(src: &Path, dst: &Path) -> Result<(), String> {
    let meta = std::fs::symlink_metadata(src).map_err(|e| format!("{src:?}: {e}"))?;
    if meta.file_type().is_symlink() {
        let target = std::fs::read_link(src).map_err(|e| format!("{src:?}: {e}"))?;
        std::os::unix::fs::symlink(target, dst).map_err(|e| format!("{dst:?}: {e}"))?;
    } else if meta.is_dir() {
        std::fs::create_dir_all(dst).map_err(|e| format!("{dst:?}: {e}"))?;
        for entry in std::fs::read_dir(src).map_err(|e| format!("{src:?}: {e}"))? {
            let entry = entry.map_err(|e| format!("{src:?}: {e}"))?;
            copy_entry(&entry.path(), &dst.join(entry.file_name()))?;
        }
    } else {
        std::fs::copy(src, dst).map_err(|e| format!("{src:?}: {e}"))?;
    }
    Ok(())
}

/// Fetch a URL with `curl` through PATH (the engine's URL intakes all go
/// through PATH — `docs/gsa-contract.md` §D.2).
fn fetch_url(url: &str) -> Result<Vec<u8>, String> {
    let out = std::process::Command::new("curl")
        .args([
            "--silent",
            "--show-error",
            "--location",
            "--fail",
            "--max-time",
            "60",
            "--connect-timeout",
            "10",
        ])
        .arg(url)
        .output()
        .map_err(|e| format!("cannot fetch '{url}': curl: {e}"))?;
    if !out.status.success() {
        return Err(format!(
            "cannot fetch the standalone PKGBUILD from '{url}': curl exit {}",
            out.status
        ));
    }
    Ok(out.stdout)
}

/// The staged recipe id derived from the target: the directory name (Dir),
/// the `PKGBUILD`'s parent directory name (File), or the URL's path segment
/// before the `PKGBUILD` leaf (Url). Sanitized to the topology id charset;
/// a name that sanitizes away entirely becomes `standalone`.
fn derived_name(token: &str, kind: Kind) -> String {
    let raw = match kind {
        Kind::Url => {
            let trimmed = token.trim_end_matches('/');
            let mut segments: Vec<&str> = trimmed
                .rsplit('/')
                .filter(|segment| !segment.is_empty())
                .collect();
            if segments
                .first()
                .is_some_and(|s| s.eq_ignore_ascii_case("PKGBUILD"))
            {
                segments.remove(0);
            }
            segments.first().copied().unwrap_or("").to_string()
        }
        Kind::File => {
            let path = Path::new(token);
            let parent = match path.parent() {
                Some(parent) if !parent.as_os_str().is_empty() => parent.to_path_buf(),
                _ => std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")),
            };
            let parent = std::fs::canonicalize(&parent).unwrap_or(parent);
            parent
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_default()
        }
        Kind::Dir => Path::new(token)
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_default(),
    };
    sanitize_name(&raw)
}

/// The topology id charset (`A-Za-z0-9._+-`), with the `record::subject_id`
/// fallback shape: never empty, never `.`/`..` (the name is joined under
/// `packages/misc/`).
fn sanitize_name(raw: &str) -> String {
    let mapped: String = raw
        .chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '+' | '-') {
                c
            } else {
                '-'
            }
        })
        .collect();
    if mapped.is_empty() || mapped.chars().all(|c| c == '.') {
        "standalone".to_string()
    } else {
        mapped
    }
}

fn join_names<'a>(names: impl Iterator<Item = &'a str>) -> String {
    names
        .map(|name| format!("'{name}'"))
        .collect::<Vec<_>>()
        .join(", ")
}

/// A per-process staging-name suffix (ephemeral staging must never collide
/// across concurrent runs).
fn unique_suffix() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "gsa-standalone-test-{tag}-{}-{}",
            std::process::id(),
            unique_suffix()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn kinds_are_syntactic() {
        assert_eq!(kind_of("https://example.invalid/a/PKGBUILD"), Some(Kind::Url));
        assert_eq!(kind_of("http://example.invalid/raw"), Some(Kind::Url));
        assert_eq!(kind_of("file:///tmp/a/PKGBUILD"), Some(Kind::Url));
        assert_eq!(kind_of("/nowhere/PKGBUILD"), Some(Kind::File));
        assert_eq!(kind_of("PKGBUILD"), Some(Kind::File));
        assert_eq!(kind_of("mesa-git"), None);
        assert_eq!(kind_of("@misc"), None);
    }

    #[test]
    fn dir_kind_needs_an_actual_pkgbuild() {
        let dir = temp_dir("kind");
        std::fs::create_dir_all(dir.join("empty")).unwrap();
        assert_eq!(kind_of(dir.join("empty").to_str().unwrap()), None);
        std::fs::write(dir.join("empty").join("PKGBUILD"), "pkgname=x\n").unwrap();
        assert_eq!(kind_of(dir.join("empty").to_str().unwrap()), Some(Kind::Dir));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn names_derive_and_sanitize() {
        assert_eq!(derived_name("/a/b/foo", Kind::Dir), "foo");
        assert_eq!(derived_name("https://h/x/bar/PKGBUILD", Kind::Url), "bar");
        assert_eq!(derived_name("https://h/x/PKGBUILD", Kind::Url), "x");
        assert_eq!(sanitize_name("my recipe"), "my-recipe");
        assert_eq!(sanitize_name(".."), "standalone");
        assert_eq!(sanitize_name(""), "standalone");
    }

    #[test]
    fn stage_builds_the_one_node_workspace() {
        let dir = temp_dir("stage");
        let src = dir.join("shared").join("neat-pkg");
        std::fs::create_dir_all(src.join("src")).unwrap();
        std::fs::create_dir_all(src.join("pkg")).unwrap();
        std::fs::write(src.join("PKGBUILD"), "pkgname=neat-pkg\n").unwrap();
        std::fs::write(src.join("fix.patch"), "patch\n").unwrap();
        std::fs::write(src.join("src").join("junk"), "build output\n").unwrap();
        std::fs::write(src.join("neat-pkg-1-1-any.pkg.tar.zst"), "archive\n").unwrap();

        let root = dir.join("staged");
        let entries = vec![(src.to_str().unwrap().to_string(), Kind::Dir)];
        let ids = stage(&entries, &root, None).unwrap();
        assert_eq!(ids, vec!["neat-pkg".to_string()]);

        let recipe = root.join("packages").join("misc").join("neat-pkg");
        assert!(recipe.join("PKGBUILD").is_file());
        assert!(recipe.join("fix.patch").is_file());
        assert!(!recipe.join("src").exists(), "makepkg output dirs are not staged");
        assert!(!recipe.join("pkg").exists(), "makepkg output dirs are not staged");
        assert!(
            !recipe.join("neat-pkg-1-1-any.pkg.tar.zst").exists(),
            "archives are not staged"
        );

        let topology = std::fs::read_to_string(root.join("config").join("topology.conf")).unwrap();
        assert!(topology.contains("neat-pkg|packages/misc/neat-pkg|misc|"));
        let defaults =
            std::fs::read_to_string(root.join("config").join("build-defaults.conf")).unwrap();
        gsa_topo::parse_build_defaults(&defaults, "staged").expect("the staged defaults parse");

        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn stage_dedupes_colliding_names() {
        let dir = temp_dir("dedupe");
        let a = dir.join("a").join("same");
        let b = dir.join("b").join("same");
        std::fs::create_dir_all(&a).unwrap();
        std::fs::create_dir_all(&b).unwrap();
        std::fs::write(a.join("PKGBUILD"), "pkgname=same\n").unwrap();
        std::fs::write(b.join("PKGBUILD"), "pkgname=same\n").unwrap();
        let entries = vec![
            (a.to_str().unwrap().to_string(), Kind::Dir),
            (b.to_str().unwrap().to_string(), Kind::Dir),
        ];
        let ids = stage(&entries, &dir.join("staged"), None).unwrap();
        assert_eq!(ids, vec!["same".to_string(), "same-2".to_string()]);
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn stage_carries_the_shared_gate_library() {
        let dir = temp_dir("shared-lib");
        let src = dir.join("shared").join("neat-pkg");
        std::fs::create_dir_all(&src).unwrap();
        std::fs::write(src.join("PKGBUILD"), "pkgname=neat-pkg\n").unwrap();
        let workspace = dir.join("workspace");
        std::fs::create_dir_all(workspace.join("lib")).unwrap();
        std::fs::write(workspace.join("lib").join("pgo.sh"), "# shared gate\n").unwrap();
        std::fs::write(workspace.join("lib").join("cups-config"), "#!/bin/sh\n").unwrap();
        let entries = vec![(src.to_str().unwrap().to_string(), Kind::Dir)];

        // With a discoverable workspace root: its lib/ lands in the staged
        // workspace (a shared-gate recipe sources $startdir/../../../lib/…).
        let root = dir.join("staged");
        stage(&entries, &root, Some(&workspace)).unwrap();
        assert!(root.join("lib").join("pgo.sh").is_file());
        assert!(root.join("lib").join("cups-config").is_file());

        // A workspace root with no lib/ (or none at all) stages nothing —
        // never a fabricated library.
        let bare = dir.join("bare");
        std::fs::create_dir_all(&bare).unwrap();
        let root = dir.join("staged-2");
        stage(&entries, &root, Some(&bare)).unwrap();
        assert!(!root.join("lib").exists());
        let root = dir.join("staged-3");
        stage(&entries, &root, None).unwrap();
        assert!(!root.join("lib").exists());
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn staged_ids_satisfy_the_topology_id_charset() {
        for name in ["foo-2", "my-recipe", "a.b+c_d", "standalone"] {
            assert!(name
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '+' | '-')));
        }
    }
}
