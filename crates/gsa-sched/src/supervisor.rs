//! The lane supervisor (contract §K): event-driven dispatch over the state
//! machine, one process group per lane, atomic result publication consumed
//! through the codec, signal teardown, and loud `lost` mapping for anything
//! that does not decode.
//!
//! Readiness is event-driven: every lane is reaped by a waiter thread that
//! blocks in `wait(2)` and reports onto one channel; signal receipt and the
//! teardown grace window arrive on the same channel through the self-pipe.
//! There is no poll cycle (plan-native-pm.md §8: "the poll cycle dies by
//! construction").

use std::collections::HashMap;
use std::io::Write;
use std::os::unix::process::CommandExt;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::time::Duration;

use gsa_model::{OutcomeRow, RecipeId, RowStatus};

use crate::budget::Budget;
use crate::codec::{self, LaneResult};
use crate::machine::{Machine, Node, NodePhase, ParkRequest, Policy, Recorded};
use crate::signals::{self, install_handlers, signal_group, signal_lane_code, SIGKILL};
use gsa_fetch::candidacy::FetchCandidacy;
use gsa_fetch::child as fetch_child;
use gsa_fetch::engine;
use gsa_fetch::verdict::{self, FetchResult, FetchVerdict, REASON_RESULT_LOST};
use gsa_fetch::window::{PkgFetchState, PrefetchWindow};

/// One schedulable recipe as the supervisor sees it.
#[derive(Clone, Debug)]
pub struct SupNode {
    pub id: RecipeId,
    pub recipe_dir: PathBuf,
    pub core: bool,
    pub build_tools: bool,
    pub prereqs: Vec<usize>,
    pub consumers: Vec<usize>,
    pub batch: Option<usize>,
}

/// Everything a run needs (contract §K).
pub struct RunSetup {
    pub root: PathBuf,
    pub state_dir: PathBuf,
    pub run_id: String,
    /// The engine binary: lanes are `exec`'d `<exe> --lane-job …` supervisors,
    /// never an interpreter per lane (§K.1).
    pub exe: PathBuf,
    pub budget: Budget,
    pub policy: Policy,
    /// makepkg flags handed to every lane (`gsa --lane-job … <flags…>`).
    pub lane_flags: Vec<String>,
    pub nodes: Vec<SupNode>,
    /// Coupled batches (`abi=must`/`abi=should`), member indices per batch.
    pub batches: Vec<Vec<usize>>,
    /// The post-build install hook (install-before-dependents, rule 11):
    /// called with (package id, recipe directory) when a lane published `ok`,
    /// BEFORE its result reaches the machine — so consumers only compile
    /// after the install landed. Runs on the supervisor's single event loop,
    /// which is what makes "one `pacman -U` at a time" structural (§K.3).
    pub install: Option<Box<dyn FnMut(&str, &std::path::Path) -> InstallStep + Send>>,
    /// Fetch-ahead (contract §B.8 `--prefetch-ahead`/`--no-prefetch`, plan.md
    /// §2): `None` is `--no-prefetch`. Advisory by construction — a fetch
    /// outcome never reaches [`Machine`] and never changes a run-record row.
    pub prefetch: Option<PrefetchSetup>,
}

/// Prefetch-ahead configuration (owner decision 1/6): the lookahead window
/// over plan order, one fetch in flight at a time, niced/ionice'd children
/// running `gsa --fetch-job` (contract §D.1).
pub struct PrefetchSetup {
    /// `--prefetch-ahead N` (default 8).
    pub ahead: usize,
    /// Per-node fetch candidacy in plan order, computed by the CLI through
    /// `gsa-recipe` source classification (owner decision 3 — never grep).
    pub candidacy: Vec<FetchCandidacy>,
    /// The advisory log (`$STATE_DIR/prefetch.log`, owner decision 5):
    /// fetch children append their makepkg output here, run-scoped.
    pub log_path: PathBuf,
}

/// What the post-build install hook decided for one built package
/// (contract §B.4, §E, §G.1).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum InstallStep {
    /// The install decision stood (transaction ran or was skipped). The
    /// reason rides the outcome row: `ok`, `already-current`, …
    Done(String),
    /// Install failed or refused: the package records `failed 1 dur <reason>`
    /// and its consumer cone parks (normal failure path).
    ///
    /// A reason beginning with `install-refused` marks the refusal class
    /// (§G.1 rc 3) and is reported through [`SupOutcome::refused`];
    /// `stop_dispatch` halts new dispatch exactly once (the fail-fast stop).
    Halt { reason: String, stop_dispatch: bool },
}

/// Is this install-step reason a refusal (contract §G.1 rc 3)? The CLI maps
/// every `Decision::Refuse` row to a `Halt` whose reason starts here.
pub fn is_install_refusal(reason: &str) -> bool {
    reason.starts_with("install-refused")
}

/// Streaming dashboard events — the run record rows in motion. The dashboard
/// is a view of these; it never re-derives state (ADR 0003).
#[derive(Clone, Debug)]
pub enum SupEvent {
    Started {
        index: usize,
        jobs: u32,
        core: bool,
    },
    Finished {
        index: usize,
        row: OutcomeRow,
    },
    Parked {
        index: usize,
        reason: String,
    },
    Signal(i32),
    Teardown(&'static str),
    Diagnostic(String),
    /// One prefetch advisory (owner decision 5): loud at failure time,
    /// advisory — the lane will retry at build time. Never a run-record row.
    PrefetchWarning(String),
}

pub struct SupOutcome {
    pub rows: Vec<OutcomeRow>,
    pub interrupted: bool,
    /// The signal's lane-code-class number (129/130/143) when interrupted.
    pub signal_code: i32,
    /// A `Halt` reported a refusal (its reason starts `install-refused`);
    /// the caller feeds this to `RunOutcome::compute` so the run ends in the
    /// refusal class (§G.1 rc 3) instead of the failure class.
    pub refused: bool,
    /// Prefetch advisory records (owner decision 5): rendered in the prose
    /// summary and counted by the `prefetch-warnings` scalar. Never rows.
    pub prefetch_warnings: Vec<FetchResult>,
}

enum Event {
    LaneDone {
        index: usize,
        /// The signal that killed the lane child, when its exit status says
        /// so (`None`: it exited on its own, or wait(2) had no signal).
        killed_by: Option<i32>,
    },
    FetchDone {
        index: usize,
    },
    Signal(i32),
    GraceExpired,
}

struct ActiveLane {
    pid: u32,
    term_sent: bool,
}

/// The dispatcher-side prefetch driver (plan.md §2.1/§2.3): a lookahead
/// window over plan order, ONE fetch child in flight (single-flight), the
/// disk free-space floor, and the advisory records (owner decision 5).
/// Every fetch outcome is advisory: it warns and logs, and never reaches
/// the dispatch machine — a failed prefetch never gates dispatch and never
/// changes any package's outcome row (plan.md §3.1).
struct Prefetcher {
    window: PrefetchWindow,
    log_path: PathBuf,
    active: Option<ActiveFetch>,
    warnings: Vec<FetchResult>,
    paused: bool,
}

struct ActiveFetch {
    pid: u32,
    term_sent: bool,
}

impl Prefetcher {
    fn new(setup: &PrefetchSetup, node_count: usize) -> Prefetcher {
        let mut window = PrefetchWindow::new(node_count, setup.ahead);
        // Candidacy is decided before any spawn: a pure-VCS recipe is
        // `skipped vcs-only`, a recipe with nothing to fetch is
        // `skipped not-a-candidate` — such packages are NEVER prefetched
        // (owner decision 3).
        for (index, candidacy) in setup.candidacy.iter().enumerate().take(node_count) {
            if candidacy.skip_verdict("-").is_some() {
                window.set_state(index, PkgFetchState::Skipped);
            }
        }
        Prefetcher {
            window,
            log_path: setup.log_path.clone(),
            active: None,
            warnings: Vec::new(),
            paused: false,
        }
    }

    /// Sync the window with live dispatch state: started/finished/parked/
    /// deferred packages leave the window (plan.md §2.1).
    fn sync(&mut self, machine: &Machine) {
        for index in 0..machine.len() {
            match machine.node_phase(index) {
                NodePhase::Pending => {}
                NodePhase::Dispatched => self.window.set_state(index, PkgFetchState::Started),
                NodePhase::Settled(status) => {
                    let state = match status {
                        RowStatus::Parked => PkgFetchState::Parked,
                        RowStatus::Deferred => PkgFetchState::Deferred,
                        _ => PkgFetchState::Done,
                    };
                    self.window.set_state(index, state);
                }
            }
        }
    }

    /// Keep one fetch in flight: spawn the window's next candidate. The
    /// child is `gsa --fetch-job` in its own process group (§D.1), niced
    /// and ionice'd (owner decision 6), logging to `prefetch.log`.
    fn spawn_next(
        &mut self,
        setup: &RunSetup,
        run_dir: &std::path::Path,
    ) -> Option<(usize, std::process::Child)> {
        if self.active.is_some() {
            return None;
        }
        let index = self.window.next_to_fetch()?;
        let pkg = setup.nodes[index].id.as_str().to_string();
        let cache = engine::resolve_srcdest().unwrap_or_else(|| setup.root.clone());
        if !engine::disk_floor_ok(&cache) {
            // Below the free-space floor: pause prefetch with an advisory,
            // never fail (owner decision 6).
            if !self.paused {
                self.paused = true;
                let warning = FetchResult::new(
                    &pkg,
                    FetchVerdict::Skipped,
                    0,
                    gsa_fetch::verdict::REASON_DISK_FLOOR,
                )
                .expect("pkg id is typed");
                self.warnings.push(warning);
            }
            return None;
        }
        self.paused = false;
        let result_path = fetch_child::fetch_result_path(run_dir, &pkg);
        self.window.mark_spawned(index);
        match fetch_child::spawn(&setup.exe, &setup.root, &pkg, &result_path, &self.log_path) {
            Ok(child) => {
                self.active = Some(ActiveFetch {
                    pid: child.id(),
                    term_sent: false,
                });
                Some((index, child))
            }
            Err(error) => {
                self.window.mark_lost(index);
                self.warnings.push(
                    FetchResult::new(&pkg, FetchVerdict::Failed, 0, REASON_RESULT_LOST)
                        .expect("pkg id is typed"),
                );
                self.note(&format!(
                    "prefetch {pkg}: cannot spawn fetch child: {error}"
                ));
                None
            }
        }
    }

    /// Reap one finished fetch child: read its typed result (codec
    /// discipline, §F.2) and record the advisory if it is warning-class.
    /// An unreadable/absent result is a loud `result-lost` advisory.
    fn reap(
        &mut self,
        setup: &RunSetup,
        run_dir: &std::path::Path,
        index: usize,
    ) -> Option<FetchResult> {
        self.active = None;
        let pkg = setup.nodes[index].id.as_str().to_string();
        let result_path = fetch_child::fetch_result_path(run_dir, &pkg);
        let warning = match verdict::read_published(&result_path, &pkg) {
            Ok(result) => {
                self.window.mark_result(index, result.verdict);
                if result.is_warning() {
                    Some(result)
                } else {
                    None
                }
            }
            Err(error) => {
                self.note(&format!(
                    "prefetch result rejected for {pkg} ({}): {error}",
                    result_path.display()
                ));
                self.window.mark_lost(index);
                Some(
                    FetchResult::new(&pkg, FetchVerdict::Failed, 0, REASON_RESULT_LOST)
                        .expect("pkg id is typed"),
                )
            }
        };
        if let Some(w) = &warning {
            self.warnings.push(w.clone());
        }
        warning
    }

    /// One advisory line in `$STATE_DIR/prefetch.log` (owner decision 5).
    fn note(&self, line: &str) {
        if let Ok(mut log) = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.log_path)
        {
            use std::io::Write;
            let _ = writeln!(log, "gsa: {line}");
        }
    }

    /// Cancel the in-flight fetch silently (end of run or teardown): it is
    /// advisory work and never holds the run.
    fn cancel(&mut self) {
        if let Some(active) = self.active.take() {
            fetch_child::signal_group(active.pid, signals::SIGTERM);
            fetch_child::signal_group(active.pid, SIGKILL);
        }
    }

    /// One SIGTERM per fetch child, exactly once (§K.3).
    fn terminate(&mut self) {
        if let Some(active) = self.active.as_mut() {
            if !active.term_sent {
                fetch_child::signal_group(active.pid, signals::SIGTERM);
                active.term_sent = true;
            }
        }
    }

    /// The SIGKILL sweep for survivors (grace expiry / second signal).
    fn kill(&mut self) {
        if let Some(active) = self.active.as_ref() {
            fetch_child::signal_group(active.pid, SIGKILL);
        }
    }

    fn pid(&self) -> Option<u32> {
        self.active.as_ref().map(|a| a.pid)
    }
}

pub fn run_id_now() -> String {
    let epoch = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    format!("{epoch}-{}", std::process::id())
}

fn run_dir(setup: &RunSetup) -> PathBuf {
    setup.state_dir.join("runs").join(&setup.run_id)
}

fn result_path(setup: &RunSetup, index: usize) -> PathBuf {
    run_dir(setup).join(format!("{}.result", setup.nodes[index].id))
}

fn park_marker_path(setup: &RunSetup, index: usize) -> PathBuf {
    PathBuf::from(format!("{}.park", result_path(setup, index).display()))
}

/// Spawn one lane child: `exec`-style `<exe> --lane-job <pkg> <result>
/// <jobs> <flags…>` in its own process group (§K.1/K.3), output silenced —
/// the lane writes its own per-package log. The child handle is owned by a
/// waiter thread that blocks in `wait(2)` — readiness is delivered by the
/// kernel, never polled.
fn spawn_lane(setup: &RunSetup, index: usize, jobs: u32) -> Result<Child, String> {
    let node = &setup.nodes[index];
    let mut cmd = Command::new(&setup.exe);
    cmd.arg("--lane-job")
        .arg(node.id.as_str())
        .arg(result_path(setup, index))
        .arg(jobs.to_string())
        .args(&setup.lane_flags)
        .current_dir(&setup.root)
        .env("GSA_BUILD_JOBS", jobs.to_string())
        .env("GSA_STATE_DIR", &setup.state_dir)
        .env("GIT_CONFIG_COUNT", "0")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .process_group(0);
    cmd.spawn()
        .map_err(|e| format!("cannot spawn lane for {}: {e}", node.id))
}

fn reap_result(setup: &RunSetup, index: usize, err: &mut dyn Write) -> Option<LaneResult> {
    let node = &setup.nodes[index];
    let path = result_path(setup, index);
    match codec::read_published(&path, node.id.as_str()) {
        Ok(result) => Some(result),
        Err(error) => {
            let message = format!(
                "gsa: lane result rejected for {} ({}): {}",
                node.id,
                path.display(),
                error
            );
            let _ = writeln!(err, "{message}");
            None
        }
    }
}

/// The §F.1 lane class of a signal death cause: SIGHUP/SIGINT/SIGTERM kills
/// are attributable (129/130/143, §K.3) — any other death, a plain exit or
/// SIGKILL, carries no signal class and stays the `lost 125` reap anomaly.
fn signal_cause(killed_by: Option<i32>) -> Option<gsa_model::LaneOutcome> {
    use gsa_model::LaneOutcome;
    match killed_by {
        Some(signals::SIGHUP) => Some(LaneOutcome::Hup),
        Some(signals::SIGINT) => Some(LaneOutcome::Int),
        Some(signals::SIGTERM) => Some(LaneOutcome::Term),
        _ => None,
    }
}

fn write_park_markers(setup: &RunSetup, requests: &[ParkRequest]) {
    for request in requests {
        let path = park_marker_path(setup, request.index);
        let _ = std::fs::write(&path, format!("{}\n", request.reason));
    }
}

/// Run one build: dispatch lanes until the machine settles, applying the
/// failure policy (§I) and signal teardown (§K.3). `events` receives the
/// streaming dashboard view; `err` receives loud diagnostics (foreign or
/// garbled results always name their file, §F.2).
pub fn run(
    mut setup: RunSetup,
    events: &mut dyn FnMut(&SupEvent),
    err: &mut dyn Write,
) -> Result<SupOutcome, String> {
    std::fs::create_dir_all(run_dir(&setup))
        .map_err(|e| format!("cannot create run directory: {e}"))?;

    let nodes: Vec<Node> = setup
        .nodes
        .iter()
        .map(|n| Node {
            id: n.id.clone(),
            prereqs: n.prereqs.clone(),
            consumers: n.consumers.clone(),
            core: n.core,
            build_tools: n.build_tools,
            batch: n.batch,
        })
        .collect();
    let mut machine = Machine::new(
        nodes,
        setup.batches.clone(),
        setup.policy,
        setup.budget.lanes as usize,
    );
    // Fetch-ahead (plan.md §2.1): the dispatcher is the only brain — the
    // lookahead window is derived from live dispatch state every tick.
    let mut prefetch: Option<Prefetcher> = setup
        .prefetch
        .as_ref()
        .map(|cfg| Prefetcher::new(cfg, machine.len()));

    let (tx, rx): (Sender<Event>, Receiver<Event>) = mpsc::channel();
    let pipe = install_handlers().map_err(|e| format!("cannot install signal handlers: {e}"))?;
    {
        let tx = tx.clone();
        std::thread::spawn(move || {
            use std::io::Read;
            let mut read = pipe.read;
            let mut buf = [0u8; 64];
            loop {
                match read.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => {
                        for byte in &buf[..n] {
                            if tx.send(Event::Signal(*byte as i32)).is_err() {
                                return;
                            }
                        }
                    }
                }
            }
        });
    }

    let mut active: HashMap<usize, ActiveLane> = HashMap::new();
    let mut interrupted: Option<i32> = None;
    let mut grace_started = false;
    let mut refused = false;
    let mut dispatch_halted = false;
    let mut settle_deadline: Option<std::time::Instant> = None;

    'outer: loop {
        // Dispatch everything the machine allows right now.
        while interrupted.is_none() {
            let Some(index) = machine
                .pick()
                .into_iter()
                .find(|&i| machine.can_dispatch(i))
            else {
                break;
            };
            let jobs = if machine.node(index).core {
                setup.budget.core_jobs
            } else {
                setup.budget.normal_jobs
            };
            match spawn_lane(&setup, index, jobs) {
                Ok(mut child) => {
                    let pid = child.id();
                    machine.dispatch(index);
                    active.insert(
                        index,
                        ActiveLane {
                            pid,
                            term_sent: false,
                        },
                    );
                    events(&SupEvent::Started {
                        index,
                        jobs,
                        core: machine.node(index).core,
                    });
                    let waiter_tx = tx.clone();
                    let waiter_index = index;
                    std::thread::spawn(move || {
                        // Blocking reap (wait(2)): readiness is delivered by
                        // the kernel through the channel, never polled. The
                        // exit status carries the death cause — the only
                        // attribution for a lane that never published (§F.1).
                        let killed_by = child.wait().ok().and_then(|status| {
                            std::os::unix::process::ExitStatusExt::signal(&status)
                        });
                        let _ = waiter_tx.send(Event::LaneDone {
                            index: waiter_index,
                            killed_by,
                        });
                    });
                }
                Err(error) => {
                    machine.dispatch(index);
                    let _ = writeln!(err, "gsa: {error}");
                    let row = OutcomeRow {
                        pkg: machine.node(index).id.clone(),
                        status: RowStatus::Failed,
                        rc: Some(1),
                        dur: None,
                        reason: "build-failed".to_string(),
                    };
                    events(&SupEvent::Finished {
                        index,
                        row: row.clone(),
                    });
                    machine.record(
                        index,
                        Recorded {
                            code: gsa_model::LaneOutcome::Failed,
                            dur: None,
                            reason: "build-failed".to_string(),
                        },
                    );
                }
            }
        }

        // Fetch-ahead (plan.md §2.1): derive the lookahead window from live
        // dispatcher state and keep ONE fetch child in flight. Advisory: a
        // fetch outcome never reaches `machine` and never gates dispatch.
        if let Some(pf) = prefetch.as_mut() {
            pf.sync(&machine);
            if interrupted.is_none() {
                if let Some((index, child)) = pf.spawn_next(&setup, &run_dir(&setup)) {
                    let waiter_tx = tx.clone();
                    std::thread::spawn(move || {
                        let mut child = child;
                        let _ = child.wait();
                        let _ = waiter_tx.send(Event::FetchDone { index });
                    });
                }
            }
        }

        let nothing_left = machine.active() == 0
            && (machine.finished() || interrupted.is_some() || machine.pick().is_empty());
        if nothing_left {
            let fetch_in_flight = prefetch
                .as_ref()
                .map(|p| p.pid().is_some())
                .unwrap_or(false);
            if !fetch_in_flight {
                break 'outer;
            }
            // The machine has settled while one fetch is still in flight:
            // give it a bounded drain window (its verdict is operator
            // surface), then cancel it — advisory work never holds the run.
            let deadline = *settle_deadline
                .get_or_insert_with(|| std::time::Instant::now() + Duration::from_secs(5));
            if std::time::Instant::now() >= deadline {
                if let Some(pf) = prefetch.as_mut() {
                    pf.cancel();
                }
                break 'outer;
            }
        }

        let event = if interrupted.is_some() && machine.active() == 0 {
            // Teardown drained every lane.
            break 'outer;
        } else {
            match rx.recv_timeout(Duration::from_secs(3600)) {
                Ok(event) => event,
                Err(RecvTimeoutError::Timeout) => continue,
                Err(RecvTimeoutError::Disconnected) => break 'outer,
            }
        };

        match event {
            Event::LaneDone { index, killed_by } => {
                active.remove(&index);
                let was_interrupted = interrupted.is_some();
                let result = reap_result(&setup, index, err);
                match result {
                    Some(result) => {
                        let is_signal_report = matches!(
                            result.code,
                            gsa_model::LaneOutcome::Hup
                                | gsa_model::LaneOutcome::Int
                                | gsa_model::LaneOutcome::Term
                                | gsa_model::LaneOutcome::Parked
                        );
                        // §I.3: what started is `interrupted …` — a late
                        // ok/failed result cannot outvote the teardown. It
                        // still settles, exactly once, as the interrupt row:
                        // continuing past `machine.record` leaked the
                        // machine's active count and hung the dispatcher.
                        let late_result = was_interrupted && !is_signal_report;
                        // Post-build install hook (install-before-dependents,
                        // rule 11): a successful build installs BEFORE its
                        // result reaches the machine, so consumers only
                        // compile after the install landed. Runs on this
                        // single event loop — one `pacman -U` at a time (§K.3).
                        let mut code = if late_result {
                            signal_cause(interrupted).unwrap_or(gsa_model::LaneOutcome::Term)
                        } else {
                            result.code
                        };
                        let mut reason = if late_result {
                            "interrupted-mid-build".to_string()
                        } else {
                            result.reason.clone()
                        };
                        if code == gsa_model::LaneOutcome::Ok {
                            if let Some(hook) = setup.install.as_mut() {
                                let pkg = machine.node(index).id.as_str().to_string();
                                let recipe_dir = setup.nodes[index].recipe_dir.clone();
                                match hook(&pkg, &recipe_dir) {
                                    InstallStep::Done(step_reason) => {
                                        reason = step_reason;
                                    }
                                    InstallStep::Halt {
                                        reason: halt_reason,
                                        stop_dispatch,
                                    } => {
                                        code = gsa_model::LaneOutcome::Failed;
                                        reason = halt_reason;
                                        if is_install_refusal(&reason) {
                                            refused = true;
                                        }
                                        if stop_dispatch {
                                            // Halt new dispatch exactly once
                                            // (the fail-fast stop), loudly.
                                            machine.stop_dispatch();
                                            dispatch_halted = true;
                                            events(&SupEvent::Diagnostic(format!(
                                                "install halted dispatch: {reason}"
                                            )));
                                        }
                                    }
                                }
                            }
                        }
                        let row = OutcomeRow {
                            pkg: machine.node(index).id.clone(),
                            status: match code {
                                gsa_model::LaneOutcome::Ok => RowStatus::Succeeded,
                                gsa_model::LaneOutcome::Failed | gsa_model::LaneOutcome::Lost => {
                                    RowStatus::Failed
                                }
                                gsa_model::LaneOutcome::Parked => RowStatus::Parked,
                                gsa_model::LaneOutcome::Defer => RowStatus::Deferred,
                                gsa_model::LaneOutcome::Hup
                                | gsa_model::LaneOutcome::Int
                                | gsa_model::LaneOutcome::Term => RowStatus::Interrupted,
                            },
                            rc: Some(code.code()),
                            dur: Some(result.dur as i64),
                            reason: reason.clone(),
                        };
                        events(&SupEvent::Finished {
                            index,
                            row: row.clone(),
                        });
                        let requests = machine.record(
                            index,
                            Recorded {
                                code,
                                dur: Some(result.dur as i64),
                                reason,
                            },
                        );
                        write_park_markers(&setup, &requests);
                        for request in &requests {
                            events(&SupEvent::Parked {
                                index: request.index,
                                reason: request.reason.clone(),
                            });
                        }
                    }
                    None => {
                        // §F.1: nothing usable was published — the reap
                        // anomaly maps to `lost 125` unless the lane's death
                        // cause is an attributable signal (§K.3: SIGHUP/
                        // SIGINT/SIGTERM → 129/130/143). Either way the row
                        // settles exactly once — continuing past
                        // `machine.record` leaked the machine's active count
                        // and hung the dispatcher.
                        let (code, reason) = match signal_cause(killed_by) {
                            Some(code) => (code, "interrupted-mid-build".to_string()),
                            None => (gsa_model::LaneOutcome::Lost, "lane-lost".to_string()),
                        };
                        let message = if code == gsa_model::LaneOutcome::Lost {
                            format!(
                                "gsa: no usable result for {} — mapping to lost (125)",
                                machine.node(index).id
                            )
                        } else {
                            format!(
                                "gsa: no usable result for {} — killed by a signal, mapping to {} ({})",
                                machine.node(index).id,
                                reason,
                                code.code()
                            )
                        };
                        let _ = writeln!(err, "{message}");
                        events(&SupEvent::Diagnostic(message));
                        let row = OutcomeRow {
                            pkg: machine.node(index).id.clone(),
                            status: match code {
                                gsa_model::LaneOutcome::Hup
                                | gsa_model::LaneOutcome::Int
                                | gsa_model::LaneOutcome::Term => RowStatus::Interrupted,
                                _ => RowStatus::Failed,
                            },
                            rc: Some(code.code()),
                            dur: None,
                            reason: reason.clone(),
                        };
                        events(&SupEvent::Finished {
                            index,
                            row: row.clone(),
                        });
                        if was_interrupted {
                            // §I.3: the teardown owns what never launched —
                            // no failure policy may park the cone here.
                            machine.record_teardown(
                                index,
                                Recorded {
                                    code,
                                    dur: None,
                                    reason,
                                },
                            );
                        } else {
                            machine.record(
                                index,
                                Recorded {
                                    code,
                                    dur: None,
                                    reason,
                                },
                            );
                        }
                    }
                }
            }
            Event::FetchDone { index } => {
                // Advisory reap (plan.md §3.1): warn and log, never a row.
                if let Some(pf) = prefetch.as_mut() {
                    if let Some(warning) = pf.reap(&setup, &run_dir(&setup), index) {
                        let message = format!(
                            "prefetch {}: {} — the lane will retry at build time",
                            warning.pkg, warning.reason
                        );
                        let _ = writeln!(err, "gsa: warning: {message}");
                        events(&SupEvent::PrefetchWarning(message));
                    }
                }
            }
            Event::Signal(sig) => {
                events(&SupEvent::Signal(sig));
                if interrupted.is_none() {
                    interrupted = Some(sig);
                    events(&SupEvent::Teardown(
                        "one SIGTERM per lane, shared grace window",
                    ));
                    for lane in active.values_mut() {
                        if !lane.term_sent {
                            signal_group(lane.pid, signals::SIGTERM);
                            lane.term_sent = true;
                        }
                    }
                    if let Some(pf) = prefetch.as_mut() {
                        pf.terminate();
                    }
                    if !grace_started {
                        grace_started = true;
                        let tx = tx.clone();
                        let grace = signals::stop_grace_seconds();
                        std::thread::spawn(move || {
                            std::thread::sleep(Duration::from_secs(grace));
                            let _ = tx.send(Event::GraceExpired);
                        });
                    }
                } else {
                    // Second signal: escalate immediately (§K.3).
                    events(&SupEvent::Teardown("second signal — SIGKILL sweep"));
                    for lane in active.values() {
                        signal_group(lane.pid, SIGKILL);
                    }
                    if let Some(pf) = prefetch.as_mut() {
                        pf.kill();
                    }
                }
            }
            Event::GraceExpired => {
                if interrupted.is_some() && !active.is_empty() {
                    events(&SupEvent::Teardown("grace expired — SIGKILL sweep"));
                    for lane in active.values() {
                        signal_group(lane.pid, SIGKILL);
                    }
                }
                if interrupted.is_some() {
                    if let Some(pf) = prefetch.as_mut() {
                        pf.kill();
                    }
                }
            }
        }
    }

    // Settle the record: interrupt rows first, then policy-specific stops.
    if let Some(sig) = interrupted {
        // Give stragglers one bounded reap window after any SIGKILL sweep.
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        while !active.is_empty() && std::time::Instant::now() < deadline {
            match rx.recv_timeout(Duration::from_millis(100)) {
                Ok(Event::LaneDone { index, .. }) => {
                    active.remove(&index);
                }
                Ok(_) => {}
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => break,
            }
        }
        for lane in active.values() {
            signal_group(lane.pid, SIGKILL);
        }
        if let Some(pf) = prefetch.as_mut() {
            // The fetch child dies with the run (§K.3) — no orphans.
            pf.kill();
        }
        machine.finalize_interrupted(signal_lane_code(sig));
    } else if machine.finished() {
        // nothing to settle
    } else if (setup.policy == Policy::FailFast || dispatch_halted) && machine.active() == 0 {
        // The fail-fast stop — policy-driven, or requested once by an
        // install-step `Halt { stop_dispatch: true }`.
        machine.finalize_stopped();
    } else {
        machine.finalize_never_ready();
    }

    let prefetch_warnings = prefetch.map(|pf| pf.warnings).unwrap_or_default();
    Ok(SupOutcome {
        rows: machine.rows(),
        interrupted: interrupted.is_some(),
        signal_code: interrupted.map(signal_lane_code).unwrap_or(0),
        refused,
        prefetch_warnings,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    #[test]
    fn run_id_is_epoch_and_pid() {
        let id = run_id_now();
        let (epoch, pid) = id.split_once('-').unwrap();
        assert!(epoch.parse::<u64>().is_ok());
        assert_eq!(pid, std::process::id().to_string());
    }

    /// Scratch tree under the harness `$TMPDIR` (fixture convention).
    fn scratch(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("gsa-supervisor-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("state")).unwrap();
        std::fs::create_dir_all(dir.join("root")).unwrap();
        dir
    }

    /// A one-node run whose lane child is `stub` (any argv) — the stub never
    /// runs makepkg and never publishes through the codec unless its body
    /// says so.
    fn one_node_setup(dir: &PathBuf, stub: &PathBuf, name: &str) -> RunSetup {
        RunSetup {
            root: dir.join("root"),
            state_dir: dir.join("state"),
            run_id: format!("test-{name}-{}", std::process::id()),
            exe: stub.clone(),
            budget: Budget {
                threads: 1,
                memory_gib: 1,
                intensity: "low",
                lanes: 1,
                normal_jobs: 1,
                core_jobs: 1,
            },
            policy: Policy::ConeStop,
            lane_flags: Vec::new(),
            nodes: vec![SupNode {
                id: RecipeId::new("p1").expect("p1 is a valid id"),
                recipe_dir: dir.join("root/packages/p1"),
                core: false,
                build_tools: false,
                prereqs: Vec::new(),
                consumers: Vec::new(),
                batch: None,
            }],
            batches: Vec::new(),
            install: None,
            prefetch: None,
        }
    }

    fn write_stub(dir: &PathBuf, name: &str, body: &str) -> PathBuf {
        let stub = dir.join(name);
        std::fs::write(&stub, body).unwrap();
        std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o755)).unwrap();
        stub
    }

    /// Run one supervisor pass on its own thread behind a watchdog; the run
    /// MUST terminate — a hang fails the named expectation instead of the
    /// suite. Returns (outcome, count of `Finished` events, stderr).
    fn run_watched(setup: RunSetup) -> (SupOutcome, usize, String) {
        let _guard = crate::signals::TEST_SIGNAL_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let finished = Arc::new(AtomicUsize::new(0));
        let counter = finished.clone();
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let mut sink = move |event: &SupEvent| {
                if matches!(event, SupEvent::Finished { .. }) {
                    counter.fetch_add(1, Ordering::SeqCst);
                }
            };
            let mut err: Vec<u8> = Vec::new();
            let outcome = run(setup, &mut sink, &mut err);
            let count = finished.load(Ordering::SeqCst);
            let _ = tx.send((outcome, count, String::from_utf8_lossy(&err).into_owned()));
        });
        let (outcome, count, err) = rx.recv_timeout(Duration::from_secs(20)).expect(
            "the supervisor must terminate once its lane is gone — a teardown hang skips \
             machine.record and the run never settles (contract §K)",
        );
        (outcome.expect("run must settle without error"), count, err)
    }

    /// §F.1: a lane that exits without publishing a result is the reap
    /// anomaly — exactly one settled `lost 125` row — and the run terminates.
    #[test]
    fn a_lane_that_exits_without_a_result_settles_as_one_lost_row() {
        let dir = scratch("lost");
        // TERM-proof stub lane: latch the teardown on its parent (the test
        // process — `run` owns the handlers), then exit WITHOUT publishing.
        let stub = write_stub(
            &dir,
            "stub-lane",
            "#!/usr/bin/env bash\ntrap '' TERM INT HUP\nkill -TERM \"$PPID\" 2>/dev/null\nsleep 1\nexit 0\n",
        );
        let setup = one_node_setup(&dir, &stub, "lost");
        let (outcome, finished, err) = run_watched(setup);

        assert_eq!(
            outcome.rows.len(),
            1,
            "exactly one settled outcome row (single-node topology), got {:?}",
            outcome.rows
        );
        assert_eq!(finished, 1, "the lane settles exactly once");
        let row = &outcome.rows[0];
        assert_eq!(
            row.status,
            RowStatus::Failed,
            "a lane that vanished without a result is the lost class (§F.1): {row:?}"
        );
        assert_eq!(row.rc, Some(125), "lost maps to rc 125 (§F.1): {row:?}");
        assert_eq!(
            row.reason, "lane-lost",
            "the lost reason key (§H.3): {row:?}"
        );
        assert!(
            err.contains("no usable result for p1"),
            "the lost mapping is loud (§F.2): {err}"
        );
        assert!(outcome.interrupted, "the run was signalled (§K.3)");
    }

    /// §I.3: a result that lands only after teardown began cannot outvote
    /// the interrupt — it still settles, exactly once, as
    /// `interrupted … interrupted-mid-build`.
    #[test]
    fn a_late_result_during_teardown_settles_as_one_interrupted_row() {
        let dir = scratch("late");
        // TERM-proof stub lane that publishes `ok` on the wire, then latches
        // the teardown and exits — the result is reaped only after the
        // interrupt is in effect.
        let stub = write_stub(
            &dir,
            "stub-lane",
            "#!/usr/bin/env bash\ntrap '' TERM INT HUP\nprintf 'v2 p1 0 1 ok\\n' >\"$3\"\nkill -TERM \"$PPID\" 2>/dev/null\nsleep 1\nexit 0\n",
        );
        let setup = one_node_setup(&dir, &stub, "late");
        let (outcome, finished, _err) = run_watched(setup);

        assert_eq!(
            outcome.rows.len(),
            1,
            "exactly one settled outcome row (single-node topology), got {:?}",
            outcome.rows
        );
        assert_eq!(finished, 1, "the lane settles exactly once");
        let row = &outcome.rows[0];
        assert_eq!(
            row.status,
            RowStatus::Interrupted,
            "a late ok result cannot outvote the teardown (§I.3): {row:?}"
        );
        assert_eq!(
            row.rc,
            Some(143),
            "the row carries the teardown signal's lane code (§H.3): {row:?}"
        );
        assert_eq!(
            row.reason, "interrupted-mid-build",
            "the §H.3 reason key: {row:?}"
        );
    }
}
