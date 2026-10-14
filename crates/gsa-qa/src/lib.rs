//! `gsa-qa` — the QA check REGISTRY (contract §E.4, `plan-native-pm.md`
//! §5.3, the `bin/install-qa-check.d/` analogue): one declaration surface of
//! named checks, each with a stable kebab keyword, a scope, a SEVERITY
//! ATTRIBUTE and a check function.
//!
//! Two severity classes exist and the type system keeps them apart:
//!
//! * `report` (the DEFAULT, [`ReportOnly`]) — findings are observations. They
//!   are appended to the run record's prose summary and can never become a
//!   decision row. The five audit lints (`lib/audit.fish`'s semantics, ported
//!   natively over `.SRCINFO`/`.PKGINFO`/ELF — never bash evaluation) live
//!   here, and CONTEXT.md's "Audit lint is report-only by contract" is
//!   enforced in CODE: the only constructor of a `refuse` row takes a
//!   [`Check<MayRefuse>`], a type those five cannot occupy
//!   ([`gate::install_refusals`]).
//! * `install-refusing` ([`MayRefuse`]) — findings render as `refuse
//!   <keyword> …` decision rows in the ONE install decision seam
//!   (`docs/MEMORY.md` rule 20; `gsa-install`'s `plan()` consults this
//!   registry and nothing else re-decides). A new `MayRefuse` check must
//!   state in its change why `report` is insufficient (contract §E.4).
//!
//! Three seam surfaces ride the registry:
//!
//! * [`seam::run_qa_check`] — the hidden `--qa-check <name>` seam (§D.1):
//!   exactly one named check, its findings on stdout, rc per §G (0 = ran
//!   (report findings never change rc), 2 = usage/unknown name, 3 = an
//!   install-refusing check found ≥1 finding).
//! * [`gate::install_refusals`] — the install-seam hook: refusing checks emit
//!   `refuse` rows into the existing decision row stream (never a second
//!   seam).
//! * [`report`] — the report surface: `report`-severity findings appended to
//!   the run record's prose summary (plus the `qa-findings:` extension
//!   scalar, §H.2 — an additive scalar after the fixed set, so `format: 2`
//!   stays valid; the same "extension scalar" precedent as
//!   `prefetch-warnings`).

pub mod abi;
pub mod checks;
pub mod gate;
pub mod input;
pub mod report;
pub mod seam;

use std::fmt;
use std::marker::PhantomData;

pub use input::{QaArchive, QaInput, QaInstalled, QaRecipe, Workspace};

/// What a check reads (the task's scope vocabulary: recipe / archive /
/// installed-DB / topology). Contract §E.4 names a coarser
/// `recipe|topology|host|install` set; the mapping is 1:1 in spirit
/// (recipe→recipe, archive→install, installed-DB→host, topology→topology)
/// and the finer split is what the checks actually consume.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Scope {
    /// Committed `.SRCINFO` of the workspace recipes.
    Recipe,
    /// Built `.pkg.tar.zst` archives beside the recipes (`.PKGINFO` + ELF).
    Archive,
    /// The pacman installed database (names, provides, depends).
    InstalledDb,
    /// `config/topology.conf` records and build-order edges.
    Topology,
}

impl Scope {
    pub fn as_str(self) -> &'static str {
        match self {
            Scope::Recipe => "recipe",
            Scope::Archive => "archive",
            Scope::InstalledDb => "installed-db",
            Scope::Topology => "topology",
        }
    }
}

impl fmt::Display for Scope {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// The severity attribute of a check (contract §E.4 `report|refuse`; the
/// refusing class is named `install-refusing` here because that is exactly
/// what it can do).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Severity {
    Report,
    InstallRefusing,
}

impl Severity {
    pub fn as_str(self) -> &'static str {
        match self {
            Severity::Report => "report",
            Severity::InstallRefusing => "install-refusing",
        }
    }
}

impl fmt::Display for Severity {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

/// Severity marker: this check's findings are report-only. It has NO path to
/// a decision row — [`gate`] accepts only [`Check<MayRefuse>`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ReportOnly;

/// Severity marker: this check MAY emit `refuse` rows at the install seam.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct MayRefuse;

/// Which severity a marker stands for (sealed by construction: only the two
/// markers implement it).
pub trait SeverityClass: sealed::Sealed {
    const SEVERITY: Severity;
}

impl SeverityClass for ReportOnly {
    const SEVERITY: Severity = Severity::Report;
}

impl SeverityClass for MayRefuse {
    const SEVERITY: Severity = Severity::InstallRefusing;
}

mod sealed {
    pub trait Sealed {}
    impl Sealed for super::ReportOnly {}
    impl Sealed for super::MayRefuse {}
}

/// One finding of one check: `<check>: <subject>: <detail>` when rendered —
/// the report line's stable shape (`lib/audit.fish`'s `<lint>: <label>: …`
/// framing with the check's stable keyword as the prefix).
#[derive(Clone, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct Finding {
    /// The check's stable kebab keyword (also the finding prefix).
    pub check: &'static str,
    pub subject: String,
    pub detail: String,
}

impl Finding {
    pub fn render(&self) -> String {
        format!("{}: {}: {}", self.check, self.subject, self.detail)
    }
}

impl fmt::Display for Finding {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.render())
    }
}

/// What one check run produced: findings (deduped + sorted by rendered line)
/// and an optional "skipped" witness (a check that could not probe its input
/// says so out loud — fish's `skipped — …` class — instead of reporting a
/// vacuous clean).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct CheckResult {
    pub findings: Vec<Finding>,
    pub skipped: Option<String>,
}

impl CheckResult {
    pub fn clean() -> CheckResult {
        CheckResult::default()
    }

    pub fn skipped(reason: impl Into<String>) -> CheckResult {
        CheckResult {
            findings: Vec::new(),
            skipped: Some(reason.into()),
        }
    }

    /// Accumulate one finding.
    pub fn with(mut self, subject: impl Into<String>, detail: impl Into<String>) -> Self {
        self.findings.push(Finding {
            check: "",
            subject: subject.into(),
            detail: detail.into(),
        });
        self
    }

    /// Finish a result: stamp the check keyword on every finding, then
    /// dedupe and sort (fish `sort -u` — row order never leaks into output).
    pub fn finish(mut self, check: &'static str) -> CheckResult {
        for finding in &mut self.findings {
            finding.check = check;
        }
        self.findings.sort();
        self.findings.dedup();
        self
    }
}

/// A check function: pure over its supplied input ([`QaInput`]) — all I/O
/// (recipe files, archives, the installed DB) is assembled by the caller.
type CheckFn = fn(&QaInput<'_>) -> CheckResult;

/// One registered check. `S` is the severity marker: the report-only and the
/// install-refusing classes are distinct TYPES, so a report check cannot be
/// passed anywhere a refusing check is required (and vice versa).
pub struct Check<S> {
    /// The stable kebab keyword: the `--qa-check` name, the finding prefix,
    /// and the first reason token of a `refuse` row (contract §E.3/§E.4).
    pub name: &'static str,
    pub scope: Scope,
    run: CheckFn,
    _severity: PhantomData<S>,
}

impl<S: SeverityClass> Check<S> {
    pub fn severity(&self) -> Severity {
        S::SEVERITY
    }

    /// Run the check over its input.
    pub fn run(&self, input: &QaInput<'_>) -> CheckResult {
        (self.run)(input).finish(self.name)
    }
}

/// Declare a `report`-severity check (the DEFAULT class).
pub const fn report_check(name: &'static str, scope: Scope, run: CheckFn) -> Check<ReportOnly> {
    Check {
        name,
        scope,
        run,
        _severity: PhantomData,
    }
}

/// Declare an `install-refusing` check. Every use must state in its change
/// why `report` is insufficient (contract §E.4).
pub const fn refusing_check(name: &'static str, scope: Scope, run: CheckFn) -> Check<MayRefuse> {
    Check {
        name,
        scope,
        run,
        _severity: PhantomData,
    }
}

/// One registered check as the two named seams see it (name lookup).
pub enum CheckHandle<'a> {
    Report(&'a Check<ReportOnly>),
    Refusing(&'a Check<MayRefuse>),
}

impl CheckHandle<'_> {
    pub fn name(&self) -> &'static str {
        match self {
            CheckHandle::Report(c) => c.name,
            CheckHandle::Refusing(c) => c.name,
        }
    }

    pub fn scope(&self) -> Scope {
        match self {
            CheckHandle::Report(c) => c.scope,
            CheckHandle::Refusing(c) => c.scope,
        }
    }

    pub fn severity(&self) -> Severity {
        match self {
            CheckHandle::Report(c) => c.severity(),
            CheckHandle::Refusing(c) => c.severity(),
        }
    }

    pub fn run(&self, input: &QaInput<'_>) -> CheckResult {
        match self {
            CheckHandle::Report(c) => c.run(input),
            CheckHandle::Refusing(c) => c.run(input),
        }
    }
}

/// The registry: every declared check, in its severity class.
pub struct Registry {
    report: Vec<Check<ReportOnly>>,
    refusing: Vec<Check<MayRefuse>>,
}

impl Registry {
    /// Resolve one check by its stable keyword (exact match — a keyword is
    /// never auto-corrected).
    pub fn lookup(&self, name: &str) -> Option<CheckHandle<'_>> {
        if let Some(check) = self.report.iter().find(|c| c.name == name) {
            return Some(CheckHandle::Report(check));
        }
        if let Some(check) = self.refusing.iter().find(|c| c.name == name) {
            return Some(CheckHandle::Refusing(check));
        }
        None
    }

    /// Every stable keyword, sorted (the usage roster for unknown names).
    pub fn names(&self) -> Vec<&'static str> {
        let mut names: Vec<&'static str> = self.report.iter().map(|c| c.name).collect();
        names.extend(self.refusing.iter().map(|c| c.name));
        names.sort_unstable();
        names
    }

    /// The report-only checks (the report surface's whole roster).
    pub fn report_checks(&self) -> &[Check<ReportOnly>] {
        &self.report
    }

    /// The install-refusing checks (the install gate's whole roster). This
    /// slice is the ONLY source of refuse-row construction
    /// ([`gate::install_refusals`]).
    pub fn refusing_checks(&self) -> &[Check<MayRefuse>] {
        &self.refusing
    }
}

/// The one registry (contract §E.4: every check declares name, scope,
/// severity and a stable keyword). Order here is the declaration order;
/// every output path sorts before printing.
pub fn registry() -> Registry {
    Registry {
        report: vec![
            report_check(
                "provides-versioning",
                Scope::Recipe,
                checks::provides_versioning,
            ),
            report_check("purged-tools", Scope::Recipe, checks::purged_tools),
            report_check("swap-drift", Scope::InstalledDb, checks::swap_drift),
            report_check("abi-closure", Scope::Archive, checks::abi_closure),
            report_check("abi-exposure", Scope::InstalledDb, checks::abi_exposure),
            report_check("declared-deps", Scope::Archive, checks::declared_deps),
        ],
        refusing: vec![refusing_check(
            "stale-ignorepkg",
            Scope::Archive,
            checks::stale_ignorepkg,
        )],
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_check_declares_name_scope_severity_and_a_keyword_is_kebab() {
        let registry = registry();
        let mut seen = std::collections::BTreeSet::new();
        for name in registry.names() {
            assert!(
                name.chars().all(|c| c.is_ascii_lowercase() || c == '-'),
                "{name} is not a stable kebab keyword"
            );
            assert!(seen.insert(name), "{name} declared twice");
            let handle = registry.lookup(name).expect("declared name must resolve");
            let _ = (handle.scope(), handle.severity());
        }
    }

    #[test]
    fn the_five_audit_lints_are_report_only() {
        let registry = registry();
        for name in [
            "provides-versioning",
            "purged-tools",
            "swap-drift",
            "abi-closure",
            "abi-exposure",
        ] {
            let handle = registry.lookup(name).expect("lint must be registered");
            assert_eq!(
                handle.severity(),
                Severity::Report,
                "{name} must stay report-only (CONTEXT.md 'Audit lint')"
            );
            assert!(
                registry.refusing_checks().iter().all(|c| c.name != name),
                "{name} must never appear in the refusing roster"
            );
        }
    }

    #[test]
    fn unknown_names_do_not_resolve() {
        let registry = registry();
        assert!(registry.lookup("provides-version").is_none());
        assert!(registry.lookup("").is_none());
        assert!(registry.lookup("STALE-IGNOREPKG").is_none());
    }
}
