//! Signal receipt and teardown (contract §K.3).
//!
//! The first signal sends ONE `SIGTERM` to each lane's process group, starts
//! a shared grace window, then `SIGKILL`s survivors; a second signal
//! escalates immediately. Receipt is delivered to the supervisor loop as an
//! event: the handler is async-signal-safe (an atomic store plus one `write(2)`
//! to a self-pipe) and a reader thread forwards the byte onto the event
//! channel, so the supervisor never polls.
//!
//! The grace window is the fish engine's `_LANE_STOP_GRACE_S` seam carried
//! over unchanged: an unadvertised, non-roster override (`_GSA_STOP_GRACE_S`)
//! with a 30 s default — `docs/gsa-contract.md` §K.3 states the window but
//! names no knob (fixture gap G5), and fixtures must be able to tune it
//! without inventing an engine-side `GSA_*` input.

use std::io;
use std::os::unix::io::FromRawFd;
use std::sync::atomic::{AtomicI32, AtomicUsize, Ordering};

pub const SIGINT: i32 = 2;
pub const SIGHUP: i32 = 1;
pub const SIGTERM: i32 = 15;
pub const SIGKILL: i32 = 9;

/// The shared teardown grace window in seconds (§K.3).
pub const STOP_GRACE_DEFAULT_S: u64 = 30;

/// `_GSA_STOP_GRACE_S` — unadvertised fixture override, same class as the
/// fish engine's `_LANE_STOP_GRACE_S`. Unparsable values fall back to the
/// default (the fish rule).
pub fn stop_grace_seconds() -> u64 {
    match std::env::var("_GSA_STOP_GRACE_S") {
        Ok(v) if !v.is_empty() => v
            .parse::<u64>()
            .ok()
            .filter(|n| *n > 0)
            .unwrap_or(STOP_GRACE_DEFAULT_S),
        _ => STOP_GRACE_DEFAULT_S,
    }
}

/// Lane-code-class code for a signal number (contract §F.1: 129/130/143).
pub fn signal_lane_code(sig: i32) -> i32 {
    match sig {
        SIGHUP => 129,
        SIGINT => 130,
        SIGTERM => 143,
        _ => 130,
    }
}

extern "C" {
    /// `signal(2)`; the handler is a raw pointer so `SIG_DFL` (null) and a
    /// real handler share one declaration.
    fn signal(sig: i32, handler: usize) -> usize;
    fn kill(pid: i32, sig: i32) -> i32;
    #[link_name = "write"]
    fn write_byte(fd: i32, buf: *const std::ffi::c_void, count: usize) -> isize;
    fn pipe(fds: *mut i32) -> i32;
    fn flock(fd: i32, op: i32) -> i32;
    fn getuid() -> u32;
    fn fork() -> i32;
    fn setpgid(pid: i32, pgid: i32) -> i32;
    fn waitpid(pid: i32, status: *mut i32, options: i32) -> i32;
}

/// `SIG_DFL` — a terminated child must die on the teardown SIGTERM, so the
/// forked transaction child resets the receipt handlers to the default.
const SIG_DFL: usize = 0;

pub const LOCK_EX: i32 = 2;
pub const LOCK_NB: i32 = 4;

/// `flock(2)` on a raw fd (the run lock, contract §K).
pub fn flock_exclusive_nonblocking(fd: i32) -> bool {
    unsafe { flock(fd, LOCK_EX | LOCK_NB) == 0 }
}

/// `kill(2)` wrapper. A negative pid signals the whole process group.
pub fn send_signal(pid: i32, sig: i32) -> bool {
    unsafe { kill(pid, sig) == 0 }
}

/// Signal a lane's process group (contract §K.3: children run in their own
/// process group; teardown addresses the group).
pub fn signal_group(leader_pid: u32, sig: i32) {
    let _ = send_signal(-(leader_pid as i32), sig);
}

/// Where a [`fork_process_group`] call landed.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Forked {
    Parent { pid: u32 },
    Child,
}

/// Fork a supervised child that runs in its OWN process group (contract
/// §K.3: the teardown SIGTERM addresses that group). The child resets the
/// signal handlers to `SIG_DFL` first — the parent's self-pipe handlers must
/// not swallow the teardown signal inside the child. Call this before any
/// other thread exists (the child then runs single-threaded).
pub fn fork_process_group() -> Result<Forked, String> {
    let pid = unsafe { fork() };
    if pid < 0 {
        return Err(format!("fork failed: {}", std::io::Error::last_os_error()));
    }
    if pid == 0 {
        unsafe {
            setpgid(0, 0);
        }
        reset_signal_handlers();
        Ok(Forked::Child)
    } else {
        Ok(Forked::Parent { pid: pid as u32 })
    }
}

/// A waited child's end state.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ChildExit {
    Exited(i32),
    Signaled(i32),
}

/// Blocking `waitpid(2)` on one child — readiness is delivered by the kernel
/// (run it from a waiter thread, as the lane supervisor does).
pub fn wait_child(pid: u32) -> Result<ChildExit, String> {
    let mut status = 0i32;
    let reaped = unsafe { waitpid(pid as i32, &mut status, 0) };
    if reaped < 0 {
        return Err(format!(
            "waitpid({pid}) failed: {}",
            std::io::Error::last_os_error()
        ));
    }
    let low = status & 0x7f;
    if low == 0 {
        Ok(ChildExit::Exited((status >> 8) & 0xff))
    } else if low == 0x7f {
        Err(format!("child {pid} stopped instead of exiting"))
    } else {
        Ok(ChildExit::Signaled(low))
    }
}

/// Reset the three receipt handlers to `SIG_DFL` (forked children only).
pub fn reset_signal_handlers() {
    for sig in [SIGHUP, SIGTERM, SIGINT] {
        unsafe {
            signal(sig, SIG_DFL);
        }
    }
}

/// The build user (write-time ownership, rule 19): state files are created
/// as this uid and a wrong owner is repaired loudly, never silently adopted.
pub fn current_uid() -> u32 {
    unsafe { getuid() }
}

static PIPE_WRITE: AtomicI32 = AtomicI32::new(-1);
static SIGNAL_COUNT: AtomicUsize = AtomicUsize::new(0);
static FIRST_SIGNAL: AtomicI32 = AtomicI32::new(0);

extern "C" fn handle_signal(sig: i32) {
    SIGNAL_COUNT.fetch_add(1, Ordering::SeqCst);
    let _ = FIRST_SIGNAL.compare_exchange(0, sig, Ordering::SeqCst, Ordering::SeqCst);
    let fd = PIPE_WRITE.load(Ordering::SeqCst);
    if fd >= 0 {
        let byte = sig as u8;
        unsafe {
            write_byte(fd, &byte as *const u8 as *const std::ffi::c_void, 1);
        }
    }
}

/// How many signals the process has received (the second escalates, §K.3).
pub fn signal_count() -> usize {
    SIGNAL_COUNT.load(Ordering::SeqCst)
}

/// The first signal number received (its lane code labels the interrupted
/// rows), 0 when none.
pub fn first_signal() -> i32 {
    FIRST_SIGNAL.load(Ordering::SeqCst)
}

/// The read end of the self-pipe; the owner blocks on it and forwards each
/// byte as a signal event.
pub struct SignalPipe {
    pub read: std::fs::File,
}

/// The handler address for `signal(2)`: fn item → fn pointer → address (a
/// direct item-to-integer cast is not a stable operation).
fn handler_addr() -> usize {
    let handler: extern "C" fn(i32) = handle_signal;
    handler as usize
}

/// Simple receipt tracking for lane children (contract §K.3: "SIGHUP/SIGTERM/
/// SIGINT receipt by a child is reported through the lane codes 129/143/130"):
/// an async-signal-safe flag the child checks when its makepkg child exits.
pub fn install_receipt_handlers() {
    for sig in [SIGHUP, SIGTERM, SIGINT] {
        unsafe {
            signal(sig, handler_addr());
        }
    }
}

/// The signal a lane child last received, 0 when none.
pub fn received_signal() -> i32 {
    FIRST_SIGNAL.load(Ordering::SeqCst)
}

/// Test-only serialization for everything that installs or signals through
/// the process-global handlers: `install_handlers` owns ONE self-pipe per
/// process, so two handler-owning tests must never interleave.
#[cfg(test)]
pub static TEST_SIGNAL_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

/// Install handlers for SIGHUP/SIGTERM/SIGINT and return the self-pipe read
/// end. The handlers are process-global (one supervisor per process).
pub fn install_handlers() -> io::Result<SignalPipe> {
    let mut fds = [-1i32; 2];
    if unsafe { pipe(fds.as_mut_ptr()) } != 0 {
        return Err(io::Error::last_os_error());
    }
    PIPE_WRITE.store(fds[1], Ordering::SeqCst);
    for sig in [SIGHUP, SIGTERM, SIGINT] {
        unsafe {
            signal(sig, handler_addr());
        }
    }
    // fds[0] is the read end; owned as a File for the reader thread.
    let read = unsafe { std::fs::File::from_raw_fd(fds[0]) };
    Ok(SignalPipe { read })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lane_codes_follow_the_vocabulary() {
        assert_eq!(signal_lane_code(SIGHUP), 129);
        assert_eq!(signal_lane_code(SIGINT), 130);
        assert_eq!(signal_lane_code(SIGTERM), 143);
    }

    #[test]
    fn grace_default_is_thirty_seconds() {
        assert_eq!(STOP_GRACE_DEFAULT_S, 30);
        // Without the override the default applies; the test process does
        // not set one.
        std::env::remove_var("_GSA_STOP_GRACE_S");
        assert_eq!(stop_grace_seconds(), 30);
        std::env::set_var("_GSA_STOP_GRACE_S", "2");
        assert_eq!(stop_grace_seconds(), 2);
        std::env::set_var("_GSA_STOP_GRACE_S", "nonsense");
        assert_eq!(stop_grace_seconds(), 30);
        std::env::remove_var("_GSA_STOP_GRACE_S");
    }

    #[test]
    fn self_pipe_delivers_signal_receipt() {
        let _guard = TEST_SIGNAL_LOCK
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let pipe = install_handlers().expect("handlers install");
        std::thread::spawn(move || {
            let _ = send_signal(std::process::id() as i32, SIGTERM);
        });
        use std::io::Read;
        let mut read = pipe.read;
        let mut buf = [0u8; 1];
        read.read_exact(&mut buf).expect("signal byte arrives");
        assert_eq!(buf[0] as i32, SIGTERM);
        assert_eq!(first_signal(), SIGTERM);
        assert!(signal_count() >= 1);
    }
}
