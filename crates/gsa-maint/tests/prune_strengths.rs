//! Prune-strength tests (contract §B.7 `-Mc`/`-Mcc`/`-Mccc`): strength 1
//! touches only the named recipes' makepkg state, strength 2 removes built
//! archives but never deletes or follows symlinks, strength 3 additionally
//! removes pulled sources; `apply == false` plans with rows and deletes
//! nothing; a run-referenced archive earns `keep` and survives. Directory
//! targets (staging trees, `source-clone` dirs) are removed recursively —
//! the removal dispatch is pinned in
//! `strength3_also_removes_pulled_sources_and_companions`.

mod common;

use std::path::PathBuf;

use common::{append_run, make_archive, run_record, srcinfo, Fixture};
use gsa_maint::prune;

fn workspace(name: &str) -> (Fixture, PathBuf, PathBuf) {
    let mut fx = Fixture::new(name);
    let alpha = fx.add_recipe(
        "alpha",
        "git",
        "git",
        "",
        &srcinfo("alpha", &["alpha"], "1.0", "1", &[]),
    );
    let beta = fx.add_recipe(
        "beta",
        "stable",
        "stable",
        "",
        &srcinfo("beta", &["beta"], "1.0", "1", &[]),
    );
    for dir in [&alpha, &beta] {
        for tree in ["src", "pkg", "build"] {
            let tree = dir.join(tree);
            std::fs::create_dir_all(&tree).unwrap();
            std::fs::write(tree.join("inner.txt"), "inner\n").unwrap();
        }
        let id = dir.file_name().unwrap().to_string_lossy().into_owned();
        make_archive(
            &dir.join(format!("{id}-1.0-1-any.pkg.tar.zst")),
            &id,
            &id,
            "1.0-1",
        );
        std::fs::write(
            dir.join(format!("{id}-1.0-1-any.pkg.tar.zst.gsa-vcs-revisions")),
            "rev baseline\n",
        )
        .unwrap();
    }
    (fx, alpha, beta)
}

#[test]
fn strength1_touches_only_the_named_recipes() {
    let (fx, alpha, beta) = workspace("prune-strength1");
    let keep = alpha.join("keepme.txt");
    std::fs::write(&keep, "keep\n").unwrap();
    // A symlinked build tree is unlinked, never recursed into.
    let outside = fx.root.join("outside-data");
    std::fs::create_dir_all(&outside).unwrap();
    std::fs::write(outside.join("keep.txt"), "survives\n").unwrap();
    std::fs::remove_dir_all(alpha.join("build")).unwrap();
    std::os::unix::fs::symlink(&outside, alpha.join("build")).unwrap();

    let beta_before = common::snapshot_tree(&beta);

    fx.with_ctx(|ctx| {
        // Dry-run first: plan rows, nothing deleted.
        let plan = prune::strength1(ctx, &["alpha".to_string()], false);
        common::assert_row_grammar(&plan);
        assert!(common::has_row(
            &plan,
            &alpha.join("src").display().to_string(),
            "prune"
        ));
        assert!(
            std::fs::metadata(alpha.join("src")).is_ok(),
            "dry-run deletes nothing"
        );
        assert!(alpha.join("alpha-1.0-1-any.pkg.tar.zst").exists());

        // Applied.
        let rows = prune::strength1(ctx, &["alpha".to_string()], true);
        common::assert_row_grammar(&rows);
        assert!(common::has_row(
            &rows,
            &alpha
                .join("alpha-1.0-1-any.pkg.tar.zst")
                .display()
                .to_string(),
            "pruned"
        ));
        assert!(common::has_row(
            &rows,
            &alpha
                .join("alpha-1.0-1-any.pkg.tar.zst.gsa-vcs-revisions")
                .display()
                .to_string(),
            "pruned"
        ));
    });

    for gone in [
        alpha.join("src"),
        alpha.join("pkg"),
        alpha.join("build"),
        alpha.join("alpha-1.0-1-any.pkg.tar.zst"),
        alpha.join("alpha-1.0-1-any.pkg.tar.zst.gsa-vcs-revisions"),
    ] {
        assert!(
            std::fs::symlink_metadata(&gone).is_err(),
            "{} removed",
            gone.display()
        );
    }
    assert!(keep.exists(), "a file strength 1 does not name survives");
    assert!(
        std::fs::read_to_string(outside.join("keep.txt")).is_ok(),
        "a symlinked tree is unlinked, never followed"
    );
    assert_eq!(
        common::snapshot_tree(&beta),
        beta_before,
        "strength 1 touches only the named recipes"
    );
}

#[test]
fn strength2_removes_archives_but_never_deletes_or_follows_symlinks() {
    let (fx, alpha, beta) = workspace("prune-strength2");
    let target = alpha.join("target.bin");
    std::fs::write(&target, "bytes\n").unwrap();
    let link = alpha.join("link-1.0-1-any.pkg.tar.zst");
    std::os::unix::fs::symlink(&target, &link).unwrap();

    fx.with_ctx(|ctx| {
        let plan = prune::strength2(ctx, false);
        assert!(common::has_row(
            &plan,
            &alpha
                .join("alpha-1.0-1-any.pkg.tar.zst")
                .display()
                .to_string(),
            "prune"
        ));
        assert!(common::has_row(&plan, &link.display().to_string(), "keep"));
        assert!(
            alpha.join("alpha-1.0-1-any.pkg.tar.zst").exists(),
            "dry-run"
        );

        let rows = prune::strength2(ctx, true);
        let kept = common::find_row(&rows, &link.display().to_string(), "keep")
            .expect("symlink earns a keep row");
        assert_eq!(kept.reason, "symlink");
    });

    assert!(!alpha.join("alpha-1.0-1-any.pkg.tar.zst").exists());
    assert!(!beta.join("beta-1.0-1-any.pkg.tar.zst").exists());
    let meta = std::fs::symlink_metadata(&link).expect("the symlink itself survives");
    assert!(meta.file_type().is_symlink());
    assert!(
        target.exists(),
        "the symlink's referent is never followed/deleted"
    );
    assert!(
        alpha.join("src").is_dir(),
        "strength 2 leaves the staging trees"
    );
    assert!(!alpha
        .join("alpha-1.0-1-any.pkg.tar.zst.gsa-vcs-revisions")
        .exists());
}

#[test]
fn strength3_also_removes_pulled_sources_and_companions() {
    let mut fx = Fixture::new("prune-strength3");
    let alpha = fx.add_recipe(
        "alpha",
        "git",
        "git",
        "",
        &srcinfo(
            "alpha",
            &["alpha"],
            "1.0",
            "1",
            &[
                "git+https://example.test/src/widget.git",
                "linksrc::git+https://example.test/src/other.git",
                "https://example.test/dl/gsapkg-1.0.tar.gz",
                "https://example.test/dl/notes.txt",
                "fix.patch",
            ],
        ),
    );
    std::fs::write(fx.root.join(".gitignore"), "*.tar.gz\n*.zip\n").unwrap();

    let clone = alpha.join("widget");
    std::fs::create_dir_all(&clone).unwrap();
    std::fs::write(clone.join("cloned.txt"), "clone\n").unwrap();
    let outside = fx.root.join("outside-src");
    std::fs::create_dir_all(&outside).unwrap();
    std::fs::write(outside.join("keep.txt"), "survives\n").unwrap();
    std::os::unix::fs::symlink(&outside, alpha.join("linksrc")).unwrap();
    std::fs::write(alpha.join("gsapkg-1.0.tar.gz"), "download\n").unwrap();
    std::fs::write(alpha.join("gsapkg-1.0.tar.gz.sig"), "sig\n").unwrap();
    std::fs::write(alpha.join("notes.txt"), "not extension-matched\n").unwrap();
    std::fs::write(alpha.join("fix.patch"), "local\n").unwrap();
    make_archive(
        &alpha.join("alpha-1.0-1-any.pkg.tar.zst"),
        "alpha",
        "alpha",
        "1.0-1",
    );
    for tree in ["src", "pkg", "build", "_build"] {
        std::fs::create_dir_all(alpha.join(tree)).unwrap();
    }

    fx.with_ctx(|ctx| {
        let plan = prune::strength3(ctx, false);
        common::assert_row_grammar(&plan);
        assert!(common::has_row(
            &plan,
            &clone.display().to_string(),
            "prune"
        ));
        assert!(common::has_row(
            &plan,
            &alpha.join("gsapkg-1.0.tar.gz").display().to_string(),
            "prune"
        ));
        assert!(clone.is_dir(), "dry-run deletes nothing");

        let rows = prune::strength3(ctx, true);
        assert!(common::has_row(
            &rows,
            &alpha.join("gsapkg-1.0.tar.gz.sig").display().to_string(),
            "pruned"
        ));
        let kept = common::find_row(&rows, &alpha.join("linksrc").display().to_string(), "keep")
            .expect("symlinked clone earns keep");
        assert_eq!(kept.reason, "symlink");
        // The clone is a directory target: removed recursively, loudly.
        let pruned = common::find_row(&rows, &clone.display().to_string(), "pruned")
            .expect("the clone dir removal is applied and reported");
        assert_eq!(pruned.reason, "source-clone");
    });

    for gone in [
        alpha.join("gsapkg-1.0.tar.gz"),
        alpha.join("gsapkg-1.0.tar.gz.sig"),
        alpha.join("alpha-1.0-1-any.pkg.tar.zst"),
        alpha.join("src"),
        alpha.join("pkg"),
        alpha.join("build"),
        alpha.join("_build"),
    ] {
        assert!(
            std::fs::symlink_metadata(&gone).is_err(),
            "{} removed",
            gone.display()
        );
    }
    assert!(
        std::fs::symlink_metadata(&clone).is_err(),
        "the pulled VCS clone dir is removed recursively"
    );
    assert!(
        alpha.join("notes.txt").exists(),
        "unmatched download survives"
    );
    assert!(
        alpha.join("fix.patch").exists(),
        "a local source never matches"
    );
    assert!(outside.join("keep.txt").exists(), "symlink never followed");
    assert!(std::fs::symlink_metadata(alpha.join("linksrc"))
        .unwrap()
        .file_type()
        .is_symlink());
}

#[test]
fn a_run_referenced_archive_is_never_pruned() {
    let (fx, alpha, beta) = workspace("prune-referenced");
    std::fs::write(alpha.join("src").join("inner.txt"), "still here\n").unwrap();
    let state = fx.state();
    // The newest run still owes `alpha` (its continuation's replay may
    // consume the existing archives).
    append_run(&state, &run_record("alpha", &["alpha"]));

    fx.with_ctx(|ctx| {
        let rows = prune::strength2(ctx, true);
        let kept = common::find_row(
            &rows,
            &alpha
                .join("alpha-1.0-1-any.pkg.tar.zst")
                .display()
                .to_string(),
            "keep",
        )
        .expect("referenced archive earns keep");
        assert_eq!(kept.reason, "referenced-by-run");

        // Strength 1 protects the referenced recipe's whole target set.
        let rows = prune::strength1(ctx, &["alpha".to_string(), "beta".to_string()], true);
        assert!(common::has_row(
            &rows,
            &alpha.join("src").display().to_string(),
            "keep"
        ));
    });

    assert!(
        alpha.join("alpha-1.0-1-any.pkg.tar.zst").exists(),
        "the run-referenced archive survives"
    );
    assert!(
        alpha.join("src").join("inner.txt").exists(),
        "the run-referenced recipe's trees survive"
    );
    assert!(
        !beta.join("beta-1.0-1-any.pkg.tar.zst").exists(),
        "an unreferenced archive is pruned"
    );
}
