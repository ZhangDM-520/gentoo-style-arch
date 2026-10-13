//! World and named sets (contract §B.7/§C.2): kv-vs-`config/sets/` drift is
//! REPORTED and never rewrites `config/`; `--add`/`--remove` equivalents edit
//! only the kv side; computed sets are listed but never editable (an edit
//! aimed at one is the usage class at the adapter — asserted here as the
//! `Err` the API returns).

mod common;

use common::{has_row, make_archive, srcinfo, Fixture};
use gsa_maint::sets;

fn sets_fixture(name: &str) -> Fixture {
    let mut fx = Fixture::new(name);
    fx.add_recipe(
        "alpha",
        "git",
        "git",
        "",
        &srcinfo("alpha", &["alpha"], "1.0", "1", &[]),
    );
    fx.add_recipe(
        "beta",
        "stable",
        "stable",
        "",
        &srcinfo("beta", &["beta"], "1.0", "1", &[]),
    );
    fx.add_recipe(
        "gamma",
        "misc",
        "misc",
        "",
        &srcinfo("gamma", &["gamma"], "1.0", "1", &[]),
    );
    fx.add_set("myset", "alpha\nbeta\n");
    fx
}

#[test]
fn set_drift_is_reported_and_config_is_never_written() {
    let fx = sets_fixture("sets-drift");
    let state = fx.state();
    let mut err = Vec::new();
    gsa_state::Kv::set(&state, "set:myset", "alpha gamma not-a-real-ref", &mut err).unwrap();
    let set_file = fx.root.join("config").join("sets").join("myset");
    let before = std::fs::read(&set_file).unwrap();

    fx.with_ctx(|ctx| {
        let rows = sets::set_rows(ctx, &state, &["myset".to_string()]).unwrap();
        common::assert_row_grammar(&rows);
        assert!(has_row(&rows, "myset", "user"));
        assert!(has_row(&rows, "myset", "member"));
        let drift: Vec<_> = common::rows_with(&rows, "myset", "drift");
        assert_eq!(drift.len(), 3, "exactly the three drift classes: {drift:?}");
        assert!(drift.iter().any(|r| r.reason == "only-in-config beta"));
        assert!(drift.iter().any(|r| r.reason == "only-in-state gamma"));
        assert!(drift
            .iter()
            .any(|r| r.reason == "unknown-ref not-a-real-ref"));
        assert!(
            !drift.iter().any(|r| r.reason.contains("alpha")),
            "a member present on both sides is not drift"
        );
    });
    assert_eq!(
        std::fs::read(&set_file).unwrap(),
        before,
        "reporting drift never writes config/"
    );
}

#[test]
fn world_edits_touch_only_the_kv_side() {
    let fx = sets_fixture("sets-world");
    let state = fx.state();
    let mut err = Vec::new();
    gsa_state::Kv::set(&state, "world", "alpha beta", &mut err).unwrap();
    let config_snapshot = common::snapshot_tree(&fx.root.join("config"));

    fx.with_ctx(|ctx| {
        let rows = sets::world_rows(ctx, &state).unwrap();
        common::assert_row_grammar(&rows);
        assert!(has_row(&rows, "world", "user"));
        assert!(has_row(&rows, "world", "member"));
        // World has no committed file, so every kv member is state-only drift.
        assert!(has_row(&rows, "world", "drift"));

        // Dry-run plans and writes nothing.
        let plan = sets::edit_world(
            ctx,
            &state,
            &["gamma".to_string()],
            &["beta".to_string()],
            false,
        )
        .unwrap();
        assert!(common::find_row(&plan, "world", "add").is_some());
        assert!(common::find_row(&plan, "world", "remove").is_some());
        assert_eq!(
            sets::kv_members(&state, sets::WORLD_KEY).unwrap(),
            vec!["alpha".to_string(), "beta".to_string()],
            "dry-run mutates nothing"
        );

        // Applied: the kv side only.
        let rows = sets::edit_world(
            ctx,
            &state,
            &["gamma".to_string()],
            &["beta".to_string()],
            true,
        )
        .unwrap();
        assert!(has_row(&rows, "world", "added"));
        assert!(has_row(&rows, "world", "removed"));
        assert_eq!(
            sets::kv_members(&state, sets::WORLD_KEY).unwrap(),
            vec!["alpha".to_string(), "gamma".to_string()]
        );

        // Idempotent repeats report present/absent and write nothing new.
        let rows = sets::edit_world(
            ctx,
            &state,
            &["alpha".to_string()],
            &["delta".to_string()],
            true,
        )
        .unwrap();
        assert!(has_row(&rows, "world", "present"));
        assert!(has_row(&rows, "world", "absent"));
    });
    assert_eq!(
        common::snapshot_tree(&fx.root.join("config")),
        config_snapshot,
        "edits never write config/"
    );
}

#[test]
fn set_edits_touch_only_the_kv_side() {
    let fx = sets_fixture("sets-edit");
    let state = fx.state();
    let set_file = fx.root.join("config").join("sets").join("myset");
    let before = std::fs::read(&set_file).unwrap();

    fx.with_ctx(|ctx| {
        let rows = sets::edit_set(ctx, &state, "myset", &["beta".to_string()], &[], true).unwrap();
        assert!(has_row(&rows, "myset", "added"));
        assert_eq!(
            sets::kv_members(&state, &sets::set_key("myset")).unwrap(),
            vec!["beta"]
        );
        let rows = sets::edit_set(ctx, &state, "myset", &[], &["beta".to_string()], true).unwrap();
        assert!(has_row(&rows, "myset", "removed"));
        assert!(sets::kv_members(&state, &sets::set_key("myset"))
            .unwrap()
            .is_empty());
    });
    assert_eq!(
        std::fs::read(&set_file).unwrap(),
        before,
        "an edit never rewrites the committed set file"
    );
}

#[test]
fn computed_sets_are_listed_but_never_edited() {
    let fx = sets_fixture("sets-computed");
    let state = fx.state();

    // An edit aimed at a computed set is the Err that maps to rc 2 (usage).
    fx.with_ctx(|ctx| {
        for name in ["@stale", "stale", "live-rebuild", "@preserved-rebuild"] {
            let error = sets::edit_set(ctx, &state, name, &["alpha".to_string()], &[], true)
                .expect_err("computed sets are never edited");
            assert!(error.contains("computed set"), "{name}: {error}");
        }
        let error = sets::user_set_name("bad name!").expect_err("invalid set name");
        assert!(error.contains("invalid set name"));

        // But they are all listed with their scoped membership.
        let live = sets::set_rows(ctx, &state, &["@live-rebuild".to_string()]).unwrap();
        assert!(common::find_row(&live, "live-rebuild", "member").is_some());
        let preserved = sets::set_rows(ctx, &state, &["preserved-rebuild".to_string()]).unwrap();
        let row = common::find_row(&preserved, "preserved-rebuild", "computed").unwrap();
        assert!(row.reason.contains("unavailable"), "{}", row.reason);
        let stale = sets::set_rows(ctx, &state, &["stale".to_string()]).unwrap();
        let scope = common::find_row(&stale, "stale", "scope").unwrap();
        assert!(scope.reason.contains("version-sync"), "{}", scope.reason);
    });
}

#[test]
fn stale_set_membership_comes_from_the_side_car_records() {
    let fx = sets_fixture("sets-stale");
    let state = fx.state();
    let alpha_dir = fx.root.join("packages").join("git").join("alpha");
    let archive = alpha_dir.join("alpha-1.0-1-any.pkg.tar.zst");
    // The recorded built instance says 2.0-1 while the committed .SRCINFO
    // says 1.0-1 — the one skew the side-car can see.
    make_archive(&archive, "alpha", "alpha", "2.0-1");
    let mut err = Vec::new();
    let added = gsa_state::reindex_archives(&state, "alpha", &[archive], &mut err).unwrap();
    assert_eq!(added.len(), 1);

    fx.with_ctx(|ctx| {
        let rows = sets::set_rows(ctx, &state, &["stale".to_string()]).unwrap();
        common::assert_row_grammar(&rows);
        assert!(common::find_row(&rows, "stale", "computed").is_some());
        let member = common::find_row(&rows, "stale", "member").expect("skew member named");
        assert_eq!(member.reason, "alpha built=0:2.0-1 committed=1.0-1");
    });
}

#[test]
fn sets_referenced_answers_run_membership() {
    let fx = sets_fixture("sets-referenced");
    let state = fx.state();
    assert!(!sets::referenced(&state, "alpha"));
    common::append_run(&state, &common::run_record("alpha", &["alpha"]));
    assert!(sets::referenced(&state, "alpha"));
    assert!(!sets::referenced(&state, "beta"));
}
