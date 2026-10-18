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
//! the wall class plan.md §3.5 documents).
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
    REASON_OK, REASON_QUARANTINED_RETRY_OK, REASON_RETRY_OK, REASON_VERIFY_FAILED,
};

/// Transport attempts per recipe before the lane takes over (plan.md §2.3
/// `_PF_RETRY` = 2, 10 s apart).
pub const FETCH_ATTEMPTS: u32 = 2;
pub const FETCH_RETRY_DELAY_S: u64 = 10;

/// Pause prefetch below this much free space on the SRCDEST filesystem
/// (plan.md §2.3 `_PF_DISK_FREE_MIN_GIB` = 5 GiB, recorded in
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
pub fn find_root(start: &Path) -> Option<PathBuf> {
    let mut dir = start.to_path_buf();
    loop {
        if dir.join("config").join("topology.conf").is_file() {
            return Some(dir);
        }
        if !dir.pop() {
            return None;
        }
    }
}

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

/// makepkg's per-file failure report names the file whose pin failed
/// (`    <file> … FAILED` on stderr; checksums and PGP share the shape).
/// Used ONLY to attribute a quarantine — verification is makepkg's. The
/// match is C-locale by construction: [`verifysource_command`] pins
/// `LC_ALL=C`, so makepkg's gettext-translated `FAILED` token is English.
pub fn failing_files(output: &str) -> Vec<String> {
    let mut names = Vec::new();
    for line in output.lines() {
        let line = line.trim();
        if let Some((name, rest)) = line.split_once(" ... ") {
            if rest.starts_with("FAILED") && !name.is_empty() && !names.contains(&name.to_string())
            {
                names.push(name.to_string());
            }
        }
    }
    names
}

/// Was this failure a verification (integrity) failure rather than a
/// transport failure? makepkg's summary marker, used only to pick the
/// advisory reason key. C-locale by construction (`LC_ALL=C` at the spawn):
/// makepkg gettext-translates the summary prose.
pub fn is_verify_failure(output: &str) -> bool {
    output.contains("did not pass the validity check")
        || output.contains("Integrity checks")
        || !failing_files(output).is_empty()
}

/// One `makepkg --verifysource` attempt.
#[derive(Clone, Debug)]
pub struct Attempt {
    pub ok: bool,
    pub output: String,
}

/// Quarantine one cached file: rename `<name>` to `<name>.gsa-bad-<ts>` in
/// the shared source cache (owner decision 4). Returns the new path, or
/// `None` when the file is not in the cache (nothing to move — never a
/// recipe-directory move).
pub fn quarantine_file(cache: &Path, name: &str) -> Option<PathBuf> {
    let from = cache.join(name);
    if !from.is_file() {
        return None;
    }
    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let to = cache.join(format!("{name}.gsa-bad-{ts}"));
    std::fs::rename(&from, &to).ok().map(|_| to)
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

/// Quarantine the named files and their signature companions. Returns the
/// moved names (loud caller-side detail).
pub fn quarantine_bad_files(cache: &Path, names: &[String]) -> Vec<String> {
    let mut moved = Vec::new();
    for name in names {
        for candidate in std::iter::once(name.clone()).chain(signature_companions(name)) {
            if quarantine_file(cache, &candidate).is_some() {
                moved.push(candidate);
            }
        }
    }
    moved
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
/// Policy (plan.md §2.2/§2.3, owner decision 4):
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
    let start = Instant::now();
    let mut notes: Vec<String> = Vec::new();
    let mut quarantined: Vec<String> = Vec::new();
    let mut attempts = 0u32;
    let mut transport_retries = 0u32;
    let mut quarantine_retry_used = false;
    let mut hard_failure: Option<&'static str> = None;

    while attempts < 6 {
        attempts += 1;
        let att = attempt();
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

        let named = failing_files(&att.output);
        if named.is_empty() {
            // Transport-class failure: retry once more, 10 s apart (plan.md).
            if transport_retries < FETCH_ATTEMPTS.saturating_sub(1) {
                transport_retries += 1;
                if delay_s > 0 {
                    std::thread::sleep(std::time::Duration::from_secs(delay_s));
                }
                continue;
            }
            hard_failure = Some(REASON_FETCH_FAILED);
            break;
        }

        // Verification-class failure: quarantine the named files (never
        // leave a bad file at its final name) and retry once (owner
        // decision 4).
        match cache {
            Some(cache) => {
                let moved = quarantine_bad_files(cache, &named);
                if moved.is_empty() {
                    notes.push(format!(
                        "cannot quarantine {} (not in the shared source cache) — the wall stands until it is removed",
                        named.join(", ")
                    ));
                    hard_failure = Some(REASON_VERIFY_FAILED);
                    break;
                }
                notes.push(format!("quarantined {}", moved.join(", ")));
                quarantined.extend(moved);
            }
            None => {
                notes.push(format!(
                    "cannot quarantine {} — SRCDEST unresolvable, the shared source cache is unknown",
                    named.join(", ")
                ));
                hard_failure = Some(REASON_VERIFY_FAILED);
                break;
            }
        }
        if quarantine_retry_used {
            hard_failure = Some(REASON_VERIFY_FAILED);
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
pub(crate) fn verifysource_command(recipe_dir: &Path) -> Command {
    let mut cmd = gsa_model::privilege::build_command("makepkg");
    cmd.arg("--verifysource")
        .current_dir(recipe_dir)
        .env("GIT_CONFIG_COUNT", "0")
        .env("LC_ALL", "C");
    cmd
}

/// One real `makepkg --verifysource` attempt in the recipe directory
/// (contract §D.1 / owner decision 2). The makepkg child is a build-side
/// command (W1 privilege isolation): under a privileged run it runs as the
/// build user, like every other makepkg invocation.
pub fn makepkg_verifysource(recipe_dir: &Path) -> Attempt {
    let output = verifysource_command(recipe_dir).output();
    match output {
        Ok(output) => {
            let mut text = String::from_utf8_lossy(&output.stdout).into_owned();
            text.push_str(&String::from_utf8_lossy(&output.stderr));
            Attempt {
                ok: output.status.success(),
                output: text,
            }
        }
        Err(error) => Attempt {
            ok: false,
            output: format!("cannot run makepkg: {error}"),
        },
    }
}

/// Fetch-and-verify one recipe: candidacy first (never a grep, owner
/// decision 3), then the disk floor (owner decision 6), then the pipeline.
/// Never touches pacman or sudo; writes only the shared source cache.
pub fn fetch_recipe(pkg: &str, root: &Path, err: &mut dyn Write) -> FetchResult {
    let recipe_dir = match recipe_dir_for(pkg, root) {
        Ok(dir) => dir,
        Err(why) => {
            let _ = writeln!(err, "gsa-fetch: {pkg}: {why}");
            return FetchResult::new(pkg, FetchVerdict::Failed, 0, REASON_EVAL_FAILED)
                .expect("pkg is validated by the caller");
        }
    };
    let candidacy = match candidacy_for(pkg, root) {
        Ok(candidacy) => candidacy,
        Err(why) => {
            let _ = writeln!(err, "gsa-fetch: {pkg}: {why}");
            return FetchResult::new(pkg, FetchVerdict::Failed, 0, REASON_EVAL_FAILED)
                .expect("pkg is validated by the caller");
        }
    };
    if let Some(skip) = candidacy.skip_verdict(pkg) {
        let _ = writeln!(
            err,
            "gsa-fetch: {pkg}: skipped {} (nothing to fetch ahead)",
            skip.reason
        );
        return skip;
    }
    let cache = resolve_srcdest();
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
    let report = run_fetch_attempts(
        pkg,
        cache.as_deref(),
        || makepkg_verifysource(&recipe_dir),
        fetch_retry_delay_s(),
    );
    for note in &report.quarantined {
        let _ = writeln!(err, "gsa-fetch: {pkg}: quarantined {note} (retrying once)");
    }
    for note in &report.notes {
        let _ = writeln!(err, "gsa-fetch: {pkg}: {note}");
    }
    report.result
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
    let project = gsa_topo::load_project(root).map_err(|e| format!("configuration error: {e}"))?;
    let record = project
        .topology
        .get(pkg)
        .ok_or_else(|| format!("unknown recipe '{pkg}'"))?;
    let db = gsa_recipe::RecipeDb::load(root, std::slice::from_ref(record))
        .map_err(|e| format!("recipe metadata error: {e}"))?;
    let meta = db
        .get(pkg)
        .ok_or_else(|| format!("recipe metadata missing for '{pkg}'"))?;
    Ok(classify(&meta))
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
    if pkg.is_empty()
        || !pkg
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-' | '+'))
    {
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
            "gsa --fetch-job: cannot find config/topology.conf from the current directory upward — set `project` in gsa.conf, run inside the recipe repository, or fetch the store with `sudo gsa -Sy`"
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
    use crate::verdict::{REASON_NOT_A_CANDIDATE, REASON_RESULT_LOST, REASON_VCS_ONLY};

    fn scratch(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("gsa-fetch-engine-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn failing_files_are_attributed_from_makepkg_reports() {
        let output = "\
==> Validating source files with sha256sums...
    good-1.0.tar.gz ... Passed
    bad-1.0.tar.gz ... FAILED
    other-1.0.tar.gz ... Skipped
ERROR: One or more files did not pass the validity check!
";
        assert_eq!(failing_files(output), vec!["bad-1.0.tar.gz".to_string()]);
        // PGP failures share the shape and may carry a detail suffix.
        let pgp = "    signed.tar.gz ... FAILED (bad signature from public key ABC)\n";
        assert_eq!(failing_files(pgp), vec!["signed.tar.gz".to_string()]);
        assert!(failing_files("curl: (56) unexpected eof").is_empty());
    }

    #[test]
    fn quarantine_renames_to_gsa_bad_and_never_leaves_the_bad_name() {
        let cache = scratch("quarantine");
        std::fs::write(cache.join("bad.tar.gz"), b"corrupt").unwrap();
        std::fs::write(cache.join("bad.tar.gz.sig"), b"sig").unwrap();
        let moved = quarantine_bad_files(&cache, &["bad.tar.gz".to_string()]);
        assert!(moved.contains(&"bad.tar.gz".to_string()));
        assert!(moved.contains(&"bad.tar.gz.sig".to_string()));
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
        assert!(quarantine_file(&cache, "missing.tar.gz").is_none());
        std::fs::remove_dir_all(&cache).ok();
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
            "two attempts, 10 s apart (plan.md)"
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
            "a flaky host is loud (plan.md §3.1)"
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
        // The failure prose `failing_files`/`is_verify_failure` parse is
        // gettext-translated by makepkg; the spawn must pin it to C.
        let cmd = verifysource_command(Path::new("/nonexistent-recipe-dir"));
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
            assert!(!args.contains(&forbidden.to_string()), "argv carries {forbidden}");
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
}
