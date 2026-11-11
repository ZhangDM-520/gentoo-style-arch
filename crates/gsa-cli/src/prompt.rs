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

use std::io::{BufRead, IsTerminal, Write};

/// Is a prompt allowed to run? ONE decision for every prompt (the build
/// root, the `@app` filter): the question must be askable AND readable —
/// stdin and the stream the question is written to (stderr) are both
/// terminals — and no non-interactive signal may be set.
///
/// `--machine` asks for the machine vocabulary, never a dialogue; `CI`
/// marks an unattended run even when the runner allocated a pty
/// (`docker -t`, `ssh -t`, GitLab's `script`), which is the shape that used
/// to block forever on a question nobody could answer (blind-review
/// 2026-11-11, ci-fleet-operator and locale-terminal). `CI` follows the
/// convention: any non-empty value except `0`/`false` marks CI.
pub fn interactive(machine: bool) -> bool {
    if machine || ci_requested() {
        return false;
    }
    std::io::stdin().is_terminal() && std::io::stderr().is_terminal()
}

fn ci_requested() -> bool {
    match std::env::var("CI") {
        Ok(value) => {
            let value = value.trim().to_ascii_lowercase();
            !(value.is_empty() || value == "0" || value == "false")
        }
        Err(_) => false,
    }
}

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
    let mut notice: Option<&str> = None;
    let mut drawn = 0usize;
    loop {
        let mut frame: Vec<String> = Vec::new();
        frame.push(format!(
            "app group — choose what to build ({total} packages):"
        ));
        frame.push("  default: nothing checked = build EVERY app package".to_string());
        for (i, row) in rows.iter().enumerate() {
            let mark = if checked.contains(&(i + 1)) {
                "[x]"
            } else {
                "[ ]"
            };
            frame.push(format!("  {mark} {:>2}. {}", i + 1, row.label));
        }
        if !checked.is_empty() {
            frame.push(format!(
                "  {} checked — confirming now builds ONLY those",
                checked.len()
            ));
        }
        frame.push(
            "numbers toggle (e.g. '1 3'), 'a' all, 'c' clear, Enter build, 'q' abort".to_string(),
        );
        if let Some(line) = notice.take() {
            frame.push(line.to_string());
        }
        // The menu redraws IN PLACE (owner decision 2026-11-11): every
        // keystroke used to reprint the whole list, so a 60-row app group
        // buried the question it was asking. The dashboard's idiom
        // (`ESC[nA` up, `ESC[2K` clear) replaces the previous frame when the
        // terminal can take it; `TERM=dumb` keeps the old append behaviour.
        write_frame(out, &frame, &mut drawn, !crate::style::term_is_dumb())?;
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
            notice = Some(" unrecognized token — use numbers, 'a', 'c' or 'q'");
        }
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

/// One fitted prompt line (the same width rule as the menu).
fn emit(out: &mut dyn Write, line: &str) -> std::io::Result<()> {
    match crate::style::terminal_width() {
        Some(width) => writeln!(out, "{}", crate::style::truncate_end(line, width)),
        None => writeln!(out, "{line}"),
    }
}

/// Write one menu frame, erasing the previous one in place when the terminal
/// can take ANSI control. Lines are fitted to the terminal width so a long
/// cluster label never pushes the instruction line off-screen.
///
/// `ansi_ok` is the caller's terminal verdict (§L.9: `TERM` empty, `dumb` or
/// `unknown` cannot take cursor control). It is a parameter, not a second
/// read of `TERM`, so the append-only path is testable without mutating the
/// process environment.
fn write_frame(
    out: &mut dyn Write,
    frame: &[String],
    drawn: &mut usize,
    ansi_ok: bool,
) -> std::io::Result<()> {
    // The FIRST frame stays plain bytes: fixtures and captures read it as
    // data, and only a REDRAW needs control sequences.
    let control = *drawn > 0 && ansi_ok;
    if control {
        write!(out, "\x1b[{}A", *drawn)?;
    }
    let width = crate::style::terminal_width();
    for line in frame {
        let line = match width {
            Some(width) => crate::style::truncate_end(line, width),
            None => line.clone(),
        };
        if control {
            writeln!(out, "\x1b[2K{line}")?;
        } else {
            writeln!(out, "{line}")?;
        }
    }
    if *drawn > frame.len() && control {
        // Only a redrawing terminal needs the stale rows erased; an
        // append-only stream writes nothing extra (an unconditional
        // `ESC[2K` here put an escape byte on a `TERM=dumb` capture).
        for _ in 0..(*drawn - frame.len()) {
            writeln!(out, "\x1b[2K")?;
        }
        write!(out, "\x1b[{}A", *drawn - frame.len())?;
    }
    out.flush()?;
    *drawn = frame.len();
    Ok(())
}

/// What the build-dir prompt resolved to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BuildDirOutcome {
    /// Empty line: keep the root the layers resolved.
    Default,
    /// An operator-typed root, `~` expanded.
    Chosen(std::path::PathBuf),
    /// `q`, or the input stream closed before an answer — the caller prints
    /// the abort line (the prompt never does).
    Abort(&'static str),
}

/// Ask which build-cache root this run uses (contract §J.2). The current
/// resolution is shown WITH its provenance — an operator must be able to
/// tell a `gsa.conf` default from a stray `GSA_BUILD_DIR` before accepting
/// it. One line of input per cycle: Enter keeps the resolved root, an
/// absolute or `~/…` path replaces it for this run only, `q` aborts.
pub fn prompt_build_dir(
    default: &std::path::Path,
    source: &str,
    home: &std::path::Path,
    out: &mut dyn Write,
    input: &mut dyn BufRead,
) -> std::io::Result<BuildDirOutcome> {
    loop {
        for line in [
            "build directory (makepkg BUILDDIR/PKGDIR/PKGDEST live under it):".to_string(),
            format!("  current: {}  [{source}]", default.display()),
            "Enter keeps it, an absolute path (or ~/…) uses that root for this run, 'q' aborts"
                .to_string(),
        ] {
            emit(out, &line)?;
        }
        write!(out, "build dir> ")?;
        out.flush()?;
        let mut line = String::new();
        if input.read_line(&mut line)? == 0 {
            return Ok(BuildDirOutcome::Abort(
                "build-dir selection aborted (input closed)",
            ));
        }
        let answer = line.trim();
        if answer.is_empty() {
            return Ok(BuildDirOutcome::Default);
        }
        if answer == "q" || answer == "quit" {
            return Ok(BuildDirOutcome::Abort("build-dir selection aborted"));
        }
        let path = gsa_model::config::expand_home(answer, home);
        if !path.is_absolute() {
            writeln!(
                out,
                " not an absolute path: {} — give /path or ~/path",
                answer
            )?;
            writeln!(out)?;
            continue;
        }
        if path.exists() && !path.is_dir() {
            writeln!(out, " not a directory: {}", path.display())?;
            writeln!(out)?;
            continue;
        }
        return Ok(BuildDirOutcome::Chosen(path));
    }
}

/// The one destructive-verb confirmation (contract §B.7, owner decision
/// 2026-11-11): ask a single `y`/`N` question on the caller's error stream.
/// Anything other than `y`/`yes` — including EOF and an empty line — is NO,
/// so a stray Enter can never delete something.
pub fn confirm(
    out: &mut dyn Write,
    input: &mut dyn BufRead,
    question: &str,
) -> std::io::Result<bool> {
    write!(out, "{question} [y/N] ")?;
    out.flush()?;
    let mut line = String::new();
    if input.read_line(&mut line)? == 0 {
        return Ok(false);
    }
    Ok(matches!(
        line.trim().to_ascii_lowercase().as_str(),
        "y" | "yes"
    ))
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
            AppRow {
                label: "app1".into(),
                members: vec!["app1".into()],
            },
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
    fn a_redraw_never_writes_an_erase_to_an_append_only_terminal() {
        // A frame that SHRANK (a checked row cleared by `c`) used to emit a
        // bare `ESC[2K` per stale row even when the terminal cannot take
        // control — an escape byte in a `TERM=dumb` capture.
        let mut out: Vec<u8> = Vec::new();
        let mut drawn = 3usize;
        write_frame(&mut out, &["one".to_string()], &mut drawn, false).unwrap();
        let text = String::from_utf8(out).unwrap();
        assert!(
            !text.contains('\x1b'),
            "append-only terminal received an escape: {text:?}"
        );
        assert!(text.contains("one"));
        assert_eq!(drawn, 1);
    }

    #[test]
    fn a_redraw_erases_the_stale_rows_on_a_controlling_terminal() {
        let mut out: Vec<u8> = Vec::new();
        let mut drawn = 3usize;
        write_frame(&mut out, &["one".to_string()], &mut drawn, true).unwrap();
        let text = String::from_utf8(out).unwrap();
        assert_eq!(
            text.matches("\x1b[2K").count(),
            3,
            "one erase per new line plus one per stale row: {text:?}"
        );
        assert!(
            text.contains("\x1b[2A"),
            "the cursor returns to the frame: {text:?}"
        );
    }

    #[test]
    fn q_aborts_with_reason() {
        let (outcome, _menu) = run(&rows(), "q\n");
        assert!(matches!(
            outcome,
            PromptOutcome::Abort("app selection aborted")
        ));
    }

    #[test]
    fn closed_input_aborts_with_reason() {
        let (outcome, _menu) = run(&rows(), "");
        assert!(matches!(
            outcome,
            PromptOutcome::Abort("app selection aborted (input closed)")
        ));
    }

    fn run_dir(feed: &str) -> (BuildDirOutcome, String) {
        let mut out: Vec<u8> = Vec::new();
        let mut input = Cursor::new(feed.to_string());
        let outcome = prompt_build_dir(
            std::path::Path::new("/var/cache/gsa"),
            "gsa.conf build_dir",
            std::path::Path::new("/home/u"),
            &mut out,
            &mut input,
        )
        .unwrap();
        (outcome, String::from_utf8(out).unwrap())
    }

    #[test]
    fn empty_answer_keeps_the_resolved_root_and_shows_its_provenance() {
        let (outcome, menu) = run_dir("\n");
        assert_eq!(outcome, BuildDirOutcome::Default);
        assert!(
            menu.contains("/var/cache/gsa  [gsa.conf build_dir]"),
            "{menu}"
        );
    }

    #[test]
    fn typed_path_is_chosen_with_home_expanded() {
        let (outcome, _menu) = run_dir("~/tmp\n");
        assert_eq!(
            outcome,
            BuildDirOutcome::Chosen(std::path::PathBuf::from("/home/u/tmp"))
        );
    }

    #[test]
    fn relative_path_re_renders_instead_of_being_accepted() {
        let (outcome, menu) = run_dir("tmp\n/abs/tree\n");
        assert_eq!(
            outcome,
            BuildDirOutcome::Chosen(std::path::PathBuf::from("/abs/tree"))
        );
        assert!(menu.contains(" not an absolute path: tmp"), "{menu}");
    }

    #[test]
    fn q_and_closed_input_abort() {
        assert!(matches!(
            run_dir("q\n").0,
            BuildDirOutcome::Abort("build-dir selection aborted")
        ));
        assert!(matches!(
            run_dir("").0,
            BuildDirOutcome::Abort("build-dir selection aborted (input closed)")
        ));
    }

    fn ask(feed: &str) -> (bool, String) {
        let mut out: Vec<u8> = Vec::new();
        let mut input = Cursor::new(feed.to_string());
        let answer = confirm(&mut out, &mut input, "delete them?").unwrap();
        (answer, String::from_utf8(out).unwrap())
    }

    #[test]
    fn only_y_and_yes_consent() {
        assert!(ask("y\n").0);
        assert!(ask("YES\n").0);
        // Everything else is NO — a stray Enter or a closed stream never
        // deletes anything.
        for feed in ["n\n", "\n", "yess\n", "q\n", ""] {
            assert!(!ask(feed).0, "{feed:?} must not consent");
        }
        let (_, question) = ask("y\n");
        assert!(question.starts_with("delete them?"), "{question}");
        assert!(question.trim_end().ends_with("[y/N]"), "{question}");
    }
}
