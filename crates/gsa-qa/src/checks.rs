//! The checks. The five audit lints are native ports of `lib/audit.fish`'s
//! report-only lints (semantics preserved: same predicates, same finding
//! text, same `sort -u` dedup; the finding FRAMING is normalized to
//! `<check>: <subject>: <detail>`), implemented over committed `.SRCINFO`
//! rows, archive `.PKGINFO`/ELF reads and the installed-DB view — a PKGBUILD
//! is never evaluated. The sixth check is the registry's install-refusing
//! example (`stale-ignorepkg`).
//!
//! Every check is a pure function over [`QaInput`]: workspace-wide context
//! comes from `input.recipes`, emitted findings are limited to
//! `input.targets` (the run's/selection's recipes; empty = everything).

use crate::abi;
use crate::input::QaInput;
use crate::CheckResult;

/// Host-purged tools that must not re-enter through `makedepends`/
/// `checkdepends` (makepkg reinstalls them silently) — the fish lint's
/// denylist verbatim (`lib/audit.fish:706`, `docs/MEMORY.md` rule 8).
const PURGED_TOOLS: &[&str] = &[
    "po4a",
    "python-sphinx",
    "python-myst-parser",
    "lvm2",
    "libblockdev-lvm",
    "systemd-tests",
    "cuda",
    "gcc15",
];

/// `provides-versioning` (recipe scope; port of `audit_lint_provides`,
/// `lib/audit.fish:572-702`). The Q8 mapping scope is SONAME + NAME with
/// opposite forms: SONAME provides are BARE stems only (makepkg auto-versions
/// a bare stem from the built ELF; a hand-pinned one only rots); a NAME
/// provide is VERSIONED wherever the recipe maps a stock name (swaps it,
/// conflicts it, is its stock counterpart, or compat-maps an output name —
/// an output name of any workspace recipe) or wherever some workspace
/// consumer version-constrains it: an unversioned provide cannot satisfy
/// `>=N`, so pacman silently falls back to the repo package. A capability
/// virtual and a package providing its own name carry no routing weight and
/// stay unversioned.
pub fn provides_versioning(input: &QaInput<'_>) -> CheckResult {
    let mut result = CheckResult::clean();

    // Workspace context (the fish `mapping`/`output_names`/`recipe_outputs`/
    // `constraints` sets): every output name is the compat-map registry, and
    // a versioned dependency anywhere is a constraint on the name.
    let mut mapping: Vec<(String, String)> = Vec::new();
    let mut output_names: Vec<String> = Vec::new();
    let mut recipe_outputs: Vec<(String, String)> = Vec::new();
    let mut constraints: Vec<(String, String, String, String)> = Vec::new();
    for recipe in input.recipes {
        for name in recipe.rows.outputs() {
            output_names.push(name.clone());
            recipe_outputs.push((recipe.id.clone(), name.clone()));
            let stock = abi::stock_name(&name);
            if stock != name {
                mapping.push((recipe.id.clone(), stock));
            }
        }
        for (_, value) in &recipe.rows.conflicts {
            if value.is_empty() {
                continue;
            }
            mapping.push((recipe.id.clone(), abi::provide_name(value).to_string()));
        }
        for (_, _, value) in &recipe.rows.deps {
            if value.is_empty() {
                continue;
            }
            // optdepends carry a `: description` suffix; names never do.
            let value = value.split(':').next().unwrap_or("").trim();
            if let Some((name, op, ver)) = abi::split_constraint(value) {
                constraints.push((
                    name.to_string(),
                    op.to_string(),
                    ver.to_string(),
                    recipe.id.clone(),
                ));
            }
        }
    }

    for recipe in input.recipes {
        if !input.wanted(&recipe.id) {
            continue;
        }
        let outputs = recipe.rows.outputs();
        for (handle, value) in &recipe.rows.provides {
            if value.is_empty() {
                continue;
            }
            let (name, ver) = match value.split_once('=') {
                Some((n, v)) => (n, v),
                None => (value.as_str(), ""),
            };
            if name.is_empty() {
                continue;
            }
            // SONAME side: bare stems only; soname provides never reach the
            // NAME rules below.
            if let Some(stem) = abi::soname_stem(name) {
                if name.contains(".so.") {
                    result = result.with(
                        &recipe.id,
                        format!(
                            "soname provide '{value}' names a versioned soname — declare the bare stem '{stem}'"
                        ),
                    );
                } else if !ver.is_empty() {
                    result = result.with(
                        &recipe.id,
                        format!(
                            "soname provide '{value}' is hand-versioned — declare the bare stem '{name}' and let makepkg auto-version it from the built ELF"
                        ),
                    );
                }
                continue;
            }
            // NAME side: a provide of an output name is a compat map only
            // when some CARRYING output is named differently — a package
            // providing its own name routes nothing (like a capability
            // virtual).
            let mapped = if mapping
                .iter()
                .any(|(id, mapped_name)| id == &recipe.id && mapped_name == name)
            {
                true
            } else if output_names.iter().any(|n| n == name) {
                if !handle.is_empty() {
                    handle != name
                } else {
                    outputs.iter().any(|o| o != name)
                }
            } else {
                false
            };
            if mapped {
                if ver.is_empty() {
                    result = result.with(
                        &recipe.id,
                        format!(
                            "mapped swap/compat provide '{name}' is unversioned — declare provides=('{name}=${{pkgver}}') so versioned dependents of the mapped name resolve here"
                        ),
                    );
                }
                continue;
            }
            // A versioned name-provide satisfies its own version; only an
            // UNVERSIONED provide falls back to the repo package.
            if !ver.is_empty() {
                continue;
            }
            for (c_name, op, c_ver, consumer) in &constraints {
                if c_name == name {
                    result = result.with(
                        &recipe.id,
                        format!(
                            "unversioned provide '{name}' cannot satisfy '{name}{op}{c_ver}' (required by {consumer}) — version it as provides=('{name}=${{pkgver}}')"
                        ),
                    );
                }
            }
        }
    }
    result
}

/// `purged-tools` (recipe scope; port of `audit_lint_purged`,
/// `lib/audit.fish:704-731`): host-purged tools must not re-enter through
/// `makedepends`/`checkdepends` — makepkg reinstalls them silently.
pub fn purged_tools(input: &QaInput<'_>) -> CheckResult {
    let mut result = CheckResult::clean();
    for recipe in input.recipes {
        if !input.wanted(&recipe.id) {
            continue;
        }
        for (field, _, value) in &recipe.rows.deps {
            if field != "makedepends" && field != "checkdepends" {
                continue;
            }
            if value.is_empty() {
                continue;
            }
            let value = value.split(':').next().unwrap_or("").trim();
            let name = abi::split_constraint(value)
                .map(|(name, _, _)| name)
                .unwrap_or(value);
            if PURGED_TOOLS.contains(&name) {
                result = result.with(
                    &recipe.id,
                    format!("{field} reintroduces purged tool '{name}' — remove it (docs/MEMORY.md rule 8)"),
                );
            }
        }
    }
    result
}

/// `swap-drift` (installed-DB scope; port of `audit_lint_swap`,
/// `lib/audit.fish:1102-1250`): the Stock→house swap must be COMPLETE — an
/// output with a VCS suffix must provide AND conflict its stock counterpart,
/// empty array slots are flagged outright, and the SONAME surface must
/// survive the swap: the output's bare soname provides are compared against
/// the installed stock counterpart's provides (both drift directions,
/// because a surface that MOVES turns a name swap into a soname swap).
pub fn swap_drift(input: &QaInput<'_>) -> CheckResult {
    let mut result = CheckResult::clean();
    for recipe in input.recipes {
        if !input.wanted(&recipe.id) {
            continue;
        }
        let rows = &recipe.rows;
        let section_name = |handle: &str| -> String {
            if handle.is_empty() {
                rows.pkgbase.clone().unwrap_or_default()
            } else {
                handle.to_string()
            }
        };
        // `handle|name` keys; empty entries keep their finding and never
        // enter the keys ("any version satisfies" — names only).
        let mut provide_keys: Vec<(String, String)> = Vec::new();
        let mut conflict_keys: Vec<(String, String)> = Vec::new();
        for (handle, value) in &rows.provides {
            if value.is_empty() {
                result = result.with(
                    section_name(handle),
                    "empty provides entry — declare the stock counterpart or drop the entry",
                );
            } else {
                provide_keys.push((handle.clone(), abi::provide_name(value).to_string()));
            }
        }
        for (handle, value) in &rows.conflicts {
            if value.is_empty() {
                result = result.with(
                    section_name(handle),
                    "empty conflicts entry — declare the stock counterpart or drop the entry",
                );
            } else {
                conflict_keys.push((handle.clone(), abi::provide_name(value).to_string()));
            }
        }
        // Counterpart completeness + drift candidates. A sibling output's
        // section does not count: only the pkgbase section (makepkg merges it
        // into every output) or the output's own.
        let mut drift: Vec<(String, String, Vec<String>)> = Vec::new();
        for name in &rows.pkgnames {
            let stock = abi::stock_name(name);
            if stock == *name {
                continue;
            }
            // A soname-shaped counterpart is a provide of a library, never a
            // stock package name — nothing to swap.
            if stock.contains(".so") {
                continue;
            }
            let declared = |keys: &[(String, String)]| {
                keys.iter().any(|(handle, key_name)| {
                    key_name == &stock && (handle.is_empty() || handle == name)
                })
            };
            if !declared(&provide_keys) {
                result = result.with(
                    name.clone(),
                    format!(
                        "stock counterpart '{stock}' missing from provides — declare provides=('{stock}=${{pkgver}}')"
                    ),
                );
            }
            if !declared(&conflict_keys) {
                result = result.with(
                    name.clone(),
                    format!(
                        "stock counterpart '{stock}' missing from conflicts — declare conflicts=('{stock}')"
                    ),
                );
            }
            // House side = the output's EFFECTIVE bare soname provides
            // (pkgbase section + its own — the same merge rule).
            let mut house: Vec<String> = Vec::new();
            for (handle, key_name) in &provide_keys {
                if handle.is_empty() || handle == name {
                    if let Some(stem) = abi::soname_stem(key_name) {
                        house.push(stem.to_string());
                    }
                }
            }
            house.sort();
            house.dedup();
            drift.push((name.clone(), stock, house));
        }

        // The installed side: `pacman -Qi <stock>` resolves through provides
        // to whatever carries the stock name today (stock before the swap,
        // house after it). A counterpart with NO readable provide entry is
        // not comparable and silently skips.
        for (name, stock, house) in drift {
            let Some(resolved) = resolve_installed(input, &stock) else {
                continue;
            };
            if resolved.provides.is_empty() {
                continue;
            }
            let mut stock_stems: Vec<String> =
                abi::soname_stems(resolved.provides.iter().map(|s| s.as_str()))
                    .into_iter()
                    .map(|s| s.to_string())
                    .collect();
            stock_stems.sort();
            stock_stems.dedup();
            for stem in &house {
                if !stock_stems.contains(stem) {
                    result = result.with(
                        name.clone(),
                        format!(
                            "soname drift vs installed stock '{stock}': this recipe's provides carry '{stem}' that the installed stock does not"
                        ),
                    );
                }
            }
            for stem in &stock_stems {
                if !house.contains(stem) {
                    result = result.with(
                        name.clone(),
                        format!(
                            "soname drift vs installed stock '{stock}': the installed stock carries '{stem}' that this recipe's provides drop — the swap becomes a soname swap for its installed consumers"
                        ),
                    );
                }
            }
        }
    }
    result
}

/// `abi-closure` (archive scope; port of `audit_lint_abi_closure`,
/// `lib/audit.fish:29-236`) over WORKSPACE-BUILT OUTPUTS (the archives are
/// the only place the shipped ELF surface is real). Two rules: `ship` —
/// every `DT_SONAME` an output ships needs a bare soname provide in its
/// recipe's committed `.SRCINFO`; `needed` — every `DT_NEEDED` resolves to
/// (a) a workspace provide, (b) an expected base-system soname, or (c) an
/// exclusions entry. Without built outputs the check reports `skipped`.
pub fn abi_closure(input: &QaInput<'_>) -> CheckResult {
    if input.archives.is_empty() {
        return CheckResult::skipped(
            "no workspace-built outputs (build the recipes to enable the closure probe)",
        );
    }
    let mut result = CheckResult::clean();

    // Shipped/needed rows: `(recipe, member, soname)` / `(recipe, member,
    // needed)` — the fish `readelf -dW` rows, one member read at a time. An
    // unreadable archive ships one `(unreadable)` row and NO needed rows
    // (its DT_NEEDED is never probed).
    let mut shipped: Vec<(String, String, Option<String>)> = Vec::new();
    let mut needed: Vec<(String, String, String)> = Vec::new();
    for archive in input.archives {
        match gsa_recipe::pkginfo::members_with_dynamic(&archive.path) {
            Err(_) => shipped.push((archive.recipe_id.clone(), "(unreadable)".to_string(), None)),
            Ok(members) => {
                for (member, soname, member_needs) in members {
                    if let Some(soname) = soname {
                        shipped.push((archive.recipe_id.clone(), member.clone(), Some(soname)));
                    }
                    for need in member_needs {
                        needed.push((archive.recipe_id.clone(), member.clone(), need));
                    }
                }
            }
        }
    }

    // The declared provide surface (section handles dropped — this lint
    // matches names, not sections), workspace-wide in declared order.
    let mut declared: Vec<(&str, &str, &str)> = Vec::new();
    for recipe in input.recipes {
        for (_, value) in &recipe.rows.provides {
            if value.is_empty() {
                continue;
            }
            declared.push((recipe.id.as_str(), value, abi::provide_name(value)));
        }
    }

    // Rule ship: a shipped DT_SONAME needs its bare soname provide.
    for (id, member, soname) in &shipped {
        if !input.wanted(id) {
            continue;
        }
        if abi::excluded(input.exclusions, id) {
            continue;
        }
        let Some(soname) = soname else {
            result = result.with(
                id.clone(),
                format!("cannot extract {member} — built outputs not probed"),
            );
            continue;
        };
        let Some(stem) = abi::soname_stem(soname) else {
            continue;
        };
        let covered = declared.iter().any(|(decl_id, value, decl_name)| {
            *decl_id == id
                && (*decl_name == soname || *decl_name == stem)
                && abi::provide_covers(value, soname)
        });
        if !covered {
            result = result.with(
                format!("provider {id}"),
                format!(
                    "ships {member} with soname '{soname}' but declares no bare soname provide '{stem}' — declare provides=('{stem}') and let makepkg auto-version it"
                ),
            );
        }
    }

    // Rule needed: every DT_NEEDED resolves to (a) a workspace provide,
    // (b) an expected base-system soname, or (c) an exclusions entry.
    for (id, member, soname) in &needed {
        if !input.wanted(id) {
            continue;
        }
        if abi::excluded(input.exclusions, id) {
            continue;
        }
        if abi::base_lib_ok(soname) {
            continue;
        }
        if abi::excluded(input.exclusions, soname) {
            continue;
        }
        let stem = abi::soname_stem(soname);
        let mut providers: Vec<&str> = Vec::new();
        for (decl_id, value, decl_name) in &declared {
            let name_matches = *decl_name == soname
                || match stem {
                    Some(stem) => *decl_name == stem,
                    None => false,
                };
            if name_matches && abi::provide_covers(value, soname) && !providers.contains(decl_id) {
                providers.push(decl_id);
            }
        }
        let mut resolved = false;
        let mut mismatch: Vec<String> = Vec::new();
        for pid in &providers {
            let mut has_outputs = false;
            let mut ships = false;
            let mut shipped_names: Vec<String> = Vec::new();
            for (s_id, _, s_soname) in &shipped {
                if s_id != pid {
                    continue;
                }
                has_outputs = true;
                let Some(s_soname) = s_soname else {
                    continue;
                };
                if s_soname == soname {
                    ships = true;
                }
                if abi::soname_stem(s_soname) == stem && stem.is_some() {
                    shipped_names.push(s_soname.clone());
                }
            }
            if ships || !has_outputs {
                resolved = true;
                break;
            }
            mismatch.push(format!("{pid}: {}", shipped_names.join(", ")));
        }
        if resolved {
            continue;
        }
        if !providers.is_empty() {
            result = result.with(
                format!("consumer {id} ({member})"),
                format!(
                    "needs '{soname}' but provider {} — the provider/consumer pair must move in one batch",
                    mismatch.join(" / ")
                ),
            );
        } else {
            result = result.with(
                format!("consumer {id} ({member})"),
                format!(
                    "needs '{soname}' — no workspace provider declares it, it is not an expected base-system lib, and no config/abi-exclusions.conf entry covers it"
                ),
            );
        }
    }
    result
}

/// `abi-exposure` (installed-DB scope; port of `audit_lint_abi_exposure`,
/// `lib/audit.fish:247-507`). For every workspace lib whose soname provides
/// (committed `.SRCINFO` bare stems) differ from the installed stock
/// equivalent, report the provider → exposed-consumer mapping: one row per
/// drifted provide per installed consumer whose depends reach the drift (the
/// drifted soname name or the stock name), `-> none` when nothing installed
/// depends on it. The mapping tells the maintainer who is exposed when the
/// swap lands.
pub fn abi_exposure(input: &QaInput<'_>) -> CheckResult {
    let mut result = CheckResult::clean();
    let mut compared = false;

    // Consumer index: installed depends tokens (version suffix stripped),
    // per token.
    let mut consumers: Vec<(String, String)> = Vec::new(); // (token, consumer name)
    for pkg in input.installed {
        for dep in &pkg.depends {
            let name = abi::provide_name(dep);
            if name.is_empty() || name == "None" {
                continue;
            }
            consumers.push((name.to_string(), pkg.name.clone()));
        }
    }

    for recipe in input.recipes {
        if !input.wanted(&recipe.id) {
            continue;
        }
        if abi::excluded(input.exclusions, &recipe.id) {
            continue;
        }
        let house_values: Vec<&str> = recipe
            .rows
            .provides
            .iter()
            .map(|(_, value)| value.as_str())
            .collect();
        let house_stems = abi::soname_stems(house_values.iter().copied());
        // Candidate gate: only a recipe carrying soname-shaped provides is
        // compared, and only its stock names are queried.
        if house_stems.is_empty() {
            continue;
        }
        let mut names = recipe.rows.names();
        if names.is_empty() {
            names.push(recipe.id.clone());
        }
        let mut stocks: Vec<String> = Vec::new();
        for name in &names {
            stocks.push(abi::stock_name(name));
        }
        // The installed side of each stock: every provide entry of whatever
        // carries the stock name today. `ni == 0` (no installed provide
        // entry at all) silently skips the recipe.
        let mut installed_entries: Vec<(String, String)> = Vec::new(); // (stock, provide value)
        for stock in &stocks {
            if let Some(pkg) = resolve_installed(input, stock) {
                for value in &pkg.provides {
                    installed_entries.push((stock.clone(), value.clone()));
                }
            }
        }
        if installed_entries.is_empty() {
            continue;
        }
        compared = true;

        let mut istems: Vec<String> = Vec::new();
        for (_, value) in &installed_entries {
            if let Some(stem) = abi::soname_stem(abi::provide_name(value)) {
                istems.push(stem.to_string());
            }
        }

        // Drift = the symmetric difference of the bare stem sets, one record
        // per drifted provide entry.
        let mut drifts: Vec<(&str, &str, &str, &str)> = Vec::new(); // (kind, stock, value, name)
        for (stock, value) in &installed_entries {
            let Some(stem) = abi::soname_stem(abi::provide_name(value)) else {
                continue;
            };
            if house_stems.contains(&stem) {
                continue;
            }
            drifts.push(("stock-only", stock, value, abi::provide_name(value)));
        }
        for (_, value) in &recipe.rows.provides {
            let Some(stem) = abi::soname_stem(abi::provide_name(value)) else {
                continue;
            };
            if istems.iter().any(|s| s == stem) {
                continue;
            }
            drifts.push(("house-only", &stocks[0], value, abi::provide_name(value)));
        }

        // Exposure: a drift is reached through its provide NAME or its stock
        // name; the recipe's own names are never "exposed".
        for (kind, stock, value, name) in &drifts {
            let mut hit = false;
            for key in [*name, *stock] {
                for (token, consumer) in &consumers {
                    if token != key {
                        continue;
                    }
                    if abi::excluded(input.exclusions, consumer) {
                        continue;
                    }
                    if names.contains(consumer) || *consumer == recipe.id {
                        continue;
                    }
                    hit = true;
                    result = result.with(
                        format!("{} -> {}", recipe.id, consumer),
                        drift_line(kind, stock, value, &recipe.id),
                    );
                }
            }
            if !hit {
                result = result.with(
                    format!("{} -> none", recipe.id),
                    drift_line(kind, stock, value, &recipe.id),
                );
            }
        }
    }

    if !compared {
        return CheckResult::skipped(
            "no workspace lib has an installed stock equivalent to compare against",
        );
    }
    result
}

fn drift_line(kind: &str, stock: &str, value: &str, recipe: &str) -> String {
    if kind == "stock-only" {
        format!("stock {stock} carries '{value}' but {recipe} drops it")
    } else {
        format!("{recipe} carries '{value}' that stock {stock} does not")
    }
}

/// `stale-ignorepkg` (archive scope, INSTALL-REFUSING — the registry's
/// severity-mechanism example).
///
/// Rule 9 registers each accepted archive's own `.PKGINFO` `pkgbase` +
/// `pkgname` (the FIRST name authority) into the target conf's `[options]`
/// `IgnorePkg` closure before `pacman -U`. When those names disagree with
/// the recipe's committed `.SRCINFO` name set (pkgbase + pkgnames — the
/// SECOND name authority), the archive is STALE relative to its recipe
/// (built before a pkgbase/pkgname change): the registration would add a
/// name no recipe declares — which can shadow a real stock package and
/// silently freeze it out of upgrades — while the recipe's declared names
/// stay the ones that need protecting. One `refuse stale-ignorepkg` row per
/// undeclared name.
///
/// Why `report` is insufficient (contract §E.4): reporting would still
/// install a stale artifact and poison the IgnorePkg closure with an
/// unprunable name — the exact silent-replacement class rule 9 exists to
/// prevent, so the row refuses before any pacman call. Force mode never
/// bypasses it (like the PGO/ABI gates: force bypasses only the
/// same-version skip).
///
/// The converse direction (a declared output the archive set does not ship)
/// is deliberately NOT this check: that is `partial-set`, the discovery
/// gate's fail-closed class (`gsa-install::discover_recipe`).
pub fn stale_ignorepkg(input: &QaInput<'_>) -> CheckResult {
    let mut result = CheckResult::clean();
    for archive in input.archives {
        if !input.wanted(&archive.recipe_id) {
            continue;
        }
        // Rule 25(h): an unreadable `.PKGINFO` is the discovery gate's class
        // (`skip unreadable-pkginfo` / `refuse discover-failed`), never
        // probed here.
        let Some(info) = &archive.pkginfo else {
            continue;
        };
        let Some(recipe) = input.recipe(&archive.recipe_id) else {
            continue;
        };
        let declared = recipe.rows.names();
        let mut registration = vec![info.pkgbase.clone(), info.pkgname.clone()];
        registration.sort();
        registration.dedup();
        for name in registration {
            if !declared.contains(&name) {
                result = result.with(
                    info.pkgbase.clone(),
                    format!("{} {name} not-declared", archive.path.display()),
                );
            }
        }
    }
    result
}

/// The installed package that carries a name today: the package named
/// `name`, else the first (name-ordered) package providing it — `pacman
/// -Qi <name>`'s resolution through provides (stock before the swap, house
/// after it).
fn resolve_installed<'a>(
    input: &'a QaInput<'_>,
    name: &str,
) -> Option<&'a crate::input::QaInstalled> {
    if let Some(pkg) = input.installed.iter().find(|pkg| pkg.name == name) {
        return Some(pkg);
    }
    input
        .installed
        .iter()
        .filter(|pkg| {
            pkg.provides
                .iter()
                .any(|provide| abi::provide_name(provide) == name)
        })
        .min_by_key(|pkg| pkg.name.clone())
}
