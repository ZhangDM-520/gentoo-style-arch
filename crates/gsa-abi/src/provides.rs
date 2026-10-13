//! Shared provide/soname semantics — the ONE matcher every ABI surface
//! shares (`docs/MEMORY.md` rules 25(a)/25(b), `gsa-install::localdb`'s
//! original home). `gsa-install` and `gsa-abi` both resolve through these
//! functions; nothing here is re-implemented anywhere downstream.

/// Expected base-system sonames — the glibc + gcc-libs runtime every Arch
/// system carries (`base` depends on both). Any other non-workspace soname
/// must resolve through a provide, shipped bytes, an owned file, or the
/// exclusions registry (fish `abi_base_lib_ok`).
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

/// The name half of a provide/depend entry (`libfoo.so=1-64` → `libfoo.so`,
/// `meson>=1.8` → `meson`) — fish `abi_provide_name`.
pub fn provide_name(entry: &str) -> &str {
    entry.split(['=', '<', '>']).next().unwrap_or("").trim()
}

/// The bare soname stem of a provide NAME (`libfoo.so` or `libfoo.so.1.2` →
/// `libfoo.so`); `None` when the name is not soname-shaped — fish
/// `_lint_soname_stem`.
pub fn soname_stem(name: &str) -> Option<&str> {
    if name.ends_with(".so") {
        return Some(name);
    }
    let idx = name.find(".so.")?;
    Some(&name[..idx + 3])
}

/// Is a provide NAME soname-shaped (`libfoo.so` or `libfoo.so.N…`)? The
/// abi-token hashes bare-soname provides only (contract §J.4).
pub fn is_soname_name(name: &str) -> bool {
    soname_stem(name).is_some()
}

/// Does one provide entry cover a dependency string? Bare soname provides
/// (`libfoo.so`, makepkg-auto-versioned to `libfoo.so=<ver>`) cover the
/// `libfoo.so.N` soname family (`docs/MEMORY.md` rule 25(a)); a versioned
/// NAME provide covers the name itself (constraint satisfaction stays
/// pacman's job at transaction time). This is the ONE matcher every
/// resolution source shares (fish `abi_provide_covers`).
/// The auto-versioned form covers only its own generation: `libfoo.so=1-64`
/// covers `libfoo.so` and `libfoo.so.1` (the `-64` pkgrel-ish suffix
/// stripped) but NOT `libfoo.so.2`, so a bumped consumer NEEDED no longer
/// resolves to the old provider and the violation can name both sides.
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
/// stripped. A swap MOVES the surface to a new pkgname instead of vanishing
/// it, so "nothing installed for this pkgname" is not evidence that nothing
/// can disappear (run #31, bzip2-git).
pub fn stock_name(name: &str) -> String {
    for suffix in ["-git", "-svn", "-hg", "-snapshot"] {
        if let Some(stem) = name.strip_suffix(suffix) {
            return stem.to_string();
        }
    }
    name.to_string()
}

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
