//! Action-pass argv grammar (contract §B): `gsa <FAMILY>[cluster]
//! [long-modifiers] [targets…] [ranges…] [-- <pacman args…>]`.
//!
//! The argv is hand-rolled rather than clap-modelled because the grammar is
//! pacman's: one uppercase family plus a cluster of lowercase letters where a
//! single action letter combines with modifier letters in any position — a
//! shape clap's subcommand/flag model fights at every step.

use std::path::PathBuf;

/// The five action families (contract §B.2).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Family {
    Q,
    S,
    B,
    U,
    M,
}

impl Family {
    /// The roster, in contract order (completion's first-word order).
    pub const ALL: [Family; 5] = [Family::Q, Family::S, Family::B, Family::U, Family::M];

    pub fn as_str(self) -> &'static str {
        match self {
            Family::Q => "-Q",
            Family::S => "-S",
            Family::B => "-B",
            Family::U => "-U",
            Family::M => "-M",
        }
    }

    fn from_char(c: char) -> Option<Family> {
        match c {
            'Q' => Some(Family::Q),
            'S' => Some(Family::S),
            'B' => Some(Family::B),
            'U' => Some(Family::U),
            'M' => Some(Family::M),
            _ => None,
        }
    }

    /// Lowercase action letters of the family (none = the default action).
    fn actions(self) -> &'static str {
        match self {
            Family::Q => "islopbautrg",
            Family::S => "silgwyu",
            Family::B => "l",
            Family::U => "",
            Family::M => "adilmcshw",
        }
    }

    /// Modifier letters of the family.
    fn modifiers(self) -> &'static str {
        match self {
            Family::Q => "",
            Family::S => "fc",
            Family::B => "c",
            Family::U => "af",
            Family::M => "",
        }
    }
}

/// True when the letter is a TERMINAL query/report action of its family —
/// combining one with a build modifier is a usage error (contract §B.1).
/// Read from `ACTIONS`: the table is the roster, so a new letter carries its
/// own property instead of needing a second string edited in step.
pub fn action_is_terminal(family: Family, letter: char) -> bool {
    ACTIONS
        .iter()
        .any(|action| action.family == family && action.letter == letter && action.terminal)
}

/// One long modifier the action pass accepts (contract §B.8).
///
/// This table is the ROSTER: `parse` looks a `--name` up here before it
/// dispatches, so a flag that is absent can never parse and a flag that is
/// present can never be dead. Completion reads the same rows, which is why
/// there is no second list: the repo's "a deny-list and a delete-list are the
/// same list" rule applies to a grammar too.
pub struct FlagSpec {
    pub name: &'static str,
    /// Menu text for completion (`gsa -S --<TAB>`); never rendered by `--help`.
    pub description: &'static str,
    /// False = a bare boolean (`--name`); true = `--name <value>` or
    /// `--name=value`. The pin test in this module holds both shapes to what
    /// the parser actually does, so completion cannot offer the wrong one.
    pub takes_value: bool,
    /// The families whose documented surface names this flag. The parser is
    /// deliberately permissive (it accepts the whole roster and lets the
    /// dispatcher refuse a flag that does not apply), so this mask is the
    /// DOCUMENTED affinity, not a legality claim: it can only narrow a
    /// suggestion the documents already bind, and a flag with no stated home
    /// stays on every family.
    pub families: &'static [Family],
}

const ALL: &[Family] = &Family::ALL;
const BUILD: &[Family] = &[Family::S, Family::B];

impl FlagSpec {
    pub fn applies_to(&self, family: Family) -> bool {
        self.families.contains(&family)
    }
}

pub const FLAGS: &[FlagSpec] = &[
    FlagSpec {
        name: "dry-run",
        description: "plan only — build, install and write nothing",
        takes_value: false,
        families: BUILD,
    },
    FlagSpec {
        name: "leaf",
        description: "build exactly the named recipes, no consumer expansion",
        takes_value: false,
        families: BUILD,
    },
    FlagSpec {
        name: "machine",
        description: "force the machine block even on a terminal",
        takes_value: false,
        families: ALL,
    },
    FlagSpec {
        name: "help",
        description: "print the spelling roster and exit",
        takes_value: false,
        families: ALL,
    },
    FlagSpec {
        name: "skip",
        description: "skip recipes whose sources are unchanged (freshness-gated)",
        takes_value: false,
        families: BUILD,
    },
    FlagSpec {
        name: "skip-built",
        description: "skip recipes whose selection is already built",
        takes_value: false,
        families: BUILD,
    },
    FlagSpec {
        name: "no-sync",
        description: "do not refresh the recipe store first",
        takes_value: false,
        families: BUILD,
    },
    FlagSpec {
        name: "fail-fast",
        description: "stop dispatching on the first failure",
        takes_value: false,
        families: BUILD,
    },
    FlagSpec {
        name: "no-prefetch",
        description: "opt out of the dispatcher's fetch-ahead window",
        takes_value: false,
        families: BUILD,
    },
    FlagSpec {
        name: "no-build-dir-prompt",
        description: "never ask where the build cache should live",
        takes_value: false,
        families: &[Family::S, Family::B],
    },
    FlagSpec {
        name: "no-register-ignorepkg",
        description: "do not register accepted archives in IgnorePkg",
        takes_value: false,
        families: &[Family::S, Family::U],
    },
    FlagSpec {
        name: "allow-broken-rustc",
        description: "let a broken stock rustc preflight through",
        takes_value: false,
        families: BUILD,
    },
    FlagSpec {
        name: "noconfirm",
        description: "assume yes (non-interactive)",
        takes_value: false,
        families: ALL,
    },
    FlagSpec {
        name: "quiet",
        description: "suppress the progress lines",
        takes_value: false,
        families: ALL,
    },
    FlagSpec {
        name: "verbose",
        description: "more per-step detail",
        takes_value: false,
        families: ALL,
    },
    FlagSpec {
        name: "fix",
        description: "apply the named side-car repairs (-Md)",
        takes_value: false,
        families: &[Family::M],
    },
    FlagSpec {
        name: "prune",
        description: "drop stale IgnorePkg entries (-Mi)",
        takes_value: false,
        families: &[Family::M],
    },
    FlagSpec {
        name: "backfill",
        description: "add missing IgnorePkg entries (-Mi)",
        takes_value: false,
        families: &[Family::M],
    },
    FlagSpec {
        name: "register-ignorepkg",
        description: "register the named packages in IgnorePkg",
        takes_value: false,
        families: &[Family::M],
    },
    FlagSpec {
        name: "add",
        description: "add the named members to a set or to world",
        takes_value: false,
        families: &[Family::M],
    },
    FlagSpec {
        name: "remove",
        description: "remove the named members from a set or from world",
        takes_value: false,
        families: &[Family::M],
    },
    FlagSpec {
        name: "toolchain",
        description: "compiler family: gcc or clang",
        takes_value: true,
        families: BUILD,
    },
    FlagSpec {
        name: "lanes",
        description: "concurrent lane count (N or auto)",
        takes_value: true,
        families: BUILD,
    },
    FlagSpec {
        name: "jobs",
        description: "per-lane job count (N or auto)",
        takes_value: true,
        families: BUILD,
    },
    FlagSpec {
        name: "intensity",
        description: "scheduler intensity profile",
        takes_value: true,
        families: BUILD,
    },
    FlagSpec {
        name: "color",
        description: "colour for the human rendering: auto, always or never",
        takes_value: true,
        families: ALL,
    },
    FlagSpec {
        name: "state-dir",
        description: "state root (default /var/lib/gsa)",
        takes_value: true,
        families: ALL,
    },
    FlagSpec {
        name: "build-dir",
        description: "build cache (BUILDDIR/PKGDIR/PKGDEST)",
        takes_value: true,
        families: ALL,
    },
    FlagSpec {
        name: "config",
        description: "target pacman.conf for the transaction",
        takes_value: true,
        families: &[Family::S, Family::U],
    },
    FlagSpec {
        name: "prefetch-ahead",
        description: "fetch-ahead window size (default 8)",
        takes_value: true,
        families: BUILD,
    },
    FlagSpec {
        name: "vcs-skip-tolerance",
        description: "attempts before an unanswerable ref parks the recipe",
        takes_value: true,
        families: BUILD,
    },
    FlagSpec {
        name: "tail",
        description: "log lines to show (-Ml)",
        takes_value: true,
        families: &[Family::M],
    },
    FlagSpec {
        name: "keep",
        description: "log copies to retain (-Ml)",
        takes_value: true,
        families: &[Family::M],
    },
    FlagSpec {
        name: "show",
        description: "which run record to show (-Mh)",
        takes_value: true,
        families: &[Family::M],
    },
];

/// The roster lookup `parse` gates on and completion lists from.
pub fn flag_spec(name: &str) -> Option<&'static FlagSpec> {
    FLAGS.iter().find(|spec| spec.name == name)
}

/// One action letter (contract §B.1's cluster vocabulary).
///
/// `terminal` is the property `Family::terminal()` encodes: a terminal
/// query/report letter combines with no build modifier. The two `&'static
/// str` spellings stay hand-written for zero-cost `contains` checks and are
/// pinned equal to this table by a test — a letter added here without there
/// fails the suite.
pub struct ActionSpec {
    pub family: Family,
    pub letter: char,
    pub terminal: bool,
    /// Menu text for completion (`gsa -S --<TAB>`), the cluster spelling
    /// (`-Syu` is offered as the whole token, never `y` + `u`).
    pub description: &'static str,
}

pub const ACTIONS: &[ActionSpec] = &[
    ActionSpec {
        family: Family::Q,
        letter: 'i',
        terminal: true,
        description: "merged info: pacman fields plus the side-car record",
    },
    ActionSpec {
        family: Family::Q,
        letter: 's',
        terminal: true,
        description: "search installed names and descriptions",
    },
    ActionSpec {
        family: Family::Q,
        letter: 'l',
        terminal: true,
        description: "list owned files (pacman -Ql)",
    },
    ActionSpec {
        family: Family::Q,
        letter: 'o',
        terminal: true,
        description: "file owner (pacman -Qo)",
    },
    ActionSpec {
        family: Family::Q,
        letter: 'p',
        terminal: true,
        description: "archive probe against its index row",
    },
    ActionSpec {
        family: Family::Q,
        letter: 'b',
        terminal: true,
        description: "binpkg index rows the side-car records",
    },
    ActionSpec {
        family: Family::Q,
        letter: 'a',
        terminal: true,
        description: "ABI report: token, abi-rev, subscriptions",
    },
    ActionSpec {
        family: Family::Q,
        letter: 'u',
        terminal: true,
        description: "stale set: tracked version moved past the built one",
    },
    ActionSpec {
        family: Family::Q,
        letter: 't',
        terminal: true,
        description: "resolved topology records (id|path|groups|edges|tags)",
    },
    ActionSpec {
        family: Family::Q,
        letter: 'r',
        terminal: true,
        description: "revdep report over the installed ELF index",
    },
    ActionSpec {
        family: Family::Q,
        letter: 'g',
        terminal: true,
        description: "groups and sets with their members",
    },
    ActionSpec {
        family: Family::S,
        letter: 's',
        terminal: true,
        description: "search the buildable set",
    },
    ActionSpec {
        family: Family::S,
        letter: 'i',
        terminal: true,
        description: "info for the selection",
    },
    ActionSpec {
        family: Family::S,
        letter: 'l',
        terminal: true,
        description: "ordered selection listing with range indices",
    },
    ActionSpec {
        family: Family::S,
        letter: 'g',
        terminal: true,
        description: "groups and sets with their members",
    },
    ActionSpec {
        family: Family::S,
        letter: 'w',
        terminal: true,
        description: "fetch and verify sources only (no build, no install)",
    },
    ActionSpec {
        family: Family::S,
        letter: 'y',
        terminal: true,
        description: "version-sync pass only (rewrites stay uncommitted)",
    },
    ActionSpec {
        family: Family::S,
        letter: 'u',
        terminal: false,
        description: "update the stale set with no sync pass",
    },
    ActionSpec {
        family: Family::B,
        letter: 'l',
        terminal: true,
        description: "ordered selection listing (nothing is built)",
    },
    ActionSpec {
        family: Family::M,
        letter: 'a',
        terminal: true,
        description: "audit report (report-only)",
    },
    ActionSpec {
        family: Family::M,
        letter: 'd',
        terminal: true,
        description: "doctor: runtime-state reconciliation",
    },
    ActionSpec {
        family: Family::M,
        letter: 'i',
        terminal: true,
        description: "IgnorePkg closure of the target pacman.conf",
    },
    ActionSpec {
        family: Family::M,
        letter: 'l',
        terminal: true,
        description: "per-package log browse and tail",
    },
    ActionSpec {
        family: Family::M,
        letter: 'm',
        terminal: true,
        description: "shared-source mirrors (dedupe VCS clones)",
    },
    ActionSpec {
        family: Family::M,
        letter: 'c',
        terminal: false,
        description: "prune strength 1: src/pkg/build trees and archives",
    },
    ActionSpec {
        family: Family::M,
        letter: 's',
        terminal: true,
        description: "named sets: list, add, remove",
    },
    ActionSpec {
        family: Family::M,
        letter: 'h',
        terminal: true,
        description: "run history",
    },
    ActionSpec {
        family: Family::M,
        letter: 'w',
        terminal: true,
        description: "world: the explicitly wanted set",
    },
];

/// A hidden fixture seam (contract §D.1): excluded from `--help`, callable
/// only by fixtures, and every Phase 1 one is deferred.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Hidden {
    InstallDecide(Vec<String>),
    LaneJob(Vec<String>),
    FetchJob(Vec<String>),
    StaleLockCheck,
    LocalDbCheck(Vec<String>),
    InstallRegister(Vec<String>),
    RegisterIgnorepkg(Vec<String>),
    QaCheck(Vec<String>),
    /// `--build-identity <gcc|clang>`: the exact identity the toolchain
    /// drift marker records (§B.11). One line, so a "why did it clean?"
    /// question has an answer an operator or a fixture can diff.
    BuildIdentity(String),
    /// `--print-conf <gcc|clang>`: the built-in per-compiler makepkg body on
    /// stdout. The `gsa-pm` recipe writes it to `/etc/gsa/<family>-makepkg.conf`
    /// at package time, so the shipped file can never drift from the binary
    /// that reads it (rule 58: one source of truth, no copied flag text).
    PrintConf(Vec<String>),
    /// `--complete <words…>`: shell completion (contract §D.1). The words are
    /// the argv after the program name; the LAST one is the partial token
    /// being completed and may be empty. Advisory and fail-soft: it answers
    /// with candidates and rc 0, or with nothing at all.
    Complete(Vec<String>),
    /// `--print-completion <fish|bash|zsh>`: the wrapper text for one shell,
    /// which the `gsa-pm` recipe installs. Grammar-free by design — it calls
    /// `--complete` rather than restating the grammar in three languages.
    PrintCompletion(String),
    /// `--seam-roster`: the text-producing seams (`TEXT_SEAMS`) one per line,
    /// so the recipe battery can prove its packaging roster covers every one.
    /// Reads nothing, mutates nothing, needs no workspace.
    SeamRoster,
}

/// One parsed invocation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Invocation {
    pub family: Family,
    /// The one action letter, or None for the family's default action.
    pub action: Option<char>,
    pub modifiers: Vec<char>,
    /// `-Syu` (H9): the update run syncs first (`-Sy`, then the stale-set
    /// update). Plain `-Su` updates the stale set with NO sync pass — the
    /// committed versions and sums build as-is.
    pub sync_first: bool,
    pub dry_run: bool,
    pub leaf: bool,
    /// `--color=auto|always|never` (contract §B.8): the colour choice for the
    /// human rendering. The seam resolves the ladder; `--machine` still wins
    /// (a machine channel is never coloured).
    pub color: crate::style::ColorChoice,
    /// Output mode override (`--machine`).
    /// Unset: stdout's tty-ness picks human vs machine (output::mode()).
    pub output_mode: Option<crate::output::Mode>,
    pub targets: Vec<String>,
    pub ranges: Vec<String>,
    /// Recognised long modifiers from the contract's roster (§B.8) that a
    /// later phase owns. They parse so the refusal can name them; the
    /// dispatcher turns each into a "deferred" usage error.
    pub deferred_flags: Vec<String>,
    /// The five build-run modifiers (§B.8): real on a `-B` build, still
    /// deferred everywhere else. Values are raw; the budget resolver
    /// validates them (`--lanes N|auto`, …) and names the offender.
    pub fail_fast: bool,
    pub lanes: Option<String>,
    pub jobs: Option<String>,
    pub intensity: Option<String>,
    pub state_dir: Option<String>,
    /// `--toolchain gcc|clang` (§B.8): the run's compiler family, which
    /// selects the engine-owned makepkg body. Real on a build run; validated
    /// there, so a typo names the two alternatives instead of defaulting.
    pub toolchain: Option<String>,
    /// Fetch-ahead knobs (owner decision 1): `--no-prefetch` opts out of
    /// the dispatcher's background prefetch; `--prefetch-ahead N` bounds the
    /// lookahead window (default 8). Real on a build run; every other
    /// spelling keeps the deferred refusal.
    pub no_prefetch: bool,
    pub prefetch_ahead: Option<String>,
    /// `--skip`: skip-if-fresh resume (§B.8) — the freshness analysis
    /// (current-version set, VCS probes with waivers). Mutually exclusive
    /// with `--skip-built` (one skip MODE per run, like fish `skip_flag`).
    pub skip: bool,
    /// `--skip-built`: the built-set claim only — newest complete set at any
    /// version, no upstream probes, recipe-change gate (§B.8).
    pub skip_built: bool,
    /// `--vcs-skip-tolerance N` (raw; the freshness resolver validates and
    /// beats `GSA_VCS_SKIP_TOLERANCE`, §B.8). Positive integers only.
    pub vcs_skip_tolerance: Option<String>,
    /// `--no-sync`: build the committed version and sums as-is — no provider
    /// query, no anchoring, no rewrite (§B.8).
    pub no_sync: bool,
    /// `--build-dir PATH`: the build-cache root for this run (§J.2) — beats
    /// `GSA_BUILD_DIR` beats config `build_dir`. Also written by the prompt,
    /// so the run record's continuation restates the chosen root.
    pub build_dir: Option<String>,
    /// `--no-build-dir-prompt`: resolve the build root silently from the
    /// layers instead of asking on a TTY (the pre-prompt behaviour).
    pub no_build_dir_prompt: bool,
    /// `--no-register-ignorepkg`: skip dynamic IgnorePkg registration cleanly.
    pub no_register_ignorepkg: bool,
    /// `--allow-broken-rustc`: skip the rustc sanity probe entirely (§B.8;
    /// escape hatch for runs that compile no Rust).
    pub allow_broken_rustc: bool,
    /// `--config PATH`: the target pacman.conf of an install run (-S/-U) —
    /// the IgnorePkg registration target and the `pacman -U --config`.
    pub config: Option<String>,
    /// The maintain verbs' value sub-flags (contract §B.7): `--tail <ref>`
    /// and `--keep N` on `-Ml`, `--show <run-id>` on `-Mh`.
    pub tail: Option<String>,
    pub keep: Option<String>,
    pub show: Option<String>,
    /// Arguments after `--`, forwarded verbatim to a `pacman -U` transaction.
    pub pacman_args: Option<Vec<String>>,
    /// The staged workspace of a standalone-target run (docs/plans/plan-gsa-isolation.md
    /// W4). Set by `standalone::apply`, which also rewrites `targets` to the
    /// staged ids; `crate::resolve_workspace` prefers this root over
    /// workspace discovery.
    pub standalone_root: Option<PathBuf>,
    /// The ORIGINAL standalone tokens (the paths the user typed), kept beside
    /// the rewritten `targets`: the continuation restates the invocation, and
    /// a staged id names a workspace that no longer exists
    /// (blind-review finding, 2026-11-11).
    pub standalone_tokens: Vec<String>,
}

impl Invocation {
    /// Did the caller ask for the machine vocabulary explicitly
    /// (`--machine`)? A machine channel is never a dialogue: no prompt may
    /// run under it (see `prompt::interactive`).
    pub fn machine_requested(&self) -> bool {
        self.output_mode == Some(crate::output::Mode::Machine)
    }
}

impl Invocation {
    /// The restated spelling used by the continuation's `command:` line.
    pub fn spelling(&self) -> String {
        let mut spelling = self.family.as_str().to_string();
        if self.sync_first {
            spelling.push('y');
        }
        if let Some(action) = self.action {
            spelling.push(action);
        }
        for m in &self.modifiers {
            spelling.push(*m);
        }
        spelling
    }
}

/// The result of parsing argv: help, a real invocation, or a hidden seam.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Parsed {
    Help,
    Invoke(Invocation),
    Hidden(Hidden),
}

const HIDDEN_SEAMS: [&str; 13] = [
    "--install-decide",
    "--lane-job",
    "--fetch-job",
    "--stale-lock-check",
    "--local-db-check",
    "--install-register",
    "--register-ignorepkg",
    "--qa-check",
    "--build-identity",
    "--print-conf",
    "--complete",
    "--print-completion",
    "--seam-roster",
];

/// Seams whose verb is `--print-*`: they emit a file body that `gsa-pm` must
/// package (contract §D.1, ADR 0006). `gsa --seam-roster` publishes this list
/// so the recipe battery can diff its packaging roster against it — an engine
/// seam added without a `gsa-pm` row then fails that battery by name instead
/// of shipping to nobody (2026-11-11, the completion wrappers).
///
/// Deliberately NOT named `--print-something`: a `--print-*` name would make
/// the roster seam itself owe a shipped file.
pub const TEXT_SEAMS: [&str; 2] = ["--print-conf", "--print-completion"];

/// An INDEX range (contract §C.3): `N..M`, `N..`, `..M` — digits only. A
/// token that merely contains `..` is a path (`../x.pkg.tar.zst`,
/// `packages/../packages/foo`, `fix..stuff`): classifying it as a range
/// swallowed every relative path spelling and answered with a range error
/// (blind-review finding, 2026-11-11).
fn is_range_token(token: &str) -> bool {
    let Some((start, end)) = token.split_once("..") else {
        return false;
    };
    if end.contains("..") {
        return false;
    }
    let digits = |side: &str| side.is_empty() || side.chars().all(|c| c.is_ascii_digit());
    digits(start) && digits(end) && !(start.is_empty() && end.is_empty())
}

/// Parse the action pass. Every failure is a usage-class message; the caller
/// prints it and exits 2 (contract §G.1).
pub fn parse(args: &[String]) -> Result<Parsed, String> {
    let mut args = args.to_vec();
    if args.is_empty() {
        return Err("no action given".to_string());
    }

    // Word alias (contract §B.1): `gsa fetch` is exactly `gsa -Sw`.
    if args[0] == "fetch" {
        args[0] = "-Sw".to_string();
    }

    let first = args[0].as_str();
    if first == "--help" || first == "-h" {
        return Ok(Parsed::Help);
    }
    if first.starts_with("--") {
        if HIDDEN_SEAMS.contains(&first) {
            let rest: Vec<String> = args[1..].to_vec();
            let hidden = match first {
                "--install-decide" => Hidden::InstallDecide(rest),
                "--build-identity" => match rest.as_slice() {
                    [family] => Hidden::BuildIdentity(family.clone()),
                    [] => Hidden::BuildIdentity(String::new()),
                    [_, extra, ..] => {
                        return Err(format!(
                            "--build-identity takes exactly one family (gcc|clang), got extra '{extra}'"
                        ))
                    }
                },
                "--lane-job" => Hidden::LaneJob(rest),
                "--fetch-job" => Hidden::FetchJob(rest),
                "--stale-lock-check" => {
                    if let Some(extra) = rest.first() {
                        return Err(format!(
                            "--stale-lock-check takes no arguments (got '{extra}')"
                        ));
                    }
                    Hidden::StaleLockCheck
                }
                // `--local-db-check [health|runs]` (§D.1's seam, with the
                // run-history read of the §H.1 amendment): the verb list is
                // validated by the seam, which answers rc 2 on anything else.
                "--local-db-check" => Hidden::LocalDbCheck(rest),
                "--install-register" => Hidden::InstallRegister(rest),
                "--register-ignorepkg" => Hidden::RegisterIgnorepkg(rest),
                "--qa-check" => Hidden::QaCheck(rest),
                "--print-conf" => Hidden::PrintConf(rest),
                "--seam-roster" => {
                    if let Some(extra) = rest.first() {
                        return Err(format!(
                            "--seam-roster takes no arguments (got '{extra}')"
                        ));
                    }
                    Hidden::SeamRoster
                }
                "--complete" => Hidden::Complete(rest),
                "--print-completion" => match rest.as_slice() {
                    [shell] => Hidden::PrintCompletion(shell.clone()),
                    [] => Hidden::PrintCompletion(String::new()),
                    [_, extra, ..] => {
                        return Err(format!(
                            "--print-completion takes exactly one shell (fish|bash|zsh), got extra '{extra}'"
                        ))
                    }
                },
                _ => unreachable!(),
            };
            return Ok(Parsed::Hidden(hidden));
        }
        // §B.8 gap G4: the `--leaf=<value>` spellings are refused wherever
        // they appear and the refusal names `--leaf` WITHOUT echoing the
        // banned spelling (no engine output may contain it).
        if let Some((name, _)) = first.strip_prefix("--").unwrap_or("").split_once('=') {
            if name == "leaf" {
                return Err("flag '--leaf' takes no value".to_string());
            }
        }
        return Err(format!(
            "unknown flag '{first}' (a bare invocation needs a family: -Q, -S, -B, -U, -M)"
        ));
    }

    // Family + cluster.
    let mut chars = first.chars();
    let _ = chars.next(); // the leading '-'
    let Some(family_char) = chars.next() else {
        return Err(format!(
            "unknown family '{first}' (expected -Q, -S, -B, -U, or -M)"
        ));
    };
    if !first.starts_with('-') {
        return Err(format!(
            "unknown verb '{first}' (the only word alias is 'gsa fetch'; families are -Q, -S, -B, -U, -M)"
        ));
    }
    let Some(family) = Family::from_char(family_char) else {
        return Err(format!(
            "unknown family '{first}' (expected -Q, -S, -B, -U, or -M)"
        ));
    };
    let mut action: Option<char> = None;
    let mut modifiers: Vec<char> = Vec::new();
    let mut sync_first = false;
    for letter in chars {
        if family.actions().contains(letter) {
            // `-Mcc`/`-Mccc` repeat the prune-strength letter; every other
            // family takes exactly one action letter.
            if family == Family::M && letter == 'c' && modifiers.len() < 2 && action == Some('c') {
                modifiers.push('c');
                continue;
            }
            // `-Syu` is the one two-letter action (H9): the `y` is the
            // sync-first marker of the `u` update, spelled exactly `-Syu`.
            if family == Family::S && letter == 'u' && action == Some('y') {
                action = Some('u');
                sync_first = true;
                continue;
            }
            if action.is_some() {
                return Err(format!(
                    "only one action letter per invocation (already have '{}', got '{letter}')",
                    action.unwrap()
                ));
            }
            action = Some(letter);
        } else if family.modifiers().contains(letter) {
            modifiers.push(letter);
        } else {
            return Err(format!(
                "unknown option letter '{letter}' for family {} (actions: '{}', modifiers: '{}')",
                family.as_str(),
                family.actions(),
                family.modifiers()
            ));
        }
    }
    // Terminal query letters combine with no build modifier (contract §B.1).
    if let Some(action) = action {
        if action_is_terminal(family, action) && !modifiers.is_empty() {
            return Err(format!(
                "cannot combine the query letter '{action}' with build modifier(s) '{}' on {}",
                modifiers.iter().collect::<String>(),
                family.as_str()
            ));
        }
    }

    let mut inv = Invocation {
        family,
        action,
        modifiers,
        sync_first,
        dry_run: false,
        leaf: false,
        color: crate::style::ColorChoice::Auto,
        output_mode: None,
        targets: Vec::new(),
        ranges: Vec::new(),
        deferred_flags: Vec::new(),
        fail_fast: false,
        lanes: None,
        toolchain: None,
        jobs: None,
        intensity: None,
        state_dir: None,
        config: None,
        tail: None,
        keep: None,
        show: None,
        pacman_args: None,
        no_prefetch: false,
        prefetch_ahead: None,
        skip: false,
        skip_built: false,
        vcs_skip_tolerance: None,
        no_sync: false,
        build_dir: None,
        no_build_dir_prompt: false,
        no_register_ignorepkg: false,
        allow_broken_rustc: false,
        standalone_root: None,
        standalone_tokens: Vec::new(),
    };

    let mut rest = &args[1..];
    while let Some(token) = rest.first() {
        rest = &rest[1..];
        if token == "--" {
            // Forwarded verbatim to `pacman -U` and mirrored on ONE line in
            // the record's continuation (§H.2): a newline would break both.
            if rest.iter().any(|arg| arg.contains(['\n', '\r'])) {
                return Err(
                    "a pacman argument after '--' must be a single line (the run record restates it on one)"
                        .to_string(),
                );
            }
            // The transaction writes into the database its configuration
            // names (`--config`), and every gate reads exactly that one.
            // A forwarded argument that rebinds the database would install
            // into a DB nothing judged (blind-review 2026-11-11,
            // security-auditor F4b), so it is a usage error, not a passthrough.
            if let Some(name) = rest.iter().find_map(|arg| db_rebinding_pacman_arg(arg)) {
                return Err(format!(
                    "a pacman argument after '--' must not rebind the database ('{name}'): the install gates read the database of the engine's --config, so choose it with --config PATH instead"
                ));
            }
            inv.pacman_args = Some(rest.to_vec());
            break;
        }
        if let Some(flag) = token.strip_prefix("--") {
            let (name, value) = match flag.split_once('=') {
                Some((name, value)) => (name, Some(value.to_string())),
                None => (flag, None),
            };
            // The roster gate (contract §B.8): `FLAGS` decides what exists
            // here, so a name can never parse without being listed and can
            // never be listed without an arm below — the pin tests in this
            // module hold both directions.
            if flag_spec(name).is_none() {
                return Err(format!(
                    "unknown flag '--{name}' (run 'gsa --help' for the roster)"
                ));
            }
            match name {
                "dry-run" => {
                    // Every other boolean refuses a value; `--dry-run=yes`
                    // was the one tolerant spelling, which the roster pin
                    // test caught (a completion table cannot describe a flag
                    // whose shape depends on the operator's mood).
                    if value.is_some() {
                        return Err("flag '--dry-run' takes no value".to_string());
                    }
                    inv.dry_run = true;
                }
                "leaf" => {
                    // §B.8 gap G4: `--leaf` is the bare boolean — the only
                    // spelling. `--leaf=no`/`--leaf=yes` are not accepted
                    // and no engine output may contain them.
                    if value.is_some() {
                        return Err("flag '--leaf' takes no value".to_string());
                    }
                    inv.leaf = true;
                }
                "help" => return Ok(Parsed::Help),
                "machine" => {
                    if value.is_some() {
                        return Err("flag '--machine' takes no value".to_string());
                    }
                    inv.output_mode = Some(crate::output::Mode::Machine);
                }
                // The rest of the contract's roster (§B.8) and the maintain
                // verbs' own modifiers parse so the refusal names them.
                // The five §B.8 sync/freshness/toolchain modifiers are
                // stored AND recorded as deferred: real on a build run,
                // refused (naming them) everywhere else.
                "skip" => {
                    if value.is_some() {
                        return Err("flag '--skip' takes no value".to_string());
                    }
                    inv.skip = true;
                    inv.deferred_flags.push("--skip".to_string());
                }
                "skip-built" => {
                    if value.is_some() {
                        return Err("flag '--skip-built' takes no value".to_string());
                    }
                    inv.skip_built = true;
                    inv.deferred_flags.push("--skip-built".to_string());
                }
                "no-sync" => {
                    if value.is_some() {
                        return Err("flag '--no-sync' takes no value".to_string());
                    }
                    inv.no_sync = true;
                    inv.deferred_flags.push("--no-sync".to_string());
                }
                "no-build-dir-prompt" => {
                    if value.is_some() {
                        return Err(format!("flag '--{name}' takes no value"));
                    }
                    inv.no_build_dir_prompt = true;
                    inv.deferred_flags.push(format!("--{name}"));
                }
                "allow-broken-rustc" => {
                    if value.is_some() {
                        return Err("flag '--allow-broken-rustc' takes no value".to_string());
                    }
                    inv.allow_broken_rustc = true;
                    inv.deferred_flags.push("--allow-broken-rustc".to_string());
                }
                "no-register-ignorepkg" => {
                    if value.is_some() {
                        return Err(format!("flag '--{name}' takes no value"));
                    }
                    inv.no_register_ignorepkg = true;
                    inv.deferred_flags.push(format!("--{name}"));
                }
                "noconfirm" | "quiet" | "verbose" | "fix" | "prune" | "backfill" | "add"
                | "remove" | "register-ignorepkg" => {
                    if value.is_some() {
                        return Err(format!("flag '--{name}' takes no value"));
                    }
                    inv.deferred_flags.push(format!("--{name}"));
                }
                "fail-fast" => {
                    if value.is_some() {
                        return Err(format!("flag '--{name}' takes no value"));
                    }
                    inv.fail_fast = true;
                    // Recorded as deferred too: it is real only on a build
                    // run (§I.3); every other spelling still refuses it.
                    inv.deferred_flags.push(format!("--{name}"));
                }
                "no-prefetch" => {
                    if value.is_some() {
                        return Err(format!("flag '--{name}' takes no value"));
                    }
                    inv.no_prefetch = true;
                    inv.deferred_flags.push(format!("--{name}"));
                }
                "vcs-skip-tolerance" | "lanes" | "jobs" | "intensity" | "color" | "state-dir"
                | "config" | "tail" | "keep" | "show" | "prefetch-ahead" | "build-dir"
                | "toolchain" => {
                    let value = match value {
                        Some(v) => v,
                        None => {
                            let Some(next) = rest.first() else {
                                return Err(format!("flag '--{name}' requires a value"));
                            };
                            rest = &rest[1..];
                            next.clone()
                        }
                    };
                    // A path that carries a newline or carriage return
                    // cannot be restated on the record's one-line
                    // `command:` value (§H.2 forbids it): the continuation
                    // would advertise an unreplayable command and the
                    // machine block would break. Refuse at the flag.
                    if matches!(
                        name,
                        "state-dir"
                            | "build-dir"
                            | "config"
                            | "vcs-skip-tolerance"
                            | "toolchain"
                            | "prefetch-ahead"
                            | "lanes"
                            | "jobs"
                            | "intensity"
                    ) && value.contains(['\n', '\r'])
                    {
                        return Err(format!(
                            "flag '--{name}' must be a single line (the run record restates it on one)"
                        ));
                    }
                    // The four build-run value flags are stored as well as
                    // deferred: a `-B` build reads them (§B.8), every other
                    // spelling keeps the deferred refusal. `--config` rides
                    // along the same way: real on an install run (-S/-U);
                    // `--prefetch-ahead` is a build-run knob (owner
                    // decision 1).
                    match name {
                        "lanes" => inv.lanes = Some(value.clone()),
                        "jobs" => inv.jobs = Some(value.clone()),
                        "intensity" => inv.intensity = Some(value.clone()),
                        "state-dir" => inv.state_dir = Some(value.clone()),
                        "toolchain" => inv.toolchain = Some(value.clone()),
                        "color" => match crate::style::ColorChoice::parse(&value) {
                            Some(choice) => inv.color = choice,
                            None => {
                                return Err(format!(
                                    "flag '--color' takes {} (got '{value}')",
                                    crate::style::ColorChoice::SPELLINGS.join(", ")
                                ))
                            }
                        },
                        "build-dir" => inv.build_dir = Some(value.clone()),
                        "config" => inv.config = Some(value.clone()),
                        "prefetch-ahead" => inv.prefetch_ahead = Some(value.clone()),
                        "vcs-skip-tolerance" => inv.vcs_skip_tolerance = Some(value.clone()),
                        "tail" => inv.tail = Some(value.clone()),
                        "keep" => inv.keep = Some(value.clone()),
                        "show" => inv.show = Some(value.clone()),
                        _ => {}
                    }
                    // `--color` is a rendering choice every verb honours, so
                    // it is never a deferred run modifier (the flag gate in
                    // `classify` would otherwise refuse it on a query).
                    if name != "color" {
                        inv.deferred_flags.push(format!("--{name}"));
                    }
                    let _ = value;
                }
                // `flag_spec` above already refused every name that is not
                // in the roster, so an unlisted name can never reach here.
                _ => unreachable!("FLAGS entry '--{name}' has no parser arm"),
            }
            continue;
        }
        if token.starts_with('-') && token.len() > 1 {
            return Err(format!(
                "unknown short option '{token}' (short clusters go directly after the family, e.g. -Qt)"
            ));
        }
        if is_range_token(token) {
            inv.ranges.push(token.clone());
        } else {
            inv.targets.push(token.clone());
        }
    }
    // One skip MODE per invocation (§B.8; fish `skip_flag` is a mode, not a
    // boolean): the two claims are different analyses, not combinable.
    if inv.skip && inv.skip_built {
        return Err("cannot combine --skip with --skip-built (pick one skip claim: --skip is freshness-gated, --skip-built is the built-set claim)".to_string());
    }
    Ok(Parsed::Invoke(inv))
}

/// A forwarded `pacman -U` argument that would move the database the
/// transaction writes (`--dbpath`, `--root`, `--sysroot`, short `-b`/`-r`)
/// or name another configuration (`--config`). Every engine gate reads the
/// DB the engine's own `--config` names, so a forwarded override installs
/// into a database nothing judged (security-auditor F4b) — the caller
/// refuses it as a usage error. Returns the spelling the refusal names.
fn db_rebinding_pacman_arg(arg: &str) -> Option<&'static str> {
    const LONG: [(&str, &str); 4] = [
        ("--dbpath", "--dbpath"),
        ("--root", "--root"),
        ("--sysroot", "--sysroot"),
        ("--config", "--config"),
    ];
    for (flag, name) in LONG {
        let long_form = arg == flag
            || arg
                .strip_prefix(flag)
                .is_some_and(|rest| rest.starts_with('='));
        if long_form {
            return Some(name);
        }
    }
    // Short forms travel as `-b PATH` / `-r PATH` (in a cluster such as
    // `-fr` the value is still the next argument), never as a long option.
    if !arg.starts_with("--") && arg.starts_with('-') {
        return arg[1..].chars().find_map(|c| match c {
            'b' => Some("-b (--dbpath)"),
            'r' => Some("-r (--root)"),
            _ => None,
        });
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse_ok(args: &[&str]) -> Invocation {
        let owned: Vec<String> = args.iter().map(|s| s.to_string()).collect();
        match parse(&owned).unwrap() {
            Parsed::Invoke(inv) => inv,
            other => panic!("expected invocation, got {other:?}"),
        }
    }

    fn parse_err(args: &[&str]) -> String {
        let owned: Vec<String> = args.iter().map(|s| s.to_string()).collect();
        parse(&owned).unwrap_err()
    }

    #[test]
    fn families_and_clusters_parse() {
        let inv = parse_ok(&["-Qt"]);
        assert_eq!(inv.family, Family::Q);
        assert_eq!(inv.action, Some('t'));
        let inv = parse_ok(&["-Sfc", "@git", "22..38"]);
        assert_eq!(inv.family, Family::S);
        assert_eq!(inv.action, None);
        assert_eq!(inv.modifiers, vec!['f', 'c']);
        assert_eq!(inv.targets, vec!["@git"]);
        assert_eq!(inv.ranges, vec!["22..38"]);
        let inv = parse_ok(&["-Bl", "--leaf", "mesa-git"]);
        assert_eq!(inv.family, Family::B);
        assert_eq!(inv.action, Some('l'));
        assert!(inv.leaf);
    }

    #[test]
    fn bare_invocation_and_bad_families_are_usage_errors() {
        assert!(parse_err(&[]).contains("no action given"));
        assert!(parse_err(&["-qT"]).contains("unknown family"));
        assert!(parse_err(&["build"]).contains("only word alias"));
    }

    #[test]
    fn one_action_letter_only() {
        assert!(parse_err(&["-Sls"]).contains("only one action letter"));
    }

    #[test]
    fn query_letters_reject_build_modifiers() {
        assert!(parse_err(&["-Sfl"]).contains("cannot combine the query letter 'l'"));
        assert!(parse_err(&["-Bcl"]).contains("cannot combine the query letter 'l'"));
        // ...but the build default action takes them fine.
        assert!(parse_ok(&["-Sfc"]).action.is_none());
    }

    #[test]
    fn unknown_letters_and_flags_name_the_offender() {
        assert!(parse_err(&["-Qx"]).contains("unknown option letter 'x'"));
        assert!(parse_err(&["-Sl", "--frobnicate"]).contains("unknown flag '--frobnicate'"));
        assert!(parse_err(&["-Sl", "-x"]).contains("unknown short option '-x'"));
    }

    #[test]
    fn leaf_takes_no_value() {
        // §B.8 gap G4: bare `--leaf` is the only spelling; the `=value`
        // spellings are refused naming `--leaf`, and the refusal itself must
        // never echo a banned spelling (no engine output may contain one).
        let inv = parse_ok(&["-B", "--leaf", "mesa-git"]);
        assert!(inv.leaf);
        for spelling in ["--leaf=no", "--leaf=yes"] {
            let mut args = vec!["-B".to_string(), spelling.to_string()];
            args.push("mesa-git".to_string());
            let message = parse(&args).unwrap_err();
            assert!(
                message.contains("flag '--leaf' takes no value"),
                "{message}"
            );
            assert!(!message.contains(spelling), "{message}");
            // The pre-family position refuses the same way (never echoes).
            let message = parse(&[spelling.to_string(), "-B".to_string()]).unwrap_err();
            assert!(
                message.contains("flag '--leaf' takes no value"),
                "{message}"
            );
            assert!(!message.contains(spelling), "{message}");
        }
    }

    #[test]
    fn pacman_passthrough_and_fetch_alias() {
        let inv = parse_ok(&["-Ua", "--", "--overwrite", "*"]);
        assert_eq!(
            inv.pacman_args,
            Some(vec!["--overwrite".to_string(), "*".to_string()])
        );
        let owned: Vec<String> = vec!["fetch".to_string(), "mesa-git".to_string()];
        match parse(&owned).unwrap() {
            Parsed::Invoke(inv) => {
                assert_eq!(inv.family, Family::S);
                assert_eq!(inv.action, Some('w'));
                assert_eq!(inv.targets, vec!["mesa-git"]);
            }
            other => panic!("expected invocation, got {other:?}"),
        }
    }

    #[test]
    fn hidden_seams_parse_but_stay_hidden() {
        let owned: Vec<String> = ["--install-decide", "checked", "a.pkg.tar.zst"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        match parse(&owned).unwrap() {
            Parsed::Hidden(Hidden::InstallDecide(args)) => assert_eq!(args.len(), 2),
            other => panic!("expected hidden seam, got {other:?}"),
        }
        // `--stale-lock-check` takes no arguments (contract §D.1: an
        // invalid invocation is rc 2 with a message naming the argument).
        assert!(parse_err(&["--stale-lock-check", "extra"]).contains("takes no arguments"));
        assert!(matches!(
            parse(&["--stale-lock-check".to_string()]).unwrap(),
            Parsed::Hidden(Hidden::StaleLockCheck)
        ));
        // `--print-conf` carries its family through to the dispatcher, which
        // is what validates it (one family, gcc|clang).
        match parse(&["--print-conf".to_string(), "clang".to_string()]).unwrap() {
            Parsed::Hidden(Hidden::PrintConf(args)) => assert_eq!(args, vec!["clang"]),
            other => panic!("expected the print-conf seam, got {other:?}"),
        }
    }

    #[test]
    fn every_print_seam_is_in_the_text_roster() {
        // The invariant the recipe battery depends on: every `--print-*` seam
        // in HIDDEN_SEAMS is published by `--seam-roster` (TEXT_SEAMS), so a
        // new text seam cannot be added without the packaging roster seeing
        // it. A seam that prints text but ships nothing is the 2026-11-11
        // completion defect (ADR 0006).
        for seam in HIDDEN_SEAMS {
            if seam.starts_with("--print-") {
                assert!(
                    TEXT_SEAMS.contains(&seam),
                    "{seam} prints text but is missing from TEXT_SEAMS, so \
                     gsa-pm's packaging roster would never see it"
                );
            }
        }
        // And the reverse: TEXT_SEAMS names only real seams.
        for seam in TEXT_SEAMS {
            assert!(
                HIDDEN_SEAMS.contains(&seam),
                "TEXT_SEAMS names a dead seam: {seam}"
            );
        }
        // `--seam-roster` must not itself be a text seam, or it would owe a
        // shipped file and the rule would eat itself.
        assert!(!TEXT_SEAMS.contains(&"--seam-roster"));
    }

    #[test]
    fn seam_roster_takes_no_arguments_and_stays_hidden() {
        assert!(matches!(
            parse(&["--seam-roster".to_string()]).unwrap(),
            Parsed::Hidden(Hidden::SeamRoster)
        ));
        assert!(parse_err(&["--seam-roster", "x"]).contains("takes no arguments"));
    }

    #[test]
    fn every_roster_flag_parses_with_its_declared_shape() {
        // The roster is the gate, so a row the parser cannot reach is dead
        // and a row whose shape lies about the parser breaks completion.
        for spec in FLAGS {
            let flag = format!("--{}", spec.name);
            // `--color` is the one roster flag with a closed value set, so
            // the generic "v" probe cannot stand for a legal invocation.
            if spec.name == "color" {
                assert!(parse(&["-Q".to_string(), format!("{flag}=always")]).is_ok());
                assert!(
                    parse(&["-Q".to_string(), format!("{flag}=nope")]).is_err(),
                    "--color accepted a value outside its three rungs"
                );
                continue;
            }
            if spec.takes_value {
                assert!(
                    parse(&["-Q".to_string(), flag.clone(), "v".to_string()]).is_ok(),
                    "roster flag {flag} (takes_value) does not parse with a separate value"
                );
                assert!(
                    parse(&["-Q".to_string(), format!("{flag}=v")]).is_ok(),
                    "roster flag {flag} (takes_value) does not parse as --name=value"
                );
            } else {
                assert!(
                    parse(&["-Q".to_string(), flag.clone()]).is_ok(),
                    "roster flag {flag} (boolean) does not parse"
                );
                // `--help` short-circuits before any value check (it is the
                // spelling roster, not an invocation), so its shape is not
                // observable here.
                if spec.name != "help" {
                    let err = parse(&["-Q".to_string(), format!("{flag}=x")]).unwrap_err();
                    assert!(
                        err.contains("takes no value"),
                        "roster flag {flag} claims boolean but accepted a value: {err}"
                    );
                }
            }
        }
    }

    #[test]
    fn roster_flag_names_are_unique_and_prefixed_like_the_grammar() {
        for (index, spec) in FLAGS.iter().enumerate() {
            assert!(
                !spec.name.is_empty()
                    && spec
                        .name
                        .chars()
                        .all(|c| c.is_ascii_lowercase() || c == '-'),
                "roster name '{}' is not a long-flag spelling",
                spec.name
            );
            assert!(
                FLAGS[..index].iter().all(|other| other.name != spec.name),
                "duplicate roster entry '{}'",
                spec.name
            );
            // A description is completion menu text: one line, no field tabs.
            assert!(
                !spec.description.contains('\t') && !spec.description.contains('\n'),
                "roster description for '{}' would break the candidate line",
                spec.name
            );
        }
    }

    #[test]
    fn every_roster_flag_is_documented_in_help() {
        // Contract §L.1: `gsa --help` is the authoritative spelling roster, so
        // a flag the parser accepts (and completion offers) must appear there —
        // otherwise it exists only in the table. Two documented exceptions:
        // `--help` is the invocation itself (never listed in its own output),
        // and the deferred `--register-ignorepkg` long modifier, whose public
        // spelling is `gsa -Mi --backfill` (§D.1 keeps the seam for fixtures).
        let undocumented = ["help", "register-ignorepkg"];
        let help = crate::help::render();
        for spec in FLAGS {
            if undocumented.contains(&spec.name) {
                continue;
            }
            let needle = format!("--{}", spec.name);
            assert!(
                help.contains(&needle),
                "roster flag {needle} is not in `gsa --help`, so it exists only in FLAGS (§L.1)"
            );
        }
    }

    #[test]
    fn every_roster_flag_names_at_least_one_family() {
        // A row with no family can never be offered: completion filters by the
        // documented affinity, so an empty mask is a dead entry.
        for spec in FLAGS {
            assert!(
                !spec.families.is_empty(),
                "roster flag '--{}' applies to no family",
                spec.name
            );
            for family in Family::ALL {
                if spec.applies_to(family) {
                    assert!(spec.families.contains(&family));
                }
            }
        }
    }

    #[test]
    fn action_letters_and_terminality_come_from_the_roster() {
        for family in Family::ALL {
            let letters: String = ACTIONS
                .iter()
                .filter(|action| action.family == family)
                .map(|action| action.letter)
                .collect();
            assert_eq!(
                family.actions(),
                letters,
                "{}: the hand-written cluster string and ACTIONS disagree",
                family.as_str()
            );
            for action in ACTIONS.iter().filter(|action| action.family == family) {
                assert_eq!(
                    action_is_terminal(family, action.letter),
                    action.terminal,
                    "{}: terminality of '{}' disagrees with the roster",
                    family.as_str(),
                    action.letter
                );
                // Every roster action is a cluster the parser accepts on its
                // own, so completion can never offer a dead letter.
                let token = format!(
                    "-{}{}",
                    family.as_str().trim_start_matches('-'),
                    action.letter
                );
                assert!(
                    parse(&[token.clone()]).is_ok(),
                    "roster action {token} does not parse"
                );
            }
        }
        assert!(
            !action_is_terminal(Family::M, 'c'),
            "the prune-strength letter is not a terminal query"
        );
    }

    #[test]
    fn completion_seams_parse_their_payload() {
        match parse(&["--complete".to_string(), "-S".to_string()]).unwrap() {
            Parsed::Hidden(Hidden::Complete(words)) => assert_eq!(words, vec!["-S"]),
            other => panic!("expected the complete seam, got {other:?}"),
        }
        // An empty argv is the first-word position, not a usage error: the
        // seam answers "which families", so the wrapper can call it always.
        match parse(&["--complete".to_string()]).unwrap() {
            Parsed::Hidden(Hidden::Complete(words)) => assert!(words.is_empty()),
            other => panic!("expected the complete seam, got {other:?}"),
        }
        match parse(&["--print-completion".to_string(), "fish".to_string()]).unwrap() {
            Parsed::Hidden(Hidden::PrintCompletion(shell)) => assert_eq!(shell, "fish"),
            other => panic!("expected the print-completion seam, got {other:?}"),
        }
        assert!(parse_err(&["--print-completion", "fish", "bash"]).contains("exactly one shell"));
    }

    #[test]
    fn register_ignorepkg_seam_parses_first_token_only() {
        // `gsa --register-ignorepkg [conf]` is a hidden seam (first token);
        // the same spelling as a trailing flag stays a long modifier so a
        // continuation can classify it.
        let owned: Vec<String> = ["--register-ignorepkg", "some.conf"]
            .iter()
            .map(|s| s.to_string())
            .collect();
        match parse(&owned).unwrap() {
            Parsed::Hidden(Hidden::RegisterIgnorepkg(args)) => {
                assert_eq!(args, vec!["some.conf".to_string()])
            }
            other => panic!("expected hidden seam, got {other:?}"),
        }
        match parse(&["--register-ignorepkg".to_string()]).unwrap() {
            Parsed::Hidden(Hidden::RegisterIgnorepkg(args)) => assert!(args.is_empty()),
            other => panic!("expected hidden seam, got {other:?}"),
        }
        let inv = parse_ok(&["-Mi", "--register-ignorepkg"]);
        assert!(inv
            .deferred_flags
            .iter()
            .any(|f| f == "--register-ignorepkg"));
    }

    #[test]
    fn config_value_flag_is_captured_for_install_runs() {
        let inv = parse_ok(&["-U", "--config", "/etc/pacman.conf", "mesa-git"]);
        assert_eq!(inv.config.as_deref(), Some("/etc/pacman.conf"));
        let inv = parse_ok(&["-S", "--config=/scratch/p.conf", "mesa-git"]);
        assert_eq!(inv.config.as_deref(), Some("/scratch/p.conf"));
    }

    #[test]
    fn a_forwarded_pacman_argument_may_not_rebind_the_database() {
        // The engine's gates judge the DB its own `--config` names; a
        // forwarded override would transact into a database nothing read.
        let inv = parse_ok(&["-U", "mesa-git", "--", "--overwrite", "*"]);
        assert_eq!(
            inv.pacman_args.as_deref(),
            Some(&["--overwrite".to_string(), "*".to_string()][..])
        );
        for args in [
            vec!["-U", "--", "--dbpath", "/scratch/db"],
            vec!["-U", "--", "--dbpath=/scratch/db"],
            vec!["-Uf", "--", "-b", "/scratch/db"],
            vec!["-U", "--", "--root", "/scratch/root"],
            vec!["-U", "--", "-r", "/scratch/root"],
            vec!["-U", "--", "--sysroot=/scratch/root"],
            vec!["-U", "--", "-fr", "/scratch/root"],
            vec!["-U", "--", "--config", "/scratch/pacman.conf"],
            vec!["-U", "--", "--config=/scratch/pacman.conf"],
        ] {
            let message = parse_err(&args);
            assert!(
                message.contains("must not rebind the database"),
                "{args:?} must refuse: {message}"
            );
        }
    }

    #[test]
    fn build_run_modifiers_are_captured() {
        let inv = parse_ok(&[
            "-B",
            "--fail-fast",
            "--lanes",
            "2",
            "--jobs=auto",
            "--intensity",
            "high",
            "--state-dir",
            "/scratch/state",
            "mesa-git",
        ]);
        assert!(inv.fail_fast);
        assert_eq!(inv.lanes.as_deref(), Some("2"));
        assert_eq!(inv.jobs.as_deref(), Some("auto"));
        assert_eq!(inv.intensity.as_deref(), Some("high"));
        assert_eq!(inv.state_dir.as_deref(), Some("/scratch/state"));
        // They still record as deferred: only a real build accepts them.
        assert!(inv.deferred_flags.iter().any(|f| f == "--fail-fast"));
        assert!(inv.deferred_flags.iter().any(|f| f == "--state-dir"));
    }

    #[test]
    fn prefetch_flags_parse_and_are_build_run_deferred_elsewhere() {
        let inv = parse_ok(&["-B", "--no-prefetch", "--prefetch-ahead", "2", "mesa-git"]);
        assert!(inv.no_prefetch);
        assert_eq!(inv.prefetch_ahead.as_deref(), Some("2"));
        // Stored as well as deferred: a build run reads them, every other
        // spelling keeps the deferred refusal (§B.8 pattern).
        assert!(inv.deferred_flags.iter().any(|f| f == "--no-prefetch"));
        assert!(inv.deferred_flags.iter().any(|f| f == "--prefetch-ahead"));
        // `--no-prefetch` takes no value; `--prefetch-ahead` requires one.
        assert!(parse_err(&["-B", "--no-prefetch=2"]).contains("takes no value"));
        assert!(parse_err(&["-B", "--prefetch-ahead"]).contains("requires a value"));
    }

    #[test]
    fn range_tokens_are_classified_by_shape() {
        let inv = parse_ok(&["-Sl", "22..38", "22..", "..15", "mesa-git"]);
        assert_eq!(inv.ranges, vec!["22..38", "22..", "..15"]);
        assert_eq!(inv.targets, vec!["mesa-git"]);
        // A `..` inside a NAME is a target, not a range: the documented
        // grammar is numeric (§C.3), and a path spelling must reach path
        // classification instead of a range error.
        let inv = parse_ok(&["-Sl", "fix..stuff", "../pkg.tar.zst"]);
        assert!(inv.ranges.is_empty(), "{:?}", inv.ranges);
        assert_eq!(inv.targets, vec!["fix..stuff", "../pkg.tar.zst"]);
    }

    #[test]
    fn su_accepts_build_modifiers_and_show_prompt_help_rosters_match_contract() {
        for cluster in ["-Suf", "-Suc", "-Syuf", "-Syuc"] {
            let inv = parse_ok(&[cluster]);
            assert_eq!(inv.action, Some('u'));
            assert!(!inv.modifiers.is_empty());
        }
        assert_eq!(
            flag_spec("no-build-dir-prompt").unwrap().families,
            &[Family::S, Family::B]
        );
        let show_desc = flag_spec("show").unwrap().description;
        assert!(show_desc.contains("-Mh"), "{show_desc}");
    }

    #[test]
    fn mirrored_value_flags_reject_newlines() {
        for flag in ["--toolchain", "--vcs-skip-tolerance", "--prefetch-ahead"] {
            let err = parse_err(&["-B", flag, "bad\nvalue", "mesa-git"]);
            assert!(
                err.contains("must be a single line"),
                "{flag} allowed newline: {err}"
            );
        }
    }
}
