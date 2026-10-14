//! Toolchain probes: the GCC build-identity drift gate and the rustc/cargo
//! sanity probe (`docs/build-guide.md` "Skip and resume",
//! `docs/gsa-contract.md` §B.8 `--allow-broken-rustc`).
//!
//! A recipe's recorded GCC build identity (`<state>/toolchains/<id>`,
//! written only after a successful build + VCS-baseline recording) that is
//! missing or changed forces a clean + rebuild even under `--skip` — stale
//! LTO objects must never survive a compiler identity change (2026-10-08
//! doxygen-git wall: ccache replayed stale LTO bytecode into the tree the
//! drift clean had just produced). The rustc sanity probe compiles a trivial
//! program and starts `cargo` to catch llvm-libs-git-vs-rust-git snapshot
//! ABI skew before any build runs (2026-09-07 – 09 LLVM snapshot recovery;
//! 2026-09-25: the run's own llvm-git install broke rustc after the
//! preflight had passed). A failing probe drives a remediation plan — a
//! narrow force-build chain escalating to the whole `core` group — and the
//! run refuses (rc 3 class, `docs/gsa-contract.md` §G.1) only when
//! remediation is impossible or its build failed (2026-10-02 owner rule:
//! remediation-by-rebuild, never abort-while-remediable).
//! `--allow-broken-rustc` skips the probe entirely; that decision belongs to
//! the caller (the CLI wiring), so this module never reads argv.
//!
//! The split is deliberate: policy functions are pure and testable, and the
//! only IO is PATH-resolved subprocesses (`gcc`, `rustc`, `cargo`, `pacman`)
//! plus reads/writes under caller-named directories — integration tests stub
//! the tools on `PATH` and keep all scratch under their own tree. The module
//! never reads `GSA_FAKE_*` (fixture-only vocabulary, contract §D.2).

use std::fmt;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::process::Command;

// ─── GCC build-identity drift gate ───────────────────────────────────────────

/// The GCC build identity recorded when no `gcc` is on `PATH` (the fish
/// reference's default behaviour, kept deliberately: a missing compiler is
/// not a refusal — the sentinel is recorded and compared like any other build
/// line, so installing or removing `gcc` later reads as drift and forces the
/// same one-time clean as a compiler upgrade).
pub const GCC_UNAVAILABLE_IDENTITY: &str = "gcc unavailable";

/// The current GCC build identity: the FIRST line of `LC_ALL=C gcc --version`,
/// resolved through `PATH` (never an absolute tool path, so fixtures can stub
/// `gcc`).
///
/// * `gcc` absent from `PATH` → `Ok(`[`GCC_UNAVAILABLE_IDENTITY`]`)`, the
///   fish default (absence is data, not an error).
/// * `gcc` present but `--version` failing or printing nothing → `Err`: the
///   fish builder refused the build ("could not determine the GCC build
///   identity"), and guessing a line here would let a marker freeze an
///   identity that never existed.
///
/// `LC_ALL=C` is pinned so the build line is locale-stable — a locale change
/// must never read as compiler drift.
pub fn gcc_identity() -> io::Result<String> {
    let output = match Command::new("gcc")
        .env("LC_ALL", "C")
        .arg("--version")
        .output()
    {
        Ok(output) => output,
        Err(err) if err.kind() == io::ErrorKind::NotFound => {
            return Ok(GCC_UNAVAILABLE_IDENTITY.to_string());
        }
        Err(err) => return Err(err),
    };
    if !output.status.success() {
        return Err(io::Error::other(format!(
            "could not determine the GCC build identity (gcc --version exited {})",
            output.status
        )));
    }
    let line = String::from_utf8_lossy(&output.stdout)
        .lines()
        .next()
        .unwrap_or_default()
        .to_string();
    if line.is_empty() {
        return Err(io::Error::other(
            "could not determine the GCC build identity (gcc --version printed nothing)",
        ));
    }
    Ok(line)
}

/// Where the per-recipe GCC identity marker lives:
/// `<state_dir>/toolchains/<recipe_id>` (`docs/gsa-contract.md` §J.1).
///
/// The recipe id comes from the topology loader, which already validates its
/// charset — this fn deliberately does not re-sanitise it, because silently
/// rewriting an id would let two ids share one marker.
pub fn marker_path(state_dir: &Path, recipe_id: &str) -> PathBuf {
    state_dir.join("toolchains").join(recipe_id)
}

/// Reads a recorded identity. `Ok(None)` = no marker exists. An unreadable
/// marker is `Err`, and [`check_identity`] collapses that to
/// [`IdentityState::Missing`] — always fail toward the one-time clean, never
/// toward "unchanged".
pub fn read_marker(state_dir: &Path, recipe_id: &str) -> io::Result<Option<String>> {
    match fs::read_to_string(marker_path(state_dir, recipe_id)) {
        Ok(contents) => Ok(Some(contents.trim_end_matches(['\n', '\r']).to_string())),
        Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(err) => Err(err),
    }
}

/// Records the current identity for `recipe_id`.
///
/// CALLER CONTRACT — the gate's whole point (`docs/build-guide.md` "Skip and
/// resume"): call this ONLY after the build succeeded AND its VCS revision
/// baseline has been recorded. A failed attempt must leave the previous
/// marker (or none) so the retry drifts again and re-cleans;
/// `tests/toolchain-drift.sh` pins exactly that. Nothing in this module
/// writes a marker on any other path.
///
/// The write is atomic (`<marker>.tmp.<pid>` + rename, mirroring the fish
/// `record_package_toolchain`) — a half-written marker must never read as
/// "unchanged". The build-user ownership gate (`docs/gsa-contract.md` §J.5)
/// is the wiring's to enforce around this call; this fn writes as the current
/// process user.
pub fn write_marker(state_dir: &Path, recipe_id: &str, identity: &str) -> io::Result<()> {
    if identity.is_empty() || identity.contains('\n') || identity.contains('\r') {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "GCC build identity must be a single non-empty line",
        ));
    }
    let path = marker_path(state_dir, recipe_id);
    let dir = path
        .parent()
        .expect("marker_path always yields <state>/toolchains/<id>");
    fs::create_dir_all(dir)?;
    let temporary = PathBuf::from(format!("{}.tmp.{}", path.display(), std::process::id()));
    let mut data = String::new();
    data.push_str(identity);
    data.push('\n');
    fs::write(&temporary, data)?;
    fs::rename(&temporary, &path).map_err(|err| {
        let _ = fs::remove_file(&temporary);
        err
    })
}

/// The drift-gate verdict, decided BEFORE any `--skip` decision.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum IdentityState {
    /// The recorded build line equals the current one — cached trees stay.
    Unchanged,
    /// The marker exists but its content is not exactly the current build
    /// line (the retired fish marker carried a recipe-path line too; any
    /// content mismatch is drift).
    Drifted {
        /// The marker content as read.
        previous: String,
        /// The build line measured now.
        current: String,
    },
    /// No readable marker — the one-time clean. A new state directory causes
    /// one clean per selected recipe BY DESIGN: relocating `GSA_STATE_DIR` is
    /// an intentional invalidation, not an accident.
    Missing,
}

impl IdentityState {
    /// Whether the wiring must clean + rebuild the recipe even under
    /// `--skip` — everything except [`IdentityState::Unchanged`].
    pub fn forces_clean_rebuild(&self) -> bool {
        !matches!(self, IdentityState::Unchanged)
    }
}

impl fmt::Display for IdentityState {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            IdentityState::Unchanged => write!(f, "GCC build identity unchanged"),
            IdentityState::Drifted { previous, current } => write!(
                f,
                "GCC build identity missing or changed; cleaning cached build artifacts \
                 (previous: {previous}; current: {current})"
            ),
            IdentityState::Missing => write!(
                f,
                "GCC build identity missing; cleaning cached build artifacts (one-time clean)"
            ),
        }
    }
}

/// The drift verdict for `recipe_id` against `current_identity` (obtained
/// from [`gcc_identity`]). Marker IO failure reads as
/// [`IdentityState::Missing`] — the safe direction.
pub fn check_identity(state_dir: &Path, recipe_id: &str, current_identity: &str) -> IdentityState {
    match read_marker(state_dir, recipe_id) {
        Ok(Some(previous)) if previous == current_identity => IdentityState::Unchanged,
        Ok(Some(previous)) => IdentityState::Drifted {
            previous,
            current: current_identity.to_string(),
        },
        Ok(None) | Err(_) => IdentityState::Missing,
    }
}

// ─── Drift-clean targets ─────────────────────────────────────────────────────

/// Everything an identity-drift clean of one recipe removes, as DATA: the
/// wiring performs the deletion — this module deletes no build artifacts.
/// That split is deliberate: the deletion site must run the ref-queryability
/// guard first (see [`clean_targets`]) and owns the error/UI channel.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CleanTargets {
    /// The `src/`, `pkg/`, `build/` trees at the recipe dir — listed whether
    /// or not they exist (`rm -rf` semantics, mirroring the fish clean).
    pub trees: Vec<PathBuf>,
    /// Existing top-level `*.pkg.tar.zst` archives of the recipe dir.
    pub archives: Vec<PathBuf>,
    /// Existing top-level `*.gsa-vcs-revisions` VCS revision records
    /// (the archives' baselines). The fish find names the narrower
    /// `*.pkg.tar.zst.gsa-vcs-revisions`; this engine sweeps every
    /// `.gsa-vcs-revisions` ending — an in-flight `*.gsa-vcs-revisions.tmp.*`
    /// manifest does not match that ending and belongs to the stale-runtime
    /// sweeper, not to a recipe clean.
    pub sidecars: Vec<PathBuf>,
}

/// Computes one recipe dir's drift-clean targets (top level only — the trees
/// cover their own recursion; classification mirrors `find -maxdepth 1 -type
/// f`).
///
/// ORDERING HARD RULE for the wiring (`docs/build-guide.md` "Skip and
/// resume"): when `--skip` might skip this recipe's current-mtime VCS
/// archive, resolve the selected refs BEFORE running this clean — an
/// unreachable ref must refuse while the archive and its VCS baseline still
/// exist. Cleaning first destroys the evidence the refusal needs.
pub fn clean_targets(recipe_dir: &Path) -> io::Result<CleanTargets> {
    let mut archives = Vec::new();
    let mut sidecars = Vec::new();
    for entry in fs::read_dir(recipe_dir)? {
        let entry = entry?;
        // `-type f` semantics: a symlinked archive is not a regular file and
        // the fish clean did not delete it either.
        if !entry.file_type()?.is_file() {
            continue;
        }
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if name.ends_with(".gsa-vcs-revisions") {
            sidecars.push(entry.path());
        } else if name.ends_with(".pkg.tar.zst") {
            archives.push(entry.path());
        }
    }
    archives.sort();
    sidecars.sort();
    Ok(CleanTargets {
        trees: vec![
            recipe_dir.join("src"),
            recipe_dir.join("pkg"),
            recipe_dir.join("build"),
        ],
        archives,
        sidecars,
    })
}

// ─── rustc/cargo sanity probe ────────────────────────────────────────────────

/// Outcome of [`rustc_sanity_probe`].
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ProbeStatus {
    /// The trivial compile and the cargo probe both succeeded — the toolchain
    /// is sane for this run.
    Ok,
    /// The probe does not engage: house `rust-git` is not installed (a distro
    /// rustc cannot be broken by an llvm-libs-git snapshot), or `rustc` is
    /// not on `PATH`.
    Skipped {
        /// Why the probe did not engage (operator-facing, log it).
        reason: String,
    },
    /// The toolchain is broken (or its probe scratch could not be managed).
    Failed {
        /// Operator-facing diagnosis: the llvm-libs-git/rust-git skew
        /// explanation, the recovery options, the `--allow-broken-rustc`
        /// bypass, and the captured tool output.
        detail: String,
    },
}

/// The one sanitisation rule the probe scratch name needs (kept verbatim from
/// the fish reference, 2026-09-07): rustc derives the crate name from the
/// output file, so only `[A-Za-z0-9_]` may appear in the per-user tag — every
/// other character becomes one `_`.
pub fn sanitize_user_tag(user: &str) -> String {
    user.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || c == '_' {
                c
            } else {
                '_'
            }
        })
        .collect()
}

/// The per-user probe scratch base under `tmpdir`:
/// `<tmpdir>/build_all_rustc_probe_<sanitized user>`. The user tag makes
/// user-mode and root-mode probe files disjoint by name — `/tmp`'s sticky
/// bit plus `fs.protected_regular=2` means even root cannot redirect over
/// another user's file, so name collisions must be impossible by
/// construction.
pub fn probe_scratch_base(tmpdir: &Path, user: &str) -> PathBuf {
    tmpdir.join(format!("build_all_rustc_probe_{}", sanitize_user_tag(user)))
}

/// The runtime scratch base: `$TMPDIR` (honoured exactly like the fish
/// reference; falls back to the platform temp dir) + [`probe_scratch_base`]
/// with `$USER` as the tag (`user` when unset). The wiring may instead call
/// [`probe_scratch_base`] with its resolved build user (`id -un`, or
/// `$SUDO_USER` under a root supervisor) — user resolution is ownership
/// policy and stays out of this module.
pub fn resolve_probe_scratch() -> PathBuf {
    let tmpdir = std::env::var_os("TMPDIR")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    let user = std::env::var("USER")
        .ok()
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| "user".to_string());
    probe_scratch_base(&tmpdir, &user)
}

/// `command -v` semantics for one program name: some `PATH` entry holds a
/// regular executable file of that name. PATH is resolved here (never an
/// absolute tool path) so fixtures can stub or withhold tools per test.
fn on_path(program: &str) -> bool {
    use std::os::unix::fs::PermissionsExt;

    let Some(path) = std::env::var_os("PATH") else {
        return false;
    };
    std::env::split_paths(&path).any(|dir| {
        fs::metadata(dir.join(program))
            .map(|meta| meta.is_file() && meta.permissions().mode() & 0o111 != 0)
            .unwrap_or(false)
    })
}

/// The two scratch files the probe owns, derived from the base the way the
/// fish reference names them (`<base>.rs`, `<base>.bin`).
fn probe_paths(scratch_base: &Path) -> (PathBuf, PathBuf) {
    let mut source = scratch_base.as_os_str().to_owned();
    source.push(".rs");
    let mut binary = scratch_base.as_os_str().to_owned();
    binary.push(".bin");
    (PathBuf::from(source), PathBuf::from(binary))
}

fn status_text(status: &std::process::ExitStatus) -> String {
    match status.code() {
        Some(code) => format!("exit status {code}"),
        None => "no exit status (signal termination)".to_string(),
    }
}

/// The shared ABI-skew diagnosis (the fish `check_rustc_sanity` text, kept
/// loud — the probe's verbatim incident message is part of the log contract,
/// `tests/toolchain-remediation.sh` asserts it). Every `Failed` detail embeds
/// it so no failure rendering can drop the recovery options.
const SKEW_NOTE: &str =
    "Almost certainly llvm-libs-git is NEWER than rust-git (LLVM snapshots have no
stable C++ ABI — see docs/NOTE.md 2026-09-07 – 09). Every build using rustc
in this run would fail or miscompile.
Recovery: downgrade-rebuild llvm-libs at the snapshot rust-git was built
against (old version in /var/log/pacman.log; procedure in docs/NOTE.md), or
rebuild the core group once a working bootstrap exists.
Bypass anyway: --allow-broken-rustc";

/// Removes the probe scratch (rm -f semantics) and folds any leftover into
/// the verdict: a leaked per-user probe file is exactly the user/root
/// collision hazard the per-user naming exists to prevent, so a probe that
/// otherwise passed still fails loudly rather than leaking silently (the fish
/// reference only warned — it had a UI channel; [`ProbeStatus`] is the only
/// channel here).
fn finish_probe(verdict: ProbeStatus, files: &[&Path]) -> ProbeStatus {
    let mut leftovers = Vec::new();
    for path in files {
        if path.exists() {
            match fs::remove_file(path) {
                Ok(()) => {}
                Err(err) => leftovers.push(format!("{} ({err})", path.display())),
            }
        }
    }
    if leftovers.is_empty() {
        return verdict;
    }
    let note = format!(
        "probe scratch could not be removed: {}",
        leftovers.join(", ")
    );
    match verdict {
        ProbeStatus::Failed { detail } => ProbeStatus::Failed {
            detail: format!("{detail}\n{note}"),
        },
        ProbeStatus::Skipped { reason } => ProbeStatus::Skipped {
            reason: format!("{reason}; {note}"),
        },
        ProbeStatus::Ok => ProbeStatus::Failed {
            detail: format!(
                "rustc sanity probe passed but {note} — refusing rather than leaking a \
                 per-user probe file into TMPDIR (the collision hazard the per-user \
                 naming exists to prevent, 2026-09-07)"
            ),
        },
    }
}

/// The rustc/cargo sanity probe (LLVM-snapshot ABI-skew guard).
///
/// Engagement (mirrors the fish `check_rustc_sanity` gates): the probe runs
/// ONLY when `pacman -Q rust-git` says the house rust-git is installed AND
/// `rustc` resolves on `PATH`; anything else is [`ProbeStatus::Skipped`] — a
/// distro rustc cannot be broken by an llvm-libs-git snapshot. `pacman` and
/// `rustc` are PATH-resolved (never absolute paths), and neither is invoked
/// before its gate passes.
///
/// The exact probes:
/// 1. trivial compile — `fn main() {}` written to `<scratch>.rs`, compiled
///    with `rustc -o <scratch>.bin <scratch>.rs` (the fish invocation,
///    verbatim);
/// 2. `cargo --version` — the documented cargo probe: the cheapest
///    invocation that still executes cargo's full startup path (shared-object
///    loading included), where the same snapshot skew surfaces, while needing
///    no workspace, no registry and no network. rust-git ships cargo, so a
///    cargo that cannot start while rust-git is installed is the same failure
///    class as a rustc that dies on a trivial compile — NOT a skip.
///
/// Scratch: [`resolve_probe_scratch`] (or a caller-chosen base via
/// [`probe_scratch_base`]); both scratch files are removed before returning
/// on every path.
///
/// `--allow-broken-rustc` is the CALLER's decision (contract §B.8: skip the
/// probe entirely as an escape hatch for runs that compile no Rust) — this
/// fn is pure capability and never reads argv or `GSA_FAKE_*`.
pub fn rustc_sanity_probe(scratch_base: &Path) -> ProbeStatus {
    match Command::new("pacman").args(["-Q", "rust-git"]).output() {
        Ok(output) if output.status.success() => {}
        Ok(output) => {
            return ProbeStatus::Skipped {
                reason: format!(
                    "house rust-git is not installed (pacman -Q rust-git: {})",
                    status_text(&output.status)
                ),
            };
        }
        Err(err) => {
            return ProbeStatus::Skipped {
                reason: format!(
                    "house rust-git could not be queried ({err}); treating it as not installed"
                ),
            };
        }
    }
    if !on_path("rustc") {
        return ProbeStatus::Skipped {
            reason: "rustc is not on PATH (pacman reports rust-git installed — check PATH)"
                .to_string(),
        };
    }

    let (probe_rs, probe_bin) = probe_paths(scratch_base);
    if let Err(err) = fs::write(&probe_rs, "fn main() {}\n") {
        return ProbeStatus::Failed {
            detail: format!(
                "cannot create rustc sanity probe {}: {err}",
                probe_rs.display()
            ),
        };
    }
    let verdict = probe_chain(&probe_rs, &probe_bin);
    finish_probe(verdict, &[&probe_rs, &probe_bin])
}

/// Both subprocess probes, in order: a failing rustc compile short-circuits
/// (cargo state cannot matter more than the compiler dying).
fn probe_chain(probe_rs: &Path, probe_bin: &Path) -> ProbeStatus {
    let compile = Command::new("rustc")
        .arg("-o")
        .arg(probe_bin)
        .arg(probe_rs)
        .output();
    match compile {
        Err(err) if err.kind() == io::ErrorKind::NotFound => {
            return ProbeStatus::Skipped {
                reason: "rustc is not on PATH".to_string(),
            };
        }
        Err(err) => {
            return ProbeStatus::Failed {
                detail: format!(
                    "rustc is BROKEN — cannot run a trivial compile (rustc: {err}).
{SKEW_NOTE}"
                ),
            };
        }
        Ok(output) if !output.status.success() => {
            return ProbeStatus::Failed {
                detail: format!(
                    "rustc is BROKEN — segfaults/heap-corrupts on a trivial compile (rustc {}).
{SKEW_NOTE}
--- rustc stderr ---
{}",
                    status_text(&output.status),
                    String::from_utf8_lossy(&output.stderr).trim()
                ),
            };
        }
        Ok(_) => {}
    }

    match Command::new("cargo").arg("--version").output() {
        Err(err) => ProbeStatus::Failed {
            detail: format!(
                "cargo probe failed — `cargo --version` could not run ({err}) while rust-git is installed.
{SKEW_NOTE}"
            ),
        },
        Ok(output) if output.status.success() => ProbeStatus::Ok,
        Ok(output) => ProbeStatus::Failed {
            detail: format!(
                "cargo probe failed — `cargo --version` did not succeed while rust-git is installed (cargo {}).
{SKEW_NOTE}
--- cargo stderr ---
{}",
                status_text(&output.status),
                String::from_utf8_lossy(&output.stderr).trim()
            ),
        },
    }
}

// ─── Remediation policy (2026-10-02 owner rule) ─────────────────────────────

/// A force-build remediation plan for a failing toolchain probe:
/// remediation-by-rebuild, never abort-while-remediable.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Remediation {
    /// Force-build exactly this chain (the implicated consumer) before
    /// anything else compiles with the broken tool.
    Narrow(Vec<String>),
    /// Force-build the whole `core` group — the general tool-clang/llvm
    /// consumer chain, not just rustc. Escalation never repeats a narrow
    /// attempt inside the core phase (`tests/toolchain-remediation.sh`
    /// scenario B pins one narrow attempt, then the whole group).
    Core(Vec<String>),
    /// No chain can be built (empty core roster and no narrow hit): the
    /// caller keeps the refusal contract — [`remediation_refusal_text`], the
    /// rc 3 class (`docs/gsa-contract.md` §G.1).
    Impossible,
}

/// The force-build plan for a failing probe (fish `toolchain_remediation_plan`,
/// escalated exactly): [`Remediation::Narrow`] with `chain = [broken_consumer]`
/// only when the broken consumer is non-empty, known to the topology AND a
/// consumer of `toolchain_pkg` in the topology's ABI direction; otherwise the
/// WHOLE `core` group (a consumer walk that fails maps to a `false` oracle —
/// fail closed toward `Core`, never toward a wrongly narrow chain); an empty
/// core roster yields [`Remediation::Impossible`].
///
/// `toolchain_pkg` documents which package the `is_consumer_of_toolchain`
/// oracle is bound to; the wiring closes over it. Mirroring the fish
/// `expand_consumers` closure (whose seed is its own first member), a probe
/// that implicates the toolchain package itself is NARROW when its closure
/// includes it — the oracle, not this fn, decides self-membership.
pub fn remediation_plan(
    toolchain_pkg: &str,
    broken_consumer: &str,
    known: &dyn Fn(&str) -> bool,
    is_consumer_of_toolchain: &dyn Fn(&str) -> bool,
    core_members: &[String],
) -> Remediation {
    debug_assert!(
        !toolchain_pkg.is_empty(),
        "remediation_plan needs a toolchain package to bind its oracles to"
    );
    if !broken_consumer.is_empty()
        && known(broken_consumer)
        && is_consumer_of_toolchain(broken_consumer)
    {
        return Remediation::Narrow(vec![broken_consumer.to_string()]);
    }
    if core_members.is_empty() {
        return Remediation::Impossible;
    }
    Remediation::Core(core_members.to_vec())
}

/// The ONE remaining probe-refusal prose (fish `probe_refusal_text`): used
/// when remediation is impossible or its build failed. Pure text — the caller
/// sets the abort state and stops dispatch, draining in-flight lanes.
pub fn remediation_refusal_text() -> &'static str {
    "  The selection must rebuild rust-git in the same pass before anything
  else compiles with rustc — stopping dispatch, draining in-flight lanes.
  Recovery: rebuild rust-git in the same run (add rust-git to the selection
  and resume with --skip), or downgrade-rebuild llvm-libs at the snapshot
  rust-git was built against.
"
}

/// Makes remediation targets dispatchable mid-run (fish
/// `force_queue_packages`): appends each `targets` id not already queued,
/// preserving existing order — ids already queued keep their topological
/// position. Returns how many ids were appended. The scheduler wires this
/// into its dispatch order AND its run-record order (the two lists the fish
/// builder appends to together), which is why the helper is order-only here.
pub fn force_queue(queue: &mut Vec<String>, targets: &[String]) -> usize {
    let mut added = 0;
    for target in targets {
        if !queue.contains(target) {
            queue.push(target.clone());
            added += 1;
        }
    }
    added
}
