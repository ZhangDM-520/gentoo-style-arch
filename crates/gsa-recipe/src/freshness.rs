//! Freshness gates for the `--skip` / `--skip-built` resume idiom
//! (`docs/gsa-contract.md` §B.8, `docs/build-guide.md` "Skip and resume").
//!
//! Local part: complete output set (every expected archive present,
//! `pacman -Qp`-readable, manifest-v2 sha256+size identity match) plus the
//! PKGBUILD-mtime gate (`--skip`) or the recipe-change gate (`--skip-built`).
//! Remote part: VCS freshness baselines (`<archive>.gsa-vcs-revisions`
//! manifest format 2) probed through a `git ls-remote`-class transport with
//! the permanent-vs-retryable classification (exit 0/2 = completed answer,
//! anything else = transport, retried with the bounded backoff schedule).
//! An unverifiable upstream is a DEFERRAL (`upstream-unverified`), never a
//! silent skip; checksum identity mismatches rebuild once to re-record.
//!
//! The module is split like the seam it ports: [`decide`] is a PURE decision
//! function (no IO — fully unit-testable) consuming an explicit
//! [`FreshnessContext`], and the `pub fn` IO helpers below it (discovery,
//! payload probe, baseline record/parse, remote probes) are what the CLI
//! wiring calls to fill that context. The port target is the fish reference
//! (`freshness_skip_decision`, `vcs_archive_is_current` and friends); where
//! fish semantics were ambiguous the deviation is documented at the exact
//! site, never silently reinterpreted.
//!
//! Environment inputs are exactly `GSA_VCS_SKIP_TOLERANCE` and `TMPDIR`
//! (contract §D.2: `GSA_FAKE_*` is fixture vocabulary and must never be read
//! here). Every external tool is resolved through `PATH` (`git`, `pacman`,
//! `svn`, `hg`, `bzr`) so tests and fixtures can stub them, and every retry
//! sleep goes through an injected sleeper so no caller ever blocks in a test.

use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, UNIX_EPOCH};

use sha2::{Digest, Sha256};

use crate::{parse_srcinfo, scan_pkgbuild, ScanValue, VcsKind};

// ---------------------------------------------------------------------------
// Reason keys (contract §H.3) — the exact strings the run record carries.
// ---------------------------------------------------------------------------

/// A skip whose complete set is verified-unchanged: no waiver, no claim to
/// make beyond "already built and still current".
pub const REASON_OK: &str = "ok";
/// A `--skip-built` claim: "built remains built", version-agnostic and
/// freshness-blind by design (a different claim from [`REASON_OK`]).
pub const REASON_SKIP_BUILT: &str = "skip-built";
/// A `--skip` claim whose ref moved within the measured freshness tolerance.
pub const REASON_FRESHNESS_WAIVED: &str = "freshness-waived";
/// A `--skip` claim whose ref moved but the recipe is a marked ABI provider:
/// upstream movement never rebuilds it (policy waiver, not tolerance).
pub const REASON_ABI_PROVIDER_WAIVED: &str = "abi-provider-waived";
/// The only deferral this module emits: upstream state unverifiable and the
/// consumer chain can absorb the wait (§H.3 `deferred`, lane rc 99).
pub const REASON_UPSTREAM_UNVERIFIED: &str = "upstream-unverified";

/// Build-reason keys. A [`Verdict::Build`] renders as `"<key>: <detail>"`;
/// the keys are kebab and stable, the detail is human prose. §H.3 does not
/// enumerate rebuild reasons (they are diagnostics, not row reasons), so the
/// vocabulary lives here where the decision order is defined.
pub mod build_reason {
    /// A pending ABI repair outranks every freshness claim — a skipped
    /// consumer is never rebuilt, so it would strand its installed outputs.
    pub const ABI_REPAIR_PENDING: &str = "abi-repair-pending";
    /// pkgver/pkgrel or the expected output set could not be established.
    pub const DISCOVERY_UNESTABLISHED: &str = "discovery-unestablished";
    /// Fresh workspace (or only stale versions): nothing to claim.
    pub const NOTHING_BUILT: &str = "nothing-built";
    /// A half-written split set — never blessed, named in the detail.
    pub const PARTIAL_OUTPUT_SET: &str = "partial-output-set";
    /// `--skip` mtime gate: the PKGBUILD postdates some archive.
    pub const RECIPE_NEWER: &str = "recipe-newer";
    /// `--skip-built` gate: the recipe changed since the claimed set was built.
    pub const RECIPE_CHANGED: &str = "recipe-changed";
    /// `pacman -Qp` cannot read the archive end to end (interrupted write?).
    pub const ARCHIVE_UNREADABLE: &str = "archive-unreadable";
    /// No recorded VCS baseline: rebuild once to record one.
    pub const VCS_BASELINE_MISSING: &str = "vcs-baseline-missing";
    /// The baseline violates manifest format 2 or belongs to different sources.
    pub const VCS_BASELINE_MALFORMED: &str = "vcs-baseline-malformed";
    /// The baseline is bound to different archive bytes.
    pub const VCS_BASELINE_IDENTITY: &str = "vcs-baseline-identity";
    /// The baseline has no matching key/protocol row for a declared source.
    pub const VCS_BASELINE_KEY: &str = "vcs-baseline-key";
    /// A selected ref moved past every waiver.
    pub const VCS_REF_MOVED: &str = "vcs-ref-moved";
    /// A pinned `#commit=` ref does not match the recorded revision (local
    /// inconsistency, not movement — even an ABI provider rebuilds).
    pub const VCS_REF_PINNED_MISMATCH: &str = "vcs-ref-pinned-mismatch";
    /// Fallback build when freshness is unverifiable and consumers cannot wait.
    pub const VCS_UNVERIFIABLE: &str = "vcs-unverifiable";
}

/// The informational measurement window for ABI-provider freshness waivers:
/// how much upstream movement a marked recipe's loud line can count exactly.
/// 64 absorbs days of llvm-project movement ("dozens of commits an hour")
/// while staying a bounded, commits-only fetch; past it the line names the
/// window instead of inventing a count (fish `_VCS_ABI_ADVANCE_WINDOW`).
pub const VCS_ABI_ADVANCE_WINDOW: u64 = 64;

/// Default freshness tolerance: how many upstream commits a recorded
/// baseline may trail a moving Git ref before `--skip` stops waiving.
pub const DEFAULT_VCS_SKIP_TOLERANCE: u64 = 5;

// ---------------------------------------------------------------------------
// Pure decision layer
// ---------------------------------------------------------------------------

/// Which claim the caller is making (fish `SKIP_MODE`, `build_package`'s
/// `skip_flag`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SkipMode {
    /// `-s` / `--skip`: the full freshness analysis (local gates + VCS
    /// probes with waiver collection).
    Skip,
    /// `--skip-built`: the built-set claim only — newest complete set at ANY
    /// version; no upstream probes (nothing in this mode may touch the
    /// network), no waivers; the recipe-change gate replaces the mtime gate.
    SkipBuilt,
}

/// The state of archive discovery, mirroring fish `current_archives` /
/// `newest_complete_archives` status 0/1/2/3.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DiscoveryStatus {
    /// 0: every expected output has an archive in the claim set.
    Complete,
    /// 1: nothing current (fresh workspace, or only stale versions).
    Nothing,
    /// 2: some outputs covered — the one state that must never bless a skip
    /// or an install (a split set cut apart by a mid-packaging SIGKILL).
    Partial,
    /// 3: discovery could not be established (pkgver/pkgrel evaluation
    /// failed or the expected output set yielded nothing usable).
    Unestablished,
}

/// One discovery result: the covered archives, the expected outputs with no
/// archive, whether the read path established the claim at all, and the
/// PV-PR key grouping the set (the `--skip-built` claim key is the newest
/// complete key; `--skip` keys to the recipe's committed version).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Discovery {
    /// Archives that map to an expected output at the claim's version key.
    pub archives: Vec<PathBuf>,
    /// Expected output names with no archive (named on a partial set).
    pub missing: Vec<String>,
    /// `false` = status 3: no archive set may ever be blessed.
    pub established: bool,
    /// The `PV-PR` key grouping the set (epoch-prefixed PV), when established.
    pub version_key: Option<String>,
}

impl Discovery {
    /// The fish 0/1/2/3 contract, typed.
    pub fn status(&self) -> DiscoveryStatus {
        if !self.established {
            return DiscoveryStatus::Unestablished;
        }
        if self.missing.is_empty() {
            return DiscoveryStatus::Complete;
        }
        if self.archives.is_empty() {
            return DiscoveryStatus::Nothing;
        }
        DiscoveryStatus::Partial
    }
}

/// Per-archive revision-baseline state (the `<archive>.gsa-vcs-revisions`
/// sidecar, manifest format 2). Only meaningful when the archive has VCS
/// sources at all; a non-VCS archive is current by its local gates alone.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum BaselineState {
    /// Present, format-2, identity-bound to the exact archive bytes, and
    /// every declared source has a matching key/protocol row.
    Ok,
    /// No baseline recorded at all.
    Missing,
    /// Present but violating format 2, or its rows belong to different
    /// sources than the recipe declares.
    Malformed,
    /// Recorded for a different build of the archive (sha256/size mismatch):
    /// a SIGKILL during a later rebuild must never let the old record bless
    /// whatever the kill left behind at the final archive name.
    IdentityMismatch,
    /// Structurally fine but a declared source has no matching row (key or
    /// protocol mismatch). `source` names the first offender.
    KeyMismatch { source: String },
}

/// Per-VCS-source remote state: what the probe learned about the declared
/// ref compared to the recorded revision.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RemoteRevisionState {
    /// The declared ref still resolves to the recorded revision (for a
    /// pinned Git `#commit=` ref: the recorded revision starts with the
    /// pinned value — pins may be short hashes).
    Unchanged,
    /// The ref moved. `Some(d)` is a MEASURED commit distance (`d >= 1`);
    /// `None` means unmeasurable or not applicable (non-git revisions have
    /// no commit distance). Unmeasurable never counts as a small move.
    Moved { distance: Option<u64> },
    /// A pinned `#commit=` ref does not match the recorded revision — local
    /// inconsistency, not upstream movement: no waiver applies.
    PinnedMismatch,
    /// The current state cannot be established (transport exhausted, source
    /// array unevaluable, ref unparseable) — the deferral class.
    Unverifiable { error: String },
    /// The ref resolves to a definite revision but there is no usable
    /// baseline to compare it against (`BaselineState` other than `Ok`).
    /// Probe-only filler: only queryability is meaningful here.
    Resolved,
}

/// One VCS source's probe record within one archive.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VcsSourceState {
    /// The 64-hex `vcs_source_key` of the expanded source entry (the
    /// manifest row key; hashed so records never expose credential-bearing
    /// URLs).
    pub key: String,
    /// `source_filename` of the entry — what diagnostics name.
    pub name: String,
    /// `None` when the entry could not be parsed at all.
    pub protocol: Option<VcsKind>,
    /// The declared ref is a Git `#commit=` pin (immutable input).
    pub pinned: bool,
    /// What the probe learned (see [`RemoteRevisionState`]).
    pub remote: RemoteRevisionState,
}

/// One archive's probe result: baseline state plus per-source remote state,
/// in declaration order (the fish per-entry loop's first-non-current-outcome
/// precedence is preserved by [`decide`] iterating in this order).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArchiveFreshness {
    pub archive: PathBuf,
    /// `None` when the archive has no VCS sources (its freshness is entirely
    /// the local gates); otherwise the sidecar's state.
    pub baseline: Option<BaselineState>,
    /// Empty when the archive has no VCS sources; otherwise the sources in
    /// declaration order. When `baseline` is not `Ok` the remote states
    /// carry queryability only ([`RemoteRevisionState::Resolved`] /
    /// [`RemoteRevisionState::Unverifiable`]).
    pub sources: Vec<VcsSourceState>,
}

impl ArchiveFreshness {
    /// A probe record for one archive (no VCS sources until pushed).
    pub fn new(archive: impl Into<PathBuf>) -> Self {
        ArchiveFreshness {
            archive: archive.into(),
            baseline: None,
            sources: Vec::new(),
        }
    }
}

/// Everything [`decide`] needs — the caller's IO probes, already reduced to
/// facts. No IO happens inside the decision.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FreshnessContext {
    /// The recipe's directory basename: what ABI-waiver lines name as the
    /// provider id.
    pub recipe_name: String,
    /// Which claim is being made.
    pub skip_mode: SkipMode,
    /// The claim set discovery (current-version set for [`SkipMode::Skip`],
    /// newest complete set for [`SkipMode::SkipBuilt`]).
    pub discovery: Discovery,
    /// Per-archive `pacman -Qp` results. Doubt fails CLOSED here: a missing
    /// entry counts as unreadable (the opposite of install's doubt-installs —
    /// an unreadable archive is never evidence of a build).
    pub payload_ok: std::collections::HashMap<PathBuf, bool>,
    /// `--skip` mtime gate: archives the PKGBUILD postdates (`test PKGBUILD
    /// -nt archive`). Any member invalidates the set.
    pub pkgbuild_newer_than: Vec<PathBuf>,
    /// `--skip-built` gate: archives whose build the recipe has changed since
    /// (`recipe_changed_since_build`). Any member invalidates the set.
    pub recipe_changed_since: Vec<PathBuf>,
    /// Per-archive VCS probe records for the claimed set, in any order.
    pub archives_probe: Vec<ArchiveFreshness>,
    /// The resolved freshness tolerance (`resolve_vcs_skip_tolerance`).
    pub tolerance: u64,
    /// The recipe carries a `.gsa-abi-provider` marker: upstream movement
    /// NEVER rebuilds it (only measured skew or an explicit build does).
    pub abi_provider: bool,
    /// A pending ABI repair marker: a rebuild this run still owes against a
    /// moved provider surface. Outranks every freshness claim.
    pub pending_abi_repair: bool,
    /// The consumer chain can absorb a deferral (the caller's
    /// `unverifiable_defer_plan` answer). `false` = fall back to a normal
    /// build attempt instead of parking the recipe.
    pub absorb_wait: bool,
}

impl FreshnessContext {
    /// A context for one claim with the conservative defaults: tolerance 5,
    /// no waivers, no gates, consumers can absorb a wait.
    pub fn new(recipe_name: impl Into<String>, skip_mode: SkipMode) -> Self {
        FreshnessContext {
            recipe_name: recipe_name.into(),
            skip_mode,
            discovery: Discovery::default(),
            payload_ok: std::collections::HashMap::new(),
            pkgbuild_newer_than: Vec::new(),
            recipe_changed_since: Vec::new(),
            archives_probe: Vec::new(),
            tolerance: DEFAULT_VCS_SKIP_TOLERANCE,
            abi_provider: false,
            pending_abi_repair: false,
            absorb_wait: true,
        }
    }
}

/// The verdict of the freshness gate.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Verdict {
    /// Claim the set. `reason` is one of the §H.3 success keys: [`REASON_OK`],
    /// [`REASON_SKIP_BUILT`], [`REASON_FRESHNESS_WAIVED`],
    /// [`REASON_ABI_PROVIDER_WAIVED`]. A waiver row keeps its waiver reason,
    /// never a bare `ok`.
    Skip {
        reason: &'static str,
        waiver_lines: Vec<String>,
        archives: Vec<PathBuf>,
    },
    /// Take the ordinary build path. `reason` is `"<kebab key>: <detail>"`
    /// with keys from [`build_reason`].
    Build { reason: String },
    /// Park the recipe (lane rc 99): [`REASON_UPSTREAM_UNVERIFIED`] is the
    /// only key this module emits.
    Defer { reason: &'static str },
}

impl Verdict {
    /// The kebab key of a [`Verdict::Build`] reason (the part before `": "`),
    /// or the §H.3 key of a skip/deferral — for run-record rows and tests.
    pub fn reason_key(&self) -> &str {
        match self {
            Verdict::Skip { reason, .. } => reason,
            Verdict::Defer { reason } => reason,
            Verdict::Build { reason } => reason.split(": ").next().unwrap_or(reason.as_str()),
        }
    }
}

fn build(key: &'static str, detail: impl AsRef<str>) -> Verdict {
    Verdict::Build {
        reason: format!("{key}: {}", detail.as_ref()),
    }
}

fn unverifiable_verdict(ctx: &FreshnessContext, error: &str) -> Verdict {
    if ctx.absorb_wait {
        return Verdict::Defer {
            reason: REASON_UPSTREAM_UNVERIFIED,
        };
    }
    build(
        build_reason::VCS_UNVERIFIABLE,
        format!(
            "cannot verify upstream VCS freshness: {error} — consumers cannot wait, falling back to a normal build attempt"
        ),
    )
}

/// The waiver one moved source earns, if any: `(claim reason, waiver line)`.
///
/// Tolerance waiver: git non-pinned refs only, and only when the measured
/// advance is a positive integer STRICTLY below the tolerance — unmeasurable
/// is never a small move. The ABI-provider waiver is policy, any distance,
/// any VCS kind (svn/hg/bzr have no commit distance and waive the same way),
/// and it is purely the 0/1 boundary: it never softens the deferral (rc 2)
/// or the rebuild-to-record (rc 3) classes. Pinned Git commits are immutable
/// inputs and cannot advance at all — they never reach here.
fn waiver_for(
    src: &VcsSourceState,
    tolerance: u64,
    abi_provider: bool,
    recipe_name: &str,
    distance: Option<u64>,
) -> Option<(&'static str, String)> {
    let git_moving = src.protocol == Some(VcsKind::Git) && !src.pinned;
    if abi_provider {
        let claim = if git_moving {
            match distance {
                Some(d) if d >= 1 => format!("upstream moved {d} commit(s)"),
                // Never invent a count the window could not measure.
                _ => format!(
                    "upstream moved past the measurement window ({VCS_ABI_ADVANCE_WINDOW} commits)"
                ),
            }
        } else {
            "upstream revision moved".to_string()
        };
        return Some((
            REASON_ABI_PROVIDER_WAIVED,
            format!(
                "{claim} — {recipe_name} is an ABI provider; freshness waived (rebuild only on measured skew or an explicit build)"
            ),
        ));
    }
    if git_moving {
        if let Some(d) = distance {
            if d >= 1 && d < tolerance {
                return Some((
                    REASON_FRESHNESS_WAIVED,
                    format!(
                        "upstream moved {d} commit(s) < tolerance {tolerance} — treating {} as current",
                        src.name
                    ),
                ));
            }
        }
    }
    None
}

/// THE skip decision — the pure port of fish `freshness_skip_decision` in the
/// same ORDER: repair marker → discovery → mtime/recipe-change gate →
/// payload gate → `--skip-built` early claim → per-archive VCS probes with
/// waiver collection. Build reasons carry their kebab key; skip/deferral
/// reasons are the verbatim §H.3 keys.
pub fn decide(ctx: &FreshnessContext) -> Verdict {
    // A pending ABI repair outranks every freshness claim below: a skipped
    // consumer is never rebuilt — a skip here would strand its installed
    // outputs forever — so both skip modes must build instead.
    if ctx.pending_abi_repair {
        return build(
            build_reason::ABI_REPAIR_PENDING,
            "pending ABI repair (a provider's soname surface moved) — forcing rebuild, not skip",
        );
    }

    // Discovery: `--skip` keys to the recipe's current pkgver-pkgrel,
    // `--skip-built` to the newest complete set at any version.
    match ctx.discovery.status() {
        DiscoveryStatus::Unestablished => {
            return build(
                build_reason::DISCOVERY_UNESTABLISHED,
                "archive discovery could not be established (pkgver/pkgrel or expected outputs unevaluable)",
            );
        }
        DiscoveryStatus::Nothing => {
            return build(
                build_reason::NOTHING_BUILT,
                "no built archive for any expected output",
            );
        }
        DiscoveryStatus::Partial => {
            return build(
                build_reason::PARTIAL_OUTPUT_SET,
                format!(
                    "built output set is incomplete (missing: {}) — rebuilding",
                    ctx.discovery.missing.join(" ")
                ),
            );
        }
        DiscoveryStatus::Complete => {}
    }
    let archives = &ctx.discovery.archives;

    // Recipe gates. `--skip`: a PKGBUILD newer than any member means the
    // whole set predates the recipe (nanosecond mtimes). `--skip-built`: the
    // gate REPLACES the mtime compare — a pull that only touches the mtime is
    // churn, a commit (or, without git metadata, the mtime fallback) after
    // the set is evidence; one changed member invalidates the set.
    match ctx.skip_mode {
        SkipMode::Skip => {
            let stale: Vec<String> = ctx
                .pkgbuild_newer_than
                .iter()
                .map(|p| short_name(p))
                .collect();
            if !stale.is_empty() {
                return build(
                    build_reason::RECIPE_NEWER,
                    format!("PKGBUILD is newer than {} — rebuilding", stale.join(" ")),
                );
            }
        }
        SkipMode::SkipBuilt => {
            let stale: Vec<String> = ctx
                .recipe_changed_since
                .iter()
                .map(|p| short_name(p))
                .collect();
            if !stale.is_empty() {
                return build(
                    build_reason::RECIPE_CHANGED,
                    format!(
                        "recipe changed since the build of {} — rebuilding",
                        stale.join(" ")
                    ),
                );
            }
        }
    }

    // Payload gate: pacman -Qp decompresses the whole zstd stream before
    // answering, so a write killed at ANY offset fails it. Doubt fails closed.
    for archive in archives {
        if !ctx.payload_ok.get(archive).copied().unwrap_or(false) {
            return build(
                build_reason::ARCHIVE_UNREADABLE,
                format!(
                    "{} cannot be read as a package archive (interrupted write?) — rebuilding",
                    short_name(archive)
                ),
            );
        }
    }

    if ctx.skip_mode == SkipMode::SkipBuilt {
        // The --skip-built claim: a complete, payload-valid set at any
        // version IS the evidence — freshness analysis stops here. The reason
        // rides the run-record row as `skip-built`, never a bare `ok`: a
        // freshness-blind skip is a different claim from an untouched archive.
        return Verdict::Skip {
            reason: REASON_SKIP_BUILT,
            waiver_lines: Vec::new(),
            archives: archives.clone(),
        };
    }

    // --skip: per-archive VCS probes, in declaration order per archive so the
    // fish loop's first-non-current-outcome precedence survives the port.
    let mut waiver_lines: Vec<String> = Vec::new();
    let mut waived_abi = false;
    let mut waived_freshness = false;
    for probe in &ctx.archives_probe {
        if probe.baseline.is_none() {
            // No VCS sources: local gates alone decide (fish returns 0
            // before ever touching the manifest).
            continue;
        }
        if !matches!(probe.baseline, Some(BaselineState::Ok)) {
            // Missing/malformed/identity/key baselines rebuild ONCE to record
            // a baseline — but only after confirming the declared refs ARE
            // queryable; unverifiable outranks (fish `vcs_selected_refs_queryable`).
            let unverifiable = probe.sources.iter().find_map(|s| match &s.remote {
                RemoteRevisionState::Unverifiable { error } => Some(error.as_str()),
                _ => None,
            });
            if let Some(error) = unverifiable {
                return unverifiable_verdict(ctx, error);
            }
            let (key, detail) = match &probe.baseline {
                Some(BaselineState::Missing) => (
                    build_reason::VCS_BASELINE_MISSING,
                    format!(
                        "no recorded VCS baseline for {}; rebuilding once to record a baseline",
                        short_name(&probe.archive)
                    ),
                ),
                Some(BaselineState::Malformed) => (
                    build_reason::VCS_BASELINE_MALFORMED,
                    format!(
                        "VCS baseline is missing, malformed, or belongs to different sources for {}; rebuilding once to record a baseline",
                        short_name(&probe.archive)
                    ),
                ),
                Some(BaselineState::IdentityMismatch) => (
                    build_reason::VCS_BASELINE_IDENTITY,
                    format!(
                        "VCS baseline was recorded for a different build of {}; rebuilding once to record a baseline",
                        short_name(&probe.archive)
                    ),
                ),
                Some(BaselineState::KeyMismatch { source }) => (
                    build_reason::VCS_BASELINE_KEY,
                    format!("VCS baseline does not match source {source}; rebuilding once to record a baseline"),
                ),
                _ => unreachable!("non-Ok baseline handled above"),
            };
            return build(key, detail);
        }
        for src in &probe.sources {
            match &src.remote {
                RemoteRevisionState::Unverifiable { error } => {
                    return unverifiable_verdict(ctx, error);
                }
                RemoteRevisionState::PinnedMismatch => {
                    return build(
                        build_reason::VCS_REF_PINNED_MISMATCH,
                        format!("pinned Git commit does not match source {}", src.name),
                    );
                }
                RemoteRevisionState::Unchanged | RemoteRevisionState::Resolved => continue,
                RemoteRevisionState::Moved { distance } => {
                    if let Some((reason, line)) = waiver_for(
                        src,
                        ctx.tolerance,
                        ctx.abi_provider,
                        &ctx.recipe_name,
                        *distance,
                    ) {
                        waived_abi |= reason == REASON_ABI_PROVIDER_WAIVED;
                        waived_freshness |= reason == REASON_FRESHNESS_WAIVED;
                        waiver_lines.push(line);
                        continue;
                    }
                    return build(
                        build_reason::VCS_REF_MOVED,
                        format!("selected upstream ref moved for source {}", src.name),
                    );
                }
            }
        }
    }

    // A waiver row keeps its waiver reason, never `ok`. Mixed waiver reasons
    // cannot occur in practice (the ABI marker is recipe-global: a marked
    // recipe waives every moved source by policy, an unmarked one can only
    // earn the tolerance waiver); the precedence below keeps the claim
    // honest if a caller assembles one anyway.
    let reason = if waived_abi {
        REASON_ABI_PROVIDER_WAIVED
    } else if waived_freshness {
        REASON_FRESHNESS_WAIVED
    } else {
        REASON_OK
    };
    Verdict::Skip {
        reason,
        waiver_lines,
        archives: archives.clone(),
    }
}

fn short_name(path: &Path) -> String {
    path.file_name()
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| path.display().to_string())
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// A named refusal from the IO layer. Every message names the failing
/// operation or source so a run-record row can carry it verbatim.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum FreshnessError {
    /// The recipe's read path cannot establish the fact (pkgver/pkgrel or the
    /// expected output set) without evaluating shell — which this engine
    /// never does (contract §A.2.3).
    Unestablished(String),
    /// Baseline text violates manifest format 2.
    Baseline(String),
    /// The built archive cannot be fingerprinted — recording must fail closed
    /// ("never bless").
    Fingerprint(String),
    /// Baseline recording refused (stale record, missing checkout, unreadable
    /// built revision, unparseable ref, publish failure).
    Record(String),
    /// A revision query could not produce an answer.
    Probe(String),
    /// Filesystem or external-tool failure, message names the operation.
    Io(String),
}

impl std::fmt::Display for FreshnessError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            FreshnessError::Unestablished(m)
            | FreshnessError::Baseline(m)
            | FreshnessError::Fingerprint(m)
            | FreshnessError::Record(m)
            | FreshnessError::Probe(m)
            | FreshnessError::Io(m) => f.write_str(m),
        }
    }
}

impl std::error::Error for FreshnessError {}

// ---------------------------------------------------------------------------
// Source-entry parsing (the facts a manifest key and a ref probe need)
// ---------------------------------------------------------------------------

/// The URL part of a `source=()` entry: everything after the LAST `::` when
/// the entry has one (fish `source_url` — greedy `^.*::`), else the whole
/// entry. `None` when the result carries no `://` (a local file).
///
/// The greedy split is a deliberate byte-faithful port: entries with more
/// than one `::` resolve exactly as the fish reference resolves them.
pub fn source_url(entry: &str) -> Option<&str> {
    let e = match entry.rfind("::") {
        Some(idx) => &entry[idx + 2..],
        None => entry,
    };
    if e.contains("://") {
        Some(e)
    } else {
        None
    }
}

/// The VCS protocol of an entry (`git`/`svn`/`hg`/`bzr` prefix on the URL
/// part), or `None` for a plain download. Read after the `name::` prefix is
/// removed — `fish::git+https://…` is a git checkout, and testing the raw
/// entry misses it.
pub fn source_vcs(entry: &str) -> Option<VcsKind> {
    let url = source_url(entry)?;
    for (kind, prefix) in [
        (VcsKind::Git, "git+"),
        (VcsKind::Svn, "svn+"),
        (VcsKind::Hg, "hg+"),
        (VcsKind::Bzr, "bzr+"),
    ] {
        if url.starts_with(prefix) {
            return Some(kind);
        }
    }
    None
}

/// The name makepkg gives one source entry: the `name::` override (up to the
/// FIRST `::`), otherwise the URL basename after `?#`/trailing-slash
/// stripping. `None` for a detached-signature entry (makepkg writes SKIP for
/// those) or an empty name — neither is a downloadable source.
pub fn source_filename(entry: &str) -> Option<String> {
    let name = if entry.contains("::") {
        entry.split("::").next().unwrap_or("").to_string()
    } else {
        let url = source_url(entry)?;
        let url = match url.find(['?', '#']) {
            Some(idx) => &url[..idx],
            None => url,
        };
        let url = url.trim_end_matches('/');
        match url.rfind('/') {
            Some(idx) => url[idx + 1..].to_string(),
            None => url.to_string(),
        }
    };
    if name.is_empty() {
        return None;
    }
    for suffix in [".sig", ".asc", ".signature", ".sign"] {
        if name.ends_with(suffix) {
            return None;
        }
    }
    Some(name)
}

/// The manifest row key of an expanded source entry: sha256 hex of the raw
/// entry bytes, so revision records never expose credential-bearing URLs.
pub fn vcs_source_key(entry: &str) -> String {
    hex_sha256(entry.as_bytes())
}

fn hex_sha256(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut out = String::with_capacity(64);
    for b in digest {
        out.push_str(&format!("{b:02x}"));
    }
    out
}

/// The selected ref of a source entry.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RefKind {
    /// No `#fragment` selected: the VCS default (`-` internally).
    Default,
    /// A bare `#<value>` fragment.
    Revision,
    /// `#commit=<hex>` — an immutable pin (Git only).
    Commit,
    /// `#branch=<name>`.
    Branch,
    /// `#tag=<name>`.
    Tag,
    /// Any other `#kind=<value>` spelling, passed through for the probe to
    /// reject per protocol.
    Other(String),
}

/// Protocol, URL, and selected ref parsed from an expanded VCS source entry
/// (fish `vcs_source_ref_info`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VcsRef {
    pub protocol: VcsKind,
    pub url: String,
    pub kind: RefKind,
    pub value: String,
}

/// Parse the protocol/URL/ref triple out of one expanded `source=()` entry.
/// `None` when the entry is not a VCS entry or its ref fragment cannot be
/// interpreted — the ref probe turns that into `upstream-unverified`.
pub fn vcs_source_ref_info(entry: &str) -> Option<VcsRef> {
    let protocol = source_vcs(entry)?;
    let raw = source_url(entry)?;
    let raw = raw
        .strip_prefix("git+")
        .or_else(|| raw.strip_prefix("svn+"))
        .or_else(|| raw.strip_prefix("hg+"))
        .or_else(|| raw.strip_prefix("bzr+"))
        .unwrap_or(raw);
    let (url, fragment) = match raw.split_once('#') {
        Some((u, f)) => (u, Some(f)),
        None => (raw, None),
    };
    // `?signed` is a download-time flag, never part of the URL or the ref.
    let url = url.strip_suffix("?signed").unwrap_or(url);
    let fragment = fragment.map(|f| f.strip_suffix("?signed").unwrap_or(f));

    let (kind, value) = match fragment {
        None | Some("") => (RefKind::Default, "-".to_string()),
        Some(f) => match f.split_once('=') {
            Some((k, v)) => {
                let kind = match k {
                    "commit" => RefKind::Commit,
                    "branch" => RefKind::Branch,
                    "tag" => RefKind::Tag,
                    "revision" => RefKind::Revision,
                    other => RefKind::Other(other.to_string()),
                };
                (kind, v.to_string())
            }
            None => (RefKind::Revision, f.to_string()),
        },
    };
    Some(VcsRef {
        protocol,
        url: url.to_string(),
        kind,
        value,
    })
}

// ---------------------------------------------------------------------------
// Archive fingerprinting (sha256 + size identity)
// ---------------------------------------------------------------------------

/// The identity a revision baseline binds to: sha256 rejects a same-size
/// replacement, size rejects a truncated write.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArchiveFingerprint {
    pub sha256: String,
    pub size: u64,
}

/// Fingerprint the exact bytes of a built archive. Fail-closed: a fingerprint
/// that cannot be taken is never replaced with a guess (fish
/// `record_vcs_archive_revisions`'s "cannot fingerprint the built archive").
pub fn fingerprint_archive(archive: &Path) -> Result<ArchiveFingerprint, FreshnessError> {
    let size = fs::metadata(archive)
        .map_err(|e| {
            FreshnessError::Fingerprint(format!("cannot fingerprint the built archive: {e}"))
        })?
        .len();
    let file = fs::File::open(archive).map_err(|e| {
        FreshnessError::Fingerprint(format!("cannot fingerprint the built archive: {e}"))
    })?;
    let mut hasher = Sha256::new();
    let mut reader = std::io::BufReader::new(file);
    let mut buf = [0u8; 64 * 1024];
    loop {
        let n = reader.read(&mut buf).map_err(|e| {
            FreshnessError::Fingerprint(format!("cannot fingerprint the built archive: {e}"))
        })?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
    }
    Ok(ArchiveFingerprint {
        sha256: hex_sha256_of(hasher),
        size,
    })
}

fn hex_sha256_of(hasher: Sha256) -> String {
    let digest = hasher.finalize();
    let mut out = String::with_capacity(64);
    for b in digest {
        out.push_str(&format!("{b:02x}"));
    }
    out
}

// ---------------------------------------------------------------------------
// Manifest format 2 — the VCS revision baseline
// ---------------------------------------------------------------------------

/// The exact first line of manifest format 2 (`lib/sources.fish`
/// `record_vcs_archive_revisions`): `gsa-vcs-revisions` TAB `2`.
pub const MANIFEST_MAGIC: &str = "gsa-vcs-revisions\t2";

/// Suffix appended to an archive path for its baseline sidecar.
pub const MANIFEST_SUFFIX: &str = ".gsa-vcs-revisions";

/// The sidecar path of one archive's baseline.
pub fn manifest_path(archive: &Path) -> PathBuf {
    let mut os = archive.as_os_str().to_owned();
    os.push(MANIFEST_SUFFIX);
    PathBuf::from(os)
}

/// One `key<TAB>protocol<TAB>revision` row: the recorded revision of one
/// distinct VCS source at the time the archive was built.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VcsBaselineRow {
    /// 64-hex `vcs_source_key` of the expanded source entry.
    pub key: String,
    pub protocol: VcsKind,
    pub revision: String,
}

/// A parsed manifest-format-2 baseline, bound to one exact archive build.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct VcsBaseline {
    /// sha256 hex of the bound archive bytes.
    pub archive_sha256: String,
    /// Size of the bound archive bytes (rejects truncation).
    pub archive_size: u64,
    /// One row per distinct VCS source, in declaration order.
    pub rows: Vec<VcsBaselineRow>,
}

fn is_lower_hex64(s: &str) -> bool {
    s.len() == 64
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

impl VcsBaseline {
    /// Parse manifest format 2 strictly: magic line, `archive` identity row
    /// (64-lowerhex sha + decimal size), then well-formed rows only. Any
    /// structural violation is an error naming the shape — a malformed
    /// baseline must read as `BaselineState::Malformed`, never half-trusted.
    pub fn parse(text: &str) -> Result<VcsBaseline, FreshnessError> {
        let mut lines = text.lines();
        let header = lines.next().unwrap_or("");
        if header != MANIFEST_MAGIC {
            return Err(FreshnessError::Baseline(
                "malformed VCS baseline: header is not 'gsa-vcs-revisions\\t2'".to_string(),
            ));
        }
        let identity = lines.next().unwrap_or("");
        let fields: Vec<&str> = identity.split('\t').collect();
        if fields.len() != 3
            || fields[0] != "archive"
            || !is_lower_hex64(fields[1])
            || fields[2].is_empty()
            || !fields[2].bytes().all(|b| b.is_ascii_digit())
        {
            return Err(FreshnessError::Baseline(
                "malformed VCS baseline: identity row must be 'archive\\t<sha256>\\t<size>'"
                    .to_string(),
            ));
        }
        let archive_sha256 = fields[1].to_string();
        let archive_size: u64 = fields[2].parse().map_err(|_| {
            FreshnessError::Baseline("malformed VCS baseline: archive size overflows".to_string())
        })?;
        let mut rows = Vec::new();
        for line in lines {
            let bad = || {
                FreshnessError::Baseline(format!(
                    "malformed VCS baseline row (expected 'key\\tprotocol\\trevision'): {line}"
                ))
            };
            let fields: Vec<&str> = line.split('\t').collect();
            if fields.len() != 3 || !is_lower_hex64(fields[0]) {
                return Err(bad());
            }
            let protocol = match fields[1] {
                "git" => VcsKind::Git,
                "svn" => VcsKind::Svn,
                "hg" => VcsKind::Hg,
                "bzr" => VcsKind::Bzr,
                _ => return Err(bad()),
            };
            if fields[2].is_empty() {
                return Err(bad());
            }
            rows.push(VcsBaselineRow {
                key: fields[0].to_string(),
                protocol,
                revision: fields[2].to_string(),
            });
        }
        Ok(VcsBaseline {
            archive_sha256,
            archive_size,
            rows,
        })
    }

    /// Render manifest format 2 exactly (trailing newline after the last
    /// row): magic, identity row, one row per distinct source.
    pub fn render(&self) -> String {
        let mut out = String::new();
        out.push_str(MANIFEST_MAGIC);
        out.push('\n');
        out.push_str(&format!(
            "archive\t{}\t{}\n",
            self.archive_sha256, self.archive_size
        ));
        for row in &self.rows {
            out.push_str(&format!(
                "{}\t{}\t{}\n",
                row.key,
                row.protocol.as_str(),
                row.revision
            ));
        }
        out
    }
}

// ---------------------------------------------------------------------------
// Baseline recording (fail-closed, atomic publish)
// ---------------------------------------------------------------------------

/// Locate the checkout makepkg actually compiled from: `$srcdir`
/// (`<recipe>/src/<name>`) first — a mirror's HEAD is the remote's default
/// branch, not the built ref — then the package root. Git strips `.git` from
/// its default source name, so both spellings are tried. (The fish recorder
/// also probes `$SRCDEST`; the engine's env roster is exactly
/// `GSA_VCS_SKIP_TOLERANCE` + `TMPDIR`, so that root is not ported.)
pub fn vcs_source_checkout(recipe_dir: &Path, entry: &str) -> Option<PathBuf> {
    let name = source_filename(entry)?;
    let mut names = vec![name.clone()];
    if let Some(stripped) = name.strip_suffix(".git") {
        names.push(stripped.to_string());
    }
    for root in [recipe_dir.join("src"), recipe_dir.to_path_buf()] {
        for candidate_name in &names {
            let candidate = root.join(candidate_name);
            if candidate.is_dir() {
                return Some(candidate);
            }
        }
    }
    None
}

/// The revision one local checkout was built at (fish `vcs_local_revision`),
/// resolved through `PATH` like every external tool here.
pub fn vcs_local_revision(protocol: VcsKind, checkout: &Path) -> Result<String, FreshnessError> {
    let checkout_arg = checkout.display().to_string();
    let output = match protocol {
        VcsKind::Git => git_output(&[
            "-c",
            "safe.bareRepository=all",
            "-C",
            &checkout_arg,
            "rev-parse",
            "--verify",
            "HEAD",
        ]),
        VcsKind::Svn => tool_output("svn", &["info", "--show-item", "revision", &checkout_arg]),
        VcsKind::Hg => tool_output(
            "hg",
            &[
                "--config",
                "ui.interactive=False",
                "log",
                "-r",
                ".",
                "--template",
                "{node}",
                &checkout_arg,
            ],
        ),
        VcsKind::Bzr => tool_output(
            "bzr",
            &[
                "version-info",
                "--custom",
                "--template={revision_id}",
                &checkout_arg,
            ],
        ),
    };
    let revision = output?.lines().next().unwrap_or("").trim().to_string();
    if revision.is_empty() {
        return Err(FreshnessError::Probe(
            "cannot read the built revision (empty answer)".to_string(),
        ));
    }
    Ok(revision)
}

/// Record one revision row per distinct VCS source for a freshly built
/// archive — fish `record_vcs_archive_revisions`, manifest format 2.
///
/// The manifest is bound to THIS archive build: the size rejects any
/// truncated write, the checksum is the identity for same-size replacements,
/// and a fingerprint that cannot be taken REFUSES the bless — a build whose
/// record cannot be bound is never skippable. The publish is atomic (tmp name
/// beside the manifest + rename); any failure removes the temporary and
/// leaves no record. `Ok(None)` means the recipe has no VCS sources: any
/// stale manifest is removed and nothing is written.
pub fn record_vcs_archive_revisions(
    recipe_dir: &Path,
    archive: &Path,
    entries: &[String],
) -> Result<Option<VcsBaseline>, FreshnessError> {
    // Distinct VCS entries, first occurrence wins (the manifest holds one row
    // per distinct source).
    let mut seen: Vec<String> = Vec::new();
    let mut vcs_entries: Vec<&String> = Vec::new();
    for entry in entries {
        if source_vcs(entry).is_none() {
            continue;
        }
        let key = vcs_source_key(entry);
        if seen.contains(&key) {
            continue;
        }
        seen.push(key);
        vcs_entries.push(entry);
    }

    let manifest = manifest_path(archive);
    if vcs_entries.is_empty() {
        match fs::remove_file(&manifest) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => {
                return Err(FreshnessError::Record(format!(
                    "cannot remove stale VCS revision metadata: {e}"
                )))
            }
        }
        return Ok(None);
    }

    // Bind the record to the exact archive bytes before anything is written.
    let fingerprint = fingerprint_archive(archive)
        .map_err(|_| FreshnessError::Record("cannot fingerprint the built archive".to_string()))?;

    // The archive changed; invalidate any old record BEFORE collecting new
    // revisions so a failed capture cannot make the replacement look current.
    match fs::remove_file(&manifest) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => {
            return Err(FreshnessError::Record(format!(
                "cannot replace VCS revision metadata: {e}"
            )))
        }
    }

    // Resolve every row first (fish resolves while writing; resolving first
    // keeps the tmp+mv publish a single atomic step and never leaves a tmp).
    let mut rows = Vec::new();
    for entry in &vcs_entries {
        let info = vcs_source_ref_info(entry)
            .ok_or_else(|| FreshnessError::Record("cannot parse a VCS source ref".to_string()))?;
        let checkout = vcs_source_checkout(recipe_dir, entry).ok_or_else(|| {
            let name = source_filename(entry).unwrap_or_default();
            FreshnessError::Record(format!("missing local checkout for {name}"))
        })?;
        let revision = vcs_local_revision(info.protocol, &checkout).map_err(|_| {
            let name = source_filename(entry).unwrap_or_default();
            FreshnessError::Record(format!("cannot read the built revision for {name}"))
        })?;
        rows.push(VcsBaselineRow {
            key: vcs_source_key(entry),
            protocol: info.protocol,
            revision,
        });
    }

    let baseline = VcsBaseline {
        archive_sha256: fingerprint.sha256,
        archive_size: fingerprint.size,
        rows,
    };
    let temporary = unique_tmp_beside(&manifest)
        .map_err(|e| FreshnessError::Record(format!("cannot create VCS revision metadata: {e}")))?;
    if let Err(e) = fs::write(&temporary, baseline.render()) {
        let _ = fs::remove_file(&temporary);
        return Err(FreshnessError::Record(format!(
            "cannot write VCS revision metadata: {e}"
        )));
    }
    if let Err(e) = fs::rename(&temporary, &manifest) {
        let _ = fs::remove_file(&temporary);
        return Err(FreshnessError::Record(format!(
            "cannot publish VCS revision metadata: {e}"
        )));
    }
    Ok(Some(baseline))
}

fn unique_tmp_beside(manifest: &Path) -> std::io::Result<PathBuf> {
    static COUNTER: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    for _ in 0..128 {
        let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let mut os = manifest.as_os_str().to_owned();
        os.push(format!(".tmp.{}.{}", std::process::id(), n));
        let path = PathBuf::from(os);
        match fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
        {
            Ok(_) => return Ok(path),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e),
        }
    }
    Err(std::io::Error::new(
        std::io::ErrorKind::AlreadyExists,
        "no free temporary name beside the manifest",
    ))
}

// ---------------------------------------------------------------------------
// Archive discovery (expected outputs, current-version set, newest set)
// ---------------------------------------------------------------------------

fn scan_recipe(recipe_dir: &Path) -> Result<crate::PkgbuildScan, FreshnessError> {
    let path = recipe_dir.join("PKGBUILD");
    let content = fs::read_to_string(&path).map_err(|e| {
        FreshnessError::Unestablished(format!("cannot read {}: {e}", path.display()))
    })?;
    Ok(scan_pkgbuild(&content))
}

fn scan_literal(scan: &crate::PkgbuildScan, key: &str) -> Result<Option<String>, FreshnessError> {
    // A dynamic value is shell-built: the engine never evaluates recipe
    // shell, so the fact is unestablished — fail closed, never guess.
    if scan.dynamic.contains(key) {
        return Err(FreshnessError::Unestablished(format!(
            "{key} is shell-derived (dynamic) and cannot be read without evaluating the recipe"
        )));
    }
    Ok(match scan.vars.get(key) {
        Some(ScanValue::Scalar(v)) => Some(v.clone()),
        _ => None,
    })
}

fn dedup_keep_order(names: Vec<String>) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for name in names {
        if !out.contains(&name) {
            out.push(name);
        }
    }
    out
}

/// The outputs a complete build must produce (fish `expected_output_names`):
/// the committed `.SRCINFO` is the recipe's published claim (deduped, order
/// preserved); without one the strict scan answers from the `pkgname` array.
/// An expected set that cannot be established is an error — never a blessing.
pub fn expected_output_names(recipe_dir: &Path) -> Result<Vec<String>, FreshnessError> {
    let srcinfo_path = recipe_dir.join(".SRCINFO");
    if srcinfo_path.is_file() {
        let content = fs::read_to_string(&srcinfo_path).map_err(|e| {
            FreshnessError::Unestablished(format!("cannot read committed .SRCINFO: {e}"))
        })?;
        let info = parse_srcinfo(&content, &srcinfo_path.display().to_string()).map_err(|e| {
            FreshnessError::Unestablished(format!("cannot parse committed .SRCINFO: {e}"))
        })?;
        let names = dedup_keep_order(info.pkgnames);
        if !names.is_empty() {
            return Ok(names);
        }
        // An .SRCINFO that names nothing falls through to the scan claim,
        // exactly like fish's sed-empty fallback.
    }
    let scan = scan_recipe(recipe_dir)?;
    let names = match scan_literal(&scan, "pkgname")? {
        Some(v) => vec![v],
        None => match scan.vars.get("pkgname") {
            Some(ScanValue::Array(items)) => dedup_keep_order(items.clone()),
            _ => Vec::new(),
        },
    };
    if names.is_empty() {
        return Err(FreshnessError::Unestablished(
            "could not establish the expected output set for archive discovery".to_string(),
        ));
    }
    Ok(names)
}

/// The `(PV, PR)` discovery key of the recipe: PV carries the `epoch:` prefix
/// exactly like fish's `pkgbuild_version` output. From the committed
/// `.SRCINFO` (the evaluated claim) with a strict-scan fallback for the facts
/// `.SRCINFO` does not carry (the crate's established read order); a computed
/// or absent value is unestablished — never broaden discovery to every
/// archive when the version-specific pattern is unknown.
pub fn current_version_key(recipe_dir: &Path) -> Result<(String, String), FreshnessError> {
    let mut pkgver: Option<String> = None;
    let mut pkgrel: Option<String> = None;
    let mut epoch: Option<String> = None;
    let srcinfo_path = recipe_dir.join(".SRCINFO");
    if srcinfo_path.is_file() {
        let content = fs::read_to_string(&srcinfo_path).map_err(|e| {
            FreshnessError::Unestablished(format!("cannot read committed .SRCINFO: {e}"))
        })?;
        let info = parse_srcinfo(&content, &srcinfo_path.display().to_string()).map_err(|e| {
            FreshnessError::Unestablished(format!("cannot parse committed .SRCINFO: {e}"))
        })?;
        pkgver = info.pkgver;
        pkgrel = info.pkgrel;
        epoch = info.epoch;
    }
    if pkgver.is_none() || pkgrel.is_none() {
        let scan = scan_recipe(recipe_dir)?;
        if pkgver.is_none() {
            pkgver = scan_literal(&scan, "pkgver")?;
        }
        if pkgrel.is_none() {
            pkgrel = scan_literal(&scan, "pkgrel")?;
        }
        if epoch.is_none() {
            epoch = scan_literal(&scan, "epoch")?;
        }
    }
    let (Some(pkgver), Some(pkgrel)) = (pkgver, pkgrel) else {
        return Err(FreshnessError::Unestablished(
            "could not evaluate pkgver/pkgrel for archive discovery".to_string(),
        ));
    };
    let pv = match epoch {
        Some(e) if !e.is_empty() => format!("{e}:{pkgver}"),
        _ => pkgver,
    };
    if pv.is_empty() || pkgrel.is_empty() {
        return Err(FreshnessError::Unestablished(
            "could not evaluate pkgver/pkgrel for archive discovery".to_string(),
        ));
    }
    Ok((pv, pkgrel))
}

/// One built archive row for discovery: nanosecond mtime + path.
struct ArchiveRow {
    mtime: (u64, u32),
    path: PathBuf,
}

fn list_archives(recipe_dir: &Path) -> Vec<ArchiveRow> {
    let mut rows: Vec<ArchiveRow> = Vec::new();
    let Ok(dir) = fs::read_dir(recipe_dir) else {
        return rows;
    };
    for entry in dir.flatten() {
        let path = entry.path();
        if !path.is_file() {
            continue;
        }
        let name = entry.file_name();
        if !name.to_string_lossy().ends_with(".pkg.tar.zst") {
            continue;
        }
        let mtime = entry
            .metadata()
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .map(|d| (d.as_secs(), d.subsec_nanos()))
            .unwrap_or((0, 0));
        rows.push(ArchiveRow { mtime, path });
    }
    // Newest first (fish `find -printf %T@ | sort -rn`; equal mtimes fall
    // back to a reverse path compare, the full-line tiebreak of `sort -rn`).
    rows.sort_by(|a, b| b.mtime.cmp(&a.mtime).then_with(|| b.path.cmp(&a.path)));
    rows
}

/// Is the archive file name `NAME-PV-PR-<arch>.pkg.tar.zst`? Literal string
/// surgery only — pkgver is recipe data and may carry glob/regex
/// metacharacters, so the prefix is never a pattern; the arch token is
/// free-form and must carry no dash.
pub fn archive_matches_output(archive: &Path, name: &str, pv: &str, pr: &str) -> bool {
    let base = short_name(archive);
    let stem = format!("{name}-{pv}-{pr}-");
    let Some(rest) = base.strip_prefix(stem.as_str()) else {
        return false;
    };
    // rest must be `<arch>.pkg.tar.zst` with a dash-free arch token.
    let Some(arch) = rest.strip_suffix(".pkg.tar.zst") else {
        return false;
    };
    !arch.is_empty() && !arch.contains('-')
}

/// `current_archives` (fish): every archive mapping to an expected output at
/// the evaluated pkgver-pkgrel, plus the state of the SET. One archive maps
/// to exactly one output name; a same-version ARCH-flavour leftover rides
/// along with the build's own archive instead of displacing it.
pub fn discover_current_set(recipe_dir: &Path) -> Discovery {
    let (pv, pr) = match current_version_key(recipe_dir) {
        Ok(v) => v,
        Err(_) => return Discovery::default(),
    };
    let names = match expected_output_names(recipe_dir) {
        Ok(n) => n,
        Err(_) => return Discovery::default(),
    };
    let rows = list_archives(recipe_dir);
    let mut chosen: Vec<PathBuf> = Vec::new();
    let mut missing: Vec<String> = Vec::new();
    for name in &names {
        let mut covered = false;
        for row in &rows {
            if archive_matches_output(&row.path, name, &pv, &pr) {
                chosen.push(row.path.clone());
                covered = true;
            }
        }
        if !covered {
            missing.push(name.clone());
        }
    }
    chosen.sort();
    Discovery {
        archives: chosen,
        missing,
        established: true,
        version_key: Some(format!("{pv}-{pr}")),
    }
}

/// `newest_complete_archives` (fish): the archives of the NEWEST complete
/// built set at ANY version — the `--skip-built` claim set. Currency is a
/// BUILD claim, never the committed pkgver (a fast-moving VCS recipe's
/// committed pkgver trails its archives; keying to it rebuilt llvm-git on
/// every run, 2026-10-07 run #40). Each archive is assigned to the LONGEST
/// expected name it is prefixed by (`p1-extra-1.0-1-any` must never count as
/// output `p1`), then grouped by its PV-PR key (only the trailing ARCH token
/// is dropped, so a pkgver carrying dashes groups with its siblings). A
/// NEWER but partial key still reports `Partial` — an older complete set must
/// never cover for a split set cut apart by a mid-packaging SIGKILL.
pub fn discover_newest_complete_set(recipe_dir: &Path) -> Discovery {
    let names = match expected_output_names(recipe_dir) {
        Ok(n) => n,
        Err(_) => return Discovery::default(),
    };
    let rows = list_archives(recipe_dir);
    let mut entries: Vec<(String, String, PathBuf)> = Vec::new(); // (key, owner, path)
    let mut newest_key = String::new();
    for row in &rows {
        let base = short_name(&row.path);
        let mut owner = String::new();
        for name in &names {
            let prefix = format!("{name}-");
            if base.len() > prefix.len() && base.starts_with(&prefix) {
                if name.len() > owner.len() {
                    owner = name.clone();
                }
            }
        }
        if owner.is_empty() {
            continue;
        }
        let tail = base[owner.len() + 1..]
            .strip_suffix(".pkg.tar.zst")
            .unwrap_or(&base[owner.len() + 1..])
            .to_string();
        // Drop the trailing ARCH token; without one the name is not
        // NAME-PV-PR-ARCH shaped and the row cannot group.
        let key = match tail.rfind('-') {
            Some(idx) => tail[..idx].to_string(),
            None => tail.clone(),
        };
        if key == tail || key.is_empty() {
            continue;
        }
        if newest_key.is_empty() {
            newest_key = key.clone();
        }
        entries.push((key, owner, row.path.clone()));
    }
    if newest_key.is_empty() {
        return Discovery {
            established: true,
            version_key: None,
            ..Discovery::default()
        };
    }
    let mut missing = Vec::new();
    for name in &names {
        if !entries
            .iter()
            .any(|(k, o, _)| k == &newest_key && o == name)
        {
            missing.push(name.clone());
        }
    }
    let mut chosen: Vec<PathBuf> = entries
        .iter()
        .filter(|(k, _, _)| k == &newest_key)
        .map(|(_, _, p)| p.clone())
        .collect();
    chosen.sort();
    Discovery {
        archives: chosen,
        missing,
        established: true,
        version_key: Some(newest_key),
    }
}

// ---------------------------------------------------------------------------
// Local gates
// ---------------------------------------------------------------------------

/// The payload gate (fish `archive_payload_ok`): `pacman -Qp` decompresses
/// the whole zstd stream before answering, so a write killed at ANY offset
/// fails it — exactly the mid-packaging SIGKILL shape that used to re-skip
/// forever. Read-only and lock-free; doubt fails CLOSED (an unreadable
/// archive is never evidence of a build).
pub fn archive_payload_ok(archive: &Path) -> bool {
    Command::new("pacman")
        .arg("-Qp")
        .arg("--")
        .arg(archive)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// The `--skip-built` recipe-change gate (fish `recipe_changed_since_build`):
/// true when there is positive evidence the recipe changed after ARCHIVE was
/// written. In a git tree the evidence is the PKGBUILD's last COMMIT time
/// (checkout, pull and makepkg's in-tree pkgver() rewrite churn the mtime
/// without moving the commit). git stamps whole seconds, so a commit MAY
/// postdate the archive once its second reaches ceil(archive mtime) — that
/// doubt rebuilds, never skips. Without git metadata the file's mtime is the
/// only evidence left (conservative direction: doubt rebuilds).
pub fn recipe_changed_since_build(recipe_dir: &Path, archive: &Path) -> bool {
    let log = git_output(&[
        "-C",
        &recipe_dir.display().to_string(),
        "log",
        "-1",
        "--format=%ct",
        "--",
        "PKGBUILD",
    ]);
    let commit = log
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty() && s.bytes().all(|b| b.is_ascii_digit()));
    if let Some(commit) = commit {
        let modified = match fs::metadata(archive).and_then(|m| m.modified()) {
            Ok(t) => t,
            // The archive vanished under us — doubt rebuilds.
            Err(_) => return true,
        };
        let Ok(since) = modified.duration_since(UNIX_EPOCH) else {
            return true;
        };
        // Second-ceil: any fractional part pushes the boundary one second up.
        let ceil = if since.subsec_nanos() > 0 {
            since.as_secs() + 1
        } else {
            since.as_secs()
        };
        let Ok(commit) = commit.parse::<u64>() else {
            return true;
        };
        return commit >= ceil;
    }
    // No git metadata: `test PKGBUILD -nt archive` (strictly newer; a
    // PKGBUILD that exists while the archive does not is "newer" too).
    match (mtime_of(&recipe_dir.join("PKGBUILD")), mtime_of(archive)) {
        (Some(pkgbuild), Some(arch)) => pkgbuild > arch,
        (Some(_), None) => true,
        (None, _) => false,
    }
}

fn mtime_of(path: &Path) -> Option<(u64, u32)> {
    let t = fs::metadata(path).ok()?.modified().ok()?;
    let d = t.duration_since(UNIX_EPOCH).ok()?;
    Some((d.as_secs(), d.subsec_nanos()))
}

// ---------------------------------------------------------------------------
// Transport: git ls-remote classification and ref resolution
// ---------------------------------------------------------------------------

/// A raw `git` invocation with the injected git config neutralised
/// (`GIT_CONFIG_COUNT=0`) and no credential prompt — agent shells inject
/// `safe.bareRepository=explicit`, which breaks bare-repo and makepkg VCS
/// operations.
fn git_base() -> Command {
    let mut cmd = Command::new("git");
    cmd.env("GIT_CONFIG_COUNT", "0");
    cmd.env("GIT_TERMINAL_PROMPT", "0");
    cmd
}

fn git_output(args: &[&str]) -> Result<String, FreshnessError> {
    let output = git_base()
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .map_err(|e| FreshnessError::Io(format!("git: {e}")))?;
    if !output.status.success() {
        return Err(FreshnessError::Probe(format!(
            "git {} exited {}",
            args.first().unwrap_or(&""),
            output.status
        )));
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

fn tool_output(tool: &str, args: &[&str]) -> Result<String, FreshnessError> {
    let output = Command::new(tool)
        .args(args)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .output()
        .map_err(|e| FreshnessError::Io(format!("{tool}: {e}")))?;
    if !output.status.success() {
        return Err(FreshnessError::Probe(format!(
            "{tool} exited {}",
            output.status
        )));
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

/// The `git ls-remote` transport verdict. Exit 0 = completed answer, exit 2
/// = clean "no such ref" (PERMANENT — an answer does not change on
/// repetition, so it is never retried), anything else = transport failure:
/// the ONLY retryable class (TLS, timeout, dead host — no answer at all).
/// Measured 2026-10-02: repo.or.cz answered 1 of 3 attempts within a minute,
/// and 2026-10-07 run #47/#48 showed failures arrive in BURSTS that outlast
/// short budgets — hence 6 attempts, 2/5/10/20/40 s backoff (~93 s), the
/// code's dated schedule (the older "3 times (0.5/1 s)" doc line is stale).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LsRemoteOutcome {
    /// Exit 0: stdout rows (`<sha>\t<ref>` / `<symref>\tHEAD`), possibly empty.
    Answered(Vec<String>),
    /// Exit 2: the queried ref does not exist — a completed answer.
    NoSuchRef,
    /// Every attempt failed to answer. The caller reports "unverifiable",
    /// never "moved".
    TransportExhausted { status: i32 },
}

/// The bounded backoff schedule for `git ls-remote` transport retries.
pub const LS_REMOTE_BACKOFF: [Duration; 5] = [
    Duration::from_secs(2),
    Duration::from_secs(5),
    Duration::from_secs(10),
    Duration::from_secs(20),
    Duration::from_secs(40),
];

/// One `git ls-remote` query with the transport classifier and bounded
/// retry. `args` are the `ls-remote` arguments verbatim (option order — e.g.
/// `--symref` before the URL — is the caller's). Sleeps go through the
/// injected `sleeper` so no test ever waits.
pub fn git_ls_remote(args: &[String], sleeper: &mut dyn FnMut(Duration)) -> LsRemoteOutcome {
    let mut attempt = 0u32;
    loop {
        attempt += 1;
        let mut cmd = git_base();
        cmd.arg("-c")
            .arg("safe.bareRepository=all")
            .arg("ls-remote")
            .args(args)
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        let status = match cmd.output() {
            Ok(output) => {
                let code = output.status.code().unwrap_or(1);
                if code == 0 {
                    let rows: Vec<String> = String::from_utf8_lossy(&output.stdout)
                        .lines()
                        .map(|l| l.to_string())
                        .collect();
                    return LsRemoteOutcome::Answered(rows);
                }
                if code == 2 {
                    return LsRemoteOutcome::NoSuchRef;
                }
                code
            }
            // A missing git binary is indistinguishable from a dead transport
            // to this caller — retry, then report unverifiable.
            Err(_) => 127,
        };
        if attempt >= 6 {
            return LsRemoteOutcome::TransportExhausted { status };
        }
        sleeper(LS_REMOTE_BACKOFF[(attempt - 1) as usize]);
    }
}

fn hash_is_full(hex: &str) -> bool {
    (40..=64).contains(&hex.len())
        && hex
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

fn split_ls_row(row: &str) -> Option<(&str, &str)> {
    let mut fields = row.split('\t');
    let a = fields.next()?;
    let b = fields.next()?;
    if fields.next().is_some() {
        return None;
    }
    Some((a, b))
}

/// Resolve the DECLARED ref of a source — never an unrelated repository HEAD
/// (fish `vcs_remote_revision`). Fixed Git commits and numeric SVN revisions
/// are immutable inputs and resolve without any query.
pub fn vcs_remote_revision(
    vref: &VcsRef,
    sleeper: &mut dyn FnMut(Duration),
) -> Result<String, FreshnessError> {
    match vref.protocol {
        VcsKind::Git => match vref.kind {
            RefKind::Commit => {
                let value = vref.value.to_lowercase();
                let ok =
                    (7..=64).contains(&value.len()) && value.bytes().all(|b| b.is_ascii_hexdigit());
                if !ok {
                    return Err(FreshnessError::Probe(
                        "pinned Git commit is not hex(7..64)".to_string(),
                    ));
                }
                // Immutable: no query at all.
                Ok(value)
            }
            RefKind::Branch => {
                let target = if vref.value.starts_with("refs/heads/") {
                    vref.value.clone()
                } else {
                    format!("refs/heads/{}", vref.value)
                };
                let rows = git_ls_remote(
                    &["--exit-code".to_string(), vref.url.clone(), target.clone()],
                    sleeper,
                );
                if let LsRemoteOutcome::Answered(rows) = rows {
                    for row in rows {
                        if let Some((hash, name)) = split_ls_row(&row) {
                            if name == target && hash_is_full(hash) {
                                return Ok(hash.to_lowercase());
                            }
                        }
                    }
                }
                Err(FreshnessError::Probe(format!(
                    "cannot resolve branch ref {target}"
                )))
            }
            RefKind::Tag => {
                let target = if vref.value.starts_with("refs/tags/") {
                    vref.value.clone()
                } else {
                    format!("refs/tags/{}", vref.value)
                };
                let peeled = format!("{target}^{{}}");
                let rows = git_ls_remote(
                    &[
                        "--exit-code".to_string(),
                        vref.url.clone(),
                        target.clone(),
                        peeled.clone(),
                    ],
                    sleeper,
                );
                let (mut tag_revision, mut peeled_revision) = (String::new(), String::new());
                if let LsRemoteOutcome::Answered(rows) = rows {
                    for row in rows {
                        if let Some((hash, name)) = split_ls_row(&row) {
                            if name == target {
                                tag_revision = hash.to_string();
                            } else if name == peeled {
                                peeled_revision = hash.to_string();
                            }
                        }
                    }
                }
                // Prefer the peeled commit — the tag object itself is not
                // what was compiled.
                let revision = if peeled_revision.is_empty() {
                    tag_revision
                } else {
                    peeled_revision
                };
                if hash_is_full(&revision) {
                    return Ok(revision.to_lowercase());
                }
                Err(FreshnessError::Probe(format!(
                    "cannot resolve tag ref {target}"
                )))
            }
            RefKind::Default => {
                let rows = git_ls_remote(
                    &[
                        "--symref".to_string(),
                        "--exit-code".to_string(),
                        vref.url.clone(),
                        "HEAD".to_string(),
                    ],
                    sleeper,
                );
                if let LsRemoteOutcome::Answered(rows) = rows {
                    for row in rows {
                        // The symref row (`ref: refs/heads/main`) fails the
                        // hash shape; the hash row wins.
                        if let Some((hash, name)) = split_ls_row(&row) {
                            if name == "HEAD" && hash_is_full(hash) {
                                return Ok(hash.to_lowercase());
                            }
                        }
                    }
                }
                Err(FreshnessError::Probe(
                    "cannot resolve default-branch HEAD".to_string(),
                ))
            }
            _ => Err(FreshnessError::Probe(
                "unsupported Git ref kind for this source".to_string(),
            )),
        },
        VcsKind::Svn => {
            if !matches!(vref.kind, RefKind::Default | RefKind::Revision) {
                return Err(FreshnessError::Probe(
                    "unsupported SVN ref kind for this source".to_string(),
                ));
            }
            let value = if vref.kind == RefKind::Default {
                "HEAD".to_string()
            } else {
                vref.value.clone()
            };
            // Numeric SVN revisions are immutable inputs: no query.
            if value != "HEAD" && !value.is_empty() && value.bytes().all(|b| b.is_ascii_digit()) {
                return Ok(value);
            }
            let revision = tool_output(
                "svn",
                &[
                    "--non-interactive",
                    "info",
                    "--show-item",
                    "revision",
                    "--revision",
                    &value,
                    &vref.url,
                ],
            )?;
            let revision = revision.trim().to_string();
            if !revision.is_empty() && revision.bytes().all(|b| b.is_ascii_digit()) {
                return Ok(revision);
            }
            Err(FreshnessError::Probe(
                "svn revision is not numeric".to_string(),
            ))
        }
        VcsKind::Hg => {
            if !matches!(
                vref.kind,
                RefKind::Default | RefKind::Branch | RefKind::Revision | RefKind::Tag
            ) {
                return Err(FreshnessError::Probe(
                    "unsupported hg ref kind for this source".to_string(),
                ));
            }
            let value = if vref.kind == RefKind::Default {
                "default".to_string()
            } else {
                vref.value.clone()
            };
            let revision = tool_output(
                "hg",
                &[
                    "--config",
                    "ui.interactive=False",
                    "identify",
                    "--template",
                    "{node}",
                    "--rev",
                    &value,
                    &vref.url,
                ],
            )?;
            let revision = revision.trim().to_string();
            if hash_is_full(&revision) {
                return Ok(revision.to_lowercase());
            }
            Err(FreshnessError::Probe("hg node is not a hash".to_string()))
        }
        VcsKind::Bzr => {
            if !matches!(vref.kind, RefKind::Default | RefKind::Revision) {
                return Err(FreshnessError::Probe(
                    "unsupported bzr ref kind for this source".to_string(),
                ));
            }
            let mut args = vec!["version-info", "--custom", "--template={revision_id}"];
            let revision_arg;
            if vref.kind == RefKind::Revision {
                revision_arg = format!("--revision={}", vref.value);
                args.push(&revision_arg);
            }
            args.push(&vref.url);
            let revision = tool_output("bzr", &args)?;
            let revision = revision.trim().to_string();
            if revision.is_empty() {
                return Err(FreshnessError::Probe(
                    "bzr revision id is empty".to_string(),
                ));
            }
            Ok(revision)
        }
    }
}

/// The fetch refspec for a selected Git ref — one home for the ref-kind →
/// refspec mapping shared by the advance probes (`vcs_remote_revision` keeps
/// its own `ls-remote` argument shapes).
pub fn vcs_git_fetch_refspec(kind: &RefKind, value: &str) -> Option<String> {
    match kind {
        RefKind::Default => Some("HEAD".to_string()),
        RefKind::Branch => Some(if value.starts_with("refs/heads/") {
            value.to_string()
        } else {
            format!("refs/heads/{value}")
        }),
        RefKind::Tag => Some(if value.starts_with("refs/tags/") {
            value.to_string()
        } else {
            format!("refs/tags/{value}")
        }),
        _ => None,
    }
}

/// The commit distance from BASELINE to TIP on a selected Git ref, or `None`
/// when it cannot be measured.
///
/// The shallow-window trick: callers only need bounded questions about the
/// advance ("fewer than tolerance new commits?"), so one bounded shallow
/// fetch into a scratch bare repo answers without cloning the world.
/// `--depth=N` fetches the tip and its N-1 nearest ancestors — exactly the
/// distances 1..N-1 are measurable (measured 2026-10-03: `--depth=6` counts
/// a baseline 5 back; 10 back is absent and `rev-list --count` fails). A
/// FAILING rev-list means the distance exceeds the window (or history was
/// rewritten) and must be treated as ">= the window", never a small move; a
/// fetch that never succeeds is likewise unmeasurable — a waiver needs
/// PROOF, nothing else may lower the verification.
pub fn vcs_git_advance_distance(
    url: &str,
    refspec: &str,
    baseline: &str,
    tip: &str,
    depth: u64,
    sleeper: &mut dyn FnMut(Duration),
) -> Option<u64> {
    let scratch = scratch_dir().ok()?;
    let repo = scratch.join("repo.git");
    let mut fetched = false;
    if git_base()
        .args(["init", "--bare", "-q"])
        .arg(&repo)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
    {
        // The tip query already worked, so a fetch failure is likely another
        // flake: the same bounded retry shape as ls-remote, shorter schedule
        // (3 attempts, 2/5 s — fish `vcs_git_advance_distance`).
        for attempt in 1..=3u32 {
            let ok = git_base()
                .arg("-C")
                .arg(&repo)
                .args(["fetch", "-q"])
                .arg(format!("--depth={depth}"))
                .args(["--filter=tree:0", "--no-tags"])
                .arg(url)
                .arg(refspec)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .map(|s| s.success())
                .unwrap_or(false);
            if ok {
                fetched = true;
                break;
            }
            if attempt < 3 {
                sleeper(Duration::from_secs(if attempt == 1 { 2 } else { 5 }));
            }
        }
    }
    let distance = if fetched {
        git_base()
            .arg("-C")
            .arg(&repo)
            .args(["rev-list", "--count"])
            .arg(format!("{baseline}..{tip}"))
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .output()
            .ok()
            .filter(|o| o.status.success())
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
    } else {
        None
    };
    let _ = fs::remove_dir_all(&scratch);
    match distance {
        Some(d) if !d.is_empty() && d.bytes().all(|b| b.is_ascii_digit()) => {
            let d: u64 = d.parse().ok()?;
            // rev-list reports 0 only when baseline == tip (which reads as
            // `Unchanged` upstream of here); a measured waiver needs >= 1.
            if d >= 1 {
                Some(d)
            } else {
                None
            }
        }
        _ => None,
    }
}

/// A fresh scratch directory under `$TMPDIR` (the engine's one scratch env
/// input, honoured the way fish `mktemp -d` honours it).
fn scratch_dir() -> std::io::Result<PathBuf> {
    static COUNTER: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
    let root = match std::env::var_os("TMPDIR") {
        Some(v) if !v.is_empty() => PathBuf::from(v),
        _ => std::env::temp_dir(),
    };
    for _ in 0..128 {
        let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let path = root.join(format!("gsa-vcs-distance-{}-{n}", std::process::id()));
        match fs::create_dir(&path) {
            Ok(()) => return Ok(path),
            Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e),
        }
    }
    Err(std::io::Error::new(
        std::io::ErrorKind::AlreadyExists,
        "no free scratch directory",
    ))
}

// ---------------------------------------------------------------------------
// Tolerance resolution
// ---------------------------------------------------------------------------

/// The resolved freshness tolerance and any loud warning it earned.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ToleranceResolution {
    pub tolerance: u64,
    pub warning: Option<String>,
}

/// Resolve the `--skip` waive threshold (fish `vcs_skip_tolerance_resolve`):
/// the CLI flag beats `GSA_VCS_SKIP_TOLERANCE`, which must match
/// `^[1-9][0-9]*$` or falls back to the default LOUDLY (a silently ignored
/// knob would make skip decisions unexplainable).
pub fn resolve_vcs_skip_tolerance(flag: Option<u64>) -> ToleranceResolution {
    let env = std::env::var("GSA_VCS_SKIP_TOLERANCE").ok();
    resolve_vcs_skip_tolerance_from(flag, env.as_deref())
}

/// The pure half of [`resolve_vcs_skip_tolerance`]: the same rules with the
/// env value passed in, so callers and tests need no environment mutation.
pub fn resolve_vcs_skip_tolerance_from(
    flag: Option<u64>,
    env_value: Option<&str>,
) -> ToleranceResolution {
    if let Some(tolerance) = flag {
        if tolerance >= 1 {
            return ToleranceResolution {
                tolerance,
                warning: None,
            };
        }
        return ToleranceResolution {
            tolerance: DEFAULT_VCS_SKIP_TOLERANCE,
            warning: Some(format!(
                "--vcs-skip-tolerance '{tolerance}' is not a positive integer — using the default {DEFAULT_VCS_SKIP_TOLERANCE}"
            )),
        };
    }
    if let Some(raw) = env_value {
        let valid =
            !raw.is_empty() && raw.bytes().all(|b| b.is_ascii_digit()) && !raw.starts_with('0');
        if valid {
            if let Ok(tolerance) = raw.parse::<u64>() {
                return ToleranceResolution {
                    tolerance,
                    warning: None,
                };
            }
        }
        return ToleranceResolution {
            tolerance: DEFAULT_VCS_SKIP_TOLERANCE,
            warning: Some(format!(
                "GSA_VCS_SKIP_TOLERANCE='{raw}' is not a positive integer — using the default {DEFAULT_VCS_SKIP_TOLERANCE}"
            )),
        };
    }
    ToleranceResolution {
        tolerance: DEFAULT_VCS_SKIP_TOLERANCE,
        warning: None,
    }
}

// ---------------------------------------------------------------------------
// The per-archive probe (the IO half of `vcs_archive_is_current`)
// ---------------------------------------------------------------------------

/// Options the probe needs beyond the source entries: which waiver rule may
/// apply, and therefore which measurement window to ask for.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProbeOptions {
    /// The resolved freshness tolerance (drives the measurement depth:
    /// tolerance+1 so the boundary AT the tolerance can count).
    pub tolerance: u64,
    /// The recipe carries `.gsa-abi-provider` (drives the wider
    /// [`VCS_ABI_ADVANCE_WINDOW`] informational measurement).
    pub abi_provider: bool,
}

/// One declared source during probing: parsed ref when the entry could be
/// parsed at all.
struct PendingSource {
    key: String,
    name: String,
    info: Option<VcsRef>,
}

/// Probe one archive's VCS freshness against its recorded baseline — the IO
/// port of fish `vcs_archive_is_current`, returning the pure
/// [`ArchiveFreshness`] for [`decide`].
///
/// Return contract mirrored as typed states: `Ok`/waived = current
/// ([`RemoteRevisionState::Unchanged`] / [`RemoteRevisionState::Moved`] under
/// a waiver), moved-past-tolerance = [`RemoteRevisionState::Moved`] with no
/// waiver, unverifiable = [`RemoteRevisionState::Unverifiable`] (transport
/// exhausted / ref unparseable → the DEFERRAL class), missing/malformed/
/// mismatched baseline = the [`BaselineState`] rebuild-once classes — but
/// only after confirming the declared refs ARE queryable.
///
/// `entries` are the expanded `source=()` values; non-VCS entries are
/// ignored. When the archive has no VCS sources the result carries no
/// baseline at all (fish returns 0 before touching the manifest). Entries are
/// probed in declaration order and the pass stops at the first non-current
/// outcome (the fish loop's early return); [`decide`] preserves that
/// first-outcome precedence by iterating the returned states in order.
pub fn probe_archive(
    archive: &Path,
    entries: &[String],
    opts: &ProbeOptions,
    sleeper: &mut dyn FnMut(Duration),
) -> ArchiveFreshness {
    // Distinct VCS entries, first occurrence wins (the manifest holds one row
    // per distinct source).
    let mut seen: Vec<String> = Vec::new();
    let mut pending: Vec<PendingSource> = Vec::new();
    for entry in entries {
        if source_vcs(entry).is_none() {
            continue;
        }
        let key = vcs_source_key(entry);
        if seen.contains(&key) {
            continue;
        }
        seen.push(key.clone());
        pending.push(PendingSource {
            key,
            name: source_filename(entry).unwrap_or_default(),
            info: vcs_source_ref_info(entry),
        });
    }
    if pending.is_empty() {
        return ArchiveFreshness::new(archive);
    }

    let manifest = manifest_path(archive);
    let text = match fs::read_to_string(&manifest) {
        Ok(text) => Some(text),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => None,
        // Present but unreadable: the same unusable-baseline class.
        Err(_) => Some(String::new()),
    };

    let Some(text) = text else {
        // No baseline: rebuild once to record one — but only after confirming
        // the declared refs ARE queryable (unverifiable outranks).
        return ArchiveFreshness {
            archive: archive.to_path_buf(),
            baseline: Some(BaselineState::Missing),
            sources: queryable_states(&pending, sleeper),
        };
    };

    let baseline = match VcsBaseline::parse(&text) {
        // Structural failure OR rows belonging to different sources (count
        // mismatch): the same rebuild-once class in fish's message.
        Ok(b) if b.rows.len() == pending.len() => b,
        _ => {
            return ArchiveFreshness {
                archive: archive.to_path_buf(),
                baseline: Some(BaselineState::Malformed),
                sources: queryable_states(&pending, sleeper),
            }
        }
    };

    // Identity: bound to the exact archive build. Size rejects a truncated
    // write, the checksum rejects a same-size replacement. A fingerprint
    // that cannot be taken is an unusable baseline, never a blessing.
    let identity_ok = fingerprint_archive(archive)
        .map(|fp| fp.sha256 == baseline.archive_sha256 && fp.size == baseline.archive_size)
        .unwrap_or(false);
    if !identity_ok {
        return ArchiveFreshness {
            archive: archive.to_path_buf(),
            baseline: Some(BaselineState::IdentityMismatch),
            sources: queryable_states(&pending, sleeper),
        };
    }

    // Full comparison pass, declaration order (fish's per-entry loop).
    let mut states: Vec<VcsSourceState> = Vec::new();
    for src in &pending {
        let Some(info) = &src.info else {
            // fish returns 2 at this entry's position — deferral class.
            states.push(parse_failure_state(src));
            return ArchiveFreshness {
                archive: archive.to_path_buf(),
                baseline: Some(BaselineState::Ok),
                sources: states,
            };
        };
        let pinned = info.kind == RefKind::Commit;
        let base_state = |remote: RemoteRevisionState| VcsSourceState {
            key: src.key.clone(),
            name: src.name.clone(),
            protocol: Some(info.protocol),
            pinned,
            remote,
        };
        // Exactly one row must match the key, and its protocol must match.
        let matching: Vec<&VcsBaselineRow> =
            baseline.rows.iter().filter(|r| r.key == src.key).collect();
        let row = match matching.as_slice() {
            [row] if row.protocol == info.protocol => *row,
            _ => {
                // Key/protocol mismatch: rebuild once to record — only after
                // confirming the declared refs ARE queryable. The pre-check
                // re-queries from the first entry, exactly like fish.
                return ArchiveFreshness {
                    archive: archive.to_path_buf(),
                    baseline: Some(BaselineState::KeyMismatch {
                        source: src.name.clone(),
                    }),
                    sources: queryable_states(&pending, sleeper),
                };
            }
        };
        let current = match vcs_remote_revision(info, sleeper) {
            Ok(current) => current,
            Err(_) => {
                states.push(base_state(RemoteRevisionState::Unverifiable {
                    error: format!("cannot query upstream revision for {}", src.name),
                }));
                return ArchiveFreshness {
                    archive: archive.to_path_buf(),
                    baseline: Some(BaselineState::Ok),
                    sources: states,
                };
            }
        };
        if pinned {
            // Pinned `#commit=` values may be short hashes: a prefix match
            // against the recorded revision is "current".
            if row.revision.starts_with(&current) {
                states.push(base_state(RemoteRevisionState::Unchanged));
                continue;
            }
            states.push(base_state(RemoteRevisionState::PinnedMismatch));
            return ArchiveFreshness {
                archive: archive.to_path_buf(),
                baseline: Some(BaselineState::Ok),
                sources: states,
            };
        }
        if row.revision == current {
            states.push(base_state(RemoteRevisionState::Unchanged));
            continue;
        }
        // The ref moved. Measure the advance for the waiver rule that can
        // apply: git non-pinned refs only (svn/hg/bzr revisions have no
        // commit distance and waive — or rebuild — on exact match alone).
        let distance = if info.protocol == VcsKind::Git {
            let depth = if opts.abi_provider {
                VCS_ABI_ADVANCE_WINDOW
            } else {
                opts.tolerance.saturating_add(1)
            };
            vcs_git_fetch_refspec(&info.kind, &info.value).and_then(|refspec| {
                vcs_git_advance_distance(
                    &info.url,
                    &refspec,
                    &row.revision,
                    &current,
                    depth,
                    sleeper,
                )
            })
        } else {
            None
        };
        // A waived move continues the pass (the waiver lines are derived
        // purely by decide); an unwaived move is the fish loop's return-1.
        let waived = waiver_for(
            &VcsSourceState {
                key: src.key.clone(),
                name: src.name.clone(),
                protocol: Some(info.protocol),
                pinned,
                remote: RemoteRevisionState::Moved { distance },
            },
            opts.tolerance,
            opts.abi_provider,
            "",
            distance,
        )
        .is_some();
        states.push(base_state(RemoteRevisionState::Moved { distance }));
        if !waived {
            return ArchiveFreshness {
                archive: archive.to_path_buf(),
                baseline: Some(BaselineState::Ok),
                sources: states,
            };
        }
    }
    ArchiveFreshness {
        archive: archive.to_path_buf(),
        baseline: Some(BaselineState::Ok),
        sources: states,
    }
}

/// The rc-3 pre-check states (fish `vcs_selected_refs_queryable`): every
/// declared ref resolved — queryability only, no comparison — stopping at
/// the first failure exactly like the fish helper.
fn queryable_states(
    pending: &[PendingSource],
    sleeper: &mut dyn FnMut(Duration),
) -> Vec<VcsSourceState> {
    let mut states = Vec::new();
    for src in pending {
        let state = match &src.info {
            None => parse_failure_state(src),
            Some(info) => {
                let pinned = info.kind == RefKind::Commit;
                let remote = match vcs_remote_revision(info, sleeper) {
                    Ok(_) => RemoteRevisionState::Resolved,
                    Err(_) => RemoteRevisionState::Unverifiable {
                        error: format!("cannot query upstream revision for {}", src.name),
                    },
                };
                VcsSourceState {
                    key: src.key.clone(),
                    name: src.name.clone(),
                    protocol: Some(info.protocol),
                    pinned,
                    remote,
                }
            }
        };
        let unverifiable = matches!(state.remote, RemoteRevisionState::Unverifiable { .. });
        states.push(state);
        if unverifiable {
            break;
        }
    }
    states
}

fn parse_failure_state(src: &PendingSource) -> VcsSourceState {
    VcsSourceState {
        key: src.key.clone(),
        name: src.name.clone(),
        protocol: None,
        pinned: false,
        remote: RemoteRevisionState::Unverifiable {
            error: "cannot parse a VCS source ref".to_string(),
        },
    }
}
