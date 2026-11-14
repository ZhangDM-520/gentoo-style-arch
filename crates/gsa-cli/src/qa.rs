//! The `--qa-check` seam wiring and the install-run QA report surface
//! (contract §D.1, §E.4): the engine-side assembly for the `gsa-qa` check
//! registry — workspace + installed-DB input — and the prose-summary block
//! of `report`-severity findings. The registry itself, its checks and their
//! severity enforcement live in `gsa-qa`; this module only gathers input and
//! renders nothing itself.

use std::io::Write;

use crate::exit::{self, Exit};
use gsa_qa::input::{collect_archives, load_workspace, QaInput};
use gsa_qa::QaInstalled;

/// The installed-DB view the installed-DB-scope checks read: `gsa-install`'s
/// `LocalDb` (a fixture's fabricated `local/` tree answers through the
/// `pacman-conf DBPath` stub, never the host's). Unreadable/absent = an
/// empty view — those checks then report `skipped`, never a fake clean.
fn installed_view_for(conf: Option<&std::path::Path>) -> Vec<QaInstalled> {
    let Ok(db_root) = gsa_install::localdb::pacman_db_root_for(conf) else {
        return Vec::new();
    };
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
            files: pkg.files.clone(),
        })
        .collect()
}

/// The hidden `--qa-check <name> [ref…]` seam (contract §D.1): run exactly
/// one named check and print its findings. rc per §G — 0 ran (report
/// findings never change rc), 2 usage/unknown name, 3 an install-refusing
/// check found ≥1 finding (gsa_qa::seam holds the classes).
pub fn run_qa_check(args: &[String], out: &mut dyn Write, err: &mut dyn Write) -> i32 {
    exit::render(run_qa_check_inner(args, out, err), err)
}

fn run_qa_check_inner(
    args: &[String],
    out: &mut dyn Write,
    _err: &mut dyn Write,
) -> Result<i32, Exit> {
    // `--state-dir PATH` is the §J.3 modifier this seam accepts (the same
    // strip as `--local-db-check`): the state tier must reach root discovery
    // too (E1 — one state tree per invocation).
    let mut positional: Vec<String> = Vec::with_capacity(args.len());
    let mut state_flag: Option<&str> = None;
    let mut iter = args.iter();
    while let Some(arg) = iter.next() {
        if arg == "--state-dir" {
            state_flag = iter.next().map(String::as_str);
            continue;
        }
        positional.push(arg.clone());
    }
    let args: &[String] = &positional;
    let root = crate::find_root(state_flag).map_err(|failure| Exit::Usage(failure.message()))?;
    Ok(gsa_qa::seam::run_qa_check(
        args,
        &root,
        &installed_view_for(None),
        out,
        _err,
    ))
}

/// The report surface's prose lines for one install run (contract §E.4:
/// `report`-severity findings appended to the run record's prose summary —
/// prose-only by the §H.2 choice recorded in `gsa-qa::report`): every
/// report-severity check over the run's subjects with workspace-wide
/// context, the run's own archive sets probed. `None` when no workspace is
/// reachable from the run.
pub fn report_lines(
    targets: &[String],
    state_flag: Option<&str>,
    conf: Option<&std::path::Path>,
) -> Option<Vec<String>> {
    let root = crate::find_root_opt(state_flag)?;
    let workspace = load_workspace(&root).ok()?;
    let archives = collect_archives(&workspace.recipes, targets);
    let installed = installed_view_for(conf);
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn installed_view_respects_explicit_pacman_config_dbpath() {
        let dir = std::env::temp_dir().join(format!(
            "gsa-cli-qa-conf-{}-{}",
            std::process::id(),
            std::thread::current()
                .name()
                .unwrap_or("t")
                .replace(':', "_")
        ));
        let _ = std::fs::remove_dir_all(&dir);
        let db = dir.join("target-db");
        let desc_dir = db.join("local/demo-pkg-1.0-1");
        std::fs::create_dir_all(&desc_dir).unwrap();
        std::fs::write(
            desc_dir.join("desc"),
            "%NAME%\ndemo-pkg\n\n%VERSION%\n1.0-1\n\n",
        )
        .unwrap();
        std::fs::write(desc_dir.join("files"), "%FILES%\nusr/bin/demo\n\n").unwrap();
        let conf: PathBuf = dir.join("pacman.conf");
        std::fs::write(&conf, format!("[options]\nDBPath = {}\n", db.display())).unwrap();

        let pkgs = installed_view_for(Some(&conf));
        assert_eq!(pkgs.len(), 1);
        assert_eq!(pkgs[0].name, "demo-pkg");
        assert_eq!(pkgs[0].version, "0:1.0-1");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
