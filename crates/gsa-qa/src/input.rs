//! The checks' input surface: plain data assembled by the callers (the
//! `--qa-check` seam, the install gate, the report surface), so every check
//! is a pure function and the registry stays host-I/O-free.

use std::path::{Path, PathBuf};

use gsa_recipe::pkginfo::{read_pkginfo, version_rank, Pkginfo};
use gsa_recipe::{parse_srcinfo_rows, SrcinfoRows};

/// One workspace recipe as the QA checks see it: its id and directory plus
/// the section-tagged committed-`.SRCINFO` rows (fish `srcinfo_rows` — the
/// per-output `provides`/`conflicts` handles the swap and provides lints
/// need). Recipes without a committed `.SRCINFO` are NOT loaded (the lints'
/// input contract is the committed metadata, never a bash evaluation).
#[derive(Clone, Debug)]
pub struct QaRecipe {
    pub id: String,
    pub dir: PathBuf,
    pub rows: SrcinfoRows,
}

/// One built archive beside its recipe, with the `.PKGINFO` truth the
/// decision seam already read (rule 25(h): unreadable = `None`, never
/// probed).
#[derive(Clone, Debug)]
pub struct QaArchive {
    pub recipe_id: String,
    pub path: PathBuf,
    pub pkginfo: Option<Pkginfo>,
}

/// One installed package as the installed-DB-scope checks need it (name,
/// version, provides, depends — the `pacman -Qi`-equivalent view — plus the
/// owned-path list, the runtime file truth of rule 25(b)). The caller
/// converts its own DB reader (`gsa-install`'s `LocalDb`, or a fixture's
/// fabricated `local/` tree behind the `pacman-conf DBPath` stub) into this
/// shape; `gsa-qa` never shells to pacman.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct QaInstalled {
    pub name: String,
    pub version: String,
    pub provides: Vec<String>,
    pub depends: Vec<String>,
    /// Owned paths from the local-DB `files` list (slash-less, as pacman
    /// records them). A soname maps to its owner by basename — the
    /// `pacman -Qo` equivalent for providers that carry no soname provide
    /// (`gsa-install::gates::needed_misses` consults the same truth; the
    /// vocabulary is mirrored here rather than imported because
    /// `gsa-install` depends on `gsa-qa`, not the other way round).
    pub files: Vec<String>,
}

/// What one check run inspects.
pub struct QaInput<'a> {
    /// The workspace recipes — the CONTEXT every workspace-wide set is
    /// computed over (all output names, every versioned constraint, the
    /// provider search).
    pub recipes: &'a [QaRecipe],
    /// Emit filter: a check reports only on recipes whose id is listed here;
    /// empty = the whole input. Context stays workspace-wide (above).
    pub targets: &'a [String],
    /// The archives under inspection (the run's archive sets; the install
    /// seam's candidates). Empty for recipe-scope runs.
    pub archives: &'a [QaArchive],
    /// The installed database view (empty = nothing installed is known).
    pub installed: &'a [QaInstalled],
    /// `config/abi-exclusions.conf` ids (rule 25(f)).
    pub exclusions: &'a [String],
}

impl QaInput<'_> {
    /// Should this recipe's findings be reported (the `targets` filter)?
    pub fn wanted(&self, recipe_id: &str) -> bool {
        self.targets.is_empty() || self.targets.iter().any(|t| t == recipe_id)
    }

    /// The loaded recipe with this id.
    pub fn recipe(&self, id: &str) -> Option<&QaRecipe> {
        self.recipes.iter().find(|r| r.id == id)
    }
}

/// A loaded workspace (recipes with committed `.SRCINFO` + the exclusions
/// registry).
pub struct Workspace {
    pub recipes: Vec<QaRecipe>,
    pub exclusions: Vec<String>,
}

/// Load the QA view of a workspace: every topology recipe with a committed
/// `.SRCINFO` (parsed section-tagged) plus `config/abi-exclusions.conf`'s
/// ids. A malformed `.SRCINFO` or exclusions entry is an error naming the
/// file (the strict-loader contract, `docs/architecture.md`).
pub fn load_workspace(root: &Path) -> Result<Workspace, String> {
    let project = gsa_topo::load_project(root).map_err(|e| format!("config: {e}"))?;
    let mut recipes = Vec::new();
    for record in &project.topology.records {
        let dir = root.join(&record.path);
        let srcinfo = dir.join(".SRCINFO");
        let Ok(content) = std::fs::read_to_string(&srcinfo) else {
            continue;
        };
        let rows =
            parse_srcinfo_rows(&content, &srcinfo.to_string_lossy()).map_err(|e| e.to_string())?;
        recipes.push(QaRecipe {
            id: record.id.as_str().to_string(),
            dir,
            rows,
        });
    }
    Ok(Workspace {
        recipes,
        exclusions: project
            .abi_exclusions
            .iter()
            .map(|entry| entry.id.clone())
            .collect(),
    })
}

/// Collect the built archives to probe for the target recipes (or every
/// loaded recipe when `targets` is empty): the newest archive per expected
/// output name, matched by the archive's own `.PKGINFO` truth (rule 11 —
/// never a glob-all fallback), and only for COMPLETE sets (fish
/// `list_split_pkgs`: a partial set is excluded entirely — a subset is never
/// probed). The install-run report surface enumerates only the run's recipes
/// (bounded cost); the full-workspace probe is the `--qa-check` seam's job.
pub fn collect_archives(recipes: &[QaRecipe], targets: &[String]) -> Vec<QaArchive> {
    let mut out = Vec::new();
    for recipe in recipes {
        if !targets.is_empty() && !targets.iter().any(|t| t == &recipe.id) {
            continue;
        }
        let expected = recipe.rows.outputs();
        let mut by_name: Vec<(String, std::time::SystemTime, PathBuf, Pkginfo)> = Vec::new();
        let Ok(entries) = std::fs::read_dir(&recipe.dir) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if !path.is_file() {
                continue;
            }
            let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
                continue;
            };
            if !name.ends_with(".pkg.tar.zst") {
                continue;
            }
            let Ok(pkginfo) = read_pkginfo(&path) else {
                continue;
            };
            if !expected.is_empty() && !expected.contains(&pkginfo.pkgname) {
                continue;
            }
            let mtime = std::fs::metadata(&path)
                .and_then(|m| m.modified())
                .unwrap_or(std::time::UNIX_EPOCH);
            by_name.push((pkginfo.pkgname.clone(), mtime, path, pkginfo));
        }
        // Version-ranked, the same order install discovery uses (the
        // wrong-skip fix): `vercmp` decides, version ties break to the
        // newest mtime, and pairs `vercmp` cannot rank keep the mtime order
        // — never string order. The mtime presort keeps ties deterministic.
        by_name.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.2.cmp(&b.2)));
        by_name.sort_by(|a, b| version_rank(&a.3.version, &b.3.version));
        // Complete set only: every expected name must answer (a recipe with
        // no expectations at all takes whatever is readable).
        if !expected.is_empty() {
            let complete = expected
                .iter()
                .all(|want| by_name.iter().any(|(name, ..)| name == want));
            if !complete {
                continue;
            }
        }
        for want in &expected {
            let best = by_name.iter().find(|(name, ..)| name == want);
            if let Some((_, _, path, pkginfo)) = best {
                out.push(QaArchive {
                    recipe_id: recipe.id.clone(),
                    path: path.clone(),
                    pkginfo: Some(pkginfo.clone()),
                });
            }
        }
        if expected.is_empty() {
            by_name.sort_by(|a, b| a.0.cmp(&b.0));
            for (.., path, pkginfo) in by_name {
                out.push(QaArchive {
                    recipe_id: recipe.id.clone(),
                    path,
                    pkginfo: Some(pkginfo),
                });
            }
        }
    }
    out
}
