//! World and named sets (`gsa -Ms`/`gsa -Mw`, contract §B.7/§C.2,
//! plan-native-pm.md §5.1 `world`/`sets`): the explicitly-wanted set and the
//! user sets live in the side-car kv store (`world`, `set:<name>` — the
//! schema-ready tenants of `kv/kv.jsonl`); `config/sets/` stays the
//! committed, read-only source. The two are reconciled and DRIFT IS
//! REPORTED; nothing here ever rewrites `config/`.
//!
//! Computed sets are listed but never editable (`@preserved-rebuild`,
//! `@stale`, `@live-rebuild`, §B.7):
//!
//! - `@live-rebuild` is the `git` group (plan-native-pm.md §5.1).
//! - `@stale` is the stale-set query scoped to what the side-car knows:
//!   recipes whose newest recorded built instance version differs from the
//!   committed `.SRCINFO` version. Provider/upstream queries belong to the
//!   version-sync phase, which is not landed — the rows say so and never
//!   approximate a live answer.
//! - `@preserved-rebuild` needs the preserved-lib registry (the ABI phase);
//!   it lists as computed with `unavailable` until that registry lands.

use std::collections::BTreeSet;

use gsa_state::{BinpkgIndex, Kv, StateRoot};

use crate::{protect, MaintCtx, Row};

/// The kv key of the world set.
pub const WORLD_KEY: &str = "world";

/// The computed set names (§B.7), without their `@`.
pub const COMPUTED_SETS: [&str; 3] = ["preserved-rebuild", "stale", "live-rebuild"];

/// The kv key of one user set.
pub fn set_key(name: &str) -> String {
    format!("set:{name}")
}

/// Is this the name of a computed set? `@` optional.
pub fn is_computed(name: &str) -> bool {
    let bare = name.strip_prefix('@').unwrap_or(name);
    COMPUTED_SETS.contains(&bare)
}

/// Normalize a set name: bare, `@`-prefixed accepted; validated against the
/// `config/sets/` id character class. A computed name is NOT a user set.
pub fn user_set_name(name: &str) -> Result<String, String> {
    let bare = name.strip_prefix('@').unwrap_or(name);
    if is_computed(bare) {
        return Err(format!(
            "'{name}' is a computed set — listed, never edited (contract §B.7)"
        ));
    }
    if bare.is_empty()
        || !bare
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '+' | '-'))
    {
        return Err(format!(
            "invalid set name '{name}' (allowed: A-Za-z0-9._+-)"
        ));
    }
    Ok(bare.to_string())
}

/// One key's members (whitespace-split, deduplicated, in file order).
pub fn kv_members(state: &StateRoot, key: &str) -> Result<Vec<String>, String> {
    let value = Kv::get(state, key).map_err(|e| e.to_string())?;
    let mut members: Vec<String> = Vec::new();
    for token in value.unwrap_or_default().split_whitespace() {
        if !members.iter().any(|m| m == token) {
            members.push(token.to_string());
        }
    }
    Ok(members)
}

fn write_members(
    state: &StateRoot,
    key: &str,
    members: &[String],
    err: &mut dyn std::io::Write,
) -> Result<(), String> {
    if members.is_empty() {
        Kv::delete(state, key, err).map_err(|e| e.to_string())
    } else {
        Kv::set(state, key, &members.join(" "), err).map_err(|e| e.to_string())
    }
}

/// The §C.1 exact-lookup subset this module needs for drift detection: a
/// recipe id, a case-variant id, a recipe path, or a pacman `pkgname`
/// (split outputs included). A typo resolves to nothing here — unknown
/// references are REPORTED as drift rows; the usage-error surface with
/// nearest candidates stays the CLI's selection layer.
pub fn resolve_exact(ctx: &MaintCtx<'_>, ref_: &str) -> Option<String> {
    for record in ctx.graph.records() {
        if record.id.as_str() == ref_ {
            return Some(record.id.as_str().to_string());
        }
    }
    for record in ctx.graph.records() {
        if record.id.as_str().eq_ignore_ascii_case(ref_) {
            return Some(record.id.as_str().to_string());
        }
    }
    for record in ctx.graph.records() {
        if ctx.root.join(&record.path) == std::path::Path::new(ref_) {
            return Some(record.id.as_str().to_string());
        }
    }
    if let Some(ids) = ctx.db.by_pkgname(ref_) {
        if let Some(id) = ids.first() {
            return Some(id.as_str().to_string());
        }
    }
    None
}

/// The `@`-namespace drift rows for one set: members only in the committed
/// `config/sets/` file, only in the state copy, or resolving to nothing.
fn drift_rows(
    ctx: &MaintCtx<'_>,
    name: &str,
    config_members: &[String],
    state_members: &[String],
) -> Vec<Row> {
    let mut rows = Vec::new();
    let resolve = |members: &[String]| -> Vec<String> {
        members
            .iter()
            .map(|m| resolve_exact(ctx, m).unwrap_or_else(|| m.clone()))
            .collect()
    };
    let config_ids = resolve(config_members);
    let state_ids = resolve(state_members);
    for (raw, id) in config_members.iter().zip(config_ids.iter()) {
        if resolve_exact(ctx, raw).is_none() {
            rows.push(Row::new(name, "drift", format!("unknown-ref {raw}")));
        } else if !state_ids.contains(id) {
            rows.push(Row::new(name, "drift", format!("only-in-config {raw}")));
        }
    }
    for (raw, id) in state_members.iter().zip(state_ids.iter()) {
        if resolve_exact(ctx, raw).is_none() {
            rows.push(Row::new(name, "drift", format!("unknown-ref {raw}")));
        } else if !config_ids.contains(id) {
            rows.push(Row::new(name, "drift", format!("only-in-state {raw}")));
        }
    }
    rows
}

/// The committed members of one `config/sets/<name>` file, if any (the
/// repo-side source, read-only here).
fn config_members(ctx: &MaintCtx<'_>, name: &str) -> Option<Vec<String>> {
    ctx.project.set(name).map(|set| set.members.clone())
}

/// `-Mw` default: the world listing with its drift rows.
/// `world user <N> member(s)`, `world member <id>`, `world drift …`.
pub fn world_rows(ctx: &MaintCtx<'_>, state: &StateRoot) -> Result<Vec<Row>, String> {
    let members = kv_members(state, WORLD_KEY)?;
    let mut rows = vec![Row::new(
        "world",
        "user",
        format!("{} member(s)", members.len()),
    )];
    for member in &members {
        rows.push(Row::new("world", "member", member));
    }
    rows.extend(drift_rows(ctx, "world", &[], &members));
    Ok(rows)
}

/// `-Mw --add/--remove` (remove = deselect): edit the kv world copy. Every
/// ref arrives resolved to a recipe id from the CLI's selection layer; the
/// edit is idempotent (`present`/`absent` rows, nothing written). `apply ==
/// false` is the dry-run plan.
pub fn edit_world(
    ctx: &MaintCtx<'_>,
    state: &StateRoot,
    add: &[String],
    remove: &[String],
    apply: bool,
) -> Result<Vec<Row>, String> {
    edit_members(ctx, state, WORLD_KEY, "world", add, remove, apply)
}

/// The shared edit path for world and one user set.
fn edit_members(
    _ctx: &MaintCtx<'_>,
    state: &StateRoot,
    key: &str,
    subject: &str,
    add: &[String],
    remove: &[String],
    apply: bool,
) -> Result<Vec<Row>, String> {
    let mut members = kv_members(state, key)?;
    let mut rows = Vec::new();
    for id in add {
        if members.iter().any(|m| m == id) {
            rows.push(Row::new(subject, "present", id));
        } else {
            members.push(id.clone());
            rows.push(Row::new(subject, if apply { "added" } else { "add" }, id));
        }
    }
    for id in remove {
        if members.iter().any(|m| m == id) {
            members.retain(|m| m != id);
            rows.push(Row::new(
                subject,
                if apply { "removed" } else { "remove" },
                id,
            ));
        } else {
            rows.push(Row::new(subject, "absent", id));
        }
    }
    if apply
        && rows
            .iter()
            .any(|r| matches!(r.action.as_str(), "added" | "removed"))
    {
        let mut err = Vec::new();
        write_members(state, key, &members, &mut err)?;
    }
    Ok(rows)
}

/// `-Ms` default: the named sets (or every set when `names` is empty) with
/// members and drift; computed sets always listed with their scoped
/// membership. Rows: `<name> user|computed <N> member(s)`, `<name> member
/// …`, `<name> drift …`.
pub fn set_rows(
    ctx: &MaintCtx<'_>,
    state: &StateRoot,
    names: &[String],
) -> Result<Vec<Row>, String> {
    let wanted: Vec<String> = if names.is_empty() {
        let mut all: BTreeSet<String> = ctx.project.sets.iter().map(|s| s.name.clone()).collect();
        if let Ok((pairs, _)) = Kv::list(state) {
            for (key, _) in pairs {
                if let Some(name) = key.strip_prefix("set:") {
                    all.insert(name.to_string());
                }
            }
        }
        for name in COMPUTED_SETS {
            all.insert(name.to_string());
        }
        all.into_iter().collect()
    } else {
        let mut out = Vec::new();
        for name in names {
            let bare = name.strip_prefix('@').unwrap_or(name).to_string();
            if is_computed(&bare) || config_members(ctx, &bare).is_some() {
                out.push(bare);
            } else {
                match user_set_name(&bare) {
                    Ok(name) => out.push(name),
                    Err(error) => return Err(error),
                }
            }
        }
        out
    };

    let mut rows = Vec::new();
    for name in wanted {
        if is_computed(&name) {
            rows.extend(computed_rows(ctx, state, &name)?);
            continue;
        }
        let state_members = kv_members(state, &set_key(&name))?;
        let config = config_members(ctx, &name).unwrap_or_default();
        rows.push(Row::new(
            &name,
            "user",
            format!("{} member(s)", state_members.len()),
        ));
        for member in &state_members {
            rows.push(Row::new(&name, "member", member));
        }
        rows.extend(drift_rows(ctx, &name, &config, &state_members));
    }
    Ok(rows)
}

/// `-Ms --add/--remove` for exactly one user set (the refs arrive resolved).
pub fn edit_set(
    ctx: &MaintCtx<'_>,
    state: &StateRoot,
    name: &str,
    add: &[String],
    remove: &[String],
    apply: bool,
) -> Result<Vec<Row>, String> {
    let name = user_set_name(name)?;
    edit_members(ctx, state, &set_key(&name), &name, add, remove, apply)
}

/// One computed set's listing rows (§B.7: listed, never editable).
fn computed_rows(ctx: &MaintCtx<'_>, state: &StateRoot, name: &str) -> Result<Vec<Row>, String> {
    match name {
        "live-rebuild" => {
            let members: Vec<String> = ctx
                .graph
                .records()
                .iter()
                .filter(|r| r.groups.contains(&gsa_model::Group::Git))
                .map(|r| r.id.as_str().to_string())
                .collect();
            let mut rows = vec![Row::new(
                name,
                "computed",
                format!("{} member(s) the git group", members.len()),
            )];
            for member in members {
                rows.push(Row::new(name, "member", member));
            }
            Ok(rows)
        }
        "stale" => {
            let index = BinpkgIndex::load(state).map_err(|e| e.to_string())?;
            let mut rows = Vec::new();
            let mut count = 0;
            for record in ctx.graph.records() {
                let id = record.id.as_str();
                let Some(built) = index.rows_for(id).first().map(|row| row.version.clone()) else {
                    continue;
                };
                let Some(committed) = ctx.committed_version(id) else {
                    continue;
                };
                if built != committed {
                    count += 1;
                    rows.push(Row::new(
                        name,
                        "member",
                        format!("{id} built={built} committed={committed}"),
                    ));
                }
            }
            let mut out = vec![
                Row::new(name, "computed", format!("{count} member(s)")),
                Row::new(
                    name,
                    "scope",
                    "side-car-records-only — provider/upstream queries land with the version-sync phase",
                ),
            ];
            out.append(&mut rows);
            Ok(out)
        }
        "preserved-rebuild" => Ok(vec![Row::new(
            name,
            "computed",
            "unavailable — preserved-lib registry lands with the ABI phase (contract §J.1)",
        )]),
        _ => unreachable!("only the three computed names route here"),
    }
}

/// The pruning-safety companion: nothing here prunes, but the same rule
/// answers "is this ref still referenced by a run?" for edit callers that
/// want to warn before deselecting a package a continuation still owes.
pub fn referenced(state: &StateRoot, id: &str) -> bool {
    protect::referenced_by_run(state).contains(id)
}
