//! Build-order graph: consumer expansion, one canonical topological sort,
//! and coupled-batch/app-cluster tag grouping.
//!
//! Vocabulary is `CONTEXT.md`'s: a topology record's `edges` are **build-order
//! edges** — "this recipe must build after that one" — never pacman
//! dependencies. If a record lists B in its `edges`, the record **consumes**
//! B; consumer expansion walks those edges backwards (the set at ABI risk
//! when B rebuilds) and never forwards (prerequisites are assumed installed
//! and current — contract §C.3).
//!
//! Build order is ONE topological sort over the whole graph, validated on
//! every invocation (contract §C.5): plan, listing, run-record and range
//! order are all restrictions of that same order, so any subselection keeps
//! "a package before its consumers". Ties break by topology record order —
//! deterministic across invocations.

use std::collections::{BTreeMap, VecDeque};

use gsa_model::{RecipeId, Tag, TopologyRecord};

/// A cycle (or unresolvable node) in the build-order graph: a refusal that
/// breaks every command and names the offenders and their lines.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CycleError {
    pub members: Vec<(RecipeId, usize)>,
}

impl std::fmt::Display for CycleError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "build-order cycle refused")?;
        for (id, line) in &self.members {
            write!(f, ", {id} (line {line})")?;
        }
        Ok(())
    }
}

impl std::error::Error for CycleError {}

/// Severity of a coupled-batch member (topology tags `abi=must` / `abi=should`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum BatchSeverity {
    Must,
    Should,
}

/// One abi-tagged member of an anchor's coupled batch. The member's own tag
/// decides its treatment — `abi=must` moves in the same pass, `abi=should`
/// is only ever noted (docs/maintainer-guide.md "Updating coupled stacks").
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CoupledMember {
    pub id: RecipeId,
    pub severity: BatchSeverity,
}

/// A coupled batch: one ABI anchor plus every abi-tagged package that
/// transitively depends on it — the reverse closure the edge file cannot
/// express (the frozen oracle's `abi_batch_dependents`). Members stay
/// separate recipes; the batch is a rebuild-set fact.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CoupledBatch {
    pub anchor: RecipeId,
    pub members: Vec<CoupledMember>,
}

/// Records presenting as ONE row in the app prompt (`app-cluster=<name>`).
/// Presentation only — the packages stay separate everywhere else (§C.4).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AppCluster {
    pub name: String,
    pub members: Vec<RecipeId>,
}

/// The validated build-order graph over one topology.
#[derive(Debug)]
pub struct Graph<'a> {
    records: &'a [TopologyRecord],
    /// Prerequisites of each record (its `edges`).
    forward: Vec<Vec<usize>>,
    /// Consumers of each record (reverse build-order adjacency).
    reverse: Vec<Vec<usize>>,
    /// Canonical topological order as record indices, ties by record order.
    order: Vec<usize>,
    /// record index → position in `order`.
    position: Vec<usize>,
}

impl<'a> Graph<'a> {
    /// Build and validate: a cycle anywhere breaks every command, naming the
    /// offenders and their lines (contract §C.5).
    pub fn build(records: &'a [TopologyRecord]) -> Result<Graph<'a>, CycleError> {
        let index: BTreeMap<&str, usize> = records
            .iter()
            .enumerate()
            .map(|(i, r)| (r.id.as_str(), i))
            .collect();
        let mut forward = vec![Vec::new(); records.len()];
        let mut reverse = vec![Vec::new(); records.len()];
        for (i, record) in records.iter().enumerate() {
            for edge in &record.edges {
                if let Some(&j) = index.get(edge.as_str()) {
                    forward[i].push(j);
                    reverse[j].push(i);
                }
            }
        }

        // Kahn's algorithm with a record-order tie-break: the ready set is
        // drained lowest-record-index first, which makes the linear extension
        // deterministic.
        let mut in_degree: Vec<usize> = forward.iter().map(|f| f.len()).collect();
        let mut ready: std::collections::BTreeSet<usize> =
            (0..records.len()).filter(|&i| in_degree[i] == 0).collect();
        let mut order = Vec::with_capacity(records.len());
        while let Some(&node) = ready.iter().next() {
            ready.remove(&node);
            order.push(node);
            for &consumer in &reverse[node] {
                in_degree[consumer] -= 1;
                if in_degree[consumer] == 0 {
                    ready.insert(consumer);
                }
            }
        }

        if order.len() != records.len() {
            // Every node not emitted is in or downstream of a cycle; name
            // each with its record line.
            let emitted: Vec<bool> = {
                let mut v = vec![false; records.len()];
                for &i in &order {
                    v[i] = true;
                }
                v
            };
            let members = records
                .iter()
                .enumerate()
                .filter(|(i, _)| !emitted[*i])
                .map(|(_, r)| (r.id.clone(), r.source_line))
                .collect();
            return Err(CycleError { members });
        }

        let mut position = vec![0usize; records.len()];
        for (pos, &node) in order.iter().enumerate() {
            position[node] = pos;
        }
        Ok(Graph {
            records,
            forward,
            reverse,
            order,
            position,
        })
    }

    pub fn len(&self) -> usize {
        self.records.len()
    }

    pub fn is_empty(&self) -> bool {
        self.records.is_empty()
    }

    pub fn records(&self) -> &'a [TopologyRecord] {
        self.records
    }

    pub fn record(&self, idx: usize) -> &'a TopologyRecord {
        &self.records[idx]
    }

    pub fn index_of(&self, id: &str) -> Option<usize> {
        self.records.iter().position(|r| r.id.as_str() == id)
    }

    /// The canonical build order: record indices in topological order.
    pub fn order(&self) -> &[usize] {
        &self.order
    }

    /// Recipe ids in canonical build order.
    pub fn ordered_ids(&self) -> Vec<RecipeId> {
        self.order
            .iter()
            .map(|&i| self.records[i].id.clone())
            .collect()
    }

    /// Position of a record in canonical build order.
    pub fn position(&self, idx: usize) -> usize {
        self.position[idx]
    }

    /// Prerequisites (the record's build-order edges, record order).
    pub fn prerequisites(&self, idx: usize) -> Vec<usize> {
        self.forward[idx].clone()
    }

    /// Consumer expansion: the seeds plus every recipe that transitively
    /// consumes one of them over build-order edges, returned in canonical
    /// build order (contract §C.3).
    pub fn consumer_closure(&self, seeds: &[usize]) -> Vec<usize> {
        let mut seen = vec![false; self.records.len()];
        let mut queue: VecDeque<usize> = VecDeque::new();
        for &seed in seeds {
            if !seen[seed] {
                seen[seed] = true;
                queue.push_back(seed);
            }
        }
        while let Some(node) = queue.pop_front() {
            for &consumer in &self.reverse[node] {
                if !seen[consumer] {
                    seen[consumer] = true;
                    queue.push_back(consumer);
                }
            }
        }
        let mut out: Vec<usize> = (0..self.records.len()).filter(|&i| seen[i]).collect();
        out.sort_by_key(|&i| self.position[i]);
        out
    }

    /// Anchor-derived coupled batches, members in canonical build order
    /// (docs/maintainer-guide.md "Updating coupled stacks"; the frozen
    /// oracle's `abi_batch_dependents` in tests/assets/build-all.fish).
    ///
    /// One batch per anchor — `config/topology.conf`: "a batch anchor is an
    /// abi=must package with no abi-tagged dependency" — carrying the
    /// anchor plus every abi-tagged package that transitively depends on
    /// it. The oracle's semantics, verbatim: the reverse closure traverses
    /// ALL records (untagged intermediates included), every reached record
    /// with an abi tag is a member (`abi=should` members are noted, never
    /// gated), the anchor itself is in the batch (its own output excludes
    /// it, the batch promise does not), and a dependent another anchor also
    /// reaches joins both batches — there is no cross-anchor pruning.
    /// Batches come out in canonical build order (first-built anchor
    /// first), so the whole vector is deterministic.
    pub fn coupled_batches(&self) -> Vec<CoupledBatch> {
        let mut batches = Vec::new();
        for &anchor in &self.order {
            if self.abi_severity(anchor) != Some(BatchSeverity::Must) {
                continue;
            }
            if self.has_abi_tagged_dependency(anchor) {
                continue;
            }
            batches.push(CoupledBatch {
                anchor: self.records[anchor].id.clone(),
                members: self.abi_batch_members(anchor),
            });
        }
        batches
    }

    /// The record's coupled-batch severity from its tags.
    fn abi_severity(&self, idx: usize) -> Option<BatchSeverity> {
        let tags = &self.records[idx].tags;
        if tags.contains(&Tag::AbiMust) {
            Some(BatchSeverity::Must)
        } else if tags.contains(&Tag::AbiShould) {
            Some(BatchSeverity::Should)
        } else {
            None
        }
    }

    /// Whether any TRANSITIVE dependency carries an abi tag (the oracle's
    /// `has_abi_tagged_dependency`: forward BFS over prerequisites, tag
    /// read per reached node, never the record itself). Such a record is a
    /// batch MEMBER, never an anchor; `abi=should` counts — it is an
    /// abi-tagged dependency too. The graph is acyclic (build refused the
    /// cycles), so the walk terminates.
    fn has_abi_tagged_dependency(&self, idx: usize) -> bool {
        let mut seen = vec![false; self.records.len()];
        let mut queue: VecDeque<usize> = self.forward[idx].iter().copied().collect();
        while let Some(node) = queue.pop_front() {
            if seen[node] {
                continue;
            }
            seen[node] = true;
            if self.abi_severity(node).is_some() {
                return true;
            }
            queue.extend(self.forward[node].iter().copied());
        }
        false
    }

    /// The anchor's batch members in canonical build order: the anchor
    /// plus every abi-tagged record the reverse closure (consumers* over
    /// ALL records) reaches.
    fn abi_batch_members(&self, anchor: usize) -> Vec<CoupledMember> {
        let mut seen = vec![false; self.records.len()];
        seen[anchor] = true;
        let mut queue: VecDeque<usize> = VecDeque::from([anchor]);
        while let Some(node) = queue.pop_front() {
            for &consumer in &self.reverse[node] {
                if !seen[consumer] {
                    seen[consumer] = true;
                    queue.push_back(consumer);
                }
            }
        }
        self.order
            .iter()
            .filter_map(|&i| {
                let severity = if seen[i] { self.abi_severity(i)? } else { return None };
                Some(CoupledMember {
                    id: self.records[i].id.clone(),
                    severity,
                })
            })
            .collect()
    }

    /// `app-cluster=<name>` rows, members in canonical build order.
    pub fn app_clusters(&self) -> Vec<AppCluster> {
        let mut clusters: BTreeMap<String, Vec<RecipeId>> = BTreeMap::new();
        for &idx in &self.order {
            for tag in &self.records[idx].tags {
                if let Tag::AppCluster(name) = tag {
                    clusters
                        .entry(name.clone())
                        .or_default()
                        .push(self.records[idx].id.clone());
                }
            }
        }
        clusters
            .into_iter()
            .map(|(name, members)| AppCluster { name, members })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn record(id: &str, line: usize, edges: &[&str], tags: Vec<Tag>) -> TopologyRecord {
        TopologyRecord {
            id: RecipeId::new(id).unwrap(),
            path: format!("packages/test/{id}"),
            groups: vec![gsa_model::Group::Git],
            edges: edges.iter().map(|e| RecipeId::new(*e).unwrap()).collect(),
            tags,
            source_line: line,
        }
    }

    #[test]
    fn order_respects_every_edge() {
        // a consumes b consumes c; d is unrelated. Every edge must point
        // forward in the canonical order.
        let records = vec![
            record("d", 1, &[], vec![]),
            record("a", 2, &["b"], vec![]),
            record("c", 3, &[], vec![]),
            record("b", 4, &["c"], vec![]),
        ];
        let graph = Graph::build(&records).unwrap();
        let order: Vec<&str> = graph
            .order()
            .iter()
            .map(|&i| records[i].id.as_str())
            .collect();
        for rec in &records {
            for edge in &rec.edges {
                let from = graph.position(graph.index_of(rec.id.as_str()).unwrap());
                let to = graph.position(graph.index_of(edge.as_str()).unwrap());
                assert!(
                    to < from,
                    "{} must build before {}: order {order:?}",
                    edge,
                    rec.id
                );
            }
        }
        // Deterministic: c before b before a (record order breaks ties).
        assert_eq!(order, vec!["d", "c", "b", "a"]);
    }

    #[test]
    fn consumer_closure_is_reverse_reachability() {
        // diamond + tail: c consumes b and d; e consumes c.
        let records = vec![
            record("a", 1, &[], vec![]),
            record("b", 2, &["a"], vec![]),
            record("c", 3, &["b", "d"], vec![]),
            record("d", 4, &[], vec![]),
            record("e", 5, &["c"], vec![]),
            record("f", 6, &[], vec![]),
        ];
        let graph = Graph::build(&records).unwrap();
        let seed = graph.index_of("a").unwrap();
        let closure = graph.consumer_closure(&[seed]);
        let names: Vec<&str> = closure.iter().map(|&i| records[i].id.as_str()).collect();
        assert_eq!(names, vec!["a", "b", "c", "e"]);

        // Oracle: naive fixpoint over reversed edges must agree exactly.
        let mut set = std::collections::BTreeSet::new();
        set.insert("a".to_string());
        loop {
            let mut changed = false;
            for rec in &records {
                if !set.contains(rec.id.as_str())
                    && rec.edges.iter().any(|e| set.contains(e.as_str()))
                {
                    set.insert(rec.id.as_str().to_string());
                    changed = true;
                }
            }
            if !changed {
                break;
            }
        }
        let mut expected: Vec<&str> = set.iter().map(|s| s.as_str()).collect();
        expected.sort();
        let mut got: Vec<&str> = names.to_vec();
        got.sort();
        assert_eq!(got, expected);
    }

    #[test]
    fn cycles_are_refused_with_offenders_and_lines() {
        let records = vec![
            record("solo", 1, &[], vec![]),
            record("a", 7, &["b"], vec![]),
            record("b", 8, &["a"], vec![]),
        ];
        let err = Graph::build(&records).unwrap_err();
        let ids: Vec<&str> = err.members.iter().map(|(id, _)| id.as_str()).collect();
        assert_eq!(ids, vec!["a", "b"]);
        assert_eq!(err.members[0], (RecipeId::new("a").unwrap(), 7));
        assert!(err.to_string().contains("a (line 7)"));
    }

    #[test]
    fn self_loops_are_refused() {
        let records = vec![record("a", 3, &["a"], vec![])];
        let err = Graph::build(&records).unwrap_err();
        assert_eq!(err.members, vec![(RecipeId::new("a").unwrap(), 3)]);
    }

    #[test]
    fn coupled_batches_are_derived_per_anchor() {
        // The promised shape (docs/maintainer-guide.md "Updating coupled
        // stacks"): one batch per anchor — an abi=must record with no
        // abi-tagged dependency — carrying the anchor plus every abi-tagged
        // package that transitively depends on it. Three independent
        // anchors must yield THREE batches (the real topology's
        // llvm-git/qt5-base-git/qt6-base-git shape in miniature), never one
        // bucket per severity (E2).
        let records = vec![
            record("llvm-git", 1, &[], vec![Tag::AbiMust]),
            record("rust-git", 2, &["llvm-git"], vec![Tag::AbiMust]),
            record("qt5-base-git", 3, &[], vec![Tag::AbiMust]),
            record("qt5-mem", 4, &["qt5-base-git"], vec![Tag::AbiMust]),
            record("qt6-base-git", 5, &[], vec![Tag::AbiMust]),
            record(
                "shared",
                6,
                &["llvm-git", "qt6-base-git"],
                vec![Tag::AbiMust],
            ),
            record("qt6-should", 7, &["qt6-base-git"], vec![Tag::AbiShould]),
            record("untagged", 8, &["llvm-git"], vec![]),
        ];
        let graph = Graph::build(&records).unwrap();
        let batches = graph.coupled_batches();
        assert_eq!(batches.len(), 3, "three anchors, three batches");
        fn ids(batch: &CoupledBatch) -> Vec<&str> {
            batch.members.iter().map(|m| m.id.as_str()).collect()
        }
        assert_eq!(batches[0].anchor, RecipeId::new("llvm-git").unwrap());
        assert_eq!(ids(&batches[0]), vec!["llvm-git", "rust-git", "shared"]);
        // The qt5 batch excludes every other anchor's subtree: a qt5 move
        // must never plan or park llvm-git (the E2 pin).
        assert_eq!(batches[1].anchor, RecipeId::new("qt5-base-git").unwrap());
        assert_eq!(ids(&batches[1]), vec!["qt5-base-git", "qt5-mem"]);
        // A dependent two anchors reach joins BOTH batches (the oracle has
        // no cross-anchor pruning); abi=should members ride the batch of
        // the anchor they depend on; untagged records never do.
        assert_eq!(batches[2].anchor, RecipeId::new("qt6-base-git").unwrap());
        assert_eq!(ids(&batches[2]), vec!["qt6-base-git", "shared", "qt6-should"]);
        // The member's OWN tag decides its treatment, never the batch's.
        let sev = |batch: &CoupledBatch, id: &str| {
            batch
                .members
                .iter()
                .find(|m| m.id.as_str() == id)
                .map(|m| m.severity)
        };
        assert_eq!(sev(&batches[0], "rust-git"), Some(BatchSeverity::Must));
        assert_eq!(sev(&batches[2], "qt6-should"), Some(BatchSeverity::Should));
    }

    #[test]
    fn an_abi_tagged_dependency_makes_a_record_a_member_never_an_anchor() {
        // topology.conf's anchor rule reads "no abi-tagged dependency" as
        // TRANSITIVE and over both severities (the oracle's
        // `has_abi_tagged_dependency`): m's abi tag comes through the
        // untagged mid, so m is a member of a's batch (the reverse closure
        // traverses untagged records too), and n — whose only abi-tagged
        // dependency is should-tagged s — is a member without any anchor
        // and forms no batch at all.
        let records = vec![
            record("a", 1, &[], vec![Tag::AbiMust]),
            record("mid", 2, &["a"], vec![]),
            record("m", 3, &["mid"], vec![Tag::AbiMust]),
            record("s", 4, &[], vec![Tag::AbiShould]),
            record("n", 5, &["s"], vec![Tag::AbiMust]),
        ];
        let graph = Graph::build(&records).unwrap();
        let batches = graph.coupled_batches();
        assert_eq!(batches.len(), 1);
        assert_eq!(batches[0].anchor, RecipeId::new("a").unwrap());
        assert_eq!(
            batches[0]
                .members
                .iter()
                .map(|m| m.id.as_str())
                .collect::<Vec<_>>(),
            vec!["a", "m"]
        );
    }

    #[test]
    fn app_clusters_collapse_rows_by_name() {
        let records = vec![
            record("a", 1, &[], vec![Tag::AppCluster("qt5".to_string())]),
            record("b", 2, &[], vec![Tag::AppCluster("qt5".to_string())]),
            record("c", 3, &[], vec![Tag::AppCluster("kde".to_string())]),
        ];
        let graph = Graph::build(&records).unwrap();
        let clusters = graph.app_clusters();
        assert_eq!(clusters.len(), 2);
        assert_eq!(clusters[0].name, "kde");
        assert_eq!(clusters[1].name, "qt5");
        assert_eq!(clusters[1].members.len(), 2);
    }

    #[test]
    fn random_dags_sort_and_closures_hold() {
        // xorshift-generated DAGs: edges always point from a lower to a
        // higher generation slot, so the graph is acyclic by construction;
        // records are emitted in shuffled order to exercise the tie-break.
        let mut state: u64 = 0x243f_6a88_85a3_08d3;
        let mut next = move || {
            state ^= state << 13;
            state ^= state >> 7;
            state ^= state << 17;
            state
        };
        for _case in 0..200 {
            let n = 2 + (next() % 24) as usize;
            let mut edges: Vec<Vec<usize>> = vec![Vec::new(); n];
            for node in 0..n {
                for other in 0..node {
                    if next() % 3 == 0 {
                        // `node` consumes `other`.
                        edges[node].push(other);
                    }
                }
            }
            let mut order: Vec<usize> = (0..n).collect();
            for i in (1..n).rev() {
                let j = (next() as usize) % (i + 1);
                order.swap(i, j);
            }
            let records: Vec<TopologyRecord> = order
                .iter()
                .enumerate()
                .map(|(line, &slot)| {
                    let mut rec = record(&format!("n{slot}"), line + 1, &[], vec![]);
                    rec.edges = edges[slot]
                        .iter()
                        .map(|&e| RecipeId::new(format!("n{e}")).unwrap())
                        .collect();
                    rec
                })
                .collect();
            let graph = Graph::build(&records).unwrap();
            // Property 1: the order respects every edge.
            for rec in &records {
                for edge in &rec.edges {
                    assert!(
                        graph.position(graph.index_of(edge.as_str()).unwrap())
                            < graph.position(graph.index_of(rec.id.as_str()).unwrap())
                    );
                }
            }
            // Property 2: consumer closure == reverse-reachability fixpoint.
            for seed_slot in 0..n {
                let seed = graph.index_of(&format!("n{seed_slot}")).unwrap();
                let got: Vec<String> = graph
                    .consumer_closure(&[seed])
                    .iter()
                    .map(|&i| records[i].id.as_str().to_string())
                    .collect();
                let mut set = std::collections::BTreeSet::new();
                set.insert(format!("n{seed_slot}"));
                loop {
                    let mut changed = false;
                    for (slot, deps) in edges.iter().enumerate() {
                        let id = format!("n{slot}");
                        if !set.contains(&id) && deps.iter().any(|d| set.contains(&format!("n{d}")))
                        {
                            set.insert(id);
                            changed = true;
                        }
                    }
                    if !changed {
                        break;
                    }
                }
                let mut expected: Vec<String> = set.into_iter().collect();
                expected.sort();
                let mut got_sorted = got.clone();
                got_sorted.sort();
                assert_eq!(got_sorted, expected);
            }
        }
    }
}
