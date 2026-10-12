//! The prefetch lookahead window (plan.md §2.1/§2.3): a bounded window over
//! the plan (topological) order, one fetch in flight at a time.
//!
//! The dispatcher is the only brain: the window is re-derived from live
//! run state every tick and skips started/done/parked/deferred/skipped
//! packages, so a package that will not build this run is never fetched and
//! a fetch never races a lane's own makepkg for the same recipe. Fetch
//! verdicts are terminal-for-fetch: a package already prefetched (or with a
//! routine-skip verdict) is never spawned again this run.

/// The lookahead window over the plan (topological) order, `--prefetch-ahead
/// N`'s default (owner decision 1/6: 8 upcoming recipes ≈ 1–2 h of runway
/// at 15–30 min builds; bounded disk exposure — plan.md §2.3).
pub const DEFAULT_PREFETCH_AHEAD: usize = 8;
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PkgFetchState {
    /// Not fetched yet, still to build: a window candidate.
    Eligible,
    /// A fetch child is running for it (single-flight slot taken).
    InFlight,
    /// Prefetched this run (verdict `ok`).
    Prefetched,
    /// A prefetch attempt concluded `failed` — advisory; never retried
    /// this run (the lane remains authoritative).
    FetchFailed,
    /// Deliberately never fetched (`vcs-only`, `not-a-candidate`, …).
    Skipped,
    /// Its lane has started (or finished): leave the window.
    Started,
    /// Terminal run outcome.
    Done,
    /// Parked (`waits-on-failed`/`coupled-batch`): never builds this run.
    Parked,
    /// Deferred (`waits-on-deferred` or the deferral itself).
    Deferred,
}

impl PkgFetchState {
    /// States that consume a window slot: still to build and fetch-relevant.
    fn in_window(self) -> bool {
        matches!(
            self,
            PkgFetchState::Eligible
                | PkgFetchState::InFlight
                | PkgFetchState::Prefetched
                | PkgFetchState::FetchFailed
        )
    }
}

/// The lookahead window over plan order. Pure state: spawning and policy
/// live in the dispatcher (`gsa-sched::supervisor`).
#[derive(Clone, Debug)]
pub struct PrefetchWindow {
    states: Vec<PkgFetchState>,
    /// `--prefetch-ahead N` (owner decision 1: default 8).
    ahead: usize,
    /// Single-flight: at most one fetch child at a time (owner decision 6).
    in_flight: Option<usize>,
}

impl PrefetchWindow {
    pub fn new(len: usize, ahead: usize) -> PrefetchWindow {
        PrefetchWindow {
            states: vec![PkgFetchState::Eligible; len],
            ahead: ahead.max(1),
            in_flight: None,
        }
    }

    pub fn len(&self) -> usize {
        self.states.len()
    }

    pub fn is_empty(&self) -> bool {
        self.states.is_empty()
    }

    pub fn state(&self, index: usize) -> PkgFetchState {
        self.states[index]
    }

    /// The dispatcher syncs live run state (started/done/parked/deferred).
    /// Never disturbs the fetch-side states of packages still to build.
    pub fn set_state(&mut self, index: usize, state: PkgFetchState) {
        if state == PkgFetchState::InFlight {
            // InFlight is set by `mark_spawned`, never by sync.
            return;
        }
        self.states[index] = state;
    }

    /// The upcoming fetch-relevant packages, in plan order: everything not
    /// yet started/done/parked/deferred/skipped.
    pub fn upcoming(&self) -> Vec<usize> {
        (0..self.states.len())
            .filter(|&i| self.states[i].in_window())
            .collect()
    }

    /// The window: the first `N` upcoming packages (plan order), bounded.
    pub fn window(&self) -> Vec<usize> {
        self.upcoming().into_iter().take(self.ahead).collect()
    }

    /// The next package to fetch: the first `Eligible` member of the
    /// window, and NONE while a fetch is in flight (single-flight) or when
    /// the window holds nothing new.
    pub fn next_to_fetch(&self) -> Option<usize> {
        if self.in_flight.is_some() {
            return None;
        }
        self.window()
            .into_iter()
            .find(|&i| self.states[i] == PkgFetchState::Eligible)
    }

    /// Mark a fetch child spawned. Refuses a second concurrent spawn
    /// (single-flight) and a non-eligible package.
    pub fn mark_spawned(&mut self, index: usize) -> bool {
        if self.in_flight.is_some() || self.states[index] != PkgFetchState::Eligible {
            return false;
        }
        self.states[index] = PkgFetchState::InFlight;
        self.in_flight = Some(index);
        true
    }

    /// Record one fetch outcome: the in-flight slot frees, the package
    /// never fetches again this run.
    pub fn mark_result(&mut self, index: usize, verdict: crate::verdict::FetchVerdict) {
        use crate::verdict::FetchVerdict;
        if self.in_flight == Some(index) {
            self.in_flight = None;
        }
        self.states[index] = match verdict {
            FetchVerdict::Ok => PkgFetchState::Prefetched,
            FetchVerdict::Failed => PkgFetchState::FetchFailed,
            FetchVerdict::Skipped => PkgFetchState::Skipped,
        };
    }

    /// A child died without a usable result (`result-lost`): same terminal
    /// treatment as `failed` — advisory, never re-spawned this run.
    pub fn mark_lost(&mut self, index: usize) {
        if self.in_flight == Some(index) {
            self.in_flight = None;
        }
        self.states[index] = PkgFetchState::FetchFailed;
    }

    pub fn in_flight(&self) -> Option<usize> {
        self.in_flight
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::verdict::FetchVerdict;

    #[test]
    fn window_is_bounded_at_n_in_plan_order() {
        let mut w = PrefetchWindow::new(10, 3);
        assert_eq!(w.window(), vec![0, 1, 2]);
        // Started/finished/parked/deferred/skipped packages leave the
        // window and the bound still holds.
        for (i, state) in [
            (0usize, PkgFetchState::Started),
            (1, PkgFetchState::Done),
            (2, PkgFetchState::Parked),
            (3, PkgFetchState::Deferred),
            (4, PkgFetchState::Skipped),
        ] {
            w.set_state(i, state);
        }
        assert_eq!(w.window(), vec![5, 6, 7]);
        assert!(w.window().len() <= 3);
    }

    #[test]
    fn window_computation_skips_started_done_parked_deferred_and_skipped() {
        let mut w = PrefetchWindow::new(7, 8);
        w.set_state(0, PkgFetchState::Started);
        w.set_state(1, PkgFetchState::Done);
        w.set_state(2, PkgFetchState::Parked);
        w.set_state(3, PkgFetchState::Deferred);
        w.set_state(4, PkgFetchState::Skipped);
        // Only the two still-to-build packages are fetchable.
        assert_eq!(w.upcoming(), vec![5, 6]);
        assert_eq!(w.window(), vec![5, 6]);
        assert_eq!(w.next_to_fetch(), Some(5));
    }

    #[test]
    fn single_flight_holds_the_slot_until_the_result_lands() {
        let mut w = PrefetchWindow::new(4, 8);
        assert_eq!(w.next_to_fetch(), Some(0));
        assert!(w.mark_spawned(0));
        // No second spawn while one is in flight — even for another node.
        assert_eq!(w.next_to_fetch(), None);
        assert!(!w.mark_spawned(1));
        assert_eq!(w.in_flight(), Some(0));
        w.mark_result(0, FetchVerdict::Ok);
        assert_eq!(w.in_flight(), None);
        assert_eq!(w.next_to_fetch(), Some(1));
        // A prefetched package is never fetched again.
        assert_eq!(w.window(), vec![0, 1, 2, 3]);
        assert_ne!(w.next_to_fetch(), Some(0));
    }

    #[test]
    fn failed_and_lost_fetches_are_never_re_spawned() {
        let mut w = PrefetchWindow::new(2, 8);
        assert!(w.mark_spawned(0));
        w.mark_result(0, FetchVerdict::Failed);
        assert_eq!(w.next_to_fetch(), Some(1));
        assert!(w.mark_spawned(1));
        w.mark_lost(1);
        assert_eq!(w.next_to_fetch(), None);
    }

    #[test]
    fn fetched_but_not_started_stays_bounded_by_the_window() {
        // The window-bound invariant the fixture asserts: at most N
        // packages are fetched-but-not-started at any time.
        let mut w = PrefetchWindow::new(10, 2);
        let mut fetched_unstarted = 0usize;
        for _ in 0..30 {
            if let Some(i) = w.next_to_fetch() {
                assert!(w.mark_spawned(i));
                w.mark_result(i, FetchVerdict::Ok);
                fetched_unstarted += 1;
            }
            assert!(fetched_unstarted <= 2, "more than 2 ahead");
            // A lane starts one of them (the plan order's oldest).
            if fetched_unstarted > 0 {
                if let Some(i) = w.upcoming().first().copied() {
                    if w.state(i) == PkgFetchState::Prefetched {
                        w.set_state(i, PkgFetchState::Started);
                        fetched_unstarted -= 1;
                    }
                }
            }
        }
    }
}
