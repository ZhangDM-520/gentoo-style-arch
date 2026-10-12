//! Registry semantics end to end (contract §E.4, §D.1, §G): name/keyword
//! resolution, the severity enforcement (the five audit lints can NEVER
//! produce a refuse row), the refusing check's exact rows, and the
//! `--qa-check` seam's rc classes. Scratch workspaces live under the test
//! process's temp dir and are removed at the end — nothing here is mutating.

use std::io::Write;
use std::path::{Path, PathBuf};

use gsa_qa::input::{collect_archives, load_workspace, QaArchive, QaInput, QaRecipe};
use gsa_qa::{registry, CheckHandle, Severity};

/// One scratch tree per test binary invocation (parallel-safe), removed by
/// `Cleanup`.
struct Scratch {
    root: PathBuf,
}

impl Scratch {
    fn new(tag: &str) -> Scratch {
        let root = std::env::temp_dir().join(format!("gsa-qa-tests-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("config")).unwrap();
        std::fs::create_dir_all(root.join("packages")).unwrap();
        std::fs::write(
            root.join("config/build-defaults.conf"),
            "lanes=1\njobs=1\nintensity=low\nmemory_per_job_gib=3\n\
             core_memory_per_job_gib=4\nreserved_memory_gib=2\nstate_dir=auto\n",
        )
        .unwrap();
        Scratch { root }
    }

    /// One recipe with a committed `.SRCINFO` (verbatim body) and its
    /// topology record (a no-edge record). A `PKGBUILD` stub satisfies the
    /// topology loader's existence probe (the engine never evaluates it).
    fn recipe(&self, id: &str, srcinfo: &str) {
        let dir = self.root.join("packages").join(id);
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(".SRCINFO"), srcinfo).unwrap();
        std::fs::write(dir.join("PKGBUILD"), format!("pkgname={id}\n")).unwrap();
        let record = format!("{id}|packages/{id}|git|\n");
        let mut conf = std::fs::OpenOptions::new()
            .append(true)
            .open(self.root.join("config/topology.conf"))
            .or_else(|_| {
                std::fs::write(self.root.join("config/topology.conf"), "")?;
                std::fs::OpenOptions::new()
                    .append(true)
                    .open(self.root.join("config/topology.conf"))
            })
            .unwrap();
        conf.write_all(record.as_bytes()).unwrap();
    }

    /// One built archive beside its recipe (`.PKGINFO` truth only).
    fn archive(&self, recipe_id: &str, pkgbase: &str, pkgname: &str) -> PathBuf {
        self.archive_with_member(recipe_id, pkgbase, pkgname, None)
    }

    /// The same, optionally shipping one member's bytes (the ELF a
    /// `DT_SONAME` probe reads).
    fn archive_with_member(
        &self,
        recipe_id: &str,
        pkgbase: &str,
        pkgname: &str,
        member: Option<(&str, Vec<u8>)>,
    ) -> PathBuf {
        let dir = self.root.join("packages").join(recipe_id);
        let path = dir.join(format!("{pkgname}-1.0.0-1-any.pkg.tar.zst"));
        let pkginfo =
            format!("pkgbase = {pkgbase}\npkgname = {pkgname}\npkgver = 1.0.0-1\narch = any\n");
        let file = std::fs::File::create(&path).unwrap();
        let enc = zstd::stream::write::Encoder::new(file, 0).unwrap();
        let mut tar = tar::Builder::new(enc);
        let mut header = tar::Header::new_gnu();
        header.set_size(pkginfo.len() as u64);
        header.set_mode(0o644);
        header.set_cksum();
        tar.append_data(&mut header, ".PKGINFO", pkginfo.as_bytes())
            .unwrap();
        if let Some((name, bytes)) = member {
            let mut header = tar::Header::new_gnu();
            header.set_size(bytes.len() as u64);
            header.set_mode(0o755);
            header.set_cksum();
            tar.append_data(&mut header, name, bytes.as_slice())
                .unwrap();
        }
        let enc = tar.into_inner().unwrap();
        enc.finish().unwrap();
        path
    }
}

/// A minimal section-less ELF64 image (ET_DYN) carrying exactly one
/// `DT_SONAME` — the byte layout after `crates/gsa-recipe/src/elf.rs`'s
/// oracle: ehdr | PT_LOAD | PT_DYNAMIC | dynamic entries | dynstr.
fn elf64_with_soname(name: &str) -> Vec<u8> {
    let mut dynstr = vec![0u8];
    dynstr.extend_from_slice(name.as_bytes());
    dynstr.push(0);
    let dynstr_off: u64 = 64 + 56 + 56 + 16 * 4;
    let total = dynstr_off + dynstr.len() as u64;
    let mut out = Vec::new();
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
    out.extend_from_slice(&56u16.to_le_bytes()); // e_phentsize
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
    // PT_DYNAMIC at 176 (after ehdr + 2 phdrs), 4 entries wide
    out.extend_from_slice(&2u32.to_le_bytes());
    out.extend_from_slice(&6u32.to_le_bytes());
    out.extend_from_slice(&176u64.to_le_bytes());
    out.extend_from_slice(&176u64.to_le_bytes());
    out.extend_from_slice(&176u64.to_le_bytes());
    out.extend_from_slice(&64u64.to_le_bytes());
    out.extend_from_slice(&64u64.to_le_bytes());
    out.extend_from_slice(&8u64.to_le_bytes());
    // DT_SONAME=14, DT_STRTAB=5, DT_STRSZ=10, DT_NULL=0
    for (tag, val) in [
        (14u64, 1u64),
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

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

fn run_seam(argv: &[&str], root: &Path) -> (i32, String, String) {
    let argv: Vec<String> = argv.iter().map(|s| s.to_string()).collect();
    let mut out = Vec::new();
    let mut err = Vec::new();
    let code = gsa_qa::seam::run_qa_check(&argv, root, &[], &mut out, &mut err);
    (
        code,
        String::from_utf8_lossy(&out).into_owned(),
        String::from_utf8_lossy(&err).into_owned(),
    )
}

#[test]
fn registry_resolves_every_keyword_with_its_scope_and_severity() {
    let registry = registry();
    for (name, scope, severity) in [
        ("provides-versioning", "recipe", Severity::Report),
        ("purged-tools", "recipe", Severity::Report),
        ("swap-drift", "installed-db", Severity::Report),
        ("abi-closure", "archive", Severity::Report),
        ("abi-exposure", "installed-db", Severity::Report),
        ("stale-ignorepkg", "archive", Severity::InstallRefusing),
    ] {
        let handle = registry
            .lookup(name)
            .unwrap_or_else(|| panic!("{name} must resolve"));
        assert_eq!(handle.name(), name);
        assert_eq!(handle.scope().as_str(), scope, "{name} scope");
        assert_eq!(handle.severity(), severity, "{name} severity");
    }
    // A keyword is exact: no fuzzy resolution of a near miss.
    assert!(registry.lookup("provides-versioningx").is_none());
    assert!(registry.lookup("stale_ignorepkg").is_none());
}

#[test]
fn the_five_lints_can_never_produce_a_refuse_row() {
    // One recipe breaking every lint: a versioned soname provide and a
    // purged tool (recipe scope), a VCS-suffixed output with no stock
    // counterpart (swap-drift) and an installed stock carrying a different
    // soname surface (abi-exposure), plus an archive shipping a DT_SONAME
    // the recipe never declares (abi-closure).
    let scratch = Scratch::new("report-only");
    scratch.recipe(
        "kit-git",
        "pkgbase = kit-git\npkgname = kit-git\npkgver = 1.0.0\npkgrel = 1\n\
         provides = libx.so.1\nmakedepends = cuda\n",
    );
    scratch.archive_with_member(
        "kit-git",
        "kit-git",
        "kit-git",
        Some(("usr/lib/libq.so.1", elf64_with_soname("libq.so.1"))),
    );
    let workspace = load_workspace(&scratch.root).unwrap();
    let recipes: Vec<QaRecipe> = workspace.recipes.clone();
    let archives = collect_archives(&recipes, &[]);
    let installed = vec![gsa_qa::QaInstalled {
        name: "kit".to_string(),
        version: "1.0.0-1".to_string(),
        provides: vec!["liby.so=2-64".to_string()],
        depends: Vec::new(),
    }];
    let input = QaInput {
        recipes: &recipes,
        targets: &[],
        archives: &archives,
        installed: &installed,
        exclusions: &workspace.exclusions,
    };

    let findings = gsa_qa::report::report_findings(&input);
    let checks: std::collections::BTreeSet<&str> = findings.iter().map(|f| f.check).collect();
    for lint in [
        "provides-versioning",
        "purged-tools",
        "swap-drift",
        "abi-closure",
        "abi-exposure",
    ] {
        assert!(
            checks.contains(lint),
            "{lint} must report its staged violation; saw {checks:?} in {findings:?}"
        );
    }

    // The enforcement: none of those findings can reach a decision row.
    let rows = gsa_qa::gate::install_refusals(&input);
    assert!(
        rows.is_empty(),
        "report-severity findings must never become refuse rows: {rows:?}"
    );
    // And every lint is a Report handle — `refuse_rows` takes a
    // `Check<MayRefuse>`, a type these cannot occupy (compile-time).
    let registry = registry();
    for lint in [
        "provides-versioning",
        "purged-tools",
        "swap-drift",
        "abi-closure",
        "abi-exposure",
    ] {
        assert!(
            matches!(registry.lookup(lint), Some(CheckHandle::Report(_))),
            "{lint} must be registered as ReportOnly"
        );
    }
    assert!(registry
        .refusing_checks()
        .iter()
        .all(|check| check.name == "stale-ignorepkg"));
}

#[test]
fn the_refusing_check_emits_exactly_its_rows() {
    // A stale archive: its .PKGINFO names a pkgbase the recipe never
    // declares (the pkgname does — discovery keeps the candidate).
    let scratch = Scratch::new("refusing");
    scratch.recipe(
        "stale",
        "pkgbase = stale\npkgname = stale\npkgver = 1.0.0\npkgrel = 1\n",
    );
    scratch.archive("stale", "stale-ghost", "stale");
    // A second recipe breaking a lint next door: it must add NO rows.
    scratch.recipe(
        "noisy",
        "pkgbase = noisy\npkgname = noisy\nmakedepends = cuda\n",
    );
    scratch.archive("noisy", "noisy", "noisy");

    let workspace = load_workspace(&scratch.root).unwrap();
    let archives = collect_archives(&workspace.recipes, &[]);
    let input = QaInput {
        recipes: &workspace.recipes,
        targets: &[],
        archives: &archives,
        installed: &[],
        exclusions: &workspace.exclusions,
    };
    let rows = gsa_qa::gate::install_refusals(&input);
    assert_eq!(rows.len(), 1, "exactly the stale archive refuses: {rows:?}");
    assert_eq!(rows[0].subject, "stale-ghost");
    assert_eq!(rows[0].decision, gsa_model::Decision::Refuse);
    assert!(
        rows[0].reason.starts_with("stale-ignorepkg "),
        "{}",
        rows[0].reason
    );
    assert!(
        rows[0].reason.ends_with("stale-ghost not-declared"),
        "{}",
        rows[0].reason
    );
}

#[test]
fn the_qa_check_seam_runs_one_named_check_and_classifies_rc_per_g() {
    let scratch = Scratch::new("seam");
    scratch.recipe(
        "viol",
        "pkgbase = viol\npkgname = viol\npkgver = 1.0.0\npkgrel = 1\nmakedepends = cuda\n",
    );
    scratch.recipe(
        "clean",
        "pkgbase = clean\npkgname = clean\npkgver = 1.0.0\npkgrel = 1\n",
    );
    scratch.archive("viol", "viol-ghost", "viol");

    // Report-severity findings never change rc (§G): rc 0 with findings.
    let (code, out, err) = run_seam(&["purged-tools"], &scratch.root);
    assert_eq!(code, 0, "report findings are rc 0: {err}");
    assert!(
        out.contains("purged-tools: viol: makedepends reintroduces purged tool 'cuda'"),
        "{out}"
    );
    assert!(out.contains("qa-check purged-tools: 1 finding(s)"), "{out}");

    // The focus filter: a clean recipe alone is clean.
    let (code, out, _err) = run_seam(&["purged-tools", "clean"], &scratch.root);
    assert_eq!(code, 0);
    assert!(out.contains("qa-check purged-tools: clean"), "{out}");

    // An install-refusing check with a finding is the refusal class (rc 3).
    let (code, out, err) = run_seam(&["stale-ignorepkg"], &scratch.root);
    assert_eq!(code, 3, "an install-refusing finding is rc 3 (§G): {err}");
    assert!(out.contains("stale-ignorepkg: viol-ghost:"), "{out}");

    // Skipped is loud and clean-class (abi-closure over zero archives).
    let (code, out, _err) = run_seam(&["abi-closure", "clean"], &scratch.root);
    assert_eq!(code, 0);
    assert!(out.contains("qa-check abi-closure: skipped —"), "{out}");

    // Usage class (§G rc 2): no name, unknown name, unknown reference.
    let (code, _out, err) = run_seam(&[], &scratch.root);
    assert_eq!(code, 2);
    assert!(err.contains("requires a check name"), "{err}");
    let (code, _out, err) = run_seam(&["purged-tool"], &scratch.root);
    assert_eq!(code, 2);
    assert!(err.contains("unknown check 'purged-tool'"), "{err}");
    assert!(
        err.contains("purged-tools"),
        "the roster must be named: {err}"
    );
    let (code, _out, err) = run_seam(&["purged-tools", "nonesuch"], &scratch.root);
    assert_eq!(code, 2);
    assert!(err.contains("unknown recipe reference 'nonesuch'"), "{err}");
}

#[test]
fn report_lines_render_the_prose_shape() {
    let scratch = Scratch::new("prose");
    scratch.recipe(
        "viol",
        "pkgbase = viol\npkgname = viol\npkgver = 1.0.0\npkgrel = 1\nmakedepends = cuda\n",
    );
    let workspace = load_workspace(&scratch.root).unwrap();
    let archives: Vec<QaArchive> = Vec::new();
    let input = QaInput {
        recipes: &workspace.recipes,
        targets: &[],
        archives: &archives,
        installed: &[],
        exclusions: &workspace.exclusions,
    };
    let lines = gsa_qa::report::render_lines(&gsa_qa::report::report_findings(&input));
    assert!(
        lines
            .iter()
            .any(|line| line.starts_with("purged-tools: viol: ")),
        "{lines:?}"
    );
}
