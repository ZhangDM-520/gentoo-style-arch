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

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use gsa_recipe::pkginfo::{member_names, members_with_needed};

use crate::localdb::{provide_covers, provide_name, soname_stem, LocalDb};

/// Expected base-system sonames — the glibc + gcc-libs runtime every Arch
/// system carries (`base` depends on both). Any other non-workspace soname
/// must resolve through a provide, shipped bytes, an owned file, or the
/// exclusions registry (fish `abi_base_lib_ok`).
pub const BASE_LIBS: &[&str] = &[
    "libc.so.6",
    "libm.so.6",
    "libmvec.so.1",
    "libdl.so.2",
    "libpthread.so.0",
    "librt.so.1",
    "libresolv.so.2",
    "libutil.so.1",
    "libnsl.so.1",
    "libthread_db.so.1",
    "ld-linux-x86-64.so.2",
    "ld-linux.so.2",
    "ld64.so.2",
    "libgcc_s.so.1",
    "libstdc++.so.6",
    "libgomp.so.1",
    "libatomic.so.1",
    "libquadmath.so.0",
];

/// Is this soname covered by the expected base-system runtime?
pub fn base_lib_ok(soname: &str) -> bool {
    BASE_LIBS.contains(&soname)
}

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

/// One installed bare-soname provide that disappears or version-moves in a
/// build (fish `abi_provide_refusals`' per-archive diff).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProvideDrift {
    /// The ARCHIVE's pkgname (the surface's home).
    pub pkgname: String,
    /// The provide name (`libfoo.so`).
    pub name: String,
    /// The installed auto-version (`1-64`), `-` when the entry is bare.
    pub inst_ver: String,
    /// The built auto-version; `None` = the provide disappears entirely.
    pub built_ver: Option<String>,
}

/// The Stock→house counterpart name (fish `abi_stock_name`): the VCS suffix
/// stripped. A swap MOVES the surface to a new pkgname instead of vanishing
/// it, so "nothing installed for this pkgname" is not evidence that nothing
/// can disappear (run #31, bzip2-git).
pub fn stock_name(name: &str) -> String {
    for suffix in ["-git", "-svn", "-hg", "-snapshot"] {
        if let Some(stem) = name.strip_suffix(suffix) {
            return stem.to_string();
        }
    }
    name.to_string()
}

fn ver_of(entry: &str) -> String {
    match entry.split_once('=') {
        Some((_, v)) if !v.trim().is_empty() => v.trim().to_string(),
        _ => "-".to_string(),
    }
}

/// The bare-soname provide drift of one build against the installed DB:
/// compare the archive's `.PKGINFO` provides against the installed provides
/// of the same pkgname — or of its stock counterpart when the pkgname is not
/// installed. Nothing installed for either name means nothing can disappear
/// (a true fresh install). Only bare `*.so` provide names are compared
/// (makepkg auto-versions them; rule 25(a)).
pub fn provide_drift(pkgname: &str, built_provides: &[String], db: &LocalDb) -> Vec<ProvideDrift> {
    let installed: Vec<String> = match db.get(pkgname) {
        Some(pkg) => pkg.provides.clone(),
        None => {
            let stock = stock_name(pkgname);
            if stock == pkgname {
                return Vec::new();
            }
            match db.get(&stock) {
                Some(pkg) => pkg.provides.clone(),
                None => return Vec::new(),
            }
        }
    };
    let mut drift = Vec::new();
    for entry in &installed {
        let name = provide_name(entry);
        if !name.ends_with(".so") {
            continue;
        }
        let inst_ver = ver_of(entry);
        let built = built_provides.iter().find(|b| provide_name(b) == name);
        match built {
            None => drift.push(ProvideDrift {
                pkgname: pkgname.to_string(),
                name: name.to_string(),
                inst_ver,
                built_ver: None,
            }),
            Some(b) => {
                let built_ver = ver_of(b);
                if built_ver != inst_ver {
                    drift.push(ProvideDrift {
                        pkgname: pkgname.to_string(),
                        name: name.to_string(),
                        inst_ver,
                        built_ver: Some(built_ver),
                    });
                }
            }
        }
    }
    drift
}

/// Link truth (rule 25(c)/(d)): the INSTALLED packages whose ELF outputs
/// `DT_NEEDED` one of the affected provide names. Name/graph reachability is
/// never consulted — naming a provider is not linking it. Owned files in ELF
/// homes (or ELF-shaped names) are read from the running system; a missing
/// file is skipped.
pub fn linked_consumers(db: &LocalDb, affected: &[String]) -> Vec<String> {
    if affected.is_empty() {
        return Vec::new();
    }
    let mut out: BTreeSet<String> = BTreeSet::new();
    for pkg in db.packages() {
        for file in &pkg.files {
            if !elf_home(file) {
                continue;
            }
            let Ok(bytes) = std::fs::read(format!("/{file}")) else {
                continue;
            };
            let needed = gsa_recipe::elf::needed_libs(&bytes);
            if needed
                .iter()
                .any(|n| affected.iter().any(|a| n == a || n.starts_with(a.as_str())))
            {
                out.insert(pkg.name.clone());
                break;
            }
        }
    }
    out.into_iter().collect()
}

fn elf_home(path: &str) -> bool {
    path.starts_with("usr/lib")
        || path.starts_with("usr/libexec")
        || path.starts_with("usr/bin")
        || path.starts_with("usr/sbin")
        || path.contains(".so")
}

/// Stock-side pinners (fish `abi_local_depend_rows`): every installed package
/// declaring a `Depends` on an affected provide name — the pin pacman will
/// enforce at transaction time before any in-run repair could run. Only
/// exact declareable shapes match (`X`, `X=ver`, `X.so=N-64`, `X.so`): the
/// depend name must equal the affected provide name.
pub fn stock_pinners(db: &LocalDb, affected: &[String]) -> Vec<(String, String)> {
    if affected.is_empty() {
        return Vec::new();
    }
    let mut out: Vec<(String, String)> = Vec::new();
    for pkg in db.packages() {
        for dep in &pkg.depends {
            let name = provide_name(dep);
            if affected.iter().any(|a| a == name) {
                out.push((pkg.name.clone(), dep.clone()));
            }
        }
    }
    out
}

/// The transaction's shipped bytes index: basename + relative path of every
/// member of every candidate (rule 25(b)/(e) resolution source (b)).
#[derive(Clone, Debug, Default)]
pub struct ShippedBytes {
    basenames: BTreeSet<String>,
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
                index
                    .basenames
                    .insert(normalized.rsplit('/').next().unwrap_or("").to_string());
                index.paths.insert(normalized.to_string());
            }
        }
        Ok(index)
    }

    /// A NEEDED name resolves when its file is in the transaction: a bare
    /// name against basenames, a path-style name (SONAME-less DSO linked by
    /// absolute path — run #119's mujs/mpv class) against the exact path.
    pub fn ships(&self, needed: &str) -> bool {
        let normalized = needed.strip_prefix('/').unwrap_or(needed);
        self.paths.contains(normalized)
            || self
                .basenames
                .contains(normalized.rsplit('/').next().unwrap_or(""))
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
            if shipped.ships(&soname) {
                continue;
            }
            if db.provides_cover(&soname) || db.owns_file(&soname) {
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

    #[test]
    fn stock_name_strips_vcs_suffixes() {
        assert_eq!(stock_name("bzip2-git"), "bzip2");
        assert_eq!(stock_name("foo-snapshot"), "foo");
        assert_eq!(stock_name("foo"), "foo");
    }
}
