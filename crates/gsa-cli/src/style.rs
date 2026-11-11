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

/// True when `TERM` names a terminal that cannot do colour or cursor
/// control: unset, empty, `dumb`, or `unknown`.
///
/// `unknown` is what `sudo` substitutes for an UNSET `TERM` (`env -u TERM
/// sudo …` reports `TERM=unknown`), so a serial console or a `systemd-run`
/// session used to get the full colour ladder and the cursor-driving
/// dashboard on a terminal that implements neither, leaving a scrambled
/// screen after every frame (blind-review 2026-11-11, keyboard-accessibility).
pub fn term_is_dumb() -> bool {
    match std::env::var("TERM") {
        Ok(term) => term.is_empty() || term == "dumb" || term == "unknown",
        Err(_) => true,
    }
}

/// Resolve and pin the seam once, at dispatch, beside `output::set_mode`.
pub fn init(choice: ColorChoice) {
    let human = crate::output::is_human();
    let tty = std::io::stdout().is_terminal();
    let term_dumb = term_is_dumb();
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

/// One line of DATA (recipe metadata, a package description, an owned path)
/// with terminal control and line-breaking characters removed: ESC and the
/// other C0 controls are dropped (except TAB, which the wrappers turn into a
/// space), and CR/LF become a single space. Applied to VALUES only — never to
/// a rendered line, whose styling is our own escape sequences.
///
/// Without this, a `pkgdesc` carrying `ESC[31m` repainted the terminal and a
/// `CR` rewound the line — one line becoming two for every line-oriented
/// reader — and the same bytes reached `--machine`, the channel that must
/// never carry colour (blind review, 2026-11-11).
pub fn sanitize_data(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut last_space = false;
    let mut chars = text.chars().peekable();
    while let Some(ch) = chars.next() {
        match ch {
            // A whole escape SEQUENCE goes, not just the ESC byte: leaving
            // `[31m` behind is residue that reads as data.
            '\x1b' => match chars.next() {
                Some('[') => {
                    for next in chars.by_ref() {
                        if ('\x40'..='\x7e').contains(&next) {
                            break;
                        }
                    }
                }
                Some(_) | None => {}
            },
            '\t' | '\r' | '\n' => {
                if !last_space {
                    out.push(' ');
                    last_space = true;
                }
            }
            c if (c as u32) < 0x20 || c == '\x7f' => {}
            c => {
                out.push(c);
                last_space = c == ' ';
            }
        }
    }
    out.trim_end().to_string()
}

/// `paint` for a call site that is building a `String` anyway.
pub fn styled(role: Role, text: impl Into<String>) -> String {
    let text = text.into();
    paint(role, &text).into_owned()
}

/// The width of the terminal the user is READING (stdout's tty), in columns:
/// `$COLUMNS` first (the explicit override), then `stty` against the
/// controlling terminal.
///
/// `stty size` inherits fd 0, so a redirected stdin (`< /dev/null`, `xargs`,
/// `vim :!`) made every probe miss the real terminal and the layout fell back
/// to 80 columns — the table then soft-wrapped into two on a 40-column screen
/// (blind-review 2026-11-11, keyboard-accessibility). `tput cols` is not
/// consulted either: this app captures its own stdout, so tput cannot see a
/// terminal and answers its 80-column default.
pub fn terminal_width() -> Option<usize> {
    if let Ok(cols) = std::env::var("COLUMNS") {
        if let Ok(n) = cols.trim().parse::<usize>() {
            if n > 0 {
                return Some(n);
            }
        }
    }
    for device in ["/dev/tty", "/proc/self/fd/1"] {
        let Ok(out) = std::process::Command::new("stty")
            .arg("-F")
            .arg(device)
            .arg("size")
            .stderr(std::process::Stdio::null())
            .output()
        else {
            continue;
        };
        if !out.status.success() {
            continue;
        }
        if let Some(cols) = String::from_utf8_lossy(&out.stdout)
            .split_whitespace()
            .nth(1)
            .and_then(|cols| cols.parse::<usize>().ok())
            .filter(|cols| *cols > 0)
        {
            return Some(cols);
        }
    }
    None
}

/// The DISPLAY CELLS one character occupies: 0 for a combining mark, 2 for
/// an East Asian Wide/Fullwidth character, 1 otherwise.
///
/// Counting `chars()` budgeted every CJK glyph as one column, so a `-Qi`
/// description wrapped to 40 columns rendered 60–70 cells and overflowed
/// every terminal (blind-review 2026-11-11, keyboard-accessibility). The
/// ranges are the East Asian Width `W`/`F` classes plus the combining-mark
/// blocks; no dependency is pulled in for them.
fn cell_width(ch: char) -> usize {
    let cp = ch as u32;
    // Combining marks: the mark hangs off the previous cell.
    if (0x0300..=0x036F).contains(&cp)
        || (0x0483..=0x0489).contains(&cp)
        || (0x0591..=0x05BD).contains(&cp)
        || (0x0610..=0x061A).contains(&cp)
        || (0x064B..=0x065F).contains(&cp)
        || (0x1AB0..=0x1AFF).contains(&cp)
        || (0x1DC0..=0x1DFF).contains(&cp)
        || (0x20D0..=0x20FF).contains(&cp)
        || (0xFE20..=0xFE2F).contains(&cp)
    {
        return 0;
    }
    // East Asian Wide (W) and Fullwidth (F).
    if (0x1100..=0x115F).contains(&cp)
        || (0x2E80..=0x303E).contains(&cp)
        || (0x3041..=0x33FF).contains(&cp)
        || (0x3400..=0x4DBF).contains(&cp)
        || (0x4E00..=0x9FFF).contains(&cp)
        || (0xA000..=0xA4CF).contains(&cp)
        || (0xA960..=0xA97F).contains(&cp)
        || (0xAC00..=0xD7A3).contains(&cp)
        || (0xF900..=0xFAFF).contains(&cp)
        || (0xFE10..=0xFE19).contains(&cp)
        || (0xFE30..=0xFE6F).contains(&cp)
        || (0xFF00..=0xFF60).contains(&cp)
        || (0xFFE0..=0xFFE6).contains(&cp)
        || (0x1B000..=0x1B001).contains(&cp)
        || (0x1F200..=0x1F251).contains(&cp)
        || (0x1F300..=0x1F64F).contains(&cp)
        || (0x1F900..=0x1F9FF).contains(&cp)
        || (0x20000..=0x3FFFD).contains(&cp)
    {
        return 2;
    }
    1
}

/// Visible columns: escape sequences (CSI, and the two-byte `ESC x` forms a
/// terminal may echo) consume no width, and a wide glyph takes its real two
/// cells (see [`cell_width`]).
pub fn visible_width(text: &str) -> usize {
    let mut width = 0;
    let mut chars = text.chars();
    while let Some(ch) = chars.next() {
        if ch != '\x1b' {
            width += cell_width(ch);
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
        // A wide glyph that does not fit whole goes to the tail: half a
        // glyph is not a cell budget the terminal honours.
        if visible + cell_width(ch) > budget {
            return (head, text[offset..].to_string());
        }
        head.push(ch);
        visible += cell_width(ch);
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
        if visible + cell_width(ch) > budget {
            break;
        }
        out.push(ch);
        visible += cell_width(ch);
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
    fn a_wide_glyph_costs_two_cells_and_a_combining_mark_none() {
        // Counting chars overflowed every budget by 2x on CJK text.
        assert_eq!(visible_width("中文"), 4);
        assert_eq!(visible_width("ab中"), 4);
        assert_eq!(visible_width("e\u{0301}"), 1);
        // fit/pad budget in cells.
        assert!(visible_width(&fit("中文中文", 5)) <= 4);
        assert_eq!(pad("中", 3), "中 ");
        assert_eq!(pad_left("中", 3), " 中");
        // A split never keeps half a glyph.
        let (head, rest) = split_visible("文中中", 3);
        assert_eq!((head.as_str(), rest.as_str()), ("文", "中中"));
        assert_eq!(visible_width(&head), 2);
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
