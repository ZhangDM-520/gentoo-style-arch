//! Native ELF dynamic-section reads (`object` crate — never `readelf`):
//! the `DT_NEEDED` set of one ELF image, the input of the package-internal
//! NEEDED probe (contract §E, `docs/MEMORY.md` rule 25(b)/(e)).
//!
//! Resolution is the dynamic loader's own truth: the `PT_DYNAMIC` segment's
//! entries with `DT_STRTAB` mapped through the `PT_LOAD` segments — section
//! headers are never required, so a fully section-stripped image still
//! probes correctly.

use object::elf;
use object::read::elf::{Dyn, ElfFile, FileHeader, ProgramHeader};
use object::read::StringTable;

/// The `DT_NEEDED` sonames of one ELF image, in file order. Non-ELF bytes
/// yield an empty list (a member that is not an ELF has nothing to probe).
pub fn needed_libs(bytes: &[u8]) -> Vec<String> {
    match object::File::parse(bytes) {
        Ok(object::File::Elf32(file)) => needed_in(&file),
        Ok(object::File::Elf64(file)) => needed_in(&file),
        _ => Vec::new(),
    }
}

fn needed_in<'data, Elf: FileHeader>(file: &ElfFile<'data, Elf, &'data [u8]>) -> Vec<String> {
    let endian = file.endian();
    let data: &'data [u8] = file.data();
    let mut out = Vec::new();
    for segment in file.elf_program_headers() {
        let Ok(Some(dyns)) = segment.dynamic(endian, data) else {
            continue;
        };
        let mut strtab_addr: Option<u64> = None;
        let mut strtab_size: u64 = 0;
        for d in dyns {
            match d.tag32(endian) {
                Some(elf::DT_STRTAB) => strtab_addr = Some(d.d_val(endian).into()),
                Some(elf::DT_STRSZ) => strtab_size = d.d_val(endian).into(),
                _ => {}
            }
        }
        let Some(addr) = strtab_addr else {
            return out;
        };
        // Map the string table's virtual address to file offsets through the
        // PT_LOAD segments (the same mapping ld.so performs).
        let mut strtab_range: Option<(u64, u64)> = None;
        for ph in file.elf_program_headers() {
            if ph.p_type(endian) != elf::PT_LOAD {
                continue;
            }
            let vaddr: u64 = ph.p_vaddr(endian).into();
            let filesz: u64 = ph.p_filesz(endian).into();
            let offset: u64 = ph.p_offset(endian).into();
            if (vaddr..vaddr + filesz).contains(&addr) {
                let start = offset + (addr - vaddr);
                let end = start.saturating_add(strtab_size).min(data.len() as u64);
                strtab_range = Some((start, end));
                break;
            }
        }
        let Some((start, end)) = strtab_range else {
            return out;
        };
        let strtab = StringTable::new(data, start, end);
        for d in dyns {
            if d.tag32(endian) == Some(elf::DT_NEEDED) {
                if let Ok(name) = d.string(endian, strtab) {
                    out.push(String::from_utf8_lossy(name).into_owned());
                }
            }
        }
        return out;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A minimal section-less ELF64 image carrying one `DT_NEEDED` entry.
    /// Layout: ehdr (64) | PT_LOAD phdr (56) | PT_DYNAMIC phdr (56) |
    /// 4 dynamic entries (64) | dynstr.
    fn elf64_with_needed(soname: &str) -> Vec<u8> {
        let mut dynstr = vec![0u8];
        dynstr.extend_from_slice(soname.as_bytes());
        dynstr.push(0);
        let dynstr_off: u64 = 64 + 56 + 56 + 64;
        let total = dynstr_off + dynstr.len() as u64;

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
        out.extend_from_slice(&64u16.to_le_bytes());
        out.extend_from_slice(&56u16.to_le_bytes());
        out.extend_from_slice(&2u16.to_le_bytes()); // e_phnum
        out.extend_from_slice(&64u16.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
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
        out.extend_from_slice(&64u64.to_le_bytes());
        out.extend_from_slice(&64u64.to_le_bytes());
        out.extend_from_slice(&8u64.to_le_bytes());
        // Dynamic entries: DT_NEEDED, DT_STRTAB, DT_STRSZ, DT_NULL
        for (tag, val) in [
            (1u64, 1u64),
            (5u64, dynstr_off),
            (10u64, dynstr.len() as u64),
            (0u64, 0u64),
        ] {
            out.extend_from_slice(&tag.to_le_bytes());
            out.extend_from_slice(&val.to_le_bytes());
        }
        out.extend_from_slice(&dynstr);
        out
    }

    #[test]
    fn needed_libs_reads_dt_needed() {
        let bytes = elf64_with_needed("libmissing.so.1");
        assert_eq!(needed_libs(&bytes), vec!["libmissing.so.1".to_string()]);
    }

    #[test]
    fn needed_libs_is_empty_for_non_elf() {
        assert!(needed_libs(b"not an elf").is_empty());
        assert!(needed_libs(&[]).is_empty());
    }
}
