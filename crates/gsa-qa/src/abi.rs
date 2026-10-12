//! The ABI name vocabulary the checks share (fish `abi_*` / `_*_lint_*`
//! helpers in `build-all.fish` + `lib/audit.fish`).
//!
//! These are small, pure functions with one semantics each. `gsa-install`
//! carries its own copies for the install gates (`localdb.rs`, `gates.rs`);
//! the duplication is deliberate — `gsa-install` depends on `gsa-qa` (the
//! decision hook), so `gsa-qa` cannot depend back on it without a cycle, and
//! lifting the vocabulary into `gsa-model` is a later cleanup. Both copies
//! are unit-tested against the same documented semantics.

/// The name half of a provide/depend entry (`libfoo.so=1-64` → `libfoo.so`,
/// `meson>=1.8` → `meson`) — fish `abi_provide_name` (version suffix
/// `[=<>].*$` stripped).
pub fn provide_name(entry: &str) -> &str {
    entry.split(['=', '<', '>']).next().unwrap_or("").trim()
}

/// The bare soname stem of a name (`libfoo.so` → `libfoo.so`,
/// `libfoo.so.1.2` → `libfoo.so`); `None` when the name is not
/// soname-shaped — fish `_lint_soname_stem`.
pub fn soname_stem(name: &str) -> Option<&str> {
    if name.ends_with(".so") {
        return Some(name);
    }
    let idx = name.find(".so.")?;
    Some(&name[..idx + 3])
}

/// Does one provide entry cover a dependency string? Bare soname provides
/// (`libfoo.so`, makepkg-auto-versioned to `libfoo.so=<ver>`) cover the
/// `libfoo.so.N` soname family; the auto-versioned form covers only its own
/// generation (`libfoo.so=1-64` covers `libfoo.so.1`, not `libfoo.so.2`).
/// A versioned NAME provide covers the name itself. Fish
/// `abi_provide_covers`; the same matcher `gsa-install::localdb::provide_covers`
/// documents as "the ONE matcher every resolution source shares".
pub fn provide_covers(provide: &str, dep: &str) -> bool {
    let (name, ver) = match provide.split_once('=') {
        Some((n, v)) => (n.trim(), Some(v.trim())),
        None => (provide.trim(), None),
    };
    if name.is_empty() || dep.is_empty() {
        return false;
    }
    if name == dep {
        return true;
    }
    if soname_stem(dep) == Some(name) {
        let Some(ver) = ver else {
            return true;
        };
        if ver.is_empty() {
            return true;
        }
        // `1-64` → `1`: makepkg's auto-version is `<generation>-<pkgrel-ish>`.
        let generation = match ver.rfind('-') {
            Some(idx) => &ver[..idx],
            None => ver,
        };
        return dep == format!("{name}.{generation}");
    }
    false
}

/// The Stock→house counterpart name (fish `abi_stock_name`): the VCS suffix
/// stripped, else the name unchanged.
pub fn stock_name(name: &str) -> String {
    for suffix in ["-git", "-svn", "-hg", "-snapshot"] {
        if let Some(stem) = name.strip_suffix(suffix) {
            return stem.to_string();
        }
    }
    name.to_string()
}

/// Expected base-system sonames — the glibc + gcc-libs runtime every Arch
/// system carries (fish `abi_base_lib_ok`'s list, byte-identical to
/// `gsa-install::gates::BASE_LIBS`). Any other non-workspace soname must
/// resolve through a provide, shipped bytes, an owned file, or the
/// exclusions registry.
pub const BASE_LIBS: &[&str] = &[
    "libc.so.6",
    "libm.so.6",
    "libmvec.so.1",
    "libdl.so.2",
    "libpthread.so.0",
    "librt.so.1",
    "libresolv.so.2",
    "libutil.so.1",
    "libnsl.so.1",
    "libthread_db.so.1",
    "ld-linux-x86-64.so.2",
    "ld-linux.so.2",
    "ld64.so.2",
    "libgcc_s.so.1",
    "libstdc++.so.6",
    "libgomp.so.1",
    "libatomic.so.1",
    "libquadmath.so.0",
];

/// Is this soname covered by the expected base-system runtime?
pub fn base_lib_ok(soname: &str) -> bool {
    BASE_LIBS.contains(&soname)
}

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
