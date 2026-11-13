//! The ABI name vocabulary the checks share (fish `abi_*` / `_*_lint_*`
//! helpers in `build-all.fish` + `lib/audit.fish`). Re-exported from
//! [`gsa_model::abi`] so `gsa-abi`, `gsa-install`, and `gsa-qa` share one
//! definition without duplicating helper logic (`F-QA-03`).

pub use gsa_model::abi::{
    base_lib_ok, provide_covers, provide_covers_as, provide_name, soname_stem, stock_name,
    ElfClass, BASE_LIBS,
};

/// Does the exclusions registry (`config/abi-exclusions.conf` ids) cover
/// this name (a package id, a soname, or its bare stem)? — fish
/// `abi_excluded` / `gsa-install::gates::AbiExclusions::covers`.
pub fn excluded(exclusions: &[String], name: &str) -> bool {
    if exclusions.iter().any(|id| id == name) {
        return true;
    }
    match soname_stem(name) {
        Some(stem) => exclusions.iter().any(|id| id == stem),
        None => false,
    }
}

/// The soname stems of a provide-entry list (versioned provides like
/// `libfoo.so=1-64` collapse to `libfoo.so`) — fish `abi_soname_stems`, the
/// layer-2/5 comparison unit.
pub fn soname_stems<'a>(entries: impl IntoIterator<Item = &'a str>) -> Vec<&'a str> {
    let mut stems: Vec<&str> = entries
        .into_iter()
        .filter_map(|entry| soname_stem(provide_name(entry)))
        .collect();
    stems.sort_unstable();
    stems.dedup();
    stems
}

/// Split a dependency/provide value into `(name, op, ver)` on the first
/// version constraint — fish's `^(.+?)(>=|<=|=|>|<)(.+)$` (non-greedy name,
/// operator alternatives tried in that order at each position). `None` when
/// the value carries no constraint.
pub fn split_constraint(value: &str) -> Option<(&str, &str, &str)> {
    let value = value.trim();
    let bytes = value.as_bytes();
    for i in 0..bytes.len() {
        for op in [">=", "<=", "=", ">", "<"] {
            if value[i..].starts_with(op) {
                let name = value[..i].trim();
                let ver = value[i + op.len()..].trim();
                if name.is_empty() {
                    return None;
                }
                return Some((name, op, ver));
            }
        }
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn soname_stem_shapes() {
        assert_eq!(soname_stem("libfoo.so"), Some("libfoo.so"));
        assert_eq!(soname_stem("libfoo.so.1.2"), Some("libfoo.so"));
        assert_eq!(soname_stem("meson"), None);
        assert_eq!(soname_stem("sowhat"), None);
    }

    #[test]
    fn provide_name_strips_every_constraint_spelling() {
        assert_eq!(provide_name("libfoo.so=1-64"), "libfoo.so");
        assert_eq!(provide_name("meson>=1.8"), "meson");
        assert_eq!(provide_name("meson<=1.8"), "meson");
        assert_eq!(provide_name("bare"), "bare");
    }

    #[test]
    fn provide_covers_generation_semantics() {
        assert!(provide_covers("libfoo.so", "libfoo.so.2"));
        assert!(provide_covers("libfoo.so=1-64", "libfoo.so.1"));
        assert!(!provide_covers("libfoo.so=1-64", "libfoo.so.2"));
        assert!(provide_covers("meson=1.8", "meson"));
        assert!(!provide_covers("meson=1.8", "ninja"));
    }

    #[test]
    fn stock_name_strips_only_vcs_suffixes() {
        assert_eq!(stock_name("meson-git"), "meson");
        assert_eq!(stock_name("foo-snapshot"), "foo");
        assert_eq!(stock_name("foo-bar"), "foo-bar");
    }

    #[test]
    fn split_constraint_matches_the_fish_regex() {
        assert_eq!(split_constraint("meson>=1.8"), Some(("meson", ">=", "1.8")));
        assert_eq!(split_constraint("a=b"), Some(("a", "=", "b")));
        assert_eq!(split_constraint("a>1"), Some(("a", ">", "1")));
        assert_eq!(split_constraint("a<1"), Some(("a", "<", "1")));
        assert_eq!(split_constraint("bare"), None);
        assert_eq!(split_constraint(""), None);
    }

    #[test]
    fn base_libs_and_exclusions() {
        assert!(base_lib_ok("libc.so.6"));
        assert!(!base_lib_ok("libfoo.so.1"));
        let exclusions = vec!["libfoo.so".to_string(), "meson-git".to_string()];
        assert!(excluded(&exclusions, "libfoo.so.1"));
        assert!(excluded(&exclusions, "meson-git"));
        assert!(!excluded(&exclusions, "libbar.so.1"));
    }
}
