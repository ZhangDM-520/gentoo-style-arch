//! Output modes: human (TTY default) vs machine (capture default).
//!
//! Owner decision 2026-10-23: the DEFAULT surface is human-easy-to-read (the
//! fish-era vocabulary: `✓ pkg (3m07s)`, icons, live dashboard); the concise
//! determinate surface moves into a machine mode whose every streamed line
//! carries an explicit level and direct-action shape:
//!
//! ```text
//! INFO lane-done pkg=ghostty-git status=succeeded rc=0 dur=237
//! WARNING lane-failed pkg=vtk status=failed rc=1 dur=2145 action=inspect-log log=/var/lib/gsa/logs/vtk.log
//! ```
//!
//! Row vocabularies (decision rows, plan/outcome rows, `format: 2` run
//! records) are the machine channel already and stay byte-stable in both
//! modes. Mode selection: `--machine` / `--human` force; otherwise stdout
//! being a TTY picks human (a capture is a machine — this also keeps
//! fixtures on stable output).

use std::io::IsTerminal;
use std::sync::OnceLock;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    Human,
    Machine,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Level {
    Info,
    Warning,
    Error,
}

impl Level {
    pub fn tag(self) -> &'static str {
        match self {
            Level::Info => "INFO",
            Level::Warning => "WARNING",
            Level::Error => "ERROR",
        }
    }
}

static MODE: OnceLock<Mode> = OnceLock::new();

/// Pin the mode once, at dispatch (an explicit `--machine`/`--human`).
pub fn set_mode(mode: Mode) {
    let _ = MODE.set(mode);
}

/// The active mode: the pinned value, else stdout's tty-ness.
pub fn mode() -> Mode {
    match MODE.get() {
        Some(m) => *m,
        None if std::io::stdout().is_terminal() => Mode::Human,
        None => Mode::Machine,
    }
}

pub fn is_human() -> bool {
    mode() == Mode::Human
}

/// One machine line: `LEVEL event k=v k=v …` — values are space-free by
/// construction (callers quote/squeeze anything free-form into `_`).
pub fn kv_line(level: Level, event: &str, pairs: &[(&str, String)]) -> String {
    let mut line = format!("{} {}", level.tag(), event);
    for (k, v) in pairs {
        line.push(' ');
        line.push_str(k);
        line.push('=');
        line.push_str(v);
    }
    line
}

/// Machine-mode free-form values: squeeze runs of whitespace to `_` so the
/// `k=v` grammar stays one-line and field-splittable.
pub fn squash(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join("_")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kv_grammar_is_level_event_pairs() {
        let line = kv_line(
            Level::Warning,
            "lane-failed",
            &[
                ("pkg", "vtk".to_string()),
                ("rc", "1".to_string()),
                ("action", squash("inspect log now")),
            ],
        );
        assert_eq!(
            line,
            "WARNING lane-failed pkg=vtk rc=1 action=inspect_log_now"
        );
    }

    #[test]
    fn level_tags_are_the_contract_vocabulary() {
        assert_eq!(Level::Info.tag(), "INFO");
        assert_eq!(Level::Warning.tag(), "WARNING");
        assert_eq!(Level::Error.tag(), "ERROR");
    }
}
