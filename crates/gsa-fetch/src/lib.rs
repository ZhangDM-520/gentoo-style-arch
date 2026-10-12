//! `gsa-fetch` — the fetch-ahead subsystem (`docs/gsa-contract.md` §B.4
//! `-Sw`, §D.1 `--fetch-job`, plan.md §2): fetch-and-verify of recipe
//! sources through `makepkg --verifysource` as the ONLY fetch/verify engine,
//! plus the dispatcher's bounded lookahead prefetch window.
//!
//! The verification contract is makepkg's and is never re-implemented and
//! never weakened (§L.8): the fetch argv is exactly `makepkg --verifysource`
//! with `GIT_CONFIG_COUNT=0` — no `-s`, no `-o`, no `--holdver`, and never
//! `--skipchecksums`/`--skipinteg`/`--skippgpcheck`. Prefetch and the lane
//! therefore enforce the identical checksum/`validpgpkeys` contract.
//!
//! Modules:
//! - [`verdict`]: the fetch verdict vocabulary (`ok|failed|skipped` + kebab
//!   reason) and its typed result codec — the only way a fetch outcome
//!   crosses the process boundary (same discipline as the lane codec,
//!   contract §F.2, but an OWN vocabulary: never `lane_outcome_*`).
//! - [`candidacy`]: per-recipe source classification through
//!   `gsa-recipe`'s classifier (never grep): v1 prefetches plain-URL
//!   sources only; a pure-VCS recipe is `skipped vcs-only`, a recipe with no
//!   fetchable source is `skipped not-a-candidate`.
//! - [`window`]: the lookahead window over the plan (topological) order —
//!   bounded at `--prefetch-ahead N`, single-flight, skipping
//!   started/done/parked/deferred/skipped packages.
//! - [`engine`]: the fetch/verify pipeline per recipe (attempts, quarantine
//!   of a pinned-bad cached file, one loud retry), the SRCDEST/disk-floor
//!   lookups, and the `--fetch-job` child entry.
//! - [`child`]: one-shot fetch-child spawn/teardown shape (own process
//!   group; killed with the run).

pub mod candidacy;
pub mod child;
pub mod engine;
pub mod verdict;
pub mod window;
