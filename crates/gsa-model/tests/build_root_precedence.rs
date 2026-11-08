//! The build-root precedence (contract §J.2): the run-scoped override is
//! above the environment on purpose — a lane child that re-resolves the
//! layout must land where its supervisor decided, not where a stale
//! `GSA_BUILD_DIR` pointed. One test, one process: the override lives behind
//! a `OnceLock`, so a second test in this file would observe the first's set.

use gsa_model::config::{
    build_root, build_root_override, build_root_with_source, set_build_root_override, GsaConfig,
};
use std::path::PathBuf;

fn cfg(build_dir: Option<&str>) -> GsaConfig {
    GsaConfig {
        build_dir: build_dir.map(PathBuf::from),
        ..GsaConfig::default()
    }
}

#[test]
fn precedence_is_override_then_env_then_config() {
    std::env::remove_var("GSA_BUILD_DIR");

    // The built-in rung: the build user's ~/.cache/gsa, labelled as such.
    let (root, source) = build_root_with_source(&cfg(None)).unwrap();
    assert_eq!(
        root,
        gsa_model::config::build_user_home()
            .unwrap()
            .join(".cache")
            .join("gsa")
    );
    assert_eq!(source, "the built-in default");

    let (root, source) = build_root_with_source(&cfg(Some("/conf/tree"))).unwrap();
    assert_eq!(root, PathBuf::from("/conf/tree"));
    assert_eq!(source, "gsa.conf build_dir");

    std::env::set_var("GSA_BUILD_DIR", "/env/tree");
    let (root, source) = build_root_with_source(&cfg(Some("/conf/tree"))).unwrap();
    assert_eq!(root, PathBuf::from("/env/tree"));
    assert_eq!(source, "GSA_BUILD_DIR");
    // A blank environment value is unset: the config rung answers again.
    std::env::set_var("GSA_BUILD_DIR", "  ");
    let (root, source) = build_root_with_source(&cfg(Some("/conf/tree"))).unwrap();
    assert_eq!(root, PathBuf::from("/conf/tree"));
    assert_eq!(source, "gsa.conf build_dir");
    std::env::set_var("GSA_BUILD_DIR", "/env/tree");

    set_build_root_override(PathBuf::from("/chosen/tree"));
    assert_eq!(build_root(&cfg(Some("/conf/tree"))).unwrap(), PathBuf::from("/chosen/tree"));
    assert_eq!(
        build_root_override(),
        Some(std::path::Path::new("/chosen/tree"))
    );
    assert_eq!(build_root_with_source(&cfg(None)).unwrap().1, "this run's choice");

    std::env::remove_var("GSA_BUILD_DIR");
}
