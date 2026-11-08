//! `progress` — the ONE fold of the supervisor's event stream into the run's
//! plan order and settled rows (contract §H, the one-record rule).
//!
//! The live dashboard (§L.5) and the run record (§H) are two renderings of
//! one structure: this projection. The dashboard used to keep its own
//! counters folded by hand from the same events and drifted once — a
//! `--leaf` one-package install run rendered `1/332` because the box counted
//! the never-activated remediation latent pool (2026-11-03). Every tally here
//! is DERIVED — the total from [`Progress::order`], the settled counts from
//! [`Progress::rows`] — so no counter can disagree with the rows the record
//! renders.
//!
//! What the fold can see is what the supervisor emits: a lane's `Started`
//! (and a latent's activation through it), its `Finished`, and a stand-down
//! `Parked`. The machine also settles carried packages backstage — a pending
//! node parks under the failure policy, and the `finalize_*` passes settle
//! what never dispatched — so those rows are record-only by construction.
//! [`Progress::drift`] states exactly what must hold between the projection
//! and the record.

use std::collections::{BTreeMap, BTreeSet};

use gsa_model::{OutcomeRow, RecipeId, RowStatus};

use crate::supervisor::SupEvent;

/// The run as the live view sees it: plan order plus settled rows, folded
/// from [`SupEvent`]s — one settlement per package, one plan slot per node.
///
/// I/O-free and deterministic: the same event stream always folds to the
/// same order and rows, which is what lets the dashboard assert the equality
/// and the record neither know nor care that a view exists.
#[derive(Clone, Debug)]
pub struct Progress {
    /// Every carried node in run order, latent slots included (the machine's
    /// node order — the `Started` index addresses this list).
    plan: Vec<RecipeId>,
    /// The plan slot of every id (the settlement ordering key).
    slot: BTreeMap<RecipeId, usize>,
    /// The latent pool: ids that join the run only when activated.
    latents: BTreeSet<RecipeId>,
    /// The run's visible order (§H `order`): the plan minus the latents that
    /// were never activated. A latent joins at its plan slot the first time
    /// it was activated (`Started`).
    order: Vec<RecipeId>,
    /// Settled rows in plan order — one per package, the row the record
    /// carries for it. A re-settlement (the remediation force rebuild)
    /// replaces the package's row in place; it never adds one.
    rows: Vec<OutcomeRow>,
    /// Packages that were dispatched at least once.
    dispatched: BTreeSet<RecipeId>,
}

impl Progress {
    /// Plan order is the carried node list (`ids`, latents included);
    /// `latents` names the nodes that are held out of the run's total until
    /// an activation dispatches them.
    pub fn new(ids: Vec<RecipeId>, latents: Vec<RecipeId>) -> Self {
        let slot: BTreeMap<RecipeId, usize> = ids
            .iter()
            .enumerate()
            .map(|(i, id)| (id.clone(), i))
            .collect();
        let latents: BTreeSet<RecipeId> = latents.into_iter().collect();
        let order = ids
            .iter()
            .filter(|id| !latents.contains(*id))
            .cloned()
            .collect();
        Progress {
            plan: ids,
            slot,
            latents,
            order,
            rows: Vec::new(),
            dispatched: BTreeSet::new(),
        }
    }

    /// Fold one supervisor event. The only inputs are the event vocabulary:
    /// an activation (or any dispatch) through `Started`, a settlement
    /// through `Finished`, a stand-down through `Parked`.
    pub fn observe(&mut self, event: &SupEvent) {
        match event {
            SupEvent::Started { index, .. } => self.started(*index),
            SupEvent::Finished { row, .. } => self.settled(row.clone()),
            SupEvent::Parked { index, reason } => {
                if let Some(id) = self.plan.get(*index).cloned() {
                    // A stand-down settles a package the machine parked
                    // before its lane ever produced a result row; a lane
                    // that does publish one replaces this row in place.
                    self.settled(OutcomeRow {
                        pkg: id,
                        status: RowStatus::Parked,
                        rc: None,
                        dur: None,
                        reason: reason.clone(),
                    });
                }
            }
            _ => {}
        }
    }

    /// The node id at a supervisor index (the `Started`/`Parked` address).
    pub fn pkg(&self, index: usize) -> Option<&RecipeId> {
        self.plan.get(index)
    }

    /// This run's packages (§H `order`): the selection plus the latents that
    /// were activated, in plan order.
    pub fn order(&self) -> &[RecipeId] {
        &self.order
    }

    /// The settled rows, in plan order — the rows the record renders.
    pub fn rows(&self) -> &[OutcomeRow] {
        &self.rows
    }

    /// The run's visible package count: the plan order's length, never the
    /// latent pool (an activated latent is exactly what makes it grow).
    pub fn total(&self) -> usize {
        self.order.len()
    }

    /// Packages dispatched at least once (a re-dispatch of a settled node —
    /// the remediation force rebuild — is the same package, not a new one).
    pub fn dispatched(&self) -> usize {
        self.dispatched.len()
    }

    /// Settled packages by status, derived from [`Progress::rows`] — never a
    /// separate incrementing field that can drift from them.
    pub fn count(&self, status: RowStatus) -> usize {
        self.rows.iter().filter(|row| row.status == status).count()
    }

    pub fn succeeded(&self) -> usize {
        self.count(RowStatus::Succeeded)
    }

    pub fn failed(&self) -> usize {
        self.count(RowStatus::Failed)
    }

    fn started(&mut self, index: usize) {
        let Some(id) = self.plan.get(index).cloned() else {
            return;
        };
        self.dispatched.insert(id.clone());
        if self.latents.contains(&id) && !self.order.contains(&id) {
            // §H `order` semantics: an activated latent joins the run at its
            // plan slot (the latents are carried after the selection, so
            // this is the append the contract describes) — exactly once.
            let pos = self
                .order
                .iter()
                .position(|other| self.slot_of(other) > self.slot_of(&id))
                .unwrap_or(self.order.len());
            self.order.insert(pos, id);
        }
    }

    fn settled(&mut self, row: OutcomeRow) {
        if let Some(slot) = self.rows.iter().position(|r| r.pkg == row.pkg) {
            // One package settles once per run *record*: a re-settlement
            // (the machine's `force_rebuild` reopens a node in place) is the
            // later row, never a second one.
            self.rows[slot] = row;
            return;
        }
        let slot = self.slot_of(&row.pkg);
        let at = self
            .rows
            .iter()
            .position(|r| self.slot_of(&r.pkg) > slot)
            .unwrap_or(self.rows.len());
        self.rows.insert(at, row);
    }

    fn slot_of(&self, id: &RecipeId) -> usize {
        self.slot.get(id).copied().unwrap_or(usize::MAX)
    }

    /// Bind the projection to the record's own source (the supervisor's
    /// final `rows()`/`order()`): `None` means the live view and the record
    /// are views of the same run, `Some` names the drift class.
    ///
    /// What must hold: identical plan order, and every settlement the fold
    /// saw must be the record's row for that package, in the record's order.
    /// The record may carry rows the fold never saw — the machine's backstage
    /// settlements (a pending park, `finalize_stopped` / `_never_ready` /
    /// `_interrupted`) emit no event by design — but only with a status no
    /// lane reported. A `succeeded`/`failed` row without a matching live
    /// settlement is exactly the drift this pins.
    pub fn drift(&self, rows: &[OutcomeRow], order: &[RecipeId]) -> Option<String> {
        if self.order != order {
            let at = self
                .order
                .iter()
                .zip(order)
                .position(|(live, record)| live != record)
                .unwrap_or(self.order.len().min(order.len()));
            return Some(format!(
                "order drift: the live view carries {} id(s), the record {}; \
                 first divergence at position {at}: live {:?}, record {:?}",
                self.order.len(),
                order.len(),
                self.order.get(at),
                order.get(at)
            ));
        }
        let mut live = 0;
        for row in rows {
            match self.rows.get(live) {
                Some(settled) if settled.pkg == row.pkg => {
                    if settled != row {
                        return Some(format!(
                            "row drift for {}: the live view settled {}, the record carries {}",
                            row.pkg,
                            brief(settled),
                            brief(row)
                        ));
                    }
                    live += 1;
                }
                _ => {
                    if matches!(row.status, RowStatus::Succeeded | RowStatus::Failed) {
                        return Some(format!(
                            "unreported settlement: the record carries `{} {} {}` \
                             that the live view never saw",
                            row.pkg, row.status, row.reason
                        ));
                    }
                }
            }
        }
        if let Some(settled) = self.rows.get(live) {
            return Some(format!(
                "phantom settlement: the live view settled `{}` that the record does not carry",
                settled.pkg
            ));
        }
        None
    }
}

/// One row as a drift message shows it: `<status> <rc> <dur> <reason>`.
fn brief(row: &OutcomeRow) -> String {
    let rc = row
        .rc
        .map(|rc| rc.to_string())
        .unwrap_or_else(|| "-".to_string());
    let dur = row
        .dur
        .map(|d| d.to_string())
        .unwrap_or_else(|| "-".to_string());
    format!("`{} {rc} {dur} {}`", row.status, row.reason)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn id(s: &str) -> RecipeId {
        RecipeId::new(s).expect("test id")
    }

    fn row(pkg: &str, status: RowStatus, reason: &str) -> OutcomeRow {
        OutcomeRow {
            pkg: id(pkg),
            status,
            rc: Some(0),
            dur: Some(1),
            reason: reason.to_string(),
        }
    }

    fn started(index: usize) -> SupEvent {
        SupEvent::Started {
            index,
            jobs: 1,
            core: false,
        }
    }

    fn finished(index: usize, row: OutcomeRow) -> SupEvent {
        SupEvent::Finished { index, row }
    }

    /// A node settles once: a late or duplicate `Finished` (a re-settlement,
    /// or a lane racing its own teardown) replaces the package's row and
    /// moves no counter twice.
    #[test]
    fn a_duplicate_finished_settles_once() {
        let ids = vec![id("p1"), id("p2")];
        let mut progress = Progress::new(ids, Vec::new());
        progress.observe(&started(0));
        progress.observe(&started(1));
        progress.observe(&finished(0, row("p1", RowStatus::Succeeded, "ok")));
        progress.observe(&finished(0, row("p1", RowStatus::Succeeded, "ok")));

        assert_eq!(
            progress.rows().len(),
            1,
            "one row per package: {:?}",
            progress.rows()
        );
        assert_eq!(progress.succeeded(), 1);
        assert_eq!(progress.dispatched(), 2, "both lanes started");
        assert_eq!(progress.total(), 2);

        // The later settlement of the same package is the record's row (the
        // machine's force rebuild reopens a node in place).
        progress.observe(&finished(0, row("p1", RowStatus::Failed, "build-failed")));
        assert_eq!(progress.rows().len(), 1);
        assert_eq!(
            progress.succeeded(),
            0,
            "a re-settlement replaces, never adds"
        );
        assert_eq!(progress.failed(), 1);
        assert_eq!(progress.rows()[0].reason, "build-failed");
    }

    /// The total counts the run's own packages: a latent joins exactly once,
    /// at its activation, and a second `Started` cannot grow it twice.
    #[test]
    fn a_latent_joins_the_total_once_at_activation() {
        let ids = vec![id("leaf"), id("rust-git"), id("core-x")];
        let latents = vec![id("rust-git"), id("core-x")];
        let mut progress = Progress::new(ids, latents);
        assert_eq!(
            progress.total(),
            1,
            "the latent pool is never counted up front"
        );

        progress.observe(&started(0));
        assert_eq!(progress.total(), 1);

        progress.observe(&started(1));
        progress.observe(&started(1));
        assert_eq!(progress.total(), 2, "activation joins once");
        assert_eq!(
            progress.dispatched(),
            2,
            "a re-dispatch is the same package"
        );

        progress.observe(&started(2));
        assert_eq!(progress.total(), 3);
        assert_eq!(
            progress.order(),
            [id("leaf"), id("rust-git"), id("core-x")],
            "activated latents keep plan order"
        );
    }

    /// The plan order is what binds the view to the record: a record `order`
    /// that differs is named, as is a `succeeded`/`failed` row the fold never
    /// saw. A backstage settlement (parked, never-started) is legitimate.
    #[test]
    fn drift_names_the_class() {
        let ids = vec![id("p1"), id("p2")];
        let mut progress = Progress::new(ids.clone(), Vec::new());
        progress.observe(&started(0));
        progress.observe(&finished(0, row("p1", RowStatus::Succeeded, "ok")));

        // In lockstep: the fold's row, plus a backstage parked row.
        let record = vec![
            row("p1", RowStatus::Succeeded, "ok"),
            OutcomeRow {
                pkg: id("p2"),
                status: RowStatus::Parked,
                rc: None,
                dur: None,
                reason: "waits-on-failed".to_string(),
            },
        ];
        assert_eq!(
            progress.drift(&record, &ids),
            None,
            "{:?}",
            progress.drift(&record, &ids)
        );

        // A record shorter than the projection's plan is not drift: the
        // unfold is the run still in motion, never a disagreement.
        assert_eq!(
            progress.drift(&record[..1], &ids),
            None,
            "the backlog is not drift"
        );

        // The same package with a different row — and, behind it, a success
        // the live view never saw (a lane-less settlement).
        let mut one = Progress::new(ids.clone(), vec![id("p2")]);
        one.observe(&started(0));
        one.observe(&finished(0, row("p1", RowStatus::Succeeded, "ok")));
        assert_eq!(
            one.order(),
            [id("p1")],
            "p2 stays latent: the plan orders match"
        );
        let record = vec![row("p1", RowStatus::Failed, "build-failed")];
        let drift = one
            .drift(&record, &ids[..1])
            .expect("a differing row is drift");
        assert!(drift.starts_with("row drift for p1"), "{drift}");

        let record = vec![
            row("p1", RowStatus::Succeeded, "ok"),
            row("p2", RowStatus::Succeeded, "ok"),
        ];
        let drift = one
            .drift(&record, &ids[..1])
            .expect("a missing settlement is drift");
        assert!(drift.starts_with("unreported settlement"), "{drift}");

        // A different plan order.
        let swapped = vec![id("p2"), id("p1")];
        let drift = progress
            .drift(&progress.rows().to_vec(), &swapped)
            .expect("order drift");
        assert!(drift.starts_with("order drift"), "{drift}");
    }
}
