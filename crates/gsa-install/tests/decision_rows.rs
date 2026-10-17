//! Integration tests for the install decision seam (contract §E): plan-row
//! generation for every decision class against real tiny `.pkg.tar.zst`
//! archives, a synthetic installed DB, and crafted ELF members. Scratch
//! trees live under `std::env::temp_dir()` and are removed at the end of
//! each test.

use std::fs::File;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Mutex;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use gsa_install::{
    decide, decide_mode, discover_recipe, install_built_package, rollback_registration_names,
    rows_rc, Candidate, DecideMode, DecisionContext, EmptyListPolicy, InstallRun, InstalledPackage,
    LocalDb,
};
use gsa_model::Decision;

static COUNTER: AtomicU32 = AtomicU32::new(0);

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "gsa-install-test-{name}-{}-{}",
        std::process::id(),
        COUNTER.fetch_add(1, Ordering::SeqCst)
    ));
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

/// A minimal `.PKGINFO` body. `version` is makepkg's `pkgver` field (the
/// full `pkgver-pkgrel`); canonical form becomes `0:<version>`.
fn pkginfo_body(pkgname: &str, version: &str, provides: &[&str]) -> Vec<u8> {
    let mut body =
        format!("pkgbase = {pkgname}\npkgname = {pkgname}\npkgver = {version}\narch = x86_64\n");
    for provide in provides {
        body.push_str(&format!("provides = {provide}\n"));
    }
    body.into_bytes()
}

fn candidate(path: &Path, recipe_dir: Option<&Path>) -> Candidate {
    Candidate {
        archive: path.to_path_buf(),
        recipe_dir: recipe_dir.map(|d| d.to_path_buf()),
    }
}

fn checked_ctx() -> DecisionContext {
    DecisionContext {
        mode: DecideMode::Checked,
        empty_list: EmptyListPolicy::Refuse,
        ..Default::default()
    }
}

fn force_ctx() -> DecisionContext {
    DecisionContext {
        mode: DecideMode::Force,
        empty_list: EmptyListPolicy::Noop,
        ..Default::default()
    }
}

fn rendered(rows: &[gsa_model::DecisionRow]) -> Vec<String> {
    rows.iter().map(|r| r.render()).collect()
}

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
    for (tag, val) in [
        (1u64, 1u64), // DT_NEEDED
        (5u64, dynstr_off),
        (10u64, dynstr.len() as u64),
        (0u64, 0u64), // DT_NULL
    ] {
        out.extend_from_slice(&tag.to_le_bytes());
        out.extend_from_slice(&val.to_le_bytes());
    }
    out.extend_from_slice(&dynstr);
    out
}

fn set_mtime(path: &Path, time: SystemTime) {
    File::open(path).unwrap().set_modified(time).unwrap();
}

fn installed(
    name: &str,
    version: &str,
    provides: &[&str],
    depends: &[&str],
    install_date: Option<SystemTime>,
) -> InstalledPackage {
    InstalledPackage {
        name: name.to_string(),
        version: version.to_string(),
        base: Some(name.to_string()),
        provides: provides.iter().map(|s| s.to_string()).collect(),
        depends: depends.iter().map(|s| s.to_string()).collect(),
        files: Vec::new(),
        install_date,
    }
}

// ─── decision classes ────────────────────────────────────────────────────────

#[test]
fn force_mode_installs_every_surviving_candidate() {
    let dir = scratch("force-install");
    let archive = dir.join("foo-1.0-1-x86_64.pkg.tar.zst");
    write_archive(
        &archive,
        &[(".PKGINFO", &pkginfo_body("foo", "1.0-1", &[]))],
    );
    let rows = decide(
        std::slice::from_ref(&candidate(&archive, None)),
        &force_ctx(),
        &LocalDb::default(),
    )
    .unwrap();
    assert_eq!(rendered(&rows), vec!["foo install ok".to_string()]);
    assert_eq!(rows_rc(&rows), 0);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn checked_mode_skips_already_current_and_installs_on_doubt() {
    let dir = scratch("skip");
    let archive = dir.join("foo-1.0-1-x86_64.pkg.tar.zst");
    write_archive(
        &archive,
        &[(".PKGINFO", &pkginfo_body("foo", "1.0-1", &[]))],
    );
    let old = SystemTime::now() - Duration::from_secs(3600);
    set_mtime(&archive, old);

    // Exact version + install date not older than the archive → skip.
    let db = LocalDb::from_packages(vec![installed(
        "foo",
        "0:1.0-1",
        &[],
        &[],
        Some(SystemTime::now()),
    )]);
    let rows = decide(
        std::slice::from_ref(&candidate(&archive, None)),
        &checked_ctx(),
        &db,
    )
    .unwrap();
    assert_eq!(
        rendered(&rows),
        vec!["foo skip already-current 0:1.0-1".to_string()]
    );
    assert_eq!(rows_rc(&rows), 0);

    // Doubt installs: a missing install date keeps the archive in the set.
    let db_doubt = LocalDb::from_packages(vec![installed("foo", "0:1.0-1", &[], &[], None)]);
    let rows = decide(
        std::slice::from_ref(&candidate(&archive, None)),
        &checked_ctx(),
        &db_doubt,
    )
    .unwrap();
    assert_eq!(rendered(&rows), vec!["foo install ok".to_string()]);

    // Doubt installs: a version mismatch installs.
    let db_other = LocalDb::from_packages(vec![installed(
        "foo",
        "0:0.9-1",
        &[],
        &[],
        Some(SystemTime::now()),
    )]);
    let rows = decide(
        std::slice::from_ref(&candidate(&archive, None)),
        &checked_ctx(),
        &db_other,
    )
    .unwrap();
    assert_eq!(rendered(&rows), vec!["foo install ok".to_string()]);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn checked_mode_installs_when_the_archive_is_newer_than_the_install() {
    let dir = scratch("newer");
    let archive = dir.join("foo-1.0-1-x86_64.pkg.tar.zst");
    write_archive(
        &archive,
        &[(".PKGINFO", &pkginfo_body("foo", "1.0-1", &[]))],
    );
    // The archive was rebuilt AFTER the install: a same-version rebuild
    // still installs (rule 11's freshness guard, nanosecond compare).
    set_mtime(&archive, SystemTime::now());
    let db = LocalDb::from_packages(vec![installed(
        "foo",
        "0:1.0-1",
        &[],
        &[],
        Some(SystemTime::now() - Duration::from_secs(3600)),
    )]);
    let rows = decide(
        std::slice::from_ref(&candidate(&archive, None)),
        &checked_ctx(),
        &db,
    )
    .unwrap();
    assert_eq!(rendered(&rows), vec!["foo install ok".to_string()]);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn force_mode_bypasses_the_same_version_skip() {
    let dir = scratch("force-skip");
    let archive = dir.join("foo-1.0-1-x86_64.pkg.tar.zst");
    write_archive(
        &archive,
        &[(".PKGINFO", &pkginfo_body("foo", "1.0-1", &[]))],
    );
    set_mtime(&archive, SystemTime::now() - Duration::from_secs(3600));
    let db = LocalDb::from_packages(vec![installed(
        "foo",
        "0:1.0-1",
        &[],
        &[],
        Some(SystemTime::now()),
    )]);
    let rows = decide(
        std::slice::from_ref(&candidate(&archive, None)),
        &force_ctx(),
        &db,
    )
    .unwrap();
    assert_eq!(rendered(&rows), vec!["foo install ok".to_string()]);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn pgo_payload_gate_refuses_an_instrumented_recipe() {
    let dir = scratch("pgo");
    let recipe = dir.join("recipe");
    std::fs::create_dir_all(&recipe).unwrap();
    std::fs::write(
        recipe.join("PKGBUILD"),
        "build() {\n  CFLAGS=\"$CFLAGS -fprofile-generate=/build/prof\"\n}\n",
    )
    .unwrap();
    let archive = recipe.join("foo-1.0-1-x86_64.pkg.tar.zst");
    let mut payload = b"\x7fELF noise ".to_vec();
    payload.extend_from_slice(b"/x/y.gcda");
    payload.extend_from_slice(b" tail");
    write_archive(
        &archive,
        &[
            (".PKGINFO", &pkginfo_body("foo", "1.0-1", &[])),
            ("usr/bin/foo", &payload),
        ],
    );
    let rows = decide(
        std::slice::from_ref(&candidate(&archive, Some(&recipe))),
        &force_ctx(),
        &LocalDb::default(),
    )
    .unwrap();
    let want = [
        format!("foo refuse pgo-hit {} usr/bin/foo", archive.display()),
        format!("foo refuse pgo-instrumented {}", archive.display()),
    ];
    assert_eq!(rendered(&rows), want);
    assert_eq!(rows_rc(&rows), 1);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn pgo_payload_gate_ignores_glob_literals() {
    let dir = scratch("pgo-glob");
    let recipe = dir.join("recipe");
    std::fs::create_dir_all(&recipe).unwrap();
    std::fs::write(
        recipe.join("PKGBUILD"),
        "build() {\n  CFLAGS=\"$CFLAGS -fprofile-generate=/build/prof\"\n}\n",
    )
    .unwrap();
    let archive = recipe.join("foo-1.0-1-x86_64.pkg.tar.zst");
    write_archive(
        &archive,
        &[
            (".PKGINFO", &pkginfo_body("foo", "1.0-1", &[])),
            ("usr/bin/ctest", b"coverage output goes to /*.gcda glob"),
        ],
    );
    let rows = decide(
        std::slice::from_ref(&candidate(&archive, Some(&recipe))),
        &force_ctx(),
        &LocalDb::default(),
    )
    .unwrap();
    assert_eq!(rendered(&rows), vec!["foo install ok".to_string()]);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn needed_probe_refuses_an_unresolvable_soname() {
    let dir = scratch("needed");
    let archive = dir.join("foo-1.0-1-x86_64.pkg.tar.zst");
    write_archive(
        &archive,
        &[
            (".PKGINFO", &pkginfo_body("foo", "1.0-1", &[])),
            ("usr/bin/foo", &elf64_with_needed("libmissing.so.1")),
        ],
    );
    let rows = decide(
        std::slice::from_ref(&candidate(&archive, None)),
        &force_ctx(),
        &LocalDb::default(),
    )
    .unwrap();
    assert_eq!(
        rendered(&rows),
        vec![format!(
            "foo refuse needed {} usr/bin/foo libmissing.so.1",
            archive.display()
        )]
    );
    assert_eq!(rows_rc(&rows), 1);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn needed_probe_accepts_sonames_the_transaction_ships() {
    let dir = scratch("needed-shipped");
    let archive = dir.join("foo-1.0-1-x86_64.pkg.tar.zst");
    write_archive(
        &archive,
        &[
            (".PKGINFO", &pkginfo_body("foo", "1.0-1", &[])),
            ("usr/bin/foo", &elf64_with_needed("libmissing.so.1")),
            ("usr/lib/libmissing.so.1", b"the shipped provider"),
        ],
    );
    let rows = decide(
        std::slice::from_ref(&candidate(&archive, None)),
        &force_ctx(),
        &LocalDb::default(),
    )
    .unwrap();
    assert_eq!(rendered(&rows), vec!["foo install ok".to_string()]);

    // The base-system sonames skip the probe entirely.
    let archive2 = dir.join("bar-1.0-1-x86_64.pkg.tar.zst");
    write_archive(
        &archive2,
        &[
            (".PKGINFO", &pkginfo_body("bar", "1.0-1", &[])),
            ("usr/bin/bar", &elf64_with_needed("libc.so.6")),
        ],
    );
    let rows = decide(
        std::slice::from_ref(&candidate(&archive2, None)),
        &force_ctx(),
        &LocalDb::default(),
    )
    .unwrap();
    assert_eq!(rendered(&rows), vec!["bar install ok".to_string()]);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn abi_soname_gate_refuses_a_disappearing_provide() {
    let dir = scratch("abi");
    let archive = dir.join("foo-2.0-1-x86_64.pkg.tar.zst");
    write_archive(
        &archive,
        &[(".PKGINFO", &pkginfo_body("foo", "2.0-1", &[]))],
    );
    let db = LocalDb::from_packages(vec![installed(
        "foo",
        "0:1.0-1",
        &["libfoo.so=1-64"],
        &[],
        Some(SystemTime::now()),
    )]);
    let rows = decide(
        std::slice::from_ref(&candidate(&archive, None)),
        &force_ctx(),
        &db,
    )
    .unwrap();
    assert_eq!(
        rendered(&rows),
        vec![format!(
            "foo refuse abi-soname {} foo libfoo.so 1-64 -",
            archive.display()
        )]
    );
    assert_eq!(rows_rc(&rows), 1);

    // A version move names both sides (installed → built).
    let archive2 = dir.join("foo-2.1-1-x86_64.pkg.tar.zst");
    write_archive(
        &archive2,
        &[(
            ".PKGINFO",
            &pkginfo_body("foo", "2.1-1", &["libfoo.so=2-64"]),
        )],
    );
    let rows = decide(
        std::slice::from_ref(&candidate(&archive2, None)),
        &force_ctx(),
        &db,
    )
    .unwrap();
    assert_eq!(
        rendered(&rows),
        vec![format!(
            "foo refuse abi-soname {} foo libfoo.so 1-64 2-64",
            archive2.display()
        )]
    );
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn unreadable_pkginfo_is_skipped_when_names_establish_and_refuses_when_they_do_not() {
    let dir = scratch("unreadable");
    let garbage = dir.join("foo-1.0-1-x86_64.pkg.tar.zst");
    std::fs::write(&garbage, b"this is not a zstd tar archive").unwrap();

    // Names NOT establishable (no recipe dir, no .PKGINFO) → fail-closed.
    let rows = decide(
        std::slice::from_ref(&candidate(&garbage, None)),
        &force_ctx(),
        &LocalDb::default(),
    )
    .unwrap();
    assert_eq!(
        rendered(&rows),
        vec![format!("- refuse discover-failed {}", garbage.display())]
    );
    assert_eq!(rows_rc(&rows), 1);

    // Names establishable from the second authority → skip, never probed.
    let recipe = dir.join("recipe");
    std::fs::create_dir_all(&recipe).unwrap();
    std::fs::write(recipe.join(".SRCINFO"), "pkgbase = foo\npkgname = foo\n").unwrap();
    let garbage2 = recipe.join("foo-1.0-1-x86_64.pkg.tar.zst");
    std::fs::write(&garbage2, b"still not a zstd tar archive").unwrap();
    let rows = decide(
        std::slice::from_ref(&candidate(&garbage2, Some(&recipe))),
        &force_ctx(),
        &LocalDb::default(),
    )
    .unwrap();
    assert_eq!(
        rendered(&rows),
        vec!["foo skip unreadable-pkginfo".to_string()]
    );
    assert_eq!(rows_rc(&rows), 0);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn empty_list_refuses_under_checked_and_noops_under_force() {
    let db = LocalDb::default();
    let rows = decide(&[], &checked_ctx(), &db).unwrap();
    assert_eq!(rendered(&rows), vec!["- refuse empty-list".to_string()]);
    assert_eq!(rows_rc(&rows), 1);

    let rows = decide(&[], &force_ctx(), &db).unwrap();
    assert_eq!(rendered(&rows), vec!["- noop empty-list".to_string()]);
    assert_eq!(rows_rc(&rows), 0);
}

#[test]
fn parked_subjects_are_never_probed() {
    let dir = scratch("parked");
    let archive = dir.join("foo-1.0-1-x86_64.pkg.tar.zst");
    write_archive(
        &archive,
        &[(".PKGINFO", &pkginfo_body("foo", "1.0-1", &[]))],
    );
    let mut ctx = force_ctx();
    ctx.parks = vec![("foo".to_string(), "waits-on-deferred".to_string())];
    let rows = decide(
        std::slice::from_ref(&candidate(&archive, None)),
        &ctx,
        &LocalDb::default(),
    )
    .unwrap();
    assert_eq!(
        rendered(&rows),
        vec!["foo parked waits-on-deferred".to_string()]
    );
    assert_eq!(rows_rc(&rows), 0, "parking is a deferral, not a refusal");

    // A parked subject's row is parked even when every other gate would
    // have spoken (here: the unreadable-pkginfo class).
    let recipe = dir.join("recipe");
    std::fs::create_dir_all(&recipe).unwrap();
    std::fs::write(recipe.join(".SRCINFO"), "pkgbase = foo\npkgname = foo\n").unwrap();
    let garbage = recipe.join("foo-2.0-1-x86_64.pkg.tar.zst");
    std::fs::write(&garbage, b"garbage").unwrap();
    let rows = decide(
        std::slice::from_ref(&candidate(&garbage, Some(&recipe))),
        &ctx,
        &LocalDb::default(),
    )
    .unwrap();
    assert_eq!(
        rendered(&rows),
        vec!["foo parked waits-on-deferred".to_string()]
    );
    let _ = std::fs::remove_dir_all(&dir);
}

// ─── rc contract and mode parsing (§E.5, §D.1) ───────────────────────────────

#[test]
fn rows_rc_distinguishes_plans_from_refusals() {
    let ok = gsa_model::DecisionRow {
        subject: "foo".to_string(),
        decision: Decision::Install,
        reason: "ok".to_string(),
    };
    let refused = gsa_model::DecisionRow {
        subject: "foo".to_string(),
        decision: Decision::Refuse,
        reason: "pgo-instrumented foo.pkg.tar.zst".to_string(),
    };
    assert_eq!(rows_rc(&[ok.clone()]), 0);
    assert_eq!(rows_rc(&[ok, refused]), 1);
}

#[test]
fn decide_mode_rejects_unknown_words() {
    assert_eq!(decide_mode("checked").unwrap(), DecideMode::Checked);
    assert_eq!(decide_mode("force").unwrap(), DecideMode::Force);
    assert!(decide_mode("Checked").is_err());
    assert!(decide_mode("").is_err());
    assert!(decide_mode("nope").is_err());
}

// ─── discovery and the install step (rule 11's partial-set refusal) ──────────

#[test]
fn install_built_package_refuses_an_incomplete_output_set_pacman_free() {
    let dir = scratch("partial");
    let recipe = dir.join("recipe");
    std::fs::create_dir_all(&recipe).unwrap();
    std::fs::write(
        recipe.join(".SRCINFO"),
        "pkgbase = foo\npkgname = foo\npkgname = foo-docs\n",
    )
    .unwrap();
    write_archive(
        &recipe.join("foo-1.0-1-x86_64.pkg.tar.zst"),
        &[(".PKGINFO", &pkginfo_body("foo", "1.0-1", &[]))],
    );
    let run = InstallRun {
        mode: DecideMode::Checked,
        state_dir: dir.join("state"),
        conf: Some(dir.join("pacman.conf")),
        pacman_args: Vec::new(),
        register_ignorepkg: false,
        later_installs: Vec::new(),
    };
    let (rows, outcome) = install_built_package(&recipe, &run).unwrap();
    assert!(
        outcome.is_none(),
        "a refused plan is pacman-free (rule 25(h))"
    );
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].decision, Decision::Refuse);
    assert!(rows[0]
        .reason
        .starts_with(&format!("partial-set {} foo-docs", recipe.display())));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn install_built_package_refuses_a_mixed_version_set() {
    let dir = scratch("mixed");
    let recipe = dir.join("recipe");
    std::fs::create_dir_all(&recipe).unwrap();
    std::fs::write(
        recipe.join(".SRCINFO"),
        "pkgbase = foo\npkgname = foo\npkgname = foo-docs\n",
    )
    .unwrap();
    write_archive(
        &recipe.join("foo-1.0-1-x86_64.pkg.tar.zst"),
        &[(".PKGINFO", &pkginfo_body("foo", "1.0-1", &[]))],
    );
    write_archive(
        &recipe.join("foo-docs-2.0-1-any.pkg.tar.zst"),
        &[(".PKGINFO", &pkginfo_body("foo-docs", "2.0-1", &[]))],
    );
    let run = InstallRun {
        mode: DecideMode::Force,
        state_dir: dir.join("state"),
        conf: Some(dir.join("pacman.conf")),
        pacman_args: Vec::new(),
        register_ignorepkg: false,
        later_installs: Vec::new(),
    };
    let (rows, outcome) = install_built_package(&recipe, &run).unwrap();
    assert!(outcome.is_none());
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].decision, Decision::Refuse);
    assert!(rows[0]
        .reason
        .starts_with(&format!("partial-set {} mixed-versions", recipe.display())));
    let _ = std::fs::remove_dir_all(&dir);
}

// ─── the IgnorePkg rollback computation (rule 9's complement) ───────────────
// The `-U` path feeds the same computation its staged-swap shape: `keep`
// carries the skip (already-current) names AND the names whose archives
// LANDED, so a multi-wave partial success keeps exactly its landed
// registrations.

fn name_list(list: &[&str]) -> Vec<String> {
    list.iter().map(|s| s.to_string()).collect()
}

#[test]
fn rollback_registration_names_keeps_the_landed_waves_names() {
    // Multi-wave partial success: wave 1 landed (lib1, app1 — kept), wave 2
    // failed (lib2, app2), the leftover was held (solo), and a name shared
    // by a landed and a failed archive stays — it IS installed via the
    // landed one. Only the never-installed additions go back.
    assert_eq!(
        rollback_registration_names(
            &name_list(&["lib1", "app1", "shared", "lib2", "app2", "solo", "skipper"]),
            &name_list(&["lib1", "app1", "shared", "lib2", "app2", "solo"]),
            // keep = skip (already-current) ∪ landed waves
            &name_list(&["skipper", "lib1", "app1", "shared"]),
        ),
        name_list(&["lib2", "app2", "solo"])
    );
}

#[test]
fn rollback_registration_names_on_the_interrupt_set() {
    // Interrupt with nothing landed (the in-flight transaction was torn
    // down): every install-bearing added name goes back, while a skip
    // (already-current) name stays — it IS installed.
    assert_eq!(
        rollback_registration_names(
            &name_list(&["alpha", "alpha-out", "skipper"]),
            &name_list(&["alpha", "alpha-out"]),
            &name_list(&["skipper"]),
        ),
        name_list(&["alpha", "alpha-out"])
    );
}

// ─── version-ranked discovery (the wrong-skip fix) ──────────────────────────
//
// Selection ranks archives by canonical version first and breaks version ties
// (and unrankable pairs) by mtime: a same-version rebuild with a newer mtime
// must never shadow a higher-version archive into an `already-current` skip.
// Ranking resolves `vercmp` through PATH, so the fixtures whose outcome
// DEPENDS on version order hold `ENV_LOCK` against the one fixture that
// empties PATH — the others are deliberately fallback-invariant.

static ENV_LOCK: Mutex<()> = Mutex::new(());

fn discovered_archives(found: &gsa_install::RecipeArchives) -> Vec<PathBuf> {
    found.candidates.iter().map(|c| c.archive.clone()).collect()
}

#[test]
fn discovery_ranks_by_version_before_mtime() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let dir = scratch("version-rank");
    let recipe = dir.join("recipe");
    std::fs::create_dir_all(&recipe).unwrap();
    std::fs::write(recipe.join(".SRCINFO"), "pkgbase = foo\npkgname = foo\n").unwrap();
    // The 1.0-1 archive is the newer rebuild (mtime 200 vs 100): mtime order
    // picks it and the checked skip then fires against the installed 1.0-1,
    // shadowing the higher-version archive on disk (the wrong-skip).
    let low = recipe.join("foo-1.0-1-x86_64.pkg.tar.zst");
    write_archive(&low, &[(".PKGINFO", &pkginfo_body("foo", "1.0-1", &[]))]);
    set_mtime(&low, UNIX_EPOCH + Duration::from_secs(200));
    let high = recipe.join("foo-2.0-1-x86_64.pkg.tar.zst");
    write_archive(&high, &[(".PKGINFO", &pkginfo_body("foo", "2.0-1", &[]))]);
    set_mtime(&high, UNIX_EPOCH + Duration::from_secs(100));

    let found = discover_recipe(&recipe).unwrap();
    assert_eq!(
        discovered_archives(&found),
        vec![high.clone()],
        "the higher version must win over the newer-mtime shadow"
    );

    // Checked mode must INSTALL the version mismatch, never skip.
    let db = LocalDb::from_packages(vec![installed(
        "foo",
        "0:1.0-1",
        &[],
        &[],
        Some(SystemTime::now()),
    )]);
    let rows = decide(&found.candidates, &checked_ctx(), &db).unwrap();
    assert_eq!(rendered(&rows), vec!["foo install ok".to_string()]);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn discovery_ranks_versions_numerically_not_lexically() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let dir = scratch("version-lexical");
    let recipe = dir.join("recipe");
    std::fs::create_dir_all(&recipe).unwrap();
    std::fs::write(recipe.join(".SRCINFO"), "pkgbase = foo\npkgname = foo\n").unwrap();
    // 1.9 wins on mtime AND lexically (`9` > `1`); only vercmp order ranks
    // 1.10 above it — string order must never stand in for version order.
    let nine = recipe.join("foo-1.9-1-x86_64.pkg.tar.zst");
    write_archive(&nine, &[(".PKGINFO", &pkginfo_body("foo", "1.9-1", &[]))]);
    set_mtime(&nine, UNIX_EPOCH + Duration::from_secs(200));
    let ten = recipe.join("foo-1.10-1-x86_64.pkg.tar.zst");
    write_archive(&ten, &[(".PKGINFO", &pkginfo_body("foo", "1.10-1", &[]))]);
    set_mtime(&ten, UNIX_EPOCH + Duration::from_secs(100));

    let found = discover_recipe(&recipe).unwrap();
    assert_eq!(discovered_archives(&found), vec![ten]);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn discovery_breaks_version_ties_by_the_newest_mtime() {
    let dir = scratch("version-tie");
    let recipe = dir.join("recipe");
    std::fs::create_dir_all(&recipe).unwrap();
    std::fs::write(recipe.join(".SRCINFO"), "pkgbase = foo\npkgname = foo\n").unwrap();
    // Same canonical version: the newest rebuild wins (rule 11's freshness
    // direction). Outcome is identical without vercmp, so no PATH lock.
    let x86 = recipe.join("foo-1.0-1-x86_64.pkg.tar.zst");
    write_archive(&x86, &[(".PKGINFO", &pkginfo_body("foo", "1.0-1", &[]))]);
    set_mtime(&x86, UNIX_EPOCH + Duration::from_secs(100));
    let any = recipe.join("foo-1.0-1-any.pkg.tar.zst");
    write_archive(&any, &[(".PKGINFO", &pkginfo_body("foo", "1.0-1", &[]))]);
    set_mtime(&any, UNIX_EPOCH + Duration::from_secs(200));

    let found = discover_recipe(&recipe).unwrap();
    assert_eq!(discovered_archives(&found), vec![any]);
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn discovery_keeps_split_outputs_of_one_version_together() {
    let dir = scratch("set-scoped");
    let recipe = dir.join("recipe");
    std::fs::create_dir_all(&recipe).unwrap();
    std::fs::write(
        recipe.join(".SRCINFO"),
        "pkgbase = foo\npkgname = foo\npkgname = foo-docs\n",
    )
    .unwrap();
    // A half-built 2.0-1 set (foo only) beside a complete 1.0-1 set carrying
    // the newer mtimes. Splicing foo-2.0-1 into the 1.0-1 pair manufactures a
    // `partial-set … mixed-versions` refusal where the mtime-ranked chooser
    // installed a coherent set: selection must stay set-scoped, one version's
    // split outputs together.
    let foo_20 = recipe.join("foo-2.0-1-x86_64.pkg.tar.zst");
    write_archive(&foo_20, &[(".PKGINFO", &pkginfo_body("foo", "2.0-1", &[]))]);
    set_mtime(&foo_20, UNIX_EPOCH + Duration::from_secs(300));
    let foo_10 = recipe.join("foo-1.0-1-x86_64.pkg.tar.zst");
    write_archive(&foo_10, &[(".PKGINFO", &pkginfo_body("foo", "1.0-1", &[]))]);
    set_mtime(&foo_10, UNIX_EPOCH + Duration::from_secs(100));
    let docs_10 = recipe.join("foo-docs-1.0-1-any.pkg.tar.zst");
    write_archive(
        &docs_10,
        &[(".PKGINFO", &pkginfo_body("foo-docs", "1.0-1", &[]))],
    );
    set_mtime(&docs_10, UNIX_EPOCH + Duration::from_secs(300));

    let found = discover_recipe(&recipe).unwrap();
    assert_eq!(
        discovered_archives(&found),
        vec![foo_10, docs_10],
        "the set-scoped choice: one version's outputs together"
    );
    assert!(!found.mixed_versions, "no new mixed-versions refusal");
    assert!(found.missing.is_empty());
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn discovery_without_vercmp_keeps_the_mtime_order() {
    let _lock = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
    let dir = scratch("no-vercmp");
    let recipe = dir.join("recipe");
    std::fs::create_dir_all(&recipe).unwrap();
    std::fs::write(recipe.join(".SRCINFO"), "pkgbase = foo\npkgname = foo\n").unwrap();
    let low = recipe.join("foo-1.0-1-x86_64.pkg.tar.zst");
    write_archive(&low, &[(".PKGINFO", &pkginfo_body("foo", "1.0-1", &[]))]);
    set_mtime(&low, UNIX_EPOCH + Duration::from_secs(200));
    let high = recipe.join("foo-2.0-1-x86_64.pkg.tar.zst");
    write_archive(&high, &[(".PKGINFO", &pkginfo_body("foo", "2.0-1", &[]))]);
    set_mtime(&high, UNIX_EPOCH + Duration::from_secs(100));

    // PATH without vercmp: the rank degrades to mtime order, never to string
    // order (which would pick the 2.0-1 archive here).
    let empty_path = dir.join("path");
    std::fs::create_dir_all(&empty_path).unwrap();
    let saved = std::env::var_os("PATH");
    std::env::set_var("PATH", &empty_path);
    let found = discover_recipe(&recipe);
    match saved {
        Some(path) => std::env::set_var("PATH", path),
        None => std::env::remove_var("PATH"),
    }
    let found = found.unwrap();
    assert_eq!(
        discovered_archives(&found),
        vec![low],
        "without vercmp the chooser must keep the mtime order"
    );
    let _ = std::fs::remove_dir_all(&dir);
}
