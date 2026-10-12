//! The `--qa-check` seam wiring and the install-run QA report surface
//! (contract §D.1, §E.4): the engine-side assembly for the `gsa-qa` check
//! registry — workspace + installed-DB input — and the prose-summary block
//! of `report`-severity findings. The registry itself, its checks and their
//! severity enforcement live in `gsa-qa`; this module only gathers input and
//! renders nothing itself.

use std::io::Write;

use gsa_qa::input::{collect_archives, load_workspace, QaInput};
use gsa_qa::QaInstalled;

/// The installed-DB view the installed-DB-scope checks read: `gsa-install`'s
/// `LocalDb` (a fixture's fabricated `local/` tree answers through the
/// `pacman-conf DBPath` stub, never the host's). Unreadable/absent = an
/// empty view — those checks then report `skipped`, never a fake clean.
fn installed_view() -> Vec<QaInstalled> {
    let db_root = gsa_install::localdb::pacman_db_root();
    let Ok(db) = gsa_install::LocalDb::load(&db_root) else {
        return Vec::new();
    };
    db.packages()
        .into_iter()
        .map(|pkg| QaInstalled {
            name: pkg.name.clone(),
            version: pkg.version.clone(),
            provides: pkg.provides.clone(),
            depends: pkg.depends.clone(),
        })
        .collect()
}

/// The hidden `--qa-check <name> [ref…]` seam (contract §D.1): run exactly
/// one named check and print its findings. rc per §G — 0 ran (report
/// findings never change rc), 2 usage/unknown name, 3 an install-refusing
/// check found ≥1 finding (gsa_qa::seam holds the classes).
pub fn run_qa_check(args: &[String], out: &mut dyn Write, err: &mut dyn Write) -> i32 {
    let Some(root) = crate::find_root() else {
        let _ = writeln!(
            err,
            "gsa: cannot find config/topology.conf from the current directory upward (run inside the recipe repository)"
        );
        return 2;
    };
    gsa_qa::seam::run_qa_check(args, &root, &installed_view(), out, err)
}

/// The report surface's prose lines for one install run (contract §E.4:
/// `report`-severity findings appended to the run record's prose summary —
/// prose-only by the §H.2 choice recorded in `gsa-qa::report`): every
/// report-severity check over the run's subjects with workspace-wide
/// context, the run's own archive sets probed. `None` when no workspace is
/// reachable from the run.
pub fn report_lines(targets: &[String]) -> Option<Vec<String>> {
    let root = crate::find_root()?;
    let workspace = load_workspace(&root).ok()?;
    let archives = collect_archives(&workspace.recipes, targets);
    let installed = installed_view();
    let input = QaInput {
        recipes: &workspace.recipes,
        targets,
        archives: &archives,
        installed: &installed,
        exclusions: &workspace.exclusions,
    };
    let findings = gsa_qa::report::report_findings(&input);
    Some(gsa_qa::report::render_lines(&findings))
}
