//! The one exit renderer (contract §G.1): a step returns a typed [`Exit`],
//! and this module owns the mapping to the process rc and every line a gate
//! still owes. A step that refuses cannot invent a code — the class list is
//! closed, and the refusal record (§H.1) already carries the reason key when
//! one was emitted.
//!
//! - [`Exit::Usage`] is the §G.1 usage class (rc 2). Its message is carried
//!   EXACTLY as the site printed it after the leading `gsa: `: the renderer
//!   writes `gsa: {message}\n`, so a multi-line message keeps its later
//!   lines verbatim.
//! - [`Exit::Refuse`] is the refusal class (rc 3). A [`RecordOwed::Yes`]
//!   refusal already rendered the prose summary + `format: 2` record +
//!   persisted history at the seam that refused, so the renderer prints
//!   nothing more — the record said it. A [`RecordOwed::No`] refusal owns its
//!   `note` lines (caller keeps any `gsa: ` prefix) because no record will.

use std::io::Write;

use crate::{RC_REFUSED, RC_USAGE};

/// The §G.1 exit a step returns: usage (rc 2) or refusal (rc 3).
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Exit {
    /// Usage class (§G.1 rc 2): the message after the leading `gsa: `.
    Usage(String),
    /// Refusal class (§G.1 rc 3) with its reason class and record state.
    Refuse(Refusal),
}

/// One refusal (§G.1 rc 3).
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Refusal {
    /// The reason class the refusal represents (§H.3's row vocabulary).
    pub(crate) class: RefusalClass,
    /// Whether a run record was already emitted for this refusal.
    pub(crate) record: RecordOwed,
    /// Lines still owed to stderr when no record was emitted; each is
    /// written verbatim (the caller includes any `gsa: ` prefix).
    pub(crate) note: Vec<String>,
}

/// Whether the refusing seam already emitted the run record (§H.1).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RecordOwed {
    /// The emitting seam already wrote the prose summary + `format: 2`
    /// record + persisted history (the build family).
    Yes,
    /// No run existed (privilege/usage-shaped gates).
    No,
}

/// The refusal classes that appear as exit reasons today. The key is the
/// §H.3 reason string the run record's rows carry — never a new spelling.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum RefusalClass {
    StartupRefused,
    SyncRefused,
    IntegrityStop,
    AnchorRefused,
    AbiConsumerUncovered,
    PreflightRefused,
}

impl RefusalClass {
    pub(crate) fn key(self) -> &'static str {
        match self {
            RefusalClass::StartupRefused => "startup-refused",
            RefusalClass::SyncRefused => "sync-refused",
            RefusalClass::IntegrityStop => "integrity-stop",
            RefusalClass::AnchorRefused => "anchor-refused",
            RefusalClass::AbiConsumerUncovered => "abi-consumer-uncovered",
            RefusalClass::PreflightRefused => "preflight-refused",
        }
    }

    /// The class a §H.3 reason key names, if it is one this module knows.
    pub(crate) fn from_key(key: &str) -> Option<Self> {
        [
            RefusalClass::StartupRefused,
            RefusalClass::SyncRefused,
            RefusalClass::IntegrityStop,
            RefusalClass::AnchorRefused,
            RefusalClass::AbiConsumerUncovered,
            RefusalClass::PreflightRefused,
        ]
        .into_iter()
        .find(|class| class.key() == key)
    }
}

impl Refusal {
    /// A refusal whose seam already emitted the full run record.
    pub(crate) fn recorded(class: RefusalClass) -> Self {
        Self {
            class,
            record: RecordOwed::Yes,
            note: Vec::new(),
        }
    }

    /// A refusal that emitted no record and owes nothing beyond the rc.
    pub(crate) fn silent(class: RefusalClass) -> Self {
        Self {
            class,
            record: RecordOwed::No,
            note: Vec::new(),
        }
    }

    /// A refusal that emitted no record and still owes these lines.
    pub(crate) fn noted(class: RefusalClass, note: Vec<String>) -> Self {
        Self {
            class,
            record: RecordOwed::No,
            note,
        }
    }
}

impl Exit {
    /// The usage class for one site's message (after its `gsa: ` prefix).
    pub(crate) fn usage(message: impl Into<String>) -> Self {
        Exit::Usage(message.into())
    }

    /// A refusal that emitted no record and owes nothing beyond the rc.
    pub(crate) fn refuse(class: RefusalClass) -> Self {
        Exit::Refuse(Refusal::silent(class))
    }

    /// Write every line this exit still owes and return its §G.1 code.
    pub(crate) fn render(self, err: &mut dyn Write) -> i32 {
        match self {
            Exit::Usage(message) => {
                let _ = writeln!(err, "gsa: {message}");
                RC_USAGE
            }
            Exit::Refuse(Refusal {
                record: RecordOwed::Yes,
                ..
            }) => RC_REFUSED,
            Exit::Refuse(refusal) => {
                for line in &refusal.note {
                    let _ = writeln!(err, "{line}");
                }
                RC_REFUSED
            }
        }
    }
}

/// The ONE entry adapter every converted command uses: a computed run code
/// passes through, and a typed exit is rendered here.
pub(crate) fn render(result: Result<i32, Exit>, err: &mut dyn Write) -> i32 {
    match result {
        Ok(code) => code,
        Err(exit) => exit.render(err),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn capture(exit: Exit) -> (i32, String) {
        let mut err: Vec<u8> = Vec::new();
        let rc = exit.render(&mut err);
        (rc, String::from_utf8(err).expect("utf-8 stderr"))
    }

    #[test]
    fn usage_renders_the_prefixed_message_and_the_usage_code() {
        let (rc, err) = capture(Exit::Usage(
            "config/topology.conf: duplicate record 'glib2-git'".to_string(),
        ));
        assert_eq!(rc, 2);
        assert_eq!(
            err,
            "gsa: config/topology.conf: duplicate record 'glib2-git'\n"
        );
    }

    #[test]
    fn usage_keeps_a_multiline_message_verbatim() {
        let (rc, err) = capture(Exit::usage("first line\ngsa: second line"));
        assert_eq!(rc, 2);
        assert_eq!(err, "gsa: first line\ngsa: second line\n");
    }

    #[test]
    fn a_refusal_returns_the_refusal_code() {
        let (rc, err) = capture(Exit::refuse(RefusalClass::SyncRefused));
        assert_eq!(rc, 3);
        assert_eq!(err, "", "a recordless refusal owes only its rc");
    }

    #[test]
    fn a_recorded_refusal_prints_no_note() {
        // `record: Yes` means the seam already emitted the prose summary and
        // the `format: 2` block; printing the note again would double it.
        let exit = Exit::Refuse(Refusal {
            class: RefusalClass::AbiConsumerUncovered,
            record: RecordOwed::Yes,
            note: vec!["gsa: must not print (the record said it)".to_string()],
        });
        let (rc, err) = capture(exit);
        assert_eq!(rc, 3);
        assert_eq!(err, "");
    }

    #[test]
    fn a_recordless_refusal_writes_its_note_verbatim() {
        let exit = Exit::Refuse(Refusal::noted(
            RefusalClass::StartupRefused,
            vec!["gsa: first".to_string(), "second".to_string()],
        ));
        let (rc, err) = capture(exit);
        assert_eq!(rc, 3);
        assert_eq!(err, "gsa: first\nsecond\n");
    }

    #[test]
    fn class_keys_are_the_record_vocabulary() {
        for key in [
            "startup-refused",
            "sync-refused",
            "integrity-stop",
            "anchor-refused",
            "abi-consumer-uncovered",
            "preflight-refused",
        ] {
            let class = RefusalClass::from_key(key).expect("a known class key");
            assert_eq!(class.key(), key);
        }
        assert_eq!(RefusalClass::from_key("toolchain-identity"), None);
    }
}
