//! The installed world, as the two expansion seams read it: consumer
//! expansion in `select` and the ABI rebuild wave in `gsa-abi`.
//!
//! The one predicate (`AGENTS.md` rule 76): a recipe is in the installed
//! world when ANY of its output names is recorded in the local pacman DB.
//! A recipe installed nowhere owns no files, links through no soname and
//! can be rebuilt by nothing, so it can neither break nor be covered; it
//! must not join a consumer expansion, seed a wave, or have its build
//! prerequisites installed as a side effect.

use std::collections::BTreeSet;

use gsa_graph::Graph;
use gsa_install::localdb::LocalDb;
use gsa_recipe::RecipeDb;

use crate::args::Invocation;

/// Every output name one recipe can be installed under: its id (`pkgbase`
/// fallback), the committed `.SRCINFO` pkgbase, and its declared pkgnames.
/// The prerequisite seam and the expansion filter share this one set, so a
/// split output installed under a pkgname is never read as absent.
pub(crate) fn output_names(db: &RecipeDb, record: &gsa_model::TopologyRecord) -> Vec<String> {
    let mut names = vec![record.id.as_str().to_string()];
    if let Some(meta) = db.get(record.id.as_str()) {
        if let Some(info) = &meta.srcinfo {
            if let Some(base) = &info.pkgbase {
                names.push(base.clone());
            }
        }
        names.extend(meta.pkgnames());
    }
    names.sort();
    names.dedup();
    names
}

/// Parse the DB the transaction will read (`--config`'s DBPath). `Err` is
/// the DB itself being unreadable; unreadable ENTRIES are reported by
/// [`completeness_error`], because a listing may still answer from what it
/// could read while a build must not.
pub(crate) fn load_local(inv: &Invocation) -> Result<LocalDb, String> {
    let conf = inv.config.as_deref().map(std::path::Path::new);
    let db_root = gsa_install::localdb::pacman_db_root_for(conf)?;
    LocalDb::load(&db_root)
}

/// The unreadable-entry refusal for a seam that DECIDES on the world: a
/// consumer could be hidden in the part that could not be read, and
/// dropping it would build past a real consumer (rule 71 — unreadable is
/// never absent).
pub(crate) fn completeness_error(local: &LocalDb) -> Option<String> {
    let first = local.unreadable.first()?;
    Some(format!(
        "the installed DB has {} unreadable entr{} ({first}) — the installed world is unknown, and no consumer may be dropped from expansion on a partial read",
        local.unreadable.len(),
        if local.unreadable.len() == 1 { "y" } else { "ies" },
    ))
}

/// The recipe ids with at least one installed output. Parsed once per verb;
/// every seam in that verb reads this one answer.
pub(crate) struct InstalledWorld {
    recipes: BTreeSet<String>,
}

impl InstalledWorld {
    /// The world a work verb decides on. `Err` when the DB cannot be read
    /// or has unreadable entries (UNKNOWN world state, never an empty one).
    pub(crate) fn load(
        inv: &Invocation,
        graph: &Graph<'_>,
        db: &RecipeDb,
    ) -> Result<(Self, LocalDb), String> {
        let local = load_local(inv)?;
        if let Some(message) = completeness_error(&local) {
            return Err(message);
        }
        Ok((Self::from_db(graph, db, &local), local))
    }

    /// The derivation both seams share, for a caller that already parsed the
    /// DB (the update path's stale set, the install path's swap plan).
    pub(crate) fn from_db(graph: &Graph<'_>, db: &RecipeDb, local: &LocalDb) -> Self {
        let recipes = graph
            .records()
            .iter()
            .filter(|record| {
                output_names(db, record)
                    .iter()
                    .any(|name| local.get(name).is_some())
            })
            .map(|record| record.id.as_str().to_string())
            .collect();
        Self { recipes }
    }

    pub(crate) fn contains(&self, recipe_id: &str) -> bool {
        self.recipes.contains(recipe_id)
    }

    /// The recipe-id view the ABI planner takes: its seeds and closure name
    /// topology ids, never pacman pkgnames.
    pub(crate) fn recipe_ids(&self) -> &BTreeSet<String> {
        &self.recipes
    }
}
