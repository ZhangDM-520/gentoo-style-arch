//! The fetch/verify pipeline (owner decision 2): `makepkg --verifysource` is
//! the ONLY fetch/verify engine — download-if-needed plus checksum AND PGP
//! verification, then exit before extract/build. Verification is makepkg's
//! and is never re-implemented and never weakened (contract §A.3.4/§L.8):
//! the argv is exactly `["--verifysource"]` with `GIT_CONFIG_COUNT=0`, so no
//! `-s` (no pacman), no `-o`, no `--holdver`, and none of
//! `--skipchecksums`/`--skipinteg`/`--skippgpcheck` can ever appear.
//!
//! Failure handling (owner decision 4): a cached file that fails its pin is
//! QUARANTINED — renamed to `<name>.gsa-bad-<ts>` in the shared source cache
//! (SRCDEST) — and the recipe is retried ONCE, loudly. The recipe's
//! checksum/`validpgpkeys` remain the trust anchor throughout; a bad file is
//! never left at its final name (makepkg re-verifies such files forever —
//! the wall class docs/plans/plan.md §3.5 documents).
//!
//! Attribution of the failing file is makepkg's own failure report (`<file>
//! … FAILED` lines, `/usr/share/makepkg/integrity/verify_checksum.sh` and
//! `verify_signature.sh`); this module never parses makepkg output to
//! *decide* verification — only to name the file to quarantine. makepkg
//! gettext-translates that prose and its exit codes carry no class, so the
//! spawn pins `LC_ALL=C`: every prose match below is C-locale by
//! construction (see [`verifysource_command`]).

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use crate::candidacy::{classify, FetchCandidacy};
use crate::verdict::{
    self, FetchResult, FetchVerdict, REASON_DISK_FLOOR, REASON_EVAL_FAILED, REASON_FETCH_FAILED,
    REASON_LOCAL_SOURCE_MISSING, REASON_OK, REASON_QUARANTINED_RETRY_OK, REASON_RETRY_OK,
    REASON_UNVERIFIED_SUMS, REASON_VERIFY_FAILED,
};

/// Transport attempts per recipe before the lane takes over (docs/plans/plan.md §2.3
/// `_PF_RETRY` = 2, 10 s apart).
pub const FETCH_ATTEMPTS: u32 = 2;
pub const FETCH_RETRY_DELAY_S: u64 = 10;

/// Pause prefetch below this much free space on the SRCDEST filesystem
/// (docs/plans/plan.md §2.3 `_PF_DISK_FREE_MIN_GIB` = 5 GiB, recorded in
/// docs/adr/0004-prefetch-advisory.md).
pub const DISK_FREE_MIN_GIB: u64 = 5;

/// Unadvertised fixture seams (the `_GSA_STOP_GRACE_S` class,
/// `gsa-sched::signals`): never engine inputs, never in `--help`, only so
/// fixtures can tune timing without inventing a `GSA_*` knob (§D.2).
fn env_u64(name: &str, default: u64) -> u64 {
    match std::env::var(name) {
        Ok(v) if !v.is_empty() => v.parse::<u64>().ok().unwrap_or(default),
        _ => default,
    }
}

pub fn fetch_retry_delay_s() -> u64 {
    env_u64("_GSA_FETCH_RETRY_S", FETCH_RETRY_DELAY_S)
}

pub fn disk_free_min_gib() -> u64 {
    env_u64("_GSA_DISK_FLOOR_GIB", DISK_FREE_MIN_GIB)
}

/// Find the recipe repository: walk up from `start` until
/// `config/topology.conf` exists (same rule as `gsa-build::find_root`).
pub use gsa_model::config::find_root;

/// The shared source cache (SRCDEST) makepkg downloads into. Resolution
/// mirrors makepkg's lookup as closely as shell-free code may: the
/// `SRCDEST` environment first (fixture control and explicit operator
/// intent), then the simple `SRCDEST=…` assignment of `~/.makepkg.conf`,
/// then `/etc/makepkg.conf`. `None` means makepkg's `$startdir` default —
/// the fetch child then skips quarantine and says so loudly rather than
/// touching recipe directories (contract §D.1: the child touches only the
/// shared source cache).
/// The makepkg `SRCDEST` seam — one resolution lives in `gsa-model::config`
/// (the build user's makepkg.conf, never the raw env alone).
pub fn resolve_srcdest() -> Option<PathBuf> {
    gsa_model::config::resolve_srcdest()
}

#[repr(C)]
struct StatVfs {
    f_bsize: u64,
    f_frsize: u64,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_favail: u64,
    f_fsid: u64,
    f_flag: u64,
    f_namemax: u64,
    _spare: [u32; 6],
}

extern "C" {
    fn statvfs(path: *const std::ffi::c_char, buf: *mut StatVfs) -> i32;
}

/// Free space (GiB) on the filesystem holding `path` (`statvfs`, no
/// subprocess). `None` when the probe fails.
pub fn disk_free_gib(path: &Path) -> Option<u64> {
    let c = std::ffi::CString::new(path.to_string_lossy().as_bytes()).ok()?;
    let mut buf: StatVfs = unsafe { std::mem::zeroed() };
    if unsafe { statvfs(c.as_ptr(), &mut buf) } != 0 {
        return None;
    }
    let bytes = buf.f_bavail.saturating_mul(buf.f_frsize.max(buf.f_bsize));
    Some(bytes / (1024 * 1024 * 1024))
}

/// The disk-floor gate (owner decision 6): true when fetch-ahead may spawn
/// — free space on the cache filesystem is at least the floor.
pub fn disk_floor_ok(cache_path: &Path) -> bool {
    match disk_free_gib(cache_path) {
        Some(gib) => gib >= disk_free_min_gib(),
        // An unprobeable floor never blocks fetch-ahead; the download
        // itself fails loudly if the disk really is full.
        None => true,
    }
}

/// What a verification-class failure actually indicts. makepkg runs the
/// checksum stage and the signature stage as separate `==>` sections and
/// `check_source_integrity` returns on a checksum failure, so the two never
/// co-occur in one attempt (`/usr/share/makepkg/integrity.sh:42-43`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum VerifyFailure {
    /// `==> Validating source files with <algo>…`: the bytes on disk are not
    /// the bytes the recipe pins.
    Checksum { files: Vec<String> },
    /// `==> Verifying source file signatures with gpg…`: makepkg names the
    /// PAYLOAD (it prints `${file%.*}`), so `files` is what the signature
    /// covers, never proof about that file's own bytes.
    Signature {
        files: Vec<String>,
        reason: &'static str,
        detail: String,
    },
}

impl VerifyFailure {
    /// The files the report named (payloads, for both classes).
    pub fn files(&self) -> &[String] {
        match self {
            VerifyFailure::Checksum { files } | VerifyFailure::Signature { files, .. } => files,
        }
    }

    /// The reason key this class reports.
    pub fn reason(&self) -> &'static str {
        match self {
            VerifyFailure::Checksum { .. } => REASON_VERIFY_FAILED,
            VerifyFailure::Signature { reason, .. } => reason,
        }
    }
}

/// Read makepkg's verification report into the class it actually failed.
///
/// The prose is C-locale by construction ([`verifysource_command`] pins
/// `LC_ALL=C`): a `==>` header selects the stage, and a `    <file> … FAILED`
/// line inside it is an offender of THAT stage. Reading only the `FAILED`
/// token — as this module once did — is what let a signature failure
/// quarantine a payload whose checksum had just PASSED, and what collapsed a
/// missing keyring entry and a bad download into one `verify-failed`.
pub fn verify_failure(output: &str) -> Option<VerifyFailure> {
    #[derive(Clone, Copy, PartialEq, Eq)]
    enum Stage {
        Other,
        Checksum,
        Signature,
    }
    let mut stage = Stage::Other;
    let mut checksum: Vec<String> = Vec::new();
    let mut signature: Vec<(String, String)> = Vec::new();
    let mut unattributed: Vec<String> = Vec::new();
    let mut saw_stage = false;
    for raw in output.lines() {
        let line = raw.trim();
        if let Some(header) = line.strip_prefix("==> ") {
            stage = if header.starts_with("Validating source files") {
                saw_stage = true;
                Stage::Checksum
            } else if header.starts_with("Verifying source file signatures") {
                saw_stage = true;
                Stage::Signature
            } else {
                Stage::Other
            };
            continue;
        }
        let Some((name, rest)) = line.split_once(" ... ") else {
            continue;
        };
        let Some(detail) = rest.strip_prefix("FAILED") else {
            continue;
        };
        if name.is_empty() {
            continue;
        }
        let detail = detail
            .trim()
            .trim_start_matches('(')
            .trim_end_matches(')')
            .trim();
        match stage {
            Stage::Checksum => {
                if !checksum.iter().any(|n| n == name) {
                    checksum.push(name.to_string());
                }
            }
            Stage::Signature => {
                if !signature.iter().any(|(n, _)| n == name) {
                    signature.push((name.to_string(), detail.to_string()));
                }
            }
            Stage::Other => {
                if !unattributed.iter().any(|n| n == name) {
                    unattributed.push(name.to_string());
                }
            }
        }
    }
    // A report with no stage header at all is the pre-header shape (and what
    // a minimal oracle prints). It keeps the CHECKSUM class: that is the
    // quarantine-and-retry class, the conservative reading, and it never
    // claims a key problem the prose did not name.
    if checksum.is_empty() && !saw_stage {
        checksum = unattributed;
    }
    if !checksum.is_empty() {
        return Some(VerifyFailure::Checksum { files: checksum });
    }
    if !signature.is_empty() {
        let detail = signature
            .iter()
            .map(|(_, d)| d.as_str())
            .find(|d| !d.is_empty())
            .unwrap_or("")
            .to_string();
        return Some(VerifyFailure::Signature {
            files: signature.into_iter().map(|(n, _)| n).collect(),
            reason: verdict::classify_signature_failure(&detail),
            detail,
        });
    }
    None
}

/// Was this failure a verification (integrity) failure rather than a
/// One `makepkg --verifysource` attempt.
#[derive(Clone, Debug)]
pub struct Attempt {
    pub ok: bool,
    pub output: String,
}

/// Quarantine one cached file: rename `<name>` to `<name>.gsa-bad-<ts>` in
/// the shared source cache (owner decision 4). Returns `Ok(None)` when the
/// file is absent from the cache (nothing to move — never a recipe-directory
/// move) or propagates rename I/O failures so callers report them loudly.
pub fn quarantine_file(cache: &Path, name: &str) -> std::io::Result<Option<PathBuf>> {
    let from = cache.join(name);
    match std::fs::symlink_metadata(&from) {
        Ok(meta) if !meta.is_dir() => {}
        Ok(_) => return Ok(None),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error),
    }
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let to = cache.join(format!("{name}.gsa-bad-{ts}"));
    std::fs::rename(&from, &to)?;
    Ok(Some(to))
}

/// Signature companions makepkg fetches beside a source file (the PGP
/// failure class quarantines them too: when the source passed its checksum
/// pin the companion is the suspect, and either way the retry re-fetches).
pub fn signature_companions(name: &str) -> Vec<String> {
    [".sig", ".asc", ".sign"]
        .iter()
        .map(|suffix| format!("{name}{suffix}"))
        .collect()
}

/// Quarantine outcomes: moved filenames and any filesystem errors observed.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct QuarantineOutcome {
    pub moved: Vec<String>,
    pub errors: Vec<String>,
}

/// Quarantine the named files and their signature companions. Returns both
/// moved filenames and any rename/stat errors so failures are surfaced loudly.
pub fn quarantine_bad_files(cache: &Path, names: &[String]) -> QuarantineOutcome {
    let mut outcome = QuarantineOutcome::default();
    for name in names {
        for candidate in std::iter::once(name.clone()).chain(signature_companions(name)) {
            match quarantine_file(cache, &candidate) {
                Ok(Some(_)) => outcome.moved.push(candidate),
                Ok(None) => {}
                Err(error) => outcome
                    .errors
                    .push(format!("cannot quarantine {candidate}: {error}")),
            }
        }
    }
    outcome
}

/// Everything one fetch recipe run produced.
#[derive(Clone, Debug)]
pub struct FetchReport {
    pub result: FetchResult,
    /// Quarantined file names, in order (loud: warning + log, owner
    /// decision 4).
    pub quarantined: Vec<String>,
    /// Human notes for the run's prefetch log (attempts, quarantine detail).
    pub notes: Vec<String>,
}

/// The fetch/verify pipeline over a scripted attempt runner — the seam the
/// unit tests drive (and the reason the retry/quarantine policy is testable
/// without processes).
///
/// Policy (docs/plans/plan.md §2.2/§2.3, owner decision 4):
/// - transport failures retry up to `FETCH_ATTEMPTS` times, `delay_s` apart;
/// - a failure that names a bad file quarantines it (plus signature
///   companions) and retries ONCE immediately — further bad files are still
///   quarantined (a bad file is never left at its final name) but never
///   retried again;
/// - `ok` after a quarantine is `quarantined-retry-ok`, after a plain retry
///   `retry-ok` — both warning-class (the host misbehaved).
pub fn run_fetch_attempts(
    pkg: &str,
    cache: Option<&Path>,
    mut attempt: impl FnMut() -> Attempt,
    delay_s: u64,
) -> FetchReport {
    run_fetch_attempts_checked(pkg, cache, || Ok(attempt()), delay_s)
}

/// Checked variant of [`run_fetch_attempts`] where `Err(diag)` represents a
/// permanent setup/spawn failure that fails fast without sleeping or retrying.
pub fn run_fetch_attempts_checked(
    pkg: &str,
    cache: Option<&Path>,
    mut attempt: impl FnMut() -> Result<Attempt, String>,
    delay_s: u64,
) -> FetchReport {
    let start = Instant::now();
    let mut notes: Vec<String> = Vec::new();
    let mut quarantined: Vec<String> = Vec::new();
    let mut attempts = 0u32;
    let mut transport_retries = 0u32;
    let mut quarantine_retry_used = false;
    let mut hard_failure: Option<&'static str> = None;

    while attempts < 6 {
        attempts += 1;
        let att = match attempt() {
            Ok(att) => att,
            Err(diag) => {
                notes.push(diag);
                hard_failure = Some(REASON_EVAL_FAILED);
                break;
            }
        };
        if att.ok {
            let reason = if quarantined.is_empty() {
                if attempts > 1 {
                    REASON_RETRY_OK
                } else {
                    REASON_OK
                }
            } else {
                REASON_QUARANTINED_RETRY_OK
            };
            let result = FetchResult::new(pkg, FetchVerdict::Ok, start.elapsed().as_secs(), reason)
                .expect("pkg is validated by the caller");
            return FetchReport {
                result,
                quarantined,
                notes,
            };
        }
        notes.push(format!("attempt {attempts} failed"));

        let Some(failure) = verify_failure(&att.output) else {
            // Transport-class failure: retry once more, 10 s apart (docs/plans/plan.md).
            if transport_retries < FETCH_ATTEMPTS.saturating_sub(1) {
                transport_retries += 1;
                if delay_s > 0 {
                    std::thread::sleep(std::time::Duration::from_secs(delay_s));
                }
                continue;
            }
            hard_failure = Some(REASON_FETCH_FAILED);
            break;
        };
        let named = failure.files().to_vec();
        let reason = failure.reason();

        // A SIGNATURE failure whose cause is TRUST in the key indicts nothing
        // on disk: the same bytes re-download to the same unverifiable
        // signature. Quarantining the payload would destroy a byte-perfect
        // download and the retry would only spend the network, so fail at
        // once with the reason that names the repair (R2-juno-4).
        if verdict::is_sig_trust_reason(reason) {
            let detail = match &failure {
                VerifyFailure::Signature { detail, .. } if !detail.is_empty() => detail.clone(),
                _ => "makepkg could not check the signature".to_string(),
            };
            notes.push(format!(
                "{reason}: {} — {detail}; the file is not the suspect (re-fetching the same bytes cannot change the outcome)",
                named.join(", ")
            ));
            hard_failure = Some(reason);
            break;
        }

        // A QUARANTINE class: the payload is the suspect for a checksum
        // failure; for a cryptographic signature failure only the signature
        // COMPANION is (the bytes it signs verified).
        let suspects = match &failure {
            VerifyFailure::Checksum { .. } => named.clone(),
            VerifyFailure::Signature { files, .. } => files
                .iter()
                .flat_map(|name| signature_companions(name))
                .collect(),
        };
        match cache {
            Some(cache) => {
                let outcome = quarantine_bad_files(cache, &suspects);
                notes.extend(outcome.errors);
                if outcome.moved.is_empty() {
                    notes.push(format!(
                        "cannot quarantine {} (not quarantined from shared source cache) — the wall stands until it is removed",
                        suspects.join(", ")
                    ));
                    hard_failure = Some(reason);
                    break;
                }
                notes.push(format!("quarantined {}", outcome.moved.join(", ")));
                quarantined.extend(outcome.moved);
            }
            None => {
                notes.push(format!(
                    "cannot quarantine {} — SRCDEST unresolvable, the shared source cache is unknown",
                    suspects.join(", ")
                ));
                hard_failure = Some(reason);
                break;
            }
        }
        if quarantine_retry_used {
            hard_failure = Some(reason);
            break;
        }
        quarantine_retry_used = true;
    }

    let reason = hard_failure.unwrap_or(REASON_VERIFY_FAILED);
    let result = FetchResult::new(pkg, FetchVerdict::Failed, start.elapsed().as_secs(), reason)
        .expect("pkg is validated by the caller");
    FetchReport {
        result,
        quarantined,
        notes,
    }
}

/// The ONE `makepkg --verifysource` command (contract §D.1 / owner decision
/// 2 — the argv is a constant, so no verification bypass can be
/// constructed). `LC_ALL=C` pins makepkg's failure prose to C: makepkg
/// gettext-translates `FAILED` and its validity summary, and its exit codes
/// are all 1 (`exit 1 # TODO: error code` in `verify_checksum.sh`) so they
/// discriminate nothing — C-locale prose is the only attribution channel.
pub(crate) fn verifysource_command(recipe_dir: &Path) -> Result<Command, String> {
    let mut cmd = gsa_model::privilege::build_command("makepkg");
    cmd.arg("--verifysource")
        .current_dir(recipe_dir)
        .env("GIT_CONFIG_COUNT", "0")
        .env("LC_ALL", "C");
    // §B.11: the engine owns the makepkg configuration, so the fetch honours
    // the same source cache the build will. `--verifysource` reads only the
    // universal half (SRCDEST and friends); the compiler body in the
    // composite is inert here, so the run override or the default family is
    // enough and no recipe scan is needed.
    let toolchain =
        gsa_model::toolchain::override_value().unwrap_or(gsa_model::toolchain::Toolchain::DEFAULT);
    let layout = gsa_model::config::build_layout_for_run()?;
    match gsa_model::config::resolve_srcdest_checked()?.0 {
        Some(srcdest) => {
            let abs = gsa_model::config::absolute_for_child(&srcdest);
            cmd.env("SRCDEST", &abs);
            cmd.env("GSA_LANE_SRCDEST", abs);
        }
        None => {
            cmd.env_remove("SRCDEST");
            cmd.env_remove("GSA_LANE_SRCDEST");
        }
    }
    let conf = gsa_model::makepkg_conf::install(&layout.root, toolchain)?;
    cmd.arg("--config").arg(conf);
    Ok(cmd)
}

/// One real `makepkg --verifysource` attempt in the recipe directory
/// (contract §D.1 / owner decision 2), distinguishing setup/spawn errors from
/// makepkg verification/transport failures so permanent setup errors fail fast.
pub fn try_makepkg_verifysource(recipe_dir: &Path) -> Result<Attempt, String> {
    let mut command = verifysource_command(recipe_dir)
        .map_err(|message| format!("cannot configure makepkg: {message}"))?;
    let output = command
        .output()
        .map_err(|error| format!("cannot run makepkg: {error}"))?;
    let mut text = String::from_utf8_lossy(&output.stdout).into_owned();
    text.push_str(&String::from_utf8_lossy(&output.stderr));
    Ok(Attempt {
        ok: output.status.success(),
        output: text,
    })
}

pub fn makepkg_verifysource(recipe_dir: &Path) -> Attempt {
    match try_makepkg_verifysource(recipe_dir) {
        Ok(att) => att,
        Err(message) => Attempt {
            ok: false,
            output: message,
        },
    }
}

/// Fetch-and-verify one recipe: candidacy first (never a grep, owner
/// decision 3), then the disk floor (owner decision 6), then the pipeline.
/// Never touches pacman or sudo; writes only the shared source cache.
pub fn fetch_recipe(pkg: &str, root: &Path, err: &mut dyn Write) -> FetchResult {
    let (recipe_dir, meta) = match recipe_dir_and_meta(pkg, root) {
        Ok(pair) => pair,
        Err(why) => {
            let _ = writeln!(err, "gsa-fetch: {pkg}: {why}");
            return FetchResult::new(pkg, FetchVerdict::Failed, 0, REASON_EVAL_FAILED)
                .expect("pkg is validated by the caller");
        }
    };
    let candidacy = classify(&meta);
    // A declared local source that is absent means the build cannot start;
    // the fetch run must say so rather than skip as "nothing to fetch"
    // (blind-review 2026-11-11, airgapped-admin). makepkg's own verdict is
    // the same class, but this costs no spawn and names every missing file.
    let missing = meta.missing_local_sources(&recipe_dir);
    if !missing.is_empty() {
        let _ = writeln!(
            err,
            "gsa-fetch: {pkg}: {REASON_LOCAL_SOURCE_MISSING}: {} — declared in source=() but absent from {}",
            missing.join(" "),
            recipe_dir.display()
        );
        return FetchResult::new(pkg, FetchVerdict::Failed, 0, REASON_LOCAL_SOURCE_MISSING)
            .expect("pkg is validated by the caller");
    }
    if let Some(skip) = candidacy.skip_verdict(pkg) {
        let _ = writeln!(
            err,
            "gsa-fetch: {pkg}: skipped {} (nothing to fetch ahead)",
            skip.reason
        );
        return skip;
    }
    let cache = match gsa_model::config::resolve_srcdest_checked() {
        Ok((cache, _)) => cache,
        Err(why) => {
            let _ = writeln!(err, "gsa-fetch: {pkg}: configuration error: {why}");
            return FetchResult::new(pkg, FetchVerdict::Failed, 0, REASON_EVAL_FAILED)
                .expect("pkg is validated by the caller");
        }
    };
    let floor_probe = cache.clone().unwrap_or_else(|| recipe_dir.clone());
    if !disk_floor_ok(&floor_probe) {
        let _ = writeln!(
            err,
            "gsa-fetch: {pkg}: skipped {REASON_DISK_FLOOR} (free space below {} GiB floor)",
            disk_free_min_gib()
        );
        return FetchResult::new(pkg, FetchVerdict::Skipped, 0, REASON_DISK_FLOOR)
            .expect("pkg is validated by the caller");
    }
    let report = run_fetch_attempts_checked(
        pkg,
        cache.as_deref(),
        || try_makepkg_verifysource(&recipe_dir),
        fetch_retry_delay_s(),
    );
    for note in &report.quarantined {
        let _ = writeln!(err, "gsa-fetch: {pkg}: quarantined {note} (retrying once)");
    }
    for note in &report.notes {
        let _ = writeln!(err, "gsa-fetch: {pkg}: {note}");
    }
    // A signature-trust failure owes a REMEDY, not just a reason: the two
    // repairs are mutually exclusive and a user cannot tell them apart from
    // the reason alone (R2-juno-4 — "the difference between a bad recipe and
    // a bad keyring is exactly what I need to know").
    if let Some(remedy) = remedy_for_reason(&report.result.reason, &meta) {
        let _ = writeln!(err, "gsa-fetch: {pkg}: remedy: {remedy}");
    }
    let mut result = report.result;
    // A remote source the recipe pins as `SKIP` was fetched, never verified
    // — never report that as a clean `ok` (blind-review 2026-11-11).
    if result.verdict == FetchVerdict::Ok && result.reason == REASON_OK {
        let unverified = meta.unverified_remote_sums();
        if !unverified.is_empty() {
            let _ = writeln!(
                err,
                "gsa-fetch: {pkg}: {REASON_UNVERIFIED_SUMS}: {} — fetched but never verified (the recipe pins SKIP)",
                unverified.join(" ")
            );
            result.reason = REASON_UNVERIFIED_SUMS.to_string();
        }
    }
    result
}

/// The operator-facing remedy for a signature-trust failure, or `None` when
/// the reason is not a trust class. The two repairs are genuinely different
/// and mutually exclusive, which is why one reason word cannot carry them:
/// an unknown key is a KEYRING problem, a not-allowed key is a RECIPE
/// problem, and a no-`validpgpkeys` recipe is a RECIPE-DECLARATION problem.
fn remedy_for_reason(reason: &str, meta: &gsa_recipe::RecipeMeta) -> Option<String> {
    if !verdict::is_sig_trust_reason(reason) {
        return None;
    }
    let keys = meta
        .srcinfo
        .as_ref()
        .map(|info| info.validpgpkeys.clone())
        .or_else(|| match meta.scanned.as_ref()?.vars.get("validpgpkeys")? {
            gsa_recipe::ScanValue::Array(items) => Some(items.clone()),
            gsa_recipe::ScanValue::Scalar(one) => Some(vec![one.clone()]),
        })
        .unwrap_or_default();
    let allowed = if keys.is_empty() {
        "this recipe declares no validpgpkeys".to_string()
    } else {
        format!("this recipe allows {}", keys.join(" "))
    };
    Some(match reason {
        verdict::REASON_SIG_KEY_UNKNOWN => format!(
            "the signing key is not in the local keyring ({allowed}). Receive it \
             (the gpg line above names the key) — re-fetching the same bytes \
             cannot change the verdict"
        ),
        verdict::REASON_SIG_KEY_NOT_ALLOWED => format!(
            "upstream signed with a key this recipe does not allow ({allowed}). \
             Decide which is wrong: add the signing key to validpgpkeys, or \
             take the release only after the recipe's key set is corrected"
        ),
        verdict::REASON_SIG_KEY_UNTRUSTED => format!(
            "no key is pinned here ({allowed}), so gpg fell back to local trust \
             and the key is not trusted. Pin the signing key in validpgpkeys"
        ),
        _ => return None,
    })
}

fn recipe_dir_and_meta(
    pkg: &str,
    root: &Path,
) -> Result<(PathBuf, gsa_recipe::RecipeMeta), String> {
    let project = gsa_topo::load_project(root).map_err(|e| format!("configuration error: {e}"))?;
    let record = project
        .topology
        .get(pkg)
        .ok_or_else(|| format!("unknown recipe '{pkg}'"))?;
    let db = gsa_recipe::RecipeDb::load(root, std::slice::from_ref(record))
        .map_err(|e| format!("recipe metadata error: {e}"))?;
    let meta = db
        .get(pkg)
        .map(|meta| (*meta).clone())
        .ok_or_else(|| format!("recipe metadata missing for '{pkg}'"))?;
    Ok((root.join(&record.path), meta))
}

/// The recipe directory of one topology id (read-only).
pub fn recipe_dir_for(pkg: &str, root: &Path) -> Result<PathBuf, String> {
    let project = gsa_topo::load_project(root).map_err(|e| format!("configuration error: {e}"))?;
    let record = project
        .topology
        .get(pkg)
        .ok_or_else(|| format!("unknown recipe '{pkg}'"))?;
    Ok(root.join(&record.path))
}

/// The fetch candidacy of one recipe (committed `.SRCINFO` or the strict
/// scan fallback — `gsa-recipe`, never grep).
pub fn candidacy_for(pkg: &str, root: &Path) -> Result<FetchCandidacy, String> {
    Ok(classify(&meta_for(pkg, root)?))
}

/// One recipe's loaded metadata (read-only): the shared input of candidacy
/// and the integrity checks above.
pub fn meta_for(pkg: &str, root: &Path) -> Result<gsa_recipe::RecipeMeta, String> {
    let project = gsa_topo::load_project(root).map_err(|e| format!("configuration error: {e}"))?;
    let record = project
        .topology
        .get(pkg)
        .ok_or_else(|| format!("unknown recipe '{pkg}'"))?;
    let db = gsa_recipe::RecipeDb::load(root, std::slice::from_ref(record))
        .map_err(|e| format!("recipe metadata error: {e}"))?;
    db.get(pkg)
        .map(|meta| (*meta).clone())
        .ok_or_else(|| format!("recipe metadata missing for '{pkg}'"))
}

/// `gsa --fetch-job <pkg> <result-path>` (contract §D.1): the one-shot
/// fetch child. Exactly two positionals; control characters and extra
/// arguments are rc 2 with a message naming the argument. The child touches
/// ONLY the shared source cache (SRCDEST) — never recipe directories, never
/// pacman, never sudo — and publishes exactly one typed result row through
/// the codec. It exits 0 always: a `failed` verdict is data, not process
/// failure.
pub fn run_fetch_job(args: &[String], err: &mut dyn Write) -> i32 {
    if args.len() != 2 {
        let _ = writeln!(
            err,
            "gsa --fetch-job: usage: gsa --fetch-job <pkg> <result-path> (got {} argument(s))",
            args.len()
        );
        return 2;
    }
    let pkg = &args[0];
    if gsa_model::RecipeId::new(pkg).is_err() {
        let _ = writeln!(
            err,
            "gsa --fetch-job: package '{pkg}' is not a valid recipe id"
        );
        return 2;
    }
    if args[1].is_empty() || args[1].chars().any(|c| c.is_control()) {
        let _ = writeln!(
            err,
            "gsa --fetch-job: result path '{}' is empty or carries control characters",
            args[1]
        );
        return 2;
    }
    let result_path = PathBuf::from(&args[1]);

    let cwd = std::env::current_dir().unwrap_or_else(|_| PathBuf::from("."));
    let Some(root) = find_root(&cwd) else {
        let _ = writeln!(
            err,
            "gsa --fetch-job: cannot find config/topology.conf from the current directory upward — {}",
            gsa_model::config::WORKSPACE_HINT
        );
        return 2;
    };
    let result = fetch_recipe(pkg, &root, err);
    match verdict::publish(&result_path, &result) {
        Ok(()) => 0,
        Err(message) => {
            let _ = writeln!(err, "gsa --fetch-job: {message}");
            // Fail closed to the reader: no usable result is a loud
            // `result-lost` advisory on the dispatcher side (§F.2).
            0
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::verdict::{
        REASON_NOT_A_CANDIDATE, REASON_RESULT_LOST, REASON_SIG_BAD, REASON_SIG_ERROR,
        REASON_SIG_KEY_NOT_ALLOWED, REASON_SIG_KEY_UNKNOWN, REASON_SIG_KEY_UNTRUSTED,
        REASON_VCS_ONLY,
    };

    fn scratch(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("gsa-fetch-engine-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn a_report_naming_no_file_is_a_transport_failure() {
        // `verify_failure` returning None is what routes an attempt to the
        // transport class, so a bare curl error must stay unrecognised as a
        // verification failure.
        assert!(verify_failure("curl: (56) unexpected eof").is_none());
    }

    #[test]
    fn a_signature_failure_is_never_read_as_a_checksum_failure() {
        // The exact two stages makepkg prints for R2-juno-4: the checksum
        // stage PASSES the payload and skips the signature, then the
        // signature stage blames the payload for a key the keyring lacks.
        let output = "\
==> Validating source files with sha256sums...
    rsync-3.5.2.tar.gz ... Passed
    rsync-3.5.2.tar.gz.asc ... Skipped
    rsyncd.conf ... Passed
==> Verifying source file signatures with gpg...
    rsync-3.5.2.tar.gz ... FAILED (unknown public key 6909546B2C52EC2D)
==> ERROR: One or more PGP signatures could not be verified!
";
        match verify_failure(output) {
            Some(VerifyFailure::Signature {
                files,
                reason,
                detail,
            }) => {
                assert_eq!(files, vec!["rsync-3.5.2.tar.gz".to_string()]);
                assert_eq!(reason, REASON_SIG_KEY_UNKNOWN);
                assert!(detail.contains("6909546B2C52EC2D"), "{detail}");
            }
            other => panic!("a signature failure must not read as a checksum one: {other:?}"),
        }
        assert!(verdict::is_sig_trust_reason(REASON_SIG_KEY_UNKNOWN));
    }

    #[test]
    fn a_checksum_failure_still_names_the_payload() {
        let output = "\
==> Validating source files with sha256sums...
    bad-1.0.tar.gz ... FAILED
==> ERROR: One or more files did not pass the validity check!
";
        match verify_failure(output) {
            Some(VerifyFailure::Checksum { files }) => {
                assert_eq!(files, vec!["bad-1.0.tar.gz".to_string()]);
            }
            other => panic!("expected a checksum failure, got {other:?}"),
        }
    }

    #[test]
    fn every_signature_parenthetical_maps_to_its_own_reason() {
        // verify_signature.sh's five shapes, verbatim (C locale).
        let cases = [
            (
                "unknown public key 6909546B2C52EC2D",
                REASON_SIG_KEY_UNKNOWN,
            ),
            (
                "the public key ABCDEF0123456789 is not trusted",
                REASON_SIG_KEY_UNTRUSTED,
            ),
            (
                "invalid public key 8EDF88F4731A1E8B45D67FBE6909546B2C52EC2D",
                REASON_SIG_KEY_NOT_ALLOWED,
            ),
            (
                "public key ABC has been revoked",
                REASON_SIG_KEY_NOT_ALLOWED,
            ),
            (
                "bad signature from public key ABCDEF0123456789",
                REASON_SIG_BAD,
            ),
            ("error during signature verification", REASON_SIG_ERROR),
        ];
        for (detail, want) in cases {
            assert_eq!(
                verdict::classify_signature_failure(detail),
                want,
                "detail: {detail}"
            );
        }
        // Only the three TRUST reasons skip the quarantine-and-retry path.
        assert!(!verdict::is_sig_trust_reason(REASON_SIG_BAD));
        assert!(!verdict::is_sig_trust_reason(REASON_SIG_ERROR));
        assert!(verdict::is_sig_reason(REASON_SIG_BAD));
    }

    /// A recipe meta carrying only a `validpgpkeys` set, for the remedy tests.
    fn meta_with_keys(keys: &[&str]) -> gsa_recipe::RecipeMeta {
        use gsa_model::RecipeId;
        gsa_recipe::RecipeMeta {
            id: RecipeId::new("pkg").unwrap(),
            path: "packages/test/pkg".to_string(),
            srcinfo: Some(gsa_recipe::Srcinfo {
                pkgbase: Some("pkg".to_string()),
                validpgpkeys: keys.iter().map(|k| (*k).to_string()).collect(),
                ..Default::default()
            }),
            scanned: None,
            source: gsa_recipe::MetaSource::Srcinfo,
        }
    }

    #[test]
    fn a_trust_failure_names_the_repair_and_the_recipe_key_set() {
        let pinned = meta_with_keys(&["AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"]);
        let remedy = remedy_for_reason(REASON_SIG_KEY_NOT_ALLOWED, &pinned).unwrap();
        assert!(remedy.contains("validpgpkeys"), "{remedy}");
        assert!(
            remedy.contains("AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"),
            "the remedy must name the recipe's allowed set: {remedy}"
        );
        // The unknown-key repair is a KEYRING action, not a recipe edit.
        let unknown = remedy_for_reason(REASON_SIG_KEY_UNKNOWN, &pinned).unwrap();
        assert!(unknown.contains("keyring"), "{unknown}");
        assert!(
            unknown.contains("cannot change the verdict"),
            "it must say a re-fetch is pointless: {unknown}"
        );
        // A recipe with no pin at all is a declaration problem.
        let bare = meta_with_keys(&[]);
        let untrusted = remedy_for_reason(REASON_SIG_KEY_UNTRUSTED, &bare).unwrap();
        assert!(untrusted.contains("no key is pinned"), "{untrusted}");
        // Non-trust reasons owe no remedy line of their own.
        assert!(remedy_for_reason(REASON_VERIFY_FAILED, &pinned).is_none());
        assert!(remedy_for_reason(REASON_SIG_BAD, &pinned).is_none());
    }

    #[test]
    fn a_trust_failure_quarantines_nothing_and_retries_nothing() {
        // the attempt must be spent ONCE and the good bytes left in place.
        let cache = scratch("sig-trust");
        std::fs::write(cache.join("good.tar.gz"), b"perfect bytes").unwrap();
        std::fs::write(cache.join("good.tar.gz.asc"), b"signature").unwrap();
        let mut calls = 0;
        let report = run_fetch_attempts(
            "pkg",
            Some(&cache),
            || {
                calls += 1;
                Attempt {
                    ok: false,
                    output: "==> Verifying source file signatures with gpg...\n    good.tar.gz ... FAILED (unknown public key 6909546B2C52EC2D)\n".to_string(),
                }
            },
            0,
        );
        assert_eq!(calls, 1, "a trust failure is not retried");
        assert_eq!(report.result.verdict, FetchVerdict::Failed);
        assert_eq!(report.result.reason, REASON_SIG_KEY_UNKNOWN);
        assert!(report.quarantined.is_empty(), "nothing may be quarantined");
        assert!(
            cache.join("good.tar.gz").exists(),
            "a payload whose checksum passed must survive a signature failure"
        );
        let notes = report.notes.join("\n");
        assert!(notes.contains(REASON_SIG_KEY_UNKNOWN), "{notes}");
        assert!(notes.contains("6909546B2C52EC2D"), "{notes}");
        std::fs::remove_dir_all(&cache).ok();
    }

    #[test]
    fn a_bad_signature_quarantines_only_its_companion_and_retries_once() {
        let cache = scratch("sig-bad");
        std::fs::write(cache.join("good.tar.gz"), b"perfect bytes").unwrap();
        std::fs::write(cache.join("good.tar.gz.asc"), b"signature").unwrap();
        let mut calls = 0;
        let report = run_fetch_attempts(
            "pkg",
            Some(&cache),
            || {
                calls += 1;
                Attempt {
                    ok: false,
                    output: "==> Verifying source file signatures with gpg...\n    good.tar.gz ... FAILED (bad signature from public key ABC)\n".to_string(),
                }
            },
            0,
        );
        assert_eq!(calls, 2, "a cryptographic failure retries once");
        assert_eq!(report.result.reason, REASON_SIG_BAD);
        assert!(
            cache.join("good.tar.gz").exists(),
            "the payload verified its checksum, so it is not the suspect"
        );
        assert!(!cache.join("good.tar.gz.asc").exists());
        assert!(report.quarantined.contains(&"good.tar.gz.asc".to_string()));
        std::fs::remove_dir_all(&cache).ok();
    }

    #[test]
    fn quarantine_renames_to_gsa_bad_and_never_leaves_the_bad_name() {
        let cache = scratch("quarantine");
        std::fs::write(cache.join("bad.tar.gz"), b"corrupt").unwrap();
        std::fs::write(cache.join("bad.tar.gz.sig"), b"sig").unwrap();
        let outcome = quarantine_bad_files(&cache, &["bad.tar.gz".to_string()]);
        assert!(outcome.moved.contains(&"bad.tar.gz".to_string()));
        assert!(outcome.moved.contains(&"bad.tar.gz.sig".to_string()));
        assert!(outcome.errors.is_empty());
        assert!(
            !cache.join("bad.tar.gz").exists(),
            "bad file left at final name"
        );
        let renames: Vec<String> = std::fs::read_dir(&cache)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .filter(|n| n.contains(".gsa-bad-"))
            .collect();
        assert_eq!(renames.len(), 2, "quarantined names: {renames:?}");
        std::fs::remove_dir_all(&cache).ok();
    }

    #[test]
    fn quarantine_of_an_absent_file_is_a_no_op() {
        let cache = scratch("quarantine-absent");
        assert!(quarantine_file(&cache, "missing.tar.gz").unwrap().is_none());
        std::fs::remove_dir_all(&cache).ok();
    }

    #[test]
    fn quarantine_surfaces_rename_and_stat_io_errors() {
        // A regular file acting as `cache` returns ENOTDIR on `symlink_metadata(cache/x)`.
        let base = scratch("quarantine-io-err");
        let file_as_cache = base.join("not-a-dir");
        std::fs::write(&file_as_cache, "file").unwrap();
        let outcome = quarantine_bad_files(&file_as_cache, &["bad.tar.gz".to_string()]);
        assert!(outcome.moved.is_empty());
        assert!(
            !outcome.errors.is_empty(),
            "ENOTDIR quarantine failure must be reported loudly, not swallowed"
        );
        std::fs::remove_dir_all(&base).ok();
    }

    #[test]
    fn bad_cached_file_is_quarantined_and_retried_once_ok() {
        let cache = scratch("retry-ok");
        std::fs::write(cache.join("bad.tar.gz"), b"corrupt").unwrap();
        let mut calls = 0;
        let report = run_fetch_attempts(
            "pkg",
            Some(&cache),
            || {
                calls += 1;
                if calls == 1 {
                    Attempt {
                        ok: false,
                        output: "    bad.tar.gz ... FAILED\nERROR: One or more files did not pass the validity check!\n".to_string(),
                    }
                } else {
                    Attempt {
                        ok: true,
                        output: "    bad.tar.gz ... Passed\n".to_string(),
                    }
                }
            },
            0,
        );
        assert_eq!(calls, 2, "exactly one retry");
        assert_eq!(report.result.verdict, FetchVerdict::Ok);
        assert_eq!(report.result.reason, REASON_QUARANTINED_RETRY_OK);
        assert!(report.result.is_warning(), "a quarantine is loud");
        assert_eq!(report.quarantined, vec!["bad.tar.gz".to_string()]);
        assert!(!cache.join("bad.tar.gz").exists());
        std::fs::remove_dir_all(&cache).ok();
    }

    #[test]
    fn a_repeated_quarantine_failure_stops_after_one_retry_but_keeps_quarantining() {
        let cache = scratch("retry-fail");
        std::fs::write(cache.join("bad.tar.gz"), b"corrupt").unwrap();
        std::fs::write(cache.join("bad2.tar.gz"), b"corrupt").unwrap();
        let mut calls = 0;
        let report = run_fetch_attempts(
            "pkg",
            Some(&cache),
            || {
                calls += 1;
                let name = if calls == 1 {
                    "bad.tar.gz"
                } else {
                    "bad2.tar.gz"
                };
                Attempt {
                    ok: false,
                    output: format!("    {name} ... FAILED\nERROR: One or more files did not pass the validity check!\n"),
                }
            },
            0,
        );
        assert_eq!(calls, 2, "quarantine retries once (owner decision 4)");
        assert_eq!(report.result.verdict, FetchVerdict::Failed);
        assert_eq!(report.result.reason, REASON_VERIFY_FAILED);
        // Both bad files are out of the way — never left at their names.
        assert!(!cache.join("bad.tar.gz").exists());
        assert!(!cache.join("bad2.tar.gz").exists());
        std::fs::remove_dir_all(&cache).ok();
    }

    #[test]
    fn transport_failures_retry_then_report_fetch_failed() {
        let cache = scratch("transport");
        let mut calls = 0;
        let report = run_fetch_attempts(
            "pkg",
            Some(&cache),
            || {
                calls += 1;
                Attempt {
                    ok: false,
                    output: "curl: (56) unexpected eof\n".to_string(),
                }
            },
            0,
        );
        assert_eq!(
            calls, FETCH_ATTEMPTS as usize,
            "two attempts, 10 s apart (docs/plans/plan.md)"
        );
        assert_eq!(report.result.verdict, FetchVerdict::Failed);
        assert_eq!(report.result.reason, REASON_FETCH_FAILED);
        assert!(report.result.is_warning());
        std::fs::remove_dir_all(&cache).ok();
    }

    #[test]
    fn a_recovered_transport_retry_is_ok_retry_ok_and_still_warns() {
        let mut calls = 0;
        let report = run_fetch_attempts(
            "pkg",
            None,
            || {
                calls += 1;
                Attempt {
                    ok: calls > 1,
                    output: if calls > 1 {
                        "ok".to_string()
                    } else {
                        "curl: (35)\n".to_string()
                    },
                }
            },
            0,
        );
        assert_eq!(report.result.verdict, FetchVerdict::Ok);
        assert_eq!(report.result.reason, REASON_RETRY_OK);
        assert!(
            report.result.is_warning(),
            "a flaky host is loud (docs/plans/plan.md §3.1)"
        );
    }

    #[test]
    fn disk_floor_reports_free_space_and_gates() {
        let dir = scratch("floor");
        assert!(
            disk_free_gib(&dir).is_some(),
            "statvfs must answer on a real dir"
        );
        // A floor no filesystem can fail below (0 GiB) never blocks.
        std::env::set_var("_GSA_DISK_FLOOR_GIB", "0");
        assert!(disk_floor_ok(&dir));
        // A floor above any plausible free space pauses prefetch.
        std::env::set_var("_GSA_DISK_FLOOR_GIB", "1048576");
        assert!(!disk_floor_ok(&dir));
        std::env::remove_var("_GSA_DISK_FLOOR_GIB");
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn makepkg_verifysource_argv_never_weakens_verification() {
        // The invocation is a constant `["--verifysource"]`; the guard is
        // structural — assert the contract on the one builder.
        let att = makepkg_verifysource(Path::new("/nonexistent-recipe-dir"));
        assert!(!att.ok, "a missing recipe directory must fail");
        // No verification bypass exists in this module's surface.
        let source = include_str!("engine.rs");
        for forbidden in ["--skipchecksums", "--skippgpcheck", "--skipinteg"] {
            // The tokens appear only in this test and in comments naming
            // them as forbidden — never in a Command argv.
            let argv_lines: Vec<&str> = source
                .lines()
                .filter(|l| l.contains("cmd.arg") || l.contains("args("))
                .collect();
            for line in argv_lines {
                assert!(
                    !line.contains(forbidden),
                    "argv construction carries {forbidden}: {line}"
                );
            }
        }
    }

    #[test]
    fn verifysource_command_pins_the_c_locale_and_keeps_the_constant_argv() {
        // The failure prose `verify_failure` parses is
        // gettext-translated by makepkg; the spawn must pin it to C.
        let cmd = verifysource_command(Path::new("/nonexistent-recipe-dir"))
            .expect("a resolvable layout is the fixture's premise");
        assert!(
            cmd.get_envs().any(|(key, value)| {
                key == std::ffi::OsStr::new("LC_ALL") && value == Some(std::ffi::OsStr::new("C"))
            }),
            "makepkg --verifysource must pin LC_ALL=C so prose parsing is C-locale by construction"
        );
        let args: Vec<String> = cmd
            .get_args()
            .map(|a| a.to_string_lossy().into_owned())
            .collect();
        assert!(args.contains(&"--verifysource".to_string()));
        for forbidden in [
            "--skipchecksums",
            "--skippgpcheck",
            "--skipinteg",
            "-s",
            "-o",
            "--holdver",
        ] {
            assert!(
                !args.contains(&forbidden.to_string()),
                "argv carries {forbidden}"
            );
        }
    }

    #[test]
    fn fetch_job_argv_check_names_the_argument() {
        let mut err = Vec::new();
        assert_eq!(run_fetch_job(&[], &mut err), 2);
        assert_eq!(run_fetch_job(&["only-one".to_string()], &mut err), 2);
        assert_eq!(
            run_fetch_job(
                &["a".to_string(), "b".to_string(), "c".to_string()],
                &mut err
            ),
            2
        );
        assert_eq!(
            run_fetch_job(&["bad pkg".to_string(), "x".to_string()], &mut err),
            2
        );
        assert_eq!(
            run_fetch_job(&["pkg".to_string(), "bad\u{7}path".to_string()], &mut err),
            2
        );
        let text = String::from_utf8_lossy(&err);
        assert!(text.contains("gsa --fetch-job"), "{text}");
    }

    #[test]
    fn reason_vocabulary_is_kebab_and_own() {
        for reason in [
            REASON_OK,
            REASON_RETRY_OK,
            REASON_QUARANTINED_RETRY_OK,
            REASON_FETCH_FAILED,
            REASON_VERIFY_FAILED,
            REASON_EVAL_FAILED,
            REASON_VCS_ONLY,
            REASON_NOT_A_CANDIDATE,
            REASON_DISK_FLOOR,
            REASON_RESULT_LOST,
        ] {
            assert!(
                reason.chars().all(|c| c.is_ascii_lowercase() || c == '-'),
                "{reason} is not kebab"
            );
            // Never a lane-outcome vocabulary word (contract §F).
            assert!(
                !matches!(
                    reason,
                    "build-failed" | "install-failed" | "lane-lost" | "waits-on-failed"
                ),
                "{reason} collides with the lane vocabulary"
            );
        }
    }

    #[test]
    fn verifysource_command_absolutizes_srcdest_and_overrides_inherited_env() {
        struct EnvGuard {
            vars: Vec<(&'static str, Option<std::ffi::OsString>)>,
        }
        impl Drop for EnvGuard {
            fn drop(&mut self) {
                for (k, v) in self.vars.drain(..) {
                    match v {
                        Some(val) => std::env::set_var(k, val),
                        None => std::env::remove_var(k),
                    }
                }
            }
        }

        let dir = scratch("srcdest-env");
        let home = dir.join("home");
        std::fs::create_dir_all(&home).unwrap();
        let conf = dir.join("gsa.conf");
        std::fs::write(&conf, "srcdest = rel-fetch-src\n").unwrap();

        let _guard = EnvGuard {
            vars: vec![
                ("GSA_CONF", std::env::var_os("GSA_CONF")),
                ("HOME", std::env::var_os("HOME")),
                ("SRCDEST", std::env::var_os("SRCDEST")),
                ("GSA_BUILD_DIR", std::env::var_os("GSA_BUILD_DIR")),
            ],
        };
        std::env::set_var("HOME", &home);
        std::env::set_var("GSA_CONF", &conf);
        std::env::set_var("GSA_BUILD_DIR", dir.join("cache"));
        std::env::set_var("SRCDEST", "/tmp/inherited-fetch-leak");

        let cmd_set = verifysource_command(&dir).expect("layout resolves");
        std::fs::write(&conf, "# unset\n").unwrap();
        let cmd_home_default = verifysource_command(&dir).expect("layout resolves");
        drop(_guard);

        let expected = std::path::absolute("rel-fetch-src").unwrap();
        let src_val = cmd_set
            .get_envs()
            .find(|(k, _)| *k == std::ffi::OsStr::new("SRCDEST"))
            .and_then(|(_, v)| v.map(PathBuf::from));
        let lane_src_val = cmd_set
            .get_envs()
            .find(|(k, _)| *k == std::ffi::OsStr::new("GSA_LANE_SRCDEST"))
            .and_then(|(_, v)| v.map(PathBuf::from));
        assert_eq!(src_val.as_ref(), Some(&expected));
        assert_eq!(lane_src_val.as_ref(), Some(&expected));
        let default_src = cmd_home_default
            .get_envs()
            .find(|(k, _)| *k == std::ffi::OsStr::new("SRCDEST"))
            .and_then(|(_, v)| v.map(PathBuf::from));
        assert_eq!(
            default_src.as_ref(),
            Some(&std::path::absolute(home.join(".gsa-src")).unwrap())
        );
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn setup_error_fails_fast_without_transport_sleep_and_keeps_diagnostic() {
        let dir = scratch("setup-fail-fast");
        let recipe = dir.join("packages/git/demo");
        std::fs::create_dir_all(&recipe).unwrap();
        std::fs::create_dir_all(dir.join("config")).unwrap();
        std::fs::write(
            dir.join("config/topology.conf"),
            "demo|packages/git/demo|git|\n",
        )
        .unwrap();
        std::fs::write(dir.join("config/build-defaults.conf"), "").unwrap();
        std::fs::write(dir.join("config/abi-exclusions.conf"), "").unwrap();
        std::fs::write(
            recipe.join("PKGBUILD"),
            "pkgname=demo\npkgver=1\npkgrel=1\nsource=('https://example.invalid/a.tar.gz')\nsha256sums=('abc')\n",
        )
        .unwrap();
        // Force a setup failure inside verifysource_command (GSA_BUILD_DIR pointing to a regular file).
        let bad_build = dir.join("bad-build-file");
        std::fs::write(&bad_build, "not-a-dir").unwrap();
        let conf = dir.join("gsa.conf");
        std::fs::write(&conf, "# valid conf\n").unwrap();
        let saved_conf = std::env::var_os("GSA_CONF");
        let saved_build = std::env::var_os("GSA_BUILD_DIR");
        let saved_delay = std::env::var_os("_GSA_FETCH_RETRY_S");
        std::env::set_var("GSA_CONF", &conf);
        std::env::set_var("GSA_BUILD_DIR", &bad_build);
        std::env::set_var("_GSA_FETCH_RETRY_S", "0");

        let mut err = Vec::new();
        let result = fetch_recipe("demo", &dir, &mut err);

        match saved_conf {
            Some(v) => std::env::set_var("GSA_CONF", v),
            None => std::env::remove_var("GSA_CONF"),
        }
        match saved_build {
            Some(v) => std::env::set_var("GSA_BUILD_DIR", v),
            None => std::env::remove_var("GSA_BUILD_DIR"),
        }
        match saved_delay {
            Some(v) => std::env::set_var("_GSA_FETCH_RETRY_S", v),
            None => std::env::remove_var("_GSA_FETCH_RETRY_S"),
        }

        let text = String::from_utf8_lossy(&err);
        let attempt_count = text.matches("attempt ").count();
        assert_eq!(result.verdict, FetchVerdict::Failed);
        assert!(
            attempt_count <= 1,
            "permanent setup error must not retry as transport: {text}"
        );
        assert!(
            text.contains("cannot configure makepkg"),
            "setup diagnostic must be surfaced, got: {text}"
        );
        std::fs::remove_dir_all(&dir).ok();
    }
}
