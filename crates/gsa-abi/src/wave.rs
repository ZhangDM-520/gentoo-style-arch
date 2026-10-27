//! Computed rebuild sets — the `@preserved-rebuild` analogue
//! (plan-native-pm.md §4.3, `plan-gentoo-qol.md` M1): given providers whose
//! abi-tokens moved, the exact wave of packages to rebuild, composed with
//! coupled batches, and the staged-swap grouping that lands one wave in ONE
//! `pacman -U`.
//!
//! The `:=` subscription model (§4.2): a consumer rebuilds when its
//! RECORDED token for the provider differs from the provider's new token.
//! Declaring a build-order edge is not enough to trigger. But when
//! subscription records are missing the planner fails toward the OLD
//! whole-closure rule (`docs/MEMORY.md` rule 25(c) direction — **never
//! under-expand**): if ANY direct topology consumer of the provider has no
//! record for it, the fallback engages and the wave is the provider's FULL
//! transitive consumer closure — exactly the pre-subscription rule.

use std::collections::{BTreeMap, BTreeSet};
use std::path::PathBuf;

use gsa_graph::Graph;
use gsa_model::{Decision, DecisionRow};

use crate::records::Subscriptions;
use crate::view::InstalledView;

/// One observed abi-token move of one provider.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TokenMove {
    pub provider: String,
    /// What consumers recorded (or the previous built token), when known.
    pub old: Option<String>,
    /// The token now built/declared.
    pub new: String,
    /// Bare provide names that moved — the content-truth term's input
    /// (installed `DT_NEEDED` resolving through a dropped/changed provide).
    pub changed_provides: Vec<String>,
}

/// Why one package is in a wave.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum MemberBasis {
    /// Its recorded `:=` token for the provider differs (the exact set).
    Recorded,
    /// No subscription record for the provider — the fail-toward-whole-
    /// closure default (rule 25(c): never under-expand).
    Unrecorded,
    /// Installed `DT_NEEDED` resolves through a provide the provider
    /// dropped/changed (content truth, rule 25(b)/(e)).
    ContentTruth,
    /// A `abi=must` coupled-batch member (same-pass move).
    CoupledMust,
    /// Reached as a transitive consumer of a seed (plan §4.3's wave term),
    /// or swept in by the whole-closure fallback.
    Closure,
}

impl MemberBasis {
    /// The diagnostic wire name the `abi-wave <provider> <member> <basis>`
    /// rows carry (additive surface; the row class is the wave check's).
    pub fn wire(&self) -> &'static str {
        match self {
            MemberBasis::Recorded => "recorded",
            MemberBasis::Unrecorded => "unrecorded",
            MemberBasis::ContentTruth => "content-truth",
            MemberBasis::CoupledMust => "coupled-must",
            MemberBasis::Closure => "closure",
        }
    }
}

/// One wave member.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WaveMember {
    pub id: String,
    pub basis: MemberBasis,
}

/// One provider's rebuild wave.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Wave {
    pub provider: String,
    /// Seeds ∪ transitive consumers of seeds, canonical build order.
    pub members: Vec<WaveMember>,
    /// `abi=should` batch members noted but not forced (plan §4.3).
    pub coupled_noted: Vec<String>,
    /// True when the fail-toward-whole-closure default engaged (≥1
    /// unrecorded consumer) — reported so the fallback is never silent.
    pub fallback: bool,
}

/// The computed plan over a set of token moves.
#[derive(Clone, Debug, Default)]
pub struct WavePlan {
    pub waves: Vec<Wave>,
    /// Buildable wave members outside the run's planned selection — the
    /// rebuild set "added to the plan".
    pub additions: Vec<String>,
    /// Wave members that cannot be built this run (unknown to the topology),
    /// per provider: the `refuse abi-consumer-uncovered` class (§E.3).
    pub uncovered: Vec<(String, Vec<String>)>,
}

impl WavePlan {
    pub fn is_empty(&self) -> bool {
        self.waves.is_empty()
    }

    /// The §E.3 under-coverage refusal rows, one per uncovered member:
    /// `<member> refuse abi-consumer-uncovered <provider>`.
    pub fn refusal_rows(&self) -> Vec<DecisionRow> {
        let mut rows = Vec::new();
        for (provider, members) in &self.uncovered {
            for member in members {
                rows.push(DecisionRow {
                    subject: member.clone(),
                    decision: Decision::Refuse,
                    reason: format!("abi-consumer-uncovered {provider}"),
                });
            }
        }
        rows
    }
}

/// Everything `plan_waves` reads. `planned` is the run's selection (what
/// this run builds/installs); `installed` feeds the content-truth term and
/// may be `None` when no installed-ELF view is available (then only the
/// record and topology terms apply).
pub struct WaveInputs<'a> {
    pub graph: &'a Graph<'a>,
    pub subs: &'a Subscriptions,
    pub moves: &'a [TokenMove],
    pub installed: Option<&'a InstalledView>,
    pub planned: &'a BTreeSet<String>,
}

/// Compute the waves: exact `:=` mismatches ∪ unrecorded consumers
/// (fail-toward whole closure) ∪ content truth ∪ `abi=must` batch members,
/// closed over transitive consumers (`wave = R(P) ∪ consumers*(R(P))`,
/// plan §4.3), then partitioned into covered / added / uncovered against
/// the run's planned set.
pub fn plan_waves(input: &WaveInputs<'_>) -> WavePlan {
    let WaveInputs {
        graph,
        subs,
        moves,
        installed,
        planned,
    } = *input;
    let mut plan = WavePlan::default();

    for movement in moves {
        let provider = movement.provider.as_str();
        let provider_idx = graph.index_of(provider);
        let mut seeds: Vec<WaveMember> = Vec::new();
        let mut seen: BTreeSet<String> = BTreeSet::new();
        let mut push = |id: String, basis: MemberBasis, seeds: &mut Vec<WaveMember>| {
            if id == provider {
                return;
            }
            if seen.insert(id.clone()) {
                seeds.push(WaveMember { id, basis });
            }
        };

        // Term 1: the := subscription model (plan §4.2). A DIRECT topology
        // consumer of the provider is a rebuild candidate when its recorded
        // token differs. When any direct consumer has NO record for the
        // provider, the fail-toward whole-closure fallback engages (rule
        // 25(c): never under-expand) and every transitive consumer joins.
        let mut direct_consumers: BTreeSet<usize> = BTreeSet::new();
        let mut fallback = false;
        if let Some(idx) = provider_idx {
            for candidate in 0..graph.len() {
                if candidate != idx && graph.prerequisites(candidate).contains(&idx) {
                    direct_consumers.insert(candidate);
                }
            }
            fallback = direct_consumers.iter().any(|&i| {
                subs.token_for(graph.record(i).id.as_str(), provider)
                    .is_none()
            });
            for consumer_idx in &direct_consumers {
                let id = graph.record(*consumer_idx).id.as_str();
                match subs.token_for(id, provider) {
                    Some(token) if token == movement.new => {
                        if fallback {
                            // Fallback sweep: a matching record cannot
                            // shrink the whole-closure rule.
                            push(id.to_string(), MemberBasis::Closure, &mut seeds);
                        }
                    }
                    Some(_) => push(id.to_string(), MemberBasis::Recorded, &mut seeds),
                    None => push(id.to_string(), MemberBasis::Unrecorded, &mut seeds),
                }
            }
            if fallback {
                // The OLD rule verbatim: the provider's FULL in-tree
                // consumer closure rebuilds.
                for consumer_idx in graph.consumer_closure(&[idx]) {
                    if consumer_idx == idx {
                        continue;
                    }
                    push(
                        graph.record(consumer_idx).id.as_str().to_string(),
                        MemberBasis::Closure,
                        &mut seeds,
                    );
                }
            }
        }
        // Recorded subscribers without a direct edge (content-truth links:
        // the consumer's ELF binds the provider's provide directly) follow
        // their record; an unknown-to-topology subscriber is external and
        // surfaces as uncovered below.
        for row in subs.for_provider(provider) {
            if direct_consumers
                .iter()
                .any(|&i| graph.record(i).id.as_str() == row.consumer)
            {
                continue;
            }
            if row.token == movement.new {
                continue;
            }
            push(row.consumer.clone(), MemberBasis::Recorded, &mut seeds);
        }

        // Term 2: content truth — installed packages whose DT_NEEDED
        // resolves through a provide the provider dropped/changed (the
        // file-backed source of rule 25(b)/(e); plan §4.3's second term).
        if let Some(view) = installed {
            if !movement.changed_provides.is_empty() {
                for consumer in crate::rows::linked_consumers(view, &movement.changed_provides) {
                    push(consumer, MemberBasis::ContentTruth, &mut seeds);
                }
            }
        }

        // Term 3: coupled batches (abi=must same-pass; abi=should noted).
        // The batches are anchor-derived (docs/maintainer-guide.md
        // "Updating coupled stacks"), so a touch pulls the Touched
        // anchor's batch only — never another anchor's subtree — and each
        // member's own tag decides its treatment (E2).
        let batches = graph.coupled_batches();
        let mut noted: Vec<String> = Vec::new();
        let mut must_members: Vec<String> = Vec::new();
        for batch in &batches {
            let touches = batch.members.iter().any(|m| {
                m.id.as_str() == provider || seeds.iter().any(|s| s.id == m.id.as_str())
            });
            if !touches {
                continue;
            }
            for m in &batch.members {
                if m.id.as_str() == provider {
                    continue;
                }
                match m.severity {
                    gsa_graph::BatchSeverity::Must => {
                        must_members.push(m.id.as_str().to_string());
                    }
                    gsa_graph::BatchSeverity::Should => {
                        let id = m.id.as_str().to_string();
                        if !noted.contains(&id) {
                            noted.push(id);
                        }
                    }
                }
            }
        }
        for id in must_members {
            push(id, MemberBasis::CoupledMust, &mut seeds);
        }

        // Wave = seeds ∪ transitive consumers of seeds (plan §4.3).
        let seed_indices: Vec<usize> = seeds.iter().filter_map(|s| graph.index_of(&s.id)).collect();
        let mut members: Vec<WaveMember> = Vec::new();
        let seed_basis: BTreeMap<&str, MemberBasis> =
            seeds.iter().map(|s| (s.id.as_str(), s.basis)).collect();
        if !seed_indices.is_empty() {
            for idx in graph.consumer_closure(&seed_indices) {
                let id = graph.record(idx).id.as_str();
                let basis = seed_basis.get(id).copied().unwrap_or(MemberBasis::Closure);
                members.push(WaveMember {
                    id: id.to_string(),
                    basis,
                });
            }
        } else {
            // No topology-known seeds (e.g. content-truth only): the seeds
            // themselves are the wave.
            members.extend(seeds.iter().cloned());
        }
        // Seeds unknown to the topology can never be built in this
        // workspace — they surface as uncovered below, never as members.
        let (known, mut external): (Vec<WaveMember>, Vec<WaveMember>) = members
            .into_iter()
            .partition(|m| graph.index_of(&m.id).is_some());
        // Seeds unknown to the topology never reach the closure term —
        // collect them here so they surface as uncovered, never dropped.
        let known_ids: BTreeSet<&str> = known.iter().map(|m| m.id.as_str()).collect();
        for seed in &seeds {
            if !known_ids.contains(seed.id.as_str()) {
                external.push(seed.clone());
            }
        }
        let wave = Wave {
            provider: provider.to_string(),
            members: known,
            coupled_noted: noted,
            fallback,
        };

        for member in &wave.members {
            if !planned.contains(&member.id) {
                plan.additions.push(member.id.clone());
            }
        }
        let mut uncovered: Vec<String> = external.into_iter().map(|m| m.id).collect();
        if !uncovered.is_empty() {
            uncovered.sort();
            uncovered.dedup();
            plan.uncovered.push((provider.to_string(), uncovered));
        }
        if !wave.members.is_empty() || !wave.coupled_noted.is_empty() {
            plan.waves.push(wave);
        }
    }

    plan.additions.sort();
    plan.additions.dedup();
    merge_overlapping(&mut plan.waves);
    plan
}

/// Waves sharing a member are ONE wave (one pass, one transaction): merge
/// them provider-wise so no archive can land in two transactions.
fn merge_overlapping(waves: &mut Vec<Wave>) {
    let mut merged: Vec<Wave> = Vec::new();
    for wave in waves.drain(..) {
        let members: BTreeSet<&str> = wave.members.iter().map(|m| m.id.as_str()).collect();
        let Some(target) = merged.iter_mut().find(|w| {
            w.members.iter().any(|m| members.contains(m.id.as_str())) || w.provider == wave.provider
        }) else {
            merged.push(wave);
            continue;
        };
        let mut seen: BTreeSet<String> = target.members.iter().map(|m| m.id.clone()).collect();
        for member in wave.members {
            if seen.insert(member.id.clone()) {
                target.members.push(member);
            }
        }
        for noted in wave.coupled_noted {
            if !target.coupled_noted.contains(&noted) {
                target.coupled_noted.push(noted);
            }
        }
        target.fallback = target.fallback || wave.fallback;
    }
    // Canonical build order is lost by merging; keep members in wave order
    // (the caller re-sorts against the graph when it matters).
    *waves = merged;
}

/// The staged-swap transaction plan (plan-native-pm.md §4.5): one
/// transaction per wave, ALL of the wave's archives together — the old
/// provider stays installed until the whole wave lands in ONE `pacman -U`.
#[derive(Clone, Debug, Default)]
pub struct SwapPlan {
    /// Archive groups, one inner Vec per `pacman -U` (wave order).
    pub transactions: Vec<Vec<PathBuf>>,
    /// Members with no eligible archive: `refuse abi-consumer-uncovered`
    /// rows — a wave is never transacted half-covered (§E.3).
    pub refusals: Vec<DecisionRow>,
}

/// Stage one swap over the computed waves: each wave becomes ONE
/// transaction carrying every member's newest eligible archive. A member
/// whose archive cannot be resolved refuses (named, per provider) and its
/// whole wave is held back — the transaction is atomic over its wave.
pub fn stage_swap(waves: &[Wave], archive_of: &dyn Fn(&str) -> Option<PathBuf>) -> SwapPlan {
    let mut plan = SwapPlan::default();
    for wave in waves {
        let mut group: Vec<PathBuf> = Vec::new();
        let mut missing: Vec<String> = Vec::new();
        for member in &wave.members {
            match archive_of(&member.id) {
                Some(archive) => {
                    if !group.contains(&archive) {
                        group.push(archive);
                    }
                }
                None => missing.push(member.id.clone()),
            }
        }
        // The provider itself rides its own wave when it has an archive.
        if let Some(archive) = archive_of(&wave.provider) {
            if !group.contains(&archive) {
                group.insert(0, archive);
            }
        }
        if !missing.is_empty() {
            for member in &missing {
                plan.refusals.push(DecisionRow {
                    subject: member.clone(),
                    decision: Decision::Refuse,
                    reason: format!("abi-consumer-uncovered {}", wave.provider),
                });
            }
            continue;
        }
        if !group.is_empty() {
            plan.transactions.push(group);
        }
    }
    plan
}

#[cfg(test)]
mod tests {
    use super::*;
    use gsa_model::{Group, RecipeId, Tag, TopologyRecord};

    fn record(id: &str, edges: &[&str], tags: &[Tag]) -> TopologyRecord {
        TopologyRecord {
            id: RecipeId::new(id).unwrap(),
            path: format!("packages/{id}"),
            groups: vec![Group::Git],
            edges: edges.iter().map(|e| RecipeId::new(*e).unwrap()).collect(),
            tags: tags.to_vec(),
            source_line: 1,
        }
    }

    fn mv(provider: &str, new: &str, old: Option<&str>) -> TokenMove {
        TokenMove {
            provider: provider.to_string(),
            old: old.map(|s| s.to_string()),
            new: new.to_string(),
            changed_provides: Vec::new(),
        }
    }

    fn sub(consumer: &str, provider: &str, token: &str) -> crate::records::Subscription {
        crate::records::Subscription {
            consumer: consumer.to_string(),
            version: "0:1.0.0-1".to_string(),
            provider: provider.to_string(),
            token: token.to_string(),
        }
    }

    fn ids(wave: &Wave) -> Vec<&str> {
        wave.members.iter().map(|m| m.id.as_str()).collect()
    }

    /// p ─▶ c1 ─▶ c2, and c0 consumes p too.
    fn dag() -> Vec<TopologyRecord> {
        vec![
            record("p", &[], &[]),
            record("c0", &["p"], &[]),
            record("c1", &["p"], &[]),
            record("c2", &["c1"], &[]),
            record("other", &[], &[]),
        ]
    }

    #[test]
    fn the_wave_is_the_record_mismatch_set_plus_its_closure() {
        let records = dag();
        let graph = Graph::build(&records).unwrap();
        let mut subs = Subscriptions::empty();
        // c0 recorded the NEW token (:= satisfied — never rebuilds).
        subs.upsert(sub("c0", "p", "T2"));
        // c1 recorded the OLD token (mismatch → seed → c2 rides the closure).
        subs.upsert(sub("c1", "p", "T1"));
        let planned = BTreeSet::new();
        let plan = plan_waves(&WaveInputs {
            graph: &graph,
            subs: &subs,
            moves: &[mv("p", "T2", Some("T1"))],
            installed: None,
            planned: &planned,
        });
        assert_eq!(plan.waves.len(), 1);
        let wave = &plan.waves[0];
        assert_eq!(ids(wave), vec!["c1", "c2"], "c0's record matched");
        assert_eq!(wave.members[0].basis, MemberBasis::Recorded);
        assert_eq!(wave.members[1].basis, MemberBasis::Closure);
        assert!(!wave.fallback, "complete records engage no fallback");
    }

    #[test]
    fn unrecorded_consumers_fail_toward_the_whole_closure() {
        let records = dag();
        let graph = Graph::build(&records).unwrap();
        let subs = Subscriptions::empty(); // NO records at all
        let planned = BTreeSet::new();
        let plan = plan_waves(&WaveInputs {
            graph: &graph,
            subs: &subs,
            moves: &[mv("p", "T2", None)],
            installed: None,
            planned: &planned,
        });
        let wave = &plan.waves[0];
        // The OLD rule 25(c): a moved provider rebuilds its FULL consumer
        // closure — c0, c1 and (through c1) c2. `other` is not a consumer.
        assert_eq!(ids(wave), vec!["c0", "c1", "c2"]);
        assert!(wave.fallback, "the whole-closure fallback must be loud");
        assert!(
            wave.members
                .iter()
                .filter(|m| m.basis == MemberBasis::Unrecorded)
                .count()
                >= 2
        );
    }

    #[test]
    fn one_missing_record_engages_the_whole_closure_fallback() {
        // c1 has a MATCHING record, c0 has none — the record set is
        // incomplete, so the OLD whole-closure rule 25(c) engages and the
        // FULL consumer closure rebuilds. Never under-expand.
        let records = dag();
        let graph = Graph::build(&records).unwrap();
        let mut subs = Subscriptions::empty();
        subs.upsert(sub("c1", "p", "T2"));
        let planned = BTreeSet::new();
        let plan = plan_waves(&WaveInputs {
            graph: &graph,
            subs: &subs,
            moves: &[mv("p", "T2", Some("T1"))],
            installed: None,
            planned: &planned,
        });
        let wave = &plan.waves[0];
        assert_eq!(
            ids(wave),
            vec!["c0", "c1", "c2"],
            "whole closure, not a partial set"
        );
        assert!(wave.fallback);
    }

    #[test]
    fn coupled_must_batches_move_in_the_same_pass() {
        // Anchor-derived batches (E2): m1's batch is m1 plus its abi-tagged
        // dependents; the unrelated anchor a2's batch must never ride along
        // with it (the old severity bucket dragged every abi=must record in).
        let records = vec![
            record("p", &[], &[]),
            record("c1", &["p"], &[]),
            record("m1", &[], &[Tag::AbiMust]),
            record("m2", &["m1"], &[Tag::AbiMust]),
            record("s1", &["m1"], &[Tag::AbiShould]),
            record("a2", &[], &[Tag::AbiMust]),
            record("m3", &["a2"], &[Tag::AbiMust]),
        ];
        let graph = Graph::build(&records).unwrap();
        let mut subs = Subscriptions::empty();
        // Complete MATCHING records (:= satisfied) so only batch membership
        // can move m2 — the same isolation B1's fixture pin makes.
        subs.upsert(sub("m2", "m1", "T9"));
        subs.upsert(sub("s1", "m1", "T9"));
        subs.upsert(sub("c1", "p", "T2"));
        let planned = BTreeSet::new();
        let plan = plan_waves(&WaveInputs {
            graph: &graph,
            subs: &subs,
            moves: &[mv("m1", "T9", Some("T8"))],
            installed: None,
            planned: &planned,
        });
        let wave = &plan.waves[0];
        assert_eq!(ids(wave), vec!["m2"], "the touched anchor's must batch moves as one pass");
        assert_eq!(wave.members[0].basis, MemberBasis::CoupledMust);
        assert_eq!(
            wave.coupled_noted,
            vec!["s1".to_string()],
            "the batch's abi=should member is noted, never forced"
        );
    }

    #[test]
    fn additions_and_uncovered_partition_against_the_plan() {
        let records = dag();
        let graph = Graph::build(&records).unwrap();
        let mut subs = Subscriptions::empty();
        subs.upsert(sub("c0", "p", "T2"));
        subs.upsert(sub("c1", "p", "T1"));
        let mut planned = BTreeSet::new();
        planned.insert("c1".to_string());
        let plan = plan_waves(&WaveInputs {
            graph: &graph,
            subs: &subs,
            moves: &[mv("p", "T2", Some("T1"))],
            installed: None,
            planned: &planned,
        });
        // c1 is planned (covered); c2 is buildable → added to the plan.
        assert_eq!(plan.additions, vec!["c2".to_string()]);
        assert!(plan.uncovered.is_empty());
        assert!(plan.refusal_rows().is_empty());
    }

    #[test]
    fn content_truth_seeds_join_and_out_of_tree_consumers_refuse() {
        use crate::view::{InstalledPkg, InstalledView};
        let records = dag();
        let graph = Graph::build(&records).unwrap();
        let mut subs = Subscriptions::empty();
        let installed = InstalledView::new([InstalledPkg {
            name: "consumer-out-of-tree".to_string(),
            version: "0:1-1".to_string(),
            provides: Vec::new(),
            depends: Vec::new(),
            files: Vec::new(),
        }]);
        let planned = BTreeSet::new();
        // A record-mismatch subscriber unknown to the topology cannot be
        // built this run → the named under-coverage refusal (§E.3).
        subs.upsert(sub("consumer-out-of-tree", "p", "T1"));
        let movement = TokenMove {
            provider: "p".to_string(),
            old: Some("T1".to_string()),
            new: "T2".to_string(),
            changed_provides: vec!["libfoo.so".to_string()],
        };
        let plan = plan_waves(&WaveInputs {
            graph: &graph,
            subs: &subs,
            moves: &[movement],
            installed: Some(&installed),
            planned: &planned,
        });
        assert_eq!(
            plan.uncovered,
            vec![("p".to_string(), vec!["consumer-out-of-tree".to_string()])]
        );
        let rows = plan.refusal_rows();
        assert_eq!(rows.len(), 1);
        assert_eq!(
            rows[0].render(),
            "consumer-out-of-tree refuse abi-consumer-uncovered p"
        );
    }

    #[test]
    fn staged_swap_is_one_transaction_per_wave_and_refuses_under_coverage() {
        use std::path::PathBuf;
        let wave = Wave {
            provider: "p".to_string(),
            members: vec![
                WaveMember {
                    id: "c1".to_string(),
                    basis: MemberBasis::Recorded,
                },
                WaveMember {
                    id: "c2".to_string(),
                    basis: MemberBasis::Closure,
                },
            ],
            coupled_noted: Vec::new(),
            fallback: false,
        };
        let archives = BTreeMap::from([
            ("p".to_string(), PathBuf::from("/a/p.pkg.tar.zst")),
            ("c1".to_string(), PathBuf::from("/a/c1.pkg.tar.zst")),
            ("c2".to_string(), PathBuf::from("/a/c2.pkg.tar.zst")),
        ]);
        let plan = stage_swap(&[wave.clone()], &|id| archives.get(id).cloned());
        assert_eq!(
            plan.transactions,
            vec![vec![
                PathBuf::from("/a/p.pkg.tar.zst"),
                PathBuf::from("/a/c1.pkg.tar.zst"),
                PathBuf::from("/a/c2.pkg.tar.zst"),
            ]],
            "ONE transaction carrying every wave archive"
        );
        assert!(plan.refusals.is_empty());

        // A member with no archive refuses named and holds the wave back.
        let mut partial = archives.clone();
        partial.remove("c2");
        let plan = stage_swap(&[wave], &|id| partial.get(id).cloned());
        assert!(plan.transactions.is_empty(), "never half a wave");
        assert_eq!(plan.refusals.len(), 1);
        assert_eq!(
            plan.refusals[0].render(),
            "c2 refuse abi-consumer-uncovered p"
        );
    }
}
