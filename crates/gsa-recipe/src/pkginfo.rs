//! Native package-archive metadata reads (contract §A.2.2/§J.4): `.PKGINFO`
//! out of `tar`+`zstd` (`.pkg.tar.zst`) archives, without shelling to
//! `tar`/`pacman`. The engine's read path never evaluates recipe shell, so
//! an archive's own `.PKGINFO` is the metadata truth for what a transaction
//! would install (rule 9's first name authority; `docs/MEMORY.md` rule 25).
//!
//! Also home of the PGO payload byte scan: a standalone absolute path ending
//! in `.gcda`/`.profraw` baked into any member (fish
//! `pgo_payload_refusals`'s `strings -a` predicate).

use std::cmp::Ordering;
use std::fs::File;
use std::io::{BufReader, Read};
use std::path::Path;

use tar::Archive as TarArchive;
use zstd::stream::read::Decoder;

/// One archive's `.PKGINFO` (`%BASE%`, `%NAME%`, `%VERSION%`/`%EPOCH%`,
/// `%PROVIDES%`, `%DEPENDS%`, `%ARCH%`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Pkginfo {
    /// `%BASE%` (falls back to `%NAME%` on old archives).
    pub pkgbase: String,
    /// `%NAME%` — one archive carries exactly one pkgname.
    pub pkgname: String,
    /// Canonical full version `epoch:pkgver-pkgrel` (epoch-0-normalized).
    pub version: String,
    /// Raw `%PROVIDES%` entries (`libfoo.so`, `bar=1.2`, …).
    pub provides: Vec<String>,
    /// Raw `%DEPENDS%` entries (`glibc>=2.28`, …).
    pub depends: Vec<String>,
    pub arch: String,
}

/// Why an archive's `.PKGINFO` could not be read (rule 25(h): never probed).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PkginfoError {
    /// The archive could not be opened/decoded at all.
    Io(String),
    /// The archive has no `.PKGINFO` member.
    Missing,
    /// `.PKGINFO` exists but a required field is absent or malformed.
    Malformed(String),
}

impl std::fmt::Display for PkginfoError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            PkginfoError::Io(m) => write!(f, "archive unreadable: {m}"),
            PkginfoError::Missing => write!(f, "no .PKGINFO member"),
            PkginfoError::Malformed(m) => write!(f, "malformed .PKGINFO: {m}"),
        }
    }
}

/// Canonical full version shared by [`Pkginfo::version`] and the installed
/// DB's `%VERSION%`: `epoch:pkgver-pkgrel` with the epoch always present
/// (`0:` when pacman recorded none), so exact version equality is one string
/// compare across both surfaces (`docs/MEMORY.md` rule 27(a) family).
pub fn canonical_version(raw: &str) -> String {
    if raw.contains(':') {
        raw.to_string()
    } else {
        format!("0:{raw}")
    }
}

/// Order two canonical versions for archive/set selection, HIGHER FIRST —
/// the `sort_by` comparator the discovery seams share. `Ordering::Equal`
/// covers both a genuine version tie and a `vercmp` non-answer (the tool is
/// absent from `PATH`, or its output is unparseable): the caller's mtime
/// order then decides, which is the fish reference's fallback. Lexical
/// order must never stand in — epochs and `1.10` vs `1.9` defeat it.
pub fn version_rank(a: &str, b: &str) -> Ordering {
    match crate::sync::vercmp(a, b) {
        Some(cmp) => cmp.cmp(&0).reverse(),
        None => Ordering::Equal,
    }
}

/// The `.PKGINFO` member name, accepting packer spelling drift
/// (`.PKGINFO` vs `./.PKGINFO`) and nothing else.
fn is_pkginfo_member(name: &str) -> bool {
    name == ".PKGINFO" || name == "./.PKGINFO"
}

/// Open one archive as a streamed tar-over-zstd reader. `Err` = the archive
/// could not be decoded at all (the fail-closed `pgo-unreadable` /
/// unreadable-`.PKGINFO` class).
fn open_archive(archive: &Path) -> Result<TarArchive<Decoder<'static, BufReader<File>>>, String> {
    let file = File::open(archive).map_err(|e| e.to_string())?;
    let decoder = Decoder::new(file).map_err(|e| e.to_string())?;
    Ok(TarArchive::new(decoder))
}

/// Parse one `.PKGINFO` body: `key = value` lines, repeated `provides`/
/// `depends` accumulate. `pkgname`, `pkgver` and `arch` are required (makepkg
/// always writes them); `pkgbase` falls back to `pkgname` (old archives).
///
/// Version normalization: `.PKGINFO`'s `pkgver` value already carries
/// `pkgver-pkgrel` (makepkg writes the full version there) and `epoch` is a
/// separate line; the canonical form is `epoch:pkgver-pkgrel` with epoch 0
/// included. A separate `pkgrel` key (never emitted by makepkg, tolerated
/// for hand-built archives) is appended only when the `pkgver` value does
/// not already end in `-<pkgrel>`; a `pkgver` without any pkgrel is kept
/// verbatim, epoch-prefixed.
fn parse_pkginfo_body(body: &str) -> Result<Pkginfo, PkginfoError> {
    let mut pkgbase: Option<String> = None;
    let mut pkgname: Option<String> = None;
    let mut pkgver: Option<String> = None;
    let mut pkgrel: Option<String> = None;
    let mut epoch: Option<String> = None;
    let mut arch: Option<String> = None;
    let mut provides: Vec<String> = Vec::new();
    let mut depends: Vec<String> = Vec::new();

    for raw_line in body.lines() {
        let line = raw_line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let Some((key, value)) = line.split_once('=') else {
            continue;
        };
        let key = key.trim();
        let value = value.trim();
        if value.is_empty() {
            continue;
        }
        match key {
            "pkgbase" => pkgbase = Some(value.to_string()),
            "pkgname" => pkgname = Some(value.to_string()),
            "pkgver" => pkgver = Some(value.to_string()),
            "pkgrel" => pkgrel = Some(value.to_string()),
            "epoch" => epoch = Some(value.to_string()),
            "arch" => {
                if arch.is_none() {
                    arch = Some(value.to_string());
                }
            }
            "provides" => provides.push(value.to_string()),
            "depends" => depends.push(value.to_string()),
            _ => {}
        }
    }

    let pkgname = pkgname.ok_or_else(|| PkginfoError::Malformed("missing pkgname".to_string()))?;
    let pkgver = pkgver.ok_or_else(|| PkginfoError::Malformed("missing pkgver".to_string()))?;
    let arch = arch.ok_or_else(|| PkginfoError::Malformed("missing arch".to_string()))?;
    let epoch = match epoch {
        Some(e) => {
            if e.parse::<u64>().is_err() {
                return Err(PkginfoError::Malformed(format!("bad epoch '{e}'")));
            }
            e
        }
        None => "0".to_string(),
    };
    let ver = match pkgrel {
        Some(rel) if !pkgver.ends_with(&format!("-{rel}")) => format!("{pkgver}-{rel}"),
        _ => pkgver,
    };

    Ok(Pkginfo {
        pkgbase: pkgbase.unwrap_or_else(|| pkgname.clone()),
        pkgname,
        version: canonical_version(&format!("{epoch}:{ver}")),
        provides,
        depends,
        arch,
    })
}

/// Read one archive's `.PKGINFO` natively (zstd frame + tar member scan).
pub fn read_pkginfo(archive: &Path) -> Result<Pkginfo, PkginfoError> {
    let mut tar = open_archive(archive).map_err(PkginfoError::Io)?;
    let entries = tar.entries().map_err(|e| PkginfoError::Io(e.to_string()))?;
    for entry in entries {
        let mut entry = entry.map_err(|e| PkginfoError::Io(e.to_string()))?;
        let name = entry
            .path()
            .map_err(|e| PkginfoError::Io(e.to_string()))?
            .to_string_lossy()
            .into_owned();
        if !is_pkginfo_member(&name) {
            continue;
        }
        let mut body = String::new();
        entry
            .read_to_string(&mut body)
            .map_err(|e| PkginfoError::Io(e.to_string()))?;
        return parse_pkginfo_body(&body);
    }
    Err(PkginfoError::Missing)
}

/// Every member name of one archive, in archive order (streamed; the names
/// alone are kept). `Err` = the archive could not be read.
pub fn member_names(archive: &Path) -> Result<Vec<String>, String> {
    let mut tar = open_archive(archive)?;
    let entries = tar.entries().map_err(|e| e.to_string())?;
    let mut names = Vec::new();
    for entry in entries {
        let entry = entry.map_err(|e| e.to_string())?;
        names.push(
            entry
                .path()
                .map_err(|e| e.to_string())?
                .to_string_lossy()
                .into_owned(),
        );
    }
    Ok(names)
}

/// One member's `DT_NEEDED` list, per member, in archive order (members that
/// are not ELF contribute an empty list). Read one member at a time — memory
/// is bounded by the largest single member. `Err` = the archive could not be
/// read.
pub fn members_with_needed(archive: &Path) -> Result<Vec<(String, Vec<String>)>, String> {
    Ok(members_with_dynamic(archive)?
        .into_iter()
        .map(|(name, _, needed)| (name, needed))
        .collect())
}

/// One member's dynamic surface, per member, in archive order:
/// `(member, DT_SONAME, DT_NEEDED)` — the ABI closure lint's per-member
/// probe (fish `readelf -dW` rows). Non-ELF members contribute `None` and an
/// empty list. Read one member at a time — memory is bounded by the largest
/// single member. `Err` = the archive could not be read.
pub fn members_with_dynamic(
    archive: &Path,
) -> Result<Vec<(String, Option<String>, Vec<String>)>, String> {
    let mut tar = open_archive(archive)?;
    let entries = tar.entries().map_err(|e| e.to_string())?;
    let mut out = Vec::new();
    for entry in entries {
        let mut entry = entry.map_err(|e| e.to_string())?;
        let name = entry
            .path()
            .map_err(|e| e.to_string())?
            .to_string_lossy()
            .into_owned();
        let mut bytes = Vec::new();
        entry.read_to_end(&mut bytes).map_err(|e| e.to_string())?;
        let soname = crate::elf::soname(&bytes);
        let needed = crate::elf::needed_libs(&bytes);
        out.push((name, soname, needed));
    }
    Ok(out)
}

/// Does this token — a maximal printable-ASCII run with no whitespace — name
/// a baked profiling destination? Exactly the fish predicate
/// `^/[^[:space:]/*][^[:space:]]*\.(gcda|profraw)$`: a STANDALONE absolute
/// path. The char class after the leading slash excludes `/` and `*`, so the
/// glob literal `/*.gcda` (CMake's own GCOV support) never hits while a real
/// baked `/build/x/y.gcda` destination does. Tokens carry no whitespace by
/// construction (the scanner splits on it), so the `[^\s]` classes are
/// already satisfied.
fn pgo_token_hit(token: &[u8]) -> bool {
    if token.len() < 2 || token[0] != b'/' {
        return false;
    }
    if token[1] == b'/' || token[1] == b'*' {
        return false;
    }
    token.ends_with(b".gcda") || token.ends_with(b".profraw")
}

/// Streaming token scanner over member bytes: maximal runs of printable
/// non-space ASCII (0x21..=0x7E) are tokens; a run longer than the cap is
/// discarded (it cannot be a realistic profile destination and must not grow
/// memory without bound).
#[derive(Default)]
struct PgoScanner {
    current: Vec<u8>,
    overflowed: bool,
}

const PGO_TOKEN_CAP: usize = 8192;

impl PgoScanner {
    /// Feed one chunk; true when a hit was seen in this chunk.
    fn feed(&mut self, chunk: &[u8]) -> bool {
        let mut hit = false;
        for &b in chunk {
            if (0x21..=0x7e).contains(&b) {
                if !self.overflowed {
                    if self.current.len() >= PGO_TOKEN_CAP {
                        self.overflowed = true;
                        self.current.clear();
                    } else {
                        self.current.push(b);
                    }
                }
            } else {
                if !self.overflowed && pgo_token_hit(&self.current) {
                    hit = true;
                }
                self.current.clear();
                self.overflowed = false;
            }
        }
        hit
    }

    fn finish(&mut self) -> bool {
        let hit = !self.overflowed && pgo_token_hit(&self.current);
        self.current.clear();
        self.overflowed = false;
        hit
    }
}

/// Member names carrying a baked profiling destination — a standalone
/// absolute path ending in `.gcda`/`.profraw` (fish `pgo_payload_refusals`
/// predicate; glob literals like `/*.gcda` do NOT hit). Scan is streamed
/// over member bytes in bounded memory. `Err` = the archive could not be
/// scanned → the caller refuses `pgo-unreadable` (fail closed).
pub fn pgo_hits(archive: &Path) -> Result<Vec<String>, String> {
    let mut tar = open_archive(archive)?;
    let entries = tar.entries().map_err(|e| e.to_string())?;
    let mut hits: Vec<String> = Vec::new();
    for entry in entries {
        let mut entry = entry.map_err(|e| e.to_string())?;
        let name = entry
            .path()
            .map_err(|e| e.to_string())?
            .to_string_lossy()
            .into_owned();
        let mut scanner = PgoScanner::default();
        let mut found = false;
        let mut buf = [0u8; 64 * 1024];
        loop {
            let n = entry.read(&mut buf).map_err(|e| e.to_string())?;
            if n == 0 {
                break;
            }
            if scanner.feed(&buf[..n]) {
                found = true;
            }
        }
        if scanner.finish() {
            found = true;
        }
        if found && !hits.contains(&name) {
            hits.push(name);
        }
    }
    hits.sort();
    Ok(hits)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir =
            std::env::temp_dir().join(format!("gsa-pkginfo-test-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    fn write_archive(path: &Path, entries: &[(&str, &[u8])]) {
        let file = File::create(path).unwrap();
        let enc = zstd::Encoder::new(file, 0).unwrap();
        let mut builder = tar::Builder::new(enc);
        for (name, data) in entries {
            let mut header = tar::Header::new_gnu();
            header.set_size(data.len() as u64);
            header.set_mode(0o644);
            header.set_cksum();
            builder.append_data(&mut header, name, *data).unwrap();
        }
        let enc = builder.into_inner().unwrap();
        enc.finish().unwrap();
    }

    #[test]
    fn read_pkginfo_parses_and_normalizes_the_version() {
        let dir = scratch("read");
        let archive = dir.join("foo-0:1.2.3-1-x86_64.pkg.tar.zst");
        write_archive(
            &archive,
            &[(
                ".PKGINFO",
                b"pkgbase = foo\npkgname = foo\nepoch = 2\npkgver = 1.2.3-1\narch = x86_64\nprovides = libfoo.so=1-64\nprovides = bar=1.0\ndepends = glibc>=2.28\n",
            )],
        );
        let info = read_pkginfo(&archive).unwrap();
        assert_eq!(info.pkgbase, "foo");
        assert_eq!(info.pkgname, "foo");
        assert_eq!(info.version, "2:1.2.3-1");
        assert_eq!(info.provides, vec!["libfoo.so=1-64", "bar=1.0"]);
        assert_eq!(info.depends, vec!["glibc>=2.28"]);
        assert_eq!(info.arch, "x86_64");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn read_pkginfo_epoch_zero_and_pkgbase_fallback() {
        let dir = scratch("fallback");
        let archive = dir.join("foo.pkg.tar.zst");
        write_archive(
            &archive,
            &[("./.PKGINFO", b"pkgname = foo\npkgver = 1.0-1\narch = any\n")],
        );
        let info = read_pkginfo(&archive).unwrap();
        assert_eq!(info.pkgbase, "foo");
        assert_eq!(info.version, "0:1.0-1");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn read_pkginfo_reports_missing_malformed_and_io() {
        let dir = scratch("errors");
        let no_member = dir.join("a.pkg.tar.zst");
        write_archive(&no_member, &[("usr/bin/x", b"hi")]);
        assert_eq!(read_pkginfo(&no_member), Err(PkginfoError::Missing));

        let malformed = dir.join("b.pkg.tar.zst");
        write_archive(&malformed, &[(".PKGINFO", b"pkgver = 1.0-1\narch = any\n")]);
        assert!(matches!(
            read_pkginfo(&malformed),
            Err(PkginfoError::Malformed(_))
        ));

        let garbage = dir.join("c.pkg.tar.zst");
        std::fs::write(&garbage, b"not an archive at all").unwrap();
        assert!(matches!(read_pkginfo(&garbage), Err(PkginfoError::Io(_))));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn pgo_hits_names_the_offending_member_and_ignores_glob_literals() {
        let dir = scratch("pgo");
        let archive = dir.join("foo.pkg.tar.zst");
        let mut data = Vec::new();
        data.extend_from_slice(b"\x7fELF noise ");
        data.extend_from_slice(b"/build/pkg/src/x.gcda");
        data.extend_from_slice(b" tail ");
        write_archive(
            &archive,
            &[
                (".PKGINFO", b"pkgname = foo\npkgver = 1-1\narch = x86_64\n"),
                ("usr/bin/foo", &data),
                ("usr/bin/cctest", b"coverage output goes to /*.gcda glob"),
                ("usr/share/doc/note.txt", b"/home/user/profile.profraw"),
            ],
        );
        let hits = pgo_hits(&archive).unwrap();
        assert_eq!(
            hits,
            vec![
                "usr/bin/foo".to_string(),
                "usr/share/doc/note.txt".to_string()
            ]
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn pgo_hits_rejects_an_undecodable_archive() {
        let dir = scratch("pgo-bad");
        let archive = dir.join("foo.pkg.tar.zst");
        std::fs::write(&archive, b"garbage").unwrap();
        assert!(pgo_hits(&archive).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn canonical_version_prefixes_epoch_zero() {
        assert_eq!(canonical_version("1.2-1"), "0:1.2-1");
        assert_eq!(canonical_version("2:1.2-1"), "2:1.2-1");
    }

    #[test]
    fn member_walks_stay_streamed() {
        let dir = scratch("walks");
        let archive = dir.join("foo.pkg.tar.zst");
        write_archive(
            &archive,
            &[
                (".PKGINFO", b"pkgname = foo\npkgver = 1-1\narch = x86_64\n"),
                ("usr/bin/foo", b"data"),
            ],
        );
        let names = member_names(&archive).unwrap();
        assert_eq!(
            names,
            vec![".PKGINFO".to_string(), "usr/bin/foo".to_string()]
        );
        let needed = members_with_needed(&archive).unwrap();
        assert_eq!(needed.len(), 2);
        assert!(needed[1].1.is_empty());
        let mut sink = Vec::new();
        write!(&mut sink, "{}", names.len()).unwrap();
        let _ = std::fs::remove_dir_all(&dir);
    }
}
