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

    /// Letters whose presence is a terminal query/report action — combining
    /// one with a build modifier is a usage error (contract §B.1).
    fn terminal(self) -> &'static str {
        match self {
            Family::Q => "islopbautrg",
            Family::S => "silgwyu",
            Family::B => "l",
            Family::U => "",
            Family::M => "adilmshw",
        }
    }
}

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
    /// The staged workspace of a standalone-target run (plan-gsa-isolation.md
    /// W4). Set by `standalone::apply`, which also rewrites `targets` to the
    /// staged ids; `crate::resolve_workspace` prefers this root over
    /// workspace discovery.
    pub standalone_root: Option<PathBuf>,
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

const HIDDEN_SEAMS: [&str; 8] = [
    "--install-decide",
    "--lane-job",
    "--fetch-job",
    "--stale-lock-check",
    "--local-db-check",
    "--install-register",
    "--register-ignorepkg",
    "--qa-check",
];

fn is_range_token(token: &str) -> bool {
    token.contains("..")
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
        if family.terminal().contains(action) && !modifiers.is_empty() {
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
        output_mode: None,
        targets: Vec::new(),
        ranges: Vec::new(),
        deferred_flags: Vec::new(),
        fail_fast: false,
        lanes: None,
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
        allow_broken_rustc: false,
        standalone_root: None,
    };

    let mut rest = &args[1..];
    while let Some(token) = rest.first() {
        rest = &rest[1..];
        if token == "--" {
            inv.pacman_args = Some(rest.to_vec());
            break;
        }
        if let Some(flag) = token.strip_prefix("--") {
            let (name, value) = match flag.split_once('=') {
                Some((name, value)) => (name, Some(value.to_string())),
                None => (flag, None),
            };
            match name {
                "dry-run" => inv.dry_run = true,
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
                "allow-broken-rustc" => {
                    if value.is_some() {
                        return Err("flag '--allow-broken-rustc' takes no value".to_string());
                    }
                    inv.allow_broken_rustc = true;
                    inv.deferred_flags.push("--allow-broken-rustc".to_string());
                }
                "no-register-ignorepkg"
                | "noconfirm"
                | "quiet"
                | "verbose"
                | "fix"
                | "prune"
                | "backfill"
                | "add"
                | "remove"
                | "register-ignorepkg" => {
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
                "vcs-skip-tolerance" | "lanes" | "jobs" | "intensity" | "state-dir" | "config"
                | "tail" | "keep" | "show" | "prefetch-ahead" => {
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
                        "config" => inv.config = Some(value.clone()),
                        "prefetch-ahead" => inv.prefetch_ahead = Some(value.clone()),
                        "vcs-skip-tolerance" => inv.vcs_skip_tolerance = Some(value.clone()),
                        "tail" => inv.tail = Some(value.clone()),
                        "keep" => inv.keep = Some(value.clone()),
                        "show" => inv.show = Some(value.clone()),
                        _ => {}
                    }
                    inv.deferred_flags.push(format!("--{name}"));
                    let _ = value;
                }
                _ => {
                    return Err(format!(
                        "unknown flag '--{name}' (run 'gsa --help' for the roster)"
                    ))
                }
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
            assert!(message.contains("flag '--leaf' takes no value"), "{message}");
            assert!(!message.contains(spelling), "{message}");
            // The pre-family position refuses the same way (never echoes).
            let message = parse(&[spelling.to_string(), "-B".to_string()]).unwrap_err();
            assert!(message.contains("flag '--leaf' takes no value"), "{message}");
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
        let inv = parse_ok(&["-Sl", "22..38", "22..", "..15", "mesa-git", "fix..stuff"]);
        assert_eq!(inv.ranges, vec!["22..38", "22..", "..15", "fix..stuff"]);
        assert_eq!(inv.targets, vec!["mesa-git"]);
    }
}
