//! Output cosmetics: the ONE colour seam (contract §L.5).
//!
//! Colour is a rendering decision, so it is made once, here, and every
//! renderer asks this module for a ROLE — never for an escape. A failed lane,
//! a failed `-Ma` row and a failed decision row all ask for `Role::Fail`, so
//! they cannot disagree, and a theme change is one table.
//!
//! Three rules hold the seam honest:
//!
//! * **The machine channel is never coloured.** `--machine`, or a captured
//!   stdout, disables the seam outright: the `format: 2` record, the kv lines
//!   and the decision rows are a stable interface, and an escape byte in them
//!   is a contract break, not a style choice. A call site cannot forget this,
//!   because `paint` consults the seam.
//! * **Colour is never the only signal.** Every state keeps the word and the
//!   glyph it always had (`✓ DONE`, `✗ FAILED`, `parked`, `deferred`); the
//!   colour is a second cue for a reader who has one.
//! * **No escape is counted as width.** [`fit`] and [`visible_width`] walk
//!   the string, keep escape sequences out of the budget, and close any
//!   colour they had to cut — a coloured dashboard row still fits the
//!   terminal (the `width - 1` rule in `dashboard::fit`).
//!
//! The ladder (first match wins): `--machine` disables; `--color=never`
//! disables; `--color=always` enables; `auto` (the default) enables when
//! stdout is a terminal, `TERM` is set and not `dumb`, and `NO_COLOR` is
//! unset or empty. One switch in each direction, and `NO_COLOR` is the
//! standard one, so an operator does not have to learn a second vocabulary.

use std::borrow::Cow;
use std::io::IsTerminal;
use std::sync::OnceLock;

/// `--color`'s three rungs (contract §B.8).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ColorChoice {
    Auto,
    Always,
    Never,
}

impl ColorChoice {
    pub fn parse(raw: &str) -> Option<ColorChoice> {
        match raw {
            "auto" => Some(ColorChoice::Auto),
            "always" => Some(ColorChoice::Always),
            "never" => Some(ColorChoice::Never),
            _ => None,
        }
    }

    /// The spellings a refusal names, in ladder order.
    pub const SPELLINGS: [&'static str; 3] = ["auto", "always", "never"];
}

/// What a piece of text IS. The renderer asks for the meaning; this module
/// owns the bytes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Role {
    /// A success: a done lane, a clean lint, an installed row.
    Ok,
    /// A failure: a failed lane, a fatal finding, a refused row.
    Fail,
    /// Attention without failure: a pending rebuild, a finding count, parked.
    Warn,
    /// A distinct-but-neutral class: deferred, a moved token.
    Accent,
    /// Secondary detail the eye should be able to skip.
    Dim,
    /// A heading or the one value on a line that matters.
    Bold,
    /// In-flight work (a running lane).
    Info,
}

impl Role {
    fn open(self) -> &'static str {
        match self {
            Role::Ok => "\x1b[32m",
            Role::Fail => "\x1b[1;31m",
            Role::Warn => "\x1b[33m",
            Role::Accent => "\x1b[35m",
            Role::Dim => "\x1b[2m",
            Role::Bold => "\x1b[1m",
            Role::Info => "\x1b[36m",
        }
    }
}

const RESET: &str = "\x1b[0m";

static ENABLED: OnceLock<bool> = OnceLock::new();

/// The ladder, as a pure function so the tests can walk every rung.
pub fn resolve(
    choice: ColorChoice,
    human: bool,
    tty: bool,
    term_dumb: bool,
    no_color: bool,
) -> bool {
    if !human {
        return false;
    }
    match choice {
        ColorChoice::Never => false,
        ColorChoice::Always => true,
        ColorChoice::Auto => tty && !term_dumb && !no_color,
    }
}

/// Resolve and pin the seam once, at dispatch, beside `output::set_mode`.
pub fn init(choice: ColorChoice) {
    let human = crate::output::is_human();
    let tty = std::io::stdout().is_terminal();
    let term_dumb = std::env::var("TERM")
        .map(|term| term.is_empty() || term == "dumb")
        .unwrap_or(true);
    let no_color = std::env::var_os("NO_COLOR")
        .map(|value| !value.is_empty())
        .unwrap_or(false);
    let _ = ENABLED.set(resolve(choice, human, tty, term_dumb, no_color));
}

/// True when this rendering may colour. Unresolved (a unit test, a hidden
/// seam that never called `init`) means OFF: a renderer that forgot to
/// initialise gets plain text, not escapes in a capture.
pub fn enabled() -> bool {
    ENABLED.get().copied().unwrap_or(false)
}

/// Paint `text` in `role`'s colour, or return it untouched.
pub fn paint(role: Role, text: &str) -> Cow<'_, str> {
    if !enabled() || text.is_empty() {
        return Cow::Borrowed(text);
    }
    Cow::Owned(format!("{}{text}{RESET}", role.open()))
}

/// `paint` for a call site that is building a `String` anyway.
pub fn styled(role: Role, text: impl Into<String>) -> String {
    let text = text.into();
    paint(role, &text).into_owned()
}

/// Visible columns: escape sequences (CSI, and the two-byte `ESC x` forms a
/// terminal may echo) consume no width.
pub fn visible_width(text: &str) -> usize {
    let mut width = 0;
    let mut chars = text.chars();
    while let Some(ch) = chars.next() {
        if ch != '\x1b' {
            width += 1;
            continue;
        }
        match chars.next() {
            Some('[') => {
                // CSI: parameters/intermediates, then one final byte.
                for next in chars.by_ref() {
                    if ('\x40'..='\x7e').contains(&next) {
                        break;
                    }
                }
            }
            // `ESC (` / `ESC )` take one more byte; any other is a two-byte
            // sequence. Either way it carries no visible column.
            Some('(') | Some(')') | Some('*') | Some('+') => {
                let _ = chars.next();
            }
            _ => {}
        }
    }
    width
}

/// Keep one cell unused (`width - 1`, the dashboard's rule) and truncate with
/// `...` on VISIBLE characters, closing any colour it had to cut. The escape
/// bytes it passes through are the caller's own styling, so a row painted
/// before fitting still fits.
pub fn fit(text: &str, width: usize) -> String {
    let max = width.saturating_sub(1).max(1);
    if visible_width(text) <= max {
        return text.to_string();
    }
    if max <= 3 {
        return truncate_visible(text, max, "");
    }
    truncate_visible(text, max - 3, "...")
}

/// Right-pad to `width` VISIBLE columns (escapes in `text` consume none), so
/// a cell painted before padding still lines up. Over-long text is NOT
/// truncated here — the column builder decides that with [`truncate_middle`].
pub fn pad(text: &str, width: usize) -> String {
    let visible = visible_width(text);
    let mut out = text.to_string();
    if width > visible {
        out.push_str(&" ".repeat(width - visible));
    }
    out
}

/// Truncate in the MIDDLE with `…`: the head and the tail both survive,
/// because a package id's ends are what a reader recognises
/// (`qemu-hw-display-virtio-gpu-…-rutabaga`). A string that already fits is
/// returned unchanged.
///
/// PLAIN text only: this counts characters, so paint the result, never the
/// input (a caller with a painted string would spend width on escapes).
pub fn truncate_middle(text: &str, width: usize) -> String {
    debug_assert!(
        !text.contains('\x1b'),
        "truncate_middle takes plain text; paint after truncating"
    );
    let chars: Vec<char> = text.chars().collect();
    // A string that already fits is unchanged — the cap counts the ellipsis
    // only for a string that must be cut.
    if chars.len() <= width {
        return text.to_string();
    }
    let Some(inner) = width.checked_sub(1) else {
        return String::new();
    };
    if inner == 0 {
        return "…".to_string();
    }
    let head = inner.div_ceil(2);
    let tail = inner - head;
    let mut out: String = chars[..head].iter().collect();
    out.push('…');
    out.extend(&chars[chars.len() - tail..]);
    out
}

/// Truncate the TAIL with `…`, keeping the head: a version reads front to
/// back, so a cut tail loses the least. PLAIN text only (see
/// [`truncate_middle`]).
pub fn truncate_end(text: &str, width: usize) -> String {
    debug_assert!(
        !text.contains('\x1b'),
        "truncate_end takes plain text; paint after truncating"
    );
    let chars: Vec<char> = text.chars().collect();
    if chars.len() <= width {
        return text.to_string();
    }
    let Some(inner) = width.checked_sub(1) else {
        return String::new();
    };
    let mut out: String = chars[..inner].iter().collect();
    out.push('…');
    out
}

/// Left-pad to `width` VISIBLE columns — the right-aligned cell (a count).
pub fn pad_left(text: &str, width: usize) -> String {
    let visible = visible_width(text);
    if width <= visible {
        return text.to_string();
    }
    let mut out = " ".repeat(width - visible);
    out.push_str(text);
    out
}

/// Split `text` after `budget` VISIBLE characters, escapes kept in the half
/// they belong to and never split. `("", text)` when the budget is zero.
pub fn split_visible(text: &str, budget: usize) -> (String, String) {
    let mut head = String::with_capacity(text.len());
    let mut visible = 0;
    let mut chars = text.char_indices();
    while let Some((offset, ch)) = chars.next() {
        if ch == '\x1b' {
            // Copy the whole sequence into the head, then keep scanning.
            head.push(ch);
            let mut next = chars.next();
            let mut escaped = String::new();
            if let Some((_, '[')) = next {
                escaped.push('[');
                for (_, byte) in chars.by_ref() {
                    escaped.push(byte);
                    if ('\x40'..='\x7e').contains(&byte) {
                        break;
                    }
                }
                head.push_str(&escaped);
                continue;
            }
            if let Some((_, byte)) = next.take() {
                head.push(byte);
                // `ESC (` / `ESC )` / `ESC *` / `ESC +` take one more byte,
                // exactly as `visible_width` counts them.
                if matches!(byte, '(' | ')' | '*' | '+') {
                    if let Some((_, extra)) = chars.next() {
                        head.push(extra);
                    }
                }
            }
            continue;
        }
        if visible == budget {
            return (head, text[offset..].to_string());
        }
        head.push(ch);
        visible += 1;
    }
    (head, String::new())
}

/// Copy `budget` visible characters, escapes included verbatim, then `tail`;
/// append a reset when any escape was emitted (the colour is cut).
fn truncate_visible(text: &str, budget: usize, tail: &str) -> String {
    let mut out = String::with_capacity(text.len().min(budget + 8));
    let mut visible = 0;
    let mut saw_escape = false;
    let mut chars = text.chars();
    while let Some(ch) = chars.next() {
        if ch == '\x1b' {
            saw_escape = true;
            out.push(ch);
            match chars.next() {
                Some('[') => {
                    out.push('[');
                    for next in chars.by_ref() {
                        out.push(next);
                        if ('\x40'..='\x7e').contains(&next) {
                            break;
                        }
                    }
                }
                Some(next) => out.push(next),
                None => break,
            }
            continue;
        }
        if visible == budget {
            break;
        }
        out.push(ch);
        visible += 1;
    }
    out.push_str(tail);
    if saw_escape {
        out.push_str(RESET);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_ladder_is_machine_then_never_then_always_then_auto() {
        // `--machine` (human = false) beats `--color=always`.
        assert!(!resolve(ColorChoice::Always, false, true, false, false));
        // `never` beats a terminal.
        assert!(!resolve(ColorChoice::Never, true, true, false, false));
        // `always` beats a pipe.
        assert!(resolve(ColorChoice::Always, true, false, true, true));
        // `auto` needs all three.
        assert!(resolve(ColorChoice::Auto, true, true, false, false));
        assert!(!resolve(ColorChoice::Auto, true, false, false, false));
        assert!(!resolve(ColorChoice::Auto, true, true, true, false));
        assert!(!resolve(ColorChoice::Auto, true, true, false, true));
    }

    #[test]
    fn an_unresolved_seam_paints_nothing() {
        // A renderer that never called `init` must not colour a capture.
        if ENABLED.get().is_none() {
            assert_eq!(paint(Role::Fail, "FAILED"), "FAILED");
            assert!(!enabled());
        }
    }

    #[test]
    fn width_ignores_escapes_and_fit_closes_a_cut_colour() {
        let red = "\x1b[1;31mFAILED-ROW\x1b[0m";
        assert_eq!(visible_width(red), 10);
        assert_eq!(visible_width("plain"), 5);
        assert_eq!(fit(red, 80), red);
        // A 10-column terminal keeps 9 visible columns: 6 for the head, 3
        // for the ellipsis.
        let cut = fit(red, 10);
        assert!(visible_width(&cut) <= 9, "{cut:?}");
        assert!(cut.ends_with(RESET), "a cut colour must be closed: {cut:?}");
        assert!(cut.contains("..."));
    }

    #[test]
    fn fit_reserves_one_cell_and_handles_tiny_widths() {
        assert_eq!(fit("abc", 10), "abc");
        assert_eq!(visible_width(&fit("abcdef", 2)), 1);
        // The ellipsis never pushes a row past the budget it was given.
        for width in 4..40 {
            let fitted = fit(&"x".repeat(200), width);
            assert!(
                visible_width(&fitted) < width,
                "width {width} produced {} columns",
                visible_width(&fitted)
            );
        }
    }

    #[test]
    fn truncate_end_keeps_the_head_and_pad_left_the_right_edge() {
        assert_eq!(truncate_end("0:1.0-1", 10), "0:1.0-1");
        assert_eq!(truncate_end("0:1.0.0_devel.232390-1", 10), "0:1.0.0_d…");
        assert_eq!(visible_width(&truncate_end("xxxxxxxxxxxxxxxx", 6)), 6);
        assert_eq!(pad_left("1", 4), "   1");
        assert_eq!(pad_left("12", 4), "  12");
        assert_eq!(pad_left("12345", 4), "12345");
    }

    #[test]
    fn split_visible_counts_columns_and_never_splits_an_escape() {
        let (head, tail) = split_visible(&"x".repeat(10), 4);
        assert_eq!((head.as_str(), tail.as_str()), ("xxxx", "xxxxxx"));
        let painted = "\x1b[2mabcdef\x1b[0m";
        let (head, tail) = split_visible(painted, 3);
        assert_eq!(visible_width(&head), 3);
        assert!(tail.ends_with('\x1b') || tail.contains("def"), "{tail:?}");
        assert_eq!(visible_width(&head) + visible_width(&tail), 6);
        // A zero budget splits before the first visible character; the
        // leading escape travels with the head it opens.
        let (head, tail) = split_visible(painted, 0);
        assert_eq!(visible_width(&head), 0);
        assert_eq!(format!("{head}{tail}"), painted);
    }

    #[test]
    fn roles_are_the_16_colour_vocabulary() {
        for role in [
            Role::Ok,
            Role::Fail,
            Role::Warn,
            Role::Accent,
            Role::Dim,
            Role::Bold,
            Role::Info,
        ] {
            let open = role.open();
            assert!(open.starts_with("\x1b["), "{role:?} is not an SGR sequence");
            assert!(open.ends_with('m'));
        }
    }
}
