//! The fetch-verdict codec (contract §D.1, plan.md §3.4): the ONLY way a
//! fetch outcome crosses the process boundary.
//!
//! Wire: `v2 <pkg> <verdict> <dur> <reason…>` — one line, typed on both
//! sides, same discipline as the lane codec (`gsa-sched::codec`, §F.2) but
//! an OWN vocabulary: the verdict words are `ok|failed|skipped` and the
//! reasons are kebab keys — never `lane_outcome_*` codes. A line that fails
//! validation is rejected and mapped to a loud `failed result-lost`
//! advisory by the reader — never silently accepted. Publication is atomic:
//! the producer writes `<result>.tmp.<pid>` and `rename(2)`s it into place.

use std::fmt;
use std::path::Path;

/// The wire version tag (same family as the lane codec's `v2`, §F.2).
pub const WIRE_VERSION: &str = "v2";

/// The fetch verdict vocabulary (contract §D.1): `ok|failed|skipped`. Own
/// vocabulary on purpose — a fetch outcome is not a lane outcome (§F).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum FetchVerdict {
    /// Fetched and verified (checksums AND PGP, by makepkg).
    Ok,
    /// The fetch/verify pipeline failed. Advisory: never gates dispatch.
    Failed,
    /// Deliberately not fetched (`vcs-only`, `not-a-candidate`,
    /// `disk-floor`, …).
    Skipped,
}

impl FetchVerdict {
    pub fn as_str(self) -> &'static str {
        match self {
            FetchVerdict::Ok => "ok",
            FetchVerdict::Failed => "failed",
            FetchVerdict::Skipped => "skipped",
        }
    }

    pub fn from_str(s: &str) -> Option<FetchVerdict> {
        match s {
            "ok" => Some(FetchVerdict::Ok),
            "failed" => Some(FetchVerdict::Failed),
            "skipped" => Some(FetchVerdict::Skipped),
            _ => None,
        }
    }
}

impl fmt::Display for FetchVerdict {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

// The kebab reason vocabulary. Additive keys are allowed without a format
// bump (contract §L.2); these are the named ones.
pub const REASON_OK: &str = "ok";
/// The first fetch attempt failed and a retry recovered (still a warning:
/// the host misbehaved — plan.md §3.1).
pub const REASON_RETRY_OK: &str = "retry-ok";
/// A cached file failed its pin, was quarantined (`<name>.gsa-bad-<ts>`),
/// and the one retry re-fetched and verified it (owner decision 4).
pub const REASON_QUARANTINED_RETRY_OK: &str = "quarantined-retry-ok";
pub const REASON_FETCH_FAILED: &str = "fetch-failed";
pub const REASON_VERIFY_FAILED: &str = "verify-failed";
pub const REASON_EVAL_FAILED: &str = "eval-failed";
pub const REASON_VCS_ONLY: &str = "vcs-only";
pub const REASON_NOT_A_CANDIDATE: &str = "not-a-candidate";
pub const REASON_DISK_FLOOR: &str = "disk-floor";
/// The fetch child vanished without a usable result (reap anomaly).
pub const REASON_RESULT_LOST: &str = "result-lost";

/// Routine skips that are not warnings: expected, zero-risk, no operator
/// action wanted (`vcs-only` and `not-a-candidate` are the v1 classes).
pub fn is_routine_skip(reason: &str) -> bool {
    matches!(reason, REASON_VCS_ONLY | REASON_NOT_A_CANDIDATE)
}

/// Is this outcome warning-class? Everything that is not a clean `ok` and
/// not a routine skip — a failed attempt, a recovered-but-suspicious retry,
/// a quarantine, a disk-floor pause (owner decision 5: counted by the
/// `prefetch-warnings` scalar).
pub fn is_warning(verdict: FetchVerdict, reason: &str) -> bool {
    match verdict {
        FetchVerdict::Ok => reason != REASON_OK,
        FetchVerdict::Failed => true,
        FetchVerdict::Skipped => !is_routine_skip(reason),
    }
}

/// One fetch outcome on the wire.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct FetchResult {
    pub pkg: String,
    pub verdict: FetchVerdict,
    pub dur: u64,
    pub reason: String,
}

/// Why a line is not a valid fetch result (decoding fails closed, §F.2.3).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CodecError {
    BadPkg(String),
    BadVersion(String),
    BadVerdict(String),
    BadDur(String),
    BadReason(String),
    Foreign { expected: String, got: String },
    Malformed(String),
    MultiplePublications,
}

impl fmt::Display for CodecError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CodecError::BadPkg(s) => write!(f, "malformed package id '{s}'"),
            CodecError::BadVersion(s) => {
                write!(f, "unknown wire version '{s}' (want {WIRE_VERSION})")
            }
            CodecError::BadVerdict(s) => write!(f, "unknown fetch verdict '{s}'"),
            CodecError::BadDur(s) => write!(f, "malformed duration '{s}'"),
            CodecError::BadReason(s) => write!(f, "malformed reason '{s}'"),
            CodecError::Foreign { expected, got } => {
                write!(f, "foreign result: expected '{expected}', got '{got}'")
            }
            CodecError::Malformed(s) => write!(f, "malformed fetch result line: {s}"),
            CodecError::MultiplePublications => write!(f, "second publication in one result file"),
        }
    }
}

impl std::error::Error for CodecError {}

/// The topology id charset (a drifted identity must never reach the wire).
fn valid_pkg(s: &str) -> bool {
    !s.is_empty()
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-' | '+'))
}

fn has_control(s: &str) -> bool {
    s.chars().any(|c| c.is_control())
}

impl FetchResult {
    /// Validate-and-build: the typed constructor both sides go through.
    pub fn new(
        pkg: impl Into<String>,
        verdict: FetchVerdict,
        dur: u64,
        reason: impl Into<String>,
    ) -> Result<FetchResult, CodecError> {
        let result = FetchResult {
            pkg: pkg.into(),
            verdict,
            dur,
            reason: reason.into(),
        };
        result.check()?;
        Ok(result)
    }

    fn check(&self) -> Result<(), CodecError> {
        if !valid_pkg(&self.pkg) {
            return Err(CodecError::BadPkg(self.pkg.clone()));
        }
        if self.reason.is_empty() || has_control(&self.reason) {
            return Err(CodecError::BadReason(self.reason.clone()));
        }
        Ok(())
    }

    /// The wire line (same discipline as §F.2's lane row).
    pub fn encode(&self) -> Result<String, CodecError> {
        self.check()?;
        Ok(format!(
            "{WIRE_VERSION} {} {} {} {}",
            self.pkg,
            self.verdict.as_str(),
            self.dur,
            self.reason
        ))
    }

    /// Is this outcome a warning (owner decision 5)?
    pub fn is_warning(&self) -> bool {
        is_warning(self.verdict, &self.reason)
    }
}

/// Decode one wire line for the expected package. Fails closed on anything
/// shape-, verdict- or identity-wrong.
pub fn decode(expected_pkg: &str, line: &str) -> Result<FetchResult, CodecError> {
    let line = line.strip_suffix('\n').unwrap_or(line);
    let line = line.strip_suffix('\r').unwrap_or(line);
    if line.is_empty() {
        return Err(CodecError::Malformed("empty line".to_string()));
    }
    if has_control(line) {
        return Err(CodecError::Malformed(
            "control character in line".to_string(),
        ));
    }
    let mut fields = line.splitn(5, ' ');
    let version = fields.next().unwrap_or("");
    if version != WIRE_VERSION {
        return Err(CodecError::BadVersion(version.to_string()));
    }
    let pkg = fields
        .next()
        .ok_or_else(|| CodecError::Malformed("missing pkg".into()))?;
    let verdict = fields
        .next()
        .ok_or_else(|| CodecError::Malformed("missing verdict".into()))?;
    let dur = fields
        .next()
        .ok_or_else(|| CodecError::Malformed("missing duration".into()))?;
    let reason = fields
        .next()
        .ok_or_else(|| CodecError::Malformed("missing reason".into()))?;
    if !valid_pkg(pkg) {
        return Err(CodecError::BadPkg(pkg.to_string()));
    }
    if pkg != expected_pkg {
        return Err(CodecError::Foreign {
            expected: expected_pkg.to_string(),
            got: pkg.to_string(),
        });
    }
    let verdict = FetchVerdict::from_str(verdict)
        .ok_or_else(|| CodecError::BadVerdict(verdict.to_string()))?;
    let dur: u64 = dur
        .parse()
        .map_err(|_| CodecError::BadDur(dur.to_string()))?;
    if reason.is_empty() || has_control(reason) {
        return Err(CodecError::BadReason(reason.to_string()));
    }
    Ok(FetchResult {
        pkg: pkg.to_string(),
        verdict,
        dur,
        reason: reason.to_string(),
    })
}

/// Publish one result atomically (§F.2.2): temp name in the same directory,
/// `rename(2)` into place. A failure never leaves a final name.
pub fn publish(result_path: &Path, result: &FetchResult) -> Result<(), String> {
    let line = result
        .encode()
        .map_err(|e| format!("cannot encode fetch result: {e}"))?;
    let tmp = result_path.with_file_name(format!(
        "{}.tmp.{}",
        result_path
            .file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| "result".to_string()),
        std::process::id()
    ));
    std::fs::write(&tmp, format!("{line}\n")).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        format!("cannot write {}: {e}", tmp.display())
    })?;
    std::fs::rename(&tmp, result_path).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        format!("cannot publish {}: {e}", result_path.display())
    })?;
    Ok(())
}

/// Reap-time read of one final result file. Ignores non-final names; more
/// than one line is a reap anomaly.
pub fn read_published(result_path: &Path, expected_pkg: &str) -> Result<FetchResult, CodecError> {
    let content = std::fs::read_to_string(result_path).map_err(|e| {
        CodecError::Malformed(format!("cannot read {}: {e}", result_path.display()))
    })?;
    let lines: Vec<&str> = content.lines().filter(|l| !l.trim().is_empty()).collect();
    if lines.len() > 1 {
        return Err(CodecError::MultiplePublications);
    }
    let line = lines
        .first()
        .ok_or_else(|| CodecError::Malformed(format!("{} is empty", result_path.display())))?;
    decode(expected_pkg, line)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_is_an_identity() {
        let reasons = [
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
        ];
        for verdict in [
            FetchVerdict::Ok,
            FetchVerdict::Failed,
            FetchVerdict::Skipped,
        ] {
            for reason in reasons {
                let result = FetchResult::new("pkg-1.2_3+x", verdict, 4242, reason).unwrap();
                let line = result.encode().unwrap();
                assert_eq!(
                    decode("pkg-1.2_3+x", &line).unwrap(),
                    result,
                    "line: {line}"
                );
            }
        }
    }

    #[test]
    fn wire_shape_is_v2_pkg_verdict_dur_reason() {
        let result = FetchResult::new("mesa-git", FetchVerdict::Ok, 12, REASON_OK).unwrap();
        assert_eq!(result.encode().unwrap(), "v2 mesa-git ok 12 ok");
    }

    #[test]
    fn foreign_lines_are_rejected_not_classified() {
        let line = "v2 other-pkg ok 12 ok";
        match decode("mesa-git", line) {
            Err(CodecError::Foreign { expected, got }) => {
                assert_eq!(expected, "mesa-git");
                assert_eq!(got, "other-pkg");
            }
            other => panic!("expected Foreign, got {other:?}"),
        }
    }

    #[test]
    fn garbled_lines_fail_closed() {
        for line in [
            "v1 mesa-git ok 12 ok",                                    // unknown version
            "v2 mesa-git built 12 ok",                                 // lane code is not a verdict
            "v2 mesa-git 0 12 ok",                                     // lane code is not a verdict
            "v2 mesa-git ok x12 ok",                                   // bad duration
            "v2 mesa-git ok 12",                                       // missing reason
            "v2 mesa-git ok 12 ",                                      // empty reason
            "v2 mesa-git ok 12 ok\nv2 mesa-git failed 3 fetch-failed", // two lines
            "v2 bad|id ok 12 ok",                                      // malformed pkg
            "v2 mesa-git ok 12 ok\t",                                  // control char
            "mesa-git ok 12 ok",                                       // missing version
            "",
        ] {
            assert!(decode("mesa-git", line).is_err(), "must reject: {line:?}");
        }
    }

    #[test]
    fn warning_classification_matches_owner_decision_five() {
        assert!(!FetchResult::new("p", FetchVerdict::Ok, 0, REASON_OK)
            .unwrap()
            .is_warning());
        assert!(FetchResult::new("p", FetchVerdict::Ok, 0, REASON_RETRY_OK)
            .unwrap()
            .is_warning());
        assert!(
            FetchResult::new("p", FetchVerdict::Ok, 0, REASON_QUARANTINED_RETRY_OK)
                .unwrap()
                .is_warning()
        );
        assert!(
            FetchResult::new("p", FetchVerdict::Failed, 0, REASON_FETCH_FAILED)
                .unwrap()
                .is_warning()
        );
        // Routine skips are not warnings; a disk-floor pause is.
        assert!(
            !FetchResult::new("p", FetchVerdict::Skipped, 0, REASON_VCS_ONLY)
                .unwrap()
                .is_warning()
        );
        assert!(
            !FetchResult::new("p", FetchVerdict::Skipped, 0, REASON_NOT_A_CANDIDATE)
                .unwrap()
                .is_warning()
        );
        assert!(
            FetchResult::new("p", FetchVerdict::Skipped, 0, REASON_DISK_FLOOR)
                .unwrap()
                .is_warning()
        );
    }

    #[test]
    fn publish_is_atomic_and_the_reader_sees_one_final_line() {
        let dir = std::env::temp_dir().join(format!("gsa-fetch-codec-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("mesa-git.fetch.result");
        let result =
            FetchResult::new("mesa-git", FetchVerdict::Skipped, 1, REASON_VCS_ONLY).unwrap();
        publish(&path, &result).unwrap();
        let entries: Vec<String> = std::fs::read_dir(&dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(entries, vec!["mesa-git.fetch.result".to_string()]);
        assert_eq!(read_published(&path, "mesa-git").unwrap(), result);
        std::fs::remove_dir_all(&dir).ok();
    }
}
