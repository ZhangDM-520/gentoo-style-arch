//! `gsa-abi` — the ABI subsystem of the native `gsa` engine
//! (`docs/gsa-contract.md` §B.3/§E/§I/§J; `plan-native-pm.md` §4;
//! `plan-gentoo-qol.md` M1+M2).
//!
//! Four surfaces, one vocabulary:
//!
//! * **abi-tokens** ([`token`]) — derived (`hash(sorted bare-soname provide
//!   set actually shipped)`) with the optional declared `abi-rev=<n>`
//!   topology-tag override. The same computation feeds the binpkg index
//!   (`gsa-state`) and the installed-ABI record; it is never re-derived at a
//!   call site.
//! * **`:=` subscriptions and rebuild waves** ([`records`], [`wave`]) —
//!   `consumer|version|provider|token` records written at install time; the
//!   wave planner computes the exact rebuild set of a provider whose token
//!   moved (recorded mismatches ∪ content truth ∪ `abi=must` coupled
//!   batches, closed over transitive consumers) and fails toward the OLD
//!   whole-closure rule (`docs/MEMORY.md` rule 25(c): never under-expand)
//!   when subscription records are missing.
//! * **preserved-libs and revdeps** ([`view`], [`revdep`]) — the
//!   installed-ELF view (read-only pacman local DB + file probe) answers
//!   `-Qa`/`-Qr`: tokens, subscriptions in/out, unresolved `DT_NEEDED`,
//!   preserved-lib survivors, exact-pin leftovers.
//! * **the install seam's ABI rows** ([`rows`]) — the frozen `refuse
//!   abi-soname …` / `refuse abi-consumer …` / `refuse abi-stock-pinner …`
//!   shapes and the under-coverage `refuse abi-consumer-uncovered …`
//!   class, computed here and folded into `gsa-install`'s one decision
//!   seam (contract §E, rule 20).
//!
//! The staged swap ([`wave::stage_swap`]) turns computed waves into
//! transactions: ONE `pacman -U` per wave carrying every wave archive
//! (plan-native-pm.md §4.5) — the old provider stays installed until the
//! whole wave lands.

pub mod provides;
pub mod records;
pub mod revdep;
pub mod rows;
pub mod token;
pub mod view;
pub mod wave;

/// Archive/ELF staging helpers for tests and fixtures (the synthetic-input
/// seam — additive to the fixed surface, `LocalDb::from_packages` precedent).
#[doc(hidden)]
pub mod test_support;

pub use provides::{
    base_lib_ok, is_soname_name, provide_covers, provide_name, soname_stem, stock_name, BASE_LIBS,
};
pub use records::{
    record_install, subscriptions_for_install, subscriptions_path, Subscription, Subscriptions,
};
pub use revdep::{
    load_preserved, preserved_registry_path, render as render_revdep, revdep_report,
    revdep_report_with_state, ExactPin, PreservedEntry, PreservedSurvivor, RevdepReport,
    UnresolvedNeed,
};
pub use rows::{
    abi_refusal_rows, abi_uncovered_row, linked_consumers, provide_drift, stock_pinners, Drift,
};
pub use token::{
    abi_rev_of, derive_stems, merge, stem_set, token_declared, token_for_archive,
    token_for_installed, token_from_parts, AbiToken,
};
pub use view::{InstalledPkg, InstalledView};
pub use wave::{
    plan_waves, stage_swap, MemberBasis, SwapPlan, TokenMove, Wave, WaveInputs, WaveMember,
    WavePlan,
};

/// A recorded-token comparison used across the surfaces: what the `-S`/`-B`
/// wave check and the `-U` staged swap treat as "the provider's abi-token
/// changed" — the recorded/previous token differs from the current one.
pub fn token_moved(recorded: Option<&str>, current: &str) -> bool {
    match recorded {
        Some(token) => token != current,
        // No record: the move is unobservable here; the wave planner's
        // fail-toward fallback is what covers record-less states.
        None => false,
    }
}
