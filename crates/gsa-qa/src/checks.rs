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
//! `declared-deps` is the one check that is NOT a fish port: it is the new
//! DT_NEEDED-vs-declared-deps guard (docs/MEMORY.md rule 54), added where
//! `abi-closure` cannot see — against the recipe's DECLARED depends.

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

/// `declared-deps` (archive scope): the DT_NEEDED-vs-declared-deps axis
/// (docs/MEMORY.md rule 54's guard, the 2026-10-14 orphan incident —
/// `docs/NOTE.md` "orphan-removal broke shared libs"). With `!autodeps` an
/// archive's `depends` is exactly what its PKGBUILD declares, so a lib a
/// build system auto-detects and links into the payload with no declared
/// runtime dep leaves its provider dep-installed, later orphan-flagged
/// (`pacman -Qdt`), and removable — breaking every consumer.
/// `abi-closure` cannot see this axis (its `needed` rule resolves against
/// the provide surface and is satisfied by an UNDECLARED provider); this
/// check compares the shipped ELF's `DT_NEEDED` closure against the recipe's
/// DECLARED `depends` closure. Without built outputs it reports `skipped`
/// (like `abi-closure`).
///
/// Coverage rules, one per `(member, DT_NEEDED)` row:
///
/// 1. self-shipped: a soname satisfied by bytes shipped INSIDE the same
///    archive (a `DT_SONAME` the archive ships, or a member named exactly
///    the soname) is covered — no package keeps those bytes installed but
///    the archive itself;
/// 2. otherwise the soname resolves to a provider in the first tier that
///    explains it — the precedence is workspace provide match, then the
///    installed truth, then base-system (rule 3's "no owner anywhere" is the
///    terminal): (a) bare-soname provide matching over `provide_covers`
///    (`libfoo.so.3` matches provide `libfoo.so` / `libfoo.so=3-64`)
///    against the WORKSPACE provide surface; else (b) the installed truth —
///    its provides AND its owned files (`pacman -Qo` by basename against
///    the local-DB `files` list, the same runtime file truth
///    `gsa-install::gates::needed_misses` consults), so a stock provider
///    that carries no soname provide — `libxres`, `jbigkit`, the incident
///    class — still resolves to its owner. The provider must lie inside the
///    provides-aware TRANSITIVE closure of the recipe's declared `depends`:
///    the walk follows each depends string to workspace recipes (by name —
///    including the stock↔house counterpart — or provide) and to installed
///    packages (by name or provide), recursing; a depends string resolving
///    to nothing stands in the closure as the external package name it
///    spells. A resolved provider OUTSIDE that closure is `undeclared-link`;
/// 3. a soname with no owner anywhere (no workspace provide, no installed
///    provide, no installed owned file, not base-system) is
///    `unresolvable-link` — the genuinely dangling class (kept rare and
///    meaningful by the ownership tier above). It is REPORTED, not skipped:
///    `abi-closure`'s `needed` rule reports the same class over the same
///    inputs, and silence here is exactly how the incident re-drifts (rule
///    54: a gap with no guard re-drifts). `config/abi-exclusions.conf`
///    (rule 25(f)) is the documented escape hatch, as for every sibling ABI
///    gate;
/// 4. transitive coverage COUNTS — a direct declaration is not required when
///    the depends closure keeps the provider installed. Trade-off: if an
///    intermediate package later drops the provider from its own depends,
///    the coverage silently disappears at runtime without a finding here;
///    demanding a direct declaration everywhere would duplicate the
///    dependency graph and punish correct transitive packaging, so the
///    installed-set sweep is the deliberate backstop for that drift.
///
/// Base-system sonames (the glibc + gcc-libs runtime) are covered OUTRIGHT,
/// before the provider tiers decide — measured 2026-10-14: 149 of 652
/// workspace recipes' committed `.SRCINFO` carry no `glibc` depends row, so
/// resolving `libc.so.6` to its owner and demanding closure membership
/// would manufacture `undeclared-link` rows for the runtime pacman itself
/// hard-depends on (it can never be orphan-removed). The precedence governs
/// every non-base soname. `makedepends`/`checkdepends` NEVER count — the
/// incident's exact leak shape is a payload link whose provider is declared
/// only at build time.
pub fn declared_deps(input: &QaInput<'_>) -> CheckResult {
    if input.archives.is_empty() {
        return CheckResult::skipped(
            "no workspace-built outputs (build the recipes to enable the declared-deps probe)",
        );
    }
    let mut result = CheckResult::clean();
    for archive in input.archives {
        if !input.wanted(&archive.recipe_id) {
            continue;
        }
        if abi::excluded(input.exclusions, &archive.recipe_id) {
            continue;
        }
        let Some(recipe) = input.recipe(&archive.recipe_id) else {
            continue;
        };
        // The shipped/needed rows: one member read at a time (the
        // `readelf -dW` rows). An unreadable archive ships one row and no
        // probe — same shape as `abi-closure`.
        let members = match gsa_recipe::pkginfo::members_with_dynamic(&archive.path) {
            Err(_) => {
                result = result.with(
                    &archive.recipe_id,
                    "cannot extract (unreadable) — declared depends not probed",
                );
                continue;
            }
            Ok(members) => members,
        };
        // Self-shipped surface (rule 1): every DT_SONAME the archive ships
        // plus every member basename.
        let mut shipped: Vec<String> = Vec::new();
        for (member, soname, _) in &members {
            if let Some(soname) = soname {
                shipped.push(soname.clone());
            }
            if let Some(base) = std::path::Path::new(member).file_name() {
                shipped.push(base.to_string_lossy().into_owned());
            }
        }
        let closure = declared_closure(
            input,
            recipe,
            archive.pkginfo.as_ref().map(|info| info.pkgname.as_str()),
        );
        for (member, _, needs) in &members {
            for soname in needs {
                if shipped.iter().any(|s| s == soname) {
                    continue;
                }
                if abi::base_lib_ok(soname) {
                    continue;
                }
                if abi::excluded(input.exclusions, soname) {
                    continue;
                }
                let subject = format!("consumer {} ({member})", archive.recipe_id);
                // Rule 2's precedence: the workspace provide surface is
                // consulted first, the installed truth (provides + owned
                // files) second — the first tier that explains the soname
                // decides alone.
                let mut providers = workspace_providers(input, soname);
                if providers.is_empty() {
                    providers = installed_providers(input, soname);
                }
                if providers.is_empty() {
                    let stem = abi::soname_stem(soname).unwrap_or(soname);
                    result = result.with(
                        subject,
                        format!(
                            "needs '{soname}' but no workspace provide, installed provide or installed owned file covers it and it is not an expected base-system lib — unresolvable-link: declare the provider in depends (a plain name where the provider carries no soname provide) or register '{stem}' in config/abi-exclusions.conf"
                        ),
                    );
                    continue;
                }
                // Rule 2: covered when ANY resolved provider lies inside the
                // declared closure — only a soname with no provider inside
                // reports, one row per provider outside.
                if providers.iter().any(|provider| closure.covers(provider)) {
                    continue;
                }
                for provider in &providers {
                    result = result.with(
                        subject.clone(),
                        format!(
                            "needs '{soname}' but declared depends never reach provider {} — undeclared-link: declare a depends entry that resolves to {} (transitively is enough) so the provider survives an orphan sweep",
                            provider.name(),
                            provider.name()
                        ),
                    );
                }
            }
        }
    }
    result
}

/// One package identity a soname can resolve to.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum DepProvider<'a> {
    /// A workspace recipe (its topology id).
    Workspace(&'a str),
    /// An installed package (its pacman name) — the runtime view's answer
    /// for providers outside the workspace (a repo package).
    Installed(&'a str),
}

impl DepProvider<'_> {
    fn name(&self) -> &str {
        match self {
            DepProvider::Workspace(id) => id,
            DepProvider::Installed(name) => name,
        }
    }
}

/// The provides-aware transitive closure of one recipe's declared `depends`.
struct DepClosure {
    /// Workspace recipe ids reached — a workspace provider inside is covered.
    ids: std::collections::BTreeSet<String>,
    /// Package names reached: the depends strings themselves and the
    /// installed packages they resolve to — an installed provider inside is
    /// covered.
    names: std::collections::BTreeSet<String>,
}

impl DepClosure {
    fn covers(&self, provider: &DepProvider<'_>) -> bool {
        match provider {
            DepProvider::Workspace(id) => self.ids.contains(*id),
            DepProvider::Installed(name) => self.names.contains(*name),
        }
    }
}

/// The declared-depends closure for one recipe's output: its `depends` rows
/// (a split output keeps the shared pkgbase section and its own section;
/// without `.PKGINFO` truth the whole declaration is the seed), walked
/// transitively. `makedepends`/`checkdepends`/`optdepends` never seed —
/// they keep no provider installed at runtime.
fn declared_closure(
    input: &QaInput<'_>,
    recipe: &crate::input::QaRecipe,
    output: Option<&str>,
) -> DepClosure {
    let mut closure = DepClosure {
        ids: std::collections::BTreeSet::new(),
        names: std::collections::BTreeSet::new(),
    };
    let mut queue: Vec<String> = Vec::new();
    let mut walked: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();
    let mut walked_installed: std::collections::BTreeSet<String> =
        std::collections::BTreeSet::new();
    for (field, handle, value) in &recipe.rows.deps {
        if field != "depends" || value.is_empty() {
            continue;
        }
        if !handle.is_empty() && output.is_some_and(|out| out != handle) {
            continue;
        }
        queue.push(abi::provide_name(value.trim()).to_string());
    }
    while let Some(token) = queue.pop() {
        if token.is_empty() || token == "None" || !walked.insert(token.clone()) {
            continue;
        }
        // An unresolved token stands in the closure as the external package
        // name it spells (`depends = libxres` keeps `libxres` installed).
        closure.names.insert(token.clone());
        for other in input.recipes {
            if closure.ids.contains(&other.id) {
                continue;
            }
            if token_resolves(&other.rows, &token) {
                closure.ids.insert(other.id.clone());
                for (field, _, value) in &other.rows.deps {
                    if field == "depends" && !value.is_empty() {
                        queue.push(abi::provide_name(value.trim()).to_string());
                    }
                }
            }
        }
        for pkg in input.installed {
            // Match by name/provide for EVERY token; only the depends
            // recursion is once-per-package (the cycle guard). Skipping a
            // package before matching would starve every later token's
            // resolution with the first token's scan (2026-10-15 wall:
            // `fcitx5-qt` → fcitx5-qt6-git's provide, pinned by fixture G7).
            if !token_resolves_installed(pkg, &token) {
                continue;
            }
            closure.names.insert(pkg.name.clone());
            if walked_installed.insert(pkg.name.clone()) {
                for value in &pkg.depends {
                    let name = abi::provide_name(value);
                    if !name.is_empty() && name != "None" {
                        queue.push(name.to_string());
                    }
                }
            }
        }
    }
    closure
}

/// Does a depends token name this workspace recipe — by name (including the
/// stock↔house counterpart) or by provide?
fn token_resolves(rows: &gsa_recipe::SrcinfoRows, token: &str) -> bool {
    rows.names()
        .iter()
        .any(|name| name == token || abi::stock_name(name) == token)
        || rows.provides.iter().any(|(_, value)| {
            let name = abi::provide_name(value);
            !name.is_empty() && (name == token || abi::provide_covers(value, token))
        })
}

/// Does a depends token name this installed package — by name (including
/// the stock↔house counterpart) or by provide?
fn token_resolves_installed(pkg: &crate::input::QaInstalled, token: &str) -> bool {
    pkg.name == token
        || abi::stock_name(&pkg.name) == token
        || pkg.provides.iter().any(|value| {
            let name = abi::provide_name(value);
            !name.is_empty() && (name == token || abi::provide_covers(value, token))
        })
}

/// Every package a soname resolves to on the WORKSPACE provide surface —
/// the same bare-stem / auto-versioned matcher `abi::provide_covers` owns.
/// Precedence tier 2(a): when this tier answers, the installed truth is not
/// consulted (the workspace surface is the more precise claim).
fn workspace_providers<'a>(input: &QaInput<'a>, soname: &str) -> Vec<DepProvider<'a>> {
    let stem = abi::soname_stem(soname);
    let covers = |value: &str| {
        let name = abi::provide_name(value);
        !name.is_empty()
            && (name == soname || Some(name) == stem)
            && abi::provide_covers(value, soname)
    };
    input
        .recipes
        .iter()
        .filter(|recipe| recipe.rows.provides.iter().any(|(_, value)| covers(value)))
        .map(|recipe| DepProvider::Workspace(recipe.id.as_str()))
        .collect()
}

/// Every package a soname resolves to in the INSTALLED truth — precedence
/// tier 2(b): the packages whose provides cover it, and the packages whose
/// OWNED FILES cover it (a `pacman -Qo` by basename against the local-DB
/// `files` list — the same runtime file truth
/// `gsa-install::gates::needed_misses` consults as `db.provides_cover ||
/// db.owns_file`; the vocabulary is mirrored, not imported, because
/// `gsa-install` depends on `gsa-qa` and not the other way round).
/// Ownership is what resolves stock providers carrying no soname provide
/// (`libxres`, `libayatana-indicator`, `jbigkit`) — the class provide
/// matching can never see.
fn installed_providers<'a>(input: &QaInput<'a>, soname: &str) -> Vec<DepProvider<'a>> {
    let stem = abi::soname_stem(soname);
    let covers = |value: &str| {
        let name = abi::provide_name(value);
        !name.is_empty()
            && (name == soname || Some(name) == stem)
            && abi::provide_covers(value, soname)
    };
    let owns = |value: &str| {
        let normalized = value.strip_prefix('/').unwrap_or(value);
        normalized.rsplit('/').next() == Some(soname)
    };
    input
        .installed
        .iter()
        .filter(|pkg| {
            pkg.provides.iter().any(|value| covers(value))
                || pkg.files.iter().any(|path| owns(path))
        })
        .map(|pkg| DepProvider::Installed(pkg.name.as_str()))
        .collect()
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::input::{QaArchive, QaInstalled, QaRecipe};
    use gsa_recipe::parse_srcinfo_rows;
    use std::path::{Path, PathBuf};

    fn recipe(id: &str, srcinfo: &str) -> QaRecipe {
        QaRecipe {
            id: id.to_string(),
            dir: PathBuf::from(format!("/w/{id}")),
            rows: parse_srcinfo_rows(srcinfo, "test").unwrap(),
        }
    }

    /// A minimal section-less ELF64 image (ET_DYN) carrying one DT_NEEDED
    /// per `needed` name and an optional DT_SONAME — the same layout the
    /// `gsa-recipe` elf tests and `crates/gsa-qa/tests/registry.rs` build.
    fn elf64_with(needed: &[&str], soname: Option<&str>) -> Vec<u8> {
        let mut dynstr = vec![0u8];
        let mut entries: Vec<(u64, u64)> = Vec::new();
        for name in needed {
            let off = dynstr.len() as u64;
            dynstr.extend_from_slice(name.as_bytes());
            dynstr.push(0);
            entries.push((1, off)); // DT_NEEDED
        }
        if let Some(name) = soname {
            let off = dynstr.len() as u64;
            dynstr.extend_from_slice(name.as_bytes());
            dynstr.push(0);
            entries.push((14, off)); // DT_SONAME
        }
        let entry_count = (entries.len() + 3) as u64; // + DT_STRTAB + DT_STRSZ + DT_NULL
        let dynstr_off = 64 + 56 + 56 + 16 * entry_count;
        entries.push((5, dynstr_off)); // DT_STRTAB
        entries.push((10, dynstr.len() as u64)); // DT_STRSZ
        let total = dynstr_off + dynstr.len() as u64;

        let mut out = Vec::new();
        out.extend_from_slice(&[0x7f, b'E', b'L', b'F', 2, 1, 1, 0]);
        out.extend_from_slice(&[0u8; 8]);
        out.extend_from_slice(&3u16.to_le_bytes()); // ET_DYN
        out.extend_from_slice(&62u16.to_le_bytes()); // EM_X86_64
        out.extend_from_slice(&1u32.to_le_bytes());
        out.extend_from_slice(&0u64.to_le_bytes()); // e_entry
        out.extend_from_slice(&64u64.to_le_bytes()); // e_phoff
        out.extend_from_slice(&0u64.to_le_bytes()); // e_shoff
        out.extend_from_slice(&0u32.to_le_bytes());
        out.extend_from_slice(&64u16.to_le_bytes()); // e_ehsize
        out.extend_from_slice(&56u16.to_le_bytes()); // e_phentsize
        out.extend_from_slice(&2u16.to_le_bytes()); // e_phnum
        out.extend_from_slice(&64u16.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        // PT_LOAD covering the whole file (vaddr == file offset).
        out.extend_from_slice(&1u32.to_le_bytes());
        out.extend_from_slice(&5u32.to_le_bytes());
        out.extend_from_slice(&0u64.to_le_bytes());
        out.extend_from_slice(&0u64.to_le_bytes());
        out.extend_from_slice(&0u64.to_le_bytes());
        out.extend_from_slice(&total.to_le_bytes());
        out.extend_from_slice(&total.to_le_bytes());
        out.extend_from_slice(&0x1000u64.to_le_bytes());
        // PT_DYNAMIC at 176 (ehdr + 2 phdrs), sized to the entry count.
        out.extend_from_slice(&2u32.to_le_bytes());
        out.extend_from_slice(&6u32.to_le_bytes());
        out.extend_from_slice(&176u64.to_le_bytes());
        out.extend_from_slice(&176u64.to_le_bytes());
        out.extend_from_slice(&176u64.to_le_bytes());
        out.extend_from_slice(&(16 * entry_count).to_le_bytes());
        out.extend_from_slice(&(16 * entry_count).to_le_bytes());
        out.extend_from_slice(&8u64.to_le_bytes());
        for (tag, val) in &entries {
            out.extend_from_slice(&tag.to_le_bytes());
            out.extend_from_slice(&val.to_le_bytes());
        }
        out.extend_from_slice(&0u64.to_le_bytes()); // DT_NULL
        out.extend_from_slice(&0u64.to_le_bytes());
        out.extend_from_slice(&dynstr);
        out
    }

    fn write_archive(path: &Path, entries: &[(&str, &[u8])]) {
        let file = std::fs::File::create(path).unwrap();
        let enc = zstd::Encoder::new(file, 0).unwrap();
        let mut builder = tar::Builder::new(enc);
        for (name, data) in entries {
            let mut header = tar::Header::new_gnu();
            header.set_size(data.len() as u64);
            header.set_mode(0o644);
            header.set_cksum();
            builder.append_data(&mut header, name, *data).unwrap();
        }
        let enc = builder.into_inner().unwrap();
        enc.finish().unwrap();
    }

    /// One scratch tree per test (tag-disambiguated, parallel-safe).
    struct Scratch(PathBuf);

    impl Scratch {
        fn new(tag: &str) -> Scratch {
            let dir = std::env::temp_dir()
                .join(format!("gsa-qa-declared-deps-{tag}-{}", std::process::id()));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir).unwrap();
            Scratch(dir)
        }

        fn archive(&self, name: &str, members: &[(&str, Vec<u8>)]) -> PathBuf {
            let path = self.0.join(name);
            let borrowed: Vec<(&str, &[u8])> =
                members.iter().map(|(n, b)| (*n, b.as_slice())).collect();
            write_archive(&path, &borrowed);
            path
        }
    }

    impl Drop for Scratch {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn archive(recipe_id: &str, path: PathBuf) -> QaArchive {
        QaArchive {
            recipe_id: recipe_id.to_string(),
            path,
            pkginfo: None,
        }
    }

    fn run(
        recipes: &[QaRecipe],
        archives: &[QaArchive],
        installed: &[QaInstalled],
        exclusions: &[String],
    ) -> CheckResult {
        let input = QaInput {
            recipes,
            targets: &[],
            archives,
            installed,
            exclusions,
        };
        declared_deps(&input)
    }

    #[test]
    fn undeclared_link_names_recipe_member_and_soname() {
        let scratch = Scratch::new("undeclared");
        let recipes = vec![
            recipe(
                "prov-git",
                "pkgbase = prov-git\npkgname = prov-git\nprovides = libfoo.so\n",
            ),
            recipe("app-git", "pkgbase = app-git\npkgname = app-git\n"),
        ];
        let path = scratch.archive(
            "app.pkg.tar.zst",
            &[(
                "usr/lib/libapp.so.1",
                elf64_with(&["libfoo.so.3"], Some("libapp.so.1")),
            )],
        );
        let result = run(&recipes, &[archive("app-git", path)], &[], &[]);
        assert_eq!(result.findings.len(), 1, "{:?}", result.findings);
        let finding = &result.findings[0];
        assert_eq!(finding.subject, "consumer app-git (usr/lib/libapp.so.1)");
        assert!(
            finding.detail.contains("undeclared-link"),
            "{}",
            finding.detail
        );
        assert!(finding.detail.contains("libfoo.so.3"), "{}", finding.detail);
        assert!(finding.detail.contains("prov-git"), "{}", finding.detail);
    }

    #[test]
    fn transitive_coverage_through_another_recipe_is_accepted() {
        let scratch = Scratch::new("transitive");
        let recipes = vec![
            recipe(
                "prov-git",
                "pkgbase = prov-git\npkgname = prov-git\nprovides = libfoo.so\n",
            ),
            recipe(
                "mid-git",
                "pkgbase = mid-git\npkgname = mid-git\ndepends = prov-git\n",
            ),
            recipe(
                "app-git",
                "pkgbase = app-git\npkgname = app-git\ndepends = mid-git\n",
            ),
        ];
        let path = scratch.archive(
            "app.pkg.tar.zst",
            &[(
                "usr/lib/libapp.so.1",
                elf64_with(&["libfoo.so.3"], Some("libapp.so.1")),
            )],
        );
        let result = run(&recipes, &[archive("app-git", path)], &[], &[]);
        assert!(result.findings.is_empty(), "{:?}", result.findings);
    }

    #[test]
    fn self_shipped_soname_is_covered() {
        let scratch = Scratch::new("self");
        let recipes = vec![recipe("app-git", "pkgbase = app-git\npkgname = app-git\n")];
        // The lib member's FILE NAME is not the soname — only its DT_SONAME
        // can satisfy the sibling member's DT_NEEDED.
        let path = scratch.archive(
            "app.pkg.tar.zst",
            &[
                (
                    "usr/lib/libself.so.1.0",
                    elf64_with(&[], Some("libself.so.1")),
                ),
                (
                    "usr/lib/libapp.so.1",
                    elf64_with(&["libself.so.1"], Some("libapp.so.1")),
                ),
            ],
        );
        let result = run(&recipes, &[archive("app-git", path)], &[], &[]);
        assert!(result.findings.is_empty(), "{:?}", result.findings);
    }

    #[test]
    fn base_system_sonames_are_covered() {
        let scratch = Scratch::new("base");
        let recipes = vec![recipe("app-git", "pkgbase = app-git\npkgname = app-git\n")];
        let path = scratch.archive(
            "app.pkg.tar.zst",
            &[(
                "usr/lib/libapp.so.1",
                elf64_with(&["libc.so.6", "libstdc++.so.6"], Some("libapp.so.1")),
            )],
        );
        let result = run(&recipes, &[archive("app-git", path)], &[], &[]);
        assert!(result.findings.is_empty(), "{:?}", result.findings);
    }

    #[test]
    fn stem_matching_covers_the_auto_versioned_provide_family() {
        let scratch = Scratch::new("stem");
        // The auto-versioned form covers its own generation; the bare stem
        // covers the whole family.
        let recipes = vec![
            recipe(
                "prov-git",
                "pkgbase = prov-git\npkgname = prov-git\n\
                 provides = libfoo.so=1-64\nprovides = libbar.so\n",
            ),
            recipe(
                "app-git",
                "pkgbase = app-git\npkgname = app-git\ndepends = prov-git\n",
            ),
        ];
        let ok = scratch.archive(
            "ok.pkg.tar.zst",
            &[(
                "usr/lib/libapp.so.1",
                elf64_with(&["libfoo.so.1", "libbar.so.7"], Some("libapp.so.1")),
            )],
        );
        let result = run(&recipes, &[archive("app-git", ok)], &[], &[]);
        assert!(result.findings.is_empty(), "{:?}", result.findings);

        // The next generation is NOT covered by `libfoo.so=1-64` — no
        // provider resolves at all.
        let skew = scratch.archive(
            "skew.pkg.tar.zst",
            &[(
                "usr/lib/libapp.so.1",
                elf64_with(&["libfoo.so.2"], Some("libapp.so.1")),
            )],
        );
        let result = run(&recipes, &[archive("app-git", skew)], &[], &[]);
        assert_eq!(result.findings.len(), 1, "{:?}", result.findings);
        assert!(
            result.findings[0].detail.contains("unresolvable-link"),
            "{}",
            result.findings[0].detail
        );
    }

    #[test]
    fn unresolvable_link_is_a_distinct_shape_and_the_exclusions_registry_clears_it() {
        let scratch = Scratch::new("unresolvable");
        let recipes = vec![recipe("app-git", "pkgbase = app-git\npkgname = app-git\n")];
        let path = scratch.archive(
            "app.pkg.tar.zst",
            &[(
                "usr/lib/libapp.so.1",
                elf64_with(&["libghost.so.1"], Some("libapp.so.1")),
            )],
        );
        let result = run(&recipes, &[archive("app-git", path.clone())], &[], &[]);
        assert_eq!(result.findings.len(), 1, "{:?}", result.findings);
        let finding = &result.findings[0];
        assert!(
            finding.detail.contains("unresolvable-link"),
            "{}",
            finding.detail
        );
        assert!(
            finding.detail.contains("libghost.so.1"),
            "{}",
            finding.detail
        );
        assert!(
            finding.detail.contains("config/abi-exclusions.conf"),
            "{}",
            finding.detail
        );

        let exclusions = vec!["libghost.so".to_string()];
        let result = run(&recipes, &[archive("app-git", path)], &[], &exclusions);
        assert!(result.findings.is_empty(), "{:?}", result.findings);
    }

    #[test]
    fn installed_provides_resolve_and_cover_external_providers() {
        let scratch = Scratch::new("installed");
        // The incident shape: a repo provider outside the workspace, its
        // identity visible only through the installed-DB provides.
        let installed = vec![QaInstalled {
            name: "libxres".to_string(),
            version: "1.2.0-1".to_string(),
            provides: vec!["libXRes.so=1-64".to_string()],
            depends: Vec::new(),
            files: Vec::new(),
        }];
        let path = scratch.archive(
            "app.pkg.tar.zst",
            &[(
                "usr/lib/libatspi.so.0",
                elf64_with(&["libXRes.so.1"], Some("libatspi.so.0")),
            )],
        );
        let undeclared = vec![recipe("app-git", "pkgbase = app-git\npkgname = app-git\n")];
        let result = run(
            &undeclared,
            &[archive("app-git", path.clone())],
            &installed,
            &[],
        );
        assert_eq!(result.findings.len(), 1, "{:?}", result.findings);
        assert!(
            result.findings[0].detail.contains("undeclared-link"),
            "{}",
            result.findings[0].detail
        );
        assert!(
            result.findings[0].detail.contains("libxres"),
            "{}",
            result.findings[0].detail
        );

        let declared = vec![recipe(
            "app-git",
            "pkgbase = app-git\npkgname = app-git\ndepends = libxres\n",
        )];
        let result = run(&declared, &[archive("app-git", path)], &installed, &[]);
        assert!(result.findings.is_empty(), "{:?}", result.findings);
    }

    #[test]
    fn file_ownership_resolves_a_no_provide_provider() {
        // The incident shape: a stock provider carrying NO soname provide
        // (libxres) is visible only through its owned files — the
        // `pacman -Qo` half of the installed truth.
        let scratch = Scratch::new("ownership");
        let installed = vec![QaInstalled {
            name: "libxres".to_string(),
            version: "1.2.0-1".to_string(),
            provides: Vec::new(),
            depends: Vec::new(),
            files: vec!["usr/lib/libXRes.so.1".to_string()],
        }];
        let path = scratch.archive(
            "app.pkg.tar.zst",
            &[(
                "usr/lib/libatspi.so.0",
                elf64_with(&["libXRes.so.1"], Some("libatspi.so.0")),
            )],
        );
        // Declared as a plain provider name (the spelling the no-provide
        // provider forces): covered via ownership.
        let declared = vec![recipe(
            "app-git",
            "pkgbase = app-git\npkgname = app-git\ndepends = libxres\n",
        )];
        let result = run(
            &declared,
            &[archive("app-git", path.clone())],
            &installed,
            &[],
        );
        assert!(result.findings.is_empty(), "{:?}", result.findings);

        // Undeclared: the owner resolves but lies outside the closure.
        let undeclared = vec![recipe("app-git", "pkgbase = app-git\npkgname = app-git\n")];
        let result = run(&undeclared, &[archive("app-git", path)], &installed, &[]);
        assert_eq!(result.findings.len(), 1, "{:?}", result.findings);
        assert!(
            result.findings[0].detail.contains("undeclared-link"),
            "{}",
            result.findings[0].detail
        );
        assert!(
            result.findings[0].detail.contains("libxres"),
            "{}",
            result.findings[0].detail
        );
    }

    #[test]
    fn workspace_provide_match_precedes_installed_ownership() {
        // Both tiers explain the soname: a workspace recipe provides it and
        // an in-closure installed package owns the file. The workspace
        // provide surface is the more precise claim (precedence 2(a) > 2(b)),
        // so the finding names the workspace provider and ownership does
        // not silently absorb it.
        let scratch = Scratch::new("precedence");
        let recipes = vec![
            recipe(
                "prov-git",
                "pkgbase = prov-git\npkgname = prov-git\nprovides = libfoo.so\n",
            ),
            recipe(
                "app-git",
                "pkgbase = app-git\npkgname = app-git\ndepends = stockfoo\n",
            ),
        ];
        let installed = vec![QaInstalled {
            name: "stockfoo".to_string(),
            version: "1.0-1".to_string(),
            provides: Vec::new(),
            depends: Vec::new(),
            files: vec!["usr/lib/libfoo.so.3".to_string()],
        }];
        let path = scratch.archive(
            "app.pkg.tar.zst",
            &[(
                "usr/lib/libapp.so.1",
                elf64_with(&["libfoo.so.3"], Some("libapp.so.1")),
            )],
        );
        let result = run(&recipes, &[archive("app-git", path)], &installed, &[]);
        assert_eq!(result.findings.len(), 1, "{:?}", result.findings);
        assert!(
            result.findings[0].detail.contains("prov-git"),
            "{}",
            result.findings[0].detail
        );
    }

    #[test]
    fn no_built_outputs_is_skipped_never_a_vacuous_clean() {
        let recipes = vec![recipe("app-git", "pkgbase = app-git\npkgname = app-git\n")];
        let result = run(&recipes, &[], &[], &[]);
        assert!(result.findings.is_empty());
        assert!(result.skipped.is_some(), "must report skipped");
    }
}
