//! The lane-result codec (contract §F.2): the ONLY way a lane outcome crosses
//! the process boundary.
//!
//! Wire: `v2 <pkg> <code> <dur> <reason…>` — one line, typed on both sides.
//! A line that fails validation (unknown version tag, unknown code, control
//! characters, malformed fields) is rejected and mapped to `lost 125` with a
//! loud diagnostic naming the file — never silently accepted. Publication is
//! atomic: the producer writes `<result>.tmp.<pid>` and `rename(2)`s it into
//! place; readers ignore non-final names and a second publication in one
//! file is a reap anomaly (`lost`).

use gsa_model::LaneOutcome;
use std::fmt;
use std::path::Path;

/// The wire version tag (contract §F.2). `format: 2`'s codec prefix.
pub const WIRE_VERSION: &str = "v2";

/// One lane outcome on the wire.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct LaneResult {
    pub pkg: String,
    pub code: LaneOutcome,
    pub dur: u64,
    pub reason: String,
}

/// Why a line is not a valid result (contract §F.2: decoding fails closed).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum CodecError {
    /// The package id is empty or outside the topology id charset.
    BadPkg(String),
    /// The version tag is not `v2`.
    BadVersion(String),
    /// The code field is not a §F.1 lane code.
    BadCode(String),
    /// The duration field is not a non-negative integer.
    BadDur(String),
    /// The reason is empty or carries a control character.
    BadReason(String),
    /// The line carries a different package identity (another lane's or an
    /// orphan's result). Never this lane's outcome (fish R-F9 semantics).
    Foreign { expected: String, got: String },
    /// Structurally wrong: missing/extra fields, embedded newline, …
    Malformed(String),
    /// More than one published line in the final result file.
    MultiplePublications,
}

impl fmt::Display for CodecError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CodecError::BadPkg(s) => write!(f, "malformed package id '{s}'"),
            CodecError::BadVersion(s) => {
                write!(f, "unknown wire version '{s}' (want {WIRE_VERSION})")
            }
            CodecError::BadCode(s) => write!(f, "unknown lane code '{s}'"),
            CodecError::BadDur(s) => write!(f, "malformed duration '{s}'"),
            CodecError::BadReason(s) => write!(f, "malformed reason '{s}'"),
            CodecError::Foreign { expected, got } => {
                write!(f, "foreign result: expected '{expected}', got '{got}'")
            }
            CodecError::Malformed(s) => write!(f, "malformed result line: {s}"),
            CodecError::MultiplePublications => write!(f, "second publication in one result file"),
        }
    }
}

impl std::error::Error for CodecError {}

/// The topology id charset: the producer asserts it so a drifted identity can
/// never reach the wire and degrade a good build to `lost` (fish R-F29).
fn valid_pkg(s: &str) -> bool {
    !s.is_empty()
        && s.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-' | '+'))
}

fn has_control(s: &str) -> bool {
    s.chars().any(|c| c.is_control())
}

impl LaneResult {
    /// Validate-and-build: the typed constructor both sides go through.
    pub fn new(
        pkg: impl Into<String>,
        code: LaneOutcome,
        dur: u64,
        reason: impl Into<String>,
    ) -> Result<LaneResult, CodecError> {
        let result = LaneResult {
            pkg: pkg.into(),
            code,
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

    /// The wire line (contract §F.2).
    pub fn encode(&self) -> Result<String, CodecError> {
        self.check()?;
        Ok(format!(
            "{WIRE_VERSION} {} {} {} {}",
            self.pkg,
            self.code.code(),
            self.dur,
            self.reason
        ))
    }
}

/// Decode one wire line for the expected package. Fails closed on anything
/// shape-, code- or identity-wrong (contract §F.2.3).
pub fn decode(expected_pkg: &str, line: &str) -> Result<LaneResult, CodecError> {
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
    let code = fields
        .next()
        .ok_or_else(|| CodecError::Malformed("missing code".into()))?;
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
    let code_num: i32 = code
        .parse()
        .map_err(|_| CodecError::BadCode(code.to_string()))?;
    let code =
        LaneOutcome::from_code(code_num).ok_or_else(|| CodecError::BadCode(code.to_string()))?;
    let dur: u64 = dur
        .parse()
        .map_err(|_| CodecError::BadDur(dur.to_string()))?;
    if reason.is_empty() || has_control(reason) {
        return Err(CodecError::BadReason(reason.to_string()));
    }
    Ok(LaneResult {
        pkg: pkg.to_string(),
        code,
        dur,
        reason: reason.to_string(),
    })
}

/// Publish one result atomically (contract §F.2.2): temp name in the same
/// directory, `rename(2)` into place. A failure never leaves a final name.
pub fn publish(result_path: &Path, result: &LaneResult) -> Result<(), String> {
    let line = result
        .encode()
        .map_err(|e| format!("cannot encode lane result: {e}"))?;
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

/// Reap-time read of one final result file. Ignores non-final names (only the
/// final name is ever read); more than one line is a reap anomaly.
pub fn read_published(result_path: &Path, expected_pkg: &str) -> Result<LaneResult, CodecError> {
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

    fn ok() -> LaneResult {
        LaneResult::new("mesa-git", LaneOutcome::Ok, 12, "ok").unwrap()
    }

    #[test]
    fn round_trip_is_an_identity() {
        let reasons = [
            "ok",
            "build-failed",
            "source-unfetchable",
            "waits-on-deferred",
            "interrupted-mid-build",
            "cone-stop via gtk4-git",
        ];
        let codes = [
            LaneOutcome::Ok,
            LaneOutcome::Failed,
            LaneOutcome::Parked,
            LaneOutcome::Defer,
            LaneOutcome::Lost,
            LaneOutcome::Hup,
            LaneOutcome::Int,
            LaneOutcome::Term,
        ];
        for code in codes {
            for reason in reasons {
                let result = LaneResult::new("pkg-1.2_3+x", code, 4242, reason).unwrap();
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
    fn wire_shape_is_v2_pkg_code_dur_reason() {
        assert_eq!(ok().encode().unwrap(), "v2 mesa-git 0 12 ok");
    }

    #[test]
    fn foreign_lines_are_rejected_not_classified() {
        let line = "v2 other-pkg 0 12 ok";
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
            "v1 mesa-git 0 12 ok",                               // unknown version
            "v2 mesa-git 7 12 ok",                               // unknown code
            "v2 mesa-git 0 x12 ok",                              // bad duration
            "v2 mesa-git 0 12",                                  // missing reason
            "v2 mesa-git 0 12 ",                                 // empty reason
            "v2 mesa-git 0 12 ok\nv2 mesa-git 1 3 build-failed", // two lines
            "v2 bad|id 0 12 ok",                                 // malformed pkg
            "v2 mesa-git 0 12 ok\t",                             // control char
            "mesa-git 0 12 ok",                                  // missing version
            "",
        ] {
            assert!(decode("mesa-git", line).is_err(), "must reject: {line:?}");
        }
    }

    #[test]
    fn encode_rejects_drifted_identities_and_control_chars() {
        assert!(matches!(
            LaneResult::new("bad|id", LaneOutcome::Ok, 0, "ok"),
            Err(CodecError::BadPkg(_))
        ));
        assert!(matches!(
            LaneResult::new("pkg", LaneOutcome::Ok, 0, "re\u{7}ason"),
            Err(CodecError::BadReason(_))
        ));
        assert!(matches!(
            LaneResult::new("pkg", LaneOutcome::Ok, 0, ""),
            Err(CodecError::BadReason(_))
        ));
    }

    #[test]
    fn publish_is_atomic_and_the_reader_sees_one_final_line() {
        let dir = std::env::temp_dir().join(format!("gsa-codec-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("mesa-git.result");
        publish(&path, &ok()).unwrap();
        // The temp name is gone; only the final name exists.
        let entries: Vec<String> = std::fs::read_dir(&dir)
            .unwrap()
            .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
            .collect();
        assert_eq!(entries, vec!["mesa-git.result".to_string()]);
        assert_eq!(read_published(&path, "mesa-git").unwrap(), ok());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn second_publication_is_a_reap_anomaly() {
        let dir = std::env::temp_dir().join(format!("gsa-codec-test2-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("mesa-git.result");
        let mut content = ok().encode().unwrap();
        content.push('\n');
        content.push_str(&ok().encode().unwrap());
        content.push('\n');
        std::fs::write(&path, content).unwrap();
        assert_eq!(
            read_published(&path, "mesa-git").unwrap_err(),
            CodecError::MultiplePublications
        );
        std::fs::remove_dir_all(&dir).ok();
    }
}
