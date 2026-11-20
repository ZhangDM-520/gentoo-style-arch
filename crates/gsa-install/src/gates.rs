//! The fail-closed decision gates (contract §E.3, `AGENTS.md` rule 25):
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
//! decision function folds into `DecisionRow`s; a gate never renders and never
//! MUTATES anything. The one host read is the repair hint's repo probe
//! ([`repo_rows`], [`repo_rows_best_effort`], [`pacman_cache_dir`]): "what does
//! the repo say about this name?" has no in-process answer, and every failure of
//! that read degrades to NO hint (never to a hint the gate cannot stand behind).

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use gsa_recipe::pkginfo::{member_names, members_with_needed};

use crate::localdb::{provide_covers_as, soname_stem, LocalDb};
use gsa_abi::view::{path_class, ElfClass};

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
/// file). An absent `PKGBUILD` is not instrumented (`Ok(false)`); an
/// unreadable `PKGBUILD` propagates `Err` so a damaged/unreadable file can
/// never silently bypass the PGO payload gate (`F-INS-02`).
pub fn pgo_instrumented_recipe(recipe_dir: Option<&Path>) -> Result<bool, String> {
    let Some(dir) = recipe_dir else {
        return Ok(false);
    };
    let Some(text) = gsa_model::read::optional(&dir.join("PKGBUILD"))? else {
        return Ok(false);
    };
    Ok(pgo_flag_in(&text))
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
        let mut links: Vec<(String, String)> = Vec::new();
        for archive in archives {
            for name in member_names(archive)
                .map_err(|e| format!("cannot list {}: {e}", archive.display()))?
            {
                let normalized = name.strip_prefix("./").unwrap_or(&name);
                index.paths.insert(normalized.to_string());
            }
            for (link, target) in gsa_recipe::pkginfo::member_symlinks(archive)
                .map_err(|e| format!("cannot list {}: {e}", archive.display()))?
            {
                let link = link.strip_prefix("./").unwrap_or(&link).to_string();
                links.push((link, target));
            }
        }
        // A symlink resolves a need only when its target is a member too: a
        // DANGLING link names a path that carries no bytes, so it covered a
        // `DT_NEEDED` nothing could satisfy and the install went through
        // rc 0 with the link broken (blind review, 2026-11-11).
        for (link, target) in &links {
            let resolves = gsa_recipe::pkginfo::resolve_member_link(link, target)
                .is_some_and(|resolved| index.paths.contains(&resolved));
            if !resolves {
                index.paths.remove(link);
            }
        }
        for path in &index.paths {
            if let Some(base) = path.rsplit('/').next() {
                index
                    .basenames
                    .entry(base.to_string())
                    .or_default()
                    .push(path.clone());
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
        candidates
            .into_iter()
            .any(|candidate| path_class(candidate) == class)
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
            // Every provide and file-truth resolution runs in the CONSUMER
            // member's ELF class: `usr/lib32/*` members resolve `-32` / lib32
            // provides and files; `usr/lib/*` members never resolve through
            // 32-bit `-32` provides or lib32 bytes (`F-INS-04`).
            let class = path_class(&member);
            if own_provides
                .iter()
                .any(|p| provide_covers_as(p, &soname, class))
            {
                continue;
            }
            if shipped.ships_as(&soname, class) {
                continue;
            }
            if db.provides_cover_as(&soname, class) || db.owns_file_as(&soname, class) {
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

/// One `--with` archive's unfit byte or pin (issue #6, §E.3 2026-11-20
/// amendment): a repo archive the operator added to the transaction whose
/// own links the post-transaction system cannot satisfy.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WithUnresolved {
    /// The archive-relative member path.
    pub member: String,
    pub soname: String,
}

/// The `--with` byte check: a repo archive admitted to the transaction must
/// fit the system the transaction produces. Two ways it may not:
///
/// * a `DT_NEEDED` that resolves only through the installed DB entry this
///   transaction is about to REPLACE — the moved generation (`drift`). The
///   installed DB still answers "yes" for it, which is exactly why a stale
///   stock archive would otherwise enter silently and break on first use;
/// * a `Depends` that pins the moved provide generation the provider is
///   leaving (`libjxl.so=0.12-64`). pacman would refuse the transaction, so
///   the plan refuses first, with the reason.
///
/// `Err` = the archive could not be read (fail closed, rule 71).
pub fn with_unresolved(
    with: &crate::WithArchive,
    drift: &[gsa_abi::Drift],
    shipped: &ShippedBytes,
    db: &LocalDb,
    exclusions: &AbiExclusions,
) -> Result<Vec<WithUnresolved>, String> {
    let mut out = Vec::new();
    let members = members_with_needed(&with.archive)
        .map_err(|e| format!("cannot probe {}: {e}", with.archive.display()))?;
    for (member, needed) in members {
        for soname in needed {
            if base_lib_ok(&soname) || exclusions.covers(&soname) {
                continue;
            }
            let class = path_class(&member);
            if with
                .pkginfo
                .provides
                .iter()
                .any(|p| provide_covers_as(p, &soname, class))
            {
                continue;
            }
            // Bytes the transaction SHIPS resolve the need even when the
            // same move also removes an older generation: the file is there
            // after the transaction (blind review 2026-11-20 — the dropped
            // test must not outrank shipped truth).
            if shipped.ships_as(&soname, class) {
                continue;
            }
            // The generation this transaction removes is NOT coverage — the
            // installed DB entry that still answers for it is the entry the
            // transaction replaces.
            let dropped = drift.iter().any(|d| {
                if d.inst_ver == "-" {
                    gsa_abi::provides::provide_covers(&d.name, &soname)
                } else {
                    gsa_abi::provides::provide_covers(
                        &format!("{}={}", d.name, d.inst_ver),
                        &soname,
                    )
                }
            });
            if dropped {
                out.push(WithUnresolved {
                    member: member.clone(),
                    soname,
                });
                continue;
            }
            if db.provides_cover_as(&soname, class) || db.owns_file_as(&soname, class) {
                continue;
            }
            out.push(WithUnresolved {
                member: member.clone(),
                soname,
            });
        }
    }
    Ok(out)
}

/// The `--with` pin check: every `Depends` entry of the archive that names a
/// moved provide at the generation this transaction REMOVES. A bare pin
/// (`libfoo.so`) is satisfied by any generation and never rows.
pub fn with_old_pins(with: &crate::WithArchive, drift: &[gsa_abi::Drift]) -> Vec<String> {
    let mut out = Vec::new();
    for dep in &with.pkginfo.depends {
        let Some((name, ver)) = dep.split_once('=') else {
            continue;
        };
        if ver.trim().is_empty() {
            continue;
        }
        if drift
            .iter()
            .any(|d| d.name == name && d.inst_ver != "-" && d.inst_ver == ver.trim())
        {
            out.push(dep.clone());
        }
    }
    out
}

/// The repo cache a `--with` resolution and the repair hint both read —
/// `pacman-conf [--config CONF] CacheDir`, the SAME answer pacman downloads
/// into (`--config` so an alternate configuration is not silently read
/// through the host's cache; blind review 2026-11-20).
pub fn pacman_cache_dir(conf: Option<&Path>) -> PathBuf {
    let mut cmd = std::process::Command::new("pacman-conf");
    cmd.env("LC_ALL", "C");
    if let Some(conf) = conf {
        cmd.arg("--config").arg(conf);
    }
    cmd.arg("CacheDir");
    if let Ok(output) = cmd.output() {
        if output.status.success() {
            if let Some(line) = String::from_utf8_lossy(&output.stdout)
                .lines()
                .map(str::trim)
                .find(|line| !line.is_empty())
            {
                return PathBuf::from(line);
            }
        }
    }
    PathBuf::from("/var/cache/pacman/pkg")
}

/// One `pacman -Si` block: the repo's current answer for one name.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RepoRow {
    pub name: String,
    pub version: String,
    pub arch: String,
}

/// Read the repo's answer for `names` — ONE `pacman -Si`, ONE block parser.
/// The two policies over it are named at their call sites, never re-derived:
/// [`repo_rows`] (an operator's `--with` list, all-or-nothing) and
/// [`repo_rows_best_effort`] (the refusal hint, take what the read gave).
fn read_repo_rows(conf: Option<&Path>, names: &[String]) -> (Vec<RepoRow>, Result<(), String>) {
    let mut cmd = std::process::Command::new("pacman");
    cmd.env("LC_ALL", "C");
    if let Some(conf) = conf {
        cmd.arg("--config").arg(conf);
    }
    cmd.arg("-Si").args(names);
    let output = match cmd.output() {
        Ok(output) => output,
        Err(e) => return (Vec::new(), Err(format!("cannot run pacman -Si: {e}"))),
    };
    let status = if output.status.success() {
        Ok(())
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let detail = stderr
            .lines()
            .find(|line| !line.trim().is_empty())
            .unwrap_or("pacman -Si failed")
            .to_string();
        Err(detail)
    };
    let text = String::from_utf8_lossy(&output.stdout);
    let mut rows: Vec<RepoRow> = Vec::new();
    let (mut name, mut version, mut arch) = (String::new(), String::new(), String::new());
    let mut flush = |name: &mut String, version: &mut String, arch: &mut String| {
        if !name.is_empty() && !version.is_empty() && !arch.is_empty() {
            rows.push(RepoRow {
                name: std::mem::take(name),
                version: std::mem::take(version),
                arch: std::mem::take(arch),
            });
        } else {
            name.clear();
            version.clear();
            arch.clear();
        }
    };
    for line in text.lines() {
        let Some((field, value)) = line.split_once(':') else {
            continue;
        };
        let value = value.trim();
        match field.trim() {
            "Name" => {
                flush(&mut name, &mut version, &mut arch);
                name = value.to_string();
            }
            "Version" => version = value.to_string(),
            "Architecture" => arch = value.to_string(),
            _ => {}
        }
    }
    flush(&mut name, &mut version, &mut arch);
    (rows, status)
}

/// The repo's answer for an OPERATOR's `--with` list: a name the configured
/// repos do not carry (or a read that failed outright) refuses the whole
/// request, so a transaction member is never silently dropped.
pub fn repo_rows(conf: Option<&Path>, names: &[String]) -> Result<Vec<RepoRow>, String> {
    match read_repo_rows(conf, names) {
        (rows, Ok(())) => Ok(rows),
        (_, Err(detail)) => Err(format!(
            "cannot resolve --with {}: {detail}",
            names.join(" ")
        )),
    }
}

/// The repo's answer for the refusal HINT: whatever blocks the read produced.
/// `pacman -Si known unknown` prints `known`'s block and exits non-zero, so
/// an all-or-nothing read would silence every repair hint as soon as one
/// stranded name is local/AUR-only (round-2 review 2026-11-20).
pub fn repo_rows_best_effort(conf: Option<&Path>, names: &[String]) -> Vec<RepoRow> {
    read_repo_rows(conf, names).0
}

/// The real archive extensions (the `.sig` sibling and any `.part` residue
/// sort beside them and are not archives — the same allowlist the
/// pre-transaction hook carries).
const ARCHIVE_EXTENSIONS: [&str; 7] = [
    ".pkg.tar.zst",
    ".pkg.tar.xz",
    ".pkg.tar.gz",
    ".pkg.tar.bz2",
    ".pkg.tar.lrz",
    ".pkg.tar.lzo",
    ".pkg.tar.Z",
];

/// The exact cached archive for one repo row — never a `.sig` sibling and
/// never a partial download (`x.pkg.tar.zst.part` sorts AFTER the real
/// archive, so a suffix blacklist alone would hand the caller the residue).
pub fn cached_archive(cache: &Path, name: &str, version: &str, arch: &str) -> Option<PathBuf> {
    let prefix = format!("{name}-{version}-{arch}");
    let entries = std::fs::read_dir(cache).ok()?;
    let mut found: Vec<PathBuf> = Vec::new();
    for entry in entries.flatten() {
        let file_name = entry.file_name();
        let Some(file_name) = file_name.to_str() else {
            continue;
        };
        let Some(rest) = file_name.strip_prefix(&prefix) else {
            continue;
        };
        if ARCHIVE_EXTENSIONS.contains(&rest) {
            found.push(entry.path());
        }
    }
    found.sort();
    found.pop()
}

/// One out-of-tree name a refusal stands on, with the repo's answer and
/// what its cached bytes would do in this transaction.
pub struct StockUpgrade {
    pub name: String,
    pub installed: String,
    pub repo: String,
    /// What `--with <name>` would actually meet — the hint must not advise a
    /// member the gate would then refuse.
    pub hint: StockHint,
}

/// Whether the repo archive behind a stranded name can join this
/// transaction, and why not when it cannot.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StockHint {
    /// Cached, and no `DT_NEEDED` on the generation this transaction
    /// removes: `--with` adds it with nothing to download.
    Verified,
    /// Cached, but its own links still hit the removed generation — the
    /// repo has not rebuilt it yet, so `--with` would refuse it
    /// (`with-unresolved`) rather than heal anything.
    CachedUnfit,
    /// Not cached: `--with` downloads it and verifies the bytes.
    Absent,
}

/// The repair hint's input (issue #6, §E.3 2026-11-20 amendment): for each
/// out-of-tree name a refusal stands on, the repo version when it differs
/// from the installed one.
///
/// A repo read that fails yields NO entry for THAT name: the refusal already
/// stands on its own, and a hint the engine could not confirm would be a
/// promise it cannot keep. One unknown name never silences the others.
pub fn stock_upgrades(
    stranded: &[(String, String)],
    drift: &[gsa_abi::Drift],
    db: &LocalDb,
    conf: Option<&Path>,
    exclusions: &AbiExclusions,
    transaction: &[&Path],
) -> Vec<StockUpgrade> {
    let mut names: Vec<String> = Vec::new();
    for (_, name) in stranded {
        if db.get(name).is_some() && !names.contains(name) {
            names.push(name.clone());
        }
    }
    if names.is_empty() {
        return Vec::new();
    }
    let repo: BTreeMap<String, (String, String)> = repo_rows_best_effort(conf, &names)
        .into_iter()
        .map(|row| (row.name, (row.version, row.arch)))
        .collect();
    let cache = pacman_cache_dir(conf);
    let mut out = Vec::new();
    for (subject, stranded_name) in stranded {
        let _ = subject;
        let Some((target, arch)) = repo.get(stranded_name) else {
            continue;
        };
        let Some(installed) = db.get(stranded_name) else {
            continue;
        };
        // Strictly newer, never merely different: an installed package
        // ahead of the repo (a local or testing build) is not an upgrade,
        // and `--with` would silently downgrade it. A `vercmp` the engine
        // cannot answer is no hint either (rule 71: unreadable is not a
        // fact).
        if gsa_recipe::sync::vercmp(
            &gsa_recipe::pkginfo::canonical_version(target),
            &gsa_recipe::pkginfo::canonical_version(&installed.version),
        ) != Some(1)
        {
            continue;
        }
        let hint = match cached_archive(&cache, stranded_name, target, arch) {
            None => StockHint::Absent,
            Some(archive) => match archive_fits(&archive, drift, exclusions, db, transaction) {
                Ok(true) => StockHint::Verified,
                // Unreadable bytes are "unverified", never "fits".
                Ok(false) | Err(_) => StockHint::CachedUnfit,
            },
        };
        // Epoch 0 is the default and reads as noise: name the version the
        // way `pacman -Q` shows it.
        let shown = installed
            .version
            .strip_prefix("0:")
            .unwrap_or(&installed.version);
        out.push(StockUpgrade {
            name: stranded_name.clone(),
            installed: shown.to_string(),
            repo: target.clone(),
            hint,
        });
    }
    out
}

/// Would `--with` TRANSACT this cached stock archive? `Err` = unreadable,
/// which is "unverified", never "fits".
///
/// The hint runs the archive through the SAME two predicates the install
/// seam runs (§E.3): `with_old_pins` for a `Depends` on the removed
/// generation, and `with_unresolved` for a `DT_NEEDED` the post-transaction
/// system cannot satisfy (honouring base libs, the exclusions registry, the
/// archive's own provides, the transaction's shipped bytes and the installed
/// DB). One predicate, so `Verified` means exactly "the gate would accept
/// it" — a hint the gate would then refuse is a promise the engine cannot
/// keep (round-2 and round-3 reviews, 2026-11-20).
fn archive_fits(
    archive: &Path,
    drift: &[gsa_abi::Drift],
    exclusions: &AbiExclusions,
    db: &LocalDb,
    transaction: &[&Path],
) -> Result<bool, String> {
    let with = crate::WithArchive::load(archive)?;
    if !with_old_pins(&with, drift).is_empty() {
        return Ok(false);
    }
    let mut archives: Vec<&Path> = transaction.to_vec();
    archives.push(archive);
    let shipped = ShippedBytes::collect(&archives)?;
    Ok(with_unresolved(&with, drift, &shipped, db, exclusions)?.is_empty())
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

    /// A `--with` archive whose `Depends` pins the generation this
    /// transaction removes is refused by name (the pin path had no pin, and
    /// pacman would otherwise fail the transaction in raw noise).
    #[test]
    fn with_pins_on_the_removed_generation_row() {
        let dir = std::env::temp_dir().join(format!("gsa-gates-with-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let build = |name: &str, depends: &[&str]| {
            let stage = dir.join(format!(".stage-{name}"));
            std::fs::create_dir_all(&stage).unwrap();
            let mut body =
                format!("pkgbase = {name}\npkgname = {name}\npkgver = 2.0-1\narch = x86_64\n");
            for dep in depends {
                body.push_str(&format!("depend = {dep}\n"));
            }
            std::fs::write(stage.join(".PKGINFO"), body).unwrap();
            let path = dir.join(format!("{name}-2.0-1-x86_64.pkg.tar.zst"));
            let file = std::fs::File::create(&path).unwrap();
            let enc = zstd::Encoder::new(file, 0).unwrap();
            let mut tar = tar::Builder::new(enc);
            tar.append_path_with_name(stage.join(".PKGINFO"), ".PKGINFO")
                .unwrap();
            tar.into_inner().unwrap().finish().unwrap();
            path
        };
        let drift = vec![gsa_abi::Drift {
            pkgname: "abipkg".to_string(),
            name: "libfoo.so".to_string(),
            inst_ver: "1-64".to_string(),
            built_ver: Some("2-64".to_string()),
        }];
        let stale_archive = build("stale", &["libfoo.so=1-64"]);
        let stale = crate::WithArchive::load(&stale_archive).unwrap();
        assert_eq!(with_old_pins(&stale, &drift), vec!["libfoo.so=1-64"]);
        let fresh_archive = build("fresh", &["libfoo.so=2-64"]);
        let fresh = crate::WithArchive::load(&fresh_archive).unwrap();
        assert!(with_old_pins(&fresh, &drift).is_empty());
        // A bare pin is satisfied by any generation.
        let bare_archive = build("bare", &["libfoo.so"]);
        let bare = crate::WithArchive::load(&bare_archive).unwrap();
        assert!(with_old_pins(&bare, &drift).is_empty());
        // The repair hint's "verified" is the SAME acceptance `--with`
        // applies: an archive pinning the removed generation is advertised
        // only if the gate would transact it (round-2 spec review).
        let no_tx: Vec<&Path> = Vec::new();
        let db = LocalDb::from_packages(Vec::new());
        let exclusions = AbiExclusions::default();
        assert!(
            !archive_fits(&stale_archive, &drift, &exclusions, &db, &no_tx).unwrap(),
            "a stale pin must never be advertised as a verified repair"
        );
        assert!(archive_fits(&fresh_archive, &drift, &exclusions, &db, &no_tx).unwrap());
        assert!(archive_fits(&bare_archive, &drift, &exclusions, &db, &no_tx).unwrap());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn cached_archive_ignores_residue_and_other_versions() {
        let dir = std::env::temp_dir().join(format!("gsa-gates-cache-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let touch = |name: &str| std::fs::write(dir.join(name), b"x").unwrap();
        touch("chafa-1.14.5-1.1-x86_64.pkg.tar.zst");
        touch("chafa-1.14.5-1.1-x86_64.pkg.tar.zst.sig");
        touch("chafa-1.14.5-1.1-x86_64.pkg.tar.zst.part");
        let found = cached_archive(&dir, "chafa", "1.14.5-1.1", "x86_64").unwrap();
        assert_eq!(
            found.file_name().unwrap().to_str().unwrap(),
            "chafa-1.14.5-1.1-x86_64.pkg.tar.zst"
        );
        assert!(cached_archive(&dir, "chafa", "1.14.6-1", "x86_64").is_none());
        let _ = std::fs::remove_dir_all(&dir);
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
