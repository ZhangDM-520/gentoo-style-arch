//! Doctor and audit (contract §B.7/§E.4): the doctor names orphan archives
//! and orphan index rows and `fix` applies exactly those repairs, a repair
//! failure is the refusal class at the adapter (the `FixOutcome::failed`
//! count the rc-3 mapping consumes), and the audit report is report-only —
//! rows in `<subject> <action> <reason…>` and zero filesystem mutation.

mod common;

use common::{has_row, make_archive, srcinfo, Fixture};
use gsa_maint::{audit, doctor};
use gsa_state::{reindex_archives, BinpkgIndex};

fn doctor_fixture(name: &str) -> Fixture {
    let mut fx = Fixture::new(name);
    fx.add_recipe(
        "alpha",
        "git",
        "git",
        "",
        &srcinfo("alpha", &["alpha"], "1.0", "1", &[]),
    );
    fx
}

#[test]
fn doctor_names_an_orphan_archive_and_fix_reindexes_it() {
    let fx = doctor_fixture("doctor-orphan-archive");
    let archive = fx
        .root
        .join("packages/git/alpha/alpha-1.0-1-any.pkg.tar.zst");
    make_archive(&archive, "alpha", "alpha", "1.0-1");

    fx.with_ctx(|ctx| {
        let rows = doctor::report(ctx);
        common::assert_row_grammar(&rows);
        let orphan = common::find_row(&rows, &archive.display().to_string(), "orphan-archive")
            .expect("orphan archive named");
        assert_eq!(orphan.reason, "no-index-row alpha");
        assert!(common::find_row(&rows, "doctor", "report").is_some());

        let outcome = doctor::fix(ctx, true).unwrap();
        assert_eq!(outcome.failed, 0);
        let reindexed =
            common::find_row(&outcome.rows, &archive.display().to_string(), "reindexed")
                .expect("fix rows name the action");
        assert_eq!(reindexed.reason, "alpha instance=1");
    });

    let state = fx.state();
    let index = BinpkgIndex::load(&state).unwrap();
    assert_eq!(index.rows.len(), 1, "the archive is indexed");
    assert_eq!(index.rows[0].version, "0:1.0-1");
    assert!(gsa_state::verify_row(&index.rows[0]).agrees());

    fx.with_ctx(|ctx| {
        assert!(doctor::report(ctx)
            .iter()
            .all(|r| r.action != "orphan-archive"));
    });
}

#[test]
fn doctor_names_an_orphan_row_and_fix_tombstones_it() {
    let fx = doctor_fixture("doctor-orphan-row");
    let state = fx.state();
    let archive = fx
        .root
        .join("packages/git/alpha/alpha-1.0-1-any.pkg.tar.zst");
    make_archive(&archive, "alpha", "alpha", "1.0-1");
    let mut err = Vec::new();
    reindex_archives(&state, "alpha", &[archive.clone()], None, &mut err).unwrap();
    std::fs::remove_file(&archive).unwrap();

    fx.with_ctx(|ctx| {
        let rows = doctor::report(ctx);
        let orphan = common::find_row(&rows, &archive.display().to_string(), "orphan-row")
            .expect("orphan row named");
        assert!(orphan.reason.contains("archive-gone alpha instance=1"));

        let outcome = doctor::fix(ctx, true).unwrap();
        assert_eq!(outcome.failed, 0);
        assert!(
            common::find_row(&outcome.rows, &archive.display().to_string(), "tombstoned").is_some()
        );
    });

    let index = BinpkgIndex::load(&state).unwrap();
    assert!(index.rows.is_empty(), "the orphan row is tombstoned");
}

#[test]
fn an_unreadable_index_is_named_and_refuses_the_repair() {
    let fx = doctor_fixture("doctor-unreadable-index");
    let archive = fx
        .root
        .join("packages/git/alpha/alpha-1.0-1-any.pkg.tar.zst");
    make_archive(&archive, "alpha", "alpha", "1.0-1");
    let state = fx.state();
    // A directory where the index file belongs: a read failure, which the
    // store never confuses with a missing index (that one is the empty
    // store a clean checkout has).
    std::fs::create_dir_all(state.index_path()).unwrap();

    fx.with_ctx(|ctx| {
        let rows = doctor::report(ctx);
        common::assert_row_grammar(&rows);
        let failure = common::find_row(&rows, "binpkg-index", "failed")
            .expect("an unreadable index is a finding of its own");
        assert!(
            failure.reason.contains("cannot read the binpkg index"),
            "{:?}",
            failure.reason
        );
        assert!(
            rows.iter()
                .all(|r| r.action != "orphan-archive" && r.action != "orphan-row"),
            "an unreadable index must not make every archive an orphan: {rows:?}"
        );
        // The repair refuses instead of reindexing against a fiction; the
        // adapter maps this Err to the rc-3 refusal class.
        assert!(doctor::fix(ctx, true).is_err());
        assert!(doctor::fix(ctx, false).is_err());
    });
}

#[test]
fn fix_dry_run_plans_the_named_repairs_and_mutates_nothing() {
    let fx = doctor_fixture("doctor-dry-run");
    let state = fx.state();
    let archive = fx
        .root
        .join("packages/git/alpha/alpha-1.0-1-any.pkg.tar.zst");
    make_archive(&archive, "alpha", "alpha", "1.0-1");
    // An orphan row: indexed, then its archive goes away.
    let gone = fx
        .root
        .join("packages/git/alpha/alpha-0.9-1-any.pkg.tar.zst");
    make_archive(&gone, "alpha", "alpha", "0.9-1");
    let mut err = Vec::new();
    reindex_archives(&state, "alpha", &[gone.clone()], None, &mut err).unwrap();
    std::fs::remove_file(&gone).unwrap();
    // A stale run artifact inside the state root.
    let stale = fx.state_dir.join(".lane1.result");
    std::fs::write(&stale, "stale\n").unwrap();

    let before = fx.snapshot();
    fx.with_ctx(|ctx| {
        let outcome = doctor::fix(ctx, false).unwrap();
        common::assert_row_grammar(&outcome.rows);
        assert_eq!(outcome.failed, 0);
        assert!(
            common::find_row(&outcome.rows, &gone.display().to_string(), "tombstone").is_some()
        );
        assert!(
            common::find_row(&outcome.rows, &archive.display().to_string(), "reindex").is_some()
        );
        assert!(common::find_row(&outcome.rows, &stale.display().to_string(), "prune").is_some());
    });
    assert_eq!(fx.snapshot(), before, "the dry-run mutates nothing");
    assert!(stale.exists());
    assert!(archive.exists());
}

#[test]
fn a_failed_repair_is_counted_for_the_refusal_class() {
    let fx = doctor_fixture("doctor-failure");
    let broken = fx
        .root
        .join("packages/git/alpha/broken-1.0-1-any.pkg.tar.zst");
    std::fs::write(&broken, "this is not a zstd tar archive\n").unwrap();

    fx.with_ctx(|ctx| {
        let outcome = doctor::fix(ctx, true).unwrap();
        // The adapter maps `failed > 0` to RC_REFUSAL (3): a write/repair
        // that failed closed is the refusal class (§G.1).
        assert_eq!(outcome.failed, 1, "one refused repair is counted");
        let row = common::find_row(&outcome.rows, &broken.display().to_string(), "failed")
            .expect("fix rows name each failure");
        assert!(row.reason.contains("reindex refused"), "{}", row.reason);
    });
}

#[test]
fn audit_report_is_read_only_and_renders_row_grammar() {
    let mut fx = Fixture::new("audit-report");
    fx.add_recipe(
        "alpha",
        "git",
        "git",
        "",
        &srcinfo("alpha", &["alpha"], "1.0", "1", &[]),
    );
    // A recipe directory the topology does not know (package drift).
    let stray = fx.root.join("packages/misc/stray");
    std::fs::create_dir_all(&stray).unwrap();
    std::fs::write(stray.join("PKGBUILD"), "# stray\n").unwrap();
    // A recipe invoking cargo without a rust-git edge (toolchain edge).
    fx.write_pkgbuild("alpha", "git", "cargo build --release\n");
    // Surviving legacy-layout path references.
    std::fs::write(fx.root.join("NOTES.txt"), "moved from .Stable/ tree\n").unwrap();
    // A stale run artifact in the state root.
    std::fs::create_dir_all(&fx.state_dir).unwrap();
    std::fs::write(fx.state_dir.join(".lane1.result"), "stale\n").unwrap();

    let before = fx.snapshot();
    fx.with_ctx(|ctx| {
        let rows = audit::report(ctx);
        common::assert_row_grammar(&rows);

        // Family summaries, then one row per finding (§B.7's report shape).
        assert!(common::find_row(&rows, "audit", "package-drift").is_some());
        assert!(common::find_row(&rows, "audit", "toolchain-edge").is_some());
        assert!(common::find_row(&rows, "audit", "legacy-layout").is_some());
        assert!(common::find_row(&rows, "audit", "version-sync-skew").is_some());

        assert!(
            has_row(&rows, "package-drift", "packages/misc/stray"),
            "the unregistered recipe dir is named"
        );
        assert!(
            has_row(&rows, "toolchain-edge", "alpha"),
            "the missing rust-git edge is named"
        );
        assert!(
            rows.iter()
                .any(|r| r.subject == "legacy-layout" && r.reason == ".Stable/"),
            "the legacy path reference is named"
        );
        assert!(
            rows.iter()
                .any(|r| r.subject == "stale-artifact" && r.reason == "lane-result"),
            "the stale run artifact is named"
        );
    });
    assert_eq!(fx.snapshot(), before, "the audit never mutates the tree");
}

#[test]
fn doctor_scans_the_pkgdest_home_and_attributes_by_pkginfo_truth() {
    let fx = doctor_fixture("doctor-pkgdest");
    let pkgdest = fx.root.join(common::CACHE_DIR).join("pkgs");
    std::fs::create_dir_all(&pkgdest).unwrap();
    // One orphan in each home: the live PKGDEST and the legacy recipe dir.
    let live = pkgdest.join("alpha-1.0-1-any.pkg.tar.zst");
    make_archive(&live, "alpha", "alpha", "1.0-1");
    let legacy = fx
        .root
        .join("packages/git/alpha/alpha-0.9-1-any.pkg.tar.zst");
    make_archive(&legacy, "alpha", "alpha", "0.9-1");
    // A PKGDEST file no committed recipe declares and no row binds: rule
    // 11's truth filter drops it — it is not any recipe's orphan, so it is
    // never reported and never re-indexed under a wrong recipe id.
    let stray = pkgdest.join("stray-9.9.9-1-any.pkg.tar.zst");
    make_archive(&stray, "stray", "stray", "9.9.9-1");

    fx.with_ctx(|ctx| {
        let rows = doctor::report(ctx);
        common::assert_row_grammar(&rows);
        let orphan = common::find_row(&rows, &live.display().to_string(), "orphan-archive")
            .expect("the PKGDEST orphan is named");
        assert_eq!(orphan.reason, "no-index-row alpha");
        assert!(
            common::find_row(&rows, &legacy.display().to_string(), "orphan-archive").is_some(),
            "the legacy-home orphan is still named"
        );
        assert!(
            common::find_row(&rows, &stray.display().to_string(), "orphan-archive").is_none(),
            "the unattributed stray is nobody's orphan (rule 11 truth filter)"
        );

        let outcome = doctor::fix(ctx, true).unwrap();
        assert_eq!(outcome.failed, 0);
    });

    let state = fx.state();
    let index = BinpkgIndex::load(&state).unwrap();
    assert_eq!(
        index.rows.len(),
        2,
        "both attributed orphans re-indexed; the unattributed stray never is"
    );
    let archived: Vec<String> = index
        .rows
        .iter()
        .map(|r| r.archive.display().to_string())
        .collect();
    assert!(archived.contains(&live.display().to_string()));
    assert!(archived.contains(&legacy.display().to_string()));
    assert!(!archived.contains(&stray.display().to_string()));

    fx.with_ctx(|ctx| {
        let rows = doctor::report(ctx);
        assert!(rows.iter().all(|r| r.action != "orphan-archive"));
    });
}

#[test]
fn doctor_and_prune_do_not_tombstone_unreadable_archive_symlink_loop() {
    let mut fx = Fixture::new("doctor-eloop");
    fx.add_recipe(
        "alpha",
        "git",
        "git",
        "",
        &srcinfo("alpha", &["alpha"], "1.0", "1", &[]),
    );
    let alpha_dir = fx.root.join("packages").join("git").join("alpha");
    let archive = alpha_dir.join("alpha-1.0-1-any.pkg.tar.zst");
    make_archive(&archive, "alpha", "alpha", "1.0-1");
    let state = fx.state();
    let mut err = Vec::new();
    gsa_state::reindex_archives(
        &state,
        "alpha",
        std::slice::from_ref(&archive),
        None,
        &mut err,
    )
    .unwrap();

    // Replace archive with a symlink loop (`ELOOP`, `exists() == false`, NOT `NotFound`).
    std::fs::remove_file(&archive).unwrap();
    let other = alpha_dir.join("loop-other");
    std::os::unix::fs::symlink(&other, &archive).unwrap();
    std::os::unix::fs::symlink(&archive, &other).unwrap();

    fx.with_ctx(|ctx| {
        let rows = doctor::report(ctx);
        assert!(
            common::find_row(&rows, &archive.display().to_string(), "orphan-row").is_none(),
            "unreadable ELOOP archive must NOT classify as orphan-row: {rows:?}"
        );
        assert!(
            common::find_row(&rows, &archive.display().to_string(), "index-mismatch").is_some(),
            "unreadable ELOOP archive must report mismatch/unreadable: {rows:?}"
        );
        doctor::fix(ctx, true).unwrap();
    });
    let after = BinpkgIndex::load(&state).unwrap();
    assert_eq!(
        after.rows.len(),
        1,
        "live row must NOT be tombstoned on ELOOP"
    );
}

#[test]
fn audit_report_surfaces_unreadable_pkgbuild() {
    let mut fx = Fixture::new("audit-unreadable-pkgbuild");
    fx.add_recipe(
        "alpha",
        "git",
        "git",
        "",
        &srcinfo("alpha", &["alpha"], "1.0", "1", &[]),
    );
    let pkgbuild = fx.root.join("packages/git/alpha/PKGBUILD");
    let other = fx.root.join("packages/git/alpha/pkgbuild-loop");

    fx.with_ctx(|ctx| {
        std::fs::remove_file(&pkgbuild).unwrap();
        std::os::unix::fs::symlink(&other, &pkgbuild).unwrap();
        std::os::unix::fs::symlink(&pkgbuild, &other).unwrap();
        let rows = gsa_maint::audit::report(ctx);
        assert!(
            rows.iter().any(|r| r.subject == "toolchain-edge"
                && r.action == "alpha"
                && r.reason.contains("unreadable")),
            "unreadable PKGBUILD must surface in audit::report instead of clean: {rows:?}"
        );
    });
}
