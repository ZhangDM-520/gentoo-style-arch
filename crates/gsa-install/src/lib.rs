//! The install pipeline (contract §E, §I, §K): ONE decision seam producing
//! typed `DecisionRow`s, then the transaction executor (`pacman -U`
//! subprocesses, `sudo -n` only) and the dynamic IgnorePkg registration.
//!
//! "One decision, one seam" (`docs/MEMORY.md` rule 20): `decide()` computes
//! the transaction plan ONCE as typed rows (`install|skip|refuse|noop|parked`,
//! §E.3) with the §E.5 rc contract (0 plan / 1 refusal / 2 bad usage held by
//! the caller). Rendering and execution never re-decide. The hidden
//! `--install-decide` seam prints exactly these rows and touches nothing else
//! — no pacman, sudo, flock, or makepkg (§D.1).
//!
//! Every gate is fail-closed (rule 25(h)): a `refuse` row means no `pacman`
//! call happens anywhere downstream of it.

pub mod exec;
pub mod gates;
pub mod localdb;
pub mod register;

use std::path::{Path, PathBuf};

pub use exec::{execute_txn, preflight_installs, TxnOutcome, TxnRequest};
pub use localdb::{InstalledPackage, LocalDb};
pub use register::{names_for_archive, register_ignorepkg, RegisterReport};

use gsa_model::{Decision, DecisionRow};
use gsa_recipe::pkginfo::{read_pkginfo, Pkginfo};

use gates::AbiExclusions;

/// The decision mode (contract §D.1, §E): `checked` applies the same-version
/// already-installed skip; `force` bypasses it (always `pacman -U`).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum DecideMode {
    #[default]
    Checked,
    Force,
}

/// Parse the seam's mode word. Unknown modes are usage-class (rc 2).
pub fn decide_mode(word: &str) -> Result<DecideMode, String> {
    match word {
        "checked" => Ok(DecideMode::Checked),
        "force" => Ok(DecideMode::Force),
        other => Err(format!(
            "--install-decide: unknown mode '{other}' (want checked|force)"
        )),
    }
}

/// What an empty candidate list means (§B.6, §E.3): a refusal under `-S`
/// (checked), a `noop empty-list` under `-Ua` (force).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum EmptyListPolicy {
    Refuse,
    #[default]
    Noop,
}

/// One archive candidate: a built package archive beside its recipe (house
/// layout, `PKGDEST=$startdir`), or an explicit `-U <archive-path>`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Candidate {
    pub archive: PathBuf,
    /// The recipe directory beside the archive, when there is one — the
    /// second name authority (rule 9) and the PGO-instrumentation witness.
    pub recipe_dir: Option<PathBuf>,
}

/// Everything the decision needs beyond the candidates and the installed DB.
#[derive(Clone, Debug, Default)]
pub struct DecisionContext {
    pub mode: DecideMode,
    /// What a zero-candidate plan means (§B.6).
    pub empty_list: EmptyListPolicy,
    /// Subjects that will be installed later in this same run: in-run repair
    /// coverage for the ABI gate (rule 25(d)) — never a license to skip a
    /// gate for the archive itself.
    pub later_installs: Vec<String>,
    /// Subjects parked before install (cone-stop `waits-on-failed`,
    /// `waits-on-deferred`, or a deferral key). A parked subject's row is
    /// `parked <reason>` and is never installed or probed (§E.3).
    pub parks: Vec<(String, String)>,
    /// Tier-2 ABI exclusions registry override (`config/abi-exclusions.conf`
    /// shape, rule 25(f)) — tests point this at a fixture registry. `None`
    /// resolves `config/abi-exclusions.conf` by walking up from the first
    /// candidate's recipe directory; absent there means the empty registry
    /// (synthetic workspaces).
    pub abi_exclusions: Option<PathBuf>,
    /// Subjects computed into an ABI rebuild wave (`plan-native-pm.md` §4.3):
    /// a wave member's same-version skip is suppressed — the wave must land
    /// wholly, so its archive installs even when the exact version is
    /// already present. Gates are untouched (force never bypasses them).
    pub wave_heal: Vec<String>,
}

/// The discovery result for one recipe directory (house layout: archives
/// beside the recipe; `gsa -U <ref>` and the `-S` per-package install both
/// consume this).
#[derive(Clone, Debug)]
pub struct RecipeArchives {
    pub recipe_dir: PathBuf,
    /// The chosen archive per expected pkgname (by `.PKGINFO` truth):
    /// version-ranked, and one version-coherent set whenever the on-disk
    /// rows admit one.
    pub candidates: Vec<Candidate>,
    /// Expected pkgnames (committed `.SRCINFO`) with no eligible archive —
    /// non-empty means `refuse partial-set <pkgdir> <missing>…`.
    pub missing: Vec<String>,
    /// The chosen set mixes full versions — `refuse partial-set … mixed-versions`.
    pub mixed_versions: bool,
}

/// How discovery ranks same-name candidates.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Rank {
    /// Highest canonical version first (install/claim selection — the
    /// default; equal versions fall to newest mtime, `vercmp` non-answers to
    /// the mtime order).
    Version,
    /// Newest mtime first — build REGISTRATION's rank, not a selection: a
    /// finished build registers the outputs it just wrote (the newest files
    /// in the scan set), never the version-ranked winner. A stale
    /// higher-version archive lying beside the recipe must not become that
    /// build's row — the retention sweep would then protect the stale file
    /// and delete the fresh one (gsa-state-v2's in-flight-guard section).
    Mtime,
}

/// Discover one recipe's best-ranked archive set. Archives are matched by
/// their own `.PKGINFO` (never a glob-all fallback, rule 11) and each
/// archive is chosen version-first per expected pkgname (highest canonical
/// version, newest mtime on a version tie, mtime order whenever `vercmp`
/// cannot rank — never string order). An archive whose `.PKGINFO`
/// cannot be read is NOT a candidate here; the decision seam reports it per
/// rule 25(h) (`skip unreadable-pkginfo` / `refuse discover-failed`).
pub fn discover_recipe(recipe_dir: &Path) -> Result<RecipeArchives, String> {
    discover_recipe_ranked(recipe_dir, Rank::Version)
}

/// [`discover_recipe`] with an explicit ranking policy (see [`Rank`]).
pub fn discover_recipe_ranked(
    recipe_dir: &Path,
    rank: Rank,
) -> Result<RecipeArchives, String> {
    // Expected output names: the committed `.SRCINFO`'s `pkgname` lines —
    // the names built archives actually carry (a recipe whose pkgbase
    // differs from its outputs must never demand an archive named after the
    // pkgbase) — falling back to pkgbase for a base-only record. No
    // `.SRCINFO` means no expectation: every readable archive is eligible.
    let mut expected: Vec<String> = Vec::new();
    let srcinfo_path = recipe_dir.join(".SRCINFO");
    if let Ok(text) = std::fs::read_to_string(&srcinfo_path) {
        let origin = srcinfo_path.to_string_lossy().into_owned();
        if let Ok(info) = gsa_recipe::parse_srcinfo(&text, &origin) {
            if !info.pkgnames.is_empty() {
                expected = info.pkgnames.clone();
            } else if let Some(base) = info.pkgbase.clone() {
                expected.push(base);
            }
        }
    }

    // The chosen archive per expected pkgname, matched by the archive's own
    // `.PKGINFO` truth (never a glob-all fallback, rule 11). An archive
    // whose `.PKGINFO` cannot be read is NOT a candidate here (rule 25(h):
    // direct-archive seams report it via decide() gate 1).
    // W4: archives live in the shared build-user `PKGDEST`; the recipe dir
    // stays in the scan set (pre-W4 trees and fixture stubs write there —
    // contract §J.2) and `.PKGINFO` truth keeps the shared dir from handing
    // over another recipe's archive. The layout comes from the engine's ONE
    // error policy (`build_layout_for_run`): an unusable layout is FATAL for
    // discovery — never a silent fall back to recipe-dir-only trees the
    // build half would not have written to.
    let layout = gsa_model::config::build_layout_for_run()?;
    let scan_dirs = gsa_model::config::archive_dirs(recipe_dir, &layout);
    let mut by_name: Vec<(String, std::time::SystemTime, PathBuf, String)> = Vec::new();
    let mut scanned = false;
    for scan_dir in &scan_dirs {
        let Ok(entries) = std::fs::read_dir(scan_dir) else {
            continue;
        };
        scanned = true;
        for entry in entries.flatten() {
            let path = entry.path();
            if !path.is_file() {
                continue;
            }
            let Some(name) = path.file_name().and_then(|n| n.to_str()) else {
                continue;
            };
            if !name.ends_with(".pkg.tar.zst") {
                continue;
            }
            let Ok(pkginfo) = read_pkginfo(&path) else {
                continue;
            };
            if !expected.is_empty() && !expected.contains(&pkginfo.pkgname) {
                continue;
            }
            let mtime = std::fs::metadata(&path)
                .and_then(|m| m.modified())
                .unwrap_or(std::time::UNIX_EPOCH);
            by_name.push((pkginfo.pkgname, mtime, path, pkginfo.version));
        }
    }
    if !scanned {
        return Err(format!(
            "cannot read recipe dir {}: no archive location is readable",
            recipe_dir.display()
        ));
    }

    let mut names_in_order: Vec<String> = expected.clone();
    if names_in_order.is_empty() {
        names_in_order = by_name.iter().map(|(n, ..)| n.clone()).collect();
        names_in_order.sort();
        names_in_order.dedup();
    }

    // Rank candidates version-first: `vercmp` decides, equal versions fall
    // to the newest mtime, and the mtime presort (path-tiebroken) survives
    // as the order for every pair `vercmp` cannot rank — including its total
    // absence, which must degrade to mtime order, never to string order
    // (epochs and 1.10-vs-1.9 defeat that). A stable sort over the presort
    // keeps every tie deterministic regardless of `read_dir` order.
    by_name.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.2.cmp(&b.2)));
    if rank == Rank::Version {
        by_name.sort_by(|a, b| gsa_recipe::pkginfo::version_rank(&a.3, &b.3));
    }

    // In Version rank a version-coherent set outranks per-name bests: split
    // outputs of one version must move together, and splicing a half-built
    // higher-version output into a complete lower-version set manufactures a
    // `partial-set … mixed-versions` refusal where the mtime-ranked chooser
    // installed a coherent set. When no single version covers every wanted
    // name, the per-name winners stand and the mixed refusal speaks — that
    // class predates this fix and must survive it. Mtime rank is the
    // pre-version-rank registration behaviour and stays per-name bests.
    let chosen_key: Option<String> = if rank == Rank::Version {
        let mut keys: Vec<(String, std::time::SystemTime)> = Vec::new();
        for row in &by_name {
            if let Some(entry) = keys.iter_mut().find(|entry| entry.0 == row.3) {
                if row.1 > entry.1 {
                    entry.1 = row.1;
                }
            } else {
                keys.push((row.3.clone(), row.1));
            }
        }
        keys.sort_by(|a, b| b.1.cmp(&a.1).then_with(|| a.0.cmp(&b.0)));
        keys.sort_by(|a, b| gsa_recipe::pkginfo::version_rank(&a.0, &b.0));
        keys.iter().map(|(key, _)| key.clone()).find(|key| {
            names_in_order
                .iter()
                .filter(|want| by_name.iter().any(|row| &row.0 == *want))
                .all(|want| by_name.iter().any(|row| &row.0 == want && &row.3 == key))
        })
    } else {
        None
    };

    let mut candidates: Vec<Candidate> = Vec::new();
    let mut missing: Vec<String> = Vec::new();
    let mut versions: Vec<String> = Vec::new();
    for want in &names_in_order {
        let best = by_name
            .iter()
            .find(|row| &row.0 == want && chosen_key.as_deref().map_or(true, |key| row.3 == key));
        match best {
            Some((_, _, archive, version)) => {
                candidates.push(Candidate {
                    archive: archive.clone(),
                    recipe_dir: Some(recipe_dir.to_path_buf()),
                });
                versions.push(version.clone());
            }
            None => missing.push(want.clone()),
        }
    }
    versions.sort();
    versions.dedup();

    Ok(RecipeArchives {
        recipe_dir: recipe_dir.to_path_buf(),
        candidates,
        missing,
        mixed_versions: versions.len() > 1,
    })
}

/// The one decision function (contract §E.1). Produces one typed row per
/// candidate — full rows, never exceptions-only (§E.2) — gating in this
/// order: unreadable/name handling, empty list, PGO payload (§E.3 `pgo-*`),
/// ABI/provide (`abi-soname`, `abi-consumer`, `abi-stock-pinner`), the
/// package-internal NEEDED probe (rule 25(b)/(e) file-truth resolution),
/// the QA registry's install-refusing checks (§E.4 `refuse <keyword> …`),
/// then the checked same-version skip (`already-current`) or the force
/// branch (`install`).
///
/// `Err` is the "plan failed without a row" class: the caller renders a
/// single `refuse plan-failed` row (§E.3) and the seam exits 1 (§E.5).
pub fn decide(
    candidates: &[Candidate],
    ctx: &DecisionContext,
    db: &LocalDb,
) -> Result<Vec<DecisionRow>, String> {
    Ok(plan(candidates, ctx, db)?.rows())
}

/// One candidate's parsed identity plus its row block: the decision is
/// computed ONCE (rule 20) and this is the single intermediate the
/// renderer and the executor both consume — never a re-decision.
struct CandidatePlan {
    candidate: Candidate,
    /// The archive's own `.PKGINFO` truth, cached so registration
    /// (`names_for_archive`) never re-reads what the plan already read.
    pkginfo: Option<Pkginfo>,
    rows: Vec<DecisionRow>,
}

struct Plan {
    /// Plan-level rows (the empty-list row — no candidate to attach to).
    plan_rows: Vec<DecisionRow>,
    candidates: Vec<CandidatePlan>,
}

impl Plan {
    fn rows(&self) -> Vec<DecisionRow> {
        let mut rows = self.plan_rows.clone();
        for group in &self.candidates {
            rows.extend(group.rows.iter().cloned());
        }
        rows
    }

    fn refused(&self) -> bool {
        self.plan_rows
            .iter()
            .chain(self.candidates.iter().flat_map(|g| g.rows.iter()))
            .any(|r| r.decision == Decision::Refuse)
    }
}

fn row(subject: &str, decision: Decision, reason: impl Into<String>) -> DecisionRow {
    DecisionRow {
        subject: subject.to_string(),
        decision,
        reason: reason.into(),
    }
}

/// The second name authority (rule 9): the recipe directory's committed
/// `.SRCINFO` pkgbase + pkgnames.
fn recipe_srcinfo_names(recipe_dir: Option<&Path>) -> Vec<String> {
    let Some(dir) = recipe_dir else {
        return Vec::new();
    };
    let path = dir.join(".SRCINFO");
    let Ok(text) = std::fs::read_to_string(&path) else {
        return Vec::new();
    };
    let origin = path.to_string_lossy().into_owned();
    let Ok(info) = gsa_recipe::parse_srcinfo(&text, &origin) else {
        return Vec::new();
    };
    let mut names = Vec::new();
    if let Some(base) = info.pkgbase {
        names.push(base);
    }
    for name in info.pkgnames {
        if !names.contains(&name) {
            names.push(name);
        }
    }
    names
}

/// The ABI subsystem's installed-ELF view over the parsed local DB — the
/// one conversion point; every ABI term (drift, link truth, stock pinners)
/// reads the same rows the decision seam already parsed.
pub fn abi_view(db: &LocalDb) -> gsa_abi::InstalledView {
    gsa_abi::InstalledView::new(db.packages().into_iter().map(|pkg| gsa_abi::InstalledPkg {
        name: pkg.name.clone(),
        version: pkg.version.clone(),
        provides: pkg.provides.clone(),
        depends: pkg.depends.clone(),
        files: pkg.files.clone(),
    }))
}

fn resolve_exclusions(
    ctx: &DecisionContext,
    candidates: &[Candidate],
) -> Result<AbiExclusions, String> {
    if let Some(path) = &ctx.abi_exclusions {
        return AbiExclusions::load(path);
    }
    let start = candidates
        .iter()
        .find_map(|c| c.recipe_dir.as_deref())
        .or(None);
    match gates::find_repo_exclusions(start) {
        Some(path) => AbiExclusions::load(&path),
        None => Ok(AbiExclusions::empty()),
    }
}

/// Checked-mode same-version skip (rule 11): exact canonical full-version
/// match AND an install date (local-DB entry dir mtime) not older than the
/// archive's mtime (nanosecond precision). Any doubt — no install date, no
/// readable archive mtime, no exact match — installs.
fn already_current(info: &Pkginfo, archive: &Path, db: &LocalDb) -> Option<String> {
    let installed = db.get(&info.pkgname)?;
    if installed.version != info.version {
        return None;
    }
    let install_date = installed.install_date?;
    let archive_mtime = std::fs::metadata(archive).ok()?.modified().ok()?;
    if install_date >= archive_mtime {
        Some(installed.version.clone())
    } else {
        None
    }
}

/// The QA gate (contract §E.4): the check registry's install-refusing
/// checks — and only those — extend the ONE decision seam's row stream with
/// `refuse <keyword> …` rows (`gsa_qa::gate`; report-severity checks cannot
/// reach that conversion at all). The input is one candidate's archive plus
/// the recipe beside it (both name authorities, rule 9) and the installed
/// DB; a candidate with no readable committed `.SRCINFO` leaves the check
/// nothing to compare and it stands down (that damage is the discovery
/// gate's `partial-set`/`discover-failed` class).
fn qa_refusals(
    candidate: &Candidate,
    info: &Pkginfo,
    qa_installed: &[gsa_qa::QaInstalled],
) -> Vec<DecisionRow> {
    let mut recipes: Vec<gsa_qa::QaRecipe> = Vec::new();
    let mut recipe_id = String::new();
    if let Some(dir) = candidate.recipe_dir.as_deref() {
        recipe_id = dir
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_default();
        let srcinfo = dir.join(".SRCINFO");
        if let Ok(content) = std::fs::read_to_string(&srcinfo) {
            if let Ok(rows) = gsa_recipe::parse_srcinfo_rows(&content, &srcinfo.to_string_lossy()) {
                recipes.push(gsa_qa::QaRecipe {
                    id: recipe_id.clone(),
                    dir: dir.to_path_buf(),
                    rows,
                });
            }
        }
    }
    let archives = vec![gsa_qa::QaArchive {
        recipe_id,
        path: candidate.archive.clone(),
        pkginfo: Some(info.clone()),
    }];
    let input = gsa_qa::QaInput {
        recipes: &recipes,
        targets: &[],
        archives: &archives,
        installed: qa_installed,
        exclusions: &[],
    };
    gsa_qa::gate::install_refusals(&input)
}

fn plan(candidates: &[Candidate], ctx: &DecisionContext, db: &LocalDb) -> Result<Plan, String> {
    let exclusions = resolve_exclusions(ctx, candidates)?;
    // The ABI subsystem's installed-ELF view over the same parsed DB (one
    // conversion per plan — the drift/link/pinner terms all read it).
    let view = abi_view(db);

    // Empty candidate list (§B.6, §E.3): a refusal under `-S` (checked), a
    // `noop empty-list` under `-Ua` (force). Subject `-` because there is no
    // candidate the row could name.
    if candidates.is_empty() {
        let decision = match ctx.empty_list {
            EmptyListPolicy::Refuse => Decision::Refuse,
            EmptyListPolicy::Noop => Decision::Noop,
        };
        return Ok(Plan {
            plan_rows: vec![row("-", decision, "empty-list")],
            candidates: Vec::new(),
        });
    }

    // Parse every candidate once (rule 20: one read, one decision).
    let parsed: Vec<Option<Pkginfo>> = candidates
        .iter()
        .map(|c| read_pkginfo(&c.archive).ok())
        .collect();
    // The transaction set: every name this plan would install — the
    // coverage side of the ABI gate.
    let tx_names: Vec<String> = parsed
        .iter()
        .flatten()
        .flat_map(|p| [p.pkgbase.clone(), p.pkgname.clone()])
        .collect();
    // Shipped bytes of the set: the NEEDED probe's resolution source (b)
    // (rule 25(b)/(e)). Only gate-1-surviving candidates are indexed — an
    // unreadable-`.PKGINFO` archive is never probed and never transacts.
    let archives: Vec<&Path> = candidates
        .iter()
        .zip(&parsed)
        .filter(|(_, info)| info.is_some())
        .map(|(c, _)| c.archive.as_path())
        .collect();
    let shipped = gates::ShippedBytes::collect(&archives)?;

    // The QA gate's installed-DB view (contract §E.4): one conversion per
    // plan, shared by every candidate's registry consult.
    let qa_installed: Vec<gsa_qa::QaInstalled> = db
        .packages()
        .into_iter()
        .map(|pkg| gsa_qa::QaInstalled {
            name: pkg.name.clone(),
            version: pkg.version.clone(),
            provides: pkg.provides.clone(),
            depends: pkg.depends.clone(),
            files: pkg.files.clone(),
        })
        .collect();

    let mut plans: Vec<CandidatePlan> = Vec::new();
    for (idx, candidate) in candidates.iter().enumerate() {
        let pkginfo = parsed[idx].clone();
        let src_names = recipe_srcinfo_names(candidate.recipe_dir.as_deref());
        let mut name_chain: Vec<String> = Vec::new();
        if let Some(info) = &pkginfo {
            name_chain.push(info.pkgbase.clone());
            name_chain.push(info.pkgname.clone());
        }
        for name in &src_names {
            if !name_chain.contains(name) {
                name_chain.push(name.clone());
            }
        }
        let subject = name_chain
            .first()
            .cloned()
            .unwrap_or_else(|| "-".to_string());

        // Parked subjects stand down before anything else: never probed,
        // never installed (§E.3 `parked`).
        if let Some((_, reason)) = ctx
            .parks
            .iter()
            .find(|(name, _)| name_chain.iter().any(|n| n == name))
        {
            plans.push(CandidatePlan {
                candidate: candidate.clone(),
                pkginfo,
                rows: vec![row(&subject, Decision::Parked, reason.clone())],
            });
            continue;
        }

        // Rule 25(h): an unreadable `.PKGINFO` is never probed. Names come
        // from the second authority (the recipe dir's committed `.SRCINFO`);
        // established → `skip unreadable-pkginfo`; unestablishable →
        // `refuse discover-failed` (rule 9 fail-closed).
        let Some(info) = pkginfo else {
            let rows = if name_chain.is_empty() {
                vec![row(
                    "-",
                    Decision::Refuse,
                    format!("discover-failed {}", candidate.archive.display()),
                )]
            } else {
                vec![row(&subject, Decision::Skip, "unreadable-pkginfo")]
            };
            plans.push(CandidatePlan {
                candidate: candidate.clone(),
                pkginfo: None,
                rows,
            });
            continue;
        };

        let mut rows: Vec<DecisionRow> = Vec::new();
        let archive = candidate.archive.display().to_string();

        // PGO payload gate — only recipes that declare instrumentation can
        // leak a payload (both flag spellings; strict content scan, never
        // shell). Fires BEFORE the ABI gate and the force branch.
        if gates::pgo_instrumented_recipe(candidate.recipe_dir.as_deref()) {
            match gsa_recipe::pkginfo::pgo_hits(&candidate.archive) {
                Err(_) => {
                    rows.push(row(
                        &info.pkgbase,
                        Decision::Refuse,
                        format!("pgo-unreadable {archive}"),
                    ));
                }
                Ok(hits) => {
                    for hit in &hits {
                        rows.push(row(
                            &info.pkgbase,
                            Decision::Refuse,
                            format!("pgo-hit {archive} {hit}"),
                        ));
                    }
                    if !hits.is_empty() {
                        rows.push(row(
                            &info.pkgbase,
                            Decision::Refuse,
                            format!("pgo-instrumented {archive}"),
                        ));
                    }
                }
            }
            if !rows.is_empty() {
                plans.push(CandidatePlan {
                    candidate: candidate.clone(),
                    pkginfo: Some(info),
                    rows,
                });
                continue;
            }
        }

        // ABI/provide gate — a bare `*.so` provide that disappears or
        // version-moves vs the installed provides of the same pkgname (or
        // its stock→house counterpart). Runs BEFORE the force branch: force
        // bypasses the same-version skip, never this gate.
        let drift = gsa_abi::provide_drift(&info.pkgname, &info.provides, &view);
        if !drift.is_empty() {
            // The ABI subsystem computes the refusal rows (contract §E.3's
            // frozen shapes); this seam only folds them into its one plan.
            rows.extend(gsa_abi::abi_refusal_rows(
                &info.pkgbase,
                &archive,
                &drift,
                &view,
                &tx_names,
                &ctx.later_installs,
            ));
            plans.push(CandidatePlan {
                candidate: candidate.clone(),
                pkginfo: Some(info),
                rows,
            });
            continue;
        }

        // Package-internal NEEDED probe (run #53 wall): the archive's own
        // ELF members must resolve via the transaction's provides/bytes or
        // the installed DB's provides/owned files.
        let misses = gates::needed_misses(
            &candidate.archive,
            &info.provides,
            &shipped,
            db,
            &exclusions,
        )?;
        for miss in &misses {
            rows.push(row(
                &info.pkgbase,
                Decision::Refuse,
                format!("needed {} {} {}", archive, miss.member, miss.soname),
            ));
        }
        if !rows.is_empty() {
            plans.push(CandidatePlan {
                candidate: candidate.clone(),
                pkginfo: Some(info),
                rows,
            });
            continue;
        }

        // QA gate (contract §E.4): the registry's install-refusing checks
        // emit `refuse <keyword> …` rows in THIS seam (never a second one;
        // rule 20). Runs BEFORE the force branch — force bypasses the
        // same-version skip, never a gate.
        let qa_rows = qa_refusals(candidate, &info, &qa_installed);
        if !qa_rows.is_empty() {
            rows.extend(qa_rows);
            plans.push(CandidatePlan {
                candidate: candidate.clone(),
                pkginfo: Some(info),
                rows,
            });
            continue;
        }

        // Branch: force installs everything that survived the gates; checked
        // applies the same-version already-current skip (rule 11) — except
        // for a computed ABI-wave member, whose skip is suppressed so the
        // wave lands wholly (plan-native-pm.md §4.5).
        let wave_heal = ctx
            .wave_heal
            .iter()
            .any(|n| name_chain.iter().any(|c| c == n));
        let rows = if ctx.mode == DecideMode::Force || wave_heal {
            vec![row(&info.pkgbase, Decision::Install, "ok")]
        } else {
            match already_current(&info, &candidate.archive, db) {
                Some(version) => vec![row(
                    &info.pkgbase,
                    Decision::Skip,
                    format!("already-current {version}"),
                )],
                None => vec![row(&info.pkgbase, Decision::Install, "ok")],
            }
        };
        plans.push(CandidatePlan {
            candidate: candidate.clone(),
            pkginfo: Some(info),
            rows,
        });
    }

    Ok(Plan {
        plan_rows: Vec::new(),
        candidates: plans,
    })
}

/// The IgnorePkg rollback computation (rule 9's complement): what one step's
/// registration must un-register when its `pacman -U` did not succeed. Only
/// names THIS registration added (`added`) for install-bearing archives are
/// undone — a failed pacman transaction installs nothing — while a name a
/// skip-only (already-current) archive also protects stays registered: it IS
/// installed, and that protection is rule 9's whole point. Names already in
/// the closure before this step are never touched.
///
/// The `-U` path reuses this computation unchanged: its `keep_names` also
/// carries the names of archives whose staged wave LANDED (a landed wave IS
/// installed), so a multi-wave partial success keeps exactly its landed
/// registrations.
pub fn rollback_registration_names(
    added: &[String],
    install_names: &[String],
    keep_names: &[String],
) -> Vec<String> {
    added
        .iter()
        .filter(|name| install_names.contains(name) && !keep_names.contains(name))
        .cloned()
        .collect()
}

/// One `-S` install step: decide, then (on a plan without `refuse`) register
/// the accepted names and run the one `pacman -U` transaction. Returns the
/// decision rows and the transaction outcome — `None` when nothing
/// transacted (all rows `skip`/`parked`) or when a `refuse` row aborted the
/// run in the refusal class before any pacman call (rule 25(h)).
pub fn install_built_package(
    recipe_dir: &Path,
    run: &InstallRun,
) -> Result<(Vec<DecisionRow>, Option<TxnOutcome>), String> {
    let discovered = discover_recipe(recipe_dir)?;

    // Discovery damage owns the plan: a shrunken set is never installed
    // silently (rule 11; fish `install_plan`'s `_GSA_DISCOVER_REFUSALS`).
    if !discovered.missing.is_empty() {
        return Ok((
            vec![row(
                "-",
                Decision::Refuse,
                format!(
                    "partial-set {} {}",
                    discovered.recipe_dir.display(),
                    discovered.missing.join(" ")
                ),
            )],
            None,
        ));
    }
    if discovered.mixed_versions {
        return Ok((
            vec![row(
                "-",
                Decision::Refuse,
                format!(
                    "partial-set {} mixed-versions",
                    discovered.recipe_dir.display()
                ),
            )],
            None,
        ));
    }

    let ctx = DecisionContext {
        mode: run.mode,
        empty_list: match run.mode {
            DecideMode::Checked => EmptyListPolicy::Refuse,
            DecideMode::Force => EmptyListPolicy::Noop,
        },
        later_installs: run.later_installs.clone(),
        parks: Vec::new(),
        abi_exclusions: None,
        wave_heal: Vec::new(),
    };
    let db_root = localdb::pacman_db_root();
    let db = LocalDb::load(&db_root)?;
    let plan = plan(&discovered.candidates, &ctx, &db)?;
    let rows = plan.rows();
    if plan.refused() {
        return Ok((rows, None));
    }

    // Rule 9: every ACCEPTED archive (install AND skip rows) has its
    // pkgbase+pkgname registered before anything can install it. Parked
    // subjects are not accepted.
    let accepted: Vec<&CandidatePlan> = plan
        .candidates
        .iter()
        .filter(|group| {
            !group.rows.is_empty()
                && group
                    .rows
                    .iter()
                    .all(|r| matches!(r.decision, Decision::Install | Decision::Skip))
        })
        .collect();
    // The registration's write set, kept for the failed-transaction rollback
    // (rule 9's complement): (conf, added, install-bearing names,
    // already-current names).
    let mut registered: Option<(PathBuf, Vec<String>, Vec<String>, Vec<String>)> = None;
    if run.register_ignorepkg {
        if !accepted.is_empty() {
            let conf = run
                .conf
                .clone()
                .unwrap_or_else(|| PathBuf::from("/etc/pacman.conf"));
            let mut names: Vec<String> = Vec::new();
            // The transaction-role partition the failed-transaction rollback
            // (below) needs: install-bearing archives vs already-current
            // skips.
            let mut install_names: Vec<String> = Vec::new();
            let mut keep_names: Vec<String> = Vec::new();
            for group in &accepted {
                let established = names_for_archive(
                    group.pkginfo.as_ref(),
                    group.candidate.recipe_dir.as_deref(),
                )?;
                let installs = group.rows.iter().any(|r| r.decision == Decision::Install);
                for name in established {
                    if !names.contains(&name) {
                        names.push(name.clone());
                    }
                    let bucket = if installs {
                        &mut install_names
                    } else {
                        &mut keep_names
                    };
                    if !bucket.contains(&name) {
                        bucket.push(name);
                    }
                }
            }
            names.sort();
            let subject = format!("{} name(s) from {} archive(s)", names.len(), accepted.len());
            let report = register_ignorepkg(&conf, &subject, &names, &db_root)?;
            // The registration's exact write set: the only names the
            // rollback below may ever un-register.
            registered = Some((conf, report.added, install_names, keep_names));
        }
    } else if !accepted.is_empty() {
        eprintln!(
            "gsa: warning: IgnorePkg registration skipped (--no-register-ignorepkg) — {} archive name(s) were NOT added to the pacman.conf closure",
            accepted.len()
        );
    }

    let install_archives: Vec<PathBuf> = plan
        .candidates
        .iter()
        .filter(|group| group.rows.iter().any(|r| r.decision == Decision::Install))
        .map(|group| group.candidate.archive.clone())
        .collect();
    if install_archives.is_empty() {
        return Ok((rows, None));
    }
    let outcome = execute_txn(&TxnRequest {
        state_dir: run.state_dir.clone(),
        conf: run.conf.clone(),
        archives: install_archives,
        pacman_args: run.pacman_args.clone(),
    });
    // Rule 9's complement: the before-ordering stands, but a transaction that
    // did not succeed must never leave names registered that it never
    // installed (a failed `pacman -U` installs nothing — the transaction is
    // atomic), or future `-Syu` silently skips them forever. Roll back this
    // registration's install-bearing additions; a hard crash between the
    // registration and this point is the known residual — the dated pre-image
    // backup (`<conf>.bak-YYYYMMDD`) is the manual recovery.
    if outcome != TxnOutcome::Ok {
        if let Some((conf, added, install_names, keep_names)) = &registered {
            let rollback = rollback_registration_names(added, install_names, keep_names);
            if !rollback.is_empty() {
                match register::prune_ignorepkg(
                    conf,
                    "rollback: the install transaction did not succeed",
                    &rollback,
                    &db_root,
                ) {
                    Ok(pruned) => eprintln!(
                        "gsa: note: rolled back IgnorePkg registration of {} name(s) never installed ({})",
                        pruned.removed.len(),
                        pruned.removed.join(", ")
                    ),
                    Err(error) => eprintln!(
                        "gsa: warning: IgnorePkg rollback failed in {} ({error}) — {} stay registered although the transaction did not install them (pre-image backup: {}.bak-<YYYYMMDD>)",
                        conf.display(),
                        rollback.join(", "),
                        conf.display()
                    ),
                }
            }
        }
    }
    // The installed-ABI record (plan §4.1): every archive this step
    // INSTALLED records its `:=` subscriptions — what its DT_NEEDED linked
    // at build time, against the providers' recorded tokens. A recording
    // failure is loud but never aborts a landed transaction: the wave
    // planner fails toward whole-closure on missing records (never under).
    if outcome == TxnOutcome::Ok {
        for group in &plan.candidates {
            if !group.rows.iter().any(|r| r.decision == Decision::Install) {
                continue;
            }
            let recipe_id = group
                .candidate
                .recipe_dir
                .as_deref()
                .and_then(|d| d.file_name())
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| info_name(group));
            // The in-run repair contract (rule 25(d)): the marked recipe's
            // own install consumes its forced-rebuild marker — only what
            // actually installed clears it, so a skipped build, a refused
            // plan or a failed transaction leaves the marker pending (fish
            // `repair_markers_clear`). Without this the read side would make
            // a marked recipe rebuild forever.
            let marker = run.state_dir.join("abi-repair").join(&recipe_id);
            if marker.exists() {
                if let Err(error) = std::fs::remove_file(&marker) {
                    eprintln!(
                        "gsa: note: abi-repair marker {} could not be consumed after install: {error} (the read side will mark {recipe_id} for rebuild again)",
                        marker.display()
                    );
                }
            }
            let Some(info) = group.pkginfo.as_ref() else {
                continue;
            };
            if let Err(error) = record_subscriptions(
                &run.state_dir,
                &recipe_id,
                &info.version,
                &group.candidate.archive,
                &db,
            ) {
                eprintln!(
                    "gsa: note: subscription record failed for {recipe_id}: {error} (wave planning will fail toward whole-closure)"
                );
            }
        }
    }
    Ok((rows, Some(outcome)))
}

/// The pkgname fallback for a consumer identity without a recipe dir.
fn info_name(group: &CandidatePlan) -> String {
    group
        .pkginfo
        .as_ref()
        .map(|i| i.pkgname.clone())
        .unwrap_or_else(|| "-".to_string())
}

/// Record one freshly installed consumer's `:=` subscriptions into the
/// state root (the installed-ABI record, plan §4.1/contract §J.1) — the ONE
/// recording path both install families share. Provider identity and token
/// come from the binpkg index when a built instance is recorded (its
/// `abi_token` is `gsa-abi`'s one derivation), else from the provider's
/// installed surface (derived; the recipe's `abi-rev=` is unknown at this
/// seam, so a derived-only record can only ever OVER-fire a wave, never
/// under — the fail-toward direction).
pub fn record_subscriptions(
    state_root: &Path,
    consumer: &str,
    version: &str,
    consumer_archive: &Path,
    db: &LocalDb,
) -> Result<Vec<gsa_abi::Subscription>, String> {
    let view = abi_view(db);
    let state = gsa_state::StateRoot::open(state_root).map_err(|e| e.to_string())?;
    let index = gsa_state::BinpkgIndex::load(&state).map_err(|e| e.to_string())?;
    let resolve = |pkg: &gsa_abi::InstalledPkg| -> Option<(String, String)> {
        for row in &index.rows {
            if row.pkgnames.iter().any(|n| n == &pkg.name) {
                return Some((row.recipe_id.clone(), row.abi_token.clone()));
            }
        }
        let token = gsa_abi::token_for_installed(pkg, &view, None);
        Some((pkg.name.clone(), token.effective))
    };
    gsa_abi::record_install(
        state_root,
        consumer,
        version,
        consumer_archive,
        &view,
        &resolve,
    )
}

/// The transaction-side inputs of one `-S`/`-U` run (contract §B.4/§B.6).
#[derive(Clone, Debug)]
pub struct InstallRun {
    pub mode: DecideMode,
    /// State root (the transaction mutex lives under `<state>/locks/`).
    pub state_dir: PathBuf,
    /// Target pacman.conf (`--config`), used for IgnorePkg registration and
    /// passed to the `pacman -U` subprocess.
    pub conf: Option<PathBuf>,
    /// Trailing `-- <pacman args…>` forwarded verbatim to the transaction
    /// (today's `-ia --overwrite '*'` idiom), before the archive list.
    pub pacman_args: Vec<String>,
    /// False under `--no-register-ignorepkg` (the skip is loud).
    pub register_ignorepkg: bool,
    /// In-run repair coverage (rule 25(d)).
    pub later_installs: Vec<String>,
}

/// Render the seam's stdout rows (§E.2) — one row per line.
pub fn render_rows(rows: &[DecisionRow]) -> String {
    let mut out = String::new();
    for row in rows {
        out.push_str(&row.render());
        out.push('\n');
    }
    out
}

/// The seam's rc contract (§E.5): 0 = plan with no `refuse` row, 1 = the
/// plan contains at least one `refuse` row. (2 is the caller's usage class.)
pub fn rows_rc(rows: &[DecisionRow]) -> i32 {
    if rows
        .iter()
        .any(|r| r.decision == gsa_model::Decision::Refuse)
    {
        1
    } else {
        0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn rollback_unregisters_only_this_steps_added_uninstalled_names() {
        // Plain case: everything the step added for its install-bearing
        // archive goes back when the transaction does not succeed.
        assert_eq!(
            rollback_registration_names(
                &names(&["foo", "foo-docs"]),
                &names(&["foo", "foo-docs"]),
                &[]
            ),
            names(&["foo", "foo-docs"])
        );
        // A name already in the closure before this step (not in `added`) is
        // never touched.
        assert_eq!(
            rollback_registration_names(&names(&["foo-docs"]), &names(&["foo", "foo-docs"]), &[]),
            names(&["foo-docs"])
        );
        // Split package: the skip-only sibling IS installed — its names stay
        // registered, including the pkgbase shared with the failed output.
        assert_eq!(
            rollback_registration_names(
                &names(&["z", "z-sub1", "z-sub2"]),
                &names(&["z", "z-sub1"]),
                &names(&["z", "z-sub2"]),
            ),
            names(&["z-sub1"])
        );
        // Skip-only step (already-current names): nothing transacted, so
        // nothing rolls back.
        assert_eq!(
            rollback_registration_names(&names(&["bar"]), &[], &names(&["bar"])),
            Vec::<String>::new()
        );
    }
}
