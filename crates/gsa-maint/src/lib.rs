//! `gsa-maint` — the `-M` maintain surface (contract §B.7; plan-native-pm.md
//! §5.1's `maintain`/`logs`/`clean` verbs, plan-gentoo-qol.md shortlist 6/7).
//! Report/repair over engine state and sets: the audit report (`-Ma`), the
//! doctor (`-Md`), the IgnorePkg closure repair (`-Mi`), log browse/retention
//! (`-Ml`), shared-source mirrors (`-Mm`), the three prune strengths
//! (`-Mc`/`-Mcc`/`-Mccc`), named sets and world (`-Ms`/`-Mw`), and run
//! history (`-Mh`).
//!
//! Scope fences, normative for every verb in this crate:
//!
//! - **Side-car self-healing only.** Repairs touch the state root, the
//!   documented `IgnorePkg` closure of a target `pacman.conf`, and the
//!   prune strengths' own workspace targets — never `/usr`, never
//!   `/var/lib/pacman`, never a file outside those surfaces.
//! - **Records over live queries.** Version-sync and VCS-freshness machinery
//!   is not landed yet; verbs that would answer "what moved upstream?" are
//!   scoped to what the side-car and the committed records already know and
//!   say so in their rows (`version-sync unavailable`), never a silent
//!   approximation.
//! - **Pruning is referent-guarded** ([`protect`]): an IgnorePkg entry in use
//!   and an archive referenced by a run are never pruned — they earn `keep`
//!   rows instead.
//! - **The engine never prompts.** The confirmation-gated verbs (`-Mm`,
//!   `-Mccc`) print their target list and stop (rc 3
//!   `confirmation-required`) unless `--noconfirm` says go; `--dry-run`
//!   renders the plan and mutates nothing.
//!
//! Row grammar is §E.2's: `<subject> <action> <reason…>`, full rows, reason
//! as the remainder of the line. rc classes are §G.1's: 0 done/reported
//! (findings never change rc — §E.4), 2 usage, 3 refusal (confirmation,
//! run-in-flight, failed write).

pub mod audit;
pub mod doctor;
pub mod history;
pub mod hygiene;
pub mod ignorepkg;
pub mod mirrors;
pub mod protect;
pub mod prune;
pub mod sets;

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use gsa_graph::Graph;
use gsa_recipe::RecipeDb;
use gsa_state::StateRoot;
use gsa_topo::ProjectConfig;

/// Success: the verb reported or applied exactly what was asked (§G.1).
pub const RC_OK: i32 = 0;
/// Usage error: bad flags/values, unknown references (with candidates),
/// unknown run id, an edit aimed at a computed set (§G.1).
pub const RC_USAGE: i32 = 2;
/// Refusal: confirmation missing, a run holds the state root's run lock, or
/// a write/repair failed closed (§G.1).
pub const RC_REFUSAL: i32 = 3;

/// One maintain row: `<subject> <action> <reason…>` (contract §E.2 — the
/// reason is the remainder of the line; rows are full, never
/// exceptions-only).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Row {
    pub subject: String,
    pub action: String,
    pub reason: String,
}

impl Row {
    pub fn new(
        subject: impl Into<String>,
        action: impl Into<String>,
        reason: impl Into<String>,
    ) -> Row {
        Row {
            subject: subject.into(),
            action: action.into(),
            reason: reason.into(),
        }
    }

    /// Render one row. An empty reason drops its leading space (the row is
    /// still two fields, never a trailing blank).
    pub fn render(&self) -> String {
        if self.reason.is_empty() {
            format!("{} {}", self.subject, self.action)
        } else {
            format!("{} {} {}", self.subject, self.action, self.reason)
        }
    }
}

/// Render rows, one per line.
pub fn render_rows(rows: &[Row]) -> String {
    let mut out = String::new();
    for row in rows {
        out.push_str(&row.render());
        out.push('\n');
    }
    out
}

/// Everything a maintain verb reads: the recipe repository (strict-loaded),
/// and the state root the surface is acting on (§J.3's override resolved by
/// the caller — flag beats `GSA_STATE_DIR` beats `/var/lib/gsa`).
pub struct MaintCtx<'a> {
    pub root: &'a Path,
    pub project: &'a ProjectConfig,
    pub graph: &'a Graph<'a>,
    pub db: &'a RecipeDb,
    pub state: &'a StateRoot,
}

impl MaintCtx<'_> {
    /// Every topology record's recipe directory, in topology order.
    pub fn recipe_dirs(&self) -> Vec<(String, PathBuf)> {
        self.graph
            .records()
            .iter()
            .map(|record| (record.id.as_str().to_string(), self.root.join(&record.path)))
            .collect()
    }

    /// The declared name universe (`pkgbase` + `pkgname`s, one list per
    /// recipe id) from the committed metadata — the authority ladder's
    /// second rung (`gsa-recipe` parse, never a PKGBUILD evaluation).
    pub fn declared_names(&self) -> BTreeMap<String, Vec<String>> {
        let mut out = BTreeMap::new();
        for record in self.graph.records() {
            let id = record.id.as_str();
            let Some(meta) = self.db.get(id) else {
                continue;
            };
            let mut names: Vec<String> = Vec::new();
            if let Some(info) = &meta.srcinfo {
                if let Some(base) = &info.pkgbase {
                    names.push(base.clone());
                }
                for name in &info.pkgnames {
                    if !names.contains(name) {
                        names.push(name.clone());
                    }
                }
            }
            if names.is_empty() {
                names = meta.pkgnames();
            }
            out.insert(id.to_string(), names);
        }
        out
    }

    /// The version of one recipe as the committed metadata states it
    /// (`epoch:pkgver-pkgrel`), for the stale-set skew rows.
    pub fn committed_version(&self, id: &str) -> Option<String> {
        self.db.get(id).and_then(|meta| meta.full_version().ok())
    }
}

/// Rule 11's truth filter for a shared-home archive entry: which recipe
/// does this archive belong to? The index row's `recipe_id` first
/// (authoritative — rows record archive paths wherever they live), else
/// the archive's own `.PKGINFO` names against the committed declared-name
/// universe. `None` = provably nobody's — such an entry is never deleted
/// and never reindexed under a wrong id.
pub(crate) fn archive_owner(
    index: &gsa_state::BinpkgIndex,
    declared: &BTreeMap<String, Vec<String>>,
    path: &Path,
) -> Option<String> {
    if let Some(row) = index.find_archive(path) {
        return Some(row.recipe_id.clone());
    }
    let info = gsa_recipe::pkginfo::read_pkginfo(path).ok()?;
    declared
        .iter()
        .find(|(_, names)| names.iter().any(|n| *n == info.pkgbase || *n == info.pkgname))
        .map(|(id, _)| id.clone())
}

/// The confirmation gate shared by `-Mm` and `-Mccc` (contract §B.8:
/// `--noconfirm` applies to the engine's own confirmations). The engine
/// never prompts (§K.3): without `--noconfirm` the caller prints its target
/// rows and stops with [`RC_REFUSAL`] and this reason; `--dry-run` renders
/// the same rows and answers [`RC_OK`].
pub const CONFIRMATION_REQUIRED: &str =
    "confirmation-required — re-run with --noconfirm to apply, or --dry-run to render only";

/// A mutating maintain verb's run-lock gate (contract §K.3's "one engine run
/// over a state root"): hold the returned lock for the verb's duration. A
/// busy lock is `run-in-flight` — an archive a run is currently using is
/// never pruned (§J.4's guard seen from the maintain side).
pub fn hold_run_lock(state: &Path) -> Result<gsa_sched::lock::RunLock, String> {
    gsa_sched::lock::acquire_run_lock(state).map_err(|e| format!("run-in-flight: {e}"))
}
