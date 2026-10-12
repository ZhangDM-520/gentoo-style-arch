//! Action-pass argv grammar (contract §B): `gsa <FAMILY>[cluster]
//! [long-modifiers] [targets…] [ranges…] [-- <pacman args…>]`.
//!
//! The argv is hand-rolled rather than clap-modelled because the grammar is
//! pacman's: one uppercase family plus a cluster of lowercase letters where a
//! single action letter combines with modifier letters in any position — a
//! shape clap's subcommand/flag model fights at every step.

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
            Family::Q => "islopbautr",
            Family::S => "silgwyu",
            Family::B => "l",
            Family::U => "",
            Family::M => "adilmcsh",
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
            Family::Q => "islopbautr",
            Family::S => "silgwyu",
            Family::B => "l",
            Family::U => "",
            Family::M => "adilmsh",
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
    LocalDbCheck,
    InstallRegister(Vec<String>),
    QaCheck(Vec<String>),
}

impl Hidden {
    pub fn spelling(&self) -> String {
        match self {
            Hidden::InstallDecide(_) => "--install-decide".to_string(),
            Hidden::LaneJob(_) => "--lane-job".to_string(),
            Hidden::FetchJob(_) => "--fetch-job".to_string(),
            Hidden::StaleLockCheck => "--stale-lock-check".to_string(),
            Hidden::LocalDbCheck => "--local-db-check".to_string(),
            Hidden::InstallRegister(_) => "--install-register".to_string(),
            Hidden::QaCheck(_) => "--qa-check".to_string(),
        }
    }
}

/// One parsed invocation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Invocation {
    pub family: Family,
    /// The one action letter, or None for the family's default action.
    pub action: Option<char>,
    pub modifiers: Vec<char>,
    pub dry_run: bool,
    pub leaf: bool,
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
    /// Arguments after `--`, forwarded verbatim to a `pacman -U` transaction.
    pub pacman_args: Option<Vec<String>>,
}

impl Invocation {
    /// The restated spelling used by the continuation's `command:` line.
    pub fn spelling(&self) -> String {
        let mut spelling = self.family.as_str().to_string();
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

const HIDDEN_SEAMS: [&str; 7] = [
    "--install-decide",
    "--lane-job",
    "--fetch-job",
    "--stale-lock-check",
    "--local-db-check",
    "--install-register",
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
                "--local-db-check" => Hidden::LocalDbCheck,
                "--install-register" => Hidden::InstallRegister(rest),
                "--qa-check" => Hidden::QaCheck(rest),
                _ => unreachable!(),
            };
            return Ok(Parsed::Hidden(hidden));
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
    for letter in chars {
        if family.actions().contains(letter) {
            // `-Mcc`/`-Mccc` repeat the prune-strength letter; every other
            // family takes exactly one action letter.
            if family == Family::M && letter == 'c' && modifiers.len() < 2 && action == Some('c') {
                modifiers.push('c');
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
        dry_run: false,
        leaf: false,
        targets: Vec::new(),
        ranges: Vec::new(),
        deferred_flags: Vec::new(),
        fail_fast: false,
        lanes: None,
        jobs: None,
        intensity: None,
        state_dir: None,
        pacman_args: None,
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
                "leaf" => inv.leaf = true,
                "help" => return Ok(Parsed::Help),
                // The rest of the contract's roster (§B.8) and the maintain
                // verbs' own modifiers parse so the refusal names them.
                "skip"
                | "skip-built"
                | "no-sync"
                | "allow-broken-rustc"
                | "no-register-ignorepkg"
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
                "vcs-skip-tolerance" | "lanes" | "jobs" | "intensity" | "state-dir" | "config"
                | "tail" | "keep" | "show" => {
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
                    // spelling keeps the deferred refusal.
                    match name {
                        "lanes" => inv.lanes = Some(value.clone()),
                        "jobs" => inv.jobs = Some(value.clone()),
                        "intensity" => inv.intensity = Some(value.clone()),
                        "state-dir" => inv.state_dir = Some(value.clone()),
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
    fn range_tokens_are_classified_by_shape() {
        let inv = parse_ok(&["-Sl", "22..38", "22..", "..15", "mesa-git", "fix..stuff"]);
        assert_eq!(inv.ranges, vec!["22..38", "22..", "..15", "fix..stuff"]);
        assert_eq!(inv.targets, vec!["mesa-git"]);
    }
}
