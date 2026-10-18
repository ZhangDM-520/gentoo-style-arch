//! The dispatch state machine: build-order readiness, the lane capacity and
//! core-solo invariants, and the failure policy (contract §I) as pure state
//! transitions. Process spawning lives in `supervisor`; everything a fixture
//! or a property test asserts about *which package ends in which state* is
//! decided here.
//!
//! Vocabulary (CONTEXT.md): the nodes are recipes, `prereqs` are build-order
//! edges (a record consumes each of its edges' recipes), `consumers` is the
//! reverse closure, and parking a package's *consumer cone* is the default
//! failure policy (§I.1).

use gsa_model::{LaneOutcome, OutcomeRow, RecipeId, RowStatus};

/// The failure policy (contract §I). Cone-stop is the default everywhere.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Policy {
    /// A failure parks the failed package's transitive consumer cone
    /// (row reason `waits-on-failed`, contract §H.3) and its coupled batch
    /// mates (reason `coupled-batch`); dispatch continues with unrelated
    /// work (§I.1).
    ConeStop,
    /// `--fail-fast`: the first failure stops new dispatch, in-flight lanes
    /// drain, unstarted packages become `never-started dispatch-stopped` (§I.3).
    FailFast,
}

/// One schedulable node (a recipe inside the selection).
#[derive(Clone, Debug)]
pub struct Node {
    pub id: RecipeId,
    /// Build-order edges resolved to node indices inside the selection.
    pub prereqs: Vec<usize>,
    /// Reverse build-order edges inside the selection.
    pub consumers: Vec<usize>,
    /// `core` membership: runs alone with the core job budget (§K.2).
    pub core: bool,
    /// `build-tools` band membership: dispatches before other ready packages,
    /// never over build-order edges (§K.2).
    pub build_tools: bool,
    /// Coupled-batch index (`abi=must`/`abi=should`), if any.
    pub batch: Option<usize>,
    /// A remediation-latent node (toolchain remediation, owner rule
    /// 2026-10-02): carried from run start but never dispatched unless
    /// [`Machine::activate`] promotes it. A latent node that was never
    /// activated has NO run-record row and NO `order` entry.
    pub latent: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum State {
    /// Latent (never activated) — settled for `finished()`, absent from
    /// `rows()`/`order()`.
    Latent,
    Pending,
    Dispatched,
    Done(RowStatus, Option<i32>, Option<i64>, String),
}

/// One recorded lane result, already decoded through the codec.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Recorded {
    pub code: LaneOutcome,
    pub dur: Option<i64>,
    pub reason: String,
}

/// Where a node stands in the dispatch machine, as the prefetch window
/// (plan.md §2.1) sees it: pending (still to build), dispatched (started),
/// or settled with its run-record status.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NodePhase {
    Pending,
    Dispatched,
    Settled(RowStatus),
}

/// A lane that should stand down before building (contract §F.1 `parked 98`):
/// the supervisor writes a park marker the spawned child checks before it
/// execs makepkg.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParkRequest {
    pub index: usize,
    pub reason: String,
}

pub struct Machine {
    nodes: Vec<Node>,
    batches: Vec<Vec<usize>>,
    policy: Policy,
    lanes: usize,
    states: Vec<State>,
    active: usize,
    core_running: bool,
    stop_dispatch: bool,
    /// The toolchain-remediation restrict set (node indices, chain order):
    /// while set, ONLY these nodes dispatch and [`Machine::pick`] answers in
    /// list order — force semantics for a mid-run rebuild chain.
    restrict: Option<Vec<usize>>,
}

impl Machine {
    pub fn new(
        mut nodes: Vec<Node>,
        batches: Vec<Vec<usize>>,
        policy: Policy,
        lanes: usize,
    ) -> Machine {
        // Coupled-batch policy must key off the batches table itself: the
        // table is what callers compute from the topology tags, and a node
        // whose `batch` index was left unfilled would silently escape its
        // mate-parking duty (the park handshake then never reaches its
        // in-flight lane at all).
        for (batch, members) in batches.iter().enumerate() {
            for &member in members {
                if nodes[member].batch.is_none() {
                    nodes[member].batch = Some(batch);
                }
            }
        }
        let states = nodes
            .iter()
            .map(|node| {
                if node.latent {
                    State::Latent
                } else {
                    State::Pending
                }
            })
            .collect();
        Machine {
            nodes,
            batches,
            policy,
            lanes: lanes.max(1),
            states,
            active: 0,
            core_running: false,
            stop_dispatch: false,
            restrict: None,
        }
    }

    pub fn len(&self) -> usize {
        self.nodes.len()
    }

    pub fn is_empty(&self) -> bool {
        self.nodes.is_empty()
    }

    pub fn node(&self, index: usize) -> &Node {
        &self.nodes[index]
    }

    /// The node's phase for the prefetch window (plan.md §2.1: the
    /// dispatcher is the only brain — the window is derived from this).
    /// A never-activated latent node reads as settled (it is never
    /// prefetched and never dispatchable).
    pub fn node_phase(&self, index: usize) -> NodePhase {
        match &self.states[index] {
            State::Latent => NodePhase::Settled(RowStatus::NeverStarted),
            State::Pending => NodePhase::Pending,
            State::Dispatched => NodePhase::Dispatched,
            State::Done(status, ..) => NodePhase::Settled(*status),
        }
    }

    pub fn policy(&self) -> Policy {
        self.policy
    }

    pub fn active(&self) -> usize {
        self.active
    }

    /// Every node has a terminal outcome (a latent node that was never
    /// activated is settled by construction — it has no run to settle).
    pub fn finished(&self) -> bool {
        self.active == 0
            && self
                .states
                .iter()
                .all(|s| matches!(s, State::Done(..) | State::Latent))
    }

    fn is_done_ok(&self, index: usize) -> bool {
        matches!(&self.states[index], State::Done(RowStatus::Succeeded, ..))
    }

    fn is_terminal(&self, index: usize) -> bool {
        matches!(self.states[index], State::Done(..))
    }

    /// Whether the node is a never-activated remediation latent.
    pub fn is_latent(&self, index: usize) -> bool {
        matches!(self.states[index], State::Latent)
    }

    /// Whether the node has settled (any outcome).
    pub fn is_settled(&self, index: usize) -> bool {
        self.is_terminal(index)
    }

    /// Whether one build-order edge is satisfied. Normal dispatch: the
    /// prerequisite settled successfully. Under the remediation restrict
    /// set (force semantics): an in-chain prerequisite only has to settle —
    /// its rebuild outcome is the remediation monitor's business — while an
    /// out-of-chain prerequisite never gates a chain member at all: the
    /// selection contract assumes prerequisites installed and current (§C),
    /// so a force rebuild jumps the queue instead of waiting on an upstream
    /// cone that is itself queued for rebuild (2026-10-18: rust-git's nine
    /// queued prereqs made `pick()` empty and the remediation stalled and
    /// refused — the documented recovery was unreachable on a large run).
    fn prereq_clear(&self, consumer: usize, prereq: usize) -> bool {
        match &self.restrict {
            Some(chain) if chain.contains(&prereq) => self.is_terminal(prereq),
            Some(chain) if chain.contains(&consumer) => true,
            _ => self.is_done_ok(prereq),
        }
    }

    /// Ready nodes: every build-order edge inside the selection is clear.
    fn ready(&self) -> Vec<usize> {
        (0..self.nodes.len())
            .filter(|&i| {
                if !matches!(self.states[i], State::Pending) || self.stop_dispatch {
                    return false;
                }
                self.nodes[i]
                    .prereqs
                    .iter()
                    .all(|&p| self.prereq_clear(i, p))
            })
            .collect()
    }

    /// Dispatch preference: `build-tools` band members first, then canonical
    /// build order — the band changes *when* a ready package dispatches and
    /// never the order the record reports (§K.2, §C.5). Under the
    /// remediation restrict set the pick is the chain's own order and only
    /// chain members (fish `pick_next_ready` force mode).
    pub fn pick(&self) -> Vec<usize> {
        let mut ready = self.ready();
        if let Some(chain) = &self.restrict {
            return chain
                .iter()
                .copied()
                .filter(|index| ready.contains(index))
                .collect();
        }
        ready.sort_by_key(|&i| (!self.nodes[i].build_tools, i));
        ready
    }

    /// Whether another lane may start right now: capacity, plus the core
    /// invariants — a `core` member runs alone (nothing else dispatches while
    /// one runs) and only starts on an idle machine (§K.2).
    pub fn can_dispatch(&self, index: usize) -> bool {
        if self.stop_dispatch || self.active >= self.lanes {
            return false;
        }
        if self.nodes[index].core {
            return self.active == 0;
        }
        !self.core_running
    }

    /// Mark a node dispatched (its lane child is spawning).
    pub fn dispatch(&mut self, index: usize) {
        assert!(
            matches!(self.states[index], State::Pending),
            "dispatch of a non-pending node"
        );
        self.states[index] = State::Dispatched;
        self.active += 1;
        if self.nodes[index].core {
            self.core_running = true;
        }
    }

    /// Transitive consumer cone of one node, inside the selection (contract
    /// §I.1: "the transitive closure of its consumers over build-order
    /// edges"). The node itself is NOT in its own cone.
    pub fn consumer_cone(&self, index: usize) -> Vec<usize> {
        let mut seen = vec![false; self.nodes.len()];
        let mut out = Vec::new();
        let mut queue: Vec<usize> = self.nodes[index].consumers.clone();
        while let Some(node) = queue.pop() {
            if seen[node] {
                continue;
            }
            seen[node] = true;
            out.push(node);
            for &next in &self.nodes[node].consumers {
                if !seen[next] {
                    queue.push(next);
                }
            }
        }
        out.sort_unstable();
        out
    }

    fn park_one(&mut self, index: usize, reason: &str, requests: &mut Vec<ParkRequest>) {
        match &self.states[index] {
            // A latent node is not part of the run's cone traffic: it stays
            // latent and only enters the run through `activate`.
            State::Latent => {}
            State::Pending => {
                self.states[index] = State::Done(RowStatus::Parked, None, None, reason.to_string());
            }
            State::Dispatched => {
                // Spawn-to-build race: the lane child has not started its
                // build yet; tell it to stand down (contract §F.1 `parked 98`).
                requests.push(ParkRequest {
                    index,
                    reason: reason.to_string(),
                });
            }
            State::Done(..) => {}
        }
    }

    /// Park a whole event closure: the roots plus everything transitively
    /// consuming them, each keeping the event's reason. Already-terminal
    /// packages stand (in-flight lanes drain and their outcomes stand, §I.2).
    fn park_event(&mut self, roots: &[usize], reason: &str, requests: &mut Vec<ParkRequest>) {
        let mut closure: Vec<usize> = Vec::new();
        for &root in roots {
            closure.push(root);
            closure.extend(self.consumer_cone(root));
        }
        closure.sort_unstable();
        closure.dedup();
        for index in closure {
            self.park_one(index, reason, requests);
        }
    }

    /// Record one lane outcome and apply the failure policy. Returns the
    /// stand-down requests for lanes that were spawned but not yet building.
    pub fn record(&mut self, index: usize, recorded: Recorded) -> Vec<ParkRequest> {
        self.record_with_policy(index, recorded, true)
    }

    /// Record one lane outcome the interrupt teardown settled (§I.3). The
    /// row lands exactly once, but the failure policy never parks a cone
    /// here: what never launched must settle as `never-started
    /// interrupted-before-start`, never as `waits-on-failed`.
    pub fn record_teardown(&mut self, index: usize, recorded: Recorded) {
        self.record_with_policy(index, recorded, false);
    }

    fn record_with_policy(
        &mut self,
        index: usize,
        recorded: Recorded,
        apply_policy: bool,
    ) -> Vec<ParkRequest> {
        assert!(
            matches!(self.states[index], State::Dispatched),
            "record for a node that is not dispatched"
        );
        self.active -= 1;
        if self.nodes[index].core {
            self.core_running = false;
        }
        let mut requests = Vec::new();
        let Recorded { code, dur, reason } = recorded;
        let (status, rc, reason) = match code {
            LaneOutcome::Ok => (RowStatus::Succeeded, Some(0), reason),
            LaneOutcome::Failed => (RowStatus::Failed, Some(1), reason),
            LaneOutcome::Lost => (RowStatus::Failed, Some(125), reason),
            LaneOutcome::Parked => (RowStatus::Parked, Some(98), reason),
            LaneOutcome::Defer => (RowStatus::Deferred, Some(99), reason),
            LaneOutcome::Hup => (RowStatus::Interrupted, Some(129), reason),
            LaneOutcome::Int => (RowStatus::Interrupted, Some(130), reason),
            LaneOutcome::Term => (RowStatus::Interrupted, Some(143), reason),
        };
        self.states[index] = State::Done(status, rc, dur, reason);

        match status {
            _ if !apply_policy => {}
            RowStatus::Failed => {
                if self.policy == Policy::FailFast {
                    self.stop_dispatch = true;
                } else {
                    // Cone-stop (§I.1): park the failed package's consumer
                    // cone, then its coupled batch mates and their cones
                    // (contract open decision 1, recommendation adopted).
                    let cone = self.consumer_cone(index);
                    self.park_event(&cone, "waits-on-failed", &mut requests);
                    if let Some(batch) = self.nodes[index].batch {
                        let mates: Vec<usize> = self.batches[batch]
                            .iter()
                            .copied()
                            .filter(|&m| m != index && !self.is_terminal(m))
                            .collect();
                        self.park_event(&mates, "coupled-batch", &mut requests);
                    }
                }
            }
            RowStatus::Deferred => {
                // Deferral is independent of the policy (§I.3): it parks only
                // the deferring package's dependents, and dispatch continues
                // with unrelated work even under --fail-fast.
                let cone = self.consumer_cone(index);
                self.park_event(&cone, "waits-on-deferred", &mut requests);
            }
            _ => {}
        }
        requests
    }

    /// Record one pre-dispatch settlement (contract §B.8): a `--skip` claim
    /// (`succeeded - - <reason>`) or a pre-dispatch deferral (`deferred 99 -
    /// <reason>`, whose cone parks `waits-on-deferred` like any deferral).
    /// The node was never dispatched, so the lane accounting never engaged;
    /// the failure policy still applies to `Failed`/`Deferred`.
    pub fn record_pre(
        &mut self,
        index: usize,
        status: RowStatus,
        rc: Option<i32>,
        reason: &str,
    ) -> Vec<ParkRequest> {
        assert!(
            matches!(self.states[index], State::Pending),
            "pre-dispatch settlement for a node that is not pending"
        );
        let mut requests = Vec::new();
        self.states[index] = State::Done(status, rc, None, reason.to_string());
        match status {
            RowStatus::Failed => {
                if self.policy == Policy::FailFast {
                    self.stop_dispatch = true;
                } else {
                    let cone = self.consumer_cone(index);
                    self.park_event(&cone, "waits-on-failed", &mut requests);
                    if let Some(batch) = self.nodes[index].batch {
                        let mates: Vec<usize> = self.batches[batch]
                            .iter()
                            .copied()
                            .filter(|&m| m != index && !self.is_terminal(m))
                            .collect();
                        self.park_event(&mates, "coupled-batch", &mut requests);
                    }
                }
            }
            RowStatus::Deferred => {
                let cone = self.consumer_cone(index);
                self.park_event(&cone, "waits-on-deferred", &mut requests);
            }
            _ => {}
        }
        requests
    }

    /// Make a latent remediation node schedulable (owner rule 2026-10-02).
    pub fn activate(&mut self, index: usize) {
        assert!(
            matches!(self.states[index], State::Latent),
            "activate of a non-latent node"
        );
        self.states[index] = State::Pending;
    }

    /// Re-dispatch a node that already settled (the remediation force
    /// rebuild IS the point, fish `pick_next_ready` force mode). The row is
    /// replaced by the new outcome and the node keeps its position in the
    /// run-record order.
    pub fn force_rebuild(&mut self, index: usize) {
        assert!(
            self.is_terminal(index),
            "force_rebuild of a node that has not settled"
        );
        self.states[index] = State::Pending;
    }

    /// Restrict dispatch to one remediation chain (node indices, chain
    /// order — [`pick`](Self::pick) answers in that order) or lift the
    /// restriction (`None`).
    pub fn set_restrict(&mut self, chain: Option<Vec<usize>>) {
        self.restrict = chain;
    }

    /// Halt new dispatch — the fail-fast stop, reached either by the
    /// `--fail-fast` failure policy or by an install-step `Halt` that asks
    /// for it (§K.3: a credential lost mid-run stops dispatch exactly once).
    /// Idempotent; in-flight lanes keep draining (§I.2).
    pub fn stop_dispatch(&mut self) {
        self.stop_dispatch = true;
    }

    /// Drain end of a `--fail-fast` run: unstarted packages become
    /// `never-started dispatch-stopped` (§I.3).
    pub fn finalize_stopped(&mut self) {
        for state in &mut self.states {
            if matches!(state, State::Pending) {
                *state = State::Done(
                    RowStatus::NeverStarted,
                    None,
                    None,
                    "dispatch-stopped".to_string(),
                );
            }
        }
    }

    /// Interrupt teardown (§I.3): what started is `interrupted
    /// interrupted-mid-build`, what never launched is `never-started
    /// interrupted-before-start`. `signal_code` is the lane-code-class code of
    /// the signal that tore the run down (129/130/143).
    pub fn finalize_interrupted(&mut self, signal_code: i32) {
        for state in &mut self.states {
            match state {
                State::Latent => {}
                State::Pending => {
                    *state = State::Done(
                        RowStatus::NeverStarted,
                        None,
                        None,
                        "interrupted-before-start".to_string(),
                    );
                }
                State::Dispatched => {
                    *state = State::Done(
                        RowStatus::Interrupted,
                        Some(signal_code),
                        None,
                        "interrupted-mid-build".to_string(),
                    );
                }
                State::Done(..) => {}
            }
        }
    }

    /// Backstop for a drained machine that somehow left pending nodes.
    pub fn finalize_never_ready(&mut self) {
        for state in &mut self.states {
            if matches!(state, State::Pending) {
                *state = State::Done(
                    RowStatus::NeverStarted,
                    None,
                    None,
                    "never-ready".to_string(),
                );
            }
        }
    }

    /// Outcome rows in node (= topological) order — one row per package the
    /// run actually carried (contract §H.2). A latent node that was never
    /// activated has no row.
    pub fn rows(&self) -> Vec<OutcomeRow> {
        self.nodes
            .iter()
            .zip(&self.states)
            .filter(|(_, state)| !matches!(state, State::Latent))
            .map(|(node, state)| match state {
                State::Done(status, rc, dur, reason) => OutcomeRow {
                    pkg: node.id.clone(),
                    status: *status,
                    rc: *rc,
                    dur: *dur,
                    reason: reason.clone(),
                },
                State::Pending | State::Dispatched => OutcomeRow {
                    pkg: node.id.clone(),
                    status: RowStatus::NeverStarted,
                    rc: None,
                    dur: None,
                    reason: "never-ready".to_string(),
                },
                State::Latent => unreachable!("filtered above"),
            })
            .collect()
    }

    /// The run-record `order` (contract §H.2): the carried nodes' ids in
    /// node order — the selection's ids plus the remediation latents that
    /// were ACTIVATED (appended after the selection at setup time, fish
    /// `_RR_ORDER`).
    pub fn order(&self) -> Vec<RecipeId> {
        self.nodes
            .iter()
            .zip(&self.states)
            .filter(|(_, state)| !matches!(state, State::Latent))
            .map(|(node, _)| node.id.clone())
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Tiny xorshift so the DAG property test needs no external crate.
    struct Rng(u64);
    impl Rng {
        fn next(&mut self) -> u64 {
            let mut x = self.0;
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            self.0 = x;
            x
        }
        fn below(&mut self, n: u64) -> u64 {
            self.next() % n.max(1)
        }
    }

    fn id(s: &str) -> RecipeId {
        RecipeId::new(s).unwrap()
    }

    /// Build nodes from an adjacency list of prereqs (indices).
    fn nodes_from(prereqs: &[Vec<usize>]) -> Vec<Node> {
        let mut consumers = vec![Vec::new(); prereqs.len()];
        for (i, ps) in prereqs.iter().enumerate() {
            for &p in ps {
                consumers[p].push(i);
            }
        }
        (0..prereqs.len())
            .map(|i| Node {
                id: id(&format!("pkg{i}")),
                prereqs: prereqs[i].clone(),
                consumers: consumers[i].clone(),
                core: false,
                build_tools: false,
                batch: None,
                latent: false,
            })
            .collect()
    }

    /// Run a machine to completion with a scripted outcome per node
    /// (`None` = succeed) and return the final rows.
    fn run_to_completion(
        prereqs: &[Vec<usize>],
        policy: Policy,
        fails: &[usize],
        defers: &[usize],
    ) -> Vec<OutcomeRow> {
        let nodes = nodes_from(prereqs);
        let mut m = Machine::new(nodes, Vec::new(), policy, 4);
        loop {
            if m.finished() {
                break;
            }
            let pick = m.pick().into_iter().find(|&i| m.can_dispatch(i));
            let Some(index) = pick else {
                // No capacity/ready work and nothing active: settle.
                if m.active() == 0 {
                    if policy == Policy::FailFast {
                        m.finalize_stopped();
                    } else {
                        m.finalize_never_ready();
                    }
                }
                break;
            };
            m.dispatch(index);
            let recorded = if fails.contains(&index) {
                Recorded {
                    code: LaneOutcome::Failed,
                    dur: Some(1),
                    reason: "build-failed".to_string(),
                }
            } else if defers.contains(&index) {
                Recorded {
                    code: LaneOutcome::Defer,
                    dur: Some(1),
                    reason: "source-unfetchable".to_string(),
                }
            } else {
                Recorded {
                    code: LaneOutcome::Ok,
                    dur: Some(1),
                    reason: "ok".to_string(),
                }
            };
            for req in m.record(index, recorded) {
                panic!("unexpected stand-down request: {req:?}");
            }
        }
        m.rows()
    }

    #[test]
    fn readiness_follows_build_order_edges() {
        // 0 -> 1 -> 2 chain plus free 3.
        let prereqs = vec![vec![], vec![0], vec![1], vec![]];
        let rows = run_to_completion(&prereqs, Policy::ConeStop, &[], &[]);
        assert!(rows.iter().all(|r| r.status == RowStatus::Succeeded));
    }

    #[test]
    fn cone_stop_parks_exactly_the_consumer_cone() {
        // diamond: 0 -> {1,2} -> 3, plus free 4.
        let prereqs = vec![vec![], vec![0], vec![0], vec![1, 2], vec![]];
        let rows = run_to_completion(&prereqs, Policy::ConeStop, &[0], &[]);
        let by = |p: &str| rows.iter().find(|r| r.pkg == id(p)).unwrap().clone();
        assert_eq!(by("pkg0").status, RowStatus::Failed);
        assert_eq!(by("pkg1").status, RowStatus::Parked);
        assert_eq!(by("pkg1").reason, "waits-on-failed");
        assert_eq!(by("pkg2").status, RowStatus::Parked);
        assert_eq!(by("pkg3").status, RowStatus::Parked);
        // The unrelated package keeps building: cone-stop continues dispatch.
        assert_eq!(by("pkg4").status, RowStatus::Succeeded);
    }

    #[test]
    fn fail_fast_stops_dispatch_and_drains_in_flight() {
        // Two free roots; the first fails while the second is in flight.
        let prereqs = vec![vec![], vec![], vec![0]];
        let nodes = nodes_from(&prereqs);
        let mut m = Machine::new(nodes, Vec::new(), Policy::FailFast, 2);
        m.dispatch(0);
        m.dispatch(1); // in flight — drains, its outcome stands
        m.record(
            0,
            Recorded {
                code: LaneOutcome::Failed,
                dur: Some(1),
                reason: "build-failed".into(),
            },
        );
        assert!(m.pick().is_empty(), "fail-fast must stop new dispatch");
        m.record(
            1,
            Recorded {
                code: LaneOutcome::Ok,
                dur: Some(1),
                reason: "ok".into(),
            },
        );
        m.finalize_stopped();
        let rows = m.rows();
        assert_eq!(rows[0].status, RowStatus::Failed);
        assert_eq!(
            rows[1].status,
            RowStatus::Succeeded,
            "in-flight lane drains"
        );
        assert_eq!(rows[2].status, RowStatus::NeverStarted);
        assert_eq!(rows[2].reason, "dispatch-stopped");
    }

    #[test]
    fn deferral_is_not_a_failure_and_not_a_cone_stop() {
        // Deferral parks only the deferring package's dependents and never
        // fails the run: unrelated work runs in BOTH policies (§I.3).
        for policy in [Policy::ConeStop, Policy::FailFast] {
            let prereqs = vec![vec![], vec![0], vec![]];
            let rows = run_to_completion(&prereqs, policy, &[], &[0]);
            assert_eq!(rows[0].status, RowStatus::Deferred);
            assert_eq!(rows[0].rc, Some(99));
            assert_eq!(rows[1].status, RowStatus::Parked);
            assert_eq!(rows[1].reason, "waits-on-deferred");
            assert_eq!(rows[2].status, RowStatus::Succeeded);
        }
    }

    #[test]
    fn coupled_batch_mates_park_with_their_cones() {
        // 0 and 1 are batch mates (no edge between them); 2 consumes 1.
        let prereqs = vec![vec![], vec![], vec![1]];
        let mut nodes = nodes_from(&prereqs);
        nodes[0].batch = Some(0);
        nodes[1].batch = Some(0);
        let mut m = Machine::new(nodes, vec![vec![0, 1]], Policy::ConeStop, 4);
        loop {
            if m.finished() {
                break;
            }
            let Some(index) = m.pick().into_iter().find(|&i| m.can_dispatch(i)) else {
                break;
            };
            m.dispatch(index);
            let recorded = if index == 0 {
                Recorded {
                    code: LaneOutcome::Failed,
                    dur: Some(1),
                    reason: "build-failed".into(),
                }
            } else {
                Recorded {
                    code: LaneOutcome::Ok,
                    dur: Some(1),
                    reason: "ok".into(),
                }
            };
            m.record(index, recorded);
        }
        let rows = m.rows();
        assert_eq!(rows[0].status, RowStatus::Failed);
        if rows[1].status == RowStatus::Succeeded {
            // Mate built before the failure landed: its outcome stands (§I.2).
            assert_eq!(rows[2].status, RowStatus::Succeeded);
        } else {
            assert_eq!(rows[1].status, RowStatus::Parked);
            assert_eq!(rows[1].reason, "coupled-batch");
            assert_eq!(rows[2].status, RowStatus::Parked);
            assert_eq!(rows[2].reason, "coupled-batch");
        }
    }

    #[test]
    fn restrict_force_dispatch_jumps_queued_out_of_chain_prereqs() {
        // Remediation force semantics (2026-10-18): a chain member's
        // out-of-chain prerequisites never gate it — the contract assumes
        // prerequisites installed and current (§C), and on a large run those
        // prereqs are themselves queued for rebuild, so waiting on them made
        // `pick()` empty and the remediation stall and refuse.
        let prereqs = vec![vec![], vec![0], vec![1]];
        let nodes = nodes_from(&prereqs);
        let mut m = Machine::new(nodes, Vec::new(), Policy::ConeStop, 4);
        m.set_restrict(Some(vec![1]));
        assert_eq!(
            m.pick(),
            vec![1],
            "the chain member must be dispatchable while its out-of-chain prereq is still queued"
        );
        m.dispatch(1);
        assert_eq!(
            m.pick(),
            Vec::<usize>::new(),
            "only the chain dispatches while the restrict set is active"
        );
    }

    #[test]
    fn restrict_in_chain_prereq_still_settles_before_its_consumer() {
        // Force semantics jump the QUEUE, not the chain's own order: an
        // in-chain prerequisite must settle before its in-chain consumer.
        let prereqs = vec![vec![], vec![0]];
        let nodes = nodes_from(&prereqs);
        let mut m = Machine::new(nodes, Vec::new(), Policy::ConeStop, 4);
        m.set_restrict(Some(vec![0, 1]));
        assert_eq!(
            m.pick(),
            vec![0],
            "the in-chain prerequisite settles first even under force semantics"
        );
    }

    #[test]
    fn interrupt_rows_split_started_from_never_started() {
        let prereqs = vec![vec![], vec![], vec![0]];
        let nodes = nodes_from(&prereqs);
        let mut m = Machine::new(nodes, Vec::new(), Policy::ConeStop, 2);
        m.dispatch(0);
        m.dispatch(1);
        m.finalize_interrupted(130);
        let rows = m.rows();
        assert_eq!(rows[0].status, RowStatus::Interrupted);
        assert_eq!(rows[0].rc, Some(130));
        assert_eq!(rows[0].reason, "interrupted-mid-build");
        assert_eq!(rows[2].status, RowStatus::NeverStarted);
        assert_eq!(rows[2].reason, "interrupted-before-start");
    }

    #[test]
    fn random_dag_cone_stop_parks_exactly_the_consumer_cone() {
        // Property (contract §I.1): for any DAG and any failing set, the
        // parked set is EXACTLY the transitive consumer cone of the packages
        // that actually failed, and everything else completes.
        let mut rng = Rng(0x5EED_1234_ABCD);
        for round in 0..200 {
            let n = 3 + rng.below(12) as usize;
            let mut prereqs: Vec<Vec<usize>> = vec![Vec::new(); n];
            for j in 1..n {
                for i in 0..j {
                    if rng.below(3) == 0 {
                        prereqs[j].push(i);
                    }
                }
            }
            // Fail a random non-empty subset; only failures that can actually
            // dispatch count (a downstream node of a failure never builds).
            let mut fail_set: Vec<usize> = Vec::new();
            for i in 0..n {
                if rng.below(4) == 0 {
                    fail_set.push(i);
                }
            }
            if fail_set.is_empty() {
                fail_set.push(rng.below(n as u64) as usize);
            }
            let rows = run_to_completion(&prereqs, Policy::ConeStop, &fail_set, &[]);

            // Expected: closure over consumers of the failures that really ran
            // (failed rows), minus failed rows themselves.
            let consumers = |i: usize| -> Vec<usize> {
                let mut seen = vec![false; n];
                let mut out = Vec::new();
                let mut queue = vec![i];
                while let Some(node) = queue.pop() {
                    for (j, ps) in prereqs.iter().enumerate() {
                        if ps.contains(&node) && !seen[j] {
                            seen[j] = true;
                            out.push(j);
                            queue.push(j);
                        }
                    }
                }
                out
            };
            let really_failed: Vec<usize> = rows
                .iter()
                .enumerate()
                .filter(|(_, r)| r.status == RowStatus::Failed)
                .map(|(i, _)| i)
                .collect();
            let mut expected: Vec<usize> = Vec::new();
            for &f in &really_failed {
                expected.extend(consumers(f));
            }
            expected.sort_unstable();
            expected.dedup();
            let mut parked: Vec<usize> = rows
                .iter()
                .enumerate()
                .filter(|(_, r)| r.status == RowStatus::Parked)
                .map(|(i, _)| i)
                .collect();
            parked.sort_unstable();
            assert_eq!(
                parked, expected,
                "round {round}: prereqs {prereqs:?} fails {fail_set:?} rows {rows:?}"
            );
            for (i, row) in rows.iter().enumerate() {
                if row.status == RowStatus::Parked {
                    assert_eq!(row.reason, "waits-on-failed");
                }
                if !expected.contains(&i) && !really_failed.contains(&i) {
                    assert_eq!(
                        row.status,
                        RowStatus::Succeeded,
                        "round {round}: node {i} must complete"
                    );
                }
            }
        }
    }
}
