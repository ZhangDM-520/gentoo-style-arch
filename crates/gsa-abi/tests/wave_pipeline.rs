//! The wave pipeline end to end through the public API (plan §4.2–§4.5):
//! subscription records → `plan_waves` → `stage_swap`. The unit tests pin
//! each term; this pins the seam between them — the wave a set of records
//! produces is the wave the swap stages, one transaction per wave, provider
//! archive first.

use std::collections::BTreeSet;
use std::path::PathBuf;

use gsa_abi::{plan_waves, stage_swap, MemberBasis, Subscriptions, TokenMove, WaveInputs};
use gsa_graph::Graph;
use gsa_model::{Group, RecipeId, Tag, TopologyRecord};

fn record(id: &str, edges: &[&str], tags: &[Tag]) -> TopologyRecord {
    TopologyRecord {
        id: RecipeId::new(id).unwrap(),
        path: format!("packages/git/{id}"),
        groups: vec![Group::Git],
        edges: edges.iter().map(|e| RecipeId::new(*e).unwrap()).collect(),
        tags: tags.to_vec(),
        source_line: 1,
    }
}

fn sub(consumer: &str, provider: &str, token: &str) -> gsa_abi::Subscription {
    gsa_abi::Subscription {
        consumer: consumer.to_string(),
        version: "1.0.0-1".to_string(),
        provider: provider.to_string(),
        token: token.to_string(),
    }
}

/// p ─▶ c1 ─▶ c2, plus an unrelated leaf.
fn dag() -> Vec<TopologyRecord> {
    vec![
        record("p", &[], &[]),
        record("c1", &["p"], &[]),
        record("c2", &["c1"], &[]),
        record("leaf", &[], &[]),
    ]
}

#[test]
fn records_to_plan_to_swap_stages_one_transaction_per_wave() {
    let records = dag();
    let graph = Graph::build(&records).unwrap();
    let mut subs = Subscriptions::empty();
    subs.upsert(sub("c1", "p", "old-token"));
    subs.upsert(sub("c2", "c1", "any-token"));

    let moves = vec![TokenMove {
        provider: "p".to_string(),
        old: Some("old-token".to_string()),
        new: "new-token".to_string(),
        changed_provides: Vec::new(),
    }];
    let planned: BTreeSet<String> = ["p".to_string()].into_iter().collect();
    let plan = plan_waves(&WaveInputs {
        graph: &graph,
        subs: &subs,
        moves: &moves,
        installed: None,
        planned: &planned,
    });

    // The record-mismatch seed (c1) and its transitive consumer (c2).
    assert_eq!(plan.waves.len(), 1, "one provider move, one wave");
    let wave = &plan.waves[0];
    let ids: Vec<&str> = wave.members.iter().map(|m| m.id.as_str()).collect();
    assert_eq!(ids, vec!["c1", "c2"], "mismatch set ∪ consumer closure");
    assert_eq!(
        wave.members
            .iter()
            .map(|m| m.basis)
            .collect::<Vec<MemberBasis>>(),
        vec![MemberBasis::Recorded, MemberBasis::Closure]
    );
    assert_eq!(plan.additions, vec!["c1".to_string(), "c2".to_string()]);
    assert!(plan.uncovered.is_empty(), "every member is topology-known");

    // Staging: ONE transaction per wave, provider archive first.
    let archive_of = |id: &str| -> Option<PathBuf> {
        match id {
            "p" | "c1" | "c2" => Some(PathBuf::from(format!("/archives/{id}-1.pkg.tar.zst"))),
            _ => None,
        }
    };
    let swap = stage_swap(&plan.waves, &archive_of);
    assert!(swap.refusals.is_empty(), "every wave member has an archive");
    assert_eq!(swap.transactions.len(), 1, "one wave, one transaction");
    let group: Vec<String> = swap.transactions[0]
        .iter()
        .map(|p| p.display().to_string())
        .collect();
    assert_eq!(
        group,
        vec![
            "/archives/p-1.pkg.tar.zst".to_string(),
            "/archives/c1-1.pkg.tar.zst".to_string(),
            "/archives/c2-1.pkg.tar.zst".to_string(),
        ],
        "the provider rides its own wave, first"
    );
}

#[test]
fn a_member_without_an_archive_refuses_and_holds_its_wave() {
    let records = dag();
    let graph = Graph::build(&records).unwrap();
    let mut subs = Subscriptions::empty();
    subs.upsert(sub("c1", "p", "old-token"));

    let moves = vec![TokenMove {
        provider: "p".to_string(),
        old: Some("old-token".to_string()),
        new: "new-token".to_string(),
        changed_provides: Vec::new(),
    }];
    let planned: BTreeSet<String> = ["p".to_string(), "c1".to_string()].into_iter().collect();
    let plan = plan_waves(&WaveInputs {
        graph: &graph,
        subs: &subs,
        moves: &moves,
        installed: None,
        planned: &planned,
    });
    assert_eq!(plan.waves.len(), 1);

    let archive_of = |id: &str| -> Option<PathBuf> {
        match id {
            "p" | "c1" => Some(PathBuf::from(format!("/archives/{id}-1.pkg.tar.zst"))),
            _ => None,
        }
    };
    let swap = stage_swap(&plan.waves, &archive_of);
    assert!(
        swap.transactions.is_empty(),
        "a wave is never transacted half-covered"
    );
    assert_eq!(swap.refusals.len(), 1, "the missing member is named");
    let row = &swap.refusals[0];
    assert_eq!(row.subject, "c2");
    assert_eq!(row.reason, "abi-consumer-uncovered p");
}

#[test]
fn no_mismatch_no_wave_stages_the_leftover_transaction() {
    let records = dag();
    let graph = Graph::build(&records).unwrap();
    let mut subs = Subscriptions::empty();
    subs.upsert(sub("c1", "p", "same-token"));

    let moves = vec![TokenMove {
        provider: "p".to_string(),
        old: Some("same-token".to_string()),
        new: "same-token".to_string(),
        changed_provides: Vec::new(),
    }];
    let planned: BTreeSet<String> = ["p".to_string()].into_iter().collect();
    let plan = plan_waves(&WaveInputs {
        graph: &graph,
        subs: &subs,
        moves: &moves,
        installed: None,
        planned: &planned,
    });
    assert!(plan.is_empty(), "a matching record is no move");

    let archive_of = |id: &str| -> Option<PathBuf> {
        (id == "p").then(|| PathBuf::from("/archives/p-1.pkg.tar.zst"))
    };
    let swap = stage_swap(&plan.waves, &archive_of);
    assert!(swap.transactions.is_empty(), "no wave, no swap group");
    assert!(swap.refusals.is_empty());
}
