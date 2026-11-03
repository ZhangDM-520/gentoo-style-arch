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
    NO_TOKEN,
};
pub use revdep::{
    load_preserved, preserved_registry_path, render as render_revdep, revdep_report,
    revdep_report_with_state, ExactPin, PreservedEntry, PreservedSurvivor, RevdepReport,
    UnresolvedNeed,
};
pub use rows::{
    abi_refusal_rows, abi_uncovered_row, linked_consumers, provide_drift, stock_pinners, AbiGate,
    Drift,
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

/// The set-based `:=` movement verdict the wave surfaces share: the
/// provider's registered token set MOVED iff some record with token truth
/// names a token it no longer ships. A split provider ships one token per
/// output (any match is current — never one arbitrary output's row alone),
/// and a [`records::NO_TOKEN`] placeholder is record-less: "No index row or
/// no record is no observable move here" (the planner's fail-toward
/// fallback owns record-less states).
pub fn records_moved(
    recorded: &[&Subscription],
    current: &std::collections::BTreeSet<String>,
) -> bool {
    recorded
        .iter()
        .filter(|s| s.has_token())
        .any(|s| !current.contains(&s.token))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sub(token: &str) -> Subscription {
        Subscription {
            consumer: "c".to_string(),
            version: "0:1-1".to_string(),
            provider: "p".to_string(),
            token: token.to_string(),
        }
    }

    fn set(tokens: &[&str]) -> std::collections::BTreeSet<String> {
        tokens.iter().map(|t| t.to_string()).collect()
    }

    #[test]
    fn the_movement_verdict_is_set_based_and_placeholder_blind() {
        // No record: no observable move (the fallback owns record-less).
        assert!(!records_moved(&[], &set(&["T2"])));
        // Placeholder rows are record-less — never a move by themselves.
        assert!(!records_moved(&[&sub(records::NO_TOKEN)], &set(&["T2"])));
        // A current record is satisfied — including across a multi-output
        // provider's token set (ANY shipped output's token matches).
        assert!(!records_moved(&[&sub("Ta")], &set(&["Ta", "Tb"])));
        assert!(!records_moved(&[&sub("Tb")], &set(&["Ta", "Tb"])));
        // A record naming a token the provider no longer ships is the move.
        assert!(records_moved(&[&sub("T1")], &set(&["Ta", "Tb"])));
        // Mixed sets decide on the real records only.
        assert!(records_moved(
            &[&sub(records::NO_TOKEN), &sub("T1")],
            &set(&["T2"])
        ));
    }
}
