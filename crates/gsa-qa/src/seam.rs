//! The hidden `--qa-check` seam (contract §D.1): the check registry's
//! single-entry point — run exactly ONE named check and print its findings.
//! Excluded from `--help` and from the continuation table (never mirrored);
//! callable only by fixtures.

use std::io::Write;
use std::path::Path;

use crate::input::{collect_archives, load_workspace, QaInput, QaInstalled};
use crate::{registry, Scope, Severity};

/// The seam's rc classes (contract §G): **0** — the check ran (report
/// findings never change rc; that is the report-only promise seen from the
/// seam); **2** — usage: no name, an unknown name (the known roster is
/// printed — a keyword is never auto-corrected), or an unknown recipe
/// reference; **3** — an install-refusing check found ≥1 finding: its
/// findings ARE refusals (§G.1's refusal class).
pub fn run_qa_check(
    argv: &[String],
    root: &Path,
    installed: &[QaInstalled],
    out: &mut dyn Write,
    err: &mut dyn Write,
) -> i32 {
    let registry = registry();
    let Some((name, refs)) = argv.split_first() else {
        let _ = writeln!(
            err,
            "gsa: --qa-check requires a check name (known: {})",
            registry.names().join(", ")
        );
        return 2;
    };
    let Some(handle) = registry.lookup(name) else {
        let _ = writeln!(
            err,
            "gsa: --qa-check: unknown check '{name}' (known: {})",
            registry.names().join(", ")
        );
        return 2;
    };

    let workspace = match load_workspace(root) {
        Ok(workspace) => workspace,
        Err(message) => {
            let _ = writeln!(err, "gsa: {message}");
            return 2;
        }
    };

    // Optional focus: exact recipe references (id or recipe path). A typo is
    // reported, never auto-corrected (contract §C.1).
    let mut targets: Vec<String> = Vec::new();
    for reference in refs {
        let found = workspace
            .recipes
            .iter()
            .find(|recipe| recipe.id == *reference || recipe.dir == root.join(reference));
        match found {
            Some(recipe) => targets.push(recipe.id.clone()),
            None => {
                let _ = writeln!(
                    err,
                    "gsa: --qa-check: unknown recipe reference '{reference}' (want a recipe id or recipe path)"
                );
                return 2;
            }
        }
    }

    // Scope-shaped input: an archive-scope check gets the workspace's built
    // archive sets (bounded to the focus); everything else needs none.
    let archives = match handle.scope() {
        Scope::Archive => collect_archives(&workspace.recipes, &targets),
        Scope::Recipe | Scope::InstalledDb | Scope::Topology => Vec::new(),
    };
    let input = QaInput {
        recipes: &workspace.recipes,
        targets: &targets,
        archives: &archives,
        installed,
        exclusions: &workspace.exclusions,
    };

    let result = handle.run(&input);
    for finding in &result.findings {
        let _ = writeln!(out, "{}", finding.render());
    }
    if let Some(reason) = &result.skipped {
        let _ = writeln!(out, "qa-check {}: skipped — {reason}", handle.name());
        return 0;
    }
    let tally = if result.findings.is_empty() {
        "clean".to_string()
    } else {
        format!("{} finding(s)", result.findings.len())
    };
    let _ = writeln!(out, "qa-check {}: {tally}", handle.name());
    if handle.severity() == Severity::InstallRefusing && !result.findings.is_empty() {
        3
    } else {
        0
    }
}
