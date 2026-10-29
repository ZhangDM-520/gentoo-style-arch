//! TTY multi-select prompt for app-group members (contract §C.4).
//!
//! Port of the fish-era `prompt_app_selection`
//! (tests/assets/build-all.fish §app group multi-select prompt), same
//! semantics and strings — tests/app-group.sh §5-12 pin them byte-for-byte:
//!
//! - default state is all-unchecked: confirming with nothing checked builds
//!   EVERY member behind every row; confirming with rows checked builds only
//!   those rows' members;
//! - one line of whitespace-separated input per cycle: `N` toggles row N,
//!   `a` checks all, `c` clears all, an empty line confirms, `q` aborts;
//!   anything else re-renders with a notice;
//! - rows, not packages: members sharing an `app-cluster=<name>` tag render
//!   as ONE row labelled `name [member ids]` at the cluster's first member's
//!   position in build order, and toggling it toggles every member;
//! - the menu and notices go to the caller's error stream so a command
//!   substitution can never swallow them; only the chosen IDs travel the
//!   data channel.

use std::io::{BufRead, Write};

/// One toggle row of the menu.
pub struct AppRow {
    /// Singleton rows carry the package id; cluster rows carry
    /// `name [member ids]`.
    pub label: String,
    /// Every package behind the row, in build order.
    pub members: Vec<String>,
}

/// What the user confirmed.
pub enum PromptOutcome {
    /// Nothing was checked: build every member behind every row.
    All,
    /// Checked rows: the union of their members, in row order.
    Picked(Vec<String>),
    /// `q`, or the input stream closed before a confirm — carries the abort
    /// line as its reason; the caller prints it exactly once (the prompt
    /// never prints it, fish parity: one line, with the reason).
    Abort(&'static str),
}

/// Render the menu, read toggle lines until a confirm, and resolve the
/// checked rows to member ids. All rendering goes to `out` (the caller's
/// error stream).
pub fn prompt_app_selection(
    rows: &[AppRow],
    out: &mut dyn Write,
    input: &mut dyn BufRead,
) -> std::io::Result<PromptOutcome> {
    let total: usize = rows.iter().map(|row| row.members.len()).sum();
    let mut checked: Vec<usize> = Vec::new();
    loop {
        writeln!(out, "app group — choose what to build ({total} packages):")?;
        writeln!(out, "  default: nothing checked = build EVERY app package")?;
        for (i, row) in rows.iter().enumerate() {
            let mark = if checked.contains(&(i + 1)) { "[x]" } else { "[ ]" };
            writeln!(out, "  {mark} {:>2}. {}", i + 1, row.label)?;
        }
        if !checked.is_empty() {
            writeln!(
                out,
                "  {} checked — confirming now builds ONLY those",
                checked.len()
            )?;
        }
        writeln!(
            out,
            "numbers toggle (e.g. '1 3'), 'a' all, 'c' clear, Enter build, 'q' abort"
        )?;
        let mut line = String::new();
        if input.read_line(&mut line)? == 0 {
            return Ok(PromptOutcome::Abort("app selection aborted (input closed)"));
        }
        let tokens: Vec<&str> = line.split_whitespace().collect();
        if tokens.is_empty() {
            break;
        }
        let mut invalid = false;
        for token in tokens {
            match token {
                "q" | "quit" => {
                    return Ok(PromptOutcome::Abort("app selection aborted"));
                }
                "a" | "all" => checked = (1..=rows.len()).collect(),
                "c" | "clear" => checked.clear(),
                _ => match token.parse::<usize>() {
                    Ok(n) if n >= 1 && n <= rows.len() => {
                        if let Some(at) = checked.iter().position(|&r| r == n) {
                            checked.remove(at);
                        } else {
                            checked.push(n);
                            checked.sort_unstable();
                        }
                    }
                    _ => invalid = true,
                },
            }
        }
        if invalid {
            writeln!(out, " unrecognized token — use numbers, 'a', 'c' or 'q'")?;
        }
        writeln!(out)?;
    }
    if checked.is_empty() {
        return Ok(PromptOutcome::All);
    }
    let mut picked = Vec::new();
    for (i, row) in rows.iter().enumerate() {
        if checked.contains(&(i + 1)) {
            picked.extend(row.members.iter().cloned());
        }
    }
    Ok(PromptOutcome::Picked(picked))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    fn run(rows: &[AppRow], feed: &str) -> (PromptOutcome, String) {
        let mut out: Vec<u8> = Vec::new();
        let mut input = Cursor::new(feed.to_string());
        let outcome = prompt_app_selection(rows, &mut out, &mut input).unwrap();
        (outcome, String::from_utf8(out).unwrap())
    }

    fn rows() -> Vec<AppRow> {
        vec![
            AppRow { label: "app1".into(), members: vec!["app1".into()] },
            AppRow {
                label: "fcitx5 [app2 app3]".into(),
                members: vec!["app2".into(), "app3".into()],
            },
        ]
    }

    fn ids(outcome: PromptOutcome) -> Option<Vec<String>> {
        match outcome {
            PromptOutcome::All => None,
            PromptOutcome::Picked(v) => Some(v),
            PromptOutcome::Abort(reason) => panic!("aborted: {reason}"),
        }
    }

    // Prose rendering is pinned in exactly ONE place (§L.5):
    // tests/app-group.sh's PTY sections. These tests pin outcomes and
    // behaviours — except the invalid-token notice, which no fixture
    // scenario renders.
    #[test]
    fn empty_confirm_builds_everything() {
        let (outcome, _menu) = run(&rows(), "\n");
        assert!(ids(outcome).is_none());
    }

    #[test]
    fn toggle_selects_the_whole_cluster_row() {
        let (outcome, _menu) = run(&rows(), "2\n\n");
        assert_eq!(ids(outcome), Some(vec!["app2".into(), "app3".into()]));
    }

    #[test]
    fn tokens_toggle_clear_and_invalid_renders_notice() {
        let (outcome, menu) = run(&rows(), "1 a\nc\n1 1\nbogus\n1\n\n");
        // 1 toggled on, a checks all, c clears, 1 twice toggles on then off,
        // bogus re-renders without aborting, final 1 leaves row 1 checked.
        assert_eq!(ids(outcome), Some(vec!["app1".into()]));
        assert!(menu.contains(" unrecognized token — use numbers, 'a', 'c' or 'q'"));
    }

    #[test]
    fn q_aborts_with_reason() {
        let (outcome, _menu) = run(&rows(), "q\n");
        assert!(matches!(outcome, PromptOutcome::Abort("app selection aborted")));
    }

    #[test]
    fn closed_input_aborts_with_reason() {
        let (outcome, _menu) = run(&rows(), "");
        assert!(matches!(
            outcome,
            PromptOutcome::Abort("app selection aborted (input closed)")
        ));
    }
}
