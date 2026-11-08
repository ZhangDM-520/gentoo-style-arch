//! The live run view (contract §L.5): what a human watches during a run.
//!
//! Three shapes, one state machine (the fish builder's `render_dashboard` /
//! `dashboard_tail_rows` / `sanitize_log_stream` /
//! `fit_dashboard_line` — tests/assets/build-all.fish):
//! * a TTY gets the redrawn progress box — progress header, one row per lane
//!   with three run-scoped log-tail rows, spinner + last-event footer;
//! * a human-mode stream that is not an interactive terminal (TERM=dumb or
//!   unset) gets append-only event lines plus the 10 s `STATUS:` hint (the
//!   "is it stuck?" surface);
//! * the machine vocabulary passes through untouched — a machine stream is
//!   the leveled kv lines and gains nothing from the view.
//!
//! The tails are run-scoped through the lane-state markers
//! (`<run>/<pkg>.started`, gsa-sched): `logs/<pkg>.log` is appended across
//! runs, and the marker's `log-offset` is where this run's output starts.

use std::io::{IsTerminal, Write};
use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use gsa_model::RecipeId;
use gsa_sched::progress::Progress;
use gsa_sched::supervisor::SupEvent;

use crate::render::fmt_dur;

/// The dashboard gate (fish `_OUTPUT_INTERACTIVE`): stdout is a terminal and
/// `TERM` is set and is not `dumb`.
pub fn tty_enabled() -> bool {
    std::io::stdout().is_terminal()
        && std::env::var("TERM")
            .map(|term| !term.is_empty() && term != "dumb")
            .unwrap_or(false)
}

/// Strip terminal controls before log text reaches the box (fish
/// `sanitize_log_stream`): no ANSI CSI sequences, no `\r`, tabs become four
/// spaces, every other control byte goes.
fn sanitize(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut chars = line.chars().peekable();
    while let Some(ch) = chars.next() {
        match ch {
            '\x1b' => {
                // CSI: ESC '[' parameter/intermediate bytes, one final byte.
                if chars.peek() == Some(&'[') {
                    chars.next();
                    while let Some(&next) = chars.peek() {
                        chars.next();
                        if ('\x40'..='\x7e').contains(&next) {
                            break;
                        }
                    }
                }
            }
            '\r' => {}
            '\t' => out.push_str("    "),
            ch if (ch as u32) < 0x20 || ch == '\x7f' => {}
            ch => out.push(ch),
        }
    }
    out
}

/// Keep one cell unused so a terminal never enters its pending-wrap state
/// (fish `fit_dashboard_line`): truncate on character count with a `...`.
fn fit(text: &str, width: usize) -> String {
    let max = width.saturating_sub(1).max(1);
    if text.chars().count() <= max {
        return text.to_string();
    }
    if max <= 3 {
        return text.chars().take(max).collect();
    }
    let target = max - 3;
    let prefix: String = text.chars().take(target).collect();
    format!("{prefix}...")
}

/// The terminal width (fish `dashboard_width`): `tput cols`, then `COLUMNS`,
/// then 80 — floored at 20. Probed once per view (a mid-run resize refits on
/// the next run; recorded deviation in docs/gsa-contract.md §L).
fn probe_width() -> usize {
    let width = std::process::Command::new("tput")
        .arg("cols")
        .output()
        .ok()
        .and_then(|o| String::from_utf8_lossy(&o.stdout).trim().parse::<usize>().ok())
        .or_else(|| {
            std::env::var("COLUMNS")
                .ok()
                .and_then(|v| v.trim().parse::<usize>().ok())
        })
        .unwrap_or(80);
    width.max(20)
}

fn now_epoch() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// One lane slot's live state, filled from the supervisor's `Started` event
/// and its `<run>/<pkg>.started` marker.
struct Lane {
    pkg: Option<String>,
    epoch: u64,
    offset: u64,
}

/// The run view fed by the supervisor's event stream (plus its ~1s tick).
///
/// Every tally is a PROJECTION: the view folds the events into a
/// [`Progress`] — the same plan order and settled rows the run record renders
/// (§H one-record rule) — and reads its numbers from there. The view owned
/// its own counters until 2026-11-09 and drifted (`1/332` for a `--leaf`
/// run, 2026-11-03); a derived tally cannot disagree with the rows.
pub struct View {
    human: bool,
    interactive: bool,
    state_dir: PathBuf,
    progress: Progress,
    lanes: Vec<Lane>,
    stop_starting: bool,
    last_event: String,
    spinner: usize,
    rows_drawn: usize,
    box_active: bool,
    width: usize,
    last_status: u64,
}

const SPINNER_FRAMES: [char; 4] = ['-', '\\', '|', '/'];

impl View {
    /// `ids` is the run's carried node list in plan order (the `Started`
    /// index addresses it); `latent_ids` names the remediation latents, which
    /// stay out of the total until an activation dispatches them (§H `order`
    /// semantics — a `--leaf` run must never render `1/332`).
    pub fn new(
        human: bool,
        state_dir: PathBuf,
        ids: Vec<RecipeId>,
        lane_count: usize,
        latent_ids: Vec<RecipeId>,
    ) -> Self {
        let interactive = human && tty_enabled();
        View {
            human,
            interactive,
            state_dir,
            progress: Progress::new(ids, latent_ids),
            lanes: (0..lane_count.max(1))
                .map(|_| Lane {
                    pkg: None,
                    epoch: 0,
                    offset: 0,
                })
                .collect(),
            stop_starting: false,
            last_event: String::new(),
            spinner: 1,
            rows_drawn: 0,
            box_active: false,
            width: if interactive { probe_width() } else { 0 },
            // Fish starts the 10 s STATUS clock at run start: the first hint
            // is never immediate.
            last_status: now_epoch(),
        }
    }

    /// Feed one supervisor event; `line` is its rendered form (the human
    /// catalog line, or the machine kv line in machine mode — which simply
    /// passes through).
    pub fn handle(&mut self, event: &SupEvent, line: &str, out: &mut dyn Write) {
        // The projection folds EVERY event, in every output mode: the run's
        // tallies and the record must be the same structure whichever surface
        // renders them (a machine stream carries no box but the run still
        // settles against the record).
        self.progress.observe(event);
        if !self.human {
            let _ = write!(out, "{line}");
            return;
        }
        match event {
            SupEvent::Tick => {
                self.spinner = self.spinner % SPINNER_FRAMES.len() + 1;
            }
            SupEvent::Started { index, .. } => {
                let pkg = self
                    .progress
                    .pkg(*index)
                    .map(|id| id.as_str().to_string())
                    .unwrap_or_default();
                let (epoch, offset) = self.lane_state(&pkg);
                if let Some(lane) = self
                    .lanes
                    .iter_mut()
                    .find(|lane| lane.pkg.is_none())
                {
                    lane.pkg = Some(pkg);
                    lane.epoch = epoch;
                    lane.offset = offset;
                }
                self.last_event = line.trim_end().to_string();
            }
            SupEvent::Finished { row, .. } => {
                let pkg = row.pkg.as_str();
                for lane in self.lanes.iter_mut() {
                    if lane.pkg.as_deref() == Some(pkg) {
                        lane.pkg = None;
                        lane.epoch = 0;
                        lane.offset = 0;
                    }
                }
                self.last_event = line.trim_end().to_string();
            }
            SupEvent::Signal(_) | SupEvent::Teardown(_) => {
                self.stop_starting = true;
                self.last_event = line.trim_end().to_string();
            }
            _ => {
                self.last_event = line.trim_end().to_string();
            }
        }
        if self.interactive {
            self.redraw(out);
        } else {
            let _ = write!(out, "{line}");
            self.status_hint(out);
        }
    }

    /// The projection this view renders — the caller binds it to the run
    /// record after the run (`build.rs`): the dashboard is a view of the
    /// record, never a fourth derivation of the run's state.
    pub fn progress(&self) -> &Progress {
        &self.progress
    }

    /// Restore the terminal when the box is done (and before any other
    /// surface — the run record — prints).
    pub fn finish(&mut self, out: &mut dyn Write) {
        if self.box_active {
            let _ = write!(out, "\x1b[?25h");
            self.box_active = false;
            self.rows_drawn = 0;
        }
    }

    /// The lane's start epoch and log offset from its `<run>/<pkg>.started`
    /// marker (written before the `Started` event renders); a missing marker
    /// degrades to "no output yet" tails and a now-epoch, loudly noted by
    /// the supervisor at the write.
    fn lane_state(&self, pkg: &str) -> (u64, u64) {
        let path = self
            .state_dir
            .join("runs")
            .join(&self.current_run())
            .join(format!("{pkg}.started"));
        let text = std::fs::read_to_string(path).unwrap_or_default();
        let mut epoch = now_epoch();
        let mut offset = 0;
        for field in text.split_whitespace() {
            if let Some(value) = field.strip_prefix("epoch=") {
                epoch = value.parse().unwrap_or(epoch);
            } else if let Some(value) = field.strip_prefix("log-offset=") {
                offset = value.parse().unwrap_or(0);
            }
        }
        (epoch, offset)
    }

    /// The run id `runs/current` names (the lane-state pointer).
    fn current_run(&self) -> String {
        std::fs::read_to_string(self.state_dir.join("runs").join("current"))
            .map(|text| text.trim().to_string())
            .unwrap_or_default()
    }

    fn busy(&self) -> usize {
        self.lanes.iter().filter(|lane| lane.pkg.is_some()).count()
    }

    /// The 10 s pipe hint (fish's dispatcher poll): named busy lanes with
    /// their elapsed time — the answer to "is it stuck?".
    fn status_hint(&mut self, out: &mut dyn Write) {
        if self.lanes.len() <= 1 || self.busy() <= 1 {
            return;
        }
        let now = now_epoch();
        if now.saturating_sub(self.last_status) < 10 {
            return;
        }
        let parts: Vec<String> = self
            .lanes
            .iter()
            .enumerate()
            .filter_map(|(i, lane)| {
                let pkg = lane.pkg.as_deref()?;
                let dur = fmt_dur(now.saturating_sub(lane.epoch) as i64);
                Some(format!("lane {}: {pkg} ({dur})", i + 1))
            })
            .collect();
        if parts.is_empty() {
            return;
        }
        let _ = writeln!(out, "  STATUS: {}", parts.join(" | "));
        self.last_status = now;
    }

    /// The box's rows (fish `render_dashboard`): progress header, one row per
    /// lane plus its three tail rows, spinner + last-event footer.
    fn rows_at(&self, now: u64) -> Vec<String> {
        let failed = self.progress.failed();
        let succeeded = self.progress.succeeded();
        let total = self.progress.total();
        let (state, icon) = if failed > 0 {
            ("FAILED", '✗')
        } else if self.stop_starting {
            ("STOPPING", '⚠')
        } else if succeeded == total && total > 0 {
            ("DONE", '✓')
        } else {
            ("RUNNING", '→')
        };
        let mut rows = vec![format!(
            "Progress: {}/{} started | {} done | {} failed | {icon} {state}",
            self.progress.dispatched(),
            total,
            succeeded,
            failed
        )];
        for (i, lane) in self.lanes.iter().enumerate() {
            match &lane.pkg {
                Some(pkg) => {
                    let dur = fmt_dur(now.saturating_sub(lane.epoch) as i64);
                    rows.push(format!(
                        "Lane {}: → RUNNING {pkg} {dur}",
                        i + 1
                    ));
                    rows.extend(self.tail_rows(Some((pkg.as_str(), lane.offset))));
                }
                None => {
                    rows.push(format!("Lane {}: · idle", i + 1));
                    rows.extend(self.tail_rows(None));
                }
            }
        }
        if !self.last_event.is_empty() {
            rows.push(format!(
                "{} Event: {}",
                SPINNER_FRAMES[self.spinner - 1],
                self.last_event
            ));
        }
        rows
    }

    /// The three run-scoped log-tail rows (fish `dashboard_tail_rows`).
    fn tail_rows(&self, pkg: Option<(&str, u64)>) -> Vec<String> {
        let Some((pkg, offset)) = pkg else {
            return vec!["  · idle".to_string(); 3];
        };
        let log = gsa_model::log_path(&self.state_dir, pkg);
        let mut text = String::new();
        if let Ok(mut file) = std::fs::File::open(&log) {
            use std::io::{Read, Seek};
            let _ = file.seek(std::io::SeekFrom::Start(offset));
            let _ = file.read_to_string(&mut text);
        }
        let lines: Vec<String> = text.lines().map(sanitize).collect();
        let tail = &lines[lines.len().saturating_sub(3)..];
        let mut rows = Vec::with_capacity(3);
        for i in 0..3 {
            match tail.get(i).filter(|line| !line.is_empty()) {
                Some(line) => rows.push(format!("  > {line}")),
                None => rows.push("  · no output yet".to_string()),
            }
        }
        rows
    }

    fn redraw(&mut self, out: &mut dyn Write) {
        let rows = self.rows_at(now_epoch());
        if !self.box_active {
            let _ = write!(out, "\x1b[?25l");
        }
        if self.rows_drawn > 0 {
            let _ = write!(out, "\x1b[{}A", self.rows_drawn);
        }
        for row in &rows {
            let _ = write!(out, "\r\x1b[2K{}\n", fit(row, self.width));
        }
        // The row count is stable during a run, but clear any remainder.
        for _ in rows.len()..self.rows_drawn {
            let _ = write!(out, "\r\x1b[2K\n");
        }
        self.rows_drawn = rows.len();
        self.box_active = true;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gsa_model::{OutcomeRow, RowStatus};

    fn id(name: &str) -> RecipeId {
        RecipeId::new(name).expect("test id")
    }

    fn started(index: usize) -> SupEvent {
        SupEvent::Started {
            index,
            jobs: 1,
            core: false,
        }
    }

    fn settled(pkg: &str, status: RowStatus, rc: Option<i32>) -> SupEvent {
        SupEvent::Finished {
            index: 0,
            row: OutcomeRow {
                pkg: id(pkg),
                status,
                rc,
                dur: Some(1),
                reason: "test".to_string(),
            },
        }
    }

    #[test]
    fn sanitize_strips_terminal_controls() {
        assert_eq!(sanitize("a\x1b[1;32mb\x1b[0mc"), "abc");
        assert_eq!(sanitize("cr\rline"), "crline");
        assert_eq!(sanitize("tab\there"), "tab    here");
        assert_eq!(sanitize("bell\x07end"), "bellend");
    }

    #[test]
    fn fit_keeps_one_cell_and_truncates_with_ellipsis() {
        assert_eq!(fit("hello", 80), "hello");
        let long = "x".repeat(200);
        let fitted = fit(&long, 80);
        assert_eq!(fitted.chars().count(), 79, "one cell unused at 80 cols: {fitted:?}");
        assert!(fitted.ends_with("..."), "truncated rows say so: {fitted:?}");
        let fitted = fit(&long, 160);
        assert_eq!(fitted.chars().count(), 159, "one cell unused at 160 cols");
    }

    #[test]
    fn the_box_carries_progress_lanes_tails_and_event() {
        let state = std::env::temp_dir().join(format!("gsa-view-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&state);
        std::fs::create_dir_all(state.join("runs/42-1")).unwrap();
        std::fs::create_dir_all(state.join("logs")).unwrap();
        std::fs::write(state.join("runs/current"), "42-1\n").unwrap();
        // The offset is the run-scoped tail start: 13 bytes skipped.
        std::fs::write(state.join("runs/42-1/p1.started"), "pid=9 epoch=100 log-offset=13\n").unwrap();
        std::fs::write(state.join("logs/p1.log"), "old run line\nmake: up to date\ncc p1.c\n").unwrap();

        let mut view = View::new(
            true,
            state.clone(),
            vec![id("p1"), id("p2")],
            2,
            Vec::new(),
        );
        view.interactive = true;
        view.width = 80;
        let mut out = Vec::new();
        // p1 has been running 5s; p2 is done; one lane idles.
        view.handle(&started(0), "→ p1", &mut out);
        view.handle(&started(1), "→ p2", &mut out);
        view.handle(&settled("p2", RowStatus::Succeeded, Some(0)), "✓ p2 (1s)", &mut out);
        let rows = view.rows_at(105);
        assert_eq!(
            rows[0],
            "Progress: 2/2 started | 1 done | 0 failed | → RUNNING"
        );
        assert_eq!(rows[1], "Lane 1: → RUNNING p1 5s");
        // The tail is RUN-SCOPED: the pre-offset line never shows.
        assert_eq!(rows[2], "  > make: up to date");
        assert_eq!(rows[3], "  > cc p1.c");
        assert_eq!(rows[4], "  · no output yet");
        assert_eq!(rows[5], "Lane 2: · idle");
        assert_eq!(rows[6], "  · idle");
        assert_eq!(rows[9], "- Event: ✓ p2 (1s)");
        let _ = std::fs::remove_dir_all(&state);
    }

    #[test]
    fn a_latent_never_inflates_the_total_until_it_joins() {
        // 2026-11-03: a `--leaf` one-package install run rendered as
        // "1/332 started" — the box counted the never-activated remediation
        // latents up front. The total counts the run's own packages; an
        // activated latent joins at its dispatch (§H `order` semantics).
        let mut view = View::new(
            true,
            PathBuf::new(),
            vec![id("leaf"), id("rust-git"), id("core-x")],
            1,
            vec![id("rust-git"), id("core-x")],
        );
        view.interactive = true;
        view.width = 80;
        let mut out = Vec::new();
        // The selection's package runs while both latents stay parked.
        view.handle(&started(0), "-", &mut out);
        let rows = view.rows_at(0);
        assert_eq!(
            rows[0], "Progress: 1/1 started | 0 done | 0 failed | → RUNNING",
            "the latent pool must not inflate the total"
        );
        // Remediation activates the latents: each joins the total exactly
        // at its dispatch.
        for index in [1, 2] {
            view.handle(&started(index), "-", &mut out);
        }
        let rows = view.rows_at(0);
        assert_eq!(
            rows[0], "Progress: 3/3 started | 0 done | 0 failed | → RUNNING",
            "an activated latent joins the run's total"
        );
    }

    #[test]
    fn the_box_totals_are_the_projection() {
        // The tallies the box renders are DERIVED from the same order and
        // rows the run record renders (§H one-record rule) — the view keeps
        // no counter of its own to drift from them.
        let mut view = View::new(
            true,
            PathBuf::new(),
            vec![id("p1"), id("p2"), id("p3")],
            2,
            vec![id("p3")],
        );
        let mut out = Vec::new();
        assert_eq!(
            (
                view.progress().total(),
                view.progress().dispatched(),
                view.progress().succeeded(),
                view.progress().failed(),
            ),
            (2, 0, 0, 0),
            "the latent pool is not in the run's total"
        );
        view.handle(&started(0), "-", &mut out);
        view.handle(&started(1), "-", &mut out);
        view.handle(&settled("p1", RowStatus::Succeeded, Some(0)), "-", &mut out);
        view.handle(&settled("p2", RowStatus::Failed, Some(1)), "-", &mut out);
        assert_eq!(
            view.rows_at(0)[0],
            "Progress: 2/2 started | 1 done | 1 failed | ✗ FAILED"
        );
        view.handle(&started(2), "-", &mut out);
        assert_eq!(
            view.rows_at(0)[0],
            "Progress: 3/3 started | 1 done | 1 failed | ✗ FAILED",
            "an activated latent grows the total, never the settled counts"
        );
        // Derived: the counts ARE a fold over the settled rows, not fields.
        let rows = view.progress().rows();
        assert_eq!(
            view.progress().succeeded(),
            rows.iter().filter(|r| r.status == RowStatus::Succeeded).count()
        );
        assert_eq!(
            view.progress().failed(),
            rows.iter().filter(|r| r.status == RowStatus::Failed).count()
        );
    }

    #[test]
    fn failed_stops_the_header_first() {
        let ids = vec![id("p1"), id("p2"), id("p3")];
        let mut out = Vec::new();
        // One failure outranks the stop and the completion.
        let mut view = View::new(true, PathBuf::new(), ids.clone(), 1, Vec::new());
        for index in 0..3 {
            view.handle(&started(index), "-", &mut out);
        }
        view.handle(&settled("p1", RowStatus::Failed, Some(1)), "-", &mut out);
        view.stop_starting = true;
        assert!(view.rows_at(0)[0].ends_with("✗ FAILED"));

        // A clean run: dispatch stopped mid-way, then every lane landed.
        let mut view = View::new(true, PathBuf::new(), ids.clone(), 1, Vec::new());
        for index in 0..3 {
            view.handle(&started(index), "-", &mut out);
        }
        view.stop_starting = true;
        view.handle(&settled("p1", RowStatus::Succeeded, Some(0)), "-", &mut out);
        view.handle(&settled("p2", RowStatus::Succeeded, Some(0)), "-", &mut out);
        assert!(view.rows_at(0)[0].ends_with("⚠ STOPPING"));
        view.stop_starting = false;
        assert!(view.rows_at(0)[0].ends_with("→ RUNNING"));
        view.handle(&settled("p3", RowStatus::Succeeded, Some(0)), "-", &mut out);
        assert!(view.rows_at(0)[0].ends_with("✓ DONE"));
    }
}
