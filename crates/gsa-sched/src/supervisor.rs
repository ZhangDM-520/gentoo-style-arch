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
use crate::machine::{Machine, Node, ParkRequest, Policy, Recorded};
use crate::signals::{self, install_handlers, signal_group, signal_lane_code, SIGKILL};

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
}

/// Streaming dashboard events — the run record rows in motion. The dashboard
/// is a view of these; it never re-derives state (ADR 0003).
#[derive(Clone, Debug)]
pub enum SupEvent {
    Started { index: usize, jobs: u32, core: bool },
    Finished { index: usize, row: OutcomeRow },
    Parked { index: usize, reason: String },
    Signal(i32),
    Teardown(&'static str),
    Diagnostic(String),
}

pub struct SupOutcome {
    pub rows: Vec<OutcomeRow>,
    pub interrupted: bool,
    /// The signal's lane-code-class number (129/130/143) when interrupted.
    pub signal_code: i32,
}

enum Event {
    LaneDone { index: usize },
    Signal(i32),
    GraceExpired,
}

struct ActiveLane {
    pid: u32,
    term_sent: bool,
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
    setup: RunSetup,
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
                        // the kernel through the channel, never polled.
                        let _ = child.wait();
                        let _ = waiter_tx.send(Event::LaneDone {
                            index: waiter_index,
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

        let nothing_left = machine.active() == 0
            && (machine.finished() || interrupted.is_some() || machine.pick().is_empty());
        if nothing_left {
            break 'outer;
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
            Event::LaneDone { index } => {
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
                        if was_interrupted && !is_signal_report {
                            // §I.3: what started is `interrupted …` — a late
                            // ok/failed result cannot outvote the teardown.
                            continue 'outer;
                        }
                        let row = OutcomeRow {
                            pkg: machine.node(index).id.clone(),
                            status: match result.code {
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
                            rc: Some(result.code.code()),
                            dur: Some(result.dur as i64),
                            reason: result.reason.clone(),
                        };
                        events(&SupEvent::Finished {
                            index,
                            row: row.clone(),
                        });
                        let requests = machine.record(
                            index,
                            Recorded {
                                code: result.code,
                                dur: Some(result.dur as i64),
                                reason: result.reason,
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
                        if was_interrupted {
                            // Teardown killed the lane before it published;
                            // finalize_interrupted owns the row.
                            continue 'outer;
                        }
                        let message = format!(
                            "gsa: no usable result for {} — mapping to lost (125)",
                            machine.node(index).id
                        );
                        let _ = writeln!(err, "{message}");
                        events(&SupEvent::Diagnostic(message));
                        let row = OutcomeRow {
                            pkg: machine.node(index).id.clone(),
                            status: RowStatus::Failed,
                            rc: Some(125),
                            dur: None,
                            reason: "lane-lost".to_string(),
                        };
                        events(&SupEvent::Finished {
                            index,
                            row: row.clone(),
                        });
                        machine.record(
                            index,
                            Recorded {
                                code: gsa_model::LaneOutcome::Lost,
                                dur: None,
                                reason: "lane-lost".to_string(),
                            },
                        );
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
                }
            }
            Event::GraceExpired => {
                if interrupted.is_some() && !active.is_empty() {
                    events(&SupEvent::Teardown("grace expired — SIGKILL sweep"));
                    for lane in active.values() {
                        signal_group(lane.pid, SIGKILL);
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
                Ok(Event::LaneDone { index }) => {
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
        machine.finalize_interrupted(signal_lane_code(sig));
    } else if machine.finished() {
        // nothing to settle
    } else {
        if setup.policy == Policy::FailFast && machine.active() == 0 {
            machine.finalize_stopped();
        } else {
            machine.finalize_never_ready();
        }
    }

    Ok(SupOutcome {
        rows: machine.rows(),
        interrupted: interrupted.is_some(),
        signal_code: interrupted.map(signal_lane_code).unwrap_or(0),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn run_id_is_epoch_and_pid() {
        let id = run_id_now();
        let (epoch, pid) = id.split_once('-').unwrap();
        assert!(epoch.parse::<u64>().is_ok());
        assert_eq!(pid, std::process::id().to_string());
    }
}
