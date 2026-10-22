//! The fail-closed decision gates (contract §E.3, `docs/MEMORY.md` rule 25):
//!
//! * PGO payload — an archive from a `-fprofile-generate`/`-Cprofile-generate`
//!   recipe carrying a baked `.gcda`/`.profraw` destination refuses
//!   (`pgo-hit` / `pgo-instrumented` / `pgo-unreadable`).
//! * ABI/provide — `abi-soname` (a bare soname provide disappears or moves
//!   vs the installed provide set), `abi-consumer` / `abi-consumer-uncovered`
//!   (a moving/removed soname with a LINKED installed consumer outside the
//!   transaction and outside in-run repair coverage — rule 25(d)), and
//!   `abi-stock-pinner` (an installed out-of-tree package Depends on the
//!   affected provide). Port of `build-all.fish:1996-2352` semantics,
//!   reference only.
//! * The package-internal NEEDED probe — a staged archive's own `DT_NEEDED`
//!   must resolve via the archive's own provides, the transaction's shipped
//!   bytes, or the installed DB (provides + owned files — rule 25(b) file
//!   truth), else `refuse` (run #53 wall).
//!
//! Every gate consumes parsed inputs and returns typed refusal details the
//! decision function folds into `DecisionRow`s; gates never render and never
//! execute anything.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use gsa_recipe::pkginfo::{member_names, members_with_needed};

use gsa_abi::view::{path_class, ElfClass};
use crate::localdb::{provide_covers, soname_stem, LocalDb};

// The base-system soname roster and its predicate are SHARED with the ABI
// subsystem (`gsa-abi::provides`); re-exported here so the gate surface
// keeps one home for the rule-25(b) roster.
pub use gsa_abi::provides::{base_lib_ok, BASE_LIBS};

/// Tier-2 ABI exclusions (`config/abi-exclusions.conf`, rule 25(f)): a
/// strict-loader `id|reason|review-by` registry — entries match a package id
/// or a soname name/stem. Tier-1 exposure is never excludable.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct AbiExclusions {
    pub ids: Vec<String>,
}

impl AbiExclusions {
    pub fn empty() -> AbiExclusions {
        AbiExclusions::default()
    }

    /// Strict loader: every non-comment, non-blank line is exactly
    /// `id|reason|review-by`; `id` matches `[A-Za-z0-9._+-]+`, `reason` is
    /// non-empty, `review-by` is an ISO date, ids are unique. A malformed
    /// line is `Err` naming the file and line — silent gaps are exactly what
    /// the guard exists to prevent.
    pub fn load(path: &Path) -> Result<AbiExclusions, String> {
        let text = std::fs::read_to_string(path)
            .map_err(|e| format!("cannot read abi-exclusions {}: {e}", path.display()))?;
        let mut ids: Vec<String> = Vec::new();
        for (idx, raw_line) in text.lines().enumerate() {
            let line_no = idx + 1;
            let line = raw_line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let fields: Vec<&str> = line.split('|').collect();
            if fields.len() != 3 {
                return Err(format!(
                    "invalid abi-exclusions entry (expected 'id|reason|review-by'): {} line {line_no}",
                    path.display()
                ));
            }
            let id = fields[0].trim();
            let reason = fields[1].trim();
            let review_by = fields[2].trim();
            if id.is_empty()
                || !id
                    .chars()
                    .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '+' | '-'))
            {
                return Err(format!(
                    "invalid abi-exclusions id '{id}' (allowed: A-Za-z0-9._+-): {} line {line_no}",
                    path.display()
                ));
            }
            if reason.is_empty() {
                return Err(format!(
                    "abi-exclusions entry {id} has no reason: {} line {line_no}",
                    path.display()
                ));
            }
            if !is_iso_date(review_by) {
                return Err(format!(
                    "abi-exclusions entry {id} has no ISO review-by date: {} line {line_no}",
                    path.display()
                ));
            }
            if ids.iter().any(|existing| existing == id) {
                return Err(format!(
                    "duplicate abi-exclusions id: {id} ({} line {line_no})",
                    path.display()
                ));
            }
            ids.push(id.to_string());
        }
        Ok(AbiExclusions { ids })
    }

    /// Does the registry cover this name (package id, soname, or its bare
    /// stem)? — fish `abi_excluded`.
    pub fn covers(&self, name: &str) -> bool {
        if self.ids.iter().any(|id| id == name) {
            return true;
        }
        match soname_stem(name) {
            Some(stem) => self.ids.iter().any(|id| id == stem),
            None => false,
        }
    }
}

fn is_iso_date(text: &str) -> bool {
    let bytes = text.as_bytes();
    bytes.len() == 10
        && bytes[0..4].iter().all(|b| b.is_ascii_digit())
        && bytes[4] == b'-'
        && bytes[5..7].iter().all(|b| b.is_ascii_digit())
        && bytes[7] == b'-'
        && bytes[8..10].iter().all(|b| b.is_ascii_digit())
}

/// Does this recipe declare PGO instrumentation? A strict read-only content
/// scan of the `PKGBUILD` for the C (`-fprofile-generate`) or rustc
/// (`-Cprofile-generate` / `-C profile-generate`) spelling — never shell, and
/// whole-file so a flag inside `build()` is seen (the fish gate greps the
/// file). A missing/unreadable recipe is not instrumented (no witness).
pub fn pgo_instrumented_recipe(recipe_dir: Option<&Path>) -> bool {
    let Some(dir) = recipe_dir else {
        return false;
    };
    let Ok(text) = std::fs::read_to_string(dir.join("PKGBUILD")) else {
        return false;
    };
    pgo_flag_in(&text)
}

fn pgo_flag_in(text: &str) -> bool {
    for (idx, _) in text.match_indices("profile-generate") {
        let head = &text[..idx];
        // `-fprofile-generate`: the C flag ends right before the match.
        if head.ends_with("-f") {
            return true;
        }
        // `-C ?profile-generate` (fish ERE: `-C` plus an optional space):
        // rustc's `-Cprofile-generate` or `-C profile-generate`.
        if head.ends_with("-C") || head.ends_with("-C ") {
            return true;
        }
    }
    false
}

// The ABI drift/link-truth/stock-pinner computations moved VERBATIM to
// `gsa-abi::rows` (the ABI subsystem owns them; the install seam renders
// the rows). `gsa_abi::provide_drift`, `gsa_abi::linked_consumers`,
// `gsa_abi::stock_pinners` and `gsa_abi::stock_name` are the ONE
// implementation.

/// The transaction's shipped bytes index: basename + relative path of every
/// member of every candidate (rule 25(b)/(e) resolution source (b)).
#[derive(Clone, Debug, Default)]
pub struct ShippedBytes {
    /// basename -> the member paths carrying it (class filtering needs the
    /// paths, not just the names).
    basenames: BTreeMap<String, Vec<String>>,
    paths: BTreeSet<String>,
}

impl ShippedBytes {
    /// Build the index from every candidate's member names. `Err` = one
    /// archive could not be walked (fail closed — the probe would otherwise
    /// under-report resolution sources).
    pub fn collect(archives: &[&Path]) -> Result<ShippedBytes, String> {
        let mut index = ShippedBytes::default();
        for archive in archives {
            for name in member_names(archive)
                .map_err(|e| format!("cannot list {}: {e}", archive.display()))?
            {
                let normalized = name.strip_prefix("./").unwrap_or(&name);
                if let Some(base) = normalized.rsplit('/').next() {
                    index
                        .basenames
                        .entry(base.to_string())
                        .or_default()
                        .push(normalized.to_string());
                }
                index.paths.insert(normalized.to_string());
            }
        }
        Ok(index)
    }

    /// A NEEDED name resolves when its file is in the transaction: a bare
    /// name against basenames, a path-style name (SONAME-less DSO linked by
    /// absolute path — run #119's mujs/mpv class) against the exact path.
    /// `class` is the CONSUMER member's ELF class: lib32-shipped bytes never
    /// resolve a 64-bit member's need (and vice versa).
    pub fn ships_as(&self, needed: &str, class: ElfClass) -> bool {
        let normalized = needed.strip_prefix('/').unwrap_or(needed);
        let base = normalized.rsplit('/').next().unwrap_or("");
        let mut candidates: Vec<&str> = Vec::new();
        if self.paths.contains(normalized) {
            candidates.push(normalized);
        }
        if let Some(paths) = self.basenames.get(base) {
            candidates.extend(paths.iter().map(|s| s.as_str()));
        }
        candidates.into_iter().any(|candidate| path_class(candidate) == class)
    }

    /// The dominant class of the probe path itself (bare names: 64-bit).
    pub fn ships(&self, needed: &str) -> bool {
        self.ships_as(needed, path_class(needed))
    }
}

/// One unresolved `DT_NEEDED` of one archive member (rule 25(e)).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NeededMiss {
    /// The archive-relative member path.
    pub member: String,
    pub soname: String,
}

/// The package-internal NEEDED probe for ONE archive: every ELF member's
/// `DT_NEEDED` must resolve via (a) the archive's own provides, (b) bytes
/// the transaction ships, or (c) the installed DB (provides + owned files —
/// runtime file truth so stock providers declaring no soname provide do not
/// false-abort). Base-system sonames and the exclusions registry skip.
/// `Err` = the archive could not be read → the caller refuses fail-closed.
pub fn needed_misses(
    archive: &Path,
    own_provides: &[String],
    shipped: &ShippedBytes,
    db: &LocalDb,
    exclusions: &AbiExclusions,
) -> Result<Vec<NeededMiss>, String> {
    let members = members_with_needed(archive)
        .map_err(|e| format!("cannot probe {}: {e}", archive.display()))?;
    let mut misses = Vec::new();
    for (member, needed) in members {
        for soname in needed {
            if base_lib_ok(&soname) || exclusions.covers(&soname) {
                continue;
            }
            if own_provides.iter().any(|p| provide_covers(p, &soname)) {
                continue;
            }
            // Every file-truth resolution runs in the CONSUMER member's ELF
            // class: `usr/lib32/*` members resolve lib32-owned/shipped
            // files, `usr/lib/*` members never resolve through lib32 bytes.
            let class = path_class(&member);
            if shipped.ships_as(&soname, class) {
                continue;
            }
            if db.provides_cover(&soname) || db.owns_file_as(&soname, class) {
                continue;
            }
            misses.push(NeededMiss {
                member: member.clone(),
                soname,
            });
        }
    }
    Ok(misses)
}

/// Kept for the wiring layer: the default exclusions location inside a
/// workspace root (`config/abi-exclusions.conf`), resolved by walking up
/// from a recipe directory. Absent → empty registry (synthetic workspaces).
pub fn find_repo_exclusions(start: Option<&Path>) -> Option<PathBuf> {
    let mut dir = start?;
    loop {
        let candidate = dir.join("config").join("abi-exclusions.conf");
        if candidate.is_file() {
            return Some(candidate);
        }
        dir = dir.parent()?;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pgo_flag_scan_sees_both_spellings_and_ignores_neighbours() {
        assert!(pgo_flag_in("CFLAGS+=' -fprofile-generate=/tmp/p'"));
        assert!(pgo_flag_in("RUSTFLAGS='-Cprofile-generate=/tmp/p'"));
        assert!(pgo_flag_in("RUSTFLAGS='-C profile-generate'"));
        assert!(!pgo_flag_in("CFLAGS+=' -O3'"));
        assert!(!pgo_flag_in("profile-generate"));
    }

    #[test]
    fn shipped_bytes_resolve_only_in_the_consumer_class() {
        let mut index = ShippedBytes::default();
        index.basenames.insert(
            "libgone.so.1".to_string(),
            vec!["usr/lib32/libgone.so.1".to_string()],
        );
        index.paths.insert("usr/lib32/libgone.so.1".to_string());
        assert!(index.ships_as("libgone.so.1", ElfClass::X32));
        assert!(
            !index.ships_as("libgone.so.1", ElfClass::X64),
            "lib32-shipped bytes must never resolve a 64-bit member's need"
        );
    }

    #[test]
    fn exclusions_loader_is_strict() {
        let dir = std::env::temp_dir().join(format!("gsa-gates-excl-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let conf = dir.join("abi-exclusions.conf");
        std::fs::write(
            &conf,
            "# comment\nlibfoo.so|hand-rolled soname|2027-01-01\n\nmeson|tool|2027-02-02\n",
        )
        .unwrap();
        let excl = AbiExclusions::load(&conf).unwrap();
        assert!(excl.covers("libfoo.so"));
        assert!(excl.covers("libfoo.so.3"));
        assert!(excl.covers("meson"));
        assert!(!excl.covers("libbar.so"));

        std::fs::write(&conf, "bad entry without pipes\n").unwrap();
        assert!(AbiExclusions::load(&conf).is_err());
        std::fs::write(&conf, "id|reason|nodate\n").unwrap();
        assert!(AbiExclusions::load(&conf).is_err());
        std::fs::write(&conf, "id|reason|2027-01-01\nid|again|2027-01-01\n").unwrap();
        assert!(AbiExclusions::load(&conf).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
