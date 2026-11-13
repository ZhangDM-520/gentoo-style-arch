//! Shared provide/soname semantics — re-exported from [`gsa_model::abi`]
//! (`AGENTS.md` rules 25(a)/25(b)). `gsa-install`, `gsa-abi`, and `gsa-qa`
//! all share that one definition without duplicating logic.

pub use gsa_model::abi::{
    base_lib_ok, is_soname_name, provide_class, provide_covers, provide_covers_as, provide_name,
    soname_stem, stock_name, BASE_LIBS,
};

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn provide_name_strips_every_constraint_spelling() {
        assert_eq!(provide_name("libfoo.so=1-64"), "libfoo.so");
        assert_eq!(provide_name("meson>=1.8"), "meson");
        assert_eq!(provide_name("meson"), "meson");
    }

    #[test]
    fn soname_stem_shapes() {
        assert_eq!(soname_stem("libfoo.so"), Some("libfoo.so"));
        assert_eq!(soname_stem("libfoo.so.1.2"), Some("libfoo.so"));
        assert_eq!(soname_stem("meson"), None);
        assert_eq!(soname_stem("sowhat"), None);
    }

    #[test]
    fn auto_versioned_provides_cover_only_their_generation() {
        assert!(provide_covers("libfoo.so=1-64", "libfoo.so"));
        assert!(provide_covers("libfoo.so=1-64", "libfoo.so.1"));
        assert!(!provide_covers("libfoo.so=1-64", "libfoo.so.2"));
        assert!(provide_covers("libfoo.so", "libfoo.so.7"));
        assert!(provide_covers("libfoo.so", "libfoo.so"));
    }

    #[test]
    fn stock_name_strips_vcs_suffixes() {
        assert_eq!(stock_name("bzip2-git"), "bzip2");
        assert_eq!(stock_name("foo-snapshot"), "foo");
        assert_eq!(stock_name("foo"), "foo");
    }
}
