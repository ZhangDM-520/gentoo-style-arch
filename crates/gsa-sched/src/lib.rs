//! `gsa-sched` — the lane supervisor half of the native engine
//! (`docs/gsa-contract.md` §F, §I, §K; plan-native-pm.md §3.1).
//!
//! - [`budget`]: the `docs/portability.md` intensity formulas as data.
//! - [`codec`]: the typed lane-result wire (`v2 …`) with atomic publication.
//! - [`machine`]: the dispatch state machine — build-order readiness,
//!   core-solo / build-tools band invariants, and the failure policy
//!   (cone-stop default, `--fail-fast`, deferral).
//! - [`signals`]: signal receipt, the teardown grace window, process-group
//!   signalling.
//! - [`lock`]: the run lock, write-time ownership (rule 19), orphan sweeps,
//!   and the `--stale-lock-check` pacman-lock probe.
//! - [`supervisor`]: the event-driven driver that ties them together.

pub mod budget;
pub mod codec;
pub mod lock;
pub mod machine;
pub mod signals;
pub mod supervisor;
