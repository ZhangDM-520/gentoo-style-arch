//! Pruning-safety tests for the `gsa-maint` maintain surface (contract §B.7):
//! the IgnorePkg closure repair never removes a name a committed recipe still
//! declares, the referent guards answer "still referenced by a run", a busy
//! run lock refuses (`run-in-flight`), and the row grammar / rc classes stay
//! pinned (§E.2/§E.4/§G.1).

mod common;

use common::{append_run, find_row, srcinfo, Fixture};
use gsa_maint::{
    hold_run_lock, ignorepkg, protect, render_rows, Row, CONFIRMATION_REQUIRED, RC_OK, RC_REFUSAL,
    RC_USAGE,
};

/// A fixture with two declared recipes and one archive whose `.PKGINFO`
/// ships a name NO recipe declares (`gsatest-shipped`), plus a target
/// `pacman.conf` whose closure mixes declared, stale and shipped-only names.
fn closure_fixture(name: &str) -> (Fixture, std::path::PathBuf) {
    let mut fx = Fixture::new(name);
    let alpha = fx.add_recipe(
        "alpha",
        "git",
        "git",
        "",
        &srcinfo(
            "gsatest-alpha",
            &["gsatest-alpha", "gsatest-alpha-extra"],
            "1.0",
            "1",
            &[],
        ),
    );
    fx.add_recipe(
        "beta",
        "stable",
        "stable",
        "",
        &srcinfo("gsatest-beta", &["gsatest-beta"], "1.0", "1", &[]),
    );
    common::make_archive(
        &alpha.join("gsatest-shipped-1.0-1-any.pkg.tar.zst"),
        "gsatest-shipped",
        "gsatest-shipped",
        "1.0-1",
    );
    let conf = fx.root.join("pacman.conf");
    std::fs::write(
        &conf,
        "[options]\nHoldPkg = pacman glibc\nIgnorePkg = gsatest-alpha gsatest-alpha-extra gsatest-stale-gone gsatest-shipped\n",
    )
    .unwrap();
    (fx, conf)
}

#[test]
fn row_grammar_and_rc_classes_are_pinned() {
    assert_eq!(Row::new("subject", "action", "").render(), "subject action");
    assert_eq!(
        Row::new("subject", "action", "reason here").render(),
        "subject action reason here"
    );
    assert_eq!(
        render_rows(&[Row::new("a", "b", "c"), Row::new("d", "e", ""),]),
        "a b c\nd e\n"
    );
    assert_eq!(RC_OK, 0);
    assert_eq!(RC_USAGE, 2);
    assert_eq!(RC_REFUSAL, 3);
    assert!(CONFIRMATION_REQUIRED.contains("confirmation-required"));
}

#[test]
fn a_busy_run_lock_is_a_run_in_flight_refusal() {
    let fx = Fixture::new("runlock");
    let held = hold_run_lock(&fx.state_dir).expect("first acquisition succeeds");
    let busy = hold_run_lock(&fx.state_dir)
        .err()
        .expect("a second holder is refused");
    assert!(
        busy.contains("run-in-flight"),
        "refusal names run-in-flight: {busy}"
    );
    drop(held);
    let again = hold_run_lock(&fx.state_dir).expect("dropping the lock releases the flock");
    drop(again);
}

#[test]
fn report_classifies_the_closure_and_names_missing_wanted_names() {
    let (fx, conf) = closure_fixture("ignorepkg-report");
    fx.with_ctx(|ctx| {
        let rows = ignorepkg::report(ctx, &conf).unwrap();
        common::assert_row_grammar(&rows);
        assert!(find_row(&rows, "ignorepkg", "closure").is_some());
        // Declared names are in use, whatever the archives say.
        let alpha = find_row(&rows, "gsatest-alpha", "in-use").expect("alpha classified");
        assert_eq!(alpha.reason, "in-use declared-by alpha");
        assert!(find_row(&rows, "gsatest-alpha-extra", "in-use").is_some());
        // A name no recipe declares is stale, split by archive truth.
        let gone = find_row(&rows, "gsatest-stale-gone", "stale").expect("stale named");
        assert_eq!(gone.reason, "stale archives-gone");
        let shipped = find_row(&rows, "gsatest-shipped", "stale").expect("shipped-only named");
        assert!(
            shipped.reason.contains("superseded"),
            "archive truth shapes the reason: {}",
            shipped.reason
        );
        // A wanted name the closure does not cover is missing.
        let beta = find_row(&rows, "gsatest-beta", "missing").expect("missing named");
        assert_eq!(beta.reason, "declared-by beta");
    });
}

#[test]
fn prune_never_removes_a_name_a_committed_recipe_declares() {
    let (fx, conf) = closure_fixture("ignorepkg-prune");
    let before = std::fs::read_to_string(&conf).unwrap();

    // Dry-run: the plan names every class and writes nothing.
    fx.with_ctx(|ctx| {
        let rows = ignorepkg::prune(ctx, &conf, false).unwrap();
        common::assert_row_grammar(&rows);
        assert!(common::has_row(&rows, "gsatest-alpha", "keep"));
        assert!(common::has_row(&rows, "gsatest-alpha-extra", "keep"));
        assert!(common::has_row(&rows, "gsatest-stale-gone", "remove"));
        assert!(common::has_row(&rows, "gsatest-shipped", "remove"));
        assert!(common::has_row(&rows, "ignorepkg", "prune"));
    });
    assert_eq!(
        std::fs::read_to_string(&conf).unwrap(),
        before,
        "a dry-run mutates nothing"
    );

    // Applied: stale names leave, declared names survive.
    fx.with_ctx(|ctx| {
        let rows = ignorepkg::prune(ctx, &conf, true).unwrap();
        assert!(common::has_row(&rows, "gsatest-alpha", "keep"));
        assert!(common::has_row(&rows, "ignorepkg", "pruned"));
    });
    let after = std::fs::read_to_string(&conf).unwrap();
    assert!(
        after.contains("gsatest-alpha"),
        "declared name kept:\n{after}"
    );
    assert!(
        after.contains("gsatest-alpha-extra"),
        "declared split-output name kept:\n{after}"
    );
    assert!(!after.contains("gsatest-stale-gone"), "stale name removed");
    assert!(
        !after.contains("gsatest-shipped"),
        "shipped-only name removed"
    );
}

#[test]
fn backfill_adds_only_missing_names_and_is_idempotent() {
    let mut fx = Fixture::new("ignorepkg-backfill");
    fx.add_recipe(
        "alpha",
        "git",
        "git",
        "",
        &srcinfo(
            "gsatest-alpha",
            &["gsatest-alpha", "gsatest-alpha-extra"],
            "1.0",
            "1",
            &[],
        ),
    );
    fx.add_recipe(
        "beta",
        "stable",
        "stable",
        "",
        &srcinfo("gsatest-beta", &["gsatest-beta"], "1.0", "1", &[]),
    );
    let conf = fx.root.join("pacman.conf");
    std::fs::write(&conf, "[options]\nIgnorePkg = gsatest-alpha\n").unwrap();
    let before = std::fs::read_to_string(&conf).unwrap();

    fx.with_ctx(|ctx| {
        let rows = ignorepkg::backfill(ctx, &conf, false).unwrap();
        common::assert_row_grammar(&rows);
        assert!(common::has_row(&rows, "gsatest-alpha", "present"));
        assert!(common::has_row(&rows, "gsatest-alpha-extra", "add"));
        assert!(common::has_row(&rows, "gsatest-beta", "add"));
    });
    assert_eq!(std::fs::read_to_string(&conf).unwrap(), before, "dry-run");

    fx.with_ctx(|ctx| {
        let rows = ignorepkg::backfill(ctx, &conf, true).unwrap();
        assert!(common::has_row(&rows, "gsatest-alpha", "present"));
        assert_eq!(
            common::rows_with(&rows, "gsatest-alpha-extra", "add").len(),
            1
        );
        assert_eq!(common::rows_with(&rows, "gsatest-beta", "add").len(), 1);
        // Idempotent second pass: everything is present, nothing is re-added.
        let again = ignorepkg::backfill(ctx, &conf, true).unwrap();
        assert!(again.iter().all(|r| r.action == "present"));
    });
    let after = std::fs::read_to_string(&conf).unwrap();
    for name in ["gsatest-alpha", "gsatest-alpha-extra", "gsatest-beta"] {
        assert!(after.contains(name), "{name} backfilled:\n{after}");
    }
}

#[test]
fn protect_referenced_by_run_tracks_the_newest_remaining_set() {
    let fx = Fixture::new("protect-referent");
    let state = fx.state();

    // An empty history protects nothing.
    assert!(protect::referenced_by_run(&state).is_empty());

    // The newest record's `remaining:` set is the protected set.
    append_run(&state, &common::run_record("alpha", &["alpha", "beta"]));
    let protected = protect::referenced_by_run(&state);
    assert!(protected.contains("alpha"));
    assert!(protected.contains("beta"));
    assert_eq!(protected.len(), 2);

    // A later record whose remaining no longer names them releases them.
    append_run(&state, &common::run_record("gamma", &["gamma"]));
    let protected = protect::referenced_by_run(&state);
    assert!(protected.contains("gamma"));
    assert!(!protected.contains("alpha"), "released by the later record");

    // An empty continuation releases everything.
    append_run(&state, &common::run_record("delta", &[]));
    assert!(protect::referenced_by_run(&state).is_empty());
}

#[test]
fn shipped_names_sees_the_pkgdest_home_too() {
    let mut fx = Fixture::new("ignorepkg-pkgdest");
    fx.add_recipe(
        "alpha",
        "git",
        "git",
        "",
        &srcinfo("gsatest-alpha", &["gsatest-alpha"], "1.0", "1", &[]),
    );
    // The only shipper of `gsatest-pkgdest` lives in the live PKGDEST home;
    // its classification must consult it (stale superseded, not
    // archives-gone).
    let pkgdest = fx.root.join(common::CACHE_DIR).join("pkgs");
    std::fs::create_dir_all(&pkgdest).unwrap();
    common::make_archive(
        &pkgdest.join("gsatest-pkgdest-1.0-1-any.pkg.tar.zst"),
        "gsatest-pkgdest",
        "gsatest-pkgdest",
        "1.0-1",
    );
    let conf = fx.root.join("pacman.conf");
    std::fs::write(&conf, "[options]\nIgnorePkg = gsatest-pkgdest\n").unwrap();

    fx.with_ctx(|ctx| {
        let rows = ignorepkg::report(ctx, &conf).unwrap();
        common::assert_row_grammar(&rows);
        let row = find_row(&rows, "gsatest-pkgdest", "stale").expect("stale named");
        assert!(
            row.reason.contains("superseded"),
            "the PKGDEST archive is the shipper: {}",
            row.reason
        );
    });
}
