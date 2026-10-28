//! The install seam's ABI refusal rows (contract §E.3) — the subsystem's
//! computation behind `gsa-install`'s decision pipeline. The row vocabulary
//! is FROZEN: `refuse abi-soname …`, `refuse abi-consumer …`,
//! `refuse abi-stock-pinner …`, and the under-coverage class
//! `refuse abi-consumer-uncovered …` (§E.3). Gates never render and never
//! execute; they compute typed rows the seam folds into its one plan.
//!
//! The computations themselves (provide drift, link truth, stock pinners)
//! moved here verbatim from `gsa-install::gates` so the state crate, the
//! install seam and the wave planner share ONE implementation.

use std::collections::BTreeSet;

use gsa_model::{Decision, DecisionRow};

use crate::provides::{provide_name, stock_name};
use crate::view::InstalledView;

/// One installed bare-soname provide that disappears or version-moves in a
/// build (fish `abi_provide_refusals`' per-archive diff).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Drift {
    /// The ARCHIVE's pkgname (the surface's home).
    pub pkgname: String,
    /// The provide name (`libfoo.so`).
    pub name: String,
    /// The installed auto-version (`1-64`), `-` when the entry is bare.
    pub inst_ver: String,
    /// The built auto-version; `None` = the provide disappears entirely.
    pub built_ver: Option<String>,
}

fn ver_of(entry: &str) -> String {
    match entry.split_once('=') {
        Some((_, v)) if !v.trim().is_empty() => v.trim().to_string(),
        _ => "-".to_string(),
    }
}

/// The bare-soname provide drift of one build against the installed view:
/// compare the archive's `.PKGINFO` provides against the installed provides
/// of the same pkgname — or of its stock counterpart when the pkgname is not
/// installed (a Stock→house swap MOVES the surface, run #31). Nothing
/// installed for either name means nothing can disappear (a true fresh
/// install). Only bare `*.so` provide names are compared (makepkg
/// auto-versions them; rule 25(a)).
pub fn provide_drift(pkgname: &str, built_provides: &[String], view: &InstalledView) -> Vec<Drift> {
    let installed: Vec<String> = match view.get(pkgname) {
        Some(pkg) => pkg.provides.clone(),
        None => {
            let stock = stock_name(pkgname);
            if stock == pkgname {
                return Vec::new();
            }
            match view.get(&stock) {
                Some(pkg) => pkg.provides.clone(),
                None => return Vec::new(),
            }
        }
    };
    let mut drift = Vec::new();
    for entry in &installed {
        let name = provide_name(entry);
        if !name.ends_with(".so") {
            continue;
        }
        let inst_ver = ver_of(entry);
        let built = built_provides.iter().find(|b| provide_name(b) == name);
        match built {
            None => drift.push(Drift {
                pkgname: pkgname.to_string(),
                name: name.to_string(),
                inst_ver,
                built_ver: None,
            }),
            Some(b) => {
                let built_ver = ver_of(b);
                if built_ver != inst_ver {
                    drift.push(Drift {
                        pkgname: pkgname.to_string(),
                        name: name.to_string(),
                        inst_ver,
                        built_ver: Some(built_ver),
                    });
                }
            }
        }
    }
    drift
}

fn elf_home(path: &str) -> bool {
    path.starts_with("usr/lib")
        || path.starts_with("usr/libexec")
        || path.starts_with("usr/bin")
        || path.starts_with("usr/sbin")
        || path.contains(".so")
}

/// Link truth (rule 25(c)/(d)): the INSTALLED packages whose ELF outputs
/// `DT_NEEDED` one of the affected provide names. Name/graph reachability is
/// never consulted — naming a provider is not linking it. Owned files in ELF
/// homes (or ELF-shaped names) are probed through the view root; a missing
/// file is skipped.
pub fn linked_consumers(view: &InstalledView, affected: &[String]) -> Vec<String> {
    if affected.is_empty() {
        return Vec::new();
    }
    let mut out: BTreeSet<String> = BTreeSet::new();
    for pkg in view.packages() {
        for file in &pkg.files {
            if !elf_home(file) {
                continue;
            }
            let Some(bytes) = view.read_file(file) else {
                continue;
            };
            let needed = gsa_recipe::elf::needed_libs(&bytes);
            if needed
                .iter()
                .any(|n| affected.iter().any(|a| n == a || n.starts_with(a.as_str())))
            {
                out.insert(pkg.name.clone());
                break;
            }
        }
    }
    out.into_iter().collect()
}

/// Stock-side pinners (fish `abi_local_depend_rows`): every installed
/// package declaring a `Depends` on an affected provide name — the pin
/// pacman will enforce at transaction time before any in-run repair could
/// run. Only exact declareable shapes match (`X`, `X=ver`, `X.so=N-64`,
/// `X.so`): the depend name must equal the affected provide name.
pub fn stock_pinners(view: &InstalledView, affected: &[String]) -> Vec<(String, String)> {
    if affected.is_empty() {
        return Vec::new();
    }
    let mut out: Vec<(String, String)> = Vec::new();
    for pkg in view.packages() {
        for dep in &pkg.depends {
            let name = provide_name(dep);
            if affected.iter().any(|a| a == name) {
                out.push((pkg.name.clone(), dep.clone()));
            }
        }
    }
    out
}

/// The ABI gate's outcome for one drifted candidate (rule 25(d); fish
/// `abi_provide_refusals`): the refusal rows plus the in-run repair targets.
#[derive(Clone, Debug, Default)]
pub struct AbiGate {
    /// The refusal rows — EMPTY when nothing is stranded: the provide move
    /// lands with every exposure covered (the abi-soname rows are refusal
    /// rows and never ride a clean plan).
    pub rows: Vec<DecisionRow>,
    /// Consumers the run itself rebuilds and reinstalls later
    /// (`DecisionContext.later_installs`) — canonical RECIPE-ID keys (§E.3
    /// gap-G1 `<consumer-id>`), deduped across split outputs of one recipe.
    /// The provider's plan row carries `repair <consumer> <provider-id>`
    /// detail in its open REASON and the provider's install stages the
    /// forced-rebuild marker under that same key (§E.3 gap-G1 amendment) —
    /// repairs ride the plan even alongside refusals.
    pub repairs: Vec<String>,
}

/// The ABI gate's rows for one drifted candidate (the shapes the fixtures
/// pin): `abi-soname` per drifted provide plus `abi-consumer` per uncovered
/// linked consumer and `abi-stock-pinner` per uncovered out-of-tree pinner —
/// and ONLY while something is uncovered ("the refusal is conditional"):
/// coverage by the transaction (`tx_names`) or in-run repair
/// (`later_installs`, rule 25(d)) plans the move clean.
///
/// `recipe_of_name` is the ONE key-space boundary (§E.3 gap-G1
/// `<consumer-id>`): link truth names installed pkgnames (split outputs
/// included) while `later_installs` names recipe ids, so every consumer
/// resolves to its owning recipe id here — the marker file name, prepare's
/// freshness-gate lookup, the post-install clear and the later_installs
/// coverage check below all compare in that same key. An unresolvable name
/// stays itself: the marker key is then the name this seam CAN name, never
/// a dropped repair (fail closed).
///
/// Class split (fish's split rule): a pinner whose name is a workspace
/// recipe OUTPUT stays with the consumer logic — out-of-tree pinners alone
/// are `abi-stock-pinner`, and their coverage is transaction membership
/// ONLY (in-run repair structurally cannot rebuild an out-of-tree package).
pub fn abi_refusal_rows(
    subject: &str,
    archive: &str,
    drift: &[Drift],
    view: &InstalledView,
    tx_names: &[String],
    later_installs: &[String],
    recipe_of_name: &std::collections::BTreeMap<String, String>,
    workspace: &std::collections::BTreeSet<String>,
) -> AbiGate {
    let affected: Vec<String> = drift.iter().map(|d| d.name.clone()).collect();
    let in_tx = |name: &str| tx_names.iter().any(|t| t == name);
    let in_run = |name: &str| later_installs.iter().any(|t| t == name);
    let canon = |name: &str| -> String {
        recipe_of_name
            .get(name)
            .cloned()
            .unwrap_or_else(|| name.to_string())
    };
    // Consumer class (link truth): covered by the transaction, or repaired
    // in-run (F1: "coverage = same transaction OR later in-run install for
    // consumers"); anything else strands the move. The coverage check runs
    // in the canonical key space, matching the key the repair marker — and
    // its consume side — use.
    let mut uncovered: Vec<String> = Vec::new();
    let mut repairs: Vec<String> = Vec::new();
    for consumer in linked_consumers(view, &affected) {
        if in_tx(&consumer) {
            continue;
        }
        let key = canon(&consumer);
        if in_run(&key) {
            if !repairs.contains(&key) {
                repairs.push(key);
            }
            continue;
        }
        uncovered.push(consumer);
    }
    // Stock-pinner class: out-of-tree declared pinners only, uncovered
    // unless they ride THIS transaction. A name already in the consumer
    // class is never double-rowed.
    let pinners: Vec<(String, String)> = stock_pinners(view, &affected)
        .into_iter()
        .filter(|(pinner, _)| !workspace.contains(pinner))
        .filter(|(pinner, _)| !in_tx(pinner))
        .filter(|(pinner, _)| !uncovered.iter().any(|c| c == pinner))
        .filter(|(pinner, _)| !repairs.iter().any(|c| c == &canon(pinner)))
        .collect();

    let mut rows: Vec<DecisionRow> = Vec::new();
    if !uncovered.is_empty() || !pinners.is_empty() {
        for d in drift {
            rows.push(DecisionRow {
                subject: subject.to_string(),
                decision: Decision::Refuse,
                reason: format!(
                    "abi-soname {archive} {} {} {} {}",
                    d.pkgname,
                    d.name,
                    d.inst_ver,
                    d.built_ver.clone().unwrap_or_else(|| "-".to_string())
                ),
            });
        }
        for consumer in &uncovered {
            rows.push(DecisionRow {
                subject: subject.to_string(),
                decision: Decision::Refuse,
                reason: format!("abi-consumer {archive} {consumer}"),
            });
        }
        for (pinner, dep) in &pinners {
            rows.push(DecisionRow {
                subject: subject.to_string(),
                decision: Decision::Refuse,
                reason: format!("abi-stock-pinner {archive} {pinner} {dep}"),
            });
        }
    }
    AbiGate { rows, repairs }
}

/// One under-coverage refusal row (§E.3 `abi-consumer-uncovered`): the
/// moving provider's rebuild wave names a consumer this run cannot build or
/// transact. Fail-closed, named per consumer.
pub fn abi_uncovered_row(provider: &str, consumer: &str) -> DecisionRow {
    DecisionRow {
        subject: consumer.to_string(),
        decision: Decision::Refuse,
        reason: format!("abi-consumer-uncovered {provider}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::view::InstalledPkg;

    fn pkg(name: &str, provides: &[&str], depends: &[&str], files: &[&str]) -> InstalledPkg {
        InstalledPkg {
            name: name.to_string(),
            version: "0:1.0.0-1".to_string(),
            provides: provides.iter().map(|s| s.to_string()).collect(),
            depends: depends.iter().map(|s| s.to_string()).collect(),
            files: files.iter().map(|s| s.to_string()).collect(),
        }
    }

    #[test]
    fn drift_sees_disappearing_and_version_moving_provides() {
        let view = InstalledView::new([pkg(
            "abipkg",
            &["libfoo.so=1-64", "libstay.so=1-64"],
            &[],
            &[],
        )]);
        // libfoo.so version-moves AND libstay.so disappears from the build.
        let built = vec!["libfoo.so=2-64".to_string()];
        let drift = provide_drift("abipkg", &built, &view);
        assert_eq!(drift.len(), 2, "libfoo.so version-moved AND one vanished");
        let moved = drift.iter().find(|d| d.name == "libfoo.so").unwrap();
        assert_eq!(
            (moved.inst_ver.as_str(), moved.built_ver.as_deref()),
            ("1-64", Some("2-64"))
        );
        // A fresh install with nothing installed has no drift (rule: no
        // surface can disappear).
        assert!(provide_drift("fresh", &built, &view).is_empty());
    }

    #[test]
    fn zero_exposure_plans_clean() {
        // The refusal is conditional: a drift with nothing stranded (the
        // consumer owns no probeable ELF, no declared pinner) plans clean —
        // the abi-soname row is a refusal row and never rides a clean plan.
        let view = InstalledView::new([pkg("consumer-app", &[], &[], &["usr/lib/libconsumer.so"])]);
        let drift = vec![Drift {
            pkgname: "abipkg".to_string(),
            name: "libfoo.so".to_string(),
            inst_ver: "1-64".to_string(),
            built_ver: Some("2-64".to_string()),
        }];
        let gate = abi_refusal_rows(
            "abipkg",
            "/a/abipkg.pkg.tar.zst",
            &drift,
            &view,
            &["abipkg".to_string()],
            &[],
            &Default::default(),
            &Default::default(),
        );
        assert!(gate.rows.is_empty(), "nothing stranded plans clean");
        assert!(gate.repairs.is_empty());
    }

    #[test]
    fn rows_keep_the_frozen_shapes() {
        // An out-of-tree declared pinner strands the move: abi-soname per
        // drift plus abi-stock-pinner with the exact depstring.
        let view = InstalledView::new([pkg(
            "stock-pin",
            &[],
            &["libfoo.so=1-64"],
            &["usr/lib/libstock.so"],
        )]);
        let drift = vec![Drift {
            pkgname: "abipkg".to_string(),
            name: "libfoo.so".to_string(),
            inst_ver: "1-64".to_string(),
            built_ver: Some("2-64".to_string()),
        }];
        let gate = abi_refusal_rows(
            "abipkg",
            "/a/abipkg.pkg.tar.zst",
            &drift,
            &view,
            &["abipkg".to_string()],
            &[],
            &Default::default(),
            &Default::default(),
        );
        let rendered: Vec<String> = gate.rows.iter().map(|r| r.render()).collect();
        assert!(rendered.contains(
            &"abipkg refuse abi-soname /a/abipkg.pkg.tar.zst abipkg libfoo.so 1-64 2-64"
                .to_string()
        ));
        assert!(rendered.contains(
            &"abipkg refuse abi-stock-pinner /a/abipkg.pkg.tar.zst stock-pin libfoo.so=1-64"
                .to_string()
        ));
        assert_eq!(rendered.len(), 2);
        assert!(gate.repairs.is_empty());
        // The uncovered row shape is fixed.
        assert_eq!(
            abi_uncovered_row("p", "c").render(),
            "c refuse abi-consumer-uncovered p"
        );
    }

    #[test]
    fn coverage_plans_clean_and_schedules_repairs() {
        let dir = std::env::temp_dir().join(format!("gsa-abi-cover-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("usr/lib")).unwrap();
        let elf = crate::test_support::elf64(Some("libconsumer.so.1"), &["libfoo.so.1"]);
        std::fs::write(dir.join("usr/lib/libconsumer.so.1"), &elf).unwrap();
        // The ELF-owning output of recipe `consumer-app` is a SPLIT output
        // (`consumer-app-libs`): link truth names pkgnames, the run order
        // (`later_installs`) names recipe ids. The identical name/id of the
        // old fixture masked the key mismatch entirely.
        let view = InstalledView::with_root(
            dir.clone(),
            [pkg(
                "consumer-app-libs",
                &[],
                &[],
                &["usr/lib/libconsumer.so.1"],
            )],
        );
        let drift = vec![Drift {
            pkgname: "abipkg".to_string(),
            name: "libfoo.so".to_string(),
            inst_ver: "1-64".to_string(),
            built_ver: Some("2-64".to_string()),
        }];
        // Uncovered linked consumer: the move refuses (abi-soname rides the
        // refusal plan alongside the abi-consumer row).
        let gate = abi_refusal_rows(
            "abipkg",
            "/a/abipkg.pkg.tar.zst",
            &drift,
            &view,
            &["abipkg".to_string()],
            &[],
            &Default::default(),
            &Default::default(),
        );
        let rendered: Vec<String> = gate.rows.iter().map(|r| r.render()).collect();
        assert_eq!(rendered.len(), 2, "abi-soname + abi-consumer: {rendered:?}");
        assert!(rendered.contains(
            &"abipkg refuse abi-consumer /a/abipkg.pkg.tar.zst consumer-app-libs".to_string()
        ));
        assert!(gate.repairs.is_empty());
        // Rule 25(d) / F1 ("coverage = same transaction OR later in-run
        // install for consumers"): the run rebuilds recipe `consumer-app`
        // later — the move lands clean and the repair target rides the plan
        // under the RECIPE-ID key the marker surface reads back.
        let recipe_of_name = std::collections::BTreeMap::from([(
            "consumer-app-libs".to_string(),
            "consumer-app".to_string(),
        )]);
        let gate = abi_refusal_rows(
            "abipkg",
            "/a/abipkg.pkg.tar.zst",
            &drift,
            &view,
            &["abipkg".to_string()],
            &["consumer-app".to_string()],
            &recipe_of_name,
            &Default::default(),
        );
        assert!(gate.rows.is_empty(), "covered plans clean");
        assert_eq!(gate.repairs, vec!["consumer-app".to_string()]);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn workspace_pinners_stay_with_the_consumer_class() {
        // A workspace recipe output never rows as abi-stock-pinner (fish's
        // split rule) — and a workspace pinner with no link truth is not a
        // strand at all (its pin is pacman's transaction-time backstop).
        let view = InstalledView::new([pkg(
            "app-git",
            &[],
            &["libfoo.so=1-64"],
            &["usr/lib/libapp.so"],
        )]);
        let drift = vec![Drift {
            pkgname: "abipkg".to_string(),
            name: "libfoo.so".to_string(),
            inst_ver: "1-64".to_string(),
            built_ver: Some("2-64".to_string()),
        }];
        let mut workspace = std::collections::BTreeSet::new();
        workspace.insert("app-git".to_string());
        let gate = abi_refusal_rows(
            "abipkg",
            "/a/abipkg.pkg.tar.zst",
            &drift,
            &view,
            &["abipkg".to_string()],
            &[],
            &Default::default(),
            &workspace,
        );
        let rendered: Vec<String> = gate.rows.iter().map(|r| r.render()).collect();
        assert!(
            !rendered.iter().any(|r| r.contains("abi-stock-pinner")),
            "workspace outputs are never stock-pinner rows: {rendered:?}"
        );
        assert!(gate.rows.is_empty(), "nothing stranded plans clean");
    }

    #[test]
    fn link_truth_probes_files_and_names_the_consumer() {
        let dir = std::env::temp_dir().join(format!("gsa-abi-rows-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("usr/lib")).unwrap();
        let elf = crate::test_support::elf64(Some("libconsumer.so.1"), &["libfoo.so.1"]);
        std::fs::write(dir.join("usr/lib/libconsumer.so.1"), &elf).unwrap();
        let view = InstalledView::with_root(
            dir.clone(),
            [pkg("consumer-app", &[], &[], &["usr/lib/libconsumer.so.1"])],
        );
        assert_eq!(
            linked_consumers(&view, &["libfoo.so".to_string()]),
            vec!["consumer-app".to_string()]
        );
        assert!(linked_consumers(&view, &["libother.so".to_string()]).is_empty());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
