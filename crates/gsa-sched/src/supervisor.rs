//! The lane supervisor (contract §K): event-driven dispatch over the state
//! machine, one process group per lane, atomic result publication consumed
//! through the codec, signal teardown, and loud `lost` mapping for anything
//! that does not decode.
//!
//! Readiness is event-driven: every lane is reaped by a waiter thread that
//! blocks in `wait(2)` and reports onto one channel; signal receipt and the
//! teardown grace window arrive on the same channel through the self-pipe.
//! There is no poll cycle (docs/plans/plan-native-pm.md §8: "the poll cycle dies by
//! construction").

use std::collections::{HashMap, VecDeque};
use std::io::Write;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
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
    /// A pre-dispatch settlement (contract §B.8): `--skip` claims settle at
    /// readiness through the register+install hooks with NO lane; deferrals
    /// settle before any dispatch and park their consumer cone.
    pub pre: Option<PreSettle>,
    /// A remediation-latent node (never dispatched unless activated).
    pub latent: bool,
}

/// A pre-dispatch settlement for one node (contract §B.8).
#[derive(Clone, Debug)]
pub enum PreSettle {
    /// A `--skip`/`--skip-built` claim: no lane, but on an install run the
    /// claimed archives still install (and register) before consumers
    /// compile. The row is `succeeded - - <reason>`.
    Skip {
        /// The §H.3 claim key (`ok` / `skip-built` / `freshness-waived` /
        /// `abi-provider-waived`).
        reason: String,
        /// The claimed archive set (informational — the install hook
        /// discovers the same newest complete set itself).
        archives: Vec<PathBuf>,
    },
    /// A pre-dispatch deferral: `deferred 99 - <reason>`, consumer cone
    /// parked `waits-on-deferred`.
    Defer {
        /// The §H.3 deferral key (`anchoring-refused` /
        /// `source-unfetchable` / `upstream-unverified`).
        reason: String,
    },
}

/// The toolchain-remediation wiring (owner rule 2026-10-02): a mid-run
/// `rustc_sanity_probe` failure after one of `trigger_installs` lands
/// FORCE-BUILDS the at-risk chain instead of refusing while remediation is
/// possible. Everything topological comes from the CLI's one graph view —
/// this seam never re-parses topology.
#[derive(Clone, Debug)]
pub struct RemediationSetup {
    /// Probe scratch base ([`gsa_recipe::toolchain::resolve_probe_scratch`]).
    pub scratch_base: PathBuf,
    /// The install-time trigger packages (house: `llvm-git`, `llvm-libs-git`).
    pub trigger_installs: Vec<String>,
    /// The broken consumer a narrow chain names (house: `rust-git`).
    pub broken_consumer: String,
    /// Every recipe id the topology knows (`remediation_plan`'s `known`).
    pub known: Vec<String>,
    /// The `core` roster in canonical order (escalation chain order).
    pub core_members: Vec<String>,
    /// `toolchain_pkg` → its consumer closure in the topology's ABI
    /// direction (the `is_consumer_of_toolchain` oracle bound to that
    /// trigger package).
    pub toolchain_consumers: std::collections::HashMap<String, Vec<String>>,
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
    /// called with (package id, recipe directory, forced) when a lane
    /// published `ok`, BEFORE its result reaches the machine — so consumers
    /// only compile after the install landed. `forced` is the remediation
    /// force-install mode (fish `lane_force_install=1`): such installs never
    /// take the same-version skip. Runs on the supervisor's single event
    /// loop, which is what makes "one `pacman -U` at a time" structural (§K.3).
    pub install: Option<Box<dyn FnMut(&str, &std::path::Path, bool) -> InstallStep + Send>>,
    /// The post-build registration hook (contract §J.4): called with
    /// (package id, recipe directory, in-flight recipe ids, built) when a
    /// lane published `ok`, before the install hook — the instance is
    /// recorded while the run still knows which lanes are in flight, so
    /// retention pruning never deletes an archive the run is using.
    /// `built` distinguishes a real build (`true` — the VCS baselines and
    /// toolchain marker hook half) from a `--skip` claim (`false`). The
    /// return value is the hook's diagnostic notes, which surface as
    /// [`SupEvent::Diagnostic`] rows (loud reporting, §I.4).
    pub register: Option<
        Box<
            dyn FnMut(
                    &str,
                    &std::path::Path,
                    &std::collections::BTreeSet<String>,
                    bool,
                ) -> Vec<String>
                + Send,
        >,
    >,
    /// Fetch-ahead (contract §B.8 `--prefetch-ahead`/`--no-prefetch`, docs/plans/plan.md
    /// §2): `None` is `--no-prefetch`. Advisory by construction — a fetch
    /// outcome never reaches [`Machine`] and never changes a run-record row.
    pub prefetch: Option<PrefetchSetup>,
    /// The toolchain-remediation wiring: `None` on build-only runs and runs
    /// that carry `--allow-broken-rustc` past the PREFLIGHT only (the
    /// mid-run trigger is a real ABI mismatch and always engages).
    pub remediation: Option<RemediationSetup>,
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
    /// A view heartbeat (ux lane state): the event loop's ~1s idle tick, so a
    /// live dashboard redraws (spinner, elapsed) even while no lane moves.
    /// Never a message — both vocabularies render it empty (render.rs), and
    /// it never reaches the run record.
    Tick,
    /// A remediation latent node entered the active plan (`Machine::activate`)
    /// before its lane actually spawned (progress projection parity, rule 72).
    Activated {
        index: usize,
    },
    /// A settled node was reopened for force-rebuild (`Machine::force_rebuild`)
    /// so `Progress::rows` clears the stale settlement before re-dispatch.
    Reopened {
        index: usize,
    },
}

pub struct SupOutcome {
    pub rows: Vec<OutcomeRow>,
    /// The run-record `order` (contract §H.2, fish `_RR_ORDER`): the
    /// selection's node ids plus the remediation latents that were ACTIVATED
    /// (appended). Plan and outcome rows key to this list.
    pub order: Vec<RecipeId>,
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

/// The mid-run toolchain-remediation state machine (fish 6960-7130 /
/// 7180-7345, owner rule 2026-10-02): the force-built chain, its phases
/// (`narrow` → `core`), and the refusal latch.
#[derive(Clone, Debug, PartialEq, Eq)]
enum RemediationPhase {
    Narrow,
    Core,
}

struct Remediation {
    phase: RemediationPhase,
    /// Chain members queued but not yet dispatched (chain order).
    pending: Vec<usize>,
    /// Chain members currently in lanes.
    active: Vec<usize>,
    /// Chain members that settled (completion order — fish `_REMED_ATTEMPTED`).
    attempted: Vec<usize>,
    /// The trigger package whose install broke rustc (message subject).
    trigger: String,
    /// The probe failure engaged remediation (fish `probe_remediating`).
    started: bool,
    /// The refusal contract latched (fish `probe_stopped`): no new dispatch.
    probe_stopped: bool,
}

impl Remediation {
    fn owns(&self, index: usize) -> bool {
        self.pending.contains(&index)
            || self.active.contains(&index)
            || self.attempted.contains(&index)
    }

    fn landed(&self) -> bool {
        self.pending.is_empty() && self.active.is_empty()
    }

    /// Queue one chain member (fish `force_queue_packages` + force
    /// semantics): already-queued ids keep their position; a settled node is
    /// re-dispatched, a latent one activated, an in-flight/ready one keeps
    /// building. Returns the indices that were appended, in chain order.
    fn queue(
        &mut self,
        machine: &mut Machine,
        chain: &[usize],
        events: &mut dyn FnMut(&SupEvent),
    ) -> Vec<usize> {
        let mut appended = Vec::new();
        for &index in chain {
            if self.owns(index) {
                continue;
            }
            self.pending.push(index);
            appended.push(index);
            if machine.is_latent(index) {
                machine.activate(index);
                events(&SupEvent::Activated { index });
            } else if machine.is_settled(index) {
                machine.force_rebuild(index);
                events(&SupEvent::Reopened { index });
            }
        }
        appended
    }

    /// One chain member settled: move it to `attempted`.
    fn settle(&mut self, index: usize) {
        self.pending.retain(|&i| i != index);
        self.active.retain(|&i| i != index);
        self.attempted.push(index);
    }

    /// The chain member left the pending queue at dispatch.
    fn dispatched(&mut self, index: usize) {
        if self.pending.contains(&index) {
            self.pending.retain(|&i| i != index);
            self.active.push(index);
        }
    }
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

/// The dispatcher-side prefetch driver (docs/plans/plan.md §2.1/§2.3): a lookahead
/// window over plan order, ONE fetch child in flight (single-flight), the
/// disk free-space floor, and the advisory records (owner decision 5).
/// Every fetch outcome is advisory: it warns and logs, and never reaches
/// the dispatch machine — a failed prefetch never gates dispatch and never
/// changes any package's outcome row (docs/plans/plan.md §3.1).
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
    /// deferred packages leave the window (docs/plans/plan.md §2.1).
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
        err: &mut dyn Write,
    ) -> Option<(usize, std::process::Child)> {
        if self.active.is_some() {
            return None;
        }
        let index = self.window.next_to_fetch()?;
        let pkg = setup.nodes[index].id.as_str().to_string();
        // The disk-floor probe follows where the fetch writes: the resolved
        // SRCDEST mirror, else makepkg's `$startdir` default — the node's
        // recipe dir (the same fallback gsa-fetch's engine takes).
        let cache =
            engine::resolve_srcdest().unwrap_or_else(|| setup.nodes[index].recipe_dir.clone());
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
                self.note(
                    &format!("prefetch {pkg}: cannot spawn fetch child: {error}"),
                    err,
                );
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
        err: &mut dyn Write,
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
                self.note(
                    &format!(
                        "prefetch result rejected for {pkg} ({}): {error}",
                        result_path.display()
                    ),
                    err,
                );
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
    /// A log that cannot be written is a LOUD one-line diagnostic, never a
    /// silently swallowed `writeln` — but never fatal: the log is advisory
    /// surface and the run continues.
    fn note(&self, line: &str, err: &mut dyn Write) {
        let written = crate::lock::open_state_append(&self.log_path, err)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::PermissionDenied, e.to_string()))
            .and_then(|mut log| writeln!(log, "gsa: {line}"));
        if let Err(error) = written {
            let _ = writeln!(
                err,
                "gsa: warning: cannot write prefetch log {}: {error}",
                self.log_path.display()
            );
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

/// `<run>/<pkg>.started` (ux lane state): one kv line naming the lane
/// child's pid, its start epoch and the byte offset where this run's log
/// output starts. The lane log is rotated at lane start, so the offset is
/// normally `0`; it still makes the tail run-scoped when the rotation was
/// refused (an unchanged log keeps the previous run's bytes in front).
/// Written at spawn, before the `Started` event renders. The caller samples
/// [`log_start_offset`] BEFORE spawning: once the child exists it appends.
/// Write one state-root file through the write-time `O_NOFOLLOW` + `fstat`
/// ownership gate (rule 19, §J.5).
fn write_state_file_gated(path: &Path, contents: &str, err: &mut dyn Write) -> Result<(), String> {
    let mut opts = std::fs::OpenOptions::new();
    opts.create(true).write(true).truncate(true);
    let mut file =
        crate::lock::open_state_file_with_uid(path, &mut opts, crate::signals::current_uid(), err)
            .map_err(|e| e.to_string())?;
    file.write_all(contents.as_bytes())
        .map_err(|e| format!("cannot write {}: {e}", path.display()))
}

fn write_started(
    setup: &RunSetup,
    index: usize,
    pid: u32,
    log_offset: u64,
    err: &mut dyn Write,
) -> Result<(), String> {
    let pkg = setup.nodes[index].id.as_str();
    let epoch = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let path = run_dir(setup).join(format!("{pkg}.started"));
    write_state_file_gated(
        &path,
        &format!("pid={pid} epoch={epoch} log-offset={log_offset}\n"),
        err,
    )
}

/// Rotate `logs/<pkg>.log` to `.log.1` at lane start (contract §J.1 log
/// retention): ONE generation aside, replacing any previous `.1`, so the
/// live log is bounded by the current run and `-Ml --keep` can actually
/// shrink the store. Best-effort and never a gate — a refused rotation is
/// announced, the append path then decides whether the lane can log.
fn rotate_lane_log(setup: &RunSetup, index: usize, err: &mut dyn Write) {
    let pkg = setup.nodes[index].id.as_str();
    let log = gsa_model::log_path(&setup.state_dir, pkg);
    if !log.exists() {
        return;
    }
    let rotated = log.with_extension("log.1");
    if let Err(error) = std::fs::rename(&log, &rotated) {
        let _ = writeln!(
            err,
            "gsa: warning: cannot rotate build log {}: {error}",
            log.display()
        );
    }
}

/// The log's size before a lane spawns — the byte where its output starts.
fn log_start_offset(setup: &RunSetup, index: usize) -> u64 {
    let pkg = setup.nodes[index].id.as_str();
    std::fs::metadata(gsa_model::log_path(&setup.state_dir, pkg))
        .map(|m| m.len())
        .unwrap_or(0)
}

/// The run's own liveness/completion stamps in its run directory
/// (contract §J.1): `run.open` carries the supervisor's pid and start epoch,
/// `run.closed` appears only when the run reached its record. A SIGKILLed
/// run leaves `run.open` alone — that is the evidence `sweep_orphans`
/// preserves and `gsa -Mh` reports as a died run.
fn write_run_stamp(setup: &RunSetup, closed: bool, err: &mut dyn Write) -> Result<(), String> {
    let epoch = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let dir = run_dir(setup);
    if closed {
        return write_state_file_gated(&dir.join("run.closed"), &format!("epoch={epoch}\n"), err);
    }
    write_state_file_gated(
        &dir.join("run.open"),
        &format!("pid={} epoch={epoch}\n", std::process::id()),
        err,
    )
}

/// `runs/current` (ux lane state): a pointer file naming the live run id, so
/// a detached reader (the dashboard's tails) reaches this run's
/// `<pkg>.started` markers without knowing the id. Replaced atomically at
/// run start; it keeps naming the LAST run afterwards (the post-run view).
fn write_current_pointer(setup: &RunSetup, err: &mut dyn Write) -> Result<(), String> {
    let runs = setup.state_dir.join("runs");
    let tmp = runs.join(format!(".current-{}", setup.run_id));
    write_state_file_gated(&tmp, &format!("{}\n", setup.run_id), err)?;
    std::fs::rename(&tmp, runs.join("current"))
        .map_err(|e| format!("cannot point current at {}: {e}", setup.run_id))
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
    // §B.11: the run's --toolchain rides to the lane as engine output, the
    // same way GSA_BUILD_JOBS does, so the lane child resolves the family a
    // decision already made instead of re-deriving it. Set ALWAYS — an
    // inherited caller value (`GSA_LANE_TOOLCHAIN=clang sudo -E gsa -B …`)
    // otherwise reached the lane with no run decision behind it, built with
    // the other makepkg body and left the drift marker claiming the old
    // family (blind-review 2026-11-11, embedded-cross-compiler F4).
    cmd.env(
        "GSA_LANE_TOOLCHAIN",
        gsa_model::toolchain::override_value()
            .map(|family| family.as_str())
            .unwrap_or(""),
    );
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

/// The run-record reason for a node whose park stand-down could not be
/// delivered (§F.1): it settles as `lost 125 park-marker-unwritable`.
const PARK_MARKER_UNWRITABLE: &str = "park-marker-unwritable";

/// Deliver the stand-down markers for a batch of park requests (contract
/// §F.1's spawn-to-build race). A marker that cannot be written is a BROKEN
/// stand-down: the spawned lane cannot be told to stand down and would
/// build and install anyway — the ABI half-wave the park exists to prevent.
/// That node is therefore settled LOUDLY as lost (125,
/// `park-marker-unwritable`) through the machine's own outcome vocabulary
/// (`LaneOutcome::Lost`), its cone and batch mates re-park through the
/// normal policy, and its late lane result is never authoritative (the
/// `LaneDone` handler skips a node that settled under it). The rogue lane is
/// ALSO killed: its process group gets SIGKILL right here, because a lane
/// that cannot be told to stand down must not keep building (wasted work,
/// shared SRCDEST/build caches). SIGKILL, never SIGTERM — a TERM death is
/// attributable (143) or swallowed by the lane's receipt handlers and would
/// corrupt the row semantics, while a SIGKILL death is the `lost 125` reap
/// anomaly the settlement already records. The file handshake itself stays
/// the normal path; a kill-based stand-down for every park is a separate
/// redesign.
fn id_text(machine: &Machine, indices: &[usize]) -> String {
    indices
        .iter()
        .map(|&i| machine.node(i).id.as_str().to_string())
        .collect::<Vec<_>>()
        .join(", ")
}

/// Shared mutable state for one supervisor event loop (`run`), eliminating
/// long parameter lists across `write_park_markers`, `settle_skip`, and
/// `remediation_settle`.
struct SupCtx<'a> {
    setup: &'a mut RunSetup,
    machine: &'a mut Machine,
    active: &'a mut HashMap<usize, ActiveLane>,
    remediation: &'a mut Option<Remediation>,
    prefetch: &'a mut Option<Prefetcher>,
    events: &'a mut dyn FnMut(&SupEvent),
    err: &'a mut dyn Write,
    refused: bool,
    dispatch_halted: bool,
    interrupted: Option<i32>,
    grace_started: bool,
}

impl<'a> SupCtx<'a> {
    fn emit(&mut self, event: &SupEvent) {
        (self.events)(event);
    }

    fn apply_install_halt(&mut self, reason: &str, stop_dispatch: bool) {
        if is_install_refusal(reason) {
            self.refused = true;
        }
        if stop_dispatch {
            self.machine.stop_dispatch();
            self.dispatch_halted = true;
            self.emit(&SupEvent::Diagnostic(format!(
                "install halted dispatch: {reason}"
            )));
        }
    }

    fn drain_signals(
        &mut self,
        rx: &Receiver<Event>,
        _tx: &Sender<Event>,
        buffered: &mut VecDeque<Event>,
    ) {
        while let Ok(ev) = rx.try_recv() {
            match ev {
                Event::Signal(sig) => self.on_signal(sig, _tx),
                other => buffered.push_back(other),
            }
        }
    }

    fn on_signal(&mut self, sig: i32, tx: &Sender<Event>) {
        if self.interrupted.is_none() {
            self.interrupted = Some(sig);
            self.machine.stop_dispatch();
            self.dispatch_halted = true;
            self.emit(&SupEvent::Teardown(
                "signal received — stopping active lanes",
            ));
            for lane in self.active.values_mut() {
                if !lane.term_sent {
                    signal_group(lane.pid, signals::SIGTERM);
                    lane.term_sent = true;
                }
            }
            if let Some(pf) = self.prefetch.as_mut() {
                pf.terminate();
            }
            if !self.grace_started {
                self.grace_started = true;
                let timer_tx = tx.clone();
                std::thread::spawn(move || {
                    std::thread::sleep(Duration::from_secs(5));
                    let _ = timer_tx.send(Event::GraceExpired);
                });
            }
        } else if !self.active.is_empty()
            || self
                .prefetch
                .as_ref()
                .map(|p| p.pid().is_some())
                .unwrap_or(false)
        {
            self.emit(&SupEvent::Teardown("second signal — SIGKILL sweep"));
            for lane in self.active.values() {
                signal_group(lane.pid, SIGKILL);
            }
            if let Some(pf) = self.prefetch.as_mut() {
                pf.kill();
            }
        }
    }

    /// Deliver the stand-down markers for a batch of park requests (contract
    /// §F.1's spawn-to-build race). A marker that cannot be written is a BROKEN
    /// stand-down: the spawned lane cannot be told to stand down and would
    /// build and install anyway — the ABI half-wave the park exists to prevent.
    /// That node is therefore settled LOUDLY as lost (125,
    /// `park-marker-unwritable`) through the machine's own outcome vocabulary
    /// (`LaneOutcome::Lost`), its cone and batch mates re-park through the
    /// normal policy, and its late lane result is never authoritative (the
    /// `LaneDone` handler skips a node that settled under it). The rogue lane is
    /// ALSO killed: its process group gets SIGKILL right here, because a lane
    /// that cannot be told to stand down must not keep building (wasted work,
    /// shared SRCDEST/build caches). SIGKILL, never SIGTERM — a TERM death is
    /// attributable (143) or swallowed by the lane's receipt handlers and would
    /// corrupt the row semantics, while a SIGKILL death is the `lost 125` reap
    /// anomaly the settlement already records. The file handshake itself stays
    /// the normal path; a kill-based stand-down for every park is a separate
    /// redesign.
    fn write_park_markers(&mut self, requests: Vec<ParkRequest>) {
        let mut queue = requests;
        let mut handled: std::collections::BTreeSet<usize> = std::collections::BTreeSet::new();
        while let Some(request) = queue.pop() {
            if !handled.insert(request.index) || self.machine.is_settled(request.index) {
                continue;
            }
            let path = park_marker_path(self.setup, request.index);
            let contents = format!("{}\n", request.reason);
            match write_state_file_gated(&path, &contents, self.err) {
                Ok(()) => {
                    self.emit(&SupEvent::Parked {
                        index: request.index,
                        reason: request.reason.clone(),
                    });
                }
                Err(error) => {
                    // The kill lands before the settlement so the rogue lane
                    // stops as early as possible; `signal_group` ignores ESRCH
                    // (a lane that already exited is its own reap), and the
                    // later `LaneDone` is skipped by `is_settled` below.
                    if let Some(lane) = self.active.get(&request.index) {
                        signal_group(lane.pid, SIGKILL);
                    }
                    let pkg = self.machine.node(request.index).id.clone();
                    let message = format!(
                        "gsa: park marker {} cannot be written ({error}) — {pkg} cannot stand down; settling it as lost (125)",
                        path.display()
                    );
                    let _ = writeln!(self.err, "{message}");
                    self.emit(&SupEvent::Diagnostic(message));
                    self.emit(&SupEvent::Finished {
                        index: request.index,
                        row: OutcomeRow {
                            pkg: pkg.clone(),
                            status: RowStatus::Failed,
                            rc: Some(125),
                            dur: None,
                            reason: PARK_MARKER_UNWRITABLE.to_string(),
                        },
                    });
                    let more = self.machine.record(
                        request.index,
                        Recorded {
                            code: gsa_model::LaneOutcome::Lost,
                            dur: None,
                            reason: PARK_MARKER_UNWRITABLE.to_string(),
                        },
                    );
                    self.remediation_settle(request.index, gsa_model::LaneOutcome::Lost);
                    queue.extend(more);
                }
            }
        }
    }

    /// One `--skip` claim settling at readiness (contract §B.8): no lane runs,
    /// but the registration + install hooks do — a claimed set still installs
    /// (and registers, and takes the acceptance-time IgnorePkg registration)
    /// before its consumers compile. The row keeps the CLAIM reason
    /// (`succeeded - - <reason>`); a hook that halts settles it as a failure.
    fn settle_skip(&mut self, index: usize) {
        let Some(PreSettle::Skip { reason, .. }) = self.setup.nodes[index].pre.clone() else {
            return;
        };
        let pkg = self.machine.node(index).id.as_str().to_string();
        let recipe_dir = self.setup.nodes[index].recipe_dir.clone();
        if let Some(hook) = self.setup.register.as_mut() {
            let in_flight: std::collections::BTreeSet<String> = (0..self.setup.nodes.len())
                .filter(|&j| self.machine.node_phase(j) == NodePhase::Dispatched)
                .map(|j| self.setup.nodes[j].id.as_str().to_string())
                .collect();
            for note in hook(&pkg, &recipe_dir, &in_flight, false) {
                self.emit(&SupEvent::Diagnostic(note));
            }
        }
        let mut status = RowStatus::Succeeded;
        let mut rc = None;
        let mut row_reason = reason;
        if let Some(hook) = self.setup.install.as_mut() {
            match hook(&pkg, &recipe_dir, false) {
                InstallStep::Done(_) => {}
                InstallStep::Halt {
                    reason: halt_reason,
                    stop_dispatch,
                } => {
                    status = RowStatus::Failed;
                    rc = Some(1);
                    row_reason = halt_reason;
                    self.apply_install_halt(&row_reason, stop_dispatch);
                }
            }
        }
        let row = OutcomeRow {
            pkg: self.machine.node(index).id.clone(),
            status,
            rc,
            dur: None,
            reason: row_reason.clone(),
        };
        self.emit(&SupEvent::Finished { index, row });
        let requests = self.machine.record_pre(index, status, rc, &row_reason);
        self.write_park_markers(requests);
    }

    /// The remediation refusal latch (fish `probe_stopped` + `stop_starting`):
    /// the named refusal, the one probe-refusal prose, and dispatch halted
    /// exactly once. Every refusal end of the remediation machine funnels here.
    fn remediation_refuse(&mut self, message: String) {
        let _ = writeln!(self.err, "gsa: {message}");
        let _ = writeln!(
            self.err,
            "{}",
            gsa_recipe::toolchain::remediation_refusal_text()
        );
        if let Some(rem) = self.remediation.as_mut() {
            rem.probe_stopped = true;
        }
        self.machine.stop_dispatch();
        self.dispatch_halted = true;
        self.refused = true;
        self.emit(&SupEvent::Diagnostic(message));
    }

    /// The mid-run toolchain-remediation bookkeeping (fish 6960-7130 /
    /// 7180-7345, owner rule 2026-10-02), run after every settled lane. A
    /// settled chain member decides the remediation; a successful install of a
    /// trigger package re-probes and, on failure, FORCE-BUILDS the at-risk
    /// chain (narrow `rust-git` first, the whole `core` group on escalation)
    /// instead of refusing while remediation is possible.
    fn remediation_settle(&mut self, index: usize, code: gsa_model::LaneOutcome) {
        let Some(cfg) = self.setup.remediation.clone() else {
            return;
        };
        let Some(rem) = self.remediation.as_mut() else {
            return;
        };
        let pkg = self.machine.node(index).id.as_str().to_string();

        if rem.owns(index) {
            // A chain member settled: its outcome decides the remediation.
            rem.settle(index);
            match code {
                gsa_model::LaneOutcome::Ok => {
                    if !rem.landed() || rem.probe_stopped {
                        return;
                    }
                    match gsa_recipe::toolchain::rustc_sanity_probe(&cfg.scratch_base) {
                        gsa_recipe::toolchain::ProbeStatus::Ok
                        | gsa_recipe::toolchain::ProbeStatus::Skipped { .. } => {
                            let _ = writeln!(
                                self.err,
                                "gsa: toolchain remediation reconciled the at-risk chain (rebuilt {}) — rustc sanity probe passes, resuming dispatch",
                                id_text(self.machine, &rem.attempted)
                            );
                            self.machine.set_restrict(None);
                            rem.started = false;
                            rem.attempted.clear();
                            rem.phase = RemediationPhase::Narrow;
                        }
                        gsa_recipe::toolchain::ProbeStatus::Failed { detail } => {
                            let _ = writeln!(self.err, "gsa: {detail}");
                            match rem.phase {
                                RemediationPhase::Narrow => {
                                    let attempted = id_text(self.machine, &rem.attempted);
                                    let _ = writeln!(
                                        self.err,
                                        "gsa: remediation by {attempted} was insufficient — the tool-clang/llvm consumer chain is still broken"
                                    );
                                    let _ = writeln!(
                                        self.err,
                                        "  Escalating to a full core-group force-build (owner rule 2026-10-02)."
                                    );
                                    rem.phase = RemediationPhase::Core;
                                    let attempted_ids: Vec<String> = rem
                                        .attempted
                                        .iter()
                                        .map(|&i| self.machine.node(i).id.as_str().to_string())
                                        .collect();
                                    let chain: Vec<usize> = cfg
                                        .core_members
                                        .iter()
                                        .filter(|id| !attempted_ids.contains(id))
                                        .filter_map(|id| {
                                            (0..self.setup.nodes.len()).find(|&i| {
                                                self.setup.nodes[i].id.as_str() == id.as_str()
                                            })
                                        })
                                        .collect();
                                    if chain.is_empty() {
                                        self.remediation_refuse(
                                            "core-group remediation has nothing left to force-build — refusing to continue"
                                                .to_string(),
                                        );
                                        return;
                                    }
                                    let ids = id_text(self.machine, &chain);
                                    for &i in &chain {
                                        self.setup.nodes[i].pre = None;
                                    }
                                    rem.queue(self.machine, &chain, self.events);
                                    self.machine.set_restrict(Some(chain));
                                    let _ = writeln!(
                                        self.err,
                                        "gsa: toolchain remediation (phase core): force-building {ids}"
                                    );
                                }
                                RemediationPhase::Core => {
                                    let attempted = id_text(self.machine, &rem.attempted);
                                    self.remediation_refuse(format!(
                                        "core-group remediation rebuilt {attempted} and the sanity probe still fails — refusing to continue",
                                    ));
                                }
                            }
                        }
                    }
                }
                gsa_model::LaneOutcome::Defer | gsa_model::LaneOutcome::Parked => {
                    self.remediation_refuse(format!(
                        "toolchain remediation build for {pkg} was deferred — the at-risk chain cannot be reconciled; refusing to continue"
                    ));
                }
                _ => {
                    self.remediation_refuse(format!(
                        "toolchain remediation build for {pkg} failed — the at-risk chain could not be reconciled; refusing to continue"
                    ));
                }
            }
            return;
        }

        // The trigger (fish: install runs only, once per remediation cycle):
        // a successful install of a trigger package re-probes — this run's own
        // llvm install can break rustc after the preflight passed.
        let install_run = self.setup.install.is_some();
        if !install_run
            || code != gsa_model::LaneOutcome::Ok
            || !cfg.trigger_installs.iter().any(|t| t == &pkg)
            || rem.started
            || rem.probe_stopped
        {
            return;
        }
        let gsa_recipe::toolchain::ProbeStatus::Failed { detail } =
            gsa_recipe::toolchain::rustc_sanity_probe(&cfg.scratch_base)
        else {
            return;
        };
        let _ = writeln!(self.err, "gsa: {detail}");
        let _ = writeln!(
            self.err,
            "gsa: rustc sanity probe failed after {pkg} was installed — this run's own llvm install broke rustc"
        );
        for line in [
            "  Toolchain risk detected for the tool-clang/llvm consumer chain — not",
            "  just rustc. Owner rule 2026-10-02: the builder FORCE-BUILDS the at-risk",
            "  chain to reconcile it — first rust-git (rust), or the whole core group",
            "  when the broken consumer cannot be identified narrowly — and refuses",
            "  only if that remediation build also fails. This probe stays loud but",
            "  does not refuse builds while remediation is possible.",
        ] {
            let _ = writeln!(self.err, "{line}");
        }
        let known = |id: &str| cfg.known.iter().any(|k| k == id);
        let is_consumer_of_toolchain = |id: &str| {
            cfg.toolchain_consumers
                .get(&pkg)
                .map(|closure| closure.iter().any(|c| c == id))
                .unwrap_or(false)
        };
        let plan = gsa_recipe::toolchain::remediation_plan(
            &pkg,
            &cfg.broken_consumer,
            &known,
            &is_consumer_of_toolchain,
            &cfg.core_members,
        );
        let (phase, chain_ids) = match plan {
            gsa_recipe::toolchain::Remediation::Narrow(ids) => (RemediationPhase::Narrow, ids),
            gsa_recipe::toolchain::Remediation::Core(ids) => (RemediationPhase::Core, ids),
            gsa_recipe::toolchain::Remediation::Impossible => {
                self.remediation_refuse(format!(
                    "no force-build remediation chain is identifiable for {pkg} — refusing to continue"
                ));
                return;
            }
        };
        let chain: Vec<usize> = chain_ids
            .iter()
            .filter_map(|id| {
                (0..self.setup.nodes.len())
                    .find(|&i| self.setup.nodes[i].id.as_str() == id.as_str())
            })
            .collect();
        if chain.is_empty() {
            self.remediation_refuse(format!(
                "no force-build remediation chain is identifiable for {pkg} — refusing to continue"
            ));
            return;
        }
        let ids = id_text(self.machine, &chain);
        for &i in &chain {
            self.setup.nodes[i].pre = None;
        }
        rem.phase = phase;
        rem.trigger = pkg.clone();
        rem.started = true;
        rem.queue(self.machine, &chain, self.events);
        self.machine.set_restrict(Some(chain));
        let phase_name = match rem.phase {
            RemediationPhase::Narrow => "narrow",
            RemediationPhase::Core => "core",
        };
        let _ = writeln!(
            self.err,
            "gsa: toolchain remediation (phase {phase_name}): force-building {ids} to reconcile the at-risk chain before anything else compiles"
        );
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
    if let Err(error) = write_current_pointer(&setup, err) {
        events(&SupEvent::Diagnostic(format!("lane-state: {error}")));
    }
    if let Err(error) = write_run_stamp(&setup, false, err) {
        events(&SupEvent::Diagnostic(format!("lane-state: {error}")));
    }

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
            latent: n.latent,
        })
        .collect();
    let mut machine = Machine::new(
        nodes,
        setup.batches.clone(),
        setup.policy,
        setup.budget.lanes as usize,
    );
    let mut remediation: Option<Remediation> = setup.remediation.as_ref().map(|_| Remediation {
        phase: RemediationPhase::Narrow,
        pending: Vec::new(),
        active: Vec::new(),
        attempted: Vec::new(),
        trigger: String::new(),
        started: false,
        probe_stopped: false,
    });
    let mut active: HashMap<usize, ActiveLane> = HashMap::new();
    let mut prefetch: Option<Prefetcher> = setup
        .prefetch
        .as_ref()
        .map(|cfg| Prefetcher::new(cfg, machine.len()));

    let mut ctx = SupCtx {
        setup: &mut setup,
        machine: &mut machine,
        active: &mut active,
        remediation: &mut remediation,
        prefetch: &mut prefetch,
        events,
        err,
        refused: false,
        dispatch_halted: false,
        interrupted: None,
        grace_started: false,
    };

    let pre_defers: Vec<usize> = ctx
        .setup
        .nodes
        .iter()
        .enumerate()
        .filter(|(_, node)| matches!(node.pre, Some(PreSettle::Defer { .. })))
        .map(|(index, _)| index)
        .collect();
    for index in pre_defers {
        let Some(PreSettle::Defer { reason }) = ctx.setup.nodes[index].pre.clone() else {
            continue;
        };
        let row = OutcomeRow {
            pkg: ctx.machine.node(index).id.clone(),
            status: RowStatus::Deferred,
            rc: Some(99),
            dur: None,
            reason: reason.clone(),
        };
        ctx.emit(&SupEvent::Finished { index, row });
        let requests = ctx
            .machine
            .record_pre(index, RowStatus::Deferred, Some(99), &reason);
        ctx.write_park_markers(requests);
    }

    let (tx, rx): (Sender<Event>, Receiver<Event>) = mpsc::channel();
    let pipe = install_handlers().map_err(|e| format!("cannot install signal handlers: {e}"))?;
    let crate::signals::SignalPipe {
        mut read,
        guard: _signal_guard,
    } = pipe;
    {
        let tx = tx.clone();
        std::thread::spawn(move || {
            use std::io::Read;
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

    let mut buffered: VecDeque<Event> = VecDeque::new();
    let mut settle_deadline: Option<std::time::Instant> = None;

    'outer: loop {
        // `--skip` claims settle at readiness (contract §B.8), polling for
        // pending teardown signals between claims so a receipt halts before
        // subsequent register/install hooks run.
        while ctx.interrupted.is_none() {
            ctx.drain_signals(&rx, &tx, &mut buffered);
            if ctx.interrupted.is_some() {
                break;
            }
            let Some(index) = ctx
                .machine
                .pick()
                .into_iter()
                .find(|&i| matches!(ctx.setup.nodes[i].pre, Some(PreSettle::Skip { .. })))
            else {
                break;
            };
            ctx.settle_skip(index);
        }
        // Dispatch everything the machine allows right now, polling for
        // teardown signals between spawns as well.
        while ctx.interrupted.is_none() {
            ctx.drain_signals(&rx, &tx, &mut buffered);
            if ctx.interrupted.is_some() {
                break;
            }
            let Some(index) = ctx
                .machine
                .pick()
                .into_iter()
                .find(|&i| ctx.machine.can_dispatch(i))
            else {
                break;
            };
            let jobs = if ctx.machine.node(index).core {
                ctx.setup.budget.core_jobs
            } else {
                ctx.setup.budget.normal_jobs
            };
            rotate_lane_log(ctx.setup, index, ctx.err);
            let log_offset = log_start_offset(ctx.setup, index);
            match spawn_lane(ctx.setup, index, jobs) {
                Ok(mut child) => {
                    let pid = child.id();
                    if let Err(error) = write_started(ctx.setup, index, pid, log_offset, ctx.err) {
                        ctx.emit(&SupEvent::Diagnostic(format!("lane-state: {error}")));
                    }
                    ctx.machine.dispatch(index);
                    if let Some(rem) = ctx.remediation.as_mut() {
                        rem.dispatched(index);
                    }
                    ctx.active.insert(
                        index,
                        ActiveLane {
                            pid,
                            term_sent: false,
                        },
                    );
                    let core = ctx.machine.node(index).core;
                    ctx.emit(&SupEvent::Started { index, jobs, core });
                    let waiter_tx = tx.clone();
                    let waiter_index = index;
                    std::thread::spawn(move || {
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
                    ctx.machine.dispatch(index);
                    let _ = writeln!(ctx.err, "gsa: {error}");
                    let row = OutcomeRow {
                        pkg: ctx.machine.node(index).id.clone(),
                        status: RowStatus::Failed,
                        rc: Some(1),
                        dur: None,
                        reason: "build-failed".to_string(),
                    };
                    ctx.emit(&SupEvent::Finished {
                        index,
                        row: row.clone(),
                    });
                    let requests = ctx.machine.record(
                        index,
                        Recorded {
                            code: gsa_model::LaneOutcome::Failed,
                            dur: None,
                            reason: "build-failed".to_string(),
                        },
                    );
                    ctx.write_park_markers(requests);
                    ctx.remediation_settle(index, gsa_model::LaneOutcome::Failed);
                }
            }
        }

        if let Some(pf) = ctx.prefetch.as_mut() {
            pf.sync(ctx.machine);
            if ctx.interrupted.is_none() {
                let rdir = run_dir(ctx.setup);
                if let Some((index, child)) = pf.spawn_next(ctx.setup, &rdir, ctx.err) {
                    let waiter_tx = tx.clone();
                    std::thread::spawn(move || {
                        let mut child = child;
                        let _ = child.wait();
                        let _ = waiter_tx.send(Event::FetchDone { index });
                    });
                }
            }
        }

        if ctx.interrupted.is_none() {
            let stalled_ids = match (ctx.remediation.as_ref(), ctx.setup.remediation.as_ref()) {
                (Some(rem), Some(_))
                    if rem.started
                        && !rem.probe_stopped
                        && !rem.landed()
                        && ctx.machine.active() == 0
                        && ctx.machine.pick().is_empty() =>
                {
                    Some(
                        rem.pending
                            .iter()
                            .map(|&i| ctx.machine.node(i).id.as_str().to_string())
                            .collect::<Vec<_>>()
                            .join(", "),
                    )
                }
                _ => None,
            };
            if let Some(ids) = stalled_ids {
                ctx.remediation_refuse(format!(
                    "toolchain remediation stalled — {ids} cannot be dispatched; refusing to continue"
                ));
            }
        }
        let nothing_left = ctx.machine.active() == 0
            && ctx.active.is_empty()
            && (ctx.machine.finished()
                || ctx.interrupted.is_some()
                || ctx.machine.pick().is_empty());
        if nothing_left {
            let fetch_in_flight = ctx
                .prefetch
                .as_ref()
                .map(|p| p.pid().is_some())
                .unwrap_or(false);
            if !fetch_in_flight {
                break 'outer;
            }
            let deadline = *settle_deadline
                .get_or_insert_with(|| std::time::Instant::now() + Duration::from_secs(5));
            if std::time::Instant::now() >= deadline {
                if let Some(pf) = ctx.prefetch.as_mut() {
                    pf.cancel();
                }
                break 'outer;
            }
        }

        let event =
            if ctx.interrupted.is_some() && ctx.machine.active() == 0 && ctx.active.is_empty() {
                break 'outer;
            } else if let Some(ev) = buffered.pop_front() {
                ev
            } else {
                match rx.recv_timeout(Duration::from_secs(1)) {
                    Ok(event) => event,
                    Err(RecvTimeoutError::Timeout) => {
                        ctx.emit(&SupEvent::Tick);
                        continue;
                    }
                    Err(RecvTimeoutError::Disconnected) => break 'outer,
                }
            };

        match event {
            Event::LaneDone { index, killed_by } => {
                ctx.active.remove(&index);
                if ctx.machine.is_settled(index) {
                    let message = format!(
                        "gsa: late lane result for {} ignored — the node already settled ({}), it must not install",
                        ctx.machine.node(index).id,
                        PARK_MARKER_UNWRITABLE
                    );
                    let _ = writeln!(ctx.err, "{message}");
                    ctx.emit(&SupEvent::Diagnostic(message));
                    continue 'outer;
                }
                let was_interrupted = ctx.interrupted.is_some();
                let forced = ctx
                    .remediation
                    .as_ref()
                    .map(|rem| rem.owns(index))
                    .unwrap_or(false);
                let settled_code: Option<gsa_model::LaneOutcome>;
                let result = reap_result(ctx.setup, index, ctx.err);
                match result {
                    Some(result) => {
                        let is_signal_report = matches!(
                            result.code,
                            gsa_model::LaneOutcome::Hup
                                | gsa_model::LaneOutcome::Int
                                | gsa_model::LaneOutcome::Term
                                | gsa_model::LaneOutcome::Parked
                        );
                        let late_result = was_interrupted && !is_signal_report;
                        let mut code = if late_result {
                            signal_cause(ctx.interrupted).unwrap_or(gsa_model::LaneOutcome::Term)
                        } else {
                            result.code
                        };
                        let mut reason = if late_result {
                            "interrupted-mid-build".to_string()
                        } else {
                            result.reason.clone()
                        };
                        if code == gsa_model::LaneOutcome::Ok {
                            let pkg = ctx.machine.node(index).id.as_str().to_string();
                            let recipe_dir = ctx.setup.nodes[index].recipe_dir.clone();
                            if let Some(hook) = ctx.setup.register.as_mut() {
                                let in_flight: std::collections::BTreeSet<String> =
                                    (0..ctx.setup.nodes.len())
                                        .filter(|&j| j != index)
                                        .filter(|&j| {
                                            ctx.machine.node_phase(j)
                                                == crate::machine::NodePhase::Dispatched
                                        })
                                        .map(|j| ctx.setup.nodes[j].id.as_str().to_string())
                                        .collect();
                                let notes = hook(&pkg, &recipe_dir, &in_flight, true);
                                for note in notes {
                                    ctx.emit(&SupEvent::Diagnostic(note));
                                }
                            }
                            if let Some(hook) = ctx.setup.install.as_mut() {
                                match hook(&pkg, &recipe_dir, forced) {
                                    InstallStep::Done(step_reason) => {
                                        reason = step_reason;
                                    }
                                    InstallStep::Halt {
                                        reason: halt_reason,
                                        stop_dispatch,
                                    } => {
                                        code = gsa_model::LaneOutcome::Failed;
                                        reason = halt_reason;
                                        ctx.apply_install_halt(&reason, stop_dispatch);
                                    }
                                }
                            }
                        }
                        let row = OutcomeRow {
                            pkg: ctx.machine.node(index).id.clone(),
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
                        ctx.emit(&SupEvent::Finished {
                            index,
                            row: row.clone(),
                        });
                        settled_code = Some(code.clone());
                        let requests = ctx.machine.record(
                            index,
                            Recorded {
                                code,
                                dur: Some(result.dur as i64),
                                reason,
                            },
                        );
                        ctx.write_park_markers(requests);
                    }
                    None => {
                        let (code, reason) = match signal_cause(killed_by) {
                            Some(code) => (code, "interrupted-mid-build".to_string()),
                            None if was_interrupted => (
                                signal_cause(ctx.interrupted)
                                    .unwrap_or(gsa_model::LaneOutcome::Term),
                                "interrupted-mid-build".to_string(),
                            ),
                            None => (gsa_model::LaneOutcome::Lost, "lane-lost".to_string()),
                        };
                        let message = if code == gsa_model::LaneOutcome::Lost {
                            format!(
                                "gsa: no usable result for {} — mapping to lost (125)",
                                ctx.machine.node(index).id
                            )
                        } else {
                            format!(
                                "gsa: no usable result for {} — mapping to {} ({})",
                                ctx.machine.node(index).id,
                                reason,
                                code.code()
                            )
                        };
                        let _ = writeln!(ctx.err, "{message}");
                        ctx.emit(&SupEvent::Diagnostic(message));
                        let row = OutcomeRow {
                            pkg: ctx.machine.node(index).id.clone(),
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
                        ctx.emit(&SupEvent::Finished {
                            index,
                            row: row.clone(),
                        });
                        settled_code = Some(code.clone());
                        if was_interrupted {
                            ctx.machine.record_teardown(
                                index,
                                Recorded {
                                    code,
                                    dur: None,
                                    reason,
                                },
                            );
                        } else {
                            let requests = ctx.machine.record(
                                index,
                                Recorded {
                                    code,
                                    dur: None,
                                    reason,
                                },
                            );
                            ctx.write_park_markers(requests);
                        }
                    }
                }
                if let Some(code) = settled_code {
                    if !was_interrupted {
                        ctx.remediation_settle(index, code);
                    }
                }
            }
            Event::FetchDone { index } => {
                if let Some(pf) = ctx.prefetch.as_mut() {
                    let rdir = run_dir(ctx.setup);
                    if let Some(warning) = pf.reap(ctx.setup, &rdir, index, ctx.err) {
                        let message = format!(
                            "prefetch {}: {} — the lane will retry at build time",
                            warning.pkg, warning.reason
                        );
                        let _ = writeln!(ctx.err, "gsa: warning: {message}");
                        ctx.emit(&SupEvent::PrefetchWarning(message));
                    }
                }
            }
            Event::Signal(sig) => ctx.on_signal(sig, &tx),
            Event::GraceExpired => {
                if ctx.interrupted.is_some() && !ctx.active.is_empty() {
                    ctx.emit(&SupEvent::Teardown("grace expired — SIGKILL sweep"));
                    for lane in ctx.active.values() {
                        signal_group(lane.pid, SIGKILL);
                    }
                }
                if ctx.interrupted.is_some() {
                    if let Some(pf) = ctx.prefetch.as_mut() {
                        pf.kill();
                    }
                }
            }
        }
    }

    let interrupted = ctx.interrupted;
    let refused = ctx.refused;
    let dispatch_halted = ctx.dispatch_halted;
    drop(ctx);

    if let Some(sig) = interrupted {
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
            pf.kill();
        }
        machine.finalize_interrupted(signal_lane_code(sig));
    } else if machine.finished() {
    } else if (setup.policy == Policy::FailFast || dispatch_halted) && machine.active() == 0 {
        machine.finalize_stopped();
    } else {
        machine.finalize_never_ready();
    }

    if let Err(error) = write_run_stamp(&setup, true, err) {
        events(&SupEvent::Diagnostic(format!("lane-state: {error}")));
    }
    let prefetch_warnings = prefetch.map(|pf| pf.warnings).unwrap_or_default();
    Ok(SupOutcome {
        rows: machine.rows(),
        order: machine.order(),
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

    /// ux lane state: the run publishes its own coordinates — `runs/current`
    /// names the run, `<run>/<pkg>.started` names the lane's pid, start epoch
    /// and log start offset — and the view heartbeat ticks while the lane
    /// runs. Observability only: the run settles normally either way.
    #[test]
    fn lane_state_markers_and_the_view_tick_land_during_a_run() {
        let _guard = crate::signals::TEST_SIGNAL_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let dir = scratch("lane-state");
        // A lane that outlives the ~1s tick, then exits without publishing —
        // the lost settlement is beside the point, the run only must settle.
        let stub = write_stub(&dir, "slow-lane", "#!/usr/bin/env bash\nsleep 2\nexit 0\n");
        let setup = one_node_setup(&dir, &stub, "lane-state");
        let run_id = setup.run_id.clone();
        let state_dir = setup.state_dir.clone();
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let mut sink = |event: &SupEvent| {
                let _ = tx.send(event.clone());
            };
            let mut err: Vec<u8> = Vec::new();
            let _ = run(setup, &mut sink, &mut err);
        });
        let mut events: Vec<SupEvent> = Vec::new();
        loop {
            match rx.recv_timeout(Duration::from_secs(20)) {
                Ok(event) => events.push(event),
                // The sink drops when the run returns — the disconnect IS
                // the termination signal; a timeout before it is a hang.
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    panic!("the supervisor must terminate once its lane is gone (contract §K)")
                }
            }
        }

        let current = std::fs::read_to_string(state_dir.join("runs").join("current"))
            .expect("runs/current is written at run start");
        assert_eq!(current.trim(), run_id, "runs/current names THIS run");

        let started =
            std::fs::read_to_string(state_dir.join("runs").join(&run_id).join("p1.started"))
                .expect("the lane's .started marker is written at spawn");
        let pid = started
            .split_whitespace()
            .find_map(|f| f.strip_prefix("pid=")?.parse::<u32>().ok())
            .unwrap_or(0);
        assert!(
            pid > 1 && pid != std::process::id(),
            "the marker names the spawned lane child's real pid: {started:?}"
        );
        assert!(
            started.contains(" epoch=") && started.contains(" log-offset=0\n"),
            "the marker names a start epoch and the pre-spawn log offset (0 here): {started:?}"
        );
        assert!(
            events.iter().any(|e| matches!(e, SupEvent::Tick)),
            "the view heartbeat ticks while the lane runs: {:?}",
            events.len()
        );
        // The run's own stamps: opened at start (with this process's pid),
        // closed only because the run reached its record. A killed run keeps
        // `run.open` alone, which is what `-Mh` and the sweep read.
        let open = std::fs::read_to_string(state_dir.join("runs").join(&run_id).join("run.open"))
            .expect("run.open is written at run start");
        assert!(
            open.contains(&format!("pid={} ", std::process::id())),
            "run.open names the supervisor's pid: {open:?}"
        );
        assert!(
            state_dir
                .join("runs")
                .join(&run_id)
                .join("run.closed")
                .exists(),
            "a run that reached its record writes run.closed"
        );
        let _ = std::fs::remove_dir_all(&dir);
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
                pre: None,
                latent: false,
            }],
            batches: Vec::new(),
            install: None,
            register: None,
            prefetch: None,
            remediation: None,
        }
    }

    fn write_stub(dir: &PathBuf, name: &str, body: &str) -> PathBuf {
        let stub = dir.join(name);
        std::fs::write(&stub, body).unwrap();
        std::fs::set_permissions(&stub, std::fs::Permissions::from_mode(0o755)).unwrap();
        stub
    }

    /// [`run_watched`]'s sibling: the same watchdog, but every `SupEvent` the
    /// run emits is captured — the input the live projection folds.
    fn run_capturing(setup: RunSetup) -> (SupOutcome, Vec<SupEvent>, String) {
        let _guard = crate::signals::TEST_SIGNAL_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let (tx, rx) = mpsc::channel();
        std::thread::spawn(move || {
            let mut captured: Vec<SupEvent> = Vec::new();
            let mut err: Vec<u8> = Vec::new();
            let outcome = {
                let mut sink = |event: &SupEvent| captured.push(event.clone());
                run(setup, &mut sink, &mut err)
            };
            let _ = tx.send((
                outcome,
                captured,
                String::from_utf8_lossy(&err).into_owned(),
            ));
        });
        let (outcome, captured, err) = rx.recv_timeout(Duration::from_secs(20)).expect(
            "the supervisor must terminate once its lane is gone — a teardown hang skips \
             machine.record and the run never settles (contract §K)",
        );
        (
            outcome.expect("run must settle without error"),
            captured,
            err,
        )
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
    /// An unattributable death outside teardown stays lost (an OOM-killed
    /// lane names no cause); only an interrupted run re-maps rows (§I.3).
    #[test]
    fn a_lane_that_exits_without_a_result_settles_as_one_lost_row() {
        let dir = scratch("lost");
        // Stub lane that exits WITHOUT publishing — no teardown in play, so
        // the death has no interrupt to inherit.
        let stub = write_stub(&dir, "stub-lane", "#!/usr/bin/env bash\nsleep 1\nexit 0\n");
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
        assert!(
            !outcome.interrupted,
            "the reap anomaly must stay lost when no teardown is in play (§F.1)"
        );
    }

    /// §I.3: a lane that vanishes without a result DURING teardown is the
    /// run's interrupt, not a lost reap anomaly — the grace SIGKILL carries no
    /// cause, so the row settles with the interrupted signal's lane code (the
    /// late-result rule's mapping) and the interrupt owns what started.
    #[test]
    fn a_lane_that_vanishes_during_teardown_settles_as_one_interrupted_row() {
        let dir = scratch("lost-teardown");
        // TERM-proof stub lane: latch the teardown on its parent (the test
        // process — `run` owns the handlers), then exit WITHOUT publishing.
        let stub = write_stub(
            &dir,
            "stub-lane",
            "#!/usr/bin/env bash\ntrap '' TERM INT HUP\nkill -TERM \"$PPID\" 2>/dev/null\nsleep 1\nexit 0\n",
        );
        let setup = one_node_setup(&dir, &stub, "lost-teardown");
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
            RowStatus::Interrupted,
            "the teardown owns what started (§I.3): {row:?}"
        );
        assert_eq!(
            row.rc,
            Some(143),
            "the row carries the interrupted signal's lane code (§H.3): {row:?}"
        );
        assert_eq!(
            row.reason, "interrupted-mid-build",
            "the §H.3 reason key: {row:?}"
        );
        assert!(
            err.contains("no usable result for p1"),
            "the mapping is loud (§F.2): {err}"
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

    /// §F.1: a park stand-down marker that cannot be written is a broken
    /// handshake — the dispatched node settles LOUDLY as lost (125,
    /// `park-marker-unwritable`) instead of building on, its lane process
    /// group is killed so the rogue lane cannot keep building, and its late
    /// lane result is ignored (the row lands exactly once and never
    /// installs).
    #[test]
    fn an_unwritable_park_marker_settles_the_node_as_lost() {
        let dir = scratch("parklost");
        let run_id = format!("test-parklost-{}", std::process::id());
        // The stand-down channel is sabotaged up front: the `.park` path is
        // a DIRECTORY, so the marker write fails no matter when it runs.
        let run_dir = dir.join("state/runs").join(&run_id);
        std::fs::create_dir_all(run_dir.join("p2.result.park")).unwrap();
        // Coupled batch (no build-order edge): both lanes dispatch at once.
        // p1 fails immediately; p2 is still building when its stand-down is
        // demanded, later reports `ok` on the wire.
        let stub = write_stub(
            &dir,
            "stub-lane",
            "#!/usr/bin/env bash\n\
             case \"$2\" in\n\
             \x20 p1) printf 'v2 p1 1 1 build-failed\\n' >\"$3\"; exit 1 ;;\n\
             \x20 p2) printf '%s\\n' \"$$\" >\"$3.pid\"; sleep 2; : >\"$3.built\"; printf 'v2 p2 0 1 ok\\n' >\"$3\"; exit 0 ;;\n\
             esac\n\
             exit 0\n",
        );
        let mut setup = one_node_setup(&dir, &stub, "parklost");
        setup.run_id = run_id;
        setup.budget.lanes = 2;
        setup.nodes.push(SupNode {
            id: RecipeId::new("p2").expect("p2 is a valid id"),
            recipe_dir: dir.join("root/packages/p2"),
            core: false,
            build_tools: false,
            prereqs: Vec::new(),
            consumers: Vec::new(),
            batch: Some(0),
            pre: None,
            latent: false,
        });
        setup.nodes[0].batch = Some(0);
        setup.batches = vec![vec![0, 1]];

        let (outcome, finished, err) = run_watched(setup);
        assert_eq!(
            finished, 2,
            "exactly one Finished event per row: p1's failure plus the park-loss settle — the late ok must not settle again: {:?}",
            outcome.rows
        );
        let row = &outcome.rows[1];
        assert_eq!(row.pkg.as_str(), "p2");
        assert_eq!(
            (row.status, row.rc),
            (RowStatus::Failed, Some(125)),
            "a broken stand-down settles the node as lost (§F.1): {row:?}"
        );
        assert_eq!(
            row.reason, "park-marker-unwritable",
            "the reason names the broken handshake: {row:?}"
        );
        assert!(
            err.contains("cannot be written") && err.contains("park marker"),
            "the marker failure is loud: {err}"
        );
        assert!(
            err.contains("late lane result for p2 ignored"),
            "the late result of a settled node is ignored, loudly: {err}"
        );
        // The rogue lane must not build on past a stand-down that could not
        // be delivered: it never reached its build artifact, and its process
        // is gone (the broken-handshake path kills the lane's process group).
        assert!(
            !run_dir.join("p2.result.built").exists(),
            "the parked lane kept building after its stand-down failed — its process group must be killed"
        );
        // A lane killed before it could even record its pid (the kill can
        // land inside the pidfile write) is gone by definition; one that
        // recorded a pid must not survive it.
        if let Some(pid) = std::fs::read_to_string(run_dir.join("p2.result.pid"))
            .ok()
            .and_then(|text| text.trim().parse::<u32>().ok())
        {
            assert!(
                !std::path::Path::new(&format!("/proc/{pid}")).exists(),
                "the parked lane's process must be gone after the run settled (pid {pid})"
            );
        }
    }

    /// §H one-record rule: the live view and the run record are two views of
    /// ONE machine, bound by the event stream. Folding the captured events
    /// through [`Progress`] must reproduce the record's rows and `order`
    /// exactly — including the reordering that a settlement-ordered fold
    /// would get wrong (p1 is the slow lane, so completion order is not plan
    /// order).
    #[test]
    fn the_event_projection_equals_the_run_record() {
        let dir = scratch("projection");
        // Lanes publish through the codec's atomic rename; p1 holds its lane
        // while p2/p3 run and settle.
        let stub = write_stub(
            &dir,
            "stub-lane",
            "#!/usr/bin/env bash\n\
             pkg=$2\n\
             result=$3\n\
             if [ \"$pkg\" = p1 ]; then sleep 1; else sleep 0.05; fi\n\
             printf 'v2 %s 0 1 ok\\n' \"$pkg\" >\"$result.tmp.$$\"\n\
             mv \"$result.tmp.$$\" \"$result\"\n",
        );
        let ids: Vec<RecipeId> = ["p1", "p2", "p3"]
            .iter()
            .map(|name| RecipeId::new(*name).expect("test id"))
            .collect();
        let mut setup = one_node_setup(&dir, &stub, "projection");
        setup.budget.lanes = 2;
        for id in &ids[1..] {
            setup.nodes.push(SupNode {
                id: id.clone(),
                recipe_dir: dir.join("root/packages").join(id.as_str()),
                core: false,
                build_tools: false,
                prereqs: Vec::new(),
                consumers: Vec::new(),
                batch: None,
                pre: None,
                latent: false,
            });
        }

        let (outcome, events, err) = run_capturing(setup);
        assert!(
            err.is_empty() || !err.contains("gsa:"),
            "the run must settle cleanly: {err}"
        );
        let mut progress = crate::progress::Progress::new(ids.clone(), Vec::new());
        for event in &events {
            progress.observe(event);
        }

        // The completion order really is NOT plan order here: without the
        // reordering the equality below would be vacuous.
        let settled: Vec<&RecipeId> = events
            .iter()
            .filter_map(|event| match event {
                SupEvent::Finished { row, .. } => Some(&row.pkg),
                _ => None,
            })
            .collect();
        let planned: Vec<&RecipeId> = outcome.order.iter().collect();
        assert_ne!(
            settled, planned,
            "this fixture's lane timing is what makes the projection's ordering testable"
        );

        assert_eq!(
            progress.order(),
            outcome.order.as_slice(),
            "the projection's plan order must be the record's `order` (§H)"
        );
        assert_eq!(
            progress.rows(),
            outcome.rows.as_slice(),
            "the projection's settled rows must be the record's rows (§H)"
        );
        assert_eq!(progress.drift(&outcome.rows, &outcome.order), None);
        assert_eq!(progress.total(), 3);
        assert_eq!(progress.dispatched(), 3);
        assert_eq!(progress.succeeded(), 3);
        assert_eq!(progress.failed(), 0);
    }

    #[test]
    fn coupled_batch_mate_receives_park_marker_when_peer_is_lost() {
        let dir = scratch("coupled-lost-park");
        let stub = write_stub(
            &dir,
            "stub-lane",
            "#!/usr/bin/env bash\n\
             pkg=$2\n\
             result=$3\n\
             if [ \"$pkg\" = p2 ]; then exit 0; fi\n\
             sleep 0.4\n\
             printf 'v2 %s 0 1 ok\\n' \"$pkg\" >\"$result.tmp.$$\"\n\
             mv \"$result.tmp.$$\" \"$result\"\n",
        );
        let p2 = RecipeId::new("p2").unwrap();
        let mut setup = one_node_setup(&dir, &stub, "coupled-lost-park");
        setup.budget.lanes = 2;
        setup.nodes[0].batch = Some(0);
        setup.nodes.push(SupNode {
            id: p2.clone(),
            recipe_dir: dir.join("root/packages/p2"),
            core: false,
            build_tools: false,
            prereqs: Vec::new(),
            consumers: Vec::new(),
            batch: Some(0),
            pre: None,
            latent: false,
        });
        setup.batches = vec![vec![0, 1]];
        let run_dir = setup.state_dir.join("runs").join(&setup.run_id);

        let (_outcome, events, _err) = run_capturing(setup);
        assert!(
            run_dir.join("p1.result.park").exists(),
            "in-flight coupled mate p1 must receive a .park marker when p2 settles lost (125)"
        );
        assert!(
            events.iter().any(|e| matches!(
                e,
                SupEvent::Parked { index: 0, reason } if reason == "coupled-batch"
            )),
            "SupEvent::Parked(coupled-batch) must be emitted for p1: {events:?}"
        );
    }

    #[test]
    fn state_writes_refuse_symlinks_under_run_and_prefetch_log() {
        let dir = scratch("state-symlinks");
        let pf_victim = dir.join("pf-victim");
        let pf_log = dir.join("state/prefetch.log");
        std::os::unix::fs::symlink(&pf_victim, &pf_log).unwrap();
        let pf = Prefetcher::new(
            &PrefetchSetup {
                ahead: 1,
                candidacy: Vec::new(),
                log_path: pf_log,
            },
            0,
        );
        let mut pf_err = Vec::new();
        pf.note("should-not-follow", &mut pf_err);
        assert!(
            !pf_victim.exists(),
            "Prefetcher::note must refuse symlinked prefetch.log"
        );
        let pf_err_text = String::from_utf8_lossy(&pf_err);
        assert!(
            pf_err_text.contains("symlink"),
            "Prefetcher::note must warn on symlink refusal: {pf_err_text}"
        );

        let stub = write_stub(&dir, "noop-lane", "#!/usr/bin/env bash\nexit 0\n");
        let mut setup = one_node_setup(&dir, &stub, "started-symlink");
        setup.run_id = "r-sym".to_string();
        let rdir = setup.state_dir.join("runs").join(&setup.run_id);
        std::fs::create_dir_all(&rdir).unwrap();
        let started_victim = dir.join("started-victim");
        std::os::unix::fs::symlink(&started_victim, rdir.join("p1.started")).unwrap();
        let mut started_err = Vec::new();
        let _ = write_started(&setup, 0, 12345, 0, &mut started_err).unwrap_err();
        assert!(
            !started_victim.exists(),
            "write_started must refuse symlinked .started marker"
        );
    }

    #[test]
    fn settle_skip_polls_signals_between_ready_claims() {
        let dir = scratch("skip-signal");
        let stub = write_stub(&dir, "noop-lane", "#!/usr/bin/env bash\nexit 0\n");
        let mut setup = one_node_setup(&dir, &stub, "skip-signal");
        setup.nodes[0].pre = Some(PreSettle::Skip {
            reason: "skip-built".to_string(),
            archives: Vec::new(),
        });
        let p2 = RecipeId::new("p2").unwrap();
        setup.nodes.push(SupNode {
            id: p2,
            recipe_dir: dir.join("root/packages/p2"),
            core: false,
            build_tools: false,
            prereqs: Vec::new(),
            consumers: Vec::new(),
            batch: None,
            pre: Some(PreSettle::Skip {
                reason: "skip-built".to_string(),
                archives: Vec::new(),
            }),
            latent: false,
        });
        let installed: std::sync::Arc<std::sync::Mutex<Vec<String>>> =
            std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let installed_cb = std::sync::Arc::clone(&installed);
        setup.install = Some(Box::new(move |pkg, _, _| {
            installed_cb.lock().unwrap().push(pkg.to_string());
            if pkg == "p1" {
                let _ =
                    crate::signals::send_signal(std::process::id() as i32, crate::signals::SIGTERM);
                std::thread::sleep(Duration::from_millis(50));
            }
            InstallStep::Done("ok".to_string())
        }));

        let (outcome, _events, _err) = run_capturing(setup);
        assert!(outcome.interrupted);
        assert_eq!(
            *installed.lock().unwrap(),
            vec!["p1".to_string()],
            "second --skip node must not install after SIGTERM lands"
        );
    }
}
