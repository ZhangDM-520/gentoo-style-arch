//! Shared-source mirrors (`gsa -Mm`, contract §B.7) — fully local: the test
//! creates its own git clones in scratch and every git invocation is
//! hardened with `GIT_CONFIG_COUNT=0` (agent shells inject git config that
//! breaks git operations). Pins: a missing twin is only linked when applied
//! (dangling until its first build populates the canonical), a populated
//! non-git directory is skipped and never replaced, `apply == false`
//! changes nothing, and a silent git success (`git remote set-url` prints
//! nothing) is reported as `applied`, never a false failure. No network
//! access is needed, so nothing here is `#[ignore]`d.

mod common;

use std::path::Path;
use std::process::Command;

use common::srcinfo;
use gsa_maint::mirrors;

const MIRROR_URL: &str = "git+https://example.test/mirror/widget.git";

/// `git` with the agent-shell hardening neutralised (same convention as the
/// module under test and the fixture battery).
fn git(dir: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .env("GIT_CONFIG_COUNT", "0")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .unwrap();
    assert!(output.status.success(), "git {args:?} failed: {output:?}");
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

/// Two recipes declaring the same `git+` source; their local clone names
/// both resolve to `widget`.
fn mirrors_fixture(name: &str) -> (common::Fixture, std::path::PathBuf, std::path::PathBuf) {
    let mut fx = common::Fixture::new(name);
    let malpha = fx.add_recipe(
        "malpha",
        "git",
        "git",
        "",
        &srcinfo("malpha", &["malpha"], "1.0", "1", &[MIRROR_URL]),
    );
    let mbeta = fx.add_recipe(
        "mbeta",
        "misc",
        "misc",
        "",
        &srcinfo("mbeta", &["mbeta"], "1.0", "1", &[MIRROR_URL]),
    );
    (fx, malpha.join("widget"), mbeta.join("widget"))
}

#[test]
fn a_missing_twin_is_linked_only_when_applied() {
    let (fx, canonical, twin) = mirrors_fixture("mirrors-dangling");
    assert!(!canonical.exists() && !twin.exists());

    fx.with_ctx(|ctx| {
        // Dry-run: the plan names the canonical and the link; nothing is
        // created.
        let plan = mirrors::run(ctx, false).unwrap();
        common::assert_row_grammar(&plan);
        assert!(common::find_row(&plan, &canonical.display().to_string(), "canonical").is_some());
        let link = common::find_row(&plan, &twin.display().to_string(), "link")
            .expect("the duplicate twin is planned as a link");
        assert!(link.reason.contains("planned ->"), "{}", link.reason);
        assert!(
            std::fs::symlink_metadata(&twin).is_err(),
            "a dry-run creates no symlink"
        );

        // Applied: the twin becomes a dangling symlink to the canonical
        // (valid on a clean checkout — the first build populates it).
        let rows = mirrors::run(ctx, true).unwrap();
        assert!(common::find_row(&rows, &twin.display().to_string(), "link").is_some());
    });

    let meta = std::fs::symlink_metadata(&twin).expect("the twin is a symlink");
    assert!(meta.file_type().is_symlink());
    let target = std::fs::read_link(&twin).unwrap();
    assert!(
        target.ends_with("git/malpha/widget"),
        "a relative link to the canonical: {}",
        target.display()
    );
    assert!(
        !twin.exists(),
        "the link is dangling until the canonical is populated"
    );
}

#[test]
fn a_populated_non_git_directory_is_skipped_never_replaced() {
    let (fx, canonical, twin) = mirrors_fixture("mirrors-nongit");
    std::fs::create_dir_all(&canonical).unwrap();
    std::fs::write(canonical.join("keep.txt"), "hand-made tree\n").unwrap();

    fx.with_ctx(|ctx| {
        let rows = mirrors::run(ctx, true).unwrap();
        common::assert_row_grammar(&rows);
        let skip = common::find_row(&rows, &canonical.display().to_string(), "skip")
            .expect("a populated non-git directory is skipped");
        assert!(
            skip.reason.contains("populated-non-git malpha"),
            "{}",
            skip.reason
        );
    });

    assert!(
        canonical.join("keep.txt").exists(),
        "the populated non-git directory is never overwritten"
    );
    assert!(
        std::fs::symlink_metadata(&twin).is_err(),
        "the missing twin becomes the canonical (populated by its first build), never a link"
    );
}

#[test]
fn canonical_origin_repair_is_planned_then_applied() {
    let (fx, canonical, twin) = mirrors_fixture("mirrors-repair");
    std::fs::create_dir_all(&canonical).unwrap();
    git(&canonical, &["init"]);
    git(
        &canonical,
        &[
            "remote",
            "add",
            "origin",
            "git+https://example.test/mirror/WRONG.git",
        ],
    );

    fx.with_ctx(|ctx| {
        // Dry-run: the repair is planned and the origin is untouched.
        let plan = mirrors::run(ctx, false).unwrap();
        let repair = common::find_row(&plan, &canonical.display().to_string(), "repair-origin")
            .expect("the wrong origin is planned for repair");
        assert!(
            repair.reason.contains(&format!("-> {MIRROR_URL}")),
            "{}",
            repair.reason
        );
        assert_eq!(
            git(&canonical, &["config", "--get", "remote.origin.url"]),
            "git+https://example.test/mirror/WRONG.git",
            "a dry-run repairs nothing"
        );

        // Applied: `git remote set-url` succeeds silently — the row is
        // `repair-origin applied …`, and the origin is the canonical URL
        // afterwards.
        let rows = mirrors::run(ctx, true).unwrap();
        common::assert_row_grammar(&rows);
        let applied = rows
            .iter()
            .find(|r| r.subject == canonical.display().to_string() && r.action == "repair-origin")
            .unwrap_or_else(|| panic!("the repair is named in the applied rows; got {rows:?}"));
        assert!(
            applied.reason.starts_with("applied "),
            "a silent git success is success: {}",
            applied.reason
        );
    });

    assert_eq!(
        git(&canonical, &["config", "--get", "remote.origin.url"]),
        MIRROR_URL,
        "the applied repair moved the origin to the canonical URL"
    );
    assert!(std::fs::symlink_metadata(&twin)
        .unwrap()
        .file_type()
        .is_symlink());
}
