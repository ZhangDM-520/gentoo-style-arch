//! Test support for `gsa-abi`'s unit tests: a minimal section-less ELF64
//! image builder (the same `object`-readable layout `gsa-recipe/src/elf.rs`'s
//! tests use — ehdr | PT_LOAD | PT_DYNAMIC | dyn entries | dynstr) and a
//! one-pass `.pkg.tar.zst` staging helper. `#[cfg(test)]` only.

use std::path::{Path, PathBuf};

/// One ELF64 `ET_DYN` image with the given `DT_SONAME` (optional) and
/// `DT_NEEDED` entries (in order).
pub fn elf64(soname: Option<&str>, needed: &[&str]) -> Vec<u8> {
    let mut dynstr = vec![0u8];
    let mut entries: Vec<(u64, u64)> = Vec::new();
    let push_str = |dynstr: &mut Vec<u8>, s: &str| -> u64 {
        let off = dynstr.len() as u64;
        dynstr.extend_from_slice(s.as_bytes());
        dynstr.push(0);
        off
    };
    if let Some(name) = soname {
        let off = push_str(&mut dynstr, name);
        entries.push((14u64, off)); // DT_SONAME
    }
    for name in needed {
        let off = push_str(&mut dynstr, name);
        entries.push((1u64, off)); // DT_NEEDED
    }
    // The string-table entries last so the offsets above are stable.
    let n_entries = entries.len() as u64 + 3; // DT_STRTAB, DT_STRSZ, DT_NULL
    let dynstr_off: u64 = 64 + 56 + 56 + 16 * n_entries;
    entries.push((5u64, dynstr_off)); // DT_STRTAB
    entries.push((10u64, dynstr.len() as u64)); // DT_STRSZ
    entries.push((0u64, 0u64)); // DT_NULL

    let total = dynstr_off + dynstr.len() as u64;
    let dyn_bytes = 16 * n_entries;
    let mut out = Vec::new();
    // ELF header
    out.extend_from_slice(&[0x7f, b'E', b'L', b'F', 2, 1, 1, 0]);
    out.extend_from_slice(&[0u8; 8]);
    out.extend_from_slice(&3u16.to_le_bytes()); // ET_DYN
    out.extend_from_slice(&62u16.to_le_bytes()); // EM_X86_64
    out.extend_from_slice(&1u32.to_le_bytes());
    out.extend_from_slice(&0u64.to_le_bytes()); // e_entry
    out.extend_from_slice(&64u64.to_le_bytes()); // e_phoff
    out.extend_from_slice(&0u64.to_le_bytes()); // e_shoff
    out.extend_from_slice(&0u32.to_le_bytes());
    out.extend_from_slice(&64u16.to_le_bytes()); // e_ehsize
    out.extend_from_slice(&56u16.to_le_bytes()); // e_phentsize (Elf64_Phdr)
    out.extend_from_slice(&2u16.to_le_bytes()); // e_phnum
    out.extend_from_slice(&64u16.to_le_bytes()); // e_shentsize
    out.extend_from_slice(&0u16.to_le_bytes()); // e_shnum
    out.extend_from_slice(&0u16.to_le_bytes()); // e_shstrndx
                                                // PT_LOAD covering the whole file
    out.extend_from_slice(&1u32.to_le_bytes());
    out.extend_from_slice(&5u32.to_le_bytes());
    out.extend_from_slice(&0u64.to_le_bytes());
    out.extend_from_slice(&0u64.to_le_bytes());
    out.extend_from_slice(&0u64.to_le_bytes());
    out.extend_from_slice(&total.to_le_bytes());
    out.extend_from_slice(&total.to_le_bytes());
    out.extend_from_slice(&0x1000u64.to_le_bytes());
    // PT_DYNAMIC
    out.extend_from_slice(&2u32.to_le_bytes());
    out.extend_from_slice(&6u32.to_le_bytes());
    out.extend_from_slice(&176u64.to_le_bytes());
    out.extend_from_slice(&176u64.to_le_bytes());
    out.extend_from_slice(&176u64.to_le_bytes());
    out.extend_from_slice(&dyn_bytes.to_le_bytes());
    out.extend_from_slice(&dyn_bytes.to_le_bytes());
    out.extend_from_slice(&8u64.to_le_bytes());
    // Dynamic entries
    for (tag, val) in entries {
        out.extend_from_slice(&tag.to_le_bytes());
        out.extend_from_slice(&val.to_le_bytes());
    }
    out.extend_from_slice(&dynstr);
    out
}

/// One staged `.pkg.tar.zst` archive: `.PKGINFO` from `pkginfo_lines`
/// (already `key = value` shaped) plus, when given, one ELF member at
/// `usr/lib/<soname-ish>.so` carrying the soname and needed set.
pub fn make_archive(
    dir: &Path,
    name: &str,
    version: &str,
    pkginfo_lines: &[&str],
    elf: Option<(&str, &[&str])>,
) -> PathBuf {
    let stage = dir.join(format!("stage-{name}-{}", version.replace([':', '/'], "_")));
    std::fs::create_dir_all(&stage).unwrap();
    let mut body = String::new();
    body.push_str(&format!("pkgbase = {name}\n"));
    body.push_str(&format!("pkgname = {name}\n"));
    body.push_str(&format!("pkgver = {version}\n"));
    body.push_str("arch = any\n");
    for line in pkginfo_lines {
        body.push_str(line);
        body.push('\n');
    }
    std::fs::write(stage.join(".PKGINFO"), &body).unwrap();
    if let Some((soname, needed)) = elf {
        std::fs::create_dir_all(stage.join("usr/lib")).unwrap();
        let file_name = soname.split('/').next_back().unwrap_or(soname);
        std::fs::write(
            stage.join("usr/lib").join(file_name),
            elf64(Some(soname), needed),
        )
        .unwrap();
    }
    let out = dir.join(format!(
        "{name}-{version}-any.pkg.tar.zst",
        version = version.replace(':', "_")
    ));
    let file = std::fs::File::create(&out).unwrap();
    let enc = zstd::stream::Encoder::new(file, 0).unwrap();
    let mut tar = tar::Builder::new(enc);
    tar.append_dir_all(".", &stage).unwrap();
    let enc = tar.into_inner().unwrap();
    enc.finish().unwrap();
    let _ = std::fs::remove_dir_all(&stage);
    out
}
