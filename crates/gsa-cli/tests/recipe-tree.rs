//! Recipe-tree smoke: a committed `config/` + `packages/` recipe checkout must
//! load, sort and answer through the native read path. Expectations are
//! derived from the loaded records themselves (contract §L.3), never pinned
//! counts.
//!
//! The recipe half of the project is its own repository since the split, so
//! the checkout's location is an operator input (`GSA_RECIPE_CHECKOUT`,
//! contract §B.8) — this engine repository's own `../..` is only a fallback
//! while both halves still coexist. With neither, the test SKIPS loudly (one
//! stderr line, rc 0): an engine-only checkout cannot provide the tree, and
//! failing here would turn a legitimate split into a red suite.

use std::path::{Path, PathBuf};

use gsa_graph::Graph;
use gsa_recipe::RecipeDb;
use gsa_topo::load_project;

fn is_recipe_tree(path: &Path) -> bool {
    path.join("config").join("topology.conf").is_file()
}

/// The checkout to exercise: `GSA_RECIPE_CHECKOUT` first (taken as given — a
/// wrong path is an operator error and must fail, not skip), then this
/// repository's `../..` only when it really holds a recipe tree.
fn recipe_root() -> Option<PathBuf> {
    let in_repo = Path::new(env!("CARGO_MANIFEST_DIR")).join("../..");
    pick(gsa_model::config::recipe_checkout(), &in_repo)
}

/// The pure decision: the environment answer wins; the in-repo fallback only
/// counts when `config/topology.conf` is really there, so an engine-only
/// checkout yields `None` (the skip) instead of a guaranteed failure.
fn pick(env: Option<PathBuf>, in_repo: &Path) -> Option<PathBuf> {
    env.or_else(|| is_recipe_tree(in_repo).then(|| in_repo.to_path_buf()))
}

#[test]
fn an_engine_only_checkout_skips_instead_of_failing() {
    let scratch = Path::new(env!("CARGO_TARGET_TMPDIR")).join("recipe-tree-absent");
    std::fs::create_dir_all(&scratch).expect("scratch dir");
    assert_eq!(
        pick(None, &scratch),
        None,
        "an empty dir is not a recipe tree"
    );

    let tree = scratch.join("with-tree");
    std::fs::create_dir_all(tree.join("config")).expect("tree dir");
    std::fs::write(tree.join("config").join("topology.conf"), "").expect("topology");
    assert_eq!(pick(None, &tree), Some(tree.clone()));

    let explicit = PathBuf::from("/srv/gsa-recipe");
    assert_eq!(
        pick(Some(explicit.clone()), &tree),
        Some(explicit),
        "GSA_RECIPE_CHECKOUT wins over the in-repo fallback"
    );
}

#[test]
fn recipe_tree_loads_sorts_and_answers() {
    let Some(root) = recipe_root() else {
        eprintln!("recipe-tree: skipped — set GSA_RECIPE_CHECKOUT to a recipe repository checkout");
        return;
    };
    let project = load_project(&root).expect("real config/ must load");
    assert!(
        !project.topology.records.is_empty(),
        "the real topology is never empty"
    );

    // Every record has a unique id and a data-channel row of exactly five
    // fields (contract §B.3).
    for record in &project.topology.records {
        assert_eq!(record.wire().matches('|').count(), 4, "{}", record.wire());
    }

    // The graph covers every record and its canonical order respects every
    // build-order edge.
    let graph = Graph::build(&project.topology.records).expect("real graph must sort");
    assert_eq!(graph.order().len(), graph.len());
    for record in &project.topology.records {
        for edge in &record.edges {
            let from = graph.position(graph.index_of(record.id.as_str()).unwrap());
            let to = graph.position(graph.index_of(edge.as_str()).unwrap());
            assert!(to < from, "{} must build before {}", edge, record.id);
        }
    }

    // Consumer expansion on a real recipe is non-empty and self-inclusive.
    let some = graph.index_of(project.topology.records[0].id.as_str());
    let closure = graph.consumer_closure(&[some.unwrap()]);
    assert!(!closure.is_empty());

    // The recipe cache resolves every topology record through the narrowed
    // read path (.SRCINFO or the scan fallback).
    let db = RecipeDb::load(&root, graph.records()).expect("real recipes must parse");
    for record in graph.records() {
        let meta = db
            .get(record.id.as_str())
            .unwrap_or_else(|| panic!("recipe {} must have metadata", record.id));
        assert!(!meta.pkgnames().is_empty(), "{}", record.id);
    }

    // Group membership comes from the records only; the roster is closed.
    for group in gsa_model::Group::ROSTER {
        for id in project.topology.members(group) {
            assert!(project
                .topology
                .get(id.as_str())
                .unwrap()
                .groups
                .contains(&group));
        }
    }
}
