//! Shared ABI provide/soname/ELF-class semantics (`F-INS-04`, `F-QA-03`).
//!
//! `gsa-abi`, `gsa-install`, and `gsa-qa` all re-export from this module so
//! provide matching, soname stem extraction, base-system sonames, and ELF
//! class scoping (`usr/lib32/*` vs 64-bit, `-32` vs `-64` auto-versions) stay
//! single-sourced without a cyclic crate edge (`gsa-install` depends on both
//! `gsa-abi` and `gsa-qa`).

/// The ELF class a runtime file truth or soname provide claim must match
/// (Arch layout: the 32-bit ABI lives under `usr/lib32/`).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum ElfClass {
    X64,
    X32,
}

/// The class of an owned path by its lib directory (`usr/lib32/…` is 32-bit,
/// everything else is the dominant 64-bit ABI).
pub fn path_class(path: &str) -> ElfClass {
    let p = path.strip_prefix('/').unwrap_or(path);
    if p.starts_with("usr/lib32/") || p.starts_with("lib32/") {
        ElfClass::X32
    } else {
        ElfClass::X64
    }
}

/// The ELF class encoded in a makepkg auto-versioned provide (`libfoo.so=1-64`
/// → `Some(ElfClass::X64)`, `libfoo.so=1-32` → `Some(ElfClass::X32)`).
/// Unversioned or custom-versioned entries answer `None` (no class claim).
pub fn provide_class(provide: &str) -> Option<ElfClass> {
    let (_, ver) = provide.split_once('=')?;
    let ver = ver.trim();
    if ver.ends_with("-32") {
        Some(ElfClass::X32)
    } else if ver.ends_with("-64") {
        Some(ElfClass::X64)
    } else {
        None
    }
}

/// Expected base-system sonames — the glibc + gcc-libs runtime every Arch
/// system carries (`base` depends on both).
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

/// Is a provide NAME soname-shaped (`libfoo.so` or `libfoo.so.N…`)?
pub fn is_soname_name(name: &str) -> bool {
    soname_stem(name).is_some()
}

/// Does one provide entry cover a dependency string (without ELF-class scope)?
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

/// Does one provide entry cover a dependency string for a consumer in
/// `class`? Auto-versioned `-32`/`-64` soname provides only match their own
/// ELF class (`libfoo.so=1-32` never covers a 64-bit consumer's `libfoo.so.1`).
pub fn provide_covers_as(provide: &str, dep: &str, class: ElfClass) -> bool {
    if let Some(p_class) = provide_class(provide) {
        if p_class != class {
            return false;
        }
    }
    provide_covers(provide, dep)
}

/// The Stock→house counterpart name (fish `abi_stock_name`): the VCS suffix
/// stripped.
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
    fn provide_covers_as_separates_elf_classes() {
        assert!(provide_covers_as(
            "libfoo.so=1-64",
            "libfoo.so.1",
            ElfClass::X64
        ));
        assert!(!provide_covers_as(
            "libfoo.so=1-64",
            "libfoo.so.1",
            ElfClass::X32
        ));
        assert!(provide_covers_as(
            "libfoo.so=1-32",
            "libfoo.so.1",
            ElfClass::X32
        ));
        assert!(!provide_covers_as(
            "libfoo.so=1-32",
            "libfoo.so.1",
            ElfClass::X64
        ));
        assert!(provide_covers_as("libfoo.so", "libfoo.so.1", ElfClass::X32));
        assert!(provide_covers_as("libfoo.so", "libfoo.so.1", ElfClass::X64));
    }
}
