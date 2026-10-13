//! Derived abi-tokens with the optional declared `abi-rev=` override
//! (contract §J.4; plan-native-pm.md §4.1; plan-gentoo-qol.md M1).
//!
//! The token is **derived**: `hash(sorted bare-soname provide set actually
//! shipped)` — the `.PKGINFO` bare-soname provide names (`libfoo.so`, never
//! the auto-versioned `libfoo.so=1-64`) union the shipped ELF `DT_SONAME`
//! names (file truth). `DT_NEEDED` never enters the token: it is what a
//! package CONSUMES, and it feeds the subscription and revdep surfaces
//! instead. The hash is over the sorted, deduplicated stems one per line, so
//! an unchanged provide set yields an unchanged abi-token (the stability
//! property).
//!
//! **Override semantics (`abi-rev=<n>`, topology tag):** the declared
//! revision WINS over derivation's verdict of "unchanged" — for ABI moves
//! derivation provably cannot see (LLVM C++ snapshots, Qt private API,
//! `docs/MEMORY.md` rules 5 and 13) a revision bump alone moves the
//! effective token. The override never suppresses derivation: a stem
//! add/drop still moves the token even at a frozen revision, because
//! suppressing it would under-detect a real soname move (rule 25(c)'s
//! "never under-expand" direction). The effective token therefore binds
//! BOTH facts: `rev<n>-<derived>` when declared, `<derived>` otherwise.

use std::collections::BTreeSet;
use std::path::Path;

use sha2::{Digest, Sha256};

use crate::provides::{is_soname_name, provide_name};

/// One recipe's ABI identity: the derived hash, the declared override (if
/// any), and the effective token consumers record and the waves compare.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AbiToken {
    /// `hash(sorted bare-soname provide set)` — derivation only.
    pub derived: String,
    /// The declared `abi-rev=<n>` override from the topology record.
    pub rev: Option<u64>,
    /// What is recorded and compared: `rev<n>-<derived>` when the override
    /// is declared, `<derived>` otherwise.
    pub effective: String,
}

impl AbiToken {
    /// The `-Qa` rendering of the override state (`abi-rev=<n>` or `-`).
    pub fn override_state(&self) -> String {
        match self.rev {
            Some(n) => format!("abi-rev={n}"),
            None => "-".to_string(),
        }
    }
}

/// The bare-soname stem set actually shipped: the `.PKGINFO` provide NAMES
/// (soname-shaped only, `=ver` auto-version suffix stripped) union the
/// shipped ELF `DT_SONAME` names (kept whole — a generation move
/// `libfoo.so.3` → `libfoo.so.4` is an ABI move and must move the token).
pub fn stem_set(provides: &[String], sonames: &[String]) -> BTreeSet<String> {
    let mut stems = BTreeSet::new();
    for entry in provides {
        let name = provide_name(entry);
        if is_soname_name(name) {
            stems.insert(name.to_string());
        }
    }
    for soname in sonames {
        if is_soname_name(soname) {
            stems.insert(soname.clone());
        }
    }
    stems
}

/// `hash(sorted stems, one per line)` as lowercase hex (SHA-256).
pub fn derive_stems(stems: &BTreeSet<String>) -> String {
    let mut hasher = Sha256::new();
    for stem in stems {
        hasher.update(stem.as_bytes());
        hasher.update(b"\n");
    }
    hex(&hasher.finalize())
}

/// The override merge: the declared revision wins over derivation's
/// "unchanged" and binds into the effective token (see the module docs).
pub fn merge(derived: String, rev: Option<u64>) -> String {
    match rev {
        Some(n) => format!("rev{n}-{derived}"),
        None => derived,
    }
}

/// The token from already-extracted facts (the one shared computation every
/// caller goes through — never re-hash at a call site).
pub fn token_from_parts(provides: &[String], sonames: &[String], rev: Option<u64>) -> AbiToken {
    let derived = derive_stems(&stem_set(provides, sonames));
    let effective = merge(derived.clone(), rev);
    AbiToken {
        derived,
        rev,
        effective,
    }
}

/// The canonical derivation from a built archive: its `.PKGINFO` provides
/// plus the `DT_SONAME` surface of every ELF member (via
/// `gsa-recipe`'s readers — never a shell tool). `Err` = the archive could
/// not be read; the caller fails closed (no token, no row).
pub fn token_for_archive(archive: &Path, rev: Option<u64>) -> Result<AbiToken, String> {
    let info = gsa_recipe::pkginfo::read_pkginfo(archive).map_err(|e| e.to_string())?;
    let dynamic = gsa_recipe::pkginfo::members_with_dynamic(archive)?;
    let sonames: Vec<String> = dynamic
        .into_iter()
        .filter_map(|(_, soname, _)| soname)
        .collect();
    Ok(token_from_parts(&info.provides, &sonames, rev))
}

/// Declared-provides-only derivation (the `-Qa` fallback when no built
/// archive exists yet): the payload half is empty, so the report names the
/// source and never claims shipped bytes were scanned.
pub fn token_declared(provides: &[String], rev: Option<u64>) -> AbiToken {
    token_from_parts(provides, &[], rev)
}

/// The derivation over one INSTALLED package's surface (the fallback when
/// no built instance is recorded for a provider): its provides plus the
/// `DT_SONAME` names of its owned ELF files, probed read-only through the
/// view.
pub fn token_for_installed(
    pkg: &crate::view::InstalledPkg,
    view: &crate::view::InstalledView,
    rev: Option<u64>,
) -> AbiToken {
    let mut sonames: Vec<String> = Vec::new();
    for file in &pkg.files {
        let Some(bytes) = view.read_file(file) else {
            continue;
        };
        if let Some(soname) = gsa_recipe::elf::soname(&bytes) {
            sonames.push(soname);
        }
    }
    token_from_parts(&pkg.provides, &sonames, rev)
}

/// The declared `abi-rev=` of one topology record's tags (`Tag::AbiRev`),
/// `None` when undeclared.
pub fn abi_rev_of(tags: &[gsa_model::Tag]) -> Option<u64> {
    tags.iter().find_map(|t| match t {
        gsa_model::Tag::AbiRev(n) => Some(*n),
        _ => None,
    })
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn so(name: &str) -> String {
        name.to_string()
    }

    #[test]
    fn an_unchanged_provide_set_yields_an_unchanged_token() {
        let a = token_from_parts(
            &[so("libfoo.so=1-64"), so("bar=2.0")],
            &[so("libfoo.so.1")],
            None,
        );
        let b = token_from_parts(
            // Order and auto-version churn must not matter (rule 30: soname
            // beats pkgver) — only the bare-soname set does.
            &[so("bar=9.9"), so("libfoo.so=7-1")],
            &[so("libfoo.so.1")],
            None,
        );
        assert_eq!(a.effective, b.effective, "stability property");
        assert_eq!(a.derived, b.effective, "undeclared: effective is derived");
    }

    #[test]
    fn stem_moves_move_the_token() {
        let base = token_from_parts(&[so("libfoo.so=1-64")], &[so("libfoo.so.1")], None);
        let added = token_from_parts(
            &[so("libfoo.so=1-64"), so("libbar.so=1-64")],
            &[so("libfoo.so.1"), so("libbar.so.1")],
            None,
        );
        assert_ne!(base.effective, added.effective, "added provide moves");
        // A SONAME generation move is an ABI move and must move the token.
        let bumped = token_from_parts(&[so("libfoo.so=2-64")], &[so("libfoo.so.2")], None);
        assert_ne!(base.effective, bumped.effective, "generation move moves");
    }

    #[test]
    fn the_declared_override_wins_over_derivation() {
        let undeclared = token_from_parts(&[so("libfoo.so=1-64")], &[so("libfoo.so.1")], None);
        let rev2 = token_from_parts(&[so("libfoo.so=1-64")], &[so("libfoo.so.1")], Some(2));
        let rev3 = token_from_parts(&[so("libfoo.so=1-64")], &[so("libfoo.so.1")], Some(3));
        // Identical stems, identical derived hash — the DECLARATION alone
        // decides the effective token (the override wins over derivation's
        // "unchanged").
        assert_eq!(undeclared.derived, rev2.derived);
        assert_ne!(undeclared.effective, rev2.effective);
        assert_ne!(rev2.effective, rev3.effective, "a bump alone moves");
        assert_eq!(rev2.override_state(), "abi-rev=2");
        assert_eq!(undeclared.override_state(), "-");
    }

    #[test]
    fn the_override_never_suppresses_derivation() {
        // At a frozen revision a stem move still moves the token: the
        // override augments derivation, it never replaces it (a replacement
        // would under-detect a real soname drop — rule 25(c) direction).
        let before = token_from_parts(&[so("libfoo.so=1-64")], &[], Some(4));
        let after = token_from_parts(&[so("libfoo.so=1-64"), so("libbar.so=1-64")], &[], Some(4));
        assert_ne!(before.effective, after.effective);
    }

    #[test]
    fn non_soname_provides_never_enter_the_token() {
        let a = token_from_parts(&[so("meson=1.8"), so("libfoo.so=1-64")], &[], None);
        let b = token_from_parts(&[so("libfoo.so=1-64")], &[], None);
        assert_eq!(
            a.effective, b.effective,
            "tool provides are not ABI surface"
        );
    }

    #[test]
    fn archive_derivation_reads_pkginfo_and_elf_sonames() {
        let dir = std::env::temp_dir().join(format!("gsa-abi-token-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let archive = crate::test_support::make_archive(
            &dir,
            "prov",
            "1.0.0-1",
            &["provides = libfoo.so=1-64"],
            Some(("libfoo.so.1", &["libc.so.6"])),
        );
        let token = token_for_archive(&archive, None).unwrap();
        let expected = token_from_parts(&[so("libfoo.so=1-64")], &[so("libfoo.so.1")], None);
        // The helper file has SONAME libfoo.so.1 and DT_NEEDED libc.so.6:
        // the token sees the provide name plus the shipped SONAME — a
        // DT_NEEDED is consumed surface and never enters the token.
        assert_eq!(token.derived, expected.derived);
        let with_rev = token_for_archive(&archive, Some(7)).unwrap();
        assert_eq!(with_rev.effective, format!("rev7-{}", token.derived));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
