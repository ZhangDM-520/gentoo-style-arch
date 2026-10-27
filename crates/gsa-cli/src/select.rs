//! Selection semantics (contract §C): reference resolution, groups/sets,
//! consumer expansion, and index ranges.
//!
//! Exact lookup only — a typo is NEVER auto-corrected. A case-variant id and
//! a pacman package name (split outputs included) DO resolve, and the
//! substitution is announced; anything else is a usage error naming the
//! unknown reference and its nearest candidates.

use std::collections::BTreeSet;

use gsa_graph::Graph;
use gsa_model::RecipeId;
use gsa_recipe::RecipeDb;
use gsa_topo::ProjectConfig;

/// Everything selection needs: the loaded config, the validated graph, the
/// recipe cache, and the kv user sets (I5 — `@name` resolves over the kv
/// `-Ms` write side ∪ the committed `config/sets/`).
pub struct Ctx<'a> {
    pub project: &'a ProjectConfig,
    pub graph: &'a Graph<'a>,
    pub db: &'a RecipeDb,
    pub user_sets: Vec<(String, Vec<String>)>,
}

/// The kv user sets of the run's state root (the `-Ms` write side): one
/// `(name, members)` per `set:<name>` key. I5's second half of `@name`
/// resolution — a set named only in kv was invisible to selections before.
/// A kv read that fails resolves to the empty half (config sets still
/// resolve) and never fails a selection.
pub fn load_user_sets(inv: &crate::args::Invocation) -> Vec<(String, Vec<String>)> {
    let Ok(state) = gsa_model::config::resolve_state_dir(inv.state_dir.as_deref()) else {
        return Vec::new();
    };
    // Read-only handle: loading user sets is a pure read (§D.1 "touches
    // nothing else") — a dry or refused run must never create `index/`,
    // `runs/`, `kv/` just to learn a set is empty.
    let root = gsa_state::StateRoot::open_readonly(&state);
    let Ok((pairs, _corrupt)) = gsa_state::Kv::list(&root) else {
        return Vec::new();
    };
    pairs
        .into_iter()
        .filter_map(|(key, value)| {
            let name = key.strip_prefix("set:")?.to_string();
            let members = value
                .split_whitespace()
                .map(|token| token.to_string())
                .collect();
            Some((name, members))
        })
        .collect()
}

/// A selection refusal (usage class, contract §G.1).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SelectError {
    pub message: String,
}

impl SelectError {
    pub fn new(message: impl Into<String>) -> Self {
        SelectError {
            message: message.into(),
        }
    }
}

impl std::fmt::Display for SelectError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for SelectError {}

/// A resolved selection: the ordered listing a range addresses.
#[derive(Clone, Debug)]
pub struct Selection {
    /// `(anchor, recipe)` in canonical build order; anchors are 1-based
    /// positions in the unfiltered closure and survive filtering with gaps.
    pub listed: Vec<(usize, RecipeId)>,
    /// Size of the closure before range filtering.
    pub closure_size: usize,
    /// The seed recipes the targets resolved to (deduplicated).
    pub seeds: Vec<RecipeId>,
    /// Announced substitutions (case-variant ids, package names), for stderr.
    pub notes: Vec<String>,
}

/// One parsed index range (`N..M`, `N..`, `..M`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct RangeSpec {
    pub start: Option<u32>,
    pub end: Option<u32>,
}

/// Parse a range token. `..` splits it; each side is digits or empty, and at
/// least one side must carry an index.
pub fn parse_range(token: &str) -> Result<RangeSpec, SelectError> {
    let parts: Vec<&str> = token.split("..").collect();
    if parts.len() != 2 {
        return Err(SelectError::new(format!(
            "invalid range '{token}' — expected N..M, N.., or ..M (e.g. 22..38)"
        )));
    }
    let side = |s: &str| -> Result<Option<u32>, SelectError> {
        if s.is_empty() {
            return Ok(None);
        }
        if !s.chars().all(|c| c.is_ascii_digit()) {
            return Err(SelectError::new(format!(
                "invalid range '{token}' — expected N..M, N.., or ..M (e.g. 22..38)"
            )));
        }
        s.parse::<u32>()
            .map(Some)
            .map_err(|_| SelectError::new(format!("invalid range '{token}' — index out of range")))
    };
    let start = side(parts[0])?;
    let end = side(parts[1])?;
    if start.is_none() && end.is_none() {
        return Err(SelectError::new(format!(
            "invalid range '{token}' — expected N..M, N.., or ..M (e.g. 22..38)"
        )));
    }
    Ok(RangeSpec { start, end })
}

/// Damerau-free Levenshtein distance, used only to rank typo candidates.
fn edit_distance(a: &str, b: &str) -> usize {
    let a: Vec<char> = a.chars().collect();
    let b: Vec<char> = b.chars().collect();
    let mut prev: Vec<usize> = (0..=b.len()).collect();
    let mut cur = vec![0usize; b.len() + 1];
    for (i, ca) in a.iter().enumerate() {
        cur[0] = i + 1;
        for (j, cb) in b.iter().enumerate() {
            let cost = if ca == cb { 0 } else { 1 };
            cur[j + 1] = (prev[j] + cost).min(prev[j + 1] + 1).min(cur[j] + 1);
        }
        std::mem::swap(&mut prev, &mut cur);
    }
    prev[b.len()]
}

/// Nearest candidates for a reference that did not resolve: the closest
/// recipe ids, package names and `@` namespace names. Ranked, bounded, and
/// deterministic.
pub fn nearest_candidates(ctx: &Ctx<'_>, query: &str, namespace: bool) -> Vec<String> {
    let mut pool: Vec<String> = Vec::new();
    if namespace {
        for group in gsa_model::Group::ROSTER {
            pool.push(format!("@{}", group.as_str()));
        }
        for set in &ctx.project.sets {
            pool.push(format!("@{}", set.name));
        }
        for (name, _) in &ctx.user_sets {
            pool.push(format!("@{name}"));
        }
    } else {
        for record in ctx.graph.records() {
            pool.push(record.id.as_str().to_string());
        }
        for (pkgname, _) in ctx.db.pkgnames_sorted() {
            pool.push(pkgname);
        }
    }
    let lower = query.to_ascii_lowercase();
    let mut scored: Vec<(usize, String)> = pool
        .into_iter()
        .map(|candidate| {
            let distance = edit_distance(&lower, &candidate.to_ascii_lowercase());
            (distance, candidate)
        })
        .filter(|(distance, candidate)| {
            let len = query.chars().count();
            *distance <= (len / 2).max(2)
                || candidate.to_ascii_lowercase().contains(&lower)
                || lower.contains(&candidate.to_ascii_lowercase())
        })
        .collect();
    scored.sort();
    scored.dedup_by(|a, b| a.1 == b.1);
    scored.into_iter().map(|(_, c)| c).take(5).collect()
}

fn unknown_reference(ctx: &Ctx<'_>, token: &str, namespace: bool) -> SelectError {
    let candidates = nearest_candidates(ctx, token, namespace);
    if candidates.is_empty() {
        SelectError::new(format!("unknown reference '{token}'"))
    } else {
        SelectError::new(format!(
            "unknown reference '{token}' (nearest candidates: {})",
            candidates.join(", ")
        ))
    }
}

const MAX_SET_DEPTH: usize = 4;

/// Resolve one reference to seed record indices. Notes describe announced
/// substitutions (case-variant id, package name → recipe) and belong on
/// stderr so stdout stays machine-readable.
pub fn resolve_ref(
    ctx: &Ctx<'_>,
    token: &str,
    depth: usize,
) -> Result<(Vec<usize>, Vec<String>), SelectError> {
    let mut notes = Vec::new();
    if let Some(name) = token.strip_prefix('@') {
        if let Some(group) = gsa_model::Group::from_name(name) {
            let members = ctx
                .graph
                .records()
                .iter()
                .enumerate()
                .filter(|(_, r)| r.groups.contains(&group))
                .map(|(i, _)| i)
                .collect();
            return Ok((members, notes));
        }
        // I5: `@name` resolves over the kv user-sets ∪ the committed
        // `config/sets/` — a name in either half resolves, and the members
        // are the union (the two sides drift and the drift is REPORTED by
        // `-Ms`; a selection sees both halves).
        let config_set = ctx.project.set(name);
        let kv_set = ctx
            .user_sets
            .iter()
            .find(|(set_name, _)| set_name == name);
        if config_set.is_some() || kv_set.is_some() {
            if depth >= MAX_SET_DEPTH {
                return Err(SelectError::new(format!(
                    "set '@{name}' nests too deeply (possible recursion between sets)"
                )));
            }
            let mut indices = Vec::new();
            let mut seen: Vec<String> = Vec::new();
            let config_members = config_set.map(|set| set.members.clone()).unwrap_or_default();
            let kv_members = kv_set.map(|(_, members)| members.clone()).unwrap_or_default();
            for member in config_members.iter().chain(kv_members.iter()) {
                if seen.iter().any(|m| m == member) {
                    continue;
                }
                seen.push(member.clone());
                let (found, member_notes) = resolve_ref(ctx, member, depth + 1)
                    .map_err(|e| SelectError::new(format!("set '@{name}': {e}")))?;
                indices.extend(found);
                notes.extend(member_notes);
            }
            return Ok((indices, notes));
        }
        return Err(unknown_reference(ctx, token, true));
    }

    if token.contains('/') {
        let normalized = token
            .trim_end_matches('/')
            .strip_prefix("./")
            .unwrap_or(token.trim_end_matches('/'));
        if let Some(record) = ctx.graph.records().iter().find(|r| r.path == normalized) {
            return Ok((vec![ctx.graph.index_of(record.id.as_str()).unwrap()], notes));
        }
        return Err(unknown_reference(ctx, token, false));
    }

    // Exact recipe id.
    if let Some(idx) = ctx.graph.index_of(token) {
        return Ok((vec![idx], notes));
    }
    // Case-variant id: matched and announced.
    let lower = token.to_ascii_lowercase();
    let variants: Vec<usize> = ctx
        .graph
        .records()
        .iter()
        .enumerate()
        .filter(|(_, r)| r.id.as_str().to_ascii_lowercase() == lower)
        .map(|(i, _)| i)
        .collect();
    match variants.len() {
        1 => {
            let id = ctx.graph.record(variants[0]).id.as_str();
            notes.push(format!("case-variant match: '{token}' -> '{id}'"));
            return Ok((variants, notes));
        }
        n if n > 1 => {
            return Err(SelectError::new(format!(
                "ambiguous case-variant reference '{token}' (matches: {})",
                variants
                    .iter()
                    .map(|&i| ctx.graph.record(i).id.as_str())
                    .collect::<Vec<_>>()
                    .join(", ")
            )))
        }
        _ => {}
    }
    // Exact pacman package name, split outputs included: announced.
    if let Some(owners) = ctx.db.by_pkgname(token) {
        let indices: Vec<usize> = owners
            .iter()
            .filter_map(|id| ctx.graph.index_of(id.as_str()))
            .collect();
        match indices.len() {
            1 => {
                let id = ctx.graph.record(indices[0]).id.as_str();
                notes.push(format!(
                    "package name '{token}' is an output of recipe '{id}'"
                ));
                return Ok((indices, notes));
            }
            _ => {
                return Err(SelectError::new(format!(
                    "ambiguous package name '{token}' (provided by recipes: {})",
                    owners
                        .iter()
                        .map(|id| id.as_str())
                        .collect::<Vec<_>>()
                        .join(", ")
                )))
            }
        }
    }
    Err(unknown_reference(ctx, token, false))
}

/// Build the ordered selection: seeds → consumer expansion (unless leaf) →
/// canonical build order → range filtering. Anchors are 1-based positions in
/// the unfiltered closure listing, exactly what `-Sl` prints.
/// Contract §C: a selection that resolves to zero packages (e.g. a roster
/// group with no members) is a usage error, never a successful no-op. One
/// guard, two call sites: before range filtering and after it.
fn ensure_selection_nonempty(listed: &[(usize, RecipeId)]) -> Result<(), SelectError> {
    if listed.is_empty() {
        return Err(SelectError::new("selection resolved to no packages"));
    }
    Ok(())
}

pub fn build_selection(
    ctx: &Ctx<'_>,
    targets: &[String],
    ranges: &[String],
    leaf: bool,
) -> Result<Selection, SelectError> {
    if targets.is_empty() {
        return Err(SelectError::new(
            "a range requires a selection to anchor it (name a target or @group)",
        ));
    }
    let mut seeds: BTreeSet<usize> = BTreeSet::new();
    let mut notes: Vec<String> = Vec::new();
    for token in targets {
        let (indices, resolved_notes) = resolve_ref(ctx, token, 0)?;
        seeds.extend(indices);
        notes.extend(resolved_notes);
    }
    let seed_vec: Vec<usize> = seeds.into_iter().collect();
    let closure: Vec<usize> = if leaf {
        let mut s = seed_vec.clone();
        s.sort_by_key(|&i| ctx.graph.position(i));
        s
    } else {
        ctx.graph.consumer_closure(&seed_vec)
    };
    let closure_size = closure.len();
    let listed: Vec<(usize, RecipeId)> = closure
        .iter()
        .enumerate()
        .map(|(pos, &idx)| (pos + 1, ctx.graph.record(idx).id.clone()))
        .collect();

    ensure_selection_nonempty(&listed)?;

    if ranges.is_empty() {
        return Ok(Selection {
            listed,
            closure_size,
            seeds: seed_vec
                .iter()
                .map(|&i| ctx.graph.record(i).id.clone())
                .collect(),
            notes,
        });
    }

    // Range filtering over the anchors (contract §C.3).
    let total = closure_size as u32;
    let mut chosen: BTreeSet<u32> = BTreeSet::new();
    for token in ranges {
        let spec = parse_range(token)?;
        let start = spec.start.unwrap_or(1);
        let end = spec.end.unwrap_or(total);
        if start > total || end < 1 {
            return Err(SelectError::new(format!(
                "range {token} is outside the {total}-package selection (valid: 1..{total})"
            )));
        }
        if start > end {
            return Err(SelectError::new(format!(
                "range {token} is empty — the start is past the end"
            )));
        }
        let start = start.max(1);
        let end = end.min(total);
        for i in start..=end {
            chosen.insert(i);
        }
    }
    let listed: Vec<(usize, RecipeId)> = listed
        .into_iter()
        .filter(|(anchor, _)| chosen.contains(&(*anchor as u32)))
        .collect();
    ensure_selection_nonempty(&listed)?;
    Ok(Selection {
        listed,
        closure_size,
        seeds: seed_vec
            .iter()
            .map(|&i| ctx.graph.record(i).id.clone())
            .collect(),
        notes,
    })
}

/// The whole-set listing (`-Sl` with no selection): every recipe in
/// canonical build order, anchors 1..=N.
pub fn whole_set_listing(ctx: &Ctx<'_>) -> Vec<(usize, RecipeId)> {
    ctx.graph
        .order()
        .iter()
        .enumerate()
        .map(|(pos, &idx)| (pos + 1, ctx.graph.record(idx).id.clone()))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ranges_parse_and_refuse_malformed_shapes() {
        assert_eq!(
            parse_range("22..38").unwrap(),
            RangeSpec {
                start: Some(22),
                end: Some(38)
            }
        );
        assert_eq!(
            parse_range("22..").unwrap(),
            RangeSpec {
                start: Some(22),
                end: None
            }
        );
        assert_eq!(
            parse_range("..15").unwrap(),
            RangeSpec {
                start: None,
                end: Some(15)
            }
        );
        for bad in ["..", "22...38", "a..b", "22", "22..38x", "1..2..3"] {
            assert!(parse_range(bad).is_err(), "{bad} must be refused");
        }
    }

    #[test]
    fn edit_distance_ranks_typos() {
        assert_eq!(edit_distance("mesa", "mesa"), 0);
        assert_eq!(edit_distance("mesa", "mesa-git"), 4);
        assert_eq!(edit_distance("kitten", "sitting"), 3);
    }

    #[test]
    fn empty_selection_is_refused() {
        // Contract §C: zero-resolved selections are usage errors. Pinned on
        // the guard, not on a real group's membership (rule 25(j): a group can
        // gain members and must not break this).
        let err = ensure_selection_nonempty(&[]).unwrap_err();
        assert_eq!(err.to_string(), "selection resolved to no packages");
        assert!(ensure_selection_nonempty(&[(1, RecipeId::new("zstd-git").unwrap())]).is_ok());
    }
}
