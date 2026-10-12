//! The append-only JSONL line store all three side-car databases share.
//!
//! One file per store; every logical change is one JSON line appended whole.
//! Writes pass the write-time ownership gate (§J.5) before opening and
//! terminate a truncated tail first, so a later row never rides on the same
//! line as a partial one. Reads are corruption-tolerant (§J.5's failure
//! class): a line that does not parse — including a truncated final line
//! with no newline — is skipped and reported by name, and every row before
//! it is kept. That tolerance is the whole reason the format is plain
//! append-only JSONL rather than a database page file.

use std::io::Write;
use std::path::Path;

use serde::de::DeserializeOwned;
use serde::Serialize;

use crate::ownership::{ownership_gate, StateError};

/// One line a read could not use. `name` is derived leniently from the raw
/// line (the archive filename, recipe id, or key it looks like) so a health
/// report can name the offender instead of quoting bytes at the operator.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CorruptLine {
    pub store: String,
    /// 1-based line number in the store file.
    pub line: usize,
    /// The offender's best-effort name (empty when nothing can be derived).
    pub name: String,
    pub detail: String,
}

impl CorruptLine {
    /// The health-report row (contract §E.2-ish prose: kind name detail…).
    pub fn render(&self) -> String {
        let name = if self.name.is_empty() {
            format!("line-{}", self.line)
        } else {
            self.name.clone()
        };
        format!(
            "corrupt-row {} {} line {}: {}",
            self.store, name, self.line, self.detail
        )
    }
}

/// Derive a name from a raw line without parsing it: the first interesting
/// JSON string field wins (`archive` → file name, then `recipe_id`, `pkg`,
/// `key`). Best effort — an unnamed corrupt row is reported as `line-N`.
pub(crate) fn derive_name(line: &str) -> String {
    for field in ["archive", "recipe_id", "pkgbase", "pkg", "key", "name"] {
        let needle = format!("\"{field}\":\"");
        if let Some(pos) = line.find(&needle) {
            let rest = &line[pos + needle.len()..];
            if let Some(end) = rest.find('"') {
                let value = &rest[..end];
                if field == "archive" {
                    return value
                        .rsplit('/')
                        .next()
                        .filter(|s| !s.is_empty())
                        .unwrap_or(value)
                        .to_string();
                }
                return value.to_string();
            }
        }
    }
    String::new()
}

/// Append one JSON line to the store file: gate (§J.5), terminate a
/// truncated tail, then one `write(2)` of the complete line.
pub(crate) fn append_json<T: Serialize>(
    path: &Path,
    value: &T,
    err: &mut dyn Write,
) -> Result<(), StateError> {
    let line = serde_json::to_string(value)
        .map_err(|e| StateError::Io(format!("cannot serialize row for {}: {e}", path.display())))?;
    append_line(path, &line, err)
}

/// Append one already-serialized line (the fixture-visible seam keeps this
/// in `store` so every write site shares the gate and the tail repair).
pub(crate) fn append_line(path: &Path, line: &str, err: &mut dyn Write) -> Result<(), StateError> {
    ownership_gate(path, err)?;
    // A truncated tail (a prior write that died mid-line) must not swallow
    // this row: terminate it first so this row starts on its own line.
    let mut prefix = String::new();
    if let Ok(bytes) = std::fs::read(path) {
        if !bytes.is_empty() && *bytes.last().unwrap() != b'\n' {
            prefix.push('\n');
        }
    }
    let payload = format!("{prefix}{line}\n");
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|e| {
            StateError::Io(format!(
                "cannot open state file {} ({e}) — pass --state-dir PATH or set GSA_STATE_DIR",
                path.display()
            ))
        })?;
    file.write_all(payload.as_bytes()).map_err(|e| {
        StateError::Io(format!(
            "cannot append to state file {} ({e}) — pass --state-dir PATH or set GSA_STATE_DIR",
            path.display()
        ))
    })
}

/// The decoded result of one store read: usable rows plus every line that
/// could not be used (skipped, never fatal — corruption-tolerant reads).
pub struct StoreRead<T> {
    pub rows: Vec<T>,
    pub corrupt: Vec<CorruptLine>,
}

/// Read a JSONL store. A missing file is the empty store (a clean checkout
/// has no side-car history); an unterminated final line is a truncated tail
/// (reported, and the rows before it survive).
pub(crate) fn read_json<T: DeserializeOwned>(
    path: &Path,
    store: &str,
) -> Result<StoreRead<T>, StateError> {
    let mut out = StoreRead {
        rows: Vec::new(),
        corrupt: Vec::new(),
    };
    let bytes = match std::fs::read(path) {
        Ok(bytes) => bytes,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(out),
        Err(e) => {
            return Err(StateError::Io(format!(
                "cannot read state file {} ({e})",
                path.display()
            )))
        }
    };
    let text = String::from_utf8_lossy(&bytes);
    let mut lines: Vec<&str> = text.split('\n').collect();
    // The element after the last newline: empty when the file ends cleanly,
    // otherwise a truncated tail line (no terminator — never parseable).
    let tail = lines.pop().unwrap_or("");
    if !tail.is_empty() {
        out.corrupt.push(CorruptLine {
            store: store.to_string(),
            line: lines.len() + 1,
            name: derive_name(tail),
            detail: "truncated tail line (no terminator)".to_string(),
        });
    }
    for (idx, raw) in lines.iter().enumerate() {
        if raw.trim().is_empty() {
            continue;
        }
        match serde_json::from_str::<T>(raw) {
            Ok(row) => out.rows.push(row),
            Err(e) => out.corrupt.push(CorruptLine {
                store: store.to_string(),
                line: idx + 1,
                name: derive_name(raw),
                detail: e.to_string(),
            }),
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde::Deserialize;

    #[derive(Serialize, Deserialize, Debug, PartialEq)]
    struct Row {
        name: String,
        n: u32,
    }

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir =
            std::env::temp_dir().join(format!("gsa-state-store-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("store.jsonl")
    }

    #[test]
    fn round_trip_rows() {
        let path = scratch("roundtrip");
        let mut err = Vec::new();
        append_json(
            &path,
            &Row {
                name: "a".into(),
                n: 1,
            },
            &mut err,
        )
        .unwrap();
        append_json(
            &path,
            &Row {
                name: "b".into(),
                n: 2,
            },
            &mut err,
        )
        .unwrap();
        let read: StoreRead<Row> = read_json(&path, "test").unwrap();
        assert_eq!(read.rows.len(), 2);
        assert!(read.corrupt.is_empty());
    }

    #[test]
    fn a_truncated_tail_never_loses_the_rows_before_it() {
        let path = scratch("truncated");
        let mut err = Vec::new();
        append_json(
            &path,
            &Row {
                name: "a".into(),
                n: 1,
            },
            &mut err,
        )
        .unwrap();
        append_json(
            &path,
            &Row {
                name: "b".into(),
                n: 2,
            },
            &mut err,
        )
        .unwrap();
        // Truncate mid-line: the second row's line loses its tail bytes and
        // its newline.
        let bytes = std::fs::read(&path).unwrap();
        std::fs::write(&path, &bytes[..bytes.len() - 4]).unwrap();
        let read: StoreRead<Row> = read_json(&path, "test").unwrap();
        assert_eq!(
            read.rows,
            vec![Row {
                name: "a".into(),
                n: 1
            }],
            "every complete row before the truncation survives"
        );
        assert_eq!(read.corrupt.len(), 1);
        assert_eq!(
            read.corrupt[0].detail,
            "truncated tail line (no terminator)"
        );
        // The next write is not swallowed by the fragment: the store
        // terminates the tail first and the new row reads back cleanly.
        append_json(
            &path,
            &Row {
                name: "c".into(),
                n: 3,
            },
            &mut err,
        )
        .unwrap();
        let read: StoreRead<Row> = read_json(&path, "test").unwrap();
        assert_eq!(
            read.rows,
            vec![
                Row {
                    name: "a".into(),
                    n: 1
                },
                Row {
                    name: "c".into(),
                    n: 3
                }
            ]
        );
    }

    #[test]
    fn a_corrupt_line_is_named_and_skipped() {
        let path = scratch("corrupt");
        let mut err = Vec::new();
        append_json(
            &path,
            &Row {
                name: "a".into(),
                n: 1,
            },
            &mut err,
        )
        .unwrap();
        append_line(
            &path,
            r#"{"name":"bogus-1.0-1-any.pkg.tar.zst","n":2"#,
            &mut err,
        )
        .unwrap(); // truncated JSON, but newline-terminated
        append_json(
            &path,
            &Row {
                name: "c".into(),
                n: 3,
            },
            &mut err,
        )
        .unwrap();
        let read: StoreRead<Row> = read_json(&path, "test").unwrap();
        assert_eq!(read.rows.len(), 2);
        assert_eq!(read.corrupt.len(), 1);
        assert_eq!(read.corrupt[0].line, 2);
        assert_eq!(read.corrupt[0].name, "bogus-1.0-1-any.pkg.tar.zst");
        assert!(read.corrupt[0].render().contains("corrupt-row test"));
    }
}
