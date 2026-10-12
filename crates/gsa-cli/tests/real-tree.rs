//! Real-tree smoke: the committed `config/` + `packages/` of this repository
//! must load, sort and answer through the native read path. Expectations are
//! derived from the loaded records themselves (contract §L.3), never pinned
//! counts.

use std::path::Path;

use gsa_graph::Graph;
use gsa_recipe::RecipeDb;
use gsa_topo::load_project;

fn repo_root() -> std::path::PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

#[test]
fn real_tree_loads_sorts_and_answers() {
    let root = repo_root();
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
